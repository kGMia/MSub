from __future__ import annotations

import argparse
import asyncio
import atexit
import contextlib
import hashlib
import json
import math
import wave
import os
import re
import signal
import shutil
import subprocess
import threading
import time
import traceback
import uuid
from dataclasses import asdict
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from .diagnostics import JobDiagnostics

from .cli import (
    DEFAULT_EMOTION_MODEL,
    DEFAULT_EMOTION_MODEL_ID,
    DEFAULT_AUDIO_EVENT_MODEL,
    DEFAULT_AUDIO_EVENT_MODEL_ID,
    DEFAULT_MODEL,
    DEFAULT_FUNASR_MODEL,
    DEFAULT_FUNASR_MODEL_ID,
    DEFAULT_MEGA_MODEL,
    DEFAULT_MIMO_MODEL,
    DEFAULT_QWEN3_MODEL,
    DEFAULT_QWEN3_MODEL_ID,
    FUNASR_DEFAULT_MAX_TOKENS,
    FUNASR_DEFAULT_TEMPERATURE,
    FUNASR_DEFAULT_TOP_K,
    FUNASR_DEFAULT_TOP_P,
    QWEN3_DEFAULT_MAX_TOKENS,
    QWEN3_DEFAULT_TEMPERATURE,
    QWEN3_DEFAULT_TOP_K,
    QWEN3_DEFAULT_TOP_P,
    MEGA_DEFAULT_MAX_TOKENS,
    MEGA_DEFAULT_TEMPERATURE,
    MEGA_DEFAULT_TOP_K,
    MEGA_DEFAULT_TOP_P,
    MIMO_DEFAULT_MAX_TOKENS,
    MIMO_DEFAULT_TEMPERATURE,
    MIMO_DEFAULT_TOP_K,
    MIMO_DEFAULT_TOP_P,
    DEFAULT_SPEAKER_CLUSTERING_METHOD,
    DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL,
    DEFAULT_SPEAKER_RECOGNITION_MODEL,
    DEFAULT_SPEAKER_RECOGNITION_MODEL_ID,
    DEFAULT_SENSEVOICE_MODEL,
    DEFAULT_ALIGNER_MODEL,
    DEFAULT_ALIGNER_MODEL_ID,
    DEFAULT_DENOISE_MODEL,
    DEFAULT_DENOISE_MODEL_ID,
    DEFAULT_MEGA_MODEL_ID,
    DEFAULT_MIMO_MODEL_ID,
    DEFAULT_PUNC_MODEL,
    DEFAULT_PUNC_MODEL_ID,
    DEFAULT_SENSEVOICE_MODEL_ID,
    diarization_token,
    DEFAULT_FIRERED_VAD_MODEL,
    DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL,
    Segment,
    audio_timeline_sync_filter,
    build_segments,
    clear_aux_model_caches,
    clear_stt_model_cache,
    extract_audio,
    firered_vad_coreml_files_available,
    mark_non_lexical_segments,
    normalize_output_path,
    pyannote_segmentation_mlx_available,
    probe_duration,
    require_ffprobe,
    run,
    speaker_diarization_coreml_files_available,
    stt_model_cache_info,
    subprocess_tracking_context,
    terminate_active_subprocesses,
    terminate_active_subprocesses_for_owner,
    tracked_subprocess_run,
)


BASE_DIR = Path(os.getenv("MSUB_BACKEND_ROOT") or Path(__file__).resolve().parents[2])
JOB_DIR = Path(os.getenv("MSUB_JOB_DIR") or BASE_DIR / "output" / "web_jobs").expanduser()
DEFAULT_DIARIZATION_MODEL_ID = "pyannote/speaker-diarization-community-1"
LOCAL_DIARIZATION_MODEL_DIRNAME = "pyannote-speaker-diarization-community-1"
JOB_TTL_SECONDS = 6 * 60 * 60
TERMINAL_STATUSES = {"done", "error", "cancelled"}


def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


MAX_CONCURRENT_JOBS = max(1, env_int("MSUB_MAX_CONCURRENT_JOBS", 1))
MODEL_IDLE_SECONDS = max(0, env_int("MSUB_MODEL_IDLE_SECONDS", 45))
MAX_JOB_EVENTS = max(0, env_int("MSUB_MAX_JOB_EVENTS", 300))
LOG_PROGRESS_EVENTS = env_bool("MSUB_LOG_PROGRESS_EVENTS", False)
PARENT_PID = env_int("MSUB_PARENT_PID", 0)


app = FastAPI(title="MSub")

jobs: dict[str, dict[str, Any]] = {}
jobs_lock = threading.Lock()
job_semaphore = threading.Semaphore(MAX_CONCURRENT_JOBS)
job_pause_events: dict[str, threading.Event] = {}
model_lock = threading.Lock()
model_active_jobs = 0
model_last_used = 0.0
shutdown_event = threading.Event()
shutdown_lock = threading.Lock()


def append_backend_error_log(message: str) -> Path:
    JOB_DIR.mkdir(parents=True, exist_ok=True)
    path = JOB_DIR / "backend-errors.log"
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"\n[{timestamp}] {message}\n")
    return path


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    trace = traceback.format_exc()
    log_path = append_backend_error_log(
        f"{request.method} {request.url.path}\n{trace}"
    )
    print(trace, flush=True)
    return JSONResponse(
        status_code=500,
        content={
            "detail": str(exc) or exc.__class__.__name__,
            "errorType": exc.__class__.__name__,
            "tracePath": str(log_path),
        },
    )


def compute_backend_source_fingerprint() -> str:
    digest = hashlib.sha256()
    for path in (Path(__file__).with_name("cli.py"), Path(__file__)):
        digest.update(path.name.encode("utf-8"))
        try:
            digest.update(path.read_bytes())
        except OSError:
            digest.update(b"missing")
    return digest.hexdigest()


BACKEND_SOURCE_FINGERPRINT = compute_backend_source_fingerprint()


job_diagnostics: dict[str, JobDiagnostics] = {}
job_progress_persisted_at: dict[str, float] = {}
QWEN3_JA_MODEL_ID = "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-bf16"
QWEN3_JA_MODEL_DIR = "Qwen3-ASR-1.7B-JA-MLX-bf16"


class JobCancelled(RuntimeError):
    pass


def model_cache_state() -> dict[str, Any]:
    with model_lock:
        active_jobs = model_active_jobs
        last_used = model_last_used
    cache = stt_model_cache_info()
    idle_seconds = None
    if last_used > 0:
        idle_seconds = max(0, round(time.time() - last_used, 3))
    return {
        "loaded": cache["currentSize"] > 0,
        "activeJobs": active_jobs,
        "idleSeconds": idle_seconds,
        "idleUnloadSeconds": MODEL_IDLE_SECONDS,
        "cache": cache,
    }


def mark_model_job_started() -> None:
    global model_active_jobs
    with model_lock:
        model_active_jobs += 1


def mark_model_job_finished() -> None:
    global model_active_jobs, model_last_used
    with model_lock:
        model_active_jobs = max(0, model_active_jobs - 1)
        model_last_used = time.time()


def unload_model_cache(reason: str) -> bool:
    with model_lock:
        if model_active_jobs > 0:
            return False
        # Keep the check and eviction atomic against a new model job starting.
        clear_aux_model_caches()
        if stt_model_cache_info()["currentSize"] == 0:
            return False
        clear_stt_model_cache()
    print(f"MSub backend unloaded ASR model cache: {reason}", flush=True)
    return True


def unload_idle_model_if_needed() -> None:
    with model_lock:
        active_jobs = model_active_jobs
        last_used = model_last_used
    if active_jobs > 0 or last_used <= 0:
        return
    if MODEL_IDLE_SECONDS == 0 or time.time() - last_used >= MODEL_IDLE_SECONDS:
        unload_model_cache("idle")


def model_reaper_loop() -> None:
    wait_seconds = 30.0
    if MODEL_IDLE_SECONDS > 0:
        wait_seconds = max(2.0, min(30.0, MODEL_IDLE_SECONDS / 3.0))
    while not shutdown_event.wait(wait_seconds):
        unload_idle_model_if_needed()


def parent_is_alive(pid: int) -> bool:
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def mark_jobs_cancelling_for_shutdown(reason: str) -> None:
    snapshots: list[dict[str, Any]] = []
    events: list[threading.Event] = []
    now = time.time()
    with jobs_lock:
        for job in jobs.values():
            if job.get("status") in TERMINAL_STATUSES:
                continue
            job["cancelRequested"] = True
            job["pauseRequested"] = False
            job["status"] = "cancelling"
            job["progressText"] = "Shutting down"
            job["updatedAt"] = now
            snapshots.append(dict(job))
            event = job_pause_events.get(str(job.get("id", "")))
            if event is not None:
                events.append(event)

    for snapshot in snapshots:
        persist_job_status(snapshot)
        append_job_log(str(snapshot.get("id", "")), f"Backend shutdown requested: {reason}")
    for event in events:
        event.set()


def request_backend_shutdown(reason: str, *, exit_process: bool = False) -> None:
    with shutdown_lock:
        if shutdown_event.is_set():
            if exit_process:
                os._exit(0)
            return
        shutdown_event.set()

    mark_jobs_cancelling_for_shutdown(reason)
    terminate_active_subprocesses()
    unload_model_cache(reason)
    cleanup_job_files_for_shutdown()
    print(f"MSub backend shutting down: {reason}", flush=True)
    if exit_process:
        os._exit(0)


def handle_shutdown_signal(signum: int, _frame: Any) -> None:
    request_backend_shutdown(f"signal {signum}")
    raise SystemExit(0)


def parent_watchdog_loop() -> None:
    if PARENT_PID <= 0:
        return
    while not shutdown_event.wait(2):
        if not parent_is_alive(PARENT_PID):
            request_backend_shutdown("parent process exited", exit_process=True)
            return


signal.signal(signal.SIGTERM, handle_shutdown_signal)
signal.signal(signal.SIGINT, handle_shutdown_signal)
atexit.register(lambda: request_backend_shutdown("atexit"))
def preload_default_model() -> None:
    """Warm the default ASR model so the first job skips the cold load.

    Opt-in via MSUB_PRELOAD_MODEL=1; the idle reaper leaves preloaded models
    alone until the first job marks them used.
    """
    try:
        from .cli import load_stt_model

        model_id = (os.getenv("MSUB_PRELOAD_MODEL_ID") or DEFAULT_MODEL).strip()
        load_stt_model(model_id)
        print(f"MSub backend preloaded ASR model: {model_id}", flush=True)
    except Exception as exc:  # noqa: BLE001 - preload is best-effort.
        print(f"MSub backend model preload failed: {exc}", flush=True)


threading.Thread(target=model_reaper_loop, name="model-reaper", daemon=True).start()
if PARENT_PID > 0:
    threading.Thread(target=parent_watchdog_loop, name="parent-watchdog", daemon=True).start()
if env_bool("MSUB_PRELOAD_MODEL", False):
    threading.Thread(target=preload_default_model, name="model-preload", daemon=True).start()


def clean_model_request(model: str | None, asr_engine: str | None) -> tuple[str, str]:
    engine = (asr_engine or "auto").strip().lower() or "auto"
    cleaned_model = str(model or "").strip()
    if not cleaned_model:
        cleaned_model = default_model_for_engine(
            engine if engine != "auto" else "fireredasr2"
        )
    return cleaned_model, engine


def make_args(
    input_path: Path,
    output_path: Path | None = None,
    *,
    model: str = DEFAULT_MODEL,
    asr_engine: str = "auto",
    language: str = "auto",
    use_itn: bool = True,
    sensevoice_rich_info: bool = False,
    mimo_max_tokens: int = 0,
    mimo_temperature: float = 0.0,
    mimo_top_p: float = 0.0,
    mimo_top_k: int = 0,
    fmt: str = "srt",
    segment_mode: str = "vad",
    vad_engine: str = "auto",
    vad_threshold_db: float = -38.0,
    firered_vad_model: str = DEFAULT_FIRERED_VAD_MODEL,
    firered_vad_threshold: float = 0.4,
    firered_vad_smooth_window: int = 5,
    pyannote_vad_model: str = DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL,
    pyannote_vad_threshold: float = 0.5,
    vad_min_speech_seconds: float = 0.2,
    vad_min_silence_seconds: float = 0.28,
    vad_padding_seconds: float = 0.20,
    vad_max_segment_seconds: float = 5.0,
    vad_min_segment_seconds: float = 0.8,
    vad_split_search_seconds: float = 0.75,
    audio_event_filter: bool = False,
    audio_event_model: str = DEFAULT_AUDIO_EVENT_MODEL,
    audio_event_threshold: float = 0.45,
    audio_event_filter_type: str = "repetition",
    audio_event_preset: str = "balanced",
    chunk_seconds: float = 20.0,
    max_chars_per_line: int = 18,
    beam_size: int = 3,
    min_confidence: float = 0.0,
    softmax_smoothing: float = 1.25,
    length_penalty: float = 0.6,
    eos_penalty: float = 1.0,
    decode_max_len: int = 0,
    emotion_model: str = DEFAULT_EMOTION_MODEL,
    diarize_speakers: bool = False,
    speaker_labeling_engine: str = "acoustic",
    speaker_recognition_model: str = DEFAULT_SPEAKER_RECOGNITION_MODEL,
    speaker_diarization_coreml_model: str = DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL,
    speaker_cluster_threshold: float = 0.45,
    speaker_clustering_method: str = "auto",
    diarization_model: str | None = None,
    diarization_num_speakers: int = 0,
    diarization_min_speakers: int = 0,
    diarization_max_speakers: int = 0,
    asr_context: str = "",
    align_words: bool | None = None,
    align_model: str = DEFAULT_ALIGNER_MODEL,
    punctuate: bool | None = None,
    punc_model: str = DEFAULT_PUNC_MODEL,
    denoise: bool | None = None,
    denoise_model: str = DEFAULT_DENOISE_MODEL,
    prepared_audio_path: Path | None = None,
    prepared_segments: list[Segment] | None = None,
) -> argparse.Namespace:
    model, asr_engine = clean_model_request(model, asr_engine)
    audio_event_model = str(audio_event_model or "").strip() or DEFAULT_AUDIO_EVENT_MODEL
    speaker_diarization_coreml_model = (
        str(speaker_diarization_coreml_model or "").strip()
        or DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL
    )
    return argparse.Namespace(
        input=input_path,
        output=output_path,
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        sensevoice_rich_info=sensevoice_rich_info,
        format=fmt,
        keep_audio=False,
        no_extract=False,
        chunk_seconds=chunk_seconds,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        preview_segments=False,
        max_chars_per_line=max_chars_per_line,
        max_cue_chars=0,
        max_cue_duration=0.0,
        min_cue_duration=0.8,
        beam_size=beam_size,
        mimo_max_tokens=mimo_max_tokens,
        mimo_temperature=mimo_temperature,
        mimo_top_p=mimo_top_p,
        mimo_top_k=mimo_top_k,
        min_confidence=min_confidence,
        softmax_smoothing=softmax_smoothing,
        length_penalty=length_penalty,
        eos_penalty=eos_penalty,
        decode_max_len=decode_max_len,
        emotion_model=emotion_model,
        diarize_speakers=diarize_speakers,
        speaker_labeling_engine=speaker_labeling_engine,
        speaker_recognition_model=speaker_recognition_model,
        speaker_diarization_coreml_model=speaker_diarization_coreml_model,
        speaker_cluster_threshold=speaker_cluster_threshold,
        speaker_clustering_method=speaker_clustering_method,
        diarization_model=diarization_model
        or default_diarization_model(),
        diarization_num_speakers=diarization_num_speakers,
        diarization_min_speakers=diarization_min_speakers,
        diarization_max_speakers=diarization_max_speakers,
        asr_context=str(asr_context or "").strip() or os.getenv("MSUB_ASR_CONTEXT", ""),
        align_words=env_bool("MSUB_ALIGN_WORDS", False) if align_words is None else align_words,
        align_model=str(align_model or "").strip() or DEFAULT_ALIGNER_MODEL,
        punctuate=env_bool("MSUB_PUNCTUATE", False) if punctuate is None else punctuate,
        punc_model=str(punc_model or "").strip() or DEFAULT_PUNC_MODEL,
        denoise=env_bool("MSUB_DENOISE", False) if denoise is None else denoise,
        denoise_model=str(denoise_model or "").strip() or DEFAULT_DENOISE_MODEL,
        prepared_audio_path=prepared_audio_path,
        prepared_segments=prepared_segments,
        gen_kwargs=None,
        verbose=False,
    )


def local_diarization_model_path() -> Path:
    return BASE_DIR / "models" / LOCAL_DIARIZATION_MODEL_DIRNAME


def local_speaker_recognition_model_path() -> Path:
    return BASE_DIR / "models" / "speech_eres2netv2_sv_zh-cn_16k-common"


def local_emotion_mlx_model_path() -> Path:
    return BASE_DIR / "models" / "emotion2vec-plus-large-mlx"


def local_panns_audio_event_model_path() -> Path:
    return BASE_DIR / "models" / "panns-cnn14-16k-mlx"


def local_pyannote_segmentation_mlx_model_path() -> Path:
    return BASE_DIR / "models" / "Pyannote-Segmentation-MLX"


def local_speaker_diarization_coreml_model_path() -> Path:
    return BASE_DIR / "models" / "speaker-diarization-coreml"


def is_valid_diarization_model(path: Path) -> bool:
    return path.is_dir() and (path / "config.yaml").exists()


def is_available_aux_model(path_or_id: str | Path) -> bool:
    path = Path(path_or_id)
    return path.exists() and any(path.iterdir()) if path.is_dir() else False


def is_valid_mlx_aux_model(path: Path) -> bool:
    return path.is_dir() and (
        (path / "config.json").exists()
        or (path / "emotion2vec_large_config.json").exists()
        or (path / "panns_cnn14_16k_config.json").exists()
    ) and (
        any(path.glob("*.safetensors")) or any(path.glob("*.npz"))
    )


def is_valid_speaker_diarization_coreml_model(path: Path) -> bool:
    return (
        path.is_dir()
        and (
            (
                path
                / "mlpackages"
                / "Fbank.mlpackage"
                / "Data"
                / "com.apple.CoreML"
                / "model.mlmodel"
            ).exists()
            or (path / "FBank.mlmodelc").is_dir()
        )
        and (
            (
                path
                / "mlpackages"
                / "Embedding.mlpackage"
                / "Data"
                / "com.apple.CoreML"
                / "model.mlmodel"
            ).exists()
            or (path / "Embedding.mlmodelc").is_dir()
        )
    )


def default_diarization_model() -> str:
    env_model = os.getenv("MSUB_DIARIZATION_MODEL") or os.getenv("PYANNOTE_MODEL")
    if env_model:
        return env_model
    model_dir = local_diarization_model_path()
    if is_valid_diarization_model(model_dir):
        return str(model_dir)
    return DEFAULT_DIARIZATION_MODEL_ID


def default_speaker_recognition_model() -> str:
    env_model = os.getenv("MSUB_SPEAKER_RECOGNITION_MODEL")
    if env_model:
        return env_model
    model_dir = local_speaker_recognition_model_path()
    if is_available_aux_model(model_dir):
        return str(model_dir)
    return DEFAULT_SPEAKER_RECOGNITION_MODEL_ID


def default_emotion_model() -> str:
    env_model = os.getenv("MSUB_EMOTION_MODEL")
    if env_model:
        return env_model
    mlx_model_dir = local_emotion_mlx_model_path()
    if is_valid_mlx_aux_model(mlx_model_dir):
        return str(mlx_model_dir)
    return DEFAULT_EMOTION_MODEL_ID


def default_audio_event_model() -> str:
    env_model = os.getenv("MSUB_AUDIO_EVENT_MODEL")
    if env_model:
        return env_model
    panns_model_dir = local_panns_audio_event_model_path()
    if is_valid_mlx_aux_model(panns_model_dir):
        return str(panns_model_dir)
    return DEFAULT_AUDIO_EVENT_MODEL_ID


def local_firered_model_path() -> Path:
    return BASE_DIR / "models" / "FireRedASR2-AED-mlx"


def local_sensevoice_model_path() -> Path:
    return BASE_DIR / "models" / "SenseVoiceSmall"


def local_mimo_model_path() -> Path:
    return BASE_DIR / "models" / "MiMo-V2.5-ASR-MLX-4bit"


def local_mega_model_path() -> Path:
    return BASE_DIR / "models" / "Mega-ASR-bf16"


def local_qwen3_model_path() -> Path:
    return BASE_DIR / "models" / "Qwen3-ASR-1.7B-8bit"


def local_funasr_model_path() -> Path:
    return BASE_DIR / "models" / "Fun-ASR-Nano-2512"


def local_firered_vad_model_path() -> Path:
    return BASE_DIR / "models" / "FireRedVAD-CoreML"


def is_valid_mlx_stt_model(path: Path) -> bool:
    return path.is_dir() and (path / "config.json").exists() and (
        any(path.glob("*.safetensors")) or any(path.glob("*.npz"))
    )


def default_model_for_engine(engine: str) -> str:
    if engine == "sensevoice":
        model_dir = local_sensevoice_model_path()
        return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_SENSEVOICE_MODEL
    if engine == "mimo":
        model_dir = local_mimo_model_path()
        return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_MIMO_MODEL
    if engine == "mega":
        model_dir = local_mega_model_path()
        return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_MEGA_MODEL
    if engine == "qwen3":
        model_dir = local_qwen3_model_path()
        return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_QWEN3_MODEL
    if engine == "funasr":
        model_dir = local_funasr_model_path()
        return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_FUNASR_MODEL

    model_dir = local_firered_model_path()
    return str(model_dir) if is_valid_mlx_stt_model(model_dir) else DEFAULT_MODEL


def model_catalog() -> list[dict[str, Any]]:
    firered_dir = local_firered_model_path()
    sensevoice_dir = local_sensevoice_model_path()
    mimo_dir = local_mimo_model_path()
    mega_dir = local_mega_model_path()
    qwen3_dir = local_qwen3_model_path()
    funasr_dir = local_funasr_model_path()
    firered_default = default_model_for_engine("fireredasr2")
    sensevoice_default = default_model_for_engine("sensevoice")
    mimo_default = default_model_for_engine("mimo")
    mega_default = default_model_for_engine("mega")
    qwen3_default = default_model_for_engine("qwen3")
    funasr_default = default_model_for_engine("funasr")

    def available_local_path(default: str, local_dir: Path) -> tuple[str, bool]:
        if is_valid_mlx_stt_model(local_dir):
            return str(local_dir), True
        default_path = Path(default)
        if is_valid_mlx_stt_model(default_path):
            return str(default_path), True
        return str(local_dir), False

    firered_local, firered_available = available_local_path(firered_default, firered_dir)
    sensevoice_local, sensevoice_available = available_local_path(sensevoice_default, sensevoice_dir)
    mimo_local, mimo_available = available_local_path(mimo_default, mimo_dir)
    mega_local, mega_available = available_local_path(mega_default, mega_dir)
    qwen3_local, qwen3_available = available_local_path(qwen3_default, qwen3_dir)
    qwen3_ja_dir = Path(os.environ.get("MSUB_QWEN3_JA_MODEL") or str(MODELS_DIR / QWEN3_JA_MODEL_DIR)).expanduser()

    funasr_local, funasr_available = available_local_path(funasr_default, funasr_dir)
    return [
        {
            "engine": "fireredasr2",
            "title": "FireRedASR2-AED MLX",
            "defaultModel": firered_default,
            "localModel": firered_local,
            "localModelAvailable": firered_available,
            "supports": ["beam_size", "softmax_smoothing", "length_penalty", "eos_penalty", "decode_max_len"],
        },
        {
            "engine": "mega",
            "title": "Mega-ASR BF16",
            "defaultModel": mega_default,
            "localModel": mega_local,
            "localModelAvailable": mega_available,
            "supports": ["language", "language_detection", "max_tokens", "temperature", "top_p", "top_k"],
            "defaults": {
                "max_tokens": MEGA_DEFAULT_MAX_TOKENS,
                "temperature": MEGA_DEFAULT_TEMPERATURE,
                "top_p": MEGA_DEFAULT_TOP_P,
                "top_k": MEGA_DEFAULT_TOP_K,
            },
            "notes": [
                "Mega-ASR routes each utterance internally and supports 30 language hints.",
                "FireRed AED controls do not apply to this MLX adapter.",
            ],
        },
        {
            "engine": "qwen3",
            "title": "Qwen3-ASR MLX 8bit",
            "variants": [
                {"repo": DEFAULT_QWEN3_MODEL_ID, "title": "Qwen3-ASR 1.7B · 8bit",
                 "localModel": qwen3_local, "localModelAvailable": qwen3_available},
                {"repo": QWEN3_JA_MODEL_ID, "title": "Qwen3-ASR 1.7B JA · bf16",
                 "localModel": str(qwen3_ja_dir),
                 "localModelAvailable": is_valid_mlx_stt_model(qwen3_ja_dir),
                 "language": "ja"},
            ],
            "defaultModel": qwen3_default,
            "localModel": qwen3_local,
            "localModelAvailable": qwen3_available,
            "supports": ["language", "language_detection", "max_tokens", "temperature", "top_p", "top_k", "context"],
            "defaults": {
                "max_tokens": QWEN3_DEFAULT_MAX_TOKENS,
                "temperature": QWEN3_DEFAULT_TEMPERATURE,
                "top_p": QWEN3_DEFAULT_TOP_P,
                "top_k": QWEN3_DEFAULT_TOP_K,
            },
            "notes": [
                "Official Qwen3-ASR family support with the same 30-language hint set as Mega.",
                "Uses MSub safe streaming decode and dynamic token limits.",
            ],
        },
        {
            "engine": "funasr",
            "title": "Fun-ASR Nano 2512 MLX",
            "defaultModel": funasr_default,
            "localModel": funasr_local,
            "localModelAvailable": funasr_available,
            "supports": ["language", "max_tokens", "temperature", "top_p", "top_k", "context", "use_itn"],
            "defaults": {
                "max_tokens": FUNASR_DEFAULT_MAX_TOKENS,
                "temperature": FUNASR_DEFAULT_TEMPERATURE,
                "top_p": FUNASR_DEFAULT_TOP_P,
                "top_k": FUNASR_DEFAULT_TOP_K,
            },
            "notes": [
                "MLX Nano checkpoint for Chinese, English, Japanese, and Chinese dialect media.",
                "31-language MLT-Nano currently remains a non-MLX FunASR/PyTorch/vLLM candidate.",
            ],
        },
        {
            "engine": "mimo",
            "title": "MiMo-V2.5-ASR MLX 4bit",
            "defaultModel": mimo_default,
            "localModel": mimo_local,
            "localModelAvailable": mimo_available,
            "supports": ["language", "max_tokens", "temperature", "top_p", "top_k"],
            "defaults": {
                "max_tokens": MIMO_DEFAULT_MAX_TOKENS,
                "temperature": MIMO_DEFAULT_TEMPERATURE,
                "top_p": MIMO_DEFAULT_TOP_P,
                "top_k": MIMO_DEFAULT_TOP_K,
            },
            "notes": [
                "Multi-speaker robustness is not structured speaker diarization.",
                "The current MLX adapter returns text segments without speaker_id.",
            ],
        },
        {
            "engine": "sensevoice",
            "title": "SenseVoiceSmall MLX",
            "defaultModel": sensevoice_default,
            "localModel": sensevoice_local,
            "localModelAvailable": sensevoice_available,
            "supports": [
                "language",
                "use_itn",
                "language_detection",
                "emotion",
                "audio_event",
                "rich_info_output",
            ],
        },
    ]


def vad_catalog() -> list[dict[str, Any]]:
    firered_vad_dir = local_firered_vad_model_path()
    pyannote_mlx_dir = local_pyannote_segmentation_mlx_model_path()
    return [
        {
            "engine": "pyannote_mlx",
            "title": "Pyannote Segmentation 3.0 MLX",
            "defaultModel": DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL,
            "localModel": str(pyannote_mlx_dir),
            "localModelAvailable": pyannote_segmentation_mlx_available(
                DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL
            ),
            "supports": ["threshold", "min_speech", "min_silence"],
        },
        {
            "engine": "firered",
            "title": "FireRedVAD CoreML",
            "defaultModel": DEFAULT_FIRERED_VAD_MODEL,
            "localModel": str(firered_vad_dir),
            "localModelAvailable": firered_vad_coreml_files_available(
                DEFAULT_FIRERED_VAD_MODEL
            ),
            "supports": ["threshold", "smooth_window", "min_speech", "min_silence"],
        },
        {
            "engine": "energy",
            "title": "Energy VAD",
            "localModelAvailable": True,
            "supports": ["threshold_db"],
        },
    ]


def default_vad_engine() -> str:
    if pyannote_segmentation_mlx_available(DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL):
        return "pyannote_mlx"
    if firered_vad_coreml_files_available(DEFAULT_FIRERED_VAD_MODEL):
        return "firered"
    return "energy"


def _client_is_loopback(request: Request) -> bool:
    client = request.client
    return client is not None and client.host in {"127.0.0.1", "::1", "localhost"}


async def resolve_job_input(
    request: Request,
    file: UploadFile | None,
    input_path: str,
    work_dir: Path,
) -> Path:
    """Resolve the media source for a job.

    Local clients may pass `input_path` to skip the multipart upload entirely
    (zero-copy). When the path is missing or unreadable — e.g. the sandboxed
    backend cannot see it — respond 409 so the client falls back to uploading.
    """
    direct = str(input_path or "").strip()
    if direct:
        if not _client_is_loopback(request):
            raise HTTPException(
                status_code=403, detail="input_path is only allowed from localhost."
            )
        candidate = Path(direct).expanduser()
        if not candidate.is_file() or not os.access(candidate, os.R_OK):
            raise HTTPException(
                status_code=409,
                detail="input_path is not readable by the backend; upload the file instead.",
            )
        return candidate
    if file is None:
        raise HTTPException(status_code=400, detail="No media file provided.")
    return await save_upload(file, work_dir)


async def save_upload(upload: UploadFile, target_dir: Path) -> Path:
    if not upload.filename:
        raise HTTPException(status_code=400, detail="Missing upload filename.")
    suffix = Path(upload.filename).suffix or ".media"
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / f"input{suffix}"
    with open(target, "wb") as f:
        shutil.copyfileobj(upload.file, f)
    return target


def reusable_preview_key(**values: Any) -> str:
    payload = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def preview_key_for_request(
    *,
    model: str,
    asr_engine: str,
    language: str,
    use_itn: bool,
    segment_mode: str,
    vad_engine: str,
    vad_threshold_db: float,
    firered_vad_model: str,
    firered_vad_threshold: float,
    firered_vad_smooth_window: int,
    pyannote_vad_model: str,
    pyannote_vad_threshold: float,
    vad_min_speech_seconds: float,
    vad_min_silence_seconds: float,
    vad_padding_seconds: float,
    vad_max_segment_seconds: float,
    vad_min_segment_seconds: float,
    vad_split_search_seconds: float,
    audio_event_filter: bool,
    audio_event_model: str,
    audio_event_threshold: float,
    audio_event_filter_type: str,
    audio_event_preset: str,
    chunk_seconds: float,
) -> str:
    model, asr_engine = clean_model_request(model, asr_engine)
    return reusable_preview_key(
        model=model,
        asr_engine=asr_engine,
        # Recognition language and inverse text normalization affect decoding,
        # not the prepared PCM, VAD boundaries, or audio-event labels.
        stage_schema=2,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=float(vad_threshold_db),
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=float(firered_vad_threshold),
        firered_vad_smooth_window=int(firered_vad_smooth_window),
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=float(pyannote_vad_threshold),
        vad_min_speech_seconds=float(vad_min_speech_seconds),
        vad_min_silence_seconds=float(vad_min_silence_seconds),
        vad_padding_seconds=float(vad_padding_seconds),
        vad_max_segment_seconds=float(vad_max_segment_seconds),
        vad_min_segment_seconds=float(vad_min_segment_seconds),
        vad_split_search_seconds=float(vad_split_search_seconds),
        audio_event_filter=bool(audio_event_filter),
        audio_event_model=str(audio_event_model or "").strip(),
        audio_event_threshold=float(audio_event_threshold),
        audio_event_filter_type=str(audio_event_filter_type or "repetition").strip().lower().replace("-", "_"),
        audio_event_preset=str(audio_event_preset or "balanced").strip().lower().replace("-", "_"),
        chunk_seconds=float(chunk_seconds),
        audio_extraction="audio-sync-v2",
        audio_sync_filter=audio_timeline_sync_filter() or "off",
    )


def preview_plan_path(preview_id: str) -> Path | None:
    if not preview_id or not re.fullmatch(r"[0-9a-fA-F]{32}", preview_id):
        return None
    return JOB_DIR / preview_id / "preview_plan.json"


def write_preview_plan(
    preview_id: str,
    *,
    input_path: Path,
    audio_path: Path,
    duration: float,
    media_info: dict[str, Any],
    settings_key: str,
    segments: list[Segment],
) -> None:
    plan_path = preview_plan_path(preview_id)
    if plan_path is None:
        return
    payload = {
        "id": preview_id,
        "inputPath": str(input_path),
        "audioPath": str(audio_path),
        "duration": round(duration, 3),
        "mediaInfo": media_info,
        "settingsKey": settings_key,
        "segments": [asdict(segment) for segment in segments],
        "createdAt": time.time(),
    }
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def load_preview_plan(preview_id: str, settings_key: str) -> dict[str, Any] | None:
    plan_path = preview_plan_path(preview_id)
    if plan_path is None or not plan_path.exists():
        return None
    try:
        payload = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if payload.get("settingsKey") != settings_key:
        return None
    audio_path = Path(str(payload.get("audioPath") or ""))
    input_path = Path(str(payload.get("inputPath") or ""))
    if not audio_path.exists() or not input_path.exists():
        return None
    return payload


def native_segments_from_pcm(audio_path: Path, payload: str) -> list[Segment]:
    """Validate native ranges against the actual PCM; never silently drop bad rows."""
    try:
        if len(payload) > 2_000_000:
            raise ValueError("Segment plan is too large")
        rows = json.loads(payload)
        if not isinstance(rows, list) or len(rows) > 100_000:
            raise ValueError("Expected a segment list")
        with wave.open(str(audio_path), "rb") as audio:
            if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth(), audio.getcomptype()) != (16000, 1, 2, "NONE"):
                raise ValueError("Expected 16 kHz mono PCM16 WAV")
            frames = audio.getnframes()
            if frames:
                audio.setpos(frames - 1)
                if len(audio.readframes(1)) != 2:
                    raise ValueError("Truncated PCM audio")
            duration = frames / 16000
        segments = []
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError("Invalid segment")
            start, end = row.get("start"), row.get("end")
            if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value)
                   for value in (start, end)):
                raise ValueError("Segment times must be finite numbers")
            if not (0 <= start < min(end, duration) and end <= duration + 1 / 16000):
                raise ValueError("Segment lies outside the audio")
            if segments and start < segments[-1].start:
                raise ValueError("Segments must be ordered by start time")
            segments.append(Segment(index=len(segments) + 1, start=start, end=min(end, duration),
                                    flagged=bool(row.get("flagged", False))))
        return segments
    except (ValueError, TypeError, OverflowError, OSError, EOFError, wave.Error) as error:
        raise HTTPException(status_code=400, detail=f"Invalid native segment plan: {error}") from error


def segments_from_preview_plan(payload: dict[str, Any]) -> list[Segment]:
    segments: list[Segment] = []
    for item in payload.get("segments") or []:
        try:
            segments.append(
                Segment(
                    index=int(item.get("index", len(segments) + 1)),
                    start=float(item["start"]),
                    end=float(item["end"]),
                    speaker=item.get("speaker"),
                    audio_label=item.get("audio_label"),
                    audio_score=(
                        float(item["audio_score"])
                        if item.get("audio_score") is not None
                        else None
                    ),
                    audio_labels=parse_audio_labels(item.get("audio_labels")),
                    speech_score=(
                        float(item["speech_score"])
                        if item.get("speech_score") is not None
                        else None
                    ),
                    repetition_score=(
                        float(item["repetition_score"])
                        if item.get("repetition_score") is not None
                        else None
                    ),
                    flagged=bool(item.get("flagged", False)),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return segments


def parse_audio_labels(value: Any) -> list[dict[str, object]] | None:
    if not isinstance(value, list):
        return None
    labels: list[dict[str, object]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        label = str(item.get("label") or "").strip()
        if not label:
            continue
        score = None
        if item.get("score") is not None:
            try:
                score = round(float(item["score"]), 4)
            except (TypeError, ValueError):
                score = None
        labels.append({"label": label, "score": score})
    return labels or None


def segment_payload(segment: Segment, *, include_duration: bool = True) -> dict[str, Any]:
    payload = asdict(segment)
    if include_duration:
        payload["duration"] = round(segment.duration, 3)
    return payload


def preview_result_payload(
    preview_id: str,
    *,
    settings_key: str,
    duration: float,
    media_info: dict[str, Any],
    segments: list[Segment],
) -> dict[str, Any]:
    return {
        "id": preview_id,
        "previewId": preview_id,
        "settingsKey": settings_key,
        "duration": round(duration, 3),
        "count": len(segments),
        "mediaInfo": media_info,
        "segments": [segment_payload(segment) for segment in segments],
    }


def preview_control_checkpoint(job_id: str | None) -> None:
    if not job_id:
        return
    wait_if_paused(job_id)
    if cancel_requested(job_id):
        raise JobCancelled("Job cancelled.")


def update_preview_progress(
    job_id: str | None,
    current: float,
    text: str,
    *,
    total: int = 100,
) -> None:
    if not job_id:
        return
    preview_control_checkpoint(job_id)
    update_job(
        job_id,
        status="running",
        current=int(max(0, min(current, total))),
        fractionalCurrent=max(0, min(current, total)),
        total=total,
        progressText=text,
    )
    append_job_log(job_id, text)


def preview_audio_event_callback(job_id: str | None):
    if not job_id:
        return None

    def callback(event: dict) -> None:
        preview_control_checkpoint(job_id)
        name = event.get("event")
        current = 78
        text = "Marking audio events"
        if name == "audio_event_model_loading":
            current = 72
            text = "Loading audio event model"
        elif name == "audio_event_model_loaded":
            current = 76
            text = "Audio event model loaded"
        elif name == "audio_event_segments":
            done = max(0, int(event.get("current") or 0))
            total = max(1, int(event.get("total") or 1))
            current = 78 + int(17 * min(done, total) / total)
            text = f"Marking audio events {done} / {total}"
        update_job(
            job_id,
            status="running",
            current=max(0, min(current, 100)),
            fractionalCurrent=max(0, min(current, 100)),
            total=100,
            progressText=text,
        )
        append_job_log(job_id, json.dumps(event, ensure_ascii=False))

    return callback


def build_preview_payload(
    preview_id: str,
    *,
    input_path: Path,
    wav_path: Path,
    settings_key: str,
    args: argparse.Namespace,
    job_id: str | None = None,
) -> dict[str, Any]:
    phase_started = time.perf_counter()
    phase_timings = {}

    def finish_phase(name: str) -> None:
        nonlocal phase_started
        now = time.perf_counter()
        phase_timings[name] = round(now - phase_started, 3)
        phase_started = now
        if job_id:
            update_job(job_id, phaseTimings=dict(phase_timings))
            append_job_log(job_id, f"preview_phase={name} seconds={phase_timings[name]}")

    record_diagnostic_event(job_id, {"event": "audio_extract_start"})
    # Extraction can reuse PCM or finish almost instantly. Reserve most of the
    # preview bar for inference, with a separate allowance for optional events.
    vad_end = 68 if getattr(args, "audio_event_filter", False) else 95
    update_preview_progress(job_id, 2, "Reading media metadata")
    media_info = probe_media_info(input_path)

    update_preview_progress(job_id, 3, "Extracting audio")
    last_audio_progress = 0.0
    last_audio_progress_report = 0.0

    def audio_progress_callback(fraction: float) -> None:
        nonlocal last_audio_progress, last_audio_progress_report
        preview_control_checkpoint(job_id)
        if not job_id:
            return
        fraction = min(max(float(fraction), 0.0), 1.0)
        now = time.time()
        if fraction < 1.0 and (
            fraction - last_audio_progress < 0.025
            and now - last_audio_progress_report < 0.75
        ):
            return
        last_audio_progress = fraction
        last_audio_progress_report = now
        current = 3 + 5 * fraction
        update_preview_progress(
            job_id,
            current,
            f"Extracting audio {int(fraction * 100)}%",
        )

    extract_audio(
        input_path,
        wav_path,
        progress_callback=audio_progress_callback if job_id else None,
        duration=media_info.get("duration"),
    )

    update_preview_progress(job_id, 8, "Measuring audio duration")
    duration = probe_duration(wav_path)

    record_diagnostic_event(job_id, {"event": "audio_extract_done"})
    finish_phase("audioPreparation")
    update_preview_progress(job_id, 10, "Detecting speech segments")
    record_diagnostic_event(job_id, {"event": "vad_start"})
    last_vad_progress = -1.0
    last_vad_progress_report = 0.0

    def vad_progress_callback(event: dict) -> None:
        nonlocal last_vad_progress, last_vad_progress_report
        preview_control_checkpoint(job_id)
        if not job_id:
            return
        name = event.get("event")
        if name in {"vad_backend", "vad_window_timing"}:
            append_job_log(job_id, json.dumps(event, ensure_ascii=False))
            return
        if name == "vad_start":
            engine = str(event.get("engine") or "vad").replace("_", " ")
            append_job_log(job_id, json.dumps({
                "event": "vad_runtime", "engine": event.get("engine"),
                "duration": duration,
                "pyannoteBackend": os.getenv("MSUB_PYANNOTE_MLX_BACKEND", "numpy"),
                "pyannoteStepRatio": os.getenv("MSUB_PYANNOTE_MLX_STEP_RATIO", "0.5"),
                "coremlComputeUnits": os.getenv("MSUB_COREML_COMPUTE_UNITS", "cpu_and_neural_engine"),
                "coremlBatchFrames": os.getenv("MSUB_FIRERED_VAD_COREML_BATCH_FRAMES", "512"),
            }, ensure_ascii=False))
            update_preview_progress(job_id, 10, f"Detecting speech with {engine}")
            return
        if name == "vad_done":
            update_preview_progress(
                job_id,
                vad_end,
                f"Detected {int(event.get('total') or 0)} segments",
            )
            return
        if name != "vad_progress":
            return
        try:
            total = max(1, int(event.get("total") or 1))
            current = max(0, int(event.get("current") or 0))
            fraction = float(event.get("fraction", current / total) or 0.0)
        except (TypeError, ValueError):
            fraction = 0.0
        fraction = min(max(fraction, 0.0), 1.0)
        now = time.time()
        if fraction < 1.0 and (
            fraction - last_vad_progress < 0.025
            and now - last_vad_progress_report < 0.75
        ):
            return
        last_vad_progress = fraction
        last_vad_progress_report = now
        update_preview_progress(
            job_id,
            10 + (vad_end - 10) * fraction,
            f"Detecting speech {int(fraction * 100)}%",
        )

    segments = build_segments(
        wav_path,
        duration,
        args,
        progress_callback=vad_progress_callback if job_id else None,
    )
    record_diagnostic_event(job_id, {"event": "vad_done"})
    record_diagnostic_event(job_id, {"event": "postprocessing_start"})
    finish_phase("vad")
    update_preview_progress(job_id, vad_end, f"Detected {len(segments)} segments")

    if getattr(args, "audio_event_filter", False):
        segments = mark_non_lexical_segments(
            wav_path,
            segments,
            args,
            preview_audio_event_callback(job_id),
        )
    else:
        segments = mark_non_lexical_segments(wav_path, segments, args)

    record_diagnostic_event(job_id, {"event": "postprocessing_done"})
    record_diagnostic_event(job_id, {"event": "output_start"})
    finish_phase("audioEvents")
    update_preview_progress(job_id, 96, "Writing preview plan")
    write_preview_plan(
        preview_id,
        input_path=input_path,
        audio_path=wav_path,
        duration=duration,
        media_info=media_info,
        settings_key=settings_key,
        segments=segments,
    )
    record_diagnostic_event(job_id, {"event": "output_written"})
    clear_aux_model_caches()
    return preview_result_payload(
        preview_id,
        settings_key=settings_key,
        duration=duration,
        media_info=media_info,
        segments=segments,
    )


def updated_segments_from_request(items: Any, time_offset: float = 0.0) -> list[Segment]:
    if not isinstance(items, list):
        raise ValueError("segments must be a list.")
    segments: list[Segment] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        try:
            start = max(0.0, float(item["start"]) - time_offset)
            end = max(start, float(item["end"]) - time_offset)
            if end - start <= 0.01:
                continue
            segments.append(
                Segment(
                    index=len(segments) + 1,
                    start=round(start, 3),
                    end=round(end, 3),
                    speaker=item.get("speaker"),
                    audio_label=item.get("audio_label"),
                    audio_score=(
                        float(item["audio_score"])
                        if item.get("audio_score") is not None
                        else None
                    ),
                    audio_labels=parse_audio_labels(item.get("audio_labels")),
                    speech_score=(
                        float(item["speech_score"])
                        if item.get("speech_score") is not None
                        else None
                    ),
                    repetition_score=(
                        float(item["repetition_score"])
                        if item.get("repetition_score") is not None
                        else None
                    ),
                    flagged=bool(item.get("flagged", False)),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return segments


def cleanup_jobs(max_age_seconds: int = JOB_TTL_SECONDS) -> None:
    if not JOB_DIR.exists():
        return

    now = time.time()
    stale_dirs: list[Path] = []
    with jobs_lock:
        active_dirs = {
            Path(job["workDir"])
            for job in jobs.values()
            if job.get("status") not in TERMINAL_STATUSES and job.get("workDir")
        }
        stale_ids = [
            job_id
            for job_id, job in jobs.items()
            if job.get("status") in TERMINAL_STATUSES
            and now - float(job.get("updatedAt", 0)) > max_age_seconds
        ]
        for job_id in stale_ids:
            job = jobs.pop(job_id, None)
            job_progress_persisted_at.pop(job_id, None)
            if job and job.get("workDir"):
                stale_dirs.append(Path(job["workDir"]))

    for child in JOB_DIR.iterdir():
        if not child.is_dir() or child in active_dirs:
            continue
        try:
            age = now - child.stat().st_mtime
        except OSError:
            continue
        if age > max_age_seconds or child in stale_dirs:
            shutil.rmtree(child, ignore_errors=True)


def cleanup_job_files_for_shutdown() -> None:
    if not JOB_DIR.exists():
        return
    for child in JOB_DIR.iterdir():
        if child.is_dir():
            shutil.rmtree(child, ignore_errors=True)


def cancel_requested(job_id: str) -> bool:
    with jobs_lock:
        job = jobs.get(job_id)
        return bool(job and job.get("cancelRequested"))


def pause_event_for(job_id: str) -> threading.Event:
    with jobs_lock:
        event = job_pause_events.get(job_id)
        if event is None:
            event = threading.Event()
            event.set()
            job_pause_events[job_id] = event
        return event


def wait_if_paused(job_id: str) -> None:
    was_paused = False
    while True:
        with jobs_lock:
            job = jobs.get(job_id)
            if not job:
                raise JobCancelled("Job removed.")
            if job.get("cancelRequested"):
                raise JobCancelled("Job cancelled.")
            paused = bool(job.get("pauseRequested"))
            if trace := job_diagnostics.get(job_id):
                trace.pause(paused)
                job["diagnostics"] = trace.snapshot()
            last_progress_text = job.get("lastProgressText") or job.get("progressText")
            event = job_pause_events.get(job_id)
            if event is None:
                event = threading.Event()
                event.set()
                job_pause_events[job_id] = event
            if paused and job.get("status") != "paused":
                job["status"] = "paused"
                job["lastProgressText"] = last_progress_text
                job["progressText"] = "Paused"
                job["updatedAt"] = time.time()
                snapshot = dict(job)
            else:
                snapshot = None

        if snapshot is not None:
            persist_job_status(snapshot)
            append_job_log(job_id, "Job paused")
            was_paused = True

        if not paused:
            if was_paused:
                append_job_log(job_id, "Job resumed")
            return

        event.wait(timeout=0.5)


def parse_ratio(value: str | None) -> float | None:
    if not value or value == "0/0":
        return None
    if "/" in value:
        numerator, denominator = value.split("/", 1)
        try:
            denominator_float = float(denominator)
            if denominator_float == 0:
                return None
            return round(float(numerator) / denominator_float, 3)
        except ValueError:
            return None
    try:
        return round(float(value), 3)
    except ValueError:
        return None


def parse_optional_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def parse_optional_int(value: Any) -> int | None:
    try:
        parsed = int(float(value))
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def first_stream(streams: list[dict[str, Any]], codec_type: str) -> dict[str, Any]:
    for stream in streams:
        if stream.get("codec_type") == codec_type:
            return stream
    return {}


def probe_media_info(path: Path) -> dict[str, Any]:
    try:
        ffprobe = require_ffprobe()
    except RuntimeError:
        return basic_media_info(path)

    command = [
        ffprobe,
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        str(path),
    ]
    try:
        result = tracked_subprocess_run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout or "{}")
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError):
        return basic_media_info(path)
    format_info = payload.get("format") or {}
    streams = payload.get("streams") or []
    video = first_stream(streams, "video")
    audio = first_stream(streams, "audio")

    duration = (
        parse_optional_float(format_info.get("duration"))
        or parse_optional_float(video.get("duration"))
        or parse_optional_float(audio.get("duration"))
    )
    format_name = format_info.get("format_long_name") or format_info.get("format_name")

    return {
        "duration": duration,
        "formatName": format_name,
        "bitRate": parse_optional_int(format_info.get("bit_rate")),
        "videoCodec": video.get("codec_long_name") or video.get("codec_name"),
        "width": parse_optional_int(video.get("width")),
        "height": parse_optional_int(video.get("height")),
        "frameRate": parse_ratio(video.get("avg_frame_rate") or video.get("r_frame_rate")),
        "videoBitRate": parse_optional_int(video.get("bit_rate")),
        "audioCodec": audio.get("codec_long_name") or audio.get("codec_name"),
        "sampleRate": parse_optional_int(audio.get("sample_rate")),
        "channels": parse_optional_int(audio.get("channels")),
        "audioBitRate": parse_optional_int(audio.get("bit_rate")),
    }


def basic_media_info(path: Path) -> dict[str, Any]:
    try:
        duration = probe_duration(path)
    except Exception:  # noqa: BLE001 - media metadata is optional for preview.
        duration = None
    return {
        "duration": duration,
        "formatName": None,
        "bitRate": None,
        "videoCodec": None,
        "width": None,
        "height": None,
        "frameRate": None,
        "videoBitRate": None,
        "audioCodec": None,
        "sampleRate": None,
        "channels": None,
        "audioBitRate": None,
    }


def update_job(job_id: str, **values: Any) -> None:
    snapshot: dict[str, Any] | None = None
    with jobs_lock:
        job = jobs[job_id]
        status = values.get("status")
        if status in TERMINAL_STATUSES:
            job_progress_persisted_at.pop(job_id, None)
        if status == "waiting" and job_id not in job_diagnostics:
            job_diagnostics[job_id] = JobDiagnostics()
        trace = job_diagnostics.get(job_id)
        if trace:
            if status == "running":
                trace.running()
            if status in TERMINAL_STATUSES:
                job["diagnostics"] = trace.finish()
                job_diagnostics.pop(job_id, None)
            else:
                job["diagnostics"] = trace.snapshot()
        job.update(values)
        job["updatedAt"] = time.time()
        snapshot = dict(job)
    persist_job_status(snapshot)
    if values.get("status") in TERMINAL_STATUSES and snapshot.get("diagnostics"):
        append_job_log(job_id, json.dumps({"event": "job_diagnostics", **snapshot["diagnostics"]}))


def record_diagnostic_event(job_id: str | None, event: dict) -> None:
    if not job_id:
        return
    with jobs_lock:
        if trace := job_diagnostics.get(job_id):
            trace.event(event)
            jobs[job_id]["diagnostics"] = trace.snapshot()


def persist_job_status(job: dict[str, Any] | None) -> None:
    if not job:
        return
    work_dir = job.get("workDir")
    if not work_dir:
        return
    try:
        path = Path(work_dir) / "status.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(job, ensure_ascii=False, indent=2), encoding="utf-8")
    except OSError:
        pass


def append_job_log(job_id: str, message: str) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
        log_path = job.get("logPath") if job else None
    if not log_path:
        return
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        path = Path(log_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(f"[{timestamp}] {message.rstrip()}\n")
    except OSError:
        pass


def append_event(job_id: str, event: dict) -> None:
    wait_if_paused(job_id)
    snapshot: dict[str, Any] | None = None
    with jobs_lock:
        job = jobs[job_id]
        if job.get("cancelRequested"):
            raise JobCancelled("Job cancelled.")
        if trace := job_diagnostics.get(job_id):
            trace.event(event)
            job["diagnostics"] = trace.snapshot()
        events = job.setdefault("events", [])
        if MAX_JOB_EVENTS > 0:
            events.append(event)
            if len(events) > MAX_JOB_EVENTS:
                del events[: len(events) - MAX_JOB_EVENTS]
        else:
            events.clear()
        job["updatedAt"] = time.time()
        if event.get("event") == "audio_extract_start":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.01)
            job["progressText"] = "Extracting audio"
        elif event.get("event") == "audio_extract_progress":
            try:
                fraction = float(event.get("fraction") or 0.0)
            except (TypeError, ValueError):
                fraction = 0.0
            fraction = min(max(fraction, 0.0), 1.0)
            job["phaseProgress"] = max(
                float(job.get("phaseProgress", 0.0) or 0.0),
                min(0.04, 0.01 + fraction * 0.03),
            )
            job["progressText"] = f"Extracting audio {int(fraction * 100)}%"
        elif event.get("event") == "audio_extract_done":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.04)
            job["progressText"] = "Audio ready"
        elif event.get("event") == "vad_start":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.04)
            engine = str(event.get("engine") or "vad").replace("_", " ")
            job["progressText"] = f"Detecting speech with {engine}"
        elif event.get("event") == "vad_progress":
            try:
                total = max(1, int(event.get("total") or 1))
                current = max(0, int(event.get("current") or 0))
                fraction = float(event.get("fraction", current / total) or 0.0)
            except (TypeError, ValueError):
                fraction = 0.0
            fraction = min(max(fraction, 0.0), 1.0)
            job["phaseProgress"] = max(
                float(job.get("phaseProgress", 0.0) or 0.0),
                min(0.18, 0.04 + fraction * 0.14),
            )
            job["progressText"] = f"Detecting speech {int(fraction * 100)}%"
        elif event.get("event") == "vad_done":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.18)
            job["progressText"] = f"Detected {event.get('total', 0)} segments"
        elif event.get("event") == "segments":
            job["current"] = 0
            job["total"] = event.get("total", 0)
            job["fractionalCurrent"] = 0.0
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.18)
            job["progressText"] = f"Detected {event.get('total', 0)} segments"
        elif event.get("event") == "chunk_start":
            index = max(1, int(event.get("index", 1) or 1))
            job["current"] = index - 1
            job["total"] = event.get("total", job.get("total", 0))
            job["fractionalCurrent"] = float(index - 1)
            job["progressText"] = (
                f"Transcribing {index} / {job.get('total', 0)}"
            )
        elif event.get("event") == "chunk_progress":
            fractional = float(
                event.get(
                    "fractionalCurrent",
                    job.get("fractionalCurrent", 0.0),
                )
                or 0.0
            )
            job["fractionalCurrent"] = fractional
            job["current"] = int(max(0.0, fractional))
            job["total"] = event.get("total", job.get("total", 0))
            job["progressText"] = (
                f"Transcribing {event.get('index', job.get('current', 0))} / "
                f"{job.get('total', 0)}"
            )
        elif event.get("event") == "chunk_retry":
            job["progressText"] = (
                f"Retrying segment {event.get('index', 0)} / "
                f"{event.get('total', job.get('total', 0))}"
            )
        elif event.get("event") == "chunk_done":
            job["current"] = event.get("index", job.get("current", 0))
            job["total"] = event.get("total", job.get("total", 0))
            job["fractionalCurrent"] = float(job["current"])
            job["progressText"] = (
                f"Transcribed {job['current']} / {job.get('total', 0)}"
            )
            # Live transcript: append finished chunk text so clients can show
            # results while the job runs. Replaced by the authoritative output
            # when the job completes.
            text = str(event.get("text") or "").strip()
            if text and not event.get("skipped"):
                speaker = str(event.get("speaker") or "").strip()
                line = f"{speaker}: {text}" if speaker else text
                existing = str(job.get("preview") or "")
                combined = f"{existing}\n{line}" if existing else line
                job["preview"] = combined[-12000:]
        elif event.get("event") == "no_speech":
            job["progressText"] = "No speech detected"
        elif event.get("event") == "model_loading":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.18)
            job["progressText"] = "Loading model"
        elif event.get("event") == "model_loaded":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.24)
            job["progressText"] = "Model loaded"
        elif event.get("event") == "rich_model_loading":
            job["progressText"] = "Loading emotion model"
        elif event.get("event") == "rich_model_loaded":
            job["progressText"] = "Emotion model loaded"
        elif event.get("event") == "rich_model_unavailable":
            job["progressText"] = "Emotion model unavailable; continuing"
        elif event.get("event") == "speaker_labeling_fallback":
            job["progressText"] = "Using torch-free speaker labeling"
        elif event.get("event") == "audio_event_model_loading":
            job["progressText"] = "Loading audio event model"
        elif event.get("event") == "audio_event_model_loaded":
            job["progressText"] = "Audio event model loaded"
        elif event.get("event") == "audio_event_segments":
            job["progressText"] = (
                f"Marking audio events {event.get('current', 0)} / "
                f"{event.get('total', job.get('total', 0))}"
            )
        elif event.get("event") == "rich_metadata_start":
            job["progressText"] = (
                f"Detecting emotion {event.get('index', 0)} / "
                f"{event.get('total', job.get('total', 0))}"
            )
        elif event.get("event") == "speaker_recognition_start":
            job["speakerCurrent"] = 0
            job["speakerTotal"] = event.get("total", 0)
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.03)
            job["progressText"] = "Identifying speakers"
        elif event.get("event") == "speaker_recognition_segment":
            speaker_total = max(int(event.get("total", job.get("speakerTotal", 0)) or 0), 0)
            speaker_current = max(int(event.get("index", job.get("speakerCurrent", 0)) or 0), 0)
            job["speakerCurrent"] = speaker_current
            job["speakerTotal"] = speaker_total
            if speaker_total > 0:
                speaker_fraction = min(max(speaker_current / speaker_total, 0.0), 1.0)
                job["phaseProgress"] = max(
                    float(job.get("phaseProgress", 0.0) or 0.0),
                    min(0.16, 0.03 + speaker_fraction * 0.13),
                )
            job["progressText"] = (
                f"Identifying speaker {event.get('index', 0)} / "
                f"{event.get('total', job.get('total', 0))}"
            )
        elif event.get("event") == "diarization_start":
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.03)
            job["progressText"] = "Assigning speakers"
        elif event.get("event") == "diarization_done":
            job["speakerCount"] = event.get("speakerCount", 0)
            job["phaseProgress"] = max(float(job.get("phaseProgress", 0.0) or 0.0), 0.17)
            job["progressText"] = f"Assigned {job['speakerCount']} speakers"
        elif event.get("event") == "output_written":
            job["cueCount"] = event.get("cueCount", 0)
            job["output"] = event.get("output")
        if job.get("status") == "paused":
            job["status"] = "running"
        job["lastProgressText"] = job.get("progressText")
        # Keep live state and cancellation checks at every callback, but avoid
        # synchronous JSON/disk writes on the GPU producer for each progress tick.
        now = time.monotonic()
        previous = job_progress_persisted_at.get(job_id)
        if event.get("event") != "chunk_progress" or previous is None or now - previous >= 0.25:
            snapshot = dict(job)
            job_progress_persisted_at[job_id] = now
    if snapshot is not None:
        persist_job_status(snapshot)
    if LOG_PROGRESS_EVENTS or event.get("event") != "chunk_progress":
        append_job_log(job_id, json.dumps(event, ensure_ascii=False))


def other_jobs_pending(current_job_id: str) -> bool:
    with jobs_lock:
        return any(
            other_id != current_job_id and job.get("status") in {"queued", "waiting"}
            for other_id, job in jobs.items()
        )


@contextlib.contextmanager
def model_job_slot(job_id: str):
    """Cancelled queued jobs must not wait behind a long ASR decode.

    Previews use MLX auxiliary models too, so they participate in the same
    idle-cache lifecycle as transcription jobs.
    """
    acquired = False
    active = False
    try:
        while not acquired:
            if shutdown_event.is_set() or cancel_requested(job_id):
                raise JobCancelled("Job cancelled.")
            acquired = job_semaphore.acquire(timeout=0.1)
        if shutdown_event.is_set() or cancel_requested(job_id):
            raise JobCancelled("Job cancelled.")
        mark_model_job_started()
        active = True
        yield
    finally:
        if active:
            mark_model_job_finished()
        if acquired:
            job_semaphore.release()
        if active:
            unload_idle_model_if_needed()


def run_job(job_id: str, args: argparse.Namespace) -> None:
    update_job(job_id, status="waiting", progressText="Waiting for backend")
    # Keep models warm while more jobs are queued; the idle reaper reclaims
    # memory once the queue drains (MODEL_IDLE_SECONDS).
    args.keep_aux_models = lambda: other_jobs_pending(job_id)
    try:
        with model_job_slot(job_id):
            update_job(job_id, status="running", progressText="Preparing audio")
            append_job_log(job_id, f"input={args.input}")
            append_job_log(job_id, f"output={args.output}")
            append_job_log(job_id, f"model={args.model}")
            if cancel_requested(job_id):
                raise JobCancelled("Job cancelled.")
            wait_if_paused(job_id)
            with subprocess_tracking_context(job_id):
                output_path = run(args, progress_callback=lambda event: append_event(job_id, event))
            preview = ""
            if output_path and output_path.exists():
                preview = output_path.read_text(encoding="utf-8")[:12000]
            update_job(
                job_id,
                status="done",
                progressText="Done",
                output=str(output_path) if output_path else None,
                preview=preview,
            )
    except JobCancelled:
        update_job(job_id, status="cancelled", error=None, progressText="Cancelled")
    except Exception as exc:  # noqa: BLE001 - surface job errors in the UI.
        trace = traceback.format_exc()
        append_job_log(job_id, trace)
        update_job(
            job_id,
            status="error",
            error=str(exc),
            errorTrace=trace,
            progressText="Error",
        )
    finally:
        with jobs_lock:
            job_pause_events.pop(job_id, None)


def run_preview_job(
    job_id: str,
    input_path: Path,
    wav_path: Path,
    args: argparse.Namespace,
    settings_key: str,
) -> None:
    update_job(
        job_id,
        status="waiting",
        current=0,
        total=100,
        progressText="Waiting for backend",
    )
    try:
        with model_job_slot(job_id):
            update_preview_progress(job_id, 1, "Preparing segment preview")
            append_job_log(job_id, f"preview_input={input_path}")
            with subprocess_tracking_context(job_id):
                payload = build_preview_payload(
                    job_id,
                    input_path=input_path,
                    wav_path=wav_path,
                    settings_key=settings_key,
                    args=args,
                    job_id=job_id,
                )
            update_job(
                job_id,
                status="done",
                current=100,
                total=100,
                progressText="Segment preview ready",
                fractionalCurrent=100,
                **payload,
            )
    except JobCancelled:
        update_job(
            job_id,
            status="cancelled",
            error=None,
            progressText="Cancelled",
        )
    except Exception as exc:  # noqa: BLE001 - surface preview errors in the UI.
        trace = traceback.format_exc()
        append_job_log(job_id, trace)
        update_job(
            job_id,
            status="error",
            error=str(exc),
            errorTrace=trace,
            progressText="Error",
        )
    finally:
        with jobs_lock:
            job_pause_events.pop(job_id, None)


@app.get("/api/config")
def config() -> dict:
    diarization_model = default_diarization_model()
    speaker_recognition_model = default_speaker_recognition_model()
    emotion_model = default_emotion_model()
    audio_event_model = default_audio_event_model()
    emotion_mlx_model = local_emotion_mlx_model_path()
    panns_audio_event_model = local_panns_audio_event_model_path()
    pyannote_segmentation_mlx_model = local_pyannote_segmentation_mlx_model_path()
    speaker_diarization_coreml_model = local_speaker_diarization_coreml_model_path()
    return {
        "supportsNativeSegments": True,
        "defaultModel": default_model_for_engine("fireredasr2"),
        "defaultASREngine": "fireredasr2",
        "models": model_catalog(),
        "defaultVADEngine": default_vad_engine(),
        "vadEngines": vad_catalog(),
        "defaultDiarizationModel": diarization_model,
        "localDiarizationModel": str(local_diarization_model_path()),
        "diarizationModelAvailable": is_valid_diarization_model(Path(diarization_model)),
        "defaultSpeakerLabelingEngine": os.getenv("MSUB_SPEAKER_LABELING_ENGINE", "acoustic"),
        "defaultSpeakerClusteringMethod": DEFAULT_SPEAKER_CLUSTERING_METHOD,
        "defaultSpeakerRecognitionModel": speaker_recognition_model,
        "localSpeakerRecognitionModel": str(local_speaker_recognition_model_path()),
        "speakerRecognitionModelAvailable": is_available_aux_model(speaker_recognition_model),
        "localSpeakerDiarizationCoreMLModel": str(speaker_diarization_coreml_model),
        "speakerDiarizationCoreMLModelAvailable": speaker_diarization_coreml_files_available(speaker_diarization_coreml_model),
        "defaultEmotionModel": emotion_model,
        "localEmotionModel": str(emotion_mlx_model),
        "emotionModelAvailable": is_available_aux_model(emotion_model),
        "localEmotionMLXModel": str(emotion_mlx_model),
        "emotionMLXModelAvailable": is_valid_mlx_aux_model(emotion_mlx_model),
        "localPyannoteSegmentationMLXModel": str(pyannote_segmentation_mlx_model),
        "pyannoteSegmentationMLXModelAvailable": is_valid_mlx_aux_model(pyannote_segmentation_mlx_model),
        "defaultAudioEventModel": audio_event_model,
        "localAudioEventModel": str(panns_audio_event_model),
        "localPANNsAudioEventModel": str(panns_audio_event_model),
        "audioEventModelAvailable": is_available_aux_model(audio_event_model),
        "pannsAudioEventModelAvailable": is_valid_mlx_aux_model(panns_audio_event_model),
        "defaultOutputDir": str(Path(os.getenv("MSUB_OUTPUT_DIR") or JOB_DIR.parent)),
        "modelParameters": {
            "supported": [
                "asr_engine",
                "asr_context",
                "language",
                "use_itn",
                "sensevoice_rich_info",
                "vad_engine",
                "firered_vad_threshold",
                "firered_vad_smooth_window",
                "pyannote_vad_model",
                "pyannote_vad_threshold",
                "beam_size",
                "softmax_smoothing",
                "length_penalty",
                "eos_penalty",
                "decode_max_len",
                "emotion_model",
                "mimo_max_tokens",
                "mimo_temperature",
                "mimo_top_p",
                "mimo_top_k",
                "audio_event_filter",
                "audio_event_model",
                "audio_event_threshold",
                "audio_event_filter_type",
                "audio_event_preset",
                "min_confidence",
                "diarize_speakers",
                "speaker_labeling_engine",
                "speaker_recognition_model",
                "speaker_diarization_coreml_model",
                "speaker_cluster_threshold",
                "speaker_clustering_method",
                "diarization_num_speakers",
            ],
            "unsupported": [
                "repetition_penalty",
                "hotwords",
                "dialect",
            ],
        },
    }


MODELS_DIR = BASE_DIR / "models"
MODEL_REGISTRY: list[dict[str, str]] = [
    {"dir": "FireRedASR2-AED-mlx", "repo": "mlx-community/FireRedASR2-AED-mlx", "feature": "asr"},
    {"dir": "SenseVoiceSmall", "repo": DEFAULT_SENSEVOICE_MODEL_ID, "feature": "asr"},
    {"dir": "MiMo-V2.5-ASR-MLX-4bit", "repo": DEFAULT_MIMO_MODEL_ID, "feature": "asr"},
    {"dir": "Mega-ASR-bf16", "repo": DEFAULT_MEGA_MODEL_ID, "feature": "asr"},
    {"dir": "Qwen3-ASR-1.7B-8bit", "repo": DEFAULT_QWEN3_MODEL_ID, "feature": "asr"},
    {"dir": QWEN3_JA_MODEL_DIR, "repo": QWEN3_JA_MODEL_ID, "feature": "asr"},
    {"dir": "Fun-ASR-Nano-2512", "repo": DEFAULT_FUNASR_MODEL_ID, "feature": "asr"},
    {
        "dir": LOCAL_DIARIZATION_MODEL_DIRNAME,
        "repo": DEFAULT_DIARIZATION_MODEL_ID,
        "feature": "diarization",
    },
    {
        "dir": "Qwen3-ForcedAligner-0.6B-8bit",
        "repo": DEFAULT_ALIGNER_MODEL_ID,
        "feature": "align",
    },
    {"dir": "FireRedPunc", "repo": DEFAULT_PUNC_MODEL_ID, "feature": "punc"},
    {"dir": "DeepFilterNet-mlx", "repo": DEFAULT_DENOISE_MODEL_ID, "feature": "denoise"},
]
model_downloads: dict[str, dict[str, Any]] = {}
model_downloads_lock = threading.Lock()


_dir_size_cache: dict[str, tuple[float, int]] = {}
_DIR_SIZE_CACHE_TTL_SECONDS = 30.0


def _directory_size_bytes_uncached(path: Path) -> int:
    total = 0
    try:
        for entry in path.rglob("*"):
            if entry.is_file():
                with contextlib.suppress(OSError):
                    total += entry.stat().st_size
    except OSError:
        pass
    return total


def _directory_size_bytes(path: Path) -> int:
    key = str(path)
    cached = _dir_size_cache.get(key)
    now = time.time()
    if cached and now - cached[0] < _DIR_SIZE_CACHE_TTL_SECONDS:
        return cached[1]
    total = _directory_size_bytes_uncached(path)
    _dir_size_cache[key] = (now, total)
    return total


def _repo_total_bytes(repo: str) -> int | None:
    try:
        from huggingface_hub import HfApi

        info = HfApi().model_info(repo, files_metadata=True)
        sizes = [file.size for file in (info.siblings or []) if file.size]
        return sum(sizes) if sizes else None
    except Exception:  # noqa: BLE001 - progress metadata is best-effort.
        return None


def _resolve_managed_model_dir(name: str) -> Path:
    models_root = MODELS_DIR.resolve()
    target = (models_root / name).resolve()
    if target.parent != models_root or not name.strip():
        raise HTTPException(status_code=400, detail="Invalid model name.")
    return target


def _run_model_download(name: str, repo: str) -> None:
    try:
        from huggingface_hub import snapshot_download

        total_bytes = _repo_total_bytes(repo)
        if total_bytes:
            with model_downloads_lock:
                state = model_downloads.get(name)
                if state is not None:
                    state["totalBytes"] = total_bytes
        kwargs: dict[str, Any] = {
            "repo_id": repo,
            "local_dir": str(MODELS_DIR / name),
        }
        token = diarization_token()
        if token:
            kwargs["token"] = token
        snapshot_download(**kwargs)
        with model_downloads_lock:
            model_downloads[name] = {"status": "done"}
    except Exception as exc:  # noqa: BLE001 - surface download errors in the UI.
        with model_downloads_lock:
            model_downloads[name] = {"status": "error", "error": str(exc)}


@app.get("/api/models")
def list_models() -> dict:
    with model_downloads_lock:
        downloads = {name: dict(state) for name, state in model_downloads.items()}
    entries: list[dict[str, Any]] = []
    seen_dirs: set[str] = set()
    for item in MODEL_REGISTRY:
        name = item["dir"]
        seen_dirs.add(name)
        path = MODELS_DIR / name
        external_path = None
        if name == QWEN3_JA_MODEL_DIR and os.environ.get("MSUB_QWEN3_JA_MODEL"):
            candidate = Path(os.environ["MSUB_QWEN3_JA_MODEL"]).expanduser()
            if candidate.resolve() != path.resolve() and is_valid_mlx_stt_model(candidate):
                path = candidate
                external_path = str(candidate)
        installed = path.exists()
        download_state = downloads.get(name, {})
        downloading = download_state.get("status") == "downloading"
        entries.append(
            {
                "name": name,
                "repo": item["repo"],
                "feature": item["feature"],
                "installed": installed and not downloading,
                "sizeBytes": _directory_size_bytes(path) if installed and not downloading else 0,
                "downloadable": external_path is None,
                "externalPath": external_path,
                "downloadStatus": download_state.get("status"),
                "downloadError": download_state.get("error"),
                "downloadedBytes": _directory_size_bytes_uncached(path) if downloading else None,
                "totalBytes": download_state.get("totalBytes") if downloading else None,
            }
        )
    if MODELS_DIR.exists():
        for path in sorted(MODELS_DIR.iterdir()):
            if not path.is_dir() or path.name in seen_dirs or path.name.startswith("."):
                continue
            entries.append(
                {
                    "name": path.name,
                    "repo": None,
                    "feature": "other",
                    "installed": True,
                    "sizeBytes": _directory_size_bytes(path),
                    "downloadable": False,
                    "downloadStatus": None,
                    "downloadError": None,
                }
            )
    return {"modelsDir": str(MODELS_DIR), "models": entries}


@app.post("/api/models/download")
def download_model(name: str = Form(...)) -> dict:
    _resolve_managed_model_dir(name)
    registry_entry = next((item for item in MODEL_REGISTRY if item["dir"] == name), None)
    if registry_entry is None:
        raise HTTPException(status_code=404, detail="Unknown model.")
    # No early return for existing directories: snapshot_download is
    # idempotent and resumes partial downloads left by a crashed backend.
    with model_downloads_lock:
        state = model_downloads.get(name)
        if state and state.get("status") == "downloading":
            return {"ok": True, "status": "downloading"}
        model_downloads[name] = {"status": "downloading"}
    threading.Thread(
        target=_run_model_download,
        args=(name, registry_entry["repo"]),
        name=f"model-download-{name}",
        daemon=True,
    ).start()
    return {"ok": True, "status": "downloading"}


@app.post("/api/models/delete")
def delete_model(name: str = Form(...)) -> dict:
    target = _resolve_managed_model_dir(name)
    with model_downloads_lock:
        state = model_downloads.get(name)
        if state and state.get("status") == "downloading":
            raise HTTPException(status_code=409, detail="Model is downloading.")
        model_downloads.pop(name, None)
    if not target.exists():
        return {"ok": True}
    shutil.rmtree(target, ignore_errors=True)
    clear_stt_model_cache()
    return {"ok": True}


@app.get("/api/health")
def health() -> dict:
    diarization_model = default_diarization_model()
    speaker_recognition_model = default_speaker_recognition_model()
    emotion_model = default_emotion_model()
    audio_event_model = default_audio_event_model()
    emotion_mlx_model = local_emotion_mlx_model_path()
    pyannote_segmentation_mlx_model = local_pyannote_segmentation_mlx_model_path()
    panns_audio_event_model = local_panns_audio_event_model_path()
    speaker_diarization_coreml_model = local_speaker_diarization_coreml_model_path()
    return {
        "ok": True,
        "name": "MSub",
        "backendRoot": str(BASE_DIR),
        "backendSourceFingerprint": BACKEND_SOURCE_FINGERPRINT,
        "defaultModel": default_model_for_engine("fireredasr2"),
        "defaultASREngine": "fireredasr2",
        "models": model_catalog(),
        "defaultVADEngine": default_vad_engine(),
        "vadEngines": vad_catalog(),
        "defaultDiarizationModel": diarization_model,
        "localDiarizationModel": str(local_diarization_model_path()),
        "diarizationModelAvailable": is_valid_diarization_model(Path(diarization_model)),
        "defaultSpeakerLabelingEngine": os.getenv("MSUB_SPEAKER_LABELING_ENGINE", "acoustic"),
        "defaultSpeakerClusteringMethod": DEFAULT_SPEAKER_CLUSTERING_METHOD,
        "defaultSpeakerRecognitionModel": speaker_recognition_model,
        "localSpeakerRecognitionModel": str(local_speaker_recognition_model_path()),
        "speakerRecognitionModelAvailable": is_available_aux_model(speaker_recognition_model),
        "localSpeakerDiarizationCoreMLModel": str(speaker_diarization_coreml_model),
        "speakerDiarizationCoreMLModelAvailable": speaker_diarization_coreml_files_available(speaker_diarization_coreml_model),
        "defaultEmotionModel": emotion_model,
        "localEmotionModel": str(emotion_mlx_model),
        "emotionModelAvailable": is_available_aux_model(emotion_model),
        "localEmotionMLXModel": str(emotion_mlx_model),
        "emotionMLXModelAvailable": is_valid_mlx_aux_model(emotion_mlx_model),
        "localPyannoteSegmentationMLXModel": str(pyannote_segmentation_mlx_model),
        "pyannoteSegmentationMLXModelAvailable": is_valid_mlx_aux_model(pyannote_segmentation_mlx_model),
        "defaultAudioEventModel": audio_event_model,
        "localAudioEventModel": str(panns_audio_event_model),
        "localPANNsAudioEventModel": str(panns_audio_event_model),
        "audioEventModelAvailable": is_available_aux_model(audio_event_model),
        "pannsAudioEventModelAvailable": is_valid_mlx_aux_model(panns_audio_event_model),
        "jobDir": str(JOB_DIR),
        "maxConcurrentJobs": MAX_CONCURRENT_JOBS,
        "maxJobEvents": MAX_JOB_EVENTS,
        "logProgressEvents": LOG_PROGRESS_EVENTS,
        "parentPid": PARENT_PID or None,
        "modelCache": model_cache_state(),
    }


@app.post("/api/preview")
async def preview_segments(
    request: Request,
    file: UploadFile | None = File(None),
    input_path: str = Form(""),
    model: str = Form(DEFAULT_MODEL),
    asr_engine: str = Form("fireredasr2"),
    language: str = Form("auto"),
    use_itn: bool = Form(True),
    segment_mode: str = Form("vad"),
    vad_engine: str = Form("auto"),
    vad_threshold_db: float = Form(-38.0),
    firered_vad_model: str = Form(DEFAULT_FIRERED_VAD_MODEL),
    firered_vad_threshold: float = Form(0.4),
    firered_vad_smooth_window: int = Form(5),
    pyannote_vad_model: str = Form(DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL),
    pyannote_vad_threshold: float = Form(0.5),
    vad_min_speech_seconds: float = Form(0.2),
    vad_min_silence_seconds: float = Form(0.28),
    vad_padding_seconds: float = Form(0.20),
    vad_max_segment_seconds: float = Form(5.0),
    vad_min_segment_seconds: float = Form(0.8),
    vad_split_search_seconds: float = Form(0.75),
    audio_event_filter: bool = Form(False),
    audio_event_model: str = Form(DEFAULT_AUDIO_EVENT_MODEL),
    audio_event_threshold: float = Form(0.45),
    audio_event_filter_type: str = Form("repetition"),
    audio_event_preset: str = Form("balanced"),
    chunk_seconds: float = Form(20.0),
) -> JSONResponse:
    cleanup_jobs()
    job_id = uuid.uuid4().hex
    work_dir = JOB_DIR / job_id
    media_path = await resolve_job_input(request, file, input_path, work_dir)
    wav_path = work_dir / "preview.wav"
    settings_key = preview_key_for_request(
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
    )

    args = make_args(
        media_path,
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
    )

    try:
        def build_sync_preview():
            with model_job_slot(job_id):
                return build_preview_payload(
                    job_id,
                    input_path=media_path,
                    wav_path=wav_path,
                    settings_key=settings_key,
                    args=args,
                )

        # The compatibility endpoint must not block health/status/cancel routes
        # on the ASGI event loop while ffmpeg or a VAD model is running.
        payload = await asyncio.to_thread(build_sync_preview)
    except Exception as exc:  # noqa: BLE001 - return concise UI error.
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    return JSONResponse(payload)


@app.post("/api/preview/jobs")
async def create_preview_job(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    input_path: str = Form(""),
    model: str = Form(DEFAULT_MODEL),
    asr_engine: str = Form("fireredasr2"),
    language: str = Form("auto"),
    use_itn: bool = Form(True),
    segment_mode: str = Form("vad"),
    vad_engine: str = Form("auto"),
    vad_threshold_db: float = Form(-38.0),
    firered_vad_model: str = Form(DEFAULT_FIRERED_VAD_MODEL),
    firered_vad_threshold: float = Form(0.4),
    firered_vad_smooth_window: int = Form(5),
    pyannote_vad_model: str = Form(DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL),
    pyannote_vad_threshold: float = Form(0.5),
    vad_min_speech_seconds: float = Form(0.2),
    vad_min_silence_seconds: float = Form(0.28),
    vad_padding_seconds: float = Form(0.20),
    vad_max_segment_seconds: float = Form(5.0),
    vad_min_segment_seconds: float = Form(0.8),
    vad_split_search_seconds: float = Form(0.75),
    audio_event_filter: bool = Form(False),
    audio_event_model: str = Form(DEFAULT_AUDIO_EVENT_MODEL),
    audio_event_threshold: float = Form(0.45),
    audio_event_filter_type: str = Form("repetition"),
    audio_event_preset: str = Form("balanced"),
    chunk_seconds: float = Form(20.0),
) -> JSONResponse:
    cleanup_jobs()
    job_id = uuid.uuid4().hex
    work_dir = JOB_DIR / job_id
    media_path = await resolve_job_input(request, file, input_path, work_dir)
    wav_path = work_dir / "preview.wav"
    settings_key = preview_key_for_request(
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
    )

    args = make_args(
        media_path,
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
    )

    with jobs_lock:
        jobs[job_id] = {
            "id": job_id,
            "kind": "preview",
            "status": "queued",
            "createdAt": time.time(),
            "updatedAt": time.time(),
            "current": 0,
            "total": 100,
            "events": [],
            "progressText": "Queued",
            "lastProgressText": "Queued",
            "cancelRequested": False,
            "pauseRequested": False,
            "previewId": job_id,
            "settingsKey": settings_key,
            "workDir": str(work_dir),
            "logPath": str(work_dir / "job.log"),
        }
        pause_event = threading.Event()
        pause_event.set()
        job_pause_events[job_id] = pause_event
        snapshot = dict(jobs[job_id])
    persist_job_status(snapshot)
    append_job_log(job_id, "Preview job queued")
    background_tasks.add_task(
        run_preview_job,
        job_id,
        media_path,
        wav_path,
        args,
        settings_key,
    )
    return JSONResponse({"id": job_id})


@app.get("/api/preview/{preview_id}/audio")
def download_preview_audio(preview_id: str, request: Request) -> FileResponse:
    """Reuse the exact 16 kHz timeline-normalized PCM used by VAD in native ASR."""
    if not _client_is_loopback(request):
        raise HTTPException(status_code=403, detail="Preview audio is local-only.")
    plan_path = preview_plan_path(preview_id)
    if plan_path is None or not plan_path.is_file():
        raise HTTPException(status_code=404, detail="Preview not found.")
    try:
        payload = json.loads(plan_path.read_text(encoding="utf-8"))
        audio_path = Path(payload["audioPath"]).resolve()
        expected = (plan_path.parent / "preview.wav").resolve()
        if audio_path != expected or not audio_path.is_relative_to(JOB_DIR.resolve()):
            raise ValueError("Invalid preview audio path")
        if not audio_path.is_file():
            raise ValueError("Missing preview audio")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=404, detail="Preview audio is unavailable.") from exc
    return FileResponse(audio_path, filename="preview.wav", media_type="audio/wav")


@app.post("/api/preview/{preview_id}/segments")
async def update_preview_segments(preview_id: str, request: Request) -> JSONResponse:
    plan_path = preview_plan_path(preview_id)
    if plan_path is None or not plan_path.exists():
        raise HTTPException(status_code=404, detail="Preview not found.")
    try:
        payload = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=404, detail="Preview not found.") from exc

    body = await request.json()
    time_offset = float(body.get("timeOffset", 0.0) or 0.0) if isinstance(body, dict) else 0.0
    try:
        segments = updated_segments_from_request(
            body.get("segments") if isinstance(body, dict) else None,
            time_offset=time_offset,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not segments:
        raise HTTPException(status_code=400, detail="At least one segment is required.")

    payload["segments"] = [asdict(segment) for segment in segments]
    payload["updatedAt"] = time.time()
    plan_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

    shifted_segments: list[dict[str, Any]] = []
    for segment in segments:
        shifted = segment_payload(segment)
        shifted["start"] = round(segment.start + time_offset, 3)
        shifted["end"] = round(segment.end + time_offset, 3)
        shifted_segments.append(shifted)
    return JSONResponse(
        {
            "previewId": preview_id,
            "count": len(segments),
            "segments": shifted_segments,
        }
    )


@app.post("/api/jobs")
async def create_job(
    request: Request,
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(None),
    input_path: str = Form(""),
    preview_id: str = Form(""),
    native_segments: str = Form(""),
    model: str = Form(DEFAULT_MODEL),
    asr_engine: str = Form("fireredasr2"),
    language: str = Form("auto"),
    use_itn: bool = Form(True),
    sensevoice_rich_info: bool = Form(False),
    fmt: str = Form("srt"),
    segment_mode: str = Form("vad"),
    vad_engine: str = Form("auto"),
    vad_threshold_db: float = Form(-38.0),
    firered_vad_model: str = Form(DEFAULT_FIRERED_VAD_MODEL),
    firered_vad_threshold: float = Form(0.4),
    firered_vad_smooth_window: int = Form(5),
    pyannote_vad_model: str = Form(DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL),
    pyannote_vad_threshold: float = Form(0.5),
    vad_min_speech_seconds: float = Form(0.2),
    vad_min_silence_seconds: float = Form(0.28),
    vad_padding_seconds: float = Form(0.20),
    vad_max_segment_seconds: float = Form(5.0),
    vad_min_segment_seconds: float = Form(0.8),
    vad_split_search_seconds: float = Form(0.75),
    audio_event_filter: bool = Form(False),
    audio_event_model: str = Form(DEFAULT_AUDIO_EVENT_MODEL),
    audio_event_threshold: float = Form(0.45),
    audio_event_filter_type: str = Form("repetition"),
    audio_event_preset: str = Form("balanced"),
    chunk_seconds: float = Form(20.0),
    max_chars_per_line: int = Form(18),
    beam_size: int = Form(3),
    min_confidence: float = Form(0.0),
    softmax_smoothing: float = Form(1.25),
    length_penalty: float = Form(0.6),
    eos_penalty: float = Form(1.0),
    decode_max_len: int = Form(0),
    emotion_model: str = Form(DEFAULT_EMOTION_MODEL),
    mimo_max_tokens: int = Form(0),
    mimo_temperature: float = Form(0.0),
    mimo_top_p: float = Form(0.0),
    mimo_top_k: int = Form(0),
    diarize_speakers: bool = Form(False),
    speaker_labeling_engine: str = Form("acoustic"),
    speaker_recognition_model: str = Form(DEFAULT_SPEAKER_RECOGNITION_MODEL),
    speaker_diarization_coreml_model: str = Form(DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL),
    speaker_cluster_threshold: float = Form(0.45),
    speaker_clustering_method: str = Form(DEFAULT_SPEAKER_CLUSTERING_METHOD),
    diarization_num_speakers: int = Form(0),
    asr_context: str = Form(""),
    align_words: bool | None = Form(None),
    punctuate: bool | None = Form(None),
    denoise: bool | None = Form(None),
) -> JSONResponse:
    if fmt not in {"srt", "vtt", "ass", "txt", "json"}:
        raise HTTPException(status_code=400, detail="Unsupported output format.")

    if native_segments and (preview_id or segment_mode != "vad" or vad_engine != "firered"
                            or audio_event_filter or denoise or diarize_speakers):
        raise HTTPException(status_code=400, detail="Native segments require FireRed VAD without preview ID, denoising, speaker labeling or event filtering.")

    cleanup_jobs()
    job_id = uuid.uuid4().hex
    work_dir = JOB_DIR / job_id
    settings_key = preview_key_for_request(
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
    )
    preview_plan = load_preview_plan(preview_id, settings_key) if preview_id else None
    prepared_audio_path: Path | None = None
    prepared_segments: list[Segment] | None = None
    if preview_plan:
        prepared_segments = segments_from_preview_plan(preview_plan)
        if not prepared_segments and preview_plan.get("segments") != []:
            preview_plan = None
            prepared_segments = None
        else:
            input_path = Path(str(preview_plan["inputPath"]))
            prepared_audio_path = Path(str(preview_plan["audioPath"]))
    if not preview_plan:
        if file is None and not str(input_path or "").strip():
            raise HTTPException(status_code=400, detail="Preview expired or settings changed.")
        input_path = await resolve_job_input(request, file, input_path, work_dir)
    if native_segments:
        prepared_segments = await asyncio.to_thread(native_segments_from_pcm, input_path, native_segments)
        # Own the PCM before acknowledging the job. The client can then clean up
        # its temporary file even if polling disconnects or cancellation races.
        owned_pcm = work_dir / "native-input.wav"
        work_dir.mkdir(parents=True, exist_ok=True)
        if input_path.resolve() != owned_pcm.resolve():
            await asyncio.to_thread(shutil.copyfile, input_path, owned_pcm)
        input_path = prepared_audio_path = owned_pcm
    output_path = normalize_output_path(input_path, work_dir / "subtitle", fmt)
    args = make_args(
        input_path,
        output_path,
        model=model,
        asr_engine=asr_engine,
        language=language,
        use_itn=use_itn,
        sensevoice_rich_info=sensevoice_rich_info,
        fmt=fmt,
        segment_mode=segment_mode,
        vad_engine=vad_engine,
        vad_threshold_db=vad_threshold_db,
        firered_vad_model=firered_vad_model,
        firered_vad_threshold=firered_vad_threshold,
        firered_vad_smooth_window=firered_vad_smooth_window,
        pyannote_vad_model=pyannote_vad_model,
        pyannote_vad_threshold=pyannote_vad_threshold,
        vad_min_speech_seconds=vad_min_speech_seconds,
        vad_min_silence_seconds=vad_min_silence_seconds,
        vad_padding_seconds=vad_padding_seconds,
        vad_max_segment_seconds=vad_max_segment_seconds,
        vad_min_segment_seconds=vad_min_segment_seconds,
        vad_split_search_seconds=vad_split_search_seconds,
        audio_event_filter=audio_event_filter,
        audio_event_model=audio_event_model,
        audio_event_threshold=audio_event_threshold,
        audio_event_filter_type=audio_event_filter_type,
        audio_event_preset=audio_event_preset,
        chunk_seconds=chunk_seconds,
        max_chars_per_line=max_chars_per_line,
        beam_size=beam_size,
        min_confidence=min_confidence,
        softmax_smoothing=softmax_smoothing,
        length_penalty=length_penalty,
        eos_penalty=eos_penalty,
        decode_max_len=decode_max_len,
        emotion_model=emotion_model,
        mimo_max_tokens=mimo_max_tokens,
        mimo_temperature=mimo_temperature,
        mimo_top_p=mimo_top_p,
        mimo_top_k=mimo_top_k,
        diarize_speakers=diarize_speakers,
        speaker_labeling_engine=speaker_labeling_engine,
        speaker_recognition_model=speaker_recognition_model,
        speaker_diarization_coreml_model=speaker_diarization_coreml_model,
        speaker_cluster_threshold=speaker_cluster_threshold,
        speaker_clustering_method=speaker_clustering_method,
        diarization_num_speakers=diarization_num_speakers,
        asr_context=asr_context,
        align_words=align_words,
        punctuate=punctuate,
        denoise=denoise,
        prepared_audio_path=prepared_audio_path,
        prepared_segments=prepared_segments,
    )

    with jobs_lock:
        jobs[job_id] = {
            "id": job_id,
            "status": "queued",
            "createdAt": time.time(),
            "updatedAt": time.time(),
            "current": 0,
            "total": 0,
            "events": [],
            "progressText": "Queued",
            "lastProgressText": "Queued",
            "cancelRequested": False,
            "pauseRequested": False,
            "previewId": preview_id if preview_plan else None,
            "workDir": str(work_dir),
            "logPath": str(work_dir / "job.log"),
        }
        pause_event = threading.Event()
        pause_event.set()
        job_pause_events[job_id] = pause_event
        snapshot = dict(jobs[job_id])
    persist_job_status(snapshot)
    append_job_log(job_id, "Job queued")
    if native_segments:
        append_job_log(job_id, f"Using native FireRedVAD plan: {len(prepared_segments)} segments; skipping extraction and VAD")
    background_tasks.add_task(run_job, job_id, args)
    return JSONResponse({"id": job_id})


@app.post("/api/jobs/{job_id}/cancel")
def cancel_job(job_id: str) -> dict:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        if job.get("status") in TERMINAL_STATUSES:
            return {"ok": True, "status": job.get("status")}
        job["cancelRequested"] = True
        job["pauseRequested"] = False
        job["status"] = "cancelling"
        job["progressText"] = "Cancelling"
        job["updatedAt"] = time.time()
        event = job_pause_events.get(job_id)
        snapshot = dict(job)
    persist_job_status(snapshot)
    append_job_log(job_id, "Cancellation requested")
    if event:
        event.set()
    terminate_active_subprocesses_for_owner(job_id)
    return {"ok": True, "status": "cancelling"}


@app.post("/api/jobs/{job_id}/pause")
def pause_job(job_id: str) -> dict:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        if job.get("status") in TERMINAL_STATUSES:
            return {"ok": True, "status": job.get("status")}
        if job.get("cancelRequested"):
            return {"ok": True, "status": job.get("status", "cancelling")}
        job["pauseRequested"] = True
        if job.get("status") in {"queued", "waiting"}:
            job["status"] = "paused"
        if job.get("status") == "paused":
            job["progressText"] = "Paused"
        else:
            job["progressText"] = "Pause requested"
        job["updatedAt"] = time.time()
        event = job_pause_events.get(job_id)
        snapshot = dict(job)
    persist_job_status(snapshot)
    append_job_log(job_id, "Pause requested")
    if event:
        event.clear()
    return {"ok": True, "status": snapshot.get("status")}


@app.post("/api/jobs/{job_id}/resume")
def resume_job(job_id: str) -> dict:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        if job.get("status") in TERMINAL_STATUSES:
            return {"ok": True, "status": job.get("status")}
        job["pauseRequested"] = False
        if job.get("status") == "paused":
            job["status"] = "running"
        job["progressText"] = job.get("lastProgressText") or "Running"
        job["updatedAt"] = time.time()
        event = job_pause_events.get(job_id)
        snapshot = dict(job)
    persist_job_status(snapshot)
    append_job_log(job_id, "Resume requested")
    if event:
        event.set()
    return {"ok": True, "status": snapshot.get("status")}


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        if trace := job_diagnostics.get(job_id):
            job["diagnostics"] = trace.snapshot()
        return dict(job)


@app.get("/api/jobs/{job_id}/events")
async def stream_job_events(job_id: str, request: Request) -> StreamingResponse:
    """Server-sent job status updates (same JSON shape as GET /api/jobs/{id}).

    Replaces client-side polling: one connection, ~150 ms server-side refresh,
    closes automatically once the job reaches a terminal status.
    """
    with jobs_lock:
        if job_id not in jobs:
            raise HTTPException(status_code=404, detail="Job not found.")

    async def event_stream():
        last_updated = -1.0
        while True:
            if await request.is_disconnected():
                return
            payload: str | None = None
            terminal = False
            with jobs_lock:
                job = jobs.get(job_id)
                if job is None:
                    return
                updated = float(job.get("updatedAt") or 0.0)
                if updated != last_updated:
                    last_updated = updated
                    if trace := job_diagnostics.get(job_id):
                        job["diagnostics"] = trace.snapshot()
                    payload = json.dumps(dict(job), ensure_ascii=False, default=str)
                    terminal = job.get("status") in TERMINAL_STATUSES
            if payload is not None:
                yield f"data: {payload}\n\n"
                if terminal:
                    return
            await asyncio.sleep(0.15)

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/jobs/{job_id}/download")
def download_job(job_id: str) -> FileResponse:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        output = job.get("output")
    if not output:
        raise HTTPException(status_code=404, detail="Output is not ready.")
    path = Path(output)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Output file not found.")
    return FileResponse(path, filename=path.name, media_type=media_type_for_output(path))


def media_type_for_output(path: Path) -> str:
    match path.suffix.lower():
        case ".srt":
            return "application/x-subrip"
        case ".vtt":
            return "text/vtt"
        case ".json":
            return "application/json"
        case ".txt":
            return "text/plain"
        case _:
            return "application/octet-stream"


@app.get("/api/jobs/{job_id}/log")
def download_job_log(job_id: str) -> FileResponse:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found.")
        log_path = job.get("logPath")
    if not log_path:
        raise HTTPException(status_code=404, detail="Log is not ready.")
    path = Path(log_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Log file not found.")
    return FileResponse(path, filename=f"{job_id}.log", media_type="text/plain")


@app.post("/api/model/unload")
def unload_model() -> dict:
    unloaded = unload_model_cache("api")
    return {"ok": True, "unloaded": unloaded, "modelCache": model_cache_state()}


@app.post("/api/shutdown")
def shutdown_backend() -> dict:
    threading.Thread(
        target=lambda: (
            time.sleep(0.15),
            request_backend_shutdown("api", exit_process=True),
        ),
        name="api-shutdown",
        daemon=True,
    ).start()
    return {"ok": True}


def main() -> None:
    import uvicorn

    host = os.getenv("MSUB_HOST", "127.0.0.1")
    port = int(os.getenv("MSUB_PORT", "7860"))
    uvicorn.run("huz_subtitle.web:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    main()
