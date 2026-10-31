from __future__ import annotations

import argparse
import contextvars
import copy
import gc
import contextlib
import io
import json
from concurrent.futures import Future, ThreadPoolExecutor
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from dataclasses import dataclass
from functools import lru_cache
from itertools import pairwise
from pathlib import Path
from types import SimpleNamespace
from collections.abc import Callable

from .qwen_repetition import has_phrase_loop, accept_retry


_active_subprocesses: set[subprocess.Popen] = set()
_active_subprocesses_by_owner: dict[str, set[subprocess.Popen]] = {}
_active_subprocesses_lock = threading.Lock()
_active_subprocess_owner: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "msub_active_subprocess_owner",
    default=None,
)


def _register_subprocess(process: subprocess.Popen) -> None:
    with _active_subprocesses_lock:
        _active_subprocesses.add(process)
        owner = _active_subprocess_owner.get()
        if owner:
            _active_subprocesses_by_owner.setdefault(owner, set()).add(process)


def _unregister_subprocess(process: subprocess.Popen) -> None:
    with _active_subprocesses_lock:
        _active_subprocesses.discard(process)
        empty_owners = []
        for owner, processes in _active_subprocesses_by_owner.items():
            processes.discard(process)
            if not processes:
                empty_owners.append(owner)
        for owner in empty_owners:
            _active_subprocesses_by_owner.pop(owner, None)


def _terminate_subprocess(process: subprocess.Popen, timeout: float = 2.0) -> None:
    if process.poll() is not None:
        return
    with contextlib.suppress(Exception):
        process.terminate()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(Exception):
            process.kill()
        with contextlib.suppress(Exception):
            process.wait(timeout=1.0)


def terminate_active_subprocesses() -> None:
    with _active_subprocesses_lock:
        processes = list(_active_subprocesses)
    for process in processes:
        _terminate_subprocess(process, timeout=1.5)


def terminate_active_subprocesses_for_owner(owner: str) -> None:
    with _active_subprocesses_lock:
        processes = list(_active_subprocesses_by_owner.get(owner, ()))
    for process in processes:
        _terminate_subprocess(process, timeout=1.5)


@contextlib.contextmanager
def subprocess_tracking_context(owner: str | None):
    token = _active_subprocess_owner.set(owner)
    try:
        yield
    finally:
        _active_subprocess_owner.reset(token)


def tracked_subprocess_run(
    command: list[str],
    *,
    check: bool = False,
    capture_output: bool = False,
    timeout: float | None = None,
    **kwargs,
) -> subprocess.CompletedProcess:
    if capture_output:
        if kwargs.get("stdout") is not None or kwargs.get("stderr") is not None:
            raise ValueError("stdout and stderr may not be used with capture_output.")
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE

    process = subprocess.Popen(command, **kwargs)
    _register_subprocess(process)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        _terminate_subprocess(process)
        exc.output = exc.stdout
        raise
    finally:
        _unregister_subprocess(process)

    result = subprocess.CompletedProcess(
        command,
        process.returncode,
        stdout,
        stderr,
    )
    if check and result.returncode:
        raise subprocess.CalledProcessError(
            result.returncode,
            command,
            output=stdout,
            stderr=stderr,
        )
    return result


def _clean_configured_model(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = value.strip()
    return cleaned or None


DEFAULT_MODEL = (
    _clean_configured_model(os.getenv("MSUB_MODEL"))
    or _clean_configured_model(os.getenv("HUZ_MODEL"))
    or "mlx-community/FireRedASR2-AED-mlx"
)
BASE_DIR = Path(os.getenv("MSUB_BACKEND_ROOT") or Path(__file__).resolve().parents[2])
DEFAULT_SENSEVOICE_MODEL_ID = "mlx-community/SenseVoiceSmall"
LOCAL_SENSEVOICE_MODEL = BASE_DIR / "models" / "SenseVoiceSmall"
DEFAULT_SENSEVOICE_MODEL = (
    _clean_configured_model(os.getenv("MSUB_SENSEVOICE_MODEL"))
    or (
        str(LOCAL_SENSEVOICE_MODEL)
        if (LOCAL_SENSEVOICE_MODEL / "config.json").exists()
        else DEFAULT_SENSEVOICE_MODEL_ID
    )
)
DEFAULT_MIMO_MODEL_ID = "mlx-community/MiMo-V2.5-ASR-MLX-4bit"
LOCAL_MIMO_MODEL = BASE_DIR / "models" / "MiMo-V2.5-ASR-MLX-4bit"
DEFAULT_MIMO_MODEL = (
    _clean_configured_model(os.getenv("MSUB_MIMO_MODEL"))
    or (
        str(LOCAL_MIMO_MODEL)
        if (LOCAL_MIMO_MODEL / "config.json").exists()
        else DEFAULT_MIMO_MODEL_ID
    )
)
DEFAULT_MEGA_MODEL_ID = "mlx-community/Mega-ASR-bf16"
LOCAL_MEGA_MODEL = BASE_DIR / "models" / "Mega-ASR-bf16"
DEFAULT_MEGA_MODEL = (
    _clean_configured_model(os.getenv("MSUB_MEGA_MODEL"))
    or (
        str(LOCAL_MEGA_MODEL)
        if (LOCAL_MEGA_MODEL / "config.json").exists()
        else DEFAULT_MEGA_MODEL_ID
    )
)
DEFAULT_QWEN3_MODEL_ID = "mlx-community/Qwen3-ASR-1.7B-8bit"
LOCAL_QWEN3_MODEL = BASE_DIR / "models" / "Qwen3-ASR-1.7B-8bit"
DEFAULT_QWEN3_MODEL = (
    _clean_configured_model(os.getenv("MSUB_QWEN3_MODEL"))
    or (
        str(LOCAL_QWEN3_MODEL)
        if (LOCAL_QWEN3_MODEL / "config.json").exists()
        else DEFAULT_QWEN3_MODEL_ID
    )
)
DEFAULT_FUNASR_MODEL_ID = "mlx-community/Fun-ASR-Nano-2512"
LOCAL_FUNASR_MODEL = BASE_DIR / "models" / "Fun-ASR-Nano-2512"
DEFAULT_FUNASR_MODEL = (
    _clean_configured_model(os.getenv("MSUB_FUNASR_MODEL"))
    or (
        str(LOCAL_FUNASR_MODEL)
        if (LOCAL_FUNASR_MODEL / "config.json").exists()
        else DEFAULT_FUNASR_MODEL_ID
    )
)
DEFAULT_ALIGNER_MODEL_ID = "mlx-community/Qwen3-ForcedAligner-0.6B-8bit"
LOCAL_ALIGNER_MODEL = BASE_DIR / "models" / "Qwen3-ForcedAligner-0.6B-8bit"
DEFAULT_ALIGNER_MODEL = (
    _clean_configured_model(os.getenv("MSUB_ALIGN_MODEL"))
    or (
        str(LOCAL_ALIGNER_MODEL)
        if (LOCAL_ALIGNER_MODEL / "config.json").exists()
        else DEFAULT_ALIGNER_MODEL_ID
    )
)
DEFAULT_DENOISE_MODEL_ID = "mlx-community/DeepFilterNet-mlx"
LOCAL_DENOISE_MODEL = BASE_DIR / "models" / "DeepFilterNet-mlx"
DEFAULT_DENOISE_MODEL = (
    _clean_configured_model(os.getenv("MSUB_DENOISE_MODEL"))
    or (
        str(LOCAL_DENOISE_MODEL)
        if LOCAL_DENOISE_MODEL.exists()
        else DEFAULT_DENOISE_MODEL_ID
    )
)
DEFAULT_PUNC_MODEL_ID = "FireRedTeam/FireRedPunc"
LOCAL_PUNC_MODEL = BASE_DIR / "models" / "FireRedPunc"
DEFAULT_PUNC_MODEL = (
    _clean_configured_model(os.getenv("MSUB_PUNC_MODEL"))
    or (
        str(LOCAL_PUNC_MODEL)
        if (LOCAL_PUNC_MODEL / "model.pth.tar").exists()
        else DEFAULT_PUNC_MODEL_ID
    )
)
MIMO_DEFAULT_MAX_TOKENS = 256
MIMO_DEFAULT_TEMPERATURE = 0.0
MIMO_DEFAULT_TOP_P = 0.95
MIMO_DEFAULT_TOP_K = 0
MEGA_DEFAULT_MAX_TOKENS = 512
MEGA_DEFAULT_TEMPERATURE = 0.0
MEGA_DEFAULT_TOP_P = 1.0
MEGA_DEFAULT_TOP_K = 0
QWEN3_DEFAULT_MAX_TOKENS = 512
QWEN3_DEFAULT_TEMPERATURE = 0.0
QWEN3_DEFAULT_TOP_P = 1.0
QWEN3_DEFAULT_TOP_K = 0
FUNASR_DEFAULT_MAX_TOKENS = 512
FUNASR_DEFAULT_TEMPERATURE = 0.0
FUNASR_DEFAULT_TOP_P = 1.0
FUNASR_DEFAULT_TOP_K = 0
SENSEVOICE_LANGUAGES = {"auto", "zh", "en", "yue", "ja", "ko", "nospeech"}
MIMO_LANGUAGES = {"auto", "zh", "en", "nospeech"}
FUNASR_LANGUAGES = {
    "auto",
    "zh",
    "en",
    "ja",
    "yue",
    "wuu",
    "nan",
    "hak",
    "gan",
    "hsn",
    "cjy",
    "cmn",
    "nospeech",
}
MEGA_LANGUAGE_NAMES = (
    "Chinese",
    "English",
    "Cantonese",
    "Arabic",
    "German",
    "French",
    "Spanish",
    "Portuguese",
    "Indonesian",
    "Italian",
    "Korean",
    "Russian",
    "Thai",
    "Vietnamese",
    "Japanese",
    "Turkish",
    "Hindi",
    "Malay",
    "Dutch",
    "Swedish",
    "Danish",
    "Finnish",
    "Polish",
    "Czech",
    "Filipino",
    "Persian",
    "Greek",
    "Romanian",
    "Hungarian",
    "Macedonian",
)
MEGA_LANGUAGE_ALIASES = {
    "zh": "Chinese",
    "en": "English",
    "yue": "Cantonese",
    "ar": "Arabic",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "pt": "Portuguese",
    "id": "Indonesian",
    "it": "Italian",
    "ko": "Korean",
    "ru": "Russian",
    "th": "Thai",
    "vi": "Vietnamese",
    "ja": "Japanese",
    "tr": "Turkish",
    "hi": "Hindi",
    "ms": "Malay",
    "nl": "Dutch",
    "sv": "Swedish",
    "da": "Danish",
    "fi": "Finnish",
    "pl": "Polish",
    "cs": "Czech",
    "fil": "Filipino",
    "tl": "Filipino",
    "fa": "Persian",
    "el": "Greek",
    "ro": "Romanian",
    "hu": "Hungarian",
    "mk": "Macedonian",
}
MEGA_LANGUAGE_ALIASES.update({name.lower(): name for name in MEGA_LANGUAGE_NAMES})
LOCAL_FIRERED_VAD_COREML_MODEL = BASE_DIR / "models" / "FireRedVAD-CoreML"
LOCAL_FIRERED_VAD_MODEL = BASE_DIR / "models" / "FireRedVAD"
DEFAULT_FIRERED_VAD_MODEL = os.getenv("MSUB_FIRERED_VAD_MODEL") or str(LOCAL_FIRERED_VAD_COREML_MODEL)
LOCAL_PYANNOTE_SEGMENTATION_MLX_MODEL = BASE_DIR / "models" / "Pyannote-Segmentation-MLX"
DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL = (
    _clean_configured_model(os.getenv("MSUB_PYANNOTE_SEGMENTATION_MLX_MODEL"))
    or str(LOCAL_PYANNOTE_SEGMENTATION_MLX_MODEL)
)
DEFAULT_DIARIZATION_MODEL_ID = "pyannote/speaker-diarization-community-1"
LOCAL_DIARIZATION_MODEL = BASE_DIR / "models" / "pyannote-speaker-diarization-community-1"
DEFAULT_DIARIZATION_MODEL = (
    os.getenv("MSUB_DIARIZATION_MODEL")
    or os.getenv("PYANNOTE_MODEL")
    or (
        str(LOCAL_DIARIZATION_MODEL)
        if (LOCAL_DIARIZATION_MODEL / "config.yaml").exists()
        else DEFAULT_DIARIZATION_MODEL_ID
    )
)
DEFAULT_SPEAKER_RECOGNITION_MODEL_ID = "iic/speech_eres2netv2_sv_zh-cn_16k-common"
LOCAL_SPEAKER_RECOGNITION_MODEL = BASE_DIR / "models" / "speech_eres2netv2_sv_zh-cn_16k-common"
DEFAULT_SPEAKER_RECOGNITION_MODEL = (
    os.getenv("MSUB_SPEAKER_RECOGNITION_MODEL")
    or (
        str(LOCAL_SPEAKER_RECOGNITION_MODEL)
        if LOCAL_SPEAKER_RECOGNITION_MODEL.exists()
        else DEFAULT_SPEAKER_RECOGNITION_MODEL_ID
    )
)
LOCAL_SPEAKER_DIARIZATION_COREML_MODEL = BASE_DIR / "models" / "speaker-diarization-coreml"
DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL = (
    _clean_configured_model(os.getenv("MSUB_SPEAKER_DIARIZATION_COREML_MODEL"))
    or str(LOCAL_SPEAKER_DIARIZATION_COREML_MODEL)
)
DEFAULT_SPEAKER_CLUSTERING_METHOD = os.getenv(
    "MSUB_SPEAKER_CLUSTERING_METHOD",
    "spectral",
).strip().lower() or "spectral"
DEFAULT_EMOTION_MODEL_ID = "mlx-community/emotion2vec-plus-large-mlx"
LEGACY_EMOTION_MODEL_ID = "emotion2vec/emotion2vec_plus_base"
LOCAL_EMOTION_MLX_MODEL = BASE_DIR / "models" / "emotion2vec-plus-large-mlx"
DEFAULT_EMOTION_MODEL = (
    _clean_configured_model(os.getenv("MSUB_EMOTION_MODEL"))
    or (
        str(LOCAL_EMOTION_MLX_MODEL)
        if (LOCAL_EMOTION_MLX_MODEL / "emotion2vec_large_config.json").exists()
        and (LOCAL_EMOTION_MLX_MODEL / "emotion2vec_large.safetensors").exists()
        else DEFAULT_EMOTION_MODEL_ID
    )
)
DEFAULT_AUDIO_EVENT_MODEL_ID = "panns-cnn14-16k-mlx"
LOCAL_PANNS_AUDIO_EVENT_MODEL = BASE_DIR / "models" / "panns-cnn14-16k-mlx"
DEFAULT_AUDIO_EVENT_MODEL = (
    _clean_configured_model(os.getenv("MSUB_AUDIO_EVENT_MODEL"))
    or (
        str(LOCAL_PANNS_AUDIO_EVENT_MODEL)
        if (LOCAL_PANNS_AUDIO_EVENT_MODEL / "panns_cnn14_16k_config.json").exists()
        and (LOCAL_PANNS_AUDIO_EVENT_MODEL / "panns_cnn14_16k.safetensors").exists()
        else DEFAULT_AUDIO_EVENT_MODEL_ID
    )
)
ProgressCallback = Callable[[dict], None]


def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def torch_extras_enabled() -> bool:
    return env_bool("MSUB_ENABLE_TORCH_EXTRAS", False)


def audio_timeline_sync_filter() -> str | None:
    if not env_bool("MSUB_AUDIO_TIMELINE_SYNC", True):
        return None
    value = _clean_configured_model(os.getenv("MSUB_AUDIO_SYNC_FILTER"))
    if value is None:
        return "aresample=async=1000:first_pts=0"
    if value.lower() in {"0", "false", "no", "off", "none"}:
        return None
    return value


MODEL_CACHE_SIZE = max(
    1,
    env_int(
        "MSUB_STT_MODEL_CACHE_SIZE",
        env_int("MSUB_MODEL_CACHE_SIZE", 1),
    ),
)
PREFETCH_CHUNKS = env_bool("MSUB_PREFETCH_CHUNKS", True)
OVERLAP_SPEAKER_PREP = env_bool("MSUB_OVERLAP_SPEAKER_PREP", True)
CLEAR_MLX_CACHE_EACH_CHUNK = env_bool("MSUB_CLEAR_MLX_CACHE_EACH_CHUNK", True)
CLEAR_AUX_CACHE_EACH_JOB = env_bool("MSUB_CLEAR_AUX_CACHE_EACH_JOB", True)
MLX_CACHE_CLEAR_POLICY = (
    os.getenv("MSUB_MLX_CACHE_CLEAR_POLICY", "auto").strip().lower().replace("-", "_")
    or "auto"
)
MLX_CACHE_CLEAR_INTERVAL = max(1, env_int("MSUB_MLX_CACHE_CLEAR_INTERVAL", 8))
RETRY_CONFIDENCE_FLOOR = env_float("MSUB_RETRY_CONFIDENCE_FLOOR", 0.35)
RETRY_PADDING_SECONDS = env_float("MSUB_RETRY_PADDING_SECONDS", 0.22)
QWEN_REPETITION_PENALTY = env_float("MSUB_QWEN_REPETITION_PENALTY", 1.05)
QWEN_RETRY_REPETITION_PENALTY = env_float(
    "MSUB_QWEN_RETRY_REPETITION_PENALTY",
    max(1.15, QWEN_REPETITION_PENALTY),
)
QWEN_REPETITION_CONTEXT_SIZE = env_int("MSUB_QWEN_REPETITION_CONTEXT_SIZE", 100)
QWEN_RETRY_REPETITION_CONTEXT_SIZE = env_int(
    "MSUB_QWEN_RETRY_REPETITION_CONTEXT_SIZE",
    140,
)
FUNASR_REPETITION_PENALTY = env_float("MSUB_FUNASR_REPETITION_PENALTY", 1.08)
FUNASR_RETRY_REPETITION_PENALTY = env_float(
    "MSUB_FUNASR_RETRY_REPETITION_PENALTY",
    max(1.18, FUNASR_REPETITION_PENALTY),
)
FUNASR_REPETITION_CONTEXT_SIZE = env_int("MSUB_FUNASR_REPETITION_CONTEXT_SIZE", 80)
FUNASR_RETRY_REPETITION_CONTEXT_SIZE = env_int(
    "MSUB_FUNASR_RETRY_REPETITION_CONTEXT_SIZE",
    120,
)
QWEN_CLEAR_CACHE_BETWEEN_AUDIO_CHUNKS = env_bool(
    "MSUB_QWEN_CLEAR_MLX_CACHE_BETWEEN_AUDIO_CHUNKS",
    False,
)


@dataclass
class Cue:
    index: int
    start: float
    end: float
    text: str
    confidence: float | None = None
    speaker: str | None = None
    language: str | None = None
    emotion: str | None = None
    event: str | None = None
    words: list[tuple[str, float, float]] | None = None


@dataclass
class Segment:
    index: int
    start: float
    end: float
    speaker: str | None = None
    audio_label: str | None = None
    audio_score: float | None = None
    audio_labels: list[dict[str, object]] | None = None
    speech_score: float | None = None
    repetition_score: float | None = None
    flagged: bool = False

    @property
    def duration(self) -> float:
        return self.end - self.start


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate subtitles from video/audio with MLX ASR models."
    )
    parser.add_argument("input", type=Path, help="Input video or audio file.")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output path. Defaults to INPUT.srt, vtt, txt, or json.",
    )
    parser.add_argument(
        "-m",
        "--model",
        default=DEFAULT_MODEL,
        help="Hugging Face model id or local model directory.",
    )
    parser.add_argument(
        "--asr-engine",
        choices=["auto", "fireredasr2", "sensevoice", "mimo", "mega", "qwen3", "funasr"],
        default="auto",
        help="ASR engine adapter. Use auto to infer from the model path/name.",
    )
    parser.add_argument(
        "--language",
        "--sensevoice-language",
        dest="language",
        default="auto",
        help=(
            "Language hint. SenseVoice supports auto/zh/en/yue/ja/ko/nospeech; "
            "MiMo supports zh/en; Fun-ASR Nano supports zh/en/ja and Chinese dialect hints; "
            "Mega-ASR and Qwen3-ASR support zh/en/yue/ar/de/fr/es/pt/"
            "id/it/ko/ru/th/vi/ja/tr/hi/ms/nl/sv/da/fi/pl/cs/fil/fa/el/ro/hu/mk."
        ),
    )
    parser.add_argument(
        "--context",
        dest="asr_context",
        default=os.getenv("MSUB_ASR_CONTEXT", ""),
        help=(
            "Context/hotword hint for Qwen3-based engines (mega). Plain text, "
            "e.g. names and domain terms. Ignored by other engines."
        ),
    )
    parser.add_argument(
        "--align-words",
        action="store_true",
        default=env_bool("MSUB_ALIGN_WORDS", False),
        help=(
            "Refine cue timing with word-level forced alignment "
            "(Qwen3-ForcedAligner via MLX). Supports zh/en/ja/ko."
        ),
    )
    parser.add_argument(
        "--align-model",
        default=DEFAULT_ALIGNER_MODEL,
        help="Forced-alignment model id or local directory.",
    )
    parser.add_argument(
        "--denoise",
        action="store_true",
        default=env_bool("MSUB_DENOISE", False),
        help=(
            "Denoise the audio with DeepFilterNet (MLX) before VAD/ASR. "
            "Helps noisy recordings; falls back to the original audio on failure."
        ),
    )
    parser.add_argument(
        "--denoise-model",
        default=DEFAULT_DENOISE_MODEL,
        help="DeepFilterNet model id or local directory.",
    )
    parser.add_argument(
        "--punctuate",
        action="store_true",
        default=env_bool("MSUB_PUNCTUATE", False),
        help=(
            "Restore punctuation with FireRedPunc (zh/en). "
            "Requires the optional 'punc' dependency group."
        ),
    )
    parser.add_argument(
        "--punc-model",
        default=DEFAULT_PUNC_MODEL,
        help="FireRedPunc model id or local directory.",
    )
    parser.add_argument(
        "--use-itn",
        "--sensevoice-use-itn",
        dest="use_itn",
        action="store_true",
        help="Enable SenseVoice inverse text normalization.",
    )
    parser.add_argument(
        "--no-use-itn",
        dest="use_itn",
        action="store_false",
        help="Disable SenseVoice inverse text normalization.",
    )
    parser.set_defaults(use_itn=True)
    parser.add_argument(
        "--sensevoice-rich-info",
        "--include-sensevoice-rich-info",
        dest="sensevoice_rich_info",
        action="store_true",
        help=(
            "Prefix subtitle text with emotion metadata. SenseVoice uses native "
            "emotion/event labels; other ASR engines use emotion2vec."
        ),
    )
    parser.add_argument(
        "--no-sensevoice-rich-info",
        dest="sensevoice_rich_info",
        action="store_false",
        help="Keep SenseVoice emotion/event metadata out of subtitle text.",
    )
    parser.set_defaults(sensevoice_rich_info=False)
    parser.add_argument(
        "--format",
        choices=["srt", "vtt", "ass", "txt", "json"],
        default="srt",
        help="Subtitle/transcript output format.",
    )
    parser.add_argument(
        "--keep-audio",
        action="store_true",
        help="Keep the extracted 16kHz mono WAV next to the output file.",
    )
    parser.add_argument(
        "--no-extract",
        action="store_true",
        help="Use the input directly for one untimed txt/json transcription.",
    )
    parser.add_argument(
        "--chunk-seconds",
        type=float,
        default=20.0,
        help="Seconds per subtitle chunk when --segment-mode fixed is used.",
    )
    parser.add_argument(
        "--segment-mode",
        choices=["vad", "fixed"],
        default="vad",
        help="Use voice activity detection or fixed-length chunks.",
    )
    parser.add_argument(
        "--vad-threshold-db",
        type=float,
        default=-38.0,
        help="Speech energy threshold in dBFS. Higher values are stricter.",
    )
    parser.add_argument(
        "--vad-engine",
        choices=["auto", "energy", "firered", "pyannote_mlx"],
        default="auto",
        help=(
            "VAD backend. Auto uses Pyannote Segmentation MLX when available, "
            "then FireRedVAD CoreML, then Energy."
        ),
    )
    parser.add_argument(
        "--firered-vad-model",
        default=DEFAULT_FIRERED_VAD_MODEL,
        help="FireRedVAD model root or VAD subdirectory.",
    )
    parser.add_argument(
        "--firered-vad-threshold",
        type=float,
        default=0.4,
        help="FireRedVAD speech probability threshold. Higher values are stricter.",
    )
    parser.add_argument(
        "--firered-vad-smooth-window",
        type=int,
        default=5,
        help="FireRedVAD smoothing window size in frames.",
    )
    parser.add_argument(
        "--pyannote-vad-model",
        default=DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL,
        help="Pyannote Segmentation 3.0 MLX model directory.",
    )
    parser.add_argument(
        "--pyannote-vad-threshold",
        type=float,
        default=0.5,
        help="Pyannote Segmentation MLX speech probability threshold.",
    )
    parser.add_argument(
        "--vad-min-speech-seconds",
        type=float,
        default=0.2,
        help="Ignore detected speech shorter than this many seconds.",
    )
    parser.add_argument(
        "--vad-min-silence-seconds",
        type=float,
        default=0.28,
        help="Silences shorter than this are bridged into one segment.",
    )
    parser.add_argument(
        "--vad-padding-seconds",
        type=float,
        default=0.20,
        help="Seconds added before and after each VAD segment.",
    )
    parser.add_argument(
        "--vad-max-segment-seconds",
        type=float,
        default=5.0,
        help="Split long VAD segments so each model call stays bounded.",
    )
    parser.add_argument(
        "--vad-min-segment-seconds",
        type=float,
        default=0.8,
        help="Merge tiny split remainders shorter than this into nearby segments.",
    )
    parser.add_argument(
        "--vad-split-search-seconds",
        type=float,
        default=0.75,
        help="Search around long-segment cut points for the quietest local frame.",
    )
    parser.add_argument(
        "--preview-segments",
        action="store_true",
        help="Print detected segments as JSON and exit without loading the model.",
    )
    parser.add_argument(
        "--audio-event-filter",
        action="store_true",
        help="Mark likely laughter, shouting, and other non-lexical voice segments in previews.",
    )
    parser.add_argument(
        "--audio-event-model",
        default=DEFAULT_AUDIO_EVENT_MODEL,
        help="AudioSet audio classification model id or local path used for non-lexical segment marking.",
    )
    parser.add_argument(
        "--audio-event-threshold",
        type=float,
        default=0.45,
        help="Minimum AudioSet non-lexical score for marking a segment.",
    )
    parser.add_argument(
        "--audio-event-filter-type",
        choices=["all", "non_lexical", "non_speech", "repetition", "low_speech"],
        default="repetition",
        help="Which audio-event rule family should mark preview segments for deletion.",
    )
    parser.add_argument(
        "--audio-event-preset",
        choices=["strict", "balanced", "broad"],
        default="balanced",
        help="Audio-event marking preset. Strict is conservative; broad catches more candidates.",
    )
    parser.add_argument(
        "--max-chars-per-line",
        type=int,
        default=18,
        help="Wrap SRT/VTT subtitle text at this many characters. Use 0 to disable.",
    )
    parser.add_argument(
        "--max-cue-chars",
        type=int,
        default=0,
        help="Optionally split recognized text after ASR. Disabled by default.",
    )
    parser.add_argument(
        "--max-cue-duration",
        type=float,
        default=0.0,
        help="Optionally split cues after ASR by duration. Disabled by default.",
    )
    parser.add_argument(
        "--min-cue-duration",
        type=float,
        default=0.8,
        help="Avoid creating subtitle cues shorter than this when possible.",
    )
    parser.add_argument(
        "--beam-size",
        type=int,
        default=3,
        help="FireRedASR2 beam size.",
    )
    parser.add_argument(
        "--softmax-smoothing",
        type=float,
        default=1.25,
        help="FireRedASR2-AED softmax smoothing used during beam search.",
    )
    parser.add_argument(
        "--length-penalty",
        "--aed-length-penalty",
        dest="length_penalty",
        type=float,
        default=0.6,
        help="FireRedASR2-AED length normalization penalty.",
    )
    parser.add_argument(
        "--eos-penalty",
        type=float,
        default=1.0,
        help="FireRedASR2-AED end-of-sentence penalty.",
    )
    parser.add_argument(
        "--decode-max-len",
        type=int,
        default=0,
        help="Maximum decoded tokens per segment. Use 0 for model default.",
    )
    parser.add_argument(
        "--mimo-max-tokens",
        "--mega-max-tokens",
        "--qwen-max-tokens",
        "--qwen3-max-tokens",
        "--funasr-max-tokens",
        dest="mimo_max_tokens",
        type=int,
        default=0,
        help="Maximum generated tokens per segment for MiMo/Mega/Qwen3/Fun-ASR. Use 0 for engine default.",
    )
    parser.add_argument(
        "--mimo-temperature",
        "--mega-temperature",
        "--qwen-temperature",
        "--qwen3-temperature",
        "--funasr-temperature",
        dest="mimo_temperature",
        type=float,
        default=0.0,
        help="MiMo/Mega/Qwen3/Fun-ASR sampling temperature. 0 uses greedy decoding.",
    )
    parser.add_argument(
        "--mimo-top-p",
        "--mega-top-p",
        "--qwen-top-p",
        "--qwen3-top-p",
        "--funasr-top-p",
        dest="mimo_top_p",
        type=float,
        default=0.0,
        help="MiMo/Mega/Qwen3/Fun-ASR nucleus sampling top-p. Use 0 for engine default.",
    )
    parser.add_argument(
        "--mimo-top-k",
        "--mega-top-k",
        "--qwen-top-k",
        "--qwen3-top-k",
        "--funasr-top-k",
        dest="mimo_top_k",
        type=int,
        default=0,
        help="MiMo/Mega/Qwen3/Fun-ASR top-k sampling. 0 disables top-k filtering.",
    )
    parser.add_argument(
        "--min-confidence",
        type=float,
        default=0.0,
        help="Drop model segments with confidence below this value when available.",
    )
    parser.add_argument(
        "--emotion-model",
        default=DEFAULT_EMOTION_MODEL,
        help="MLX emotion2vec model id or local path used for non-SenseVoice emotion detection.",
    )
    parser.add_argument(
        "--diarize-speakers",
        action="store_true",
        help="Assign speaker labels to recognized subtitle cues.",
    )
    parser.add_argument(
        "--speaker-labeling-engine",
        choices=["acoustic", "coreml", "pyannote", "eres2netv2"],
        default=os.getenv("MSUB_SPEAKER_LABELING_ENGINE", "acoustic"),
        help=(
            "Speaker labeling backend. acoustic clusters VAD segments without torch; "
            "coreml clusters VAD segments with local CoreML speaker embeddings; "
            "pyannote performs diarization; eres2netv2 clusters VAD segments with a "
            "FunASR speaker embedding model. Torch-based engines require "
            "MSUB_ENABLE_TORCH_EXTRAS=1 and otherwise prefer coreml or acoustic."
        ),
    )
    parser.add_argument(
        "--diarization-model",
        default=os.getenv(
            "MSUB_DIARIZATION_MODEL",
            DEFAULT_DIARIZATION_MODEL,
        ),
        help="pyannote.audio diarization pipeline id or local path.",
    )
    parser.add_argument(
        "--speaker-recognition-model",
        default=DEFAULT_SPEAKER_RECOGNITION_MODEL,
        help="FunASR/ModelScope speaker embedding model id or local path.",
    )
    parser.add_argument(
        "--speaker-diarization-coreml-model",
        default=DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL,
        help="Local FluidInference speaker-diarization-coreml directory.",
    )
    parser.add_argument(
        "--speaker-cluster-threshold",
        type=float,
        default=env_float("MSUB_SPEAKER_CLUSTER_THRESHOLD", 0.45),
        help="Cosine similarity threshold for ERes2NetV2 speaker clustering.",
    )
    parser.add_argument(
        "--speaker-clustering-method",
        choices=["auto", "spectral", "incremental"],
        default=DEFAULT_SPEAKER_CLUSTERING_METHOD,
        help=(
            "Clustering method for ERes2NetV2 speaker embeddings. "
            "auto prefers spectral clustering and falls back to incremental."
        ),
    )
    parser.add_argument(
        "--diarization-num-speakers",
        type=int,
        default=0,
        help="Known number of speakers. Use 0 for automatic speaker counting.",
    )
    parser.add_argument(
        "--diarization-min-speakers",
        type=int,
        default=0,
        help="Lower bound for automatic speaker counting. Use 0 to disable.",
    )
    parser.add_argument(
        "--diarization-max-speakers",
        type=int,
        default=0,
        help="Upper bound for automatic speaker counting. Use 0 to disable.",
    )
    parser.add_argument(
        "--gen-kwargs",
        type=json.loads,
        default=None,
        help="JSON object passed to the model generate method.",
    )
    parser.add_argument("--verbose", action="store_true", help="Print inference details.")
    return parser.parse_args(argv)


def normalize_output_path(input_path: Path, output: Path | None, fmt: str) -> Path:
    if output is None:
        return input_path.with_suffix(f".{fmt}")
    if output.suffix.lower() == f".{fmt}":
        return output
    return output.with_suffix(f".{fmt}")


def executable_from_env(*names: str) -> str | None:
    for name in names:
        value = os.getenv(name)
        if not value:
            continue
        candidate = Path(value).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def bundled_executable(name: str) -> str | None:
    candidates: list[Path] = [
        BASE_DIR / name,
        BASE_DIR.parent / name,
    ]
    try:
        executable = Path(sys.executable).resolve()
        candidates.extend(parent / name for parent in executable.parents[:8])
    except OSError:
        pass

    seen: set[str] = set()
    for candidate in candidates:
        path = str(candidate)
        if path in seen:
            continue
        seen.add(path)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return path
    return None


def require_ffmpeg() -> str:
    ffmpeg = executable_from_env("MSUB_FFMPEG", "HUZ_FFMPEG", "FFMPEG_BINARY")
    ffmpeg = ffmpeg or bundled_executable("ffmpeg") or shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required for video audio extraction.")
    return ffmpeg


def require_ffprobe() -> str:
    ffprobe = executable_from_env("MSUB_FFPROBE", "HUZ_FFPROBE", "FFPROBE_BINARY")
    ffprobe = ffprobe or bundled_executable("ffprobe") or shutil.which("ffprobe")
    if not ffprobe:
        raise RuntimeError("ffprobe is required to read audio/video duration.")
    return ffprobe


def parse_ffmpeg_progress_time(line: str) -> float | None:
    key, separator, value = line.strip().partition("=")
    if not separator:
        return None
    value = value.strip()
    try:
        if key in {"out_time_ms", "out_time_us"}:
            return max(0.0, float(value) / 1_000_000.0)
        if key == "out_time":
            hours, minutes, seconds = value.split(":", 2)
            return max(0.0, int(hours) * 3600 + int(minutes) * 60 + float(seconds))
    except (TypeError, ValueError):
        return None
    return None


def copy_ready_pcm_audio(input_path: Path, wav_path: Path, sample_rate: int,
                         progress_callback=None) -> bool:
    """Reuse native/preview PCM without a second decoder or resampler."""
    try:
        source = wave.open(str(input_path), "rb")
    except (wave.Error, EOFError, OSError):
        return False
    with source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate(), source.getcomptype()) != (1, 2, sample_rate, "NONE"):
            return False
        if input_path.resolve() == wav_path.resolve():
            if progress_callback:
                progress_callback(1.0)
            return True
        wav_path.parent.mkdir(parents=True, exist_ok=True)
        total = source.getnframes()
        copied = 0
        try:
            with wave.open(str(wav_path), "wb") as target:
                target.setparams(source.getparams())
                while copied < total:
                    if progress_callback:
                        progress_callback(copied / max(1, total))
                    data = source.readframes(min(sample_rate * 5, total - copied))
                    if not data or len(data) % 2:
                        raise RuntimeError("Truncated PCM audio")
                    target.writeframesraw(data)
                    copied += len(data) // 2
            if progress_callback:
                progress_callback(1.0)
        except BaseException:
            wav_path.unlink(missing_ok=True)
            raise
        return True


def extract_audio(
    input_path: Path,
    wav_path: Path,
    *,
    progress_callback: Callable[[float], None] | None = None,
    duration: float | None = None,
    sample_rate: int = 16000,
) -> None:
    sync_filter = audio_timeline_sync_filter()
    if sync_filter in (None, "aresample=async=1000:first_pts=0") and copy_ready_pcm_audio(
        input_path, wav_path, sample_rate, progress_callback
    ):
        return
    ffmpeg = require_ffmpeg()
    wav_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostats",
        "-fflags",
        "+genpts",
        "-y",
        "-i",
        str(input_path),
        "-map",
        "0:a:0",
        "-vn",
    ]
    if sync_filter:
        command.extend(["-af", sync_filter])
    command.extend(
        [
            "-ar",
            str(sample_rate),
            "-ac",
            "1",
            "-acodec",
            "pcm_s16le",
            "-f",
            "wav",
            str(wav_path),
        ]
    )
    if progress_callback is None:
        tracked_subprocess_run(command, check=True)
        return

    total_duration = float(duration or 0.0)
    progress_command = command[:-1] + ["-progress", "pipe:1", command[-1]]
    process = subprocess.Popen(
        progress_command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    _register_subprocess(process)
    stderr = ""
    last_fraction = 0.0
    try:
        if process.stdout is not None:
            for line in process.stdout:
                seconds = parse_ffmpeg_progress_time(line)
                if seconds is not None and total_duration > 0:
                    last_fraction = min(max(seconds / total_duration, 0.0), 1.0)
                    progress_callback(last_fraction)
                elif line.startswith("progress="):
                    progress_callback(last_fraction)
                    continue
        _, stderr = process.communicate()
    except BaseException:
        _terminate_subprocess(process)
        raise
    finally:
        _unregister_subprocess(process)

    if process.returncode != 0:
        raise subprocess.CalledProcessError(
            process.returncode,
            progress_command,
            output=None,
            stderr=stderr,
        )
    progress_callback(1.0)


def extract_wav_chunk(input_path: Path, wav_path: Path, start: float, end: float) -> bool:
    try:
        with wave.open(str(input_path), "rb") as source:
            channels = source.getnchannels()
            sample_width = source.getsampwidth()
            sample_rate = source.getframerate()
            compression = source.getcomptype()
            if channels != 1 or sample_width != 2 or sample_rate != 16000 or compression != "NONE":
                return False

            duration = max(0.01, end - start)
            total_frames = source.getnframes()
            start_frame = max(0, int(round(start * sample_rate)))
            frame_count = max(1, int(round(duration * sample_rate)))
            if start_frame >= total_frames:
                return False
            frame_count = min(frame_count, total_frames - start_frame)
            source.setpos(start_frame)
            frames = source.readframes(frame_count)
    except (EOFError, OSError, wave.Error):
        return False

    wav_path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(wav_path), "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(16000)
        target.writeframes(frames)
    return True


def extract_chunk(input_path: Path, wav_path: Path, start: float, end: float) -> None:
    if env_bool("MSUB_FAST_WAV_CHUNKING", True) and extract_wav_chunk(
        input_path,
        wav_path,
        start,
        end,
    ):
        return

    ffmpeg = require_ffmpeg()
    wav_path.parent.mkdir(parents=True, exist_ok=True)
    duration = max(0.01, end - start)
    command = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{start:.3f}",
        "-t",
        f"{duration:.3f}",
        "-i",
        str(input_path),
        "-vn",
        "-ar",
        "16000",
        "-ac",
        "1",
        "-acodec",
        "pcm_s16le",
        "-f",
        "wav",
        str(wav_path),
    ]
    tracked_subprocess_run(command, check=True)


def probe_duration(path: Path) -> float:
    wav_duration = probe_wav_duration(path)
    if wav_duration is not None:
        return wav_duration

    try:
        ffprobe = require_ffprobe()
    except RuntimeError:
        ffmpeg_duration = probe_duration_with_ffmpeg(path)
        if ffmpeg_duration is not None:
            return ffmpeg_duration
        raise

    command = [
        ffprobe,
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    try:
        result = tracked_subprocess_run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        return float(result.stdout.strip())
    except (subprocess.SubprocessError, ValueError) as exc:
        ffmpeg_duration = probe_duration_with_ffmpeg(path)
        if ffmpeg_duration is not None:
            return ffmpeg_duration
        raise RuntimeError(f"Could not read media duration: {path}") from exc


def probe_wav_duration(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as wav:
            sample_rate = wav.getframerate()
            if sample_rate <= 0:
                return None
            return wav.getnframes() / sample_rate
    except (EOFError, OSError, wave.Error):
        return None


def probe_duration_with_ffmpeg(path: Path) -> float | None:
    try:
        ffmpeg = require_ffmpeg()
    except RuntimeError:
        return None
    result = tracked_subprocess_run(
        [ffmpeg, "-nostdin", "-hide_banner", "-i", str(path)],
        capture_output=True,
        text=True,
    )
    output = "\n".join(part for part in (result.stderr, result.stdout) if part)
    match = re.search(r"Duration:\s*(\d+):(\d{2}):(\d{2})(?:\.(\d+))?", output)
    if not match:
        return None
    hours = int(match.group(1))
    minutes = int(match.group(2))
    seconds = int(match.group(3))
    fraction_raw = match.group(4) or "0"
    fraction = int(fraction_raw) / (10 ** len(fraction_raw))
    duration = hours * 3600 + minutes * 60 + seconds + fraction
    return duration if duration > 0 else None


def output_base(output_path: Path) -> Path:
    return output_path.with_suffix("")


def format_srt_timestamp(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}".replace(".", ",")


def format_vtt_timestamp(seconds: float) -> str:
    return format_srt_timestamp(seconds).replace(",", ".")


def format_ass_timestamp(seconds: float) -> str:
    total_centiseconds = max(0, int(round(seconds * 100)))
    hours, remainder = divmod(total_centiseconds, 360000)
    minutes, remainder = divmod(remainder, 6000)
    secs, centiseconds = divmod(remainder, 100)
    return f"{hours}:{minutes:02d}:{secs:02d}.{centiseconds:02d}"


ASS_HEADER = """[Script Info]
; Generated by MSub
ScriptType: v4.00+
WrapStyle: 0
ScaledBorderAndShadow: yes
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,72,&H00FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,3,1,2,60,60,50,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def iter_ranges(duration: float, chunk_seconds: float) -> list[tuple[float, float]]:
    if chunk_seconds <= 0:
        raise RuntimeError("--chunk-seconds must be greater than 0.")

    ranges = []
    start = 0.0
    while start < duration - 0.05:
        end = min(duration, start + chunk_seconds)
        ranges.append((start, end))
        start = end
    return ranges


def read_wav_mono16(path: Path):
    import numpy as np

    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())

    if channels != 1 or sample_width != 2:
        raise RuntimeError("VAD expects a 16-bit mono WAV. Keep ffmpeg extraction on.")

    samples = np.frombuffer(frames, dtype="<i2").astype("float32") / 32768.0
    return samples, sample_rate


def resolve_firered_vad_model_dir(model_path: str | Path) -> Path:
    root = Path(model_path).expanduser()
    if (root / "model.pth.tar").exists() and (root / "cmvn.ark").exists():
        return root
    return root / "VAD"


def resolve_firered_vad_stream_model_dir(model_path: str | Path) -> Path:
    root = Path(model_path).expanduser()
    if (root / "model.pth.tar").exists() and (root / "cmvn.ark").exists():
        return root
    if (root / "Stream-VAD" / "model.pth.tar").exists():
        return root / "Stream-VAD"
    return root


def resolve_firered_vad_coreml_package(model_path: str | Path) -> Path:
    root = Path(model_path).expanduser()
    candidates = [
        root,
        root / "FireRedVAD.mlpackage",
        root / "fireredvad.mlmodelc",
    ]
    for candidate in candidates:
        if candidate.suffix == ".mlpackage":
            model_file = candidate / "Data" / "com.apple.CoreML" / "model.mlmodel"
            if model_file.exists():
                return candidate
        if candidate.suffix == ".mlmodelc" and candidate.exists():
            return candidate
    return root / "FireRedVAD.mlpackage"


def resolve_firered_vad_cmvn_path(model_path: str | Path) -> Path | None:
    env_path = _clean_configured_model(os.getenv("MSUB_FIRERED_VAD_CMVN"))
    if env_path:
        candidate = Path(env_path).expanduser()
        if candidate.exists():
            return candidate

    root = Path(model_path).expanduser()
    candidates = [
        root / "cmvn.ark",
        root / "Stream-VAD" / "cmvn.ark",
        LOCAL_FIRERED_VAD_COREML_MODEL / "cmvn.ark",
        LOCAL_FIRERED_VAD_MODEL / "Stream-VAD" / "cmvn.ark",
        LOCAL_FIRERED_VAD_MODEL / "VAD" / "cmvn.ark",
    ]
    return next((candidate for candidate in candidates if candidate.exists()), None)


def firered_vad_coreml_files_available(model_path: str | Path | None = None) -> bool:
    model_package = resolve_firered_vad_coreml_package(
        model_path or DEFAULT_FIRERED_VAD_MODEL
    )
    return model_package.exists() and resolve_firered_vad_cmvn_path(
        model_path or DEFAULT_FIRERED_VAD_MODEL
    ) is not None


@lru_cache(maxsize=8)
def firered_vad_coreml_available(model_path: str | Path | None = None) -> bool:
    if not firered_vad_coreml_files_available(model_path):
        return False
    if not firered_vad_coreml_runtime_cache_available():
        return False
    prepare_coreml_runtime_environment()
    try:
        import warnings

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with contextlib.redirect_stderr(io.StringIO()):
                import coremltools  # noqa: F401
        import kaldi_native_fbank  # noqa: F401
        import kaldiio  # noqa: F401
        import soundfile  # noqa: F401
    except ImportError:
        return False
    return True


def firered_vad_coreml_runtime_cache_available() -> bool:
    if env_bool("MSUB_SKIP_FIRERED_VAD_CACHE_CHECK", False):
        return True
    candidates: list[Path] = []
    for value in (
        os.getenv("MSUB_BACKEND_HOME"),
        str(Path("/private/tmp") / "msub-backend-home"),
        os.getenv("HOME"),
        str(Path(tempfile.gettempdir()) / "msub-backend-home"),
    ):
        cleaned = _clean_configured_model(value)
        if cleaned:
            candidate = Path(cleaned).expanduser()
            if candidate not in candidates:
                candidates.append(candidate)
    if not candidates:
        candidates.append(Path("/private/tmp") / "msub-backend-home")

    for home in candidates:
        cache_root = home / "Library" / "Caches" / "python3" / "com.apple.e5rt.e5bundlecache"
        try:
            cache_root.mkdir(parents=True, exist_ok=True)
            probe = cache_root / ".msub-write-test"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            os.environ["MSUB_BACKEND_HOME"] = str(home)
            return True
        except OSError:
            continue
    return False


def firered_vad_available(model_path: str | Path | None = None) -> bool:
    if firered_vad_coreml_available(model_path):
        return True
    model_dir = resolve_firered_vad_model_dir(model_path or DEFAULT_FIRERED_VAD_MODEL)
    if not ((model_dir / "model.pth.tar").exists() and (model_dir / "cmvn.ark").exists()):
        return False
    try:
        import fireredvad  # noqa: F401
    except ImportError:
        return False
    return True


def pyannote_segmentation_mlx_available(model_path: str | Path | None = None) -> bool:
    root = Path(model_path or DEFAULT_PYANNOTE_SEGMENTATION_MLX_MODEL).expanduser()
    if not ((root / "config.json").exists() and (root / "model.safetensors").exists()):
        return False
    try:
        import numpy  # noqa: F401
        import safetensors  # noqa: F401
    except ImportError:
        return False
    return True


def resolve_speaker_coreml_package(model_path: str | Path, name: str) -> Path:
    root = Path(model_path).expanduser()
    candidates = [
        root / "mlpackages" / f"{name}.mlpackage",
        root / f"{name}.mlpackage",
        root / f"{name}.mlmodelc",
    ]
    if name.lower() == "fbank":
        candidates.extend(
            [
                root / "mlpackages" / "FBank.mlpackage",
                root / "FBank.mlmodelc",
            ]
        )
    for candidate in candidates:
        if candidate.suffix == ".mlpackage":
            model_file = candidate / "Data" / "com.apple.CoreML" / "model.mlmodel"
            if model_file.exists():
                return candidate
        elif candidate.suffix == ".mlmodelc" and candidate.is_dir():
            return candidate
    return candidates[0]


@lru_cache(maxsize=8)
def speaker_diarization_coreml_available(model_path: str | Path | None = None) -> bool:
    root = Path(model_path or DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL).expanduser()
    if not speaker_diarization_coreml_files_available(root):
        return False
    if not firered_vad_coreml_runtime_cache_available():
        return False
    prepare_coreml_runtime_environment()
    try:
        import warnings

        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with contextlib.redirect_stderr(io.StringIO()):
                import coremltools  # noqa: F401
        import numpy  # noqa: F401
        import soundfile  # noqa: F401
    except ImportError:
        return False
    return True


def speaker_diarization_coreml_files_available(model_path: str | Path | None = None) -> bool:
    root = Path(model_path or DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL).expanduser()
    fbank_package = resolve_speaker_coreml_package(root, "Fbank")
    embedding_package = resolve_speaker_coreml_package(root, "Embedding")
    return fbank_package.exists() and embedding_package.exists()


def resolve_vad_engine(args: argparse.Namespace) -> str:
    requested = getattr(args, "vad_engine", "auto")
    if requested != "auto":
        return requested
    if pyannote_segmentation_mlx_available(getattr(args, "pyannote_vad_model", None)):
        return "pyannote_mlx"
    if firered_vad_coreml_available(args.firered_vad_model):
        return "firered"
    return "energy"


@lru_cache(maxsize=1)
def load_firered_vad_model(
    model_dir: str,
    threshold: float,
    smooth_window_size: int,
    min_speech_frame: int,
    max_speech_frame: int,
    min_silence_frame: int,
    chunk_max_frame: int,
):
    try:
        from fireredvad import FireRedVad, FireRedVadConfig
    except ImportError as exc:
        raise RuntimeError(
            "FireRedVAD is not installed. Run: UV_CACHE_DIR=.uv-cache uv sync"
        ) from exc

    config = FireRedVadConfig(
        use_gpu=False,
        smooth_window_size=smooth_window_size,
        speech_threshold=threshold,
        min_speech_frame=min_speech_frame,
        max_speech_frame=max_speech_frame,
        min_silence_frame=min_silence_frame,
        merge_silence_frame=0,
        extend_speech_frame=0,
        chunk_max_frame=chunk_max_frame,
    )
    return FireRedVad.from_pretrained(model_dir, config)


def prepare_coreml_runtime_environment() -> None:
    coreml_temp = _clean_configured_model(os.getenv("MSUB_COREML_TEMP_DIR"))
    if not coreml_temp:
        coreml_temp = str(Path("/private/tmp") / "msub-coreml")
    temp_root = Path(coreml_temp).expanduser()
    temp_root.mkdir(parents=True, exist_ok=True)
    temp_value = str(temp_root)
    os.environ["TMPDIR"] = temp_value
    os.environ["TEMP"] = temp_value
    os.environ["TMP"] = temp_value
    tempfile.tempdir = temp_value

    backend_home = _clean_configured_model(os.getenv("MSUB_BACKEND_HOME"))
    if not backend_home:
        backend_home = str(temp_root.parent / "msub-backend-home")
        os.environ.setdefault("MSUB_BACKEND_HOME", backend_home)
    backend_home_path = Path(backend_home).expanduser()
    (backend_home_path / "Library" / "Caches").mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(backend_home_path)
    os.environ["CFFIXED_USER_HOME"] = str(backend_home_path)


def coreml_compute_units(ct):
    requested = os.getenv("MSUB_COREML_COMPUTE_UNITS", "cpu_and_neural_engine")
    normalized = requested.strip().lower().replace("-", "_")
    return {
        "all": ct.ComputeUnit.ALL,
        "cpu": ct.ComputeUnit.CPU_ONLY,
        "cpu_only": ct.ComputeUnit.CPU_ONLY,
        "cpu_and_gpu": ct.ComputeUnit.CPU_AND_GPU,
        "cpu_and_neural_engine": ct.ComputeUnit.CPU_AND_NE,
        "cpu_and_ne": ct.ComputeUnit.CPU_AND_NE,
    }.get(normalized, ct.ComputeUnit.CPU_AND_NE)


def load_coreml_model_package(model_package: str, feature_name: str):
    import warnings

    prepare_coreml_runtime_environment()

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            with contextlib.redirect_stderr(io.StringIO()):
                import coremltools as ct
    except ImportError as exc:
        raise RuntimeError(
            f"{feature_name} requires coremltools in the backend environment."
        ) from exc

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with contextlib.redirect_stderr(io.StringIO()):
            if Path(model_package).suffix == ".mlmodelc":
                return ct.models.CompiledMLModel(
                    model_package,
                    compute_units=coreml_compute_units(ct),
                )
            return ct.models.MLModel(
                model_package,
                compute_units=coreml_compute_units(ct),
            )


@lru_cache(maxsize=1)
def load_firered_vad_coreml_model(model_package: str):
    return load_coreml_model_package(model_package, "FireRedVAD CoreML")


@lru_cache(maxsize=2)
def load_firered_vad_cmvn(cmvn_path: str) -> tuple:
    import kaldiio
    import numpy as np

    stats = kaldiio.load_mat(cmvn_path)
    if stats.shape[0] != 2:
        raise RuntimeError(f"Invalid FireRedVAD CMVN stats: {cmvn_path}")
    dim = stats.shape[-1] - 1
    count = float(stats[0, dim])
    if count < 1:
        raise RuntimeError(f"Invalid FireRedVAD CMVN frame count: {cmvn_path}")

    means = []
    inverse_std = []
    floor = 1e-20
    for index in range(dim):
        mean = float(stats[0, index]) / count
        variance = float(stats[1, index]) / count - mean * mean
        means.append(mean)
        inverse_std.append(1.0 / math.sqrt(max(variance, floor)))
    return (
        np.asarray(means, dtype=np.float32),
        np.asarray(inverse_std, dtype=np.float32),
    )


def extract_firered_vad_features(audio_path: Path, cmvn_path: Path) -> tuple:
    import kaldi_native_fbank as knf
    import numpy as np
    import soundfile as sf

    audio, sample_rate = sf.read(str(audio_path), dtype="int16", always_2d=False)
    audio = np.asarray(audio)
    if audio.ndim > 1:
        audio = audio.mean(axis=1).astype(np.int16)
    if sample_rate != 16000:
        raise RuntimeError("FireRedVAD expects 16kHz audio after ffmpeg extraction.")

    opts = knf.FbankOptions()
    opts.frame_opts.samp_freq = 16000
    opts.frame_opts.frame_length_ms = 25
    opts.frame_opts.frame_shift_ms = 10
    opts.frame_opts.dither = 0.0
    opts.frame_opts.snip_edges = True
    opts.mel_opts.num_bins = 80
    opts.mel_opts.debug_mel = False
    fbank = knf.OnlineFbank(opts)
    fbank.accept_waveform(sample_rate, audio.tolist())
    if fbank.num_frames_ready <= 0:
        return np.zeros((0, 80), dtype=np.float32), 0.0

    features = np.vstack(
        [fbank.get_frame(index) for index in range(fbank.num_frames_ready)]
    ).astype(np.float32)
    means, inverse_std = load_firered_vad_cmvn(str(cmvn_path))
    if features.shape[-1] != len(means):
        raise RuntimeError(
            f"FireRedVAD feature dim {features.shape[-1]} does not match CMVN dim {len(means)}."
        )
    features = (features - means) * inverse_std
    duration = float(audio.shape[0]) / float(sample_rate)
    return features.astype(np.float32, copy=False), duration


def predict_firered_vad_coreml_probs(
    model_package: Path, features, progress_callback: ProgressCallback | None = None,
) -> list[float]:
    import numpy as np

    model = load_firered_vad_coreml_model(str(model_package))
    cache_shape = (1, 128, 19)
    caches = {
        f"cache_{index}": np.zeros(cache_shape, dtype=np.float32)
        for index in range(8)
    }
    chunk_frames = max(1, min(512, env_int("MSUB_FIRERED_VAD_COREML_BATCH_FRAMES", 512)))
    probs: list[float] = []
    for start in range(0, len(features), chunk_frames):
        chunk = features[start : start + chunk_frames]
        inputs = {
            "feat": np.asarray(chunk, dtype=np.float32).reshape(1, len(chunk), 80),
            **caches,
        }
        output = model.predict(inputs)
        probs.extend(np.asarray(output["probs"], dtype=np.float32).reshape(-1).tolist())
        caches = {
            f"cache_{index}": np.asarray(output[f"new_cache_{index}"], dtype=np.float32)
            for index in range(8)
        }
        if progress_callback:
            progress_callback({
                "event": "vad_progress", "engine": "firered",
                "current": min(start + len(chunk), len(features)),
                "total": len(features),
                "fraction": min(start + len(chunk), len(features)) / len(features),
            })
    return probs


def stream_vad_ranges_from_probs(
    probs: list[float],
    args: argparse.Namespace,
    duration: float,
    frame_seconds: float = 0.01,
) -> tuple[list[tuple[float, float]], list[float]]:
    if not probs:
        return [], []

    smooth_window_size = max(1, int(args.firered_vad_smooth_window))
    speech_threshold = float(args.firered_vad_threshold)
    pad_start_frame = max(smooth_window_size, 5)
    min_speech_frame = max(1, int(math.ceil(args.vad_min_speech_seconds / frame_seconds)))
    min_silence_frame = max(1, int(math.ceil(args.vad_min_silence_seconds / frame_seconds)))
    max_speech_frame = max(
        min_speech_frame,
        int(math.ceil(max(args.vad_max_segment_seconds, 20.0) / frame_seconds)),
    )

    smoothed: list[float] = []
    window: list[float] = []
    window_sum = 0.0
    state = "silence"
    speech_count = 0
    silence_count = 0
    last_start = -1
    last_end = -1
    ranges: list[tuple[float, float]] = []
    hit_max_speech = False

    for frame_index, raw_prob in enumerate(probs, start=1):
        prob = max(0.0, min(1.0, float(raw_prob)))
        window.append(prob)
        window_sum += prob
        if len(window) > smooth_window_size:
            window_sum -= window.pop(0)
        smooth_prob = window_sum / len(window)
        smoothed.append(smooth_prob)
        is_speech = smooth_prob >= speech_threshold

        if hit_max_speech:
            last_start = frame_index
            hit_max_speech = False

        if state == "silence":
            if is_speech:
                state = "possible_speech"
                speech_count += 1
            else:
                silence_count += 1
                speech_count = 0
        elif state == "possible_speech":
            if is_speech:
                speech_count += 1
                if speech_count >= min_speech_frame:
                    state = "speech"
                    last_start = max(
                        1,
                        frame_index - speech_count + 1 - pad_start_frame,
                        last_end + 1,
                    )
                    silence_count = 0
            else:
                state = "silence"
                silence_count = 1
                speech_count = 0
        elif state == "speech":
            speech_count += 1
            if is_speech:
                silence_count = 0
                if speech_count >= max_speech_frame:
                    end_frame = frame_index
                    ranges.append(
                        (
                            max(0.0, (last_start - 1) * frame_seconds),
                            min(duration, max(0.0, (end_frame - 1) * frame_seconds)),
                        )
                    )
                    hit_max_speech = True
                    speech_count = 0
                    last_end = end_frame
                    last_start = -1
            else:
                state = "possible_silence"
                silence_count += 1
        elif state == "possible_silence":
            speech_count += 1
            if is_speech:
                state = "speech"
                silence_count = 0
                if speech_count >= max_speech_frame:
                    end_frame = frame_index
                    ranges.append(
                        (
                            max(0.0, (last_start - 1) * frame_seconds),
                            min(duration, max(0.0, (end_frame - 1) * frame_seconds)),
                        )
                    )
                    hit_max_speech = True
                    speech_count = 0
                    last_end = end_frame
                    last_start = -1
            else:
                silence_count += 1
                if silence_count >= min_silence_frame:
                    state = "silence"
                    end_frame = frame_index
                    if last_start > 0:
                        ranges.append(
                            (
                                max(0.0, (last_start - 1) * frame_seconds),
                                min(duration, max(0.0, (end_frame - 1) * frame_seconds)),
                            )
                        )
                    last_end = end_frame
                    last_start = -1
                    speech_count = 0

    if last_start > 0:
        ranges.append(
            (
                max(0.0, (last_start - 1) * frame_seconds),
                min(duration, max(0.0, (len(probs) - 1) * frame_seconds)),
            )
        )

    return [(start, end) for start, end in ranges if end - start > 0.05], smoothed


def ranges_from_vad_probabilities(
    probs,
    threshold: float,
    frame_seconds: float,
    duration: float,
    args: argparse.Namespace,
) -> list[tuple[float, float]]:
    import numpy as np

    prob_values = np.asarray(probs, dtype=np.float32).reshape(-1)
    if prob_values.size == 0:
        return []

    smooth_window_size = max(1, int(getattr(args, "firered_vad_smooth_window", 5) or 5))
    if smooth_window_size > 1:
        kernel = np.ones(smooth_window_size, dtype=np.float32) / float(smooth_window_size)
        prob_values = np.convolve(prob_values, kernel, mode="same").astype(np.float32)

    core_threshold = float(threshold)
    keep_threshold = max(0.05, min(core_threshold, core_threshold * 0.6))
    core_speech = prob_values >= core_threshold
    speech = prob_values >= keep_threshold
    min_silence_frames = max(1, int(math.ceil(args.vad_min_silence_seconds / frame_seconds)))
    min_speech_frames = max(1, int(math.ceil(args.vad_min_speech_seconds / frame_seconds)))

    bridged = speech.copy()
    index = 0
    while index < len(bridged):
        if bridged[index]:
            index += 1
            continue
        end = index
        while end < len(bridged) and not bridged[end]:
            end += 1
        if index > 0 and end < len(bridged) and (end - index) < min_silence_frames:
            bridged[index:end] = True
        index = end

    raw_ranges: list[tuple[float, float]] = []
    index = 0
    while index < len(bridged):
        if not bridged[index]:
            index += 1
            continue
        end = index
        while end < len(bridged) and bridged[end]:
            end += 1
        if int(core_speech[index:end].sum()) >= min_speech_frames:
            start_seconds = max(0.0, index * frame_seconds - args.vad_padding_seconds)
            end_seconds = min(duration, end * frame_seconds + args.vad_padding_seconds)
            if end_seconds - start_seconds > 0.05:
                raw_ranges.append((start_seconds, end_seconds))
        index = end

    protected_boundaries = confirmed_silence_boundaries(speech, frame_seconds, args.vad_min_silence_seconds)
    merged = merge_ranges(raw_ranges, args.vad_min_silence_seconds, protected_boundaries)
    # The cut finder minimizes its score: speech probabilities must stay positive.
    # Negating them would select the strongest speech instead of the pause.
    split_ranges = split_long_ranges(
        merged,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        prob_values,
        frame_seconds,
        args.vad_split_search_seconds,
    )
    trimmed_ranges = trim_ranges_to_speech(
        split_ranges,
        speech,
        frame_seconds,
        duration,
        args.vad_padding_seconds,
    )
    strict_ranges = split_long_ranges(
        trimmed_ranges,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        prob_values,
        frame_seconds,
        0.0,
    )
    return merge_short_adjacent_ranges(prevent_overlaps(strict_ranges), args, protected_boundaries)


def detect_speech_ranges(
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
):
    engine = resolve_vad_engine(args)
    args.resolved_vad_engine = engine
    if progress_callback:
        progress_callback({"event": "vad_start", "engine": engine, "duration": duration})
    if engine == "firered":
        try:
            ranges = detect_firered_speech_ranges(
                audio_path,
                duration,
                args,
                progress_callback,
            )
            if progress_callback:
                progress_callback({"event": "vad_done", "engine": "firered", "total": len(ranges)})
            return ranges
        except Exception as exc:
            if getattr(args, "vad_engine", "auto") != "auto":
                raise RuntimeError(f"FireRedVAD failed: {exc}") from exc
            if pyannote_segmentation_mlx_available(getattr(args, "pyannote_vad_model", None)):
                print(
                    f"FireRedVAD failed; falling back to Pyannote Segmentation MLX: {exc}",
                    file=sys.stderr,
                )
                args.resolved_vad_engine = "pyannote_mlx"
                if progress_callback:
                    progress_callback(
                        {
                            "event": "vad_start",
                            "engine": "pyannote_mlx",
                            "duration": duration,
                            "fallbackFrom": "firered",
                        }
                    )
                ranges = detect_pyannote_mlx_speech_ranges(
                    audio_path,
                    duration,
                    args,
                    progress_callback,
                )
                if progress_callback:
                    progress_callback({"event": "vad_done", "engine": "pyannote_mlx", "total": len(ranges)})
                return ranges
            if getattr(args, "vad_engine", "auto") == "auto":
                print(
                    f"FireRedVAD failed; falling back to Energy VAD: {exc}",
                    file=sys.stderr,
                )
                args.resolved_vad_engine = "energy"
                ranges = detect_energy_speech_ranges(audio_path, duration, args)
                if progress_callback:
                    progress_callback({"event": "vad_done", "engine": "energy", "total": len(ranges)})
                return ranges
            raise
    if engine == "pyannote_mlx":
        args.resolved_vad_engine = "pyannote_mlx"
        ranges = detect_pyannote_mlx_speech_ranges(
            audio_path,
            duration,
            args,
            progress_callback,
        )
        if progress_callback:
            progress_callback({"event": "vad_done", "engine": "pyannote_mlx", "total": len(ranges)})
        return ranges
    args.resolved_vad_engine = "energy"
    ranges = detect_energy_speech_ranges(audio_path, duration, args)
    if progress_callback:
        progress_callback({"event": "vad_done", "engine": "energy", "total": len(ranges)})
    return ranges


def detect_energy_speech_ranges(audio_path: Path, duration: float, args: argparse.Namespace):
    import numpy as np

    if args.vad_min_speech_seconds < 0:
        raise RuntimeError("--vad-min-speech-seconds must be 0 or greater.")
    if args.vad_min_silence_seconds < 0:
        raise RuntimeError("--vad-min-silence-seconds must be 0 or greater.")
    if args.vad_padding_seconds < 0:
        raise RuntimeError("--vad-padding-seconds must be 0 or greater.")
    if args.vad_min_segment_seconds < 0:
        raise RuntimeError("--vad-min-segment-seconds must be 0 or greater.")
    if args.vad_split_search_seconds < 0:
        raise RuntimeError("--vad-split-search-seconds must be 0 or greater.")

    samples, sample_rate = read_wav_mono16(audio_path)
    frame_seconds = 0.03
    frame_size = max(1, int(sample_rate * frame_seconds))
    frame_count = int(math.ceil(len(samples) / frame_size))
    padded = np.pad(samples, (0, frame_count * frame_size - len(samples)))
    frames = padded.reshape(frame_count, frame_size)
    rms = np.sqrt(np.mean(frames * frames, axis=1))
    dbfs = 20.0 * np.log10(np.maximum(rms, 1e-8))

    speech = dbfs >= args.vad_threshold_db
    min_silence_frames = int(math.ceil(args.vad_min_silence_seconds / frame_seconds))
    min_speech_frames = int(math.ceil(args.vad_min_speech_seconds / frame_seconds))

    bridged = speech.copy()
    i = 0
    while i < len(bridged):
        if bridged[i]:
            i += 1
            continue
        j = i
        while j < len(bridged) and not bridged[j]:
            j += 1
        if i > 0 and j < len(bridged) and (j - i) <= min_silence_frames:
            bridged[i:j] = True
        i = j

    raw_ranges: list[tuple[float, float]] = []
    i = 0
    while i < len(bridged):
        if not bridged[i]:
            i += 1
            continue
        j = i
        while j < len(bridged) and bridged[j]:
            j += 1
        if (j - i) >= min_speech_frames:
            start = max(0.0, i * frame_seconds - args.vad_padding_seconds)
            end = min(duration, j * frame_seconds + args.vad_padding_seconds)
            raw_ranges.append((start, end))
        i = j

    protected_boundaries = confirmed_silence_boundaries(speech, frame_seconds, args.vad_min_silence_seconds)
    merged = merge_ranges(raw_ranges, args.vad_min_silence_seconds, protected_boundaries)
    split_ranges = split_long_ranges(
        merged,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        dbfs,
        frame_seconds,
        args.vad_split_search_seconds,
    )
    trimmed_ranges = trim_ranges_to_speech(
        split_ranges,
        speech,
        frame_seconds,
        duration,
        args.vad_padding_seconds,
    )
    strict_ranges = split_long_ranges(
        trimmed_ranges,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        dbfs,
        frame_seconds,
        0.0,
    )
    final_ranges = trim_ranges_to_speech(
        strict_ranges,
        speech,
        frame_seconds,
        duration,
        args.vad_padding_seconds,
    )
    return merge_short_adjacent_ranges(final_ranges, args, protected_boundaries)


@lru_cache(maxsize=1)
def load_pyannote_mlx_segmentation_model(model_dir: str) -> tuple[dict, dict]:
    import numpy as np
    from safetensors import safe_open

    root = Path(model_dir).expanduser()
    config_path = root / "config.json"
    weights_path = root / "model.safetensors"
    if not (config_path.exists() and weights_path.exists()):
        raise RuntimeError(f"Pyannote Segmentation MLX model not found: {root}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    weights: dict[str, object] = {}
    with safe_open(str(weights_path), framework="np") as tensors:
        for key in tensors.keys():
            weights[key] = np.asarray(tensors.get_tensor(key), dtype=np.float32)
    return config, weights


def instance_norm_time(features, weight, bias, eps: float = 1e-5):
    import numpy as np

    values = np.asarray(features, dtype=np.float32)
    mean = np.mean(values, axis=0, keepdims=True)
    variance = np.var(values, axis=0, keepdims=True)
    normalized = (values - mean) / np.sqrt(variance + eps)
    return normalized * np.asarray(weight, dtype=np.float32) + np.asarray(bias, dtype=np.float32)


def conv1d_valid_channels_last(features, weight, bias=None, stride: int = 1):
    import numpy as np

    values = np.asarray(features, dtype=np.float32)
    kernel = np.asarray(weight, dtype=np.float32)
    kernel_size = int(kernel.shape[1])
    out_frames = (values.shape[0] - kernel_size) // stride + 1
    if out_frames <= 0:
        return np.zeros((0, kernel.shape[0]), dtype=np.float32)
    shape = (out_frames, kernel_size, values.shape[1])
    strides = (values.strides[0] * stride, values.strides[0], values.strides[1])
    windows = np.lib.stride_tricks.as_strided(values, shape=shape, strides=strides)
    output = np.einsum("tki,oki->to", windows, kernel, optimize=True).astype(np.float32)
    if bias is not None:
        output += np.asarray(bias, dtype=np.float32)
    return output


def max_pool1d_valid(features, pool_size: int = 3, stride: int = 3):
    import numpy as np

    values = np.asarray(features, dtype=np.float32)
    out_frames = (values.shape[0] - pool_size) // stride + 1
    if out_frames <= 0:
        return np.zeros((0, values.shape[1]), dtype=np.float32)
    shape = (out_frames, pool_size, values.shape[1])
    strides = (values.strides[0] * stride, values.strides[0], values.strides[1])
    windows = np.lib.stride_tricks.as_strided(values, shape=shape, strides=strides)
    return np.max(windows, axis=1).astype(np.float32)


def leaky_relu(features, slope: float = 0.01):
    import numpy as np

    values = np.asarray(features, dtype=np.float32)
    return np.where(values >= 0.0, values, values * slope).astype(np.float32)


def sigmoid(values):
    import numpy as np

    x = np.asarray(values, dtype=np.float32)
    # np.where evaluates both branches. Use one bounded exponential instead
    # of three, avoiding overflow on saturated gates as well as redundant work.
    exp_negative_abs = np.exp(-np.abs(x))
    return np.where(x >= 0, 1.0, exp_negative_abs) / (1.0 + exp_negative_abs)


def lstm_direction(features, wx, wh, bias, reverse: bool = False):
    import numpy as np

    values = np.asarray(features, dtype=np.float32)
    hidden_size = int(wh.shape[1])
    hidden = np.zeros(hidden_size, dtype=np.float32)
    cell = np.zeros(hidden_size, dtype=np.float32)
    output = np.empty((values.shape[0], hidden_size), dtype=np.float32)
    # The input projection is independent of recurrent state. One matrix
    # multiplication avoids hundreds of tiny BLAS calls per direction/window.
    projected = values @ wx.T
    indices = range(values.shape[0] - 1, -1, -1) if reverse else range(values.shape[0])
    for index in indices:
        gates = projected[index] + hidden @ wh.T + bias
        # One vectorized gate activation avoids three Python/NumPy dispatches
        # per recurrent step. The candidate cell still uses tanh below.
        activated = sigmoid(gates)
        input_gate = activated[:hidden_size]
        forget_gate = activated[hidden_size : hidden_size * 2]
        cell_gate = np.tanh(gates[hidden_size * 2 : hidden_size * 3]).astype(np.float32)
        output_gate = activated[hidden_size * 3 :]
        cell = forget_gate * cell + input_gate * cell_gate
        hidden = output_gate * np.tanh(cell).astype(np.float32)
        output[index] = hidden
    return output


def pyannote_sincnet_features(samples, weights: dict):
    import numpy as np

    x = np.asarray(samples, dtype=np.float32).reshape(-1, 1)
    x = instance_norm_time(x, weights["sincnet.wav_norm.weight"], weights["sincnet.wav_norm.bias"])

    x = conv1d_valid_channels_last(x, weights["sincnet.conv.0.weight"], stride=10)
    x = np.abs(x).astype(np.float32)
    x = max_pool1d_valid(x, 3, 3)
    x = leaky_relu(instance_norm_time(x, weights["sincnet.norm.0.weight"], weights["sincnet.norm.0.bias"]))

    x = conv1d_valid_channels_last(
        x,
        weights["sincnet.conv.1.weight"],
        weights["sincnet.conv.1.bias"],
    )
    x = max_pool1d_valid(x, 3, 3)
    x = leaky_relu(instance_norm_time(x, weights["sincnet.norm.1.weight"], weights["sincnet.norm.1.bias"]))

    x = conv1d_valid_channels_last(
        x,
        weights["sincnet.conv.2.weight"],
        weights["sincnet.conv.2.bias"],
    )
    x = max_pool1d_valid(x, 3, 3)
    x = leaky_relu(instance_norm_time(x, weights["sincnet.norm.2.weight"], weights["sincnet.norm.2.bias"]))

    return x


def pyannote_mlx_forward_chunk(samples, weights: dict):
    import numpy as np

    x = pyannote_sincnet_features(samples, weights)
    for layer in range(4):
        fwd = lstm_direction(
            x,
            weights[f"lstm_fwd.layers.{layer}.Wx"],
            weights[f"lstm_fwd.layers.{layer}.Wh"],
            weights[f"lstm_fwd.layers.{layer}.bias"],
            reverse=False,
        )
        bwd = lstm_direction(
            x,
            weights[f"lstm_bwd.layers.{layer}.Wx"],
            weights[f"lstm_bwd.layers.{layer}.Wh"],
            weights[f"lstm_bwd.layers.{layer}.bias"],
            reverse=True,
        )
        x = np.concatenate([fwd, bwd], axis=1).astype(np.float32)

    x = leaky_relu(x @ weights["linear.0.weight"].T + weights["linear.0.bias"])
    x = leaky_relu(x @ weights["linear.1.weight"].T + weights["linear.1.bias"])
    logits = x @ weights["classifier.weight"].T + weights["classifier.bias"]
    logits -= np.max(logits, axis=1, keepdims=True)
    probabilities = np.exp(logits)
    probabilities /= np.sum(probabilities, axis=1, keepdims=True)
    return np.clip(1.0 - probabilities[:, 0], 0.0, 1.0).astype(np.float32)


def pyannote_mlx_speech_probabilities(
    audio_path: Path,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
):
    import numpy as np

    from .pyannote_mlx import make_pyannote_forward

    config, weights = load_pyannote_mlx_segmentation_model(str(args.pyannote_vad_model))
    forward, backend = make_pyannote_forward(
        weights, pyannote_mlx_forward_chunk,
        os.getenv("MSUB_PYANNOTE_MLX_BACKEND", "numpy").strip().lower(),
    )
    if progress_callback:
        progress_callback({"event": "vad_backend", "engine": "pyannote_mlx", "backend": backend})
    with wave.open(str(audio_path), "rb") as wav:
        sample_rate = wav.getframerate()
        total_samples = wav.getnframes()
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise RuntimeError("VAD expects a 16-bit mono WAV. Keep ffmpeg extraction on.")
        expected_rate = int(config.get("sample_rate", 16000))
        if sample_rate != expected_rate:
            raise RuntimeError("Pyannote Segmentation MLX expects 16kHz audio after ffmpeg extraction.")

        chunk_duration = float(config.get("chunk_duration", 10.0))
        chunk_samples = max(1, int(round(chunk_duration * sample_rate)))
        frames_per_chunk = max(1, int(config.get("num_frames_per_chunk", 589)))
        frame_seconds = chunk_duration / float(frames_per_chunk)
        step_ratio = max(0.1, min(1.0, env_float("MSUB_PYANNOTE_MLX_STEP_RATIO", 0.5)))
        step_samples = max(1, int(round(chunk_samples * step_ratio)))
        total_frames = max(
            frames_per_chunk,
            int(math.ceil(max(0, total_samples - 1) / sample_rate / frame_seconds)) + frames_per_chunk,
        )
        aggregated = np.zeros(total_frames, dtype=np.float32)
        counts = np.zeros(total_frames, dtype=np.float32)
        total_chunks = 1 + (max(0, total_samples - chunk_samples) + step_samples - 1) // step_samples
        timing_started = time.perf_counter()
        inference_seconds = 0.0
        report_inference_seconds = 0.0
        report_chunk_index = 0
        next_timing_fraction = 0.1
        batch_size = 4 if backend == "mlx_batch" else 1
        batch_predictions = None

        def read_chunk(start):
            wav.setpos(start)
            read_count = min(chunk_samples, total_samples - start)
            raw = wav.readframes(read_count)
            if len(raw) != read_count * 2:
                raise RuntimeError("Truncated WAV while reading Pyannote audio window.")
            chunk = np.zeros(chunk_samples, dtype=np.float32)
            chunk[:read_count] = np.frombuffer(raw, dtype="<i2")
            chunk *= np.float32(1.0 / 32768.0)
            return chunk

        chunk_index = 0
        last_progress_fraction = -1.0
        last_progress_time = 0.0

        for start in range(0, max(1, total_samples), step_samples):
            chunk_index += 1
            # Opt-in batching retains at most four fixed windows. All output
            # windows still enter the unchanged overlap/averaging path in order.
            if batch_size > 1:
                offset = (chunk_index - 1) % batch_size
                if offset == 0:
                    count = min(batch_size, total_chunks - chunk_index + 1)
                    chunks = np.stack([read_chunk(start + i * step_samples) for i in range(count)])
                    inference_started = time.perf_counter()
                    batch_predictions = forward.predict_batch(chunks)
                    inference_seconds += time.perf_counter() - inference_started
                probs = batch_predictions[offset]
            else:
                chunk = read_chunk(start)
                inference_started = time.perf_counter()
                probs = forward(chunk)
                inference_seconds += time.perf_counter() - inference_started
            frame_start = int(round(start / sample_rate / frame_seconds))
            frame_end = min(total_frames, frame_start + len(probs))
            if frame_end <= frame_start:
                continue
            length = frame_end - frame_start
            aggregated[frame_start:frame_end] += probs[:length]
            counts[frame_start:frame_end] += 1.0
            if progress_callback:
                fraction = min(max(chunk_index / total_chunks, 0.0), 1.0)
                now = time.perf_counter()
                if fraction >= next_timing_fraction or chunk_index == total_chunks:
                    progress_callback({
                        "event": "vad_window_timing", "engine": "pyannote_mlx", "backend": backend,
                        "current": chunk_index, "total": total_chunks, "fraction": round(fraction, 4),
                        "windowMeanSeconds": round((inference_seconds - report_inference_seconds)
                                                   / (chunk_index - report_chunk_index), 4),
                        "inferenceSeconds": round(inference_seconds, 3),
                        "elapsedSeconds": round(now - timing_started, 3),
                    })
                    report_inference_seconds = inference_seconds
                    report_chunk_index = chunk_index
                    next_timing_fraction = (math.floor(fraction * 10) + 1) / 10
                if (
                    fraction >= 1.0
                    or fraction - last_progress_fraction >= 0.025
                    or now - last_progress_time >= 1.0
                ):
                    last_progress_fraction = fraction
                    last_progress_time = now
                    progress_callback(
                        {
                            "event": "vad_progress",
                            "engine": "pyannote_mlx",
                            "current": min(chunk_index, total_chunks),
                            "total": total_chunks,
                            "fraction": round(fraction, 4),
                        }
                    )
            if start + chunk_samples >= total_samples:
                break

    valid = counts > 0
    if not np.any(valid):
        return np.zeros(0, dtype=np.float32), frame_seconds
    aggregated[valid] /= counts[valid]
    last_valid = int(np.flatnonzero(valid)[-1]) + 1
    return aggregated[:last_valid], frame_seconds


def detect_pyannote_mlx_speech_ranges(
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[tuple[float, float]]:
    probs, frame_seconds = pyannote_mlx_speech_probabilities(
        audio_path,
        args,
        progress_callback,
    )
    return ranges_from_vad_probabilities(
        probs,
        float(args.pyannote_vad_threshold),
        frame_seconds,
        duration,
        args,
    )


def detect_firered_speech_ranges(
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[tuple[float, float]]:
    import numpy as np

    frame_seconds = 0.01
    coreml_package = resolve_firered_vad_coreml_package(args.firered_vad_model)
    coreml_cmvn = resolve_firered_vad_cmvn_path(args.firered_vad_model)
    if (
        coreml_package.exists()
        and coreml_cmvn is not None
        and firered_vad_coreml_available(args.firered_vad_model)
    ):
        features, feature_duration = extract_firered_vad_features(audio_path, coreml_cmvn)
        if len(features) == 0:
            return []
        probs = predict_firered_vad_coreml_probs(coreml_package, features, progress_callback)
        raw_ranges, prob_values = stream_vad_ranges_from_probs(
            probs,
            args,
            feature_duration or duration,
            frame_seconds,
        )
        raw_ranges = [
            (
                max(0.0, float(start) - args.vad_padding_seconds),
                min(duration, float(end) + args.vad_padding_seconds),
            )
            for start, end in raw_ranges
            if float(end) - float(start) > 0.05
        ]
        if not raw_ranges:
            return []

        prob_array = np.asarray(prob_values, dtype=np.float32)
        speech = prob_array >= float(args.firered_vad_threshold)
        protected_boundaries = confirmed_silence_boundaries(speech, frame_seconds, args.vad_min_silence_seconds)
        merged = merge_ranges(raw_ranges, args.vad_min_silence_seconds, protected_boundaries)
        split_ranges = split_long_ranges(
            merged,
            args.vad_max_segment_seconds,
            args.vad_min_segment_seconds,
            prob_array,
            frame_seconds,
            args.vad_split_search_seconds,
        )
        trimmed_ranges = trim_ranges_to_speech(
            split_ranges,
            speech,
            frame_seconds,
            duration,
            args.vad_padding_seconds,
        )
        strict_ranges = split_long_ranges(
            trimmed_ranges,
            args.vad_max_segment_seconds,
            args.vad_min_segment_seconds,
            prob_array,
            frame_seconds,
            0.0,
        )
        return merge_short_adjacent_ranges(prevent_overlaps(strict_ranges), args, protected_boundaries)

    model_dir = resolve_firered_vad_model_dir(args.firered_vad_model)
    if not ((model_dir / "model.pth.tar").exists() and (model_dir / "cmvn.ark").exists()):
        if coreml_package.exists() and coreml_cmvn is not None:
            raise RuntimeError(
                "FireRedVAD CoreML is not available in this runtime. "
                "Use Pyannote Segmentation MLX or Energy VAD."
            )
        raise RuntimeError(
            f"FireRedVAD model not found: {model_dir}. "
            "Run scripts/download_firered_vad_coreml.sh or set MSUB_FIRERED_VAD_MODEL."
        )

    min_speech_frame = max(1, int(math.ceil(args.vad_min_speech_seconds / frame_seconds)))
    min_silence_frame = max(1, int(math.ceil(args.vad_min_silence_seconds / frame_seconds)))
    max_speech_frame = max(
        min_speech_frame,
        int(math.ceil(max(args.vad_max_segment_seconds, 20.0) / frame_seconds)),
    )
    vad = load_firered_vad_model(
        str(model_dir),
        float(args.firered_vad_threshold),
        int(args.firered_vad_smooth_window),
        min_speech_frame,
        max_speech_frame,
        min_silence_frame,
        30000,
    )
    result, probs = vad.detect(str(audio_path))
    raw_ranges = [
        (max(0.0, float(start) - args.vad_padding_seconds), min(duration, float(end) + args.vad_padding_seconds))
        for start, end in result.get("timestamps", [])
        if float(end) - float(start) > 0.05
    ]
    if not raw_ranges:
        return []

    prob_values = probs.detach().cpu().numpy() if hasattr(probs, "detach") else np.asarray(probs)
    if len(prob_values) > 0:
        frame_seconds = max(0.001, float(result.get("dur") or duration) / len(prob_values))
    speech = prob_values >= float(args.firered_vad_threshold)

    protected_boundaries = confirmed_silence_boundaries(speech, frame_seconds, args.vad_min_silence_seconds)
    merged = merge_ranges(raw_ranges, args.vad_min_silence_seconds, protected_boundaries)
    split_ranges = split_long_ranges(
        merged,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        prob_values,
        frame_seconds,
        args.vad_split_search_seconds,
    )
    trimmed_ranges = trim_ranges_to_speech(
        split_ranges,
        speech,
        frame_seconds,
        duration,
        args.vad_padding_seconds,
    )
    strict_ranges = split_long_ranges(
        trimmed_ranges,
        args.vad_max_segment_seconds,
        args.vad_min_segment_seconds,
        prob_values,
        frame_seconds,
        0.0,
    )
    return merge_short_adjacent_ranges(prevent_overlaps(strict_ranges), args, protected_boundaries)


def confirmed_silence_boundaries(speech, frame_seconds: float, min_silence: float) -> list[float]:
    """Internal confirmed pauses; padding must not erase these split boundaries."""
    minimum = max(1, int(math.ceil(min_silence / frame_seconds)))
    boundaries = []
    start = None
    for index, active in enumerate(speech):
        if not active and start is None:
            start = index
        elif active and start is not None:
            if start > 0 and index - start >= minimum:
                boundaries.append((start + index) * frame_seconds / 2)
            start = None
    return boundaries


def crosses_silence_boundary(boundaries: list[float], start: float, end: float) -> bool:
    from bisect import bisect_right
    index = bisect_right(boundaries, start)
    return index < len(boundaries) and boundaries[index] < end


def merge_ranges(
    ranges: list[tuple[float, float]], merge_gap_seconds: float,
    protected_boundaries: list[float] | None = None,
) -> list[tuple[float, float]]:
    if not ranges:
        return []

    merged = [ranges[0]]
    for start, end in ranges[1:]:
        prev_start, prev_end = merged[-1]
        if start - prev_end <= merge_gap_seconds and not crosses_silence_boundary(
            protected_boundaries or [], prev_start, end
        ):
            merged[-1] = (prev_start, max(prev_end, end))
        else:
            merged.append((start, end))
    return merged


def split_long_ranges(
    ranges: list[tuple[float, float]],
    max_segment_seconds: float,
    min_segment_seconds: float,
    dbfs=None,
    frame_seconds: float = 0.03,
    split_search_seconds: float = 0.0,
) -> list[tuple[float, float]]:
    if max_segment_seconds <= 0:
        return ranges

    split: list[tuple[float, float]] = []
    for start, end in ranges:
        boundaries = [start]
        cursor = start
        while end - cursor > max_segment_seconds:
            target = cursor + max_segment_seconds
            low = cursor + max(0.05, min_segment_seconds)
            high = end - max(0.05, min_segment_seconds)
            if target >= high:
                if high > low and end - cursor > max_segment_seconds:
                    boundaries.append(round(high, 3))
                break
            cut = find_low_energy_cut(
                dbfs,
                frame_seconds,
                target,
                low,
                min(high, target),
                split_search_seconds,
            )
            if cut <= low or cut >= high:
                cut = target
            boundaries.append(cut)
            cursor = cut
        boundaries.append(end)

        for part_start, part_end in pairwise(boundaries):
            segment_duration = part_end - part_start
            if segment_duration <= 0.05:
                continue
            if (
                split
                and min_segment_seconds > 0
                and segment_duration < min_segment_seconds - 1e-6
                and abs(split[-1][1] - part_start) < 0.001
            ):
                split[-1] = (split[-1][0], part_end)
            else:
                split.append((part_start, part_end))
    return split


def merge_short_adjacent_ranges(
    ranges: list[tuple[float, float]],
    args: argparse.Namespace,
    protected_boundaries: list[float] | None = None,
) -> list[tuple[float, float]]:
    if len(ranges) < 2:
        return ranges

    max_segment_seconds = float(getattr(args, "vad_max_segment_seconds", 0.0) or 0.0)
    if max_segment_seconds <= 0:
        return ranges

    min_segment_seconds = float(getattr(args, "vad_min_segment_seconds", 0.8) or 0.8)
    min_silence_seconds = float(getattr(args, "vad_min_silence_seconds", 0.28) or 0.28)
    padding_seconds = float(getattr(args, "vad_padding_seconds", 0.0) or 0.0)
    merge_gap_seconds = env_float(
        "MSUB_VAD_SHORT_MERGE_GAP_SECONDS",
        max(0.75, min_silence_seconds + padding_seconds * 2.0 + 0.08),
    )
    tight_gap_seconds = env_float(
        "MSUB_VAD_TIGHT_MERGE_GAP_SECONDS",
        max(0.32, min_silence_seconds + min(0.12, padding_seconds)),
    )
    short_tail_seconds = env_float(
        "MSUB_VAD_SHORT_MERGE_MAX_SECONDS",
        max(2.2, min_segment_seconds * 3.0),
    )

    merged: list[tuple[float, float]] = []
    for start, end in ranges:
        if not merged:
            merged.append((start, end))
            continue

        prev_start, prev_end = merged[-1]
        gap = start - prev_end
        span = end - prev_start
        prev_duration = prev_end - prev_start
        current_duration = end - start
        is_short_adjacent = (
            current_duration <= short_tail_seconds
            or prev_duration <= short_tail_seconds
        )
        should_merge = (
            gap >= -0.001
            and gap <= merge_gap_seconds
            and span <= max_segment_seconds + 1e-6
            and not crosses_silence_boundary(protected_boundaries or [], prev_start, end)
            and (
                is_short_adjacent
                or gap <= tight_gap_seconds
            )
        )
        if should_merge:
            merged[-1] = (prev_start, end)
        else:
            merged.append((start, end))

    return prevent_overlaps(merged)


def trim_ranges_to_speech(
    ranges: list[tuple[float, float]],
    speech,
    frame_seconds: float,
    duration: float,
    padding_seconds: float,
) -> list[tuple[float, float]]:
    trimmed: list[tuple[float, float]] = []
    for start, end in ranges:
        start_index = max(0, int(math.floor(start / frame_seconds)))
        end_index = min(len(speech), int(math.ceil(end / frame_seconds)))
        if end_index <= start_index:
            continue

        active = [i for i in range(start_index, end_index) if bool(speech[i])]
        if not active:
            continue

        first = active[0]
        last = active[-1]
        next_start = max(start, first * frame_seconds - padding_seconds)
        next_end = min(end, (last + 1) * frame_seconds + padding_seconds)
        if next_end - next_start > 0.05:
            trimmed.append((round(next_start, 3), round(next_end, 3)))

    return prevent_overlaps(trimmed)


def prevent_overlaps(ranges: list[tuple[float, float]]) -> list[tuple[float, float]]:
    if not ranges:
        return []

    normalized = [ranges[0]]
    for start, end in ranges[1:]:
        prev_start, prev_end = normalized[-1]
        if start < prev_end:
            midpoint = round((start + prev_end) / 2, 3)
            normalized[-1] = (prev_start, max(prev_start + 0.05, midpoint))
            start = min(end - 0.05, midpoint)
        if end - start > 0.05:
            normalized.append((start, end))
    return normalized


def find_low_energy_cut(
    dbfs,
    frame_seconds: float,
    target: float,
    low: float,
    high: float,
    search_seconds: float,
) -> float:
    if dbfs is None or search_seconds <= 0:
        return target

    window_start = max(low, target - search_seconds)
    window_end = min(high, target + search_seconds)
    if window_end <= window_start:
        return target

    start_index = max(0, int(window_start / frame_seconds))
    end_index = min(len(dbfs), int(math.ceil(window_end / frame_seconds)))
    if end_index <= start_index:
        return target

    # Prefer a sustained quiet valley to a single-frame dip (e.g. a consonant).
    # A flat window supplies no boundary evidence: preserve the target instead
    # of always cutting at the beginning of the search window.
    import numpy as np

    local = np.asarray(dbfs[start_index:end_index], dtype=np.float64)
    if not np.isfinite(local).all():
        return target
    width = min(len(local), max(1, int(math.ceil(0.1 / frame_seconds))))
    sums = np.concatenate(([0.0], np.cumsum(local)))
    scores = (sums[width:] - sums[:-width]) / width
    best = float(scores.min())
    tolerance = max(1e-7, abs(best) * 1e-6)
    if float(scores.max()) - best <= tolerance:
        return target
    # Center the widest equally quiet interval; later intervals win ties.
    best_start = best_end = 0
    run_start = None
    for index in range(len(scores) + 1):
        if index < len(scores) and scores[index] <= best + tolerance:
            if run_start is None:
                run_start = index
        elif run_start is not None:
            if index - run_start >= best_end - best_start:
                best_start, best_end = run_start, index
            run_start = None
    cut_index = start_index + (best_start + best_end - 1 + width) / 2
    return round(min(window_end, max(window_start, cut_index * frame_seconds)), 3)


def build_segments(
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    speaker_turns: list[tuple[float, float, str]] | None = None,
    speaker_labels: dict[str, str] | None = None,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    if args.segment_mode == "fixed":
        ranges = iter_ranges(duration, args.chunk_seconds)
    else:
        ranges = detect_speech_ranges(audio_path, duration, args, progress_callback)
        if not ranges:
            # Media without any detected speech (e.g. music-only clips in a
            # batch) completes with an empty result instead of failing, so it
            # never interrupts multi-file runs. MSUB_STRICT_NO_SPEECH=1
            # restores the old hard error.
            if env_bool("MSUB_STRICT_NO_SPEECH", False):
                raise RuntimeError(
                    "No speech segments detected. Lower --vad-threshold-db or use "
                    "--segment-mode fixed."
                )
            print(
                "No speech segments detected; producing empty output. "
                "Lower --vad-threshold-db or use --segment-mode fixed if this "
                "media does contain speech.",
                file=sys.stderr,
            )
            if progress_callback:
                progress_callback({"event": "no_speech"})
            return []

    segments = [
        Segment(index=index, start=round(start, 3), end=round(end, 3))
        for index, (start, end) in enumerate(ranges, 1)
    ]
    if speaker_turns and speaker_labels:
        segments = split_segments_by_speaker(segments, speaker_turns, speaker_labels, args)
    for index, segment in enumerate(segments, 1):
        segment.index = index
    return segments


NON_LEXICAL_AUDIO_TERMS = (
    "laughter",
    "laugh",
    "giggle",
    "snicker",
    "chuckle",
    "scream",
    "screaming",
    "shout",
    "yell",
    "wail",
    "moan",
    "groan",
    "crying",
    "sob",
    "whimper",
    "sigh",
    "gasp",
    "breath",
    "breathing",
    "pant",
    "cough",
    "sneeze",
    "throat clearing",
)
NON_SPEECH_AUDIO_TERMS = (
    "music",
    "musical instrument",
    "singing bowl",
    "applause",
    "clapping",
    "cheering",
    "crowd",
    "noise",
    "white noise",
    "static",
    "silence",
    "vehicle",
    "engine",
    "door",
    "keyboard",
    "typing",
    "click",
    "beep",
    "alarm",
    "ringtone",
    "telephone",
    "footstep",
    "rustle",
    "wind",
    "rain",
    "thunder",
    "water",
)
SPEECH_AUDIO_TERMS = (
    "speech",
    "conversation",
    "narration",
    "monologue",
    "dialogue",
    "talking",
)
AUDIO_EVENT_FILTER_TYPES = {"all", "non_lexical", "non_speech", "repetition", "low_speech"}
AUDIO_EVENT_PRESETS = {
    "strict": {
        "event_scale": 1.22,
        "non_speech_scale": 1.08,
        "margin": 0.12,
        "speech_max": 0.18,
        "repetition": 0.72,
        "low_speech_event": 0.52,
    },
    "balanced": {
        "event_scale": 1.0,
        "non_speech_scale": 0.9,
        "margin": 0.06,
        "speech_max": 0.32,
        "repetition": 0.58,
        "low_speech_event": 0.38,
    },
    "broad": {
        "event_scale": 0.78,
        "non_speech_scale": 0.72,
        "margin": -0.02,
        "speech_max": 0.48,
        "repetition": 0.46,
        "low_speech_event": 0.28,
    },
}


def normalize_audio_label(label: str) -> str:
    return re.sub(r"\s+", " ", str(label).strip().lower().replace("_", " "))


def label_matches(label: str, terms: tuple[str, ...]) -> bool:
    normalized = normalize_audio_label(label)
    return any(term in normalized for term in terms)


def repetition_score_for_audio(samples, sample_rate: int) -> float:
    try:
        import numpy as np
    except ImportError:
        return 0.0

    audio = np.asarray(samples, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if audio.size < max(1, int(sample_rate * 0.35)):
        return 0.0

    frame = max(1, int(sample_rate * 0.025))
    hop = max(1, int(sample_rate * 0.01))
    if audio.size < frame * 3:
        return 0.0

    rms_values = []
    for start in range(0, max(1, audio.size - frame + 1), hop):
        window = audio[start : start + frame]
        if window.size < frame:
            break
        rms_values.append(float(np.sqrt(np.mean(window * window) + 1e-12)))
    if len(rms_values) < 8:
        return 0.0

    envelope = np.asarray(rms_values, dtype=np.float32)
    envelope -= float(envelope.mean())
    std = float(envelope.std())
    if std < 1e-5:
        return 0.0
    envelope /= std

    corr = np.correlate(envelope, envelope, mode="full")[len(envelope) - 1 :]
    if corr.size <= 1 or corr[0] <= 1e-6:
        return 0.0
    corr = corr / corr[0]

    seconds_per_frame = hop / float(sample_rate)
    min_lag = max(1, int(0.12 / seconds_per_frame))
    max_lag = min(corr.size - 1, int(0.55 / seconds_per_frame))
    if max_lag <= min_lag:
        return 0.0
    peak = float(np.max(corr[min_lag : max_lag + 1]))
    return round(max(0.0, min(1.0, (peak - 0.18) / 0.62)), 3)


def audio_event_device() -> str:
    if not torch_extras_enabled():
        return "cpu"
    requested = os.getenv("MSUB_AUDIO_EVENT_DEVICE", "cpu").strip().lower()
    if requested != "auto":
        return requested or "cpu"
    try:
        import torch

        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


@lru_cache(maxsize=1)
def load_audio_event_classifier(model_id: str):
    if not torch_extras_enabled():
        raise RuntimeError(
            "Legacy torch-based audio event marking is disabled by default. "
            "Use the PANNs Cnn14_16k MLX model or the repetition filter; set "
            "MSUB_ENABLE_TORCH_EXTRAS=1 only for explicit legacy testing."
        )
    try:
        import torch
        from transformers import AutoFeatureExtractor, AutoModelForAudioClassification
    except ImportError as exc:
        raise RuntimeError(
            "Legacy torch-based audio event marking requires transformers and torch in the backend "
            "environment. Use the PANNs Cnn14_16k MLX model or --audio-event-filter-type repetition."
        ) from exc

    extractor = AutoFeatureExtractor.from_pretrained(model_id)
    model = AutoModelForAudioClassification.from_pretrained(model_id)
    device = audio_event_device()
    if device != "cpu":
        try:
            model.to(torch.device(device))
        except Exception as exc:  # noqa: BLE001 - keep the setup error actionable.
            raise RuntimeError(f"Could not move audio event classifier to {device!r}.") from exc
    model.eval()
    return extractor, model, device


def top_audio_labels(scores, id_to_label: dict[int, str], limit: int = 5) -> list[tuple[str, float]]:
    try:
        import numpy as np
    except ImportError:
        return []
    indices = np.argsort(scores)[::-1][:limit]
    return [
        (id_to_label.get(int(index), str(index)), round(float(scores[index]), 4))
        for index in indices
    ]


def score_matching_labels(scores, id_to_label: dict[int, str], terms: tuple[str, ...]) -> tuple[str | None, float]:
    best_label: str | None = None
    best_score = 0.0
    for index, score in enumerate(scores):
        label = id_to_label.get(index, str(index))
        if label_matches(label, terms) and float(score) > best_score:
            best_label = label
            best_score = float(score)
    return best_label, best_score


def normalized_audio_event_filter_type(value: str | None) -> str:
    candidate = str(value or "repetition").strip().lower().replace("-", "_")
    return candidate if candidate in AUDIO_EVENT_FILTER_TYPES else "all"


def audio_event_preset(value: str | None) -> dict[str, float]:
    candidate = str(value or "balanced").strip().lower().replace("-", "_")
    return AUDIO_EVENT_PRESETS.get(candidate, AUDIO_EVENT_PRESETS["balanced"])


def has_audio_event_rule(filter_type: str, rule: str) -> bool:
    return filter_type == "all" or filter_type == rule


def mark_repetition_segments(
    audio_path: Path,
    segments: list[Segment],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    try:
        import numpy as np
        import soundfile as sf
    except ImportError as exc:
        raise RuntimeError(
            "Repetition audio marking requires numpy and soundfile in the backend environment."
        ) from exc

    audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    threshold = float(getattr(args, "audio_event_threshold", 0.45) or 0.45)
    preset = audio_event_preset(getattr(args, "audio_event_preset", "balanced"))
    repetition_threshold = max(
        0.0,
        min(1.0, max(float(preset["repetition"]), threshold)),
    )
    batch_size = max(1, env_int("MSUB_AUDIO_EVENT_BATCH_SIZE", 64))
    for batch_start in range(0, len(segments), batch_size):
        batch = segments[batch_start : batch_start + batch_size]
        for segment in batch:
            start = max(0, int(segment.start * sample_rate))
            end = min(audio.size, max(start + 1, int(segment.end * sample_rate)))
            score = repetition_score_for_audio(audio[start:end], sample_rate)
            is_flagged = score >= repetition_threshold
            segment.audio_label = "Repetition" if is_flagged else None
            segment.audio_score = score if is_flagged else None
            segment.audio_labels = [{"label": "Repetition", "score": score}]
            segment.repetition_score = score
            segment.flagged = is_flagged
        if progress_callback:
            progress_callback(
                {
                    "event": "audio_event_segments",
                    "current": min(batch_start + len(batch), len(segments)),
                    "total": len(segments),
                }
            )
    return segments


def mark_non_lexical_segments(
    audio_path: Path,
    segments: list[Segment],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    if not getattr(args, "audio_event_filter", False) or not segments:
        return segments

    raw_model_id = str(getattr(args, "audio_event_model", DEFAULT_AUDIO_EVENT_MODEL) or "").strip()
    model_id = raw_model_id or DEFAULT_AUDIO_EVENT_MODEL
    threshold = float(getattr(args, "audio_event_threshold", 0.45) or 0.45)
    filter_type = normalized_audio_event_filter_type(getattr(args, "audio_event_filter_type", "all"))
    preset = audio_event_preset(getattr(args, "audio_event_preset", "balanced"))
    use_panns_mlx = False
    panns_classifier = None
    try:
        from .panns_mlx import (
            is_panns_mlx_model_path,
            load_panns_mlx_model,
            looks_like_panns_mlx_model,
        )
    except ImportError:
        is_panns_mlx_model_path = None
        load_panns_mlx_model = None
        looks_like_panns_mlx_model = None
    if looks_like_panns_mlx_model is not None:
        use_panns_mlx = looks_like_panns_mlx_model(model_id)
        if use_panns_mlx and is_panns_mlx_model_path is not None and not is_panns_mlx_model_path(model_id):
            if is_panns_mlx_model_path(LOCAL_PANNS_AUDIO_EVENT_MODEL):
                model_id = str(LOCAL_PANNS_AUDIO_EVENT_MODEL)
            else:
                use_panns_mlx = False

    if filter_type == "repetition" or (not use_panns_mlx and not torch_extras_enabled()):
        return mark_repetition_segments(audio_path, segments, args, progress_callback)

    try:
        import numpy as np
        import soundfile as sf
    except ImportError as exc:
        raise RuntimeError(
            "Audio event marking requires numpy and soundfile in the backend environment. "
            "Use --audio-event-filter-type repetition for torch-free repeated-sound marking."
        ) from exc

    if not use_panns_mlx:
        try:
            import torch
        except ImportError as exc:
            raise RuntimeError(
                "Legacy torch-based audio event marking requires torch in the backend environment. "
                "Use the PANNs Cnn14_16k MLX model or the repetition filter."
            ) from exc

    event_threshold = max(0.0, min(1.0, threshold * preset["event_scale"]))
    non_speech_threshold = max(0.0, min(1.0, threshold * preset["non_speech_scale"]))
    if progress_callback:
        progress_callback({"event": "audio_event_model_loading", "model": model_id})
    if use_panns_mlx:
        if load_panns_mlx_model is None:
            raise RuntimeError("PANNs MLX audio event classifier is not available.")
        panns_classifier = load_panns_mlx_model(model_id)
        extractor = None
        model = None
        device = "mlx"
        id_to_label = panns_classifier.id_to_label
    else:
        extractor, model, device = load_audio_event_classifier(model_id)
        id_to_label = {
            int(index): label for index, label in getattr(model.config, "id2label", {}).items()
        }
    if progress_callback:
        progress_callback({"event": "audio_event_model_loaded", "model": model_id})

    audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    target_rate = (
        sample_rate
        if use_panns_mlx
        else int(getattr(extractor, "sampling_rate", sample_rate) or sample_rate)
    )
    if not use_panns_mlx and sample_rate != target_rate:
        try:
            import librosa

            audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=target_rate)
            sample_rate = target_rate
        except Exception as exc:  # noqa: BLE001 - this only happens on unusual preview wavs.
            raise RuntimeError(f"Could not resample audio for AudioSet classifier: {exc}") from exc

    if use_panns_mlx:
        batch_size = max(1, env_int("MSUB_PANNS_MLX_BATCH_SIZE", 16))
    else:
        batch_size = max(1, env_int("MSUB_AUDIO_EVENT_BATCH_SIZE", 8))
    for batch_start in range(0, len(segments), batch_size):
        batch = segments[batch_start : batch_start + batch_size]
        chunks = []
        chunk_repetition_scores: list[float] = []
        for segment in batch:
            start = max(0, int(segment.start * sample_rate))
            end = min(audio.size, max(start + 1, int(segment.end * sample_rate)))
            chunk = audio[start:end]
            if chunk.size < int(sample_rate * 0.1):
                chunk = np.pad(chunk, (0, max(1, int(sample_rate * 0.1) - chunk.size)))
            chunks.append(chunk)
            chunk_repetition_scores.append(repetition_score_for_audio(chunk, sample_rate))

        if use_panns_mlx:
            probabilities = panns_classifier.predict(chunks, sample_rate)
        else:
            inputs = extractor(
                chunks,
                sampling_rate=sample_rate,
                return_tensors="pt",
                padding=True,
            )
            inputs = {key: value.to(device) if hasattr(value, "to") else value for key, value in inputs.items()}
            with torch.inference_mode():
                logits = model(**inputs).logits.detach().cpu()
                probabilities = torch.sigmoid(logits).numpy()

        for segment, scores, repetition_score in zip(batch, probabilities, chunk_repetition_scores):
            non_label, non_score = score_matching_labels(scores, id_to_label, NON_LEXICAL_AUDIO_TERMS)
            non_speech_label, non_speech_score = score_matching_labels(scores, id_to_label, NON_SPEECH_AUDIO_TERMS)
            _, speech_score = score_matching_labels(scores, id_to_label, SPEECH_AUDIO_TERMS)
            top_labels = top_audio_labels(scores, id_to_label, limit=5)
            segment.audio_labels = [
                {"label": label, "score": score}
                for label, score in top_labels
            ]
            best_label, best_score = top_labels[0] if top_labels else (non_label, non_score)
            best_score = float(best_score or 0.0)
            best_is_speech = label_matches(best_label or "", SPEECH_AUDIO_TERMS)
            speech_max = float(preset["speech_max"])
            margin = float(preset["margin"])

            direct_non_lexical = (
                has_audio_event_rule(filter_type, "non_lexical")
                and non_label is not None
                and non_score >= event_threshold
                and non_score >= speech_score + margin
            )
            direct_non_speech = (
                has_audio_event_rule(filter_type, "non_speech")
                and non_speech_label is not None
                and non_speech_score >= non_speech_threshold
                and speech_score <= speech_max
                and non_speech_score >= speech_score + margin
            )
            low_speech_event = (
                has_audio_event_rule(filter_type, "low_speech")
                and speech_score <= speech_max
                and (
                    filter_type == "low_speech"
                    or (not best_is_speech and best_score >= float(preset["low_speech_event"]))
                )
            )
            repeated_non_lexical = (
                has_audio_event_rule(filter_type, "repetition")
                and repetition_score >= float(preset["repetition"])
                and (
                    non_score >= max(0.16, threshold * 0.55)
                    or non_speech_score >= max(0.16, threshold * 0.55)
                    or speech_score <= speech_max
                )
            )

            is_flagged = bool(
                direct_non_lexical
                or direct_non_speech
                or low_speech_event
                or repeated_non_lexical
            )
            chosen_label: str | None = None
            chosen_score: float | None = None
            if direct_non_lexical:
                chosen_label, chosen_score = non_label, float(non_score)
            elif direct_non_speech:
                chosen_label, chosen_score = non_speech_label, float(non_speech_score)
            elif low_speech_event:
                chosen_label = "Low speech probability" if best_is_speech else (best_label or "Low speech probability")
                chosen_score = 1.0 - float(speech_score)
            elif repeated_non_lexical:
                chosen_label = non_label or non_speech_label or "Repetition"
                chosen_score = max(float(repetition_score), float(non_score), float(non_speech_score))

            segment.audio_label = chosen_label
            segment.audio_score = round(float(chosen_score), 4) if chosen_score is not None else None
            segment.speech_score = round(float(speech_score), 4)
            segment.repetition_score = repetition_score
            segment.flagged = is_flagged

        if progress_callback:
            progress_callback(
                {
                    "event": "audio_event_segments",
                    "current": min(batch_start + len(batch), len(segments)),
                    "total": len(segments),
                }
            )
    return segments


def resolve_asr_engine(model_id: str, requested: str = "auto") -> str:
    if requested != "auto":
        return requested
    normalized = str(model_id).lower()
    if "fun-asr" in normalized or "fun_asr" in normalized or "funasr" in normalized:
        return "funasr"
    if "sensevoice" in normalized:
        return "sensevoice"
    if "mimo" in normalized:
        return "mimo"
    if "mega-asr" in normalized or "mega_asr" in normalized:
        return "mega"
    if "qwen3-asr" in normalized or "qwen3_asr" in normalized:
        return "qwen3"
    if "firered" in normalized or "fire-red" in normalized:
        return "fireredasr2"
    return "fireredasr2"


def normalize_sensevoice_language(language: str | None) -> str:
    raw = (language or "auto").strip().lower().replace("_", "-")
    aliases = {
        "": "auto",
        "zh-cn": "zh",
        "zh-hans": "zh",
        "zh-hant": "zh",
        "cmn": "zh",
        "cn": "zh",
        "zn": "zh",
        "jp": "ja",
        "kr": "ko",
    }
    return aliases.get(raw, raw)


def normalize_mega_language(language: str | None) -> str:
    raw = normalize_sensevoice_language(language)
    if raw in {"auto", "nospeech"}:
        return raw
    return MEGA_LANGUAGE_ALIASES.get(raw.lower(), raw)


def normalize_funasr_language(language: str | None) -> str | None:
    raw = normalize_sensevoice_language(language)
    if raw in {"auto", "nospeech"}:
        return None
    prompt_languages = {
        "zh": "中文",
        "cmn": "中文",
        "en": "英文",
        "ja": "日文",
        "yue": "粤语",
        "wuu": "吴语",
        "nan": "闽南语",
        "hak": "客家话",
        "gan": "赣语",
        "hsn": "湘语",
        "cjy": "晋语",
    }
    return prompt_languages.get(raw, raw)


def validate_language_for_engine(args: argparse.Namespace) -> None:
    language = normalize_sensevoice_language(args.language)
    if args.asr_engine in {"mega", "qwen3"}:
        mega_language = normalize_mega_language(language)
        if mega_language in {"auto", "nospeech"} or mega_language in MEGA_LANGUAGE_NAMES:
            return
        allowed = ", ".join(["auto", *MEGA_LANGUAGE_ALIASES.keys()])
        raise RuntimeError(f"--language is not supported by {args.asr_engine}. Use one of: {allowed}.")
    if args.asr_engine == "funasr":
        if language in FUNASR_LANGUAGES:
            return
        allowed = ", ".join(sorted(FUNASR_LANGUAGES))
        raise RuntimeError(f"--language is not supported by Fun-ASR Nano. Use one of: {allowed}.")
    if args.asr_engine == "mimo":
        if language in MIMO_LANGUAGES:
            return
        raise RuntimeError("--language for MiMo must be auto, zh, en, or nospeech.")
    if args.asr_engine == "sensevoice":
        if language in SENSEVOICE_LANGUAGES:
            return
        raise RuntimeError("--language for SenseVoice must be auto, zh, en, yue, ja, ko, or nospeech.")
    if language in SENSEVOICE_LANGUAGES or normalize_mega_language(language) in MEGA_LANGUAGE_NAMES:
        return
    raise RuntimeError("--language is not recognized.")


def apply_generation_defaults_for_engine(args: argparse.Namespace) -> None:
    if args.asr_engine == "mega":
        default_max_tokens = MEGA_DEFAULT_MAX_TOKENS
        default_temperature = MEGA_DEFAULT_TEMPERATURE
        default_top_p = MEGA_DEFAULT_TOP_P
        default_top_k = MEGA_DEFAULT_TOP_K
    elif args.asr_engine == "qwen3":
        default_max_tokens = QWEN3_DEFAULT_MAX_TOKENS
        default_temperature = QWEN3_DEFAULT_TEMPERATURE
        default_top_p = QWEN3_DEFAULT_TOP_P
        default_top_k = QWEN3_DEFAULT_TOP_K
    elif args.asr_engine == "funasr":
        default_max_tokens = FUNASR_DEFAULT_MAX_TOKENS
        default_temperature = FUNASR_DEFAULT_TEMPERATURE
        default_top_p = FUNASR_DEFAULT_TOP_P
        default_top_k = FUNASR_DEFAULT_TOP_K
    else:
        default_max_tokens = MIMO_DEFAULT_MAX_TOKENS
        default_temperature = MIMO_DEFAULT_TEMPERATURE
        default_top_p = MIMO_DEFAULT_TOP_P
        default_top_k = MIMO_DEFAULT_TOP_K

    if getattr(args, "mimo_max_tokens", 0) in {None, 0}:
        args.mimo_max_tokens = default_max_tokens
    if getattr(args, "mimo_temperature", None) is None:
        args.mimo_temperature = default_temperature
    if getattr(args, "mimo_top_p", 0.0) in {None, 0.0}:
        args.mimo_top_p = default_top_p
    if getattr(args, "mimo_top_k", None) is None:
        args.mimo_top_k = default_top_k


def normalize_asr_options(args: argparse.Namespace) -> None:
    model = str(args.model or "").strip()
    if not model:
        model = DEFAULT_MODEL
    args.asr_engine = resolve_asr_engine(
        model,
        str(args.asr_engine or "auto").strip().lower() or "auto",
    )
    args.language = normalize_sensevoice_language(args.language)
    if args.asr_engine == "sensevoice" and model == str(DEFAULT_MODEL):
        model = DEFAULT_SENSEVOICE_MODEL
    if args.asr_engine == "mimo" and model == str(DEFAULT_MODEL):
        model = DEFAULT_MIMO_MODEL
    if args.asr_engine == "mega" and model == str(DEFAULT_MODEL):
        model = DEFAULT_MEGA_MODEL
    if args.asr_engine == "qwen3" and model == str(DEFAULT_MODEL):
        model = DEFAULT_QWEN3_MODEL
    if args.asr_engine == "funasr" and model == str(DEFAULT_MODEL):
        model = DEFAULT_FUNASR_MODEL
    args.model = model
    apply_generation_defaults_for_engine(args)


def validate_subtitle_options(args: argparse.Namespace) -> None:
    if args.max_cue_chars < 0:
        raise RuntimeError("--max-cue-chars must be 0 or greater.")
    if args.max_cue_duration < 0:
        raise RuntimeError("--max-cue-duration must be 0 or greater.")
    if args.min_cue_duration < 0:
        raise RuntimeError("--min-cue-duration must be 0 or greater.")
    if (
        args.max_cue_duration > 0
        and args.min_cue_duration > 0
        and args.min_cue_duration > args.max_cue_duration
    ):
        raise RuntimeError("--min-cue-duration cannot exceed --max-cue-duration.")
    if args.beam_size < 1:
        raise RuntimeError("--beam-size must be 1 or greater.")
    if args.softmax_smoothing <= 0:
        raise RuntimeError("--softmax-smoothing must be greater than 0.")
    if args.length_penalty < 0:
        raise RuntimeError("--length-penalty must be 0 or greater.")
    if args.eos_penalty <= 0:
        raise RuntimeError("--eos-penalty must be greater than 0.")
    if args.decode_max_len < 0:
        raise RuntimeError("--decode-max-len must be 0 or greater.")
    if args.asr_engine not in {"auto", "fireredasr2", "sensevoice", "mimo", "mega", "qwen3", "funasr"}:
        raise RuntimeError("--asr-engine must be auto, fireredasr2, sensevoice, mimo, mega, qwen3, or funasr.")
    if args.vad_engine not in {"auto", "energy", "firered", "pyannote_mlx"}:
        raise RuntimeError("--vad-engine must be auto, energy, firered, or pyannote_mlx.")
    if not 0.0 <= args.firered_vad_threshold <= 1.0:
        raise RuntimeError("--firered-vad-threshold must be between 0 and 1.")
    if args.firered_vad_smooth_window < 1:
        raise RuntimeError("--firered-vad-smooth-window must be 1 or greater.")
    if not 0.0 <= args.pyannote_vad_threshold <= 1.0:
        raise RuntimeError("--pyannote-vad-threshold must be between 0 and 1.")
    if not 0.0 <= args.audio_event_threshold <= 1.0:
        raise RuntimeError("--audio-event-threshold must be between 0 and 1.")
    if normalized_audio_event_filter_type(args.audio_event_filter_type) != args.audio_event_filter_type:
        raise RuntimeError("--audio-event-filter-type must be all, non_lexical, non_speech, repetition, or low_speech.")
    if str(args.audio_event_preset).strip().lower().replace("-", "_") not in AUDIO_EVENT_PRESETS:
        raise RuntimeError("--audio-event-preset must be strict, balanced, or broad.")
    if args.mimo_max_tokens < 1:
        raise RuntimeError("--mimo-max-tokens/--mega-max-tokens/--qwen3-max-tokens/--funasr-max-tokens must be 1 or greater.")
    if args.mimo_temperature < 0:
        raise RuntimeError("--mimo-temperature/--mega-temperature/--qwen3-temperature/--funasr-temperature must be 0 or greater.")
    if not 0.0 < args.mimo_top_p <= 1.0:
        raise RuntimeError("--mimo-top-p/--mega-top-p/--qwen3-top-p/--funasr-top-p must be greater than 0 and at most 1.")
    if args.mimo_top_k < 0:
        raise RuntimeError("--mimo-top-k/--mega-top-k/--qwen3-top-k/--funasr-top-k must be 0 or greater.")
    validate_language_for_engine(args)
    if args.diarization_num_speakers < 0:
        raise RuntimeError("--diarization-num-speakers must be 0 or greater.")
    if args.diarization_min_speakers < 0:
        raise RuntimeError("--diarization-min-speakers must be 0 or greater.")
    if args.diarization_max_speakers < 0:
        raise RuntimeError("--diarization-max-speakers must be 0 or greater.")
    if args.speaker_labeling_engine not in {"acoustic", "coreml", "pyannote", "eres2netv2"}:
        raise RuntimeError(
            "--speaker-labeling-engine must be acoustic, coreml, pyannote, or eres2netv2."
        )
    if getattr(args, "speaker_clustering_method", "auto") not in {
        "auto",
        "spectral",
        "incremental",
    }:
        raise RuntimeError(
            "--speaker-clustering-method must be auto, spectral, or incremental."
        )
    if not -1.0 <= args.speaker_cluster_threshold <= 1.0:
        raise RuntimeError("--speaker-cluster-threshold must be between -1 and 1.")
    if (
        args.diarization_min_speakers > 0
        and args.diarization_max_speakers > 0
        and args.diarization_min_speakers > args.diarization_max_speakers
    ):
        raise RuntimeError("--diarization-min-speakers cannot exceed --diarization-max-speakers.")


def clean_text(text: str) -> str:
    text = re.sub(r"<\|[^|>]+?\|>", " ", text)
    text = re.sub(r"\btoken_\d+\b", " ", text, flags=re.IGNORECASE)
    return " ".join(text.replace("\n", " ").split()).strip()


def split_text_by_length(text: str, max_chars: int) -> list[str]:
    text = text.strip()
    if max_chars <= 0 or len(text) <= max_chars:
        return [text] if text else []

    break_chars = "，。！？；、,.!?;:： "
    chunks: list[str] = []
    remaining = text
    while len(remaining) > max_chars:
        low = max(1, int(max_chars * 0.55))
        high = min(len(remaining), max_chars + 1)
        split_at = -1
        for i in range(high - 1, low - 1, -1):
            if remaining[i - 1] in break_chars:
                split_at = i
                break
        if split_at < 0:
            split_at = max_chars
        chunk = remaining[:split_at].strip()
        if chunk:
            chunks.append(chunk)
        remaining = remaining[split_at:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks


def split_text_by_parts(text: str, parts: int) -> list[str]:
    text = text.strip()
    if parts <= 1 or len(text) <= 1:
        return [text] if text else []

    break_chars = "，。！？；、,.!?;:： "
    chunks: list[str] = []
    remaining = text
    remaining_parts = parts

    while remaining_parts > 1 and len(remaining) > 1:
        target = max(1, round(len(remaining) / remaining_parts))
        left = max(1, int(target * 0.65))
        right = min(len(remaining) - 1, int(target * 1.35))
        split_at = -1
        for i in range(target, right + 1):
            if remaining[i - 1] in break_chars:
                split_at = i
                break
        if split_at < 0:
            for i in range(target, left - 1, -1):
                if remaining[i - 1] in break_chars:
                    split_at = i
                    break
        if split_at < 0:
            split_at = min(target, len(remaining) - 1)

        chunk = remaining[:split_at].strip()
        if chunk:
            chunks.append(chunk)
        remaining = remaining[split_at:].strip()
        remaining_parts -= 1

    if remaining:
        chunks.append(remaining)
    return chunks


def split_text_for_subtitles(text: str, max_chars: int, target_parts: int) -> list[str]:
    if target_parts <= 1:
        return split_text_by_length(text, max_chars)

    chunks = split_text_by_parts(text, target_parts)
    if max_chars <= 0:
        return chunks

    refined: list[str] = []
    for chunk in chunks:
        refined.extend(split_text_by_length(chunk, max_chars))
    return refined


def split_cue(cue: Cue, args: argparse.Namespace) -> list[Cue]:
    text = clean_text(cue.text)
    if not text:
        return []
    if cue.end <= cue.start:
        return [
            Cue(
                index=1,
                start=cue.start,
                end=cue.end,
                text=text,
                confidence=cue.confidence,
                speaker=cue.speaker,
                language=cue.language,
                emotion=cue.emotion,
                event=cue.event,
                words=cue.words,
            )
        ]

    duration = cue.end - cue.start
    by_chars = (
        math.ceil(len(text) / args.max_cue_chars) if args.max_cue_chars > 0 else 1
    )
    by_duration = (
        math.ceil(duration / args.max_cue_duration)
        if args.max_cue_duration > 0
        else 1
    )
    target_parts = max(1, by_chars, by_duration)
    if args.min_cue_duration > 0 and duration >= args.min_cue_duration:
        max_parts = max(1, int(duration / args.min_cue_duration))
        target_parts = min(target_parts, max_parts)

    chunks = split_text_for_subtitles(text, args.max_cue_chars, target_parts)
    if len(chunks) <= 1:
        return [
            Cue(
                index=1,
                start=cue.start,
                end=cue.end,
                text=text,
                confidence=cue.confidence,
                speaker=cue.speaker,
                language=cue.language,
                emotion=cue.emotion,
                event=cue.event,
                words=cue.words,
            )
        ]

    word_slices = word_split_slices(cue.words, chunks)
    total_weight = sum(max(1, len(chunk)) for chunk in chunks)
    cursor = cue.start
    split_cues: list[Cue] = []
    for index, chunk in enumerate(chunks, 1):
        if index == len(chunks):
            end = cue.end
        elif word_slices is not None:
            end = min(cue.end, max(cursor, word_slices[index - 1][-1][2]))
        else:
            weight = max(1, len(chunk))
            end = cursor + duration * weight / total_weight
            end = min(cue.end, end)
        split_cues.append(
            Cue(
                index=1,
                start=round(cursor, 3),
                end=round(end, 3),
                text=chunk,
                confidence=cue.confidence,
                speaker=cue.speaker,
                language=cue.language,
                emotion=cue.emotion,
                event=cue.event,
                words=word_slices[index - 1] if word_slices else None,
            )
        )
        cursor = end
    return split_cues


def split_cues(cues: list[Cue], args: argparse.Namespace) -> list[Cue]:
    split: list[Cue] = []
    for cue in cues:
        split.extend(split_cue(cue, args))

    for index, cue in enumerate(split, 1):
        cue.index = index
    return split


def wrap_subtitle_text(text: str, max_chars_per_line: int) -> str:
    if max_chars_per_line <= 0 or len(text) <= max_chars_per_line:
        return text

    break_chars = "，。！？；、,.!?;:： "
    lines = []
    remaining = text.strip()
    while len(remaining) > max_chars_per_line:
        split_at = -1
        low = max(1, max_chars_per_line // 2)
        high = min(len(remaining), max_chars_per_line + 1)
        for i in range(high - 1, low - 1, -1):
            if remaining[i - 1] in break_chars:
                split_at = i
                break
        if split_at < 0:
            split_at = max_chars_per_line
        lines.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    if remaining:
        lines.append(remaining)
    return "\n".join(line for line in lines if line)


def confidence_from_result(result) -> float | None:
    segments = getattr(result, "segments", None)
    if not segments:
        return None
    confidence = segments[0].get("confidence")
    return float(confidence) if confidence is not None else None


def clean_metadata_label(value) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    text = re.sub(r"^<\|(.+?)\|>$", r"\1", text).strip()
    text = text.strip("[](){}\"'` \t\r\n")
    if not text or re.fullmatch(r"token_\d+", text, flags=re.IGNORECASE):
        return None
    return text


def normalize_sensevoice_emotion(value, default: str | None = None) -> str | None:
    text = clean_metadata_label(value)
    if not text:
        return default
    key = text.lower().replace("-", "_").replace(" ", "_")
    aliases = {
        "happiness": "happy",
        "joy": "happy",
        "anger": "angry",
        "fear": "fearful",
        "disgust": "disgusted",
        "surprise": "surprised",
        "unknown": "other",
    }
    key = aliases.get(key, key)
    return key if key in EMOTION_EMOJI else default


AUDIO_EVENT_ALIASES = {
    "speech": "Speech",
    "applause": "Applause",
    "clapping": "Applause",
    "bgm": "BGM",
    "music": "BGM",
    "laughter": "Laughter",
    "laugh": "Laughter",
    "cry": "Cry",
    "crying": "Cry",
    "sneeze": "Sneeze",
    "sneezing": "Sneeze",
    "breath": "Breath",
    "breathing": "Breath",
    "cough": "Cough",
    "coughing": "Cough",
    "noise": "Noise",
}


def normalize_audio_event(value) -> str | None:
    text = clean_metadata_label(value)
    if not text:
        return None
    key = text.lower().replace("-", " ").replace("_", " ")
    key = " ".join(key.split())
    compact_key = key.replace(" ", "")
    if compact_key in AUDIO_EVENT_ALIASES:
        return AUDIO_EVENT_ALIASES[compact_key]
    if key in AUDIO_EVENT_ALIASES:
        return AUDIO_EVENT_ALIASES[key]
    return None


def metadata_from_result(result) -> dict[str, str | None]:
    segments = getattr(result, "segments", None) or []
    first = segments[0] if segments and isinstance(segments[0], dict) else {}
    return {
        "language": getattr(result, "language", None) or first.get("language"),
        "emotion": normalize_sensevoice_emotion(first.get("emotion")),
        "event": normalize_audio_event(first.get("event")),
    }


def speaker_from_result(result) -> str | None:
    segments = getattr(result, "segments", None) or []
    first = segments[0] if segments and isinstance(segments[0], dict) else {}
    speaker = first.get("speaker") or first.get("speaker_id") or first.get("speaker_label")
    return str(speaker) if speaker is not None else None


def should_use_aux_emotion_model(args: argparse.Namespace) -> bool:
    engine = resolve_asr_engine(args.model, args.asr_engine)
    try:
        from .emotion_mlx import looks_like_emotion_mlx_model
    except ImportError:
        has_mlx_emotion_model = False
    else:
        has_mlx_emotion_model = looks_like_emotion_mlx_model(args.emotion_model)
    return (
        bool(args.sensevoice_rich_info)
        and engine != "sensevoice"
        and (has_mlx_emotion_model or torch_extras_enabled())
    )


def funasr_import_error(feature: str, exc: ImportError) -> RuntimeError:
    return RuntimeError(
        f"{feature} requires FunASR. Install it in the backend environment with: "
        "UV_CACHE_DIR=.uv-cache uv pip install funasr modelscope"
    )


def run_quietly(callable_obj):
    stdout = io.StringIO()
    stderr = io.StringIO()
    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
        return callable_obj()


def transcribe_sensevoice_metadata(model, audio_path: Path, args: argparse.Namespace):
    language = normalize_sensevoice_language(args.language)
    return model.generate(
        str(audio_path),
        language=language,
        use_itn=bool(args.use_itn),
    )


def load_emotion_model(model_id: str):
    try:
        from .emotion_mlx import load_emotion_mlx_model, looks_like_emotion_mlx_model
    except ImportError:
        load_emotion_mlx_model = None
        looks_like_emotion_mlx_model = None

    if looks_like_emotion_mlx_model is not None and looks_like_emotion_mlx_model(model_id):
        if load_emotion_mlx_model is None:
            raise RuntimeError("MLX emotion recognition is not available in this backend.")
        return load_emotion_mlx_model(model_id)

    if not torch_extras_enabled():
        raise RuntimeError(
            "The configured emotion model is a legacy FunASR/torch model. "
            "Use emotion2vec-plus-large-mlx or enable torch extras."
        )

    try:
        # Python 3.12 removed stdlib distutils. When the macOS bundle runs from
        # the embedded runtime with site-packages on PYTHONPATH, setuptools'
        # distutils shim is not activated by .pth processing. Importing
        # setuptools explicitly lets FunASR register emotion2vec models.
        import setuptools  # noqa: F401
        from funasr import AutoModel
    except ImportError as exc:
        raise funasr_import_error("emotion2vec emotion recognition", exc) from exc

    kwargs: dict[str, object] = {"disable_update": True}
    if str(model_id).startswith("emotion2vec/"):
        kwargs["hub"] = "hf"
    device = os.getenv("MSUB_EMOTION_DEVICE", "cpu").strip()
    if device:
        kwargs["device"] = device
    try:
        return run_quietly(lambda: AutoModel(model=model_id, **kwargs))
    except Exception as exc:  # noqa: BLE001 - add setup context.
        raise RuntimeError(
            f"Could not load emotion model {model_id!r}. Set MSUB_EMOTION_MODEL "
            "to a local emotion2vec path or ensure the model can be downloaded."
        ) from exc


def normalize_emotion2vec_label(value) -> str | None:
    text = clean_metadata_label(value)
    if not text:
        return None
    if "/" in text:
        text = text.split("/")[-1]
    if text == "<unk>":
        text = "other"
    if text == "unknown":
        text = "other"
    return normalize_sensevoice_emotion(text, default=None)


def emotion_metadata_from_result(result) -> dict[str, str | None]:
    item = result[0] if isinstance(result, list) and result else result
    if not isinstance(item, dict):
        return {"emotion": None, "event": None}

    direct = (
        item.get("emotion")
        or item.get("label")
        or item.get("pred")
        or item.get("prediction")
    )
    if direct is not None:
        return {"emotion": normalize_emotion2vec_label(direct), "event": None}

    labels = item.get("labels")
    scores = item.get("scores")
    if isinstance(labels, list) and labels:
        if isinstance(scores, list) and len(scores) == len(labels):
            best_index = max(range(len(labels)), key=lambda idx: float(scores[idx]))
        else:
            best_index = 0
        return {"emotion": normalize_emotion2vec_label(labels[best_index]), "event": None}

    return {"emotion": None, "event": None}


def transcribe_emotion_metadata(model, audio_path: Path, args: argparse.Namespace):
    try:
        result = run_quietly(
            lambda: model.generate(
                input=str(audio_path),
                granularity="utterance",
                extract_embedding=False,
            )
        )
    except TypeError:
        result = run_quietly(
            lambda: model.generate(
                str(audio_path),
                granularity="utterance",
                extract_embedding=False,
            )
        )
    return emotion_metadata_from_result(result)


def denoise_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "denoise", False))


@lru_cache(maxsize=1)
def load_denoise_model(model_id: str):
    from mlx_audio.sts.models.deepfilternet import DeepFilterNetModel

    return DeepFilterNetModel.from_pretrained(model_id)


def denoise_audio_for_run(
    source_path: Path,
    target_path: Path,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> bool:
    """Extract 48 kHz audio, denoise with DeepFilterNet, resample to 16 kHz.

    Best-effort: returns False on any failure so the caller falls back to the
    plain extraction path with the original audio.
    """
    try:
        model = load_denoise_model(getattr(args, "denoise_model", DEFAULT_DENOISE_MODEL))
    except Exception as exc:  # noqa: BLE001 - denoising is an optional refinement.
        if getattr(args, "verbose", False):
            print(f"denoise model unavailable: {exc}", file=sys.stderr)
        if progress_callback:
            progress_callback({"event": "denoise_unavailable", "error": str(exc)})
        return False
    try:
        if progress_callback:
            progress_callback({"event": "denoise_start"})
        with tempfile.TemporaryDirectory(prefix="msub-denoise-") as tmp:
            source_48k = Path(tmp) / "source-48k.wav"
            enhanced_48k = Path(tmp) / "enhanced-48k.wav"
            extract_audio(source_path, source_48k, sample_rate=48000)
            model.enhance_file(source_48k, enhanced_48k)
            extract_audio(enhanced_48k, target_path)
        if progress_callback:
            progress_callback({"event": "denoise_done"})
        return True
    except Exception as exc:  # noqa: BLE001 - denoising is an optional refinement.
        if getattr(args, "verbose", False):
            print(f"denoise failed, using original audio: {exc}", file=sys.stderr)
        if progress_callback:
            progress_callback({"event": "denoise_unavailable", "error": str(exc)})
        target_path.unlink(missing_ok=True)
        return False


def punctuation_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "punctuate", False))


@lru_cache(maxsize=1)
def load_punc_model(model_id: str):
    try:
        from fireredasr2s.fireredpunc.punc import FireRedPunc, FireRedPuncConfig
    except ImportError as exc:
        raise RuntimeError(
            "FireRedPunc requires the optional 'punc' dependencies (Python 3.11+). "
            "Run: UV_CACHE_DIR=.uv-cache uv sync --extra punc"
        ) from exc

    model_path = Path(str(model_id)).expanduser()
    if not model_path.exists():
        from huggingface_hub import snapshot_download

        model_path = Path(snapshot_download(repo_id=str(model_id)))
    return FireRedPunc.from_pretrained(str(model_path), FireRedPuncConfig(use_gpu=False))


def apply_punctuation(
    cues: list[Cue],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Cue]:
    """Restore punctuation on cue texts with FireRedPunc (opt-in).

    Runs one batched CPU pass over all cue texts. Any failure leaves the
    cues untouched so punctuation can never break transcription output.
    """
    if not punctuation_enabled(args) or not cues:
        return cues
    try:
        if progress_callback:
            progress_callback({"event": "punctuation_start", "total": len(cues)})
        model = load_punc_model(getattr(args, "punc_model", DEFAULT_PUNC_MODEL))
        results = model.process([cue.text for cue in cues])
    except Exception as exc:  # noqa: BLE001 - punctuation is an optional refinement.
        if getattr(args, "verbose", False):
            print(f"skip punctuation restoration: {exc}", file=sys.stderr)
        if progress_callback:
            progress_callback({"event": "punctuation_unavailable", "error": str(exc)})
        return cues
    for cue, result in zip(cues, results):
        punc_text = str((result or {}).get("punc_text") or "").strip()
        if punc_text:
            cue.text = punc_text
    if progress_callback:
        progress_callback({"event": "punctuation_done", "total": len(cues)})
    return cues


def diarization_token() -> str | None:
    for name in ("MSUB_DIARIZATION_TOKEN", "PYANNOTE_AUTH_TOKEN", "HF_TOKEN", "HUGGINGFACE_TOKEN"):
        value = os.getenv(name)
        if value:
            return value
    return None


def load_diarization_pipeline(model_id: str):
    try:
        from pyannote.audio import Pipeline
    except ImportError as exc:
        raise RuntimeError(
            "Speaker diarization requires pyannote.audio. "
            "Install it in the backend environment with: "
            "UV_CACHE_DIR=.uv-cache uv pip install pyannote.audio"
        ) from exc

    kwargs = {}
    token = diarization_token()
    if token:
        kwargs["token"] = token
    try:
        pipeline = Pipeline.from_pretrained(model_id, **kwargs)
    except Exception as exc:  # noqa: BLE001 - add actionable setup context.
        raise RuntimeError(
            "Could not load speaker diarization model. Accept the model conditions "
            "and set HF_TOKEN/PYANNOTE_AUTH_TOKEN, or set MSUB_DIARIZATION_MODEL "
            "to a local pyannote pipeline path."
        ) from exc

    device = os.getenv("MSUB_DIARIZATION_DEVICE", "cpu").strip()
    if device and device.lower() != "cpu":
        try:
            import torch

            pipeline.to(torch.device(device))
        except Exception as exc:  # noqa: BLE001 - device selection is optional.
            raise RuntimeError(f"Could not move diarization pipeline to {device!r}.") from exc

    return pipeline


def diarization_kwargs(args: argparse.Namespace) -> dict[str, int]:
    if args.diarization_num_speakers > 0:
        return {"num_speakers": args.diarization_num_speakers}

    kwargs: dict[str, int] = {}
    if args.diarization_min_speakers > 0:
        kwargs["min_speakers"] = args.diarization_min_speakers
    if args.diarization_max_speakers > 0:
        kwargs["max_speakers"] = args.diarization_max_speakers
    return kwargs


def iter_diarization_turns(output) -> list[tuple[float, float, str]]:
    annotation = (
        getattr(output, "exclusive_speaker_diarization", None)
        or getattr(output, "speaker_diarization", None)
        or output
    )
    turns: list[tuple[float, float, str]] = []

    itertracks = getattr(annotation, "itertracks", None)
    if callable(itertracks):
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            turns.append((float(turn.start), float(turn.end), str(speaker)))
        return turns

    for item in annotation:
        try:
            values = tuple(item)
        except TypeError:
            continue
        if len(values) == 2:
            turn, speaker = values
        elif len(values) >= 3:
            turn, speaker = values[0], values[-1]
        else:
            continue
        turns.append((float(turn.start), float(turn.end), str(speaker)))
    return turns


def relabel_speakers(turns: list[tuple[float, float, str]]) -> dict[str, str]:
    labels: dict[str, str] = {}
    for _, _, speaker in sorted(turns, key=lambda item: (item[0], item[1])):
        if speaker not in labels:
            labels[speaker] = f"Speaker {len(labels) + 1}"
    return labels


def load_speaker_recognition_model(model_id: str):
    try:
        import setuptools  # noqa: F401
        from funasr import AutoModel
    except ImportError as exc:
        raise funasr_import_error("ERes2NetV2 speaker recognition", exc) from exc

    kwargs: dict[str, object] = {"disable_update": True}
    device = os.getenv("MSUB_SPEAKER_RECOGNITION_DEVICE", "cpu").strip()
    if device:
        kwargs["device"] = device
    try:
        return run_quietly(lambda: AutoModel(model=model_id, **kwargs))
    except Exception as exc:  # noqa: BLE001 - add setup context.
        raise RuntimeError(
            f"Could not load speaker recognition model {model_id!r}. "
            "Set MSUB_SPEAKER_RECOGNITION_MODEL to a local model path or ensure "
            "ModelScope downloads are available."
        ) from exc


def speaker_embedding_from_result(result):
    import numpy as np

    item = result[0] if isinstance(result, list) and result else result
    if not isinstance(item, dict):
        raise RuntimeError("Speaker recognition result did not contain an embedding.")
    embedding = None
    for key in ("spk_embedding", "embedding", "emb", "feats"):
        if key in item and item[key] is not None:
            embedding = item[key]
            break
    if embedding is None:
        raise RuntimeError("Speaker recognition result did not contain spk_embedding.")
    vector = np.asarray(embedding, dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(vector))
    if norm <= 0:
        raise RuntimeError("Speaker recognition returned an empty embedding.")
    return vector / norm


def generate_speaker_embedding(model, audio_path: Path):
    try:
        result = run_quietly(lambda: model.generate(input=str(audio_path)))
    except TypeError:
        result = run_quietly(lambda: model.generate(str(audio_path)))
    return speaker_embedding_from_result(result)


@lru_cache(maxsize=1)
def load_speaker_coreml_models(model_dir: str):
    root = Path(model_dir).expanduser()
    fbank_package = resolve_speaker_coreml_package(root, "Fbank")
    embedding_package = resolve_speaker_coreml_package(root, "Embedding")
    if not (fbank_package.exists() and embedding_package.exists()):
        raise RuntimeError(
            f"Speaker CoreML model is incomplete: {root}. "
            "Expected mlpackages/Fbank.mlpackage and mlpackages/Embedding.mlpackage."
        )
    return (
        load_coreml_model_package(
            str(fbank_package),
            "Speaker diarization CoreML Fbank",
        ),
        load_coreml_model_package(
            str(embedding_package),
            "Speaker diarization CoreML Embedding",
        ),
    )


def coreml_prediction_array(prediction: dict, key: str):
    import numpy as np

    value = prediction.get(key)
    if value is None:
        if len(prediction) == 1:
            value = next(iter(prediction.values()))
        else:
            raise RuntimeError(f"CoreML prediction did not include {key!r}.")
    return np.asarray(value, dtype=np.float32)


def coreml_predict_quietly(model, inputs: dict):
    with contextlib.redirect_stderr(io.StringIO()):
        return model.predict(inputs)


def speaker_coreml_window_starts(sample_count: int, window_samples: int) -> list[int]:
    import numpy as np

    if sample_count <= window_samples:
        return [0]

    starts = list(range(0, max(1, sample_count - window_samples + 1), window_samples))
    tail_start = max(0, sample_count - window_samples)
    if not starts or starts[-1] != tail_start:
        starts.append(tail_start)

    max_windows = max(1, env_int("MSUB_COREML_SPEAKER_MAX_WINDOWS", 6))
    if len(starts) <= max_windows:
        return starts
    sampled = np.linspace(0, tail_start, num=max_windows)
    return sorted({int(round(value)) for value in sampled.tolist()})


def speaker_coreml_embedding_for_audio(audio, sample_rate: int, models):
    import numpy as np

    if sample_rate != 16000:
        raise RuntimeError("Speaker CoreML embedding expects 16 kHz mono audio.")

    fbank_model, embedding_model = models
    window_samples = 160000
    weight_frames = 589
    chunk = np.asarray(audio, dtype=np.float32).reshape(-1)
    if chunk.size <= 0:
        chunk = np.zeros(max(1, int(sample_rate * 0.2)), dtype=np.float32)

    embeddings = []
    for start in speaker_coreml_window_starts(chunk.size, window_samples):
        valid = min(window_samples, max(0, chunk.size - start))
        window = np.zeros(window_samples, dtype=np.float32)
        if valid > 0:
            window[:valid] = chunk[start : start + valid]
        fbank_result = coreml_predict_quietly(
            fbank_model,
            {"audio": window.reshape(1, 1, window_samples)},
        )
        fbank_features = coreml_prediction_array(fbank_result, "fbank_features")
        weights = np.zeros((1, weight_frames), dtype=np.float32)
        active_frames = max(
            1,
            min(weight_frames, int(math.ceil((valid / window_samples) * weight_frames))),
        )
        weights[:, :active_frames] = 1.0
        embedding_result = coreml_predict_quietly(
            embedding_model,
            {
                "fbank_features": fbank_features,
                "weights": weights,
            },
        )
        embedding = coreml_prediction_array(embedding_result, "embedding").reshape(-1)
        norm = float(np.linalg.norm(embedding))
        if norm > 1e-8:
            embeddings.append(embedding / norm)

    if not embeddings:
        raise RuntimeError("Speaker CoreML embedding returned an empty vector.")
    vector = np.mean(np.vstack(embeddings), axis=0).astype(np.float32)
    norm = float(np.linalg.norm(vector))
    if norm <= 1e-8:
        raise RuntimeError("Speaker CoreML embedding returned an empty vector.")
    return vector / norm


def speaker_labels_from_assignments(assignments: list[int]) -> list[str]:
    label_ids: dict[int, int] = {}
    labels: list[str] = []
    for assignment in assignments:
        if assignment not in label_ids:
            label_ids[assignment] = len(label_ids) + 1
        labels.append(f"Speaker {label_ids[assignment]}")
    return labels


def cluster_speaker_embeddings_incremental(
    embeddings: list,
    args: argparse.Namespace,
) -> list[str]:
    import numpy as np

    if not embeddings:
        return []
    centroids: list = []
    counts: list[int] = []
    assignments: list[int] = []
    max_speakers = max(0, int(args.diarization_num_speakers))
    threshold = float(args.speaker_cluster_threshold)

    for embedding in embeddings:
        if not centroids:
            centroids.append(embedding)
            counts.append(1)
            assignments.append(0)
            continue

        similarities = [float(np.dot(embedding, centroid)) for centroid in centroids]
        best_index = int(max(range(len(similarities)), key=similarities.__getitem__))
        can_create = max_speakers <= 0 or len(centroids) < max_speakers
        if similarities[best_index] < threshold and can_create:
            centroids.append(embedding)
            counts.append(1)
            assignments.append(len(centroids) - 1)
            continue

        assignments.append(best_index)
        counts[best_index] += 1
        centroid = centroids[best_index] * (counts[best_index] - 1) + embedding
        norm = float(np.linalg.norm(centroid))
        centroids[best_index] = centroid / norm if norm > 0 else embedding

    return speaker_labels_from_assignments(assignments)


def speaker_count_bounds(args: argparse.Namespace, segment_count: int) -> tuple[int, int]:
    min_speakers = max(1, int(getattr(args, "diarization_min_speakers", 0) or 0))
    max_speakers = int(getattr(args, "diarization_max_speakers", 0) or 0)
    max_speakers = segment_count if max_speakers <= 0 else max_speakers
    min_speakers = min(min_speakers, segment_count)
    max_speakers = min(max(min_speakers, max_speakers), segment_count)
    return min_speakers, max_speakers


def clamp_speaker_count(count: int, args: argparse.Namespace, segment_count: int) -> int:
    min_speakers, max_speakers = speaker_count_bounds(args, segment_count)
    return min(max(int(count), min_speakers), max_speakers)


def connected_component_count(similarity, threshold: float) -> int:
    import numpy as np

    segment_count = int(similarity.shape[0])
    if segment_count <= 1:
        return segment_count

    adjacency = np.asarray(similarity >= threshold, dtype=bool)
    np.fill_diagonal(adjacency, True)
    visited = np.zeros(segment_count, dtype=bool)
    components = 0
    for start in range(segment_count):
        if visited[start]:
            continue
        components += 1
        stack = [start]
        visited[start] = True
        while stack:
            current = stack.pop()
            neighbors = np.flatnonzero(adjacency[current] & ~visited)
            for neighbor in neighbors.tolist():
                visited[neighbor] = True
                stack.append(int(neighbor))
    return components


def estimate_spectral_speaker_count(
    similarity,
    args: argparse.Namespace,
) -> int:
    segment_count = int(similarity.shape[0])
    known_speakers = max(0, int(getattr(args, "diarization_num_speakers", 0) or 0))
    if known_speakers > 0:
        return min(known_speakers, segment_count)

    threshold = float(getattr(args, "speaker_cluster_threshold", 0.45))
    estimated = connected_component_count(similarity, threshold)
    return clamp_speaker_count(estimated, args, segment_count)


def deterministic_kmeans(points, cluster_count: int) -> list[int]:
    import numpy as np

    item_count = int(points.shape[0])
    if cluster_count <= 1 or item_count <= 1:
        return [0] * item_count

    centers = [points[0]]
    for _ in range(1, cluster_count):
        distances = np.min(
            np.stack([np.sum((points - center) ** 2, axis=1) for center in centers]),
            axis=0,
        )
        centers.append(points[int(np.argmax(distances))])
    centers = np.asarray(centers, dtype=np.float32)

    assignments = np.zeros(item_count, dtype=np.int32)
    for _ in range(50):
        distances = np.stack(
            [np.sum((points - center) ** 2, axis=1) for center in centers]
        )
        next_assignments = np.argmin(distances, axis=0).astype(np.int32)
        if np.array_equal(next_assignments, assignments):
            break
        assignments = next_assignments
        for cluster_index in range(cluster_count):
            members = points[assignments == cluster_index]
            if len(members):
                centers[cluster_index] = np.mean(members, axis=0)

    return [int(value) for value in assignments.tolist()]


def cluster_speaker_embeddings_spectral(
    embeddings: list,
    args: argparse.Namespace,
) -> list[str]:
    import numpy as np

    if not embeddings:
        return []
    if len(embeddings) == 1:
        return ["Speaker 1"]

    matrix = np.vstack(embeddings).astype(np.float32)
    similarity = np.clip(matrix @ matrix.T, -1.0, 1.0)
    cluster_count = estimate_spectral_speaker_count(similarity, args)
    if cluster_count <= 1:
        return ["Speaker 1"] * len(embeddings)

    affinity = np.clip((similarity + 1.0) * 0.5, 0.0, 1.0)
    np.fill_diagonal(affinity, 1.0)
    degree = np.sum(affinity, axis=1)
    degree[degree <= 1e-8] = 1e-8
    normalized_affinity = affinity / np.sqrt(np.outer(degree, degree))

    _, eigenvectors = np.linalg.eigh(normalized_affinity)
    spectral_features = eigenvectors[:, -cluster_count:].astype(np.float32)
    row_norms = np.linalg.norm(spectral_features, axis=1, keepdims=True)
    row_norms[row_norms <= 1e-8] = 1.0
    spectral_features = spectral_features / row_norms

    assignments = deterministic_kmeans(spectral_features, cluster_count)
    return speaker_labels_from_assignments(assignments)


def cluster_speaker_embeddings(embeddings: list, args: argparse.Namespace) -> list[str]:
    method = getattr(args, "speaker_clustering_method", "auto")
    method = str(method or "auto").lower()
    if method in {"auto", "spectral"}:
        try:
            return cluster_speaker_embeddings_spectral(embeddings, args)
        except Exception as exc:  # noqa: BLE001 - keep transcription usable.
            engine = resolved_speaker_labeling_engine(args)
            print(
                f"{engine} spectral clustering failed; falling back to incremental: {exc}",
                file=sys.stderr,
            )

    return cluster_speaker_embeddings_incremental(embeddings, args)


def acoustic_speaker_cluster_args(args: argparse.Namespace) -> argparse.Namespace:
    cluster_args = copy.copy(args)
    threshold = float(getattr(args, "speaker_cluster_threshold", 0.45) or 0.45)
    if threshold <= 0.5:
        threshold = env_float("MSUB_ACOUSTIC_SPEAKER_CLUSTER_THRESHOLD", 0.82)
    cluster_args.speaker_cluster_threshold = max(0.0, min(1.0, threshold))
    return cluster_args


def frame_rms_features(audio, sample_rate: int):
    import numpy as np

    frame = max(1, int(sample_rate * 0.025))
    hop = max(1, int(sample_rate * 0.01))
    if audio.size < frame:
        return np.zeros((0, 1), dtype=np.float32)
    values = []
    for start in range(0, max(1, audio.size - frame + 1), hop):
        window = audio[start : start + frame]
        if window.size < frame:
            break
        values.append(float(np.sqrt(np.mean(window * window) + 1e-12)))
    return np.asarray(values, dtype=np.float32).reshape(-1, 1)


def acoustic_fbank_features(audio, sample_rate: int):
    import numpy as np

    if audio.size <= 0:
        return np.zeros((0, 80), dtype=np.float32)
    try:
        import kaldi_native_fbank as knf

        opts = knf.FbankOptions()
        opts.frame_opts.samp_freq = sample_rate
        opts.frame_opts.frame_length_ms = 25
        opts.frame_opts.frame_shift_ms = 10
        opts.frame_opts.dither = 0.0
        opts.frame_opts.snip_edges = True
        opts.mel_opts.num_bins = 80
        opts.mel_opts.debug_mel = False
        fbank = knf.OnlineFbank(opts)
        fbank.accept_waveform(sample_rate, audio.tolist())
        if fbank.num_frames_ready > 0:
            return np.vstack(
                [fbank.get_frame(index) for index in range(fbank.num_frames_ready)]
            ).astype(np.float32)
    except Exception:
        pass
    return frame_rms_features(audio.astype(np.float32), sample_rate)


@lru_cache(maxsize=16)
def acoustic_dct_matrix(input_dim: int, output_dim: int):
    import numpy as np

    input_dim = max(1, int(input_dim))
    output_dim = max(1, min(int(output_dim), input_dim))
    n = np.arange(input_dim, dtype=np.float32)
    k = np.arange(output_dim, dtype=np.float32).reshape(-1, 1)
    matrix = np.cos((np.pi / input_dim) * (n + 0.5) * k).astype(np.float32)
    matrix[0, :] *= np.sqrt(1.0 / input_dim)
    if output_dim > 1:
        matrix[1:, :] *= np.sqrt(2.0 / input_dim)
    return matrix


def informative_acoustic_frames(features):
    import numpy as np

    if features.shape[0] < 8:
        return features
    energy = np.mean(features, axis=1)
    energy = np.nan_to_num(energy, nan=0.0, posinf=0.0, neginf=0.0)
    floor = float(np.percentile(energy, 20))
    mask = energy >= floor
    if int(np.count_nonzero(mask)) < max(4, features.shape[0] // 3):
        return features
    return features[mask]


def acoustic_summary_stats(features):
    import numpy as np

    if features.size == 0:
        return np.zeros(1, dtype=np.float32)
    return np.concatenate(
        [
            np.mean(features, axis=0),
            np.std(features, axis=0),
            np.median(features, axis=0),
            np.percentile(features, 10, axis=0),
            np.percentile(features, 90, axis=0),
        ]
    ).astype(np.float32)


def acoustic_temporal_pool(features, parts: int = 3):
    import numpy as np

    if features.size == 0:
        return np.zeros(1, dtype=np.float32)
    chunks = np.array_split(features, max(1, int(parts)), axis=0)
    pooled = [
        np.mean(chunk, axis=0) if chunk.size else np.zeros(features.shape[1], dtype=np.float32)
        for chunk in chunks
    ]
    return np.concatenate(pooled).astype(np.float32)


def acoustic_embedding_from_frames(frames):
    import numpy as np

    if frames.size == 0:
        return np.zeros(1, dtype=np.float32)
    features = np.asarray(frames, dtype=np.float32)
    if features.ndim == 1:
        features = features.reshape(-1, 1)
    features = np.nan_to_num(features, nan=0.0, posinf=0.0, neginf=0.0)
    features = informative_acoustic_frames(features)

    if features.shape[1] > 1:
        cepstral_dim = min(24, features.shape[1])
        dct = acoustic_dct_matrix(features.shape[1], cepstral_dim)
        features = features @ dct.T

    deltas = np.diff(features, axis=0) if features.shape[0] > 1 else np.zeros_like(features)
    vector = np.concatenate(
        [
            acoustic_summary_stats(features),
            np.mean(deltas, axis=0).astype(np.float32),
            np.std(deltas, axis=0).astype(np.float32),
            acoustic_temporal_pool(features, parts=3),
        ]
    ).astype(np.float32)
    vector = np.nan_to_num(vector, nan=0.0, posinf=0.0, neginf=0.0)
    vector -= float(np.mean(vector))
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 1e-8 else vector


def assign_speakers_with_acoustic_features(
    audio_path: Path,
    segments: list[Segment],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    if not segments:
        return segments
    try:
        import numpy as np
        import soundfile as sf
    except ImportError as exc:
        raise RuntimeError(
            "Acoustic speaker labeling requires numpy and soundfile in the backend environment."
        ) from exc

    if progress_callback:
        progress_callback(
            {
                "event": "speaker_recognition_start",
                "model": "acoustic",
                "total": len(segments),
            }
        )

    audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
    audio = np.asarray(audio, dtype=np.float32)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)

    embeddings = []
    for segment in segments:
        start = max(0, int(segment.start * sample_rate))
        end = min(audio.size, max(start + 1, int(segment.end * sample_rate)))
        chunk = audio[start:end]
        if chunk.size < int(sample_rate * 0.2):
            chunk = np.pad(chunk, (0, max(1, int(sample_rate * 0.2) - chunk.size)))
        frames = acoustic_fbank_features(chunk, sample_rate)
        embeddings.append(acoustic_embedding_from_frames(frames))
        if progress_callback:
            progress_callback(
                {
                    "event": "speaker_recognition_segment",
                    "index": segment.index,
                    "total": len(segments),
                }
            )

    speaker_names = cluster_speaker_embeddings(
        embeddings,
        acoustic_speaker_cluster_args(args),
    )
    for segment, speaker in zip(segments, speaker_names):
        segment.speaker = speaker

    labels = {speaker: speaker for speaker in sorted(set(speaker_names))}
    turns = [(segment.start, segment.end, segment.speaker or "") for segment in segments if segment.speaker]
    report_diarization_done(
        progress_callback,
        labels,
        turns,
        assignedSegmentCount=len(speaker_names),
    )
    return segments


def assign_speakers_with_embeddings(
    audio_path: Path,
    segments: list[Segment],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    if not segments:
        return segments
    if progress_callback:
        progress_callback(
            {
                "event": "speaker_recognition_start",
                "model": args.speaker_recognition_model,
                "total": len(segments),
            }
        )

    model = None
    embeddings = []
    try:
        model = load_speaker_recognition_model(args.speaker_recognition_model)
        with tempfile.TemporaryDirectory(prefix="huz-speakers-") as chunk_dir:
            chunk_root = Path(chunk_dir)
            for segment in segments:
                chunk_path = chunk_root / f"speaker_{segment.index:04d}.wav"
                extract_chunk(audio_path, chunk_path, segment.start, segment.end)
                embeddings.append(generate_speaker_embedding(model, chunk_path))
                if progress_callback:
                    progress_callback(
                        {
                            "event": "speaker_recognition_segment",
                            "index": segment.index,
                            "total": len(segments),
                        }
                    )
    finally:
        model = None
        release_inference_memory()

    speaker_names = cluster_speaker_embeddings(embeddings, args)
    for segment, speaker in zip(segments, speaker_names):
        segment.speaker = speaker

    labels = {speaker: speaker for speaker in sorted(set(speaker_names))}
    turns = [(segment.start, segment.end, segment.speaker or "") for segment in segments if segment.speaker]
    report_diarization_done(
        progress_callback,
        labels,
        turns,
        assignedSegmentCount=len(speaker_names),
    )
    return segments


def assign_speakers_with_coreml_embeddings(
    audio_path: Path,
    segments: list[Segment],
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Segment]:
    if not segments:
        return segments
    model_dir = getattr(
        args,
        "speaker_diarization_coreml_model",
        DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL,
    )
    model_dir = (
        _clean_configured_model(str(model_dir))
        or DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL
    )
    if progress_callback:
        progress_callback(
            {
                "event": "speaker_recognition_start",
                "model": "speaker-diarization-coreml",
                "modelPath": model_dir,
                "total": len(segments),
            }
        )

    try:
        import numpy as np
        import soundfile as sf

        models = load_speaker_coreml_models(str(model_dir))
        audio, sample_rate = sf.read(str(audio_path), dtype="float32", always_2d=False)
        audio = np.asarray(audio, dtype=np.float32)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)

        embeddings = []
        for segment in segments:
            start = max(0, int(segment.start * sample_rate))
            end = min(audio.size, max(start + 1, int(segment.end * sample_rate)))
            chunk = audio[start:end]
            if chunk.size < int(sample_rate * 0.2):
                chunk = np.pad(chunk, (0, max(1, int(sample_rate * 0.2) - chunk.size)))
            embeddings.append(
                speaker_coreml_embedding_for_audio(chunk, sample_rate, models)
            )
            if progress_callback:
                progress_callback(
                    {
                        "event": "speaker_recognition_segment",
                        "index": segment.index,
                        "total": len(segments),
                    }
                )
    except Exception as exc:  # noqa: BLE001 - keep transcription usable.
        if not env_bool("MSUB_SKIP_UNAVAILABLE_AUX_MODELS", True):
            raise
        message = f"CoreML speaker labeling failed; using acoustic instead: {exc}"
        if getattr(args, "verbose", False):
            print(message, file=sys.stderr)
        if progress_callback:
            progress_callback(
                {
                    "event": "speaker_labeling_fallback",
                    "requested": "coreml",
                    "engine": "acoustic",
                    "reason": "coreml_unavailable",
                    "message": message,
                }
            )
        return assign_speakers_with_acoustic_features(
            audio_path,
            segments,
            acoustic_speaker_cluster_args(args),
            progress_callback,
        )

    speaker_names = cluster_speaker_embeddings(embeddings, args)
    for segment, speaker in zip(segments, speaker_names):
        segment.speaker = speaker

    labels = {speaker: speaker for speaker in sorted(set(speaker_names))}
    turns = [
        (segment.start, segment.end, segment.speaker or "")
        for segment in segments
        if segment.speaker
    ]
    report_diarization_done(
        progress_callback,
        labels,
        turns,
        assignedSegmentCount=len(speaker_names),
    )
    return segments


def speaker_labeling_uses_pyannote(args: argparse.Namespace) -> bool:
    return resolved_speaker_labeling_engine(args) == "pyannote"


def speaker_labeling_uses_acoustic(args: argparse.Namespace) -> bool:
    return resolved_speaker_labeling_engine(args) == "acoustic"


def speaker_labeling_uses_coreml(args: argparse.Namespace) -> bool:
    return resolved_speaker_labeling_engine(args) == "coreml"


def speaker_labeling_uses_embeddings(args: argparse.Namespace) -> bool:
    return resolved_speaker_labeling_engine(args) == "eres2netv2"


def resolved_speaker_labeling_engine(args: argparse.Namespace) -> str:
    resolved = getattr(args, "resolved_speaker_labeling_engine", None)
    if resolved:
        return str(resolved)

    requested = str(getattr(args, "speaker_labeling_engine", "acoustic") or "acoustic")
    coreml_model = getattr(
        args,
        "speaker_diarization_coreml_model",
        DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL,
    )
    coreml_model = (
        _clean_configured_model(str(coreml_model))
        or DEFAULT_SPEAKER_DIARIZATION_COREML_MODEL
    )
    if requested == "coreml":
        return "coreml" if speaker_diarization_coreml_available(coreml_model) else "acoustic"
    if requested in {"pyannote", "eres2netv2"} and not torch_extras_enabled():
        if speaker_diarization_coreml_available(coreml_model):
            return "coreml"
        return "acoustic"
    return requested


def configure_speaker_labeling_runtime(
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> None:
    requested = str(getattr(args, "speaker_labeling_engine", "acoustic") or "acoustic")
    resolved = resolved_speaker_labeling_engine(args)
    args.resolved_speaker_labeling_engine = resolved
    if requested == resolved or not getattr(args, "diarize_speakers", False):
        return

    if requested == "coreml":
        reason = "coreml_unavailable"
        message = (
            f"speaker labeling engine {requested!r} is unavailable; "
            f"using {resolved!r} instead"
        )
    else:
        reason = "torch_extras_disabled"
        message = (
            f"speaker labeling engine {requested!r} requires torch extras; "
            f"using {resolved!r} instead"
        )
    if getattr(args, "verbose", False):
        print(message, file=sys.stderr)
    if progress_callback:
        progress_callback(
            {
                "event": "speaker_labeling_fallback",
                "requested": requested,
                "engine": resolved,
                "reason": reason,
                "message": message,
            }
        )


def load_speaker_turns(
    audio_path: Path,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> tuple[list[tuple[float, float, str]], dict[str, str]]:
    if progress_callback:
        progress_callback({"event": "diarization_start"})

    pipeline = None
    try:
        pipeline = load_diarization_pipeline(args.diarization_model)
        output = pipeline(str(audio_path), **diarization_kwargs(args))
        turns = iter_diarization_turns(output)
        labels = relabel_speakers(turns)
        return turns, labels
    finally:
        pipeline = None
        gc.collect()
        try:
            import torch

            if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
                torch.mps.empty_cache()
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except Exception:
            pass


def report_diarization_done(
    progress_callback: ProgressCallback | None,
    labels: dict[str, str],
    turns: list[tuple[float, float, str]],
    **extra: int,
) -> None:
    if not progress_callback:
        return
    progress_callback(
        {
            "event": "diarization_done",
            "speakerCount": len(labels),
            "turnCount": len(turns),
            **extra,
        }
    )


def choose_speaker_for_range(
    start_seconds: float,
    end_seconds: float,
    turns: list[tuple[float, float, str]],
    labels: dict[str, str],
) -> str | None:
    scores: dict[str, float] = {}
    for start, end, speaker in turns:
        overlap = max(0.0, min(end_seconds, end) - max(start_seconds, start))
        if overlap > 0:
            scores[speaker] = scores.get(speaker, 0.0) + overlap
    if scores:
        return labels[max(scores.items(), key=lambda item: item[1])[0]]

    midpoint = (start_seconds + end_seconds) / 2
    nearest: tuple[float, str] | None = None
    for start, end, speaker in turns:
        distance = min(abs(midpoint - start), abs(midpoint - end))
        if nearest is None or distance < nearest[0]:
            nearest = (distance, speaker)
    if nearest is not None and nearest[0] <= 1.0:
        return labels[nearest[1]]
    return None


def choose_speaker_for_cue(
    cue: Cue,
    turns: list[tuple[float, float, str]],
    labels: dict[str, str],
) -> str | None:
    return choose_speaker_for_range(cue.start, cue.end, turns, labels)


def merge_same_speaker_pieces(
    pieces: list[Segment], max_gap_seconds: float
) -> list[Segment]:
    if not pieces:
        return []

    merged: list[Segment] = [pieces[0]]
    for piece in pieces[1:]:
        previous = merged[-1]
        if (
            previous.speaker == piece.speaker
            and piece.start - previous.end <= max_gap_seconds
        ):
            previous.end = max(previous.end, piece.end)
        else:
            merged.append(piece)
    return merged


def fill_segment_gaps(segment: Segment, pieces: list[Segment]) -> list[Segment]:
    if not pieces:
        return []

    pieces[0].start = segment.start
    pieces[-1].end = segment.end
    for previous, current in pairwise(pieces):
        if current.start <= previous.end:
            midpoint = round((current.start + previous.end) / 2, 3)
        else:
            midpoint = round((current.start + previous.end) / 2, 3)
        previous.end = max(previous.start + 0.05, midpoint)
        current.start = min(current.end - 0.05, midpoint)
    return [piece for piece in pieces if piece.end - piece.start > 0.05]


def absorb_tiny_speaker_segments(
    pieces: list[Segment], min_segment_seconds: float
) -> list[Segment]:
    if min_segment_seconds <= 0 or len(pieces) <= 1:
        return pieces

    result: list[Segment] = []
    for piece in pieces:
        if piece.duration >= min_segment_seconds:
            result.append(piece)
            continue

        next_piece = next((candidate for candidate in pieces if candidate.start >= piece.end), None)
        if result and result[-1].speaker == piece.speaker:
            result[-1].end = piece.end
        elif next_piece is not None and next_piece.speaker == piece.speaker:
            next_piece.start = piece.start
        elif result and (
            next_piece is None or result[-1].duration >= next_piece.duration
        ):
            result[-1].end = piece.end
        elif next_piece is not None:
            next_piece.start = piece.start
        else:
            result.append(piece)

    return [piece for piece in result if piece.end - piece.start > 0.05]


def split_segment_by_speaker(
    segment: Segment,
    turns: list[tuple[float, float, str]],
    labels: dict[str, str],
    args: argparse.Namespace,
) -> list[Segment]:
    pieces: list[Segment] = []
    for turn_start, turn_end, raw_speaker in sorted(turns, key=lambda item: (item[0], item[1])):
        start = max(segment.start, turn_start)
        end = min(segment.end, turn_end)
        if end - start <= 0.05:
            continue
        speaker = labels.get(raw_speaker, raw_speaker)
        pieces.append(
            Segment(
                index=0,
                start=round(start, 3),
                end=round(end, 3),
                speaker=speaker,
            )
        )

    if not pieces:
        speaker = choose_speaker_for_range(segment.start, segment.end, turns, labels)
        return [Segment(index=0, start=segment.start, end=segment.end, speaker=speaker)]

    pieces = merge_same_speaker_pieces(
        pieces,
        max(0.05, args.vad_min_silence_seconds),
    )
    pieces = fill_segment_gaps(segment, pieces)
    pieces = absorb_tiny_speaker_segments(
        pieces,
        max(0.35, args.vad_min_segment_seconds),
    )
    pieces = merge_same_speaker_pieces(
        pieces,
        max(0.05, args.vad_min_silence_seconds),
    )
    return pieces or [segment]


def split_segments_by_speaker(
    segments: list[Segment],
    turns: list[tuple[float, float, str]],
    labels: dict[str, str],
    args: argparse.Namespace,
) -> list[Segment]:
    if not turns or not labels:
        return segments

    split: list[Segment] = []
    for segment in segments:
        split.extend(split_segment_by_speaker(segment, turns, labels, args))
    split.sort(key=lambda item: (item.start, item.end))
    return split


def apply_speaker_diarization(
    cues: list[Cue],
    audio_path: Path,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
) -> list[Cue]:
    if not args.diarize_speakers or not cues:
        return cues

    turns, labels = load_speaker_turns(audio_path, args, progress_callback)
    for cue in cues:
        cue.speaker = choose_speaker_for_cue(cue, turns, labels)
    assigned_count = sum(1 for cue in cues if cue.speaker)
    report_diarization_done(
        progress_callback,
        labels,
        turns,
        assignedCueCount=assigned_count,
    )
    return cues


EMOTION_EMOJI = {
    "happy": "😊",
    "sad": "😢",
    "angry": "😠",
    "neutral": "😐",
    "fearful": "😨",
    "disgusted": "🤢",
    "surprised": "😮",
    "other": "🎭",
}


def cue_text_with_speaker(cue: Cue, include_rich_info: bool = False) -> str:
    text = cue.text
    if include_rich_info:
        emoji_prefix = ""
        event_prefix = ""
        emotion = normalize_sensevoice_emotion(cue.emotion, default="neutral")
        emoji = EMOTION_EMOJI.get(emotion) if emotion else None
        if emoji:
            emoji_prefix = emoji
        event = normalize_audio_event(cue.event)
        if event and event.lower() != "speech":
            event_prefix = f"〔{event}〕"
        if emoji_prefix or event_prefix:
            text = f"{emoji_prefix}{event_prefix}{text}".strip()
    if not cue.speaker:
        return text
    return f"{cue.speaker}: {text}"


def write_output(
    cues: list[Cue],
    output_path: Path,
    fmt: str,
    max_chars_per_line: int,
    include_rich_info: bool = False,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if fmt == "srt":
        with open(output_path, "w", encoding="utf-8") as f:
            for cue in cues:
                text = wrap_subtitle_text(
                    cue_text_with_speaker(cue, include_rich_info),
                    max_chars_per_line,
                )
                f.write(f"{cue.index}\n")
                f.write(
                    f"{format_srt_timestamp(cue.start)} --> "
                    f"{format_srt_timestamp(cue.end)}\n"
                )
                f.write(f"{text}\n\n")
        return

    if fmt == "vtt":
        with open(output_path, "w", encoding="utf-8") as f:
            f.write("WEBVTT\n\n")
            for cue in cues:
                text = wrap_subtitle_text(
                    cue_text_with_speaker(cue, include_rich_info),
                    max_chars_per_line,
                )
                f.write(f"{cue.index}\n")
                f.write(
                    f"{format_vtt_timestamp(cue.start)} --> "
                    f"{format_vtt_timestamp(cue.end)}\n"
                )
                f.write(f"{text}\n\n")
        return

    if fmt == "ass":
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(ASS_HEADER)
            for cue in cues:
                text = wrap_subtitle_text(
                    cue_text_with_speaker(cue, include_rich_info),
                    max_chars_per_line,
                ).replace("\n", "\\N")
                name = (cue.speaker or "").replace(",", " ")
                f.write(
                    f"Dialogue: 0,{format_ass_timestamp(cue.start)},"
                    f"{format_ass_timestamp(cue.end)},Default,{name},0,0,0,,{text}\n"
                )
        return

    if fmt == "txt":
        with open(output_path, "w", encoding="utf-8") as f:
            f.write("\n".join(cue_text_with_speaker(cue, include_rich_info) for cue in cues))
        return

    segments = []
    for cue in cues:
        segment: dict[str, object] = {
            "index": cue.index,
            "start": cue.start,
            "end": cue.end,
            "text": cue.text,
            "confidence": cue.confidence,
            "speaker": cue.speaker,
            "language": cue.language,
            "emotion": cue.emotion,
            "event": cue.event,
        }
        if cue.words:
            segment["words"] = [
                {"text": word, "start": start, "end": end}
                for word, start, end in cue.words
            ]
        segments.append(segment)
    payload = {
        "text": "\n".join(cue_text_with_speaker(cue, include_rich_info) for cue in cues),
        "segments": segments,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)


@lru_cache(maxsize=MODEL_CACHE_SIZE)
def load_stt_model(model_id: str):
    runtime_error = mlx_stt_runtime_error()
    if runtime_error:
        raise RuntimeError(runtime_error)
    try:
        from mlx_audio.stt.utils import load
    except ImportError as exc:
        raise RuntimeError(
            "Missing MLX dependencies. Run: UV_CACHE_DIR=.uv-cache uv sync"
        ) from exc

    patch_qwen3_safe_stream_decode()
    return load(model_id)


@lru_cache(maxsize=1)
def mlx_stt_runtime_error() -> str | None:
    if env_bool("MSUB_SKIP_MLX_RUNTIME_CHECK", False):
        return None

    probe = (
        "import mlx.core as mx; "
        "x = mx.array([1.0]); "
        "mx.eval(x)"
    )
    try:
        result = tracked_subprocess_run(
            [sys.executable, "-c", probe],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return (
            "MLX runtime check timed out before loading the speech model. "
            "Restart MSub and make sure no other process is exhausting GPU resources."
        )
    except OSError as exc:
        return f"Could not start MLX runtime check: {exc}"

    if result.returncode == 0:
        return None

    detail = " ".join(
        part.strip()
        for part in [result.stderr, result.stdout]
        if part and part.strip()
    )
    if "No Metal device available" in detail or "[metal::load_device]" in detail:
        return (
            "MLX speech recognition requires an available Apple Metal device. "
            "This usually fails only in headless, sandboxed, or virtualized sessions; "
            "run MSub in a normal macOS desktop session on Apple Silicon."
        )
    return f"MLX runtime check failed before loading the speech model: {detail or 'unknown error'}"


def clear_mlx_runtime_cache() -> None:
    try:
        import mlx.core as mx

        clear_cache = getattr(mx, "clear_cache", None)
        if callable(clear_cache):
            clear_cache()

    except Exception:
        pass


def release_inference_memory(*, force: bool = False) -> None:
    if not force and not CLEAR_MLX_CACHE_EACH_CHUNK:
        return
    gc.collect()
    clear_mlx_runtime_cache()


def should_release_inference_memory_after_chunk(
    args: argparse.Namespace,
    index: int,
    total: int,
) -> bool:
    if not CLEAR_MLX_CACHE_EACH_CHUNK:
        return False
    policy = MLX_CACHE_CLEAR_POLICY
    if policy in {"0", "false", "no", "off", "never", "none"}:
        return False
    if policy in {"always", "chunk", "each_chunk"}:
        return True

    index = max(1, int(index or 1))
    total = max(1, int(total or 1))
    is_last = index >= total
    if policy in {"job", "task", "end"}:
        return is_last
    if policy == "interval":
        return is_last or index % MLX_CACHE_CLEAR_INTERVAL == 0

    engine = resolve_asr_engine(
        getattr(args, "model", ""),
        getattr(args, "asr_engine", "auto"),
    )
    if engine in {"mega", "mimo", "qwen3", "funasr"}:
        return is_last or index % MLX_CACHE_CLEAR_INTERVAL == 0
    return True


def release_inference_memory_after_chunk(
    args: argparse.Namespace,
    index: int,
    total: int,
) -> None:
    if should_release_inference_memory_after_chunk(args, index, total):
        release_inference_memory()


def keep_aux_models_requested(args: argparse.Namespace) -> bool:
    """True when the caller asked to keep auxiliary models loaded after a job.

    The web layer sets `args.keep_aux_models` to a callable that reports
    whether more jobs are queued, so batch runs skip the per-job cache clear
    and let the idle reaper reclaim memory instead.
    """
    keep = getattr(args, "keep_aux_models", False)
    if callable(keep):
        try:
            return bool(keep())
        except Exception:
            return False
    return bool(keep)


def clear_aux_model_caches() -> None:
    load_audio_event_classifier.cache_clear()
    load_word_aligner.cache_clear()
    load_punc_model.cache_clear()
    load_denoise_model.cache_clear()
    with contextlib.suppress(Exception):
        from .emotion_mlx import load_emotion_mlx_model

        load_emotion_mlx_model.cache_clear()
    with contextlib.suppress(Exception):
        from .panns_mlx import clear_panns_mlx_model_cache

        clear_panns_mlx_model_cache()
    gc.collect()
    clear_mlx_runtime_cache()


def clear_stt_model_cache() -> None:
    load_stt_model.cache_clear()
    clear_aux_model_caches()
    gc.collect()
    clear_mlx_runtime_cache()


def stt_model_cache_info() -> dict[str, int]:
    info = load_stt_model.cache_info()
    return {
        "hits": info.hits,
        "misses": info.misses,
        "maxSize": info.maxsize,
        "currentSize": info.currsize,
    }


def patch_qwen3_safe_stream_decode() -> None:
    if env_bool("MSUB_DISABLE_QWEN_SAFE_STREAM_DECODE", False):
        return
    try:
        from mlx_audio.stt.models.qwen3_asr import qwen3_asr as qwen3_module
    except Exception:
        return

    model_class = getattr(qwen3_module, "Qwen3ASRModel", None)
    if model_class is None or getattr(model_class, "_msub_safe_stream_decode", False):
        return

    original_stream_transcribe = model_class.stream_transcribe

    def stream_transcribe_safe(
        self,
        audio,
        *,
        max_tokens: int = 8192,
        temperature: float = 0.0,
        top_p: float = 1.0,
        top_k: int = 0,
        min_p: float = 0.0,
        min_tokens_to_keep: int = 1,
        repetition_penalty=None,
        repetition_context_size: int = 100,
        language=None,
        prefill_step_size: int = 2048,
        chunk_duration: float = 1200.0,
        min_chunk_duration: float = 1.0,
        verbose: bool = False,
        system_prompt: str | None = None,
    ):
        from mlx_audio.stt.utils import load_audio
        from mlx_lm.sample_utils import make_logits_processors, make_sampler

        if not hasattr(self, "_tokenizer") or not hasattr(self, "_feature_extractor"):
            raise RuntimeError(
                "Tokenizer/FeatureExtractor not initialized. Call post_load_hook first."
            )

        mx = qwen3_module.mx
        np = qwen3_module.np
        tqdm = qwen3_module.tqdm
        split_audio_into_chunks = qwen3_module.split_audio_into_chunks
        StreamingResult = qwen3_module.StreamingResult

        audio_input = audio[0] if isinstance(audio, list) else audio
        if isinstance(audio_input, str):
            audio_input = load_audio(audio_input)
        audio_np = (
            np.array(audio_input) if isinstance(audio_input, mx.array) else audio_input
        )

        chunks = split_audio_into_chunks(
            audio_np,
            sr=self.sample_rate,
            chunk_duration=chunk_duration,
            min_chunk_duration=min_chunk_duration,
        )

        sampler = make_sampler(
            temperature,
            top_p,
            min_p,
            min_tokens_to_keep=min_tokens_to_keep,
            top_k=top_k,
        )
        logits_processors = (
            make_logits_processors(
                repetition_penalty=repetition_penalty,
                repetition_context_size=repetition_context_size,
            )
            if repetition_penalty
            else None
        )

        total_prompt_tokens = 0
        total_generation_tokens = 0
        remaining_tokens = max_tokens
        detected_language = language

        chunk_iter = tqdm(
            enumerate(chunks),
            total=len(chunks),
            desc="Processing chunks",
            disable=not verbose or len(chunks) == 1,
        )
        for chunk_idx, (chunk_audio, offset_sec) in chunk_iter:
            actual_chunk_duration = len(chunk_audio) / self.sample_rate
            is_last_chunk = chunk_idx == len(chunks) - 1
            text_token_count = 0
            generated_tokens: list[int] = []
            committed_text = ""

            def decoded_body(full_text: str, token_index: int | None = None) -> tuple[str | None, bool]:
                nonlocal detected_language
                if "<asr_text>" in full_text and full_text.startswith("language "):
                    detected_language, body = self.extract_language(full_text)
                    return body, False
                if detected_language is None:
                    if (
                        token_index is not None
                        and token_index <= 16
                        and full_text.startswith("language ")
                    ):
                        return None, True
                    detected_language = "English"
                return full_text, False

            def stable_text_piece(decoded_text: str, *, final: bool) -> str:
                nonlocal committed_text
                candidate = decoded_text
                if not final:
                    replacement_index = candidate.find("\ufffd")
                    if replacement_index >= 0:
                        candidate = candidate[:replacement_index]
                if not candidate or candidate == committed_text:
                    return ""
                if not candidate.startswith(committed_text):
                    if final:
                        common_prefix = os.path.commonprefix([committed_text, candidate])
                        if common_prefix == committed_text:
                            piece = candidate[len(committed_text) :]
                            committed_text = candidate
                            return piece
                    return ""
                piece = candidate[len(committed_text) :]
                committed_text = candidate
                return piece

            _, _, num_audio_tokens = self._preprocess_audio(chunk_audio)
            input_ids = self._build_prompt(
                num_audio_tokens,
                detected_language,
                system_prompt,
            )
            chunk_prompt_tokens = input_ids.shape[1]
            total_prompt_tokens += chunk_prompt_tokens

            for token_index, (token, _) in enumerate(
                self.stream_generate(
                    chunk_audio,
                    max_tokens=remaining_tokens,
                    sampler=sampler,
                    logits_processors=logits_processors,
                    language=detected_language,
                    prefill_step_size=prefill_step_size,
                    verbose=verbose and len(chunks) == 1,
                    system_prompt=system_prompt,
                )
            ):
                generated_tokens.append(int(token))
                full_text = self._tokenizer.decode(
                    generated_tokens,
                    skip_special_tokens=True,
                )

                decoded_text, should_wait = decoded_body(full_text, token_index)
                if should_wait or not decoded_text:
                    continue

                text_piece = stable_text_piece(decoded_text, final=False)
                if not text_piece:
                    continue

                prev_progress = text_token_count / max(remaining_tokens, 1)
                text_token_count += 1
                curr_progress = min(text_token_count / max(remaining_tokens, 1), 1.0)
                estimated_start = offset_sec + (actual_chunk_duration * prev_progress)
                estimated_end = offset_sec + (actual_chunk_duration * curr_progress)

                yield StreamingResult(
                    text=text_piece,
                    is_final=False,
                    start_time=estimated_start,
                    end_time=estimated_end,
                    language=detected_language or "English",
                )

            if generated_tokens:
                final_text = self._tokenizer.decode(
                    generated_tokens,
                    skip_special_tokens=True,
                )
                final_decoded_text, _ = decoded_body(final_text, None)
                if final_decoded_text:
                    text_piece = stable_text_piece(final_decoded_text, final=True)
                    if text_piece:
                        prev_progress = text_token_count / max(remaining_tokens, 1)
                        text_token_count += 1
                        curr_progress = min(text_token_count / max(remaining_tokens, 1), 1.0)
                        estimated_start = offset_sec + (actual_chunk_duration * prev_progress)
                        estimated_end = offset_sec + (actual_chunk_duration * curr_progress)
                        yield StreamingResult(
                            text=text_piece,
                            is_final=False,
                            start_time=estimated_start,
                            end_time=estimated_end,
                            language=detected_language or "English",
                        )

            total_generation_tokens += len(generated_tokens)
            remaining_tokens -= len(generated_tokens)

            final_result = StreamingResult(
                text="",
                is_final=is_last_chunk or remaining_tokens <= 0,
                start_time=offset_sec,
                end_time=offset_sec + actual_chunk_duration,
                language=detected_language or "English",
                prompt_tokens=total_prompt_tokens,
                generation_tokens=total_generation_tokens,
            )
            final_result.final_text = committed_text
            yield final_result

            if QWEN_CLEAR_CACHE_BETWEEN_AUDIO_CHUNKS:
                mx.clear_cache()

            if remaining_tokens <= 0:
                break

    model_class._msub_original_stream_transcribe = original_stream_transcribe
    model_class.stream_transcribe = stream_transcribe_safe
    model_class._msub_safe_stream_decode = True


def dynamic_tokens_enabled_for_engine(engine: str) -> bool:
    if engine == "funasr":
        value = os.getenv("MSUB_FUNASR_DYNAMIC_MAX_TOKENS")
    else:
        value = os.getenv("MSUB_QWEN_DYNAMIC_MAX_TOKENS")
        if value is None:
            value = os.getenv("MSUB_MEGA_DYNAMIC_MAX_TOKENS")
    if value is None:
        return True
    return value.strip().lower() not in {"0", "false", "no", "off"}


def max_tokens_for_segment_duration(
    args: argparse.Namespace,
    duration: float | None,
    engine: str,
) -> int:
    configured = int(getattr(args, "mimo_max_tokens", 0) or MEGA_DEFAULT_MAX_TOKENS)
    if configured < 1:
        return MEGA_DEFAULT_MAX_TOKENS
    if not dynamic_tokens_enabled_for_engine(engine):
        return configured

    seconds = max(1.0, float(duration or 0.0))
    if engine == "funasr":
        token_rate = max(4.0, env_float("MSUB_FUNASR_DYNAMIC_TOKEN_RATE", 18.0))
        token_margin = max(16.0, env_float("MSUB_FUNASR_DYNAMIC_TOKEN_MARGIN", 48.0))
        floor = 48
    else:
        token_rate = max(4.0, env_float("MSUB_QWEN_DYNAMIC_TOKEN_RATE", 24.0))
        token_margin = max(16.0, env_float("MSUB_QWEN_DYNAMIC_TOKEN_MARGIN", 64.0))
        floor = 64
    estimated = int(math.ceil(seconds * token_rate + token_margin))
    return max(floor, min(configured, estimated))


def args_for_segment_generation(
    args: argparse.Namespace,
    segment: Segment,
) -> argparse.Namespace:
    engine = resolve_asr_engine(args.model, args.asr_engine)
    if engine not in {"mimo", "mega", "qwen3", "funasr"}:
        return args
    next_args = copy.copy(args)
    next_args.mimo_max_tokens = max_tokens_for_segment_duration(args, segment.duration, engine)
    return next_args


def hotwords_from_context(context: str | None) -> list[str]:
    text = str(context or "").strip()
    if not text:
        return []
    parts = re.split(r"[,，、;\n]+", text)
    return [part.strip() for part in parts if part.strip()]


def generation_kwargs_for_engine(args: argparse.Namespace) -> dict:
    gen_kwargs = dict(getattr(args, "gen_kwargs", None) or {})
    engine = resolve_asr_engine(args.model, args.asr_engine)
    if engine == "sensevoice":
        gen_kwargs.setdefault("language", normalize_sensevoice_language(args.language))
        gen_kwargs.setdefault("use_itn", bool(args.use_itn))
    elif engine == "mimo":
        language = normalize_sensevoice_language(args.language)
        gen_kwargs.setdefault("language", None if language in {"auto", "nospeech"} else language)
        gen_kwargs.setdefault("max_tokens", args.mimo_max_tokens)
        # MiMo's ASR path becomes unstable with sampling enabled in the current MLX
        # adapter, often producing random multilingual/code-like tokens. Keep it greedy.
        gen_kwargs["temperature"] = 0.0
        gen_kwargs.setdefault("top_p", args.mimo_top_p)
        gen_kwargs.setdefault("top_k", args.mimo_top_k)
        if QWEN_REPETITION_PENALTY > 0:
            gen_kwargs.setdefault("repetition_penalty", QWEN_REPETITION_PENALTY)
            gen_kwargs.setdefault("repetition_context_size", QWEN_REPETITION_CONTEXT_SIZE)
    elif engine in {"mega", "qwen3"}:
        language = normalize_mega_language(args.language)
        if language not in {"auto", "nospeech"}:
            gen_kwargs.setdefault("language", language)
        context = str(getattr(args, "asr_context", "") or "").strip()
        if context:
            gen_kwargs.setdefault("system_prompt", context)
        gen_kwargs.setdefault("max_tokens", args.mimo_max_tokens)
        gen_kwargs.setdefault("temperature", args.mimo_temperature)
        gen_kwargs.setdefault("top_p", args.mimo_top_p)
        gen_kwargs.setdefault("top_k", args.mimo_top_k)
        if QWEN_REPETITION_PENALTY > 0:
            gen_kwargs.setdefault("repetition_penalty", QWEN_REPETITION_PENALTY)
            gen_kwargs.setdefault("repetition_context_size", QWEN_REPETITION_CONTEXT_SIZE)
    elif engine == "funasr":
        gen_kwargs.setdefault("language", normalize_funasr_language(args.language))
        gen_kwargs.setdefault("itn", bool(args.use_itn))
        hotwords = hotwords_from_context(getattr(args, "asr_context", ""))
        if hotwords:
            gen_kwargs.setdefault("hotwords", hotwords)
        gen_kwargs.setdefault("max_tokens", args.mimo_max_tokens)
        gen_kwargs.setdefault("temperature", args.mimo_temperature)
        gen_kwargs.setdefault("top_p", args.mimo_top_p)
        gen_kwargs.setdefault("top_k", args.mimo_top_k)
        if FUNASR_REPETITION_PENALTY > 0:
            gen_kwargs.setdefault("repetition_penalty", FUNASR_REPETITION_PENALTY)
            gen_kwargs.setdefault("repetition_context_size", FUNASR_REPETITION_CONTEXT_SIZE)
    else:
        gen_kwargs.setdefault("beam_size", args.beam_size)
        gen_kwargs.setdefault("softmax_smoothing", args.softmax_smoothing)
        gen_kwargs.setdefault("length_penalty", args.length_penalty)
        gen_kwargs.setdefault("eos_penalty", args.eos_penalty)
        if args.decode_max_len > 0:
            gen_kwargs.setdefault("max_len", args.decode_max_len)
    return gen_kwargs


def transcribe_one(model, audio_path: Path, args: argparse.Namespace):
    gen_kwargs = generation_kwargs_for_engine(args)
    return model.generate(str(audio_path), **gen_kwargs)


def transcribe_one_streaming(
    model,
    audio_path: Path,
    args: argparse.Namespace,
    segment: Segment,
    total_segments: int,
    progress_callback: ProgressCallback | None = None,
):
    if resolve_asr_engine(args.model, args.asr_engine) not in {"mega", "qwen3"}:
        return transcribe_one(model, audio_path, args)
    if not env_bool("MSUB_MEGA_STREAMING_TEXT", True):
        return transcribe_one(model, audio_path, args)

    gen_kwargs = generation_kwargs_for_engine(args)
    gen_kwargs["stream"] = True
    max_tokens = max(
        1,
        int(gen_kwargs.get("max_tokens") or MEGA_DEFAULT_MAX_TOKENS),
    )
    parts: list[str] = []
    token_count = 0
    prompt_tokens = 0
    generation_tokens = 0
    language: str | None = None
    last_reported_fraction = -1.0
    final_text_parts: list[str] = []

    try:
        stream = model.generate(str(audio_path), **gen_kwargs)
    except TypeError:
        return transcribe_one(model, audio_path, args)

    for item in stream:
        if isinstance(item, str):
            text_piece = item
            is_final = False
        else:
            text_piece = str(getattr(item, "text", "") or "")
            is_final = bool(getattr(item, "is_final", False))
            language = getattr(item, "language", None) or language
            prompt_tokens = int(
                getattr(item, "prompt_tokens", 0) or prompt_tokens
            )
            generation_tokens = int(
                getattr(item, "generation_tokens", 0) or generation_tokens
            )
        if is_final:
            item_final_text = getattr(item, "final_text", None)
            if item_final_text is not None:
                item_final_text = str(item_final_text)
                if item_final_text:
                    final_text_parts.append(item_final_text)
            continue
        if text_piece:
            parts.append(text_piece)
            token_count += 1
        if progress_callback and token_count > 0:
            token_fraction = min(0.96, token_count / max_tokens)
            if token_fraction - last_reported_fraction >= 0.035:
                last_reported_fraction = token_fraction
                progress_callback(
                    {
                        "event": "chunk_progress",
                        "index": segment.index,
                        "total": total_segments,
                        "tokens": token_count,
                        "maxTokens": max_tokens,
                        "fractionalCurrent": round(
                            max(0.0, segment.index - 1 + token_fraction),
                            4,
                        ),
                    }
                )

    text = clean_text(" ".join(final_text_parts) if final_text_parts else "".join(parts))
    generation_tokens = generation_tokens or token_count
    return SimpleNamespace(
        text=text,
        segments=[
            {
                "language": language,
                "start": segment.start,
                "end": segment.end,
            }
        ],
        language=language,
        prompt_tokens=prompt_tokens,
        generation_tokens=generation_tokens,
        total_tokens=prompt_tokens + generation_tokens,
    )


ALIGNER_LANGUAGE_NAMES = {
    "zh": "Chinese",
    "yue": "Chinese",
    "en": "English",
    "ja": "Japanese",
    "ko": "Korean",
}
ALIGN_CUE_START_PADDING = 0.12
ALIGN_CUE_END_PADDING = 0.24
ALIGN_MIN_CUE_SECONDS = 0.2


def word_alignment_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "align_words", False))


@lru_cache(maxsize=1)
def load_word_aligner(model_id: str):
    from mlx_audio.stt.utils import load

    return load(model_id)


def aligner_language_name(args: argparse.Namespace, cue_language: str | None) -> str:
    for value in (cue_language, getattr(args, "language", None)):
        normalized = str(value or "").strip().lower()
        if normalized in ALIGNER_LANGUAGE_NAMES:
            return ALIGNER_LANGUAGE_NAMES[normalized]
    return "Chinese"


def align_chunk_words(
    chunk_path: Path,
    text: str,
    args: argparse.Namespace,
    offset: float,
    max_end: float,
    language: str | None = None,
) -> list[tuple[str, float, float]] | None:
    """Word-level forced alignment for one transcribed chunk.

    Returns absolute-time (word, start, end) tuples, clamped to
    [offset, max_end] and monotonically ordered, or None when alignment
    is unavailable. Alignment is an optional refinement: any failure is
    swallowed so transcription output is never blocked by it.
    """
    if not text:
        return None
    try:
        aligner = load_word_aligner(getattr(args, "align_model", DEFAULT_ALIGNER_MODEL))
        result = aligner.generate(
            str(chunk_path),
            text=text,
            language=aligner_language_name(args, language),
        )
    except Exception as exc:  # noqa: BLE001 - alignment is an optional refinement.
        if getattr(args, "verbose", False):
            print(f"word alignment failed: {exc}", file=sys.stderr)
        return None
    items = getattr(result, "items", None) or []
    words: list[tuple[str, float, float]] = []
    cursor = offset
    for item in items:
        word = str(getattr(item, "text", "") or "").strip()
        if not word:
            continue
        start = offset + max(0.0, float(getattr(item, "start_time", 0.0) or 0.0))
        end = offset + max(0.0, float(getattr(item, "end_time", 0.0) or 0.0))
        start = min(max(start, cursor), max_end)
        end = min(max(end, start), max_end)
        words.append((word, round(start, 3), round(end, 3)))
        cursor = start
    return words or None


def tightened_cue_bounds(
    words: list[tuple[str, float, float]],
    start: float,
    end: float,
) -> tuple[float, float]:
    """Shrink cue bounds toward the aligned speech, never expanding them."""
    if not words:
        return start, end
    new_start = min(max(start, words[0][1] - ALIGN_CUE_START_PADDING), end)
    new_end = max(min(end, words[-1][2] + ALIGN_CUE_END_PADDING), new_start)
    min_duration = min(ALIGN_MIN_CUE_SECONDS, max(0.0, end - start))
    if new_end - new_start < min_duration:
        return start, end
    return round(new_start, 3), round(new_end, 3)


_ALIGN_COUNT_STRIP_RE = re.compile(r"[\W_]+", re.UNICODE)


def _alignment_char_count(text: str) -> int:
    return len(_ALIGN_COUNT_STRIP_RE.sub("", text))


def word_split_slices(
    words: list[tuple[str, float, float]] | None,
    chunks: list[str],
) -> list[list[tuple[str, float, float]]] | None:
    """Partition aligned words across the split text chunks.

    Matches cumulative letter/CJK counts (punctuation and spaces ignored)
    so FireRedPunc-restored punctuation does not break the mapping.
    Returns None whenever the mapping is ambiguous; callers then fall back
    to proportional timing.
    """
    if not words or len(chunks) <= 1:
        return None
    chunk_counts = [_alignment_char_count(chunk) for chunk in chunks]
    word_counts = [_alignment_char_count(word) for word, _, _ in words]
    if 0 in chunk_counts or sum(chunk_counts) != sum(word_counts):
        return None
    slices: list[list[tuple[str, float, float]]] = []
    word_index = 0
    for chunk_count in chunk_counts[:-1]:
        consumed = 0
        start_index = word_index
        while word_index < len(words) and consumed < chunk_count:
            consumed += word_counts[word_index]
            word_index += 1
        if consumed != chunk_count:
            return None
        slices.append(words[start_index:word_index])
    slices.append(words[word_index:])
    return slices


def word_split_end_times(
    words: list[tuple[str, float, float]] | None,
    chunks: list[str],
) -> list[float] | None:
    """End times for all but the last text chunk, from aligned words."""
    slices = word_split_slices(words, chunks)
    if slices is None:
        return None
    return [chunk_words[-1][2] for chunk_words in slices[:-1]]


def retry_reason_for_chunk(
    text: str,
    confidence: float | None,
    args: argparse.Namespace,
) -> str | None:
    if not text:
        return "empty"
    threshold = max(float(getattr(args, "min_confidence", 0.0) or 0.0), RETRY_CONFIDENCE_FLOOR)
    if confidence is not None and confidence < threshold:
        return "low_confidence"
    return None


def retry_args_for_chunk(args: argparse.Namespace) -> argparse.Namespace:
    retry_args = copy.copy(args)
    retry_args.beam_size = min(6, max(int(getattr(args, "beam_size", 3) or 3) + 1, 4))
    retry_args.vad_padding_seconds = max(
        float(getattr(args, "vad_padding_seconds", 0.0) or 0.0),
        RETRY_PADDING_SECONDS,
    )
    engine = resolve_asr_engine(args.model, args.asr_engine)
    if engine in {"mimo", "mega", "qwen3", "funasr"}:
        retry_args.mimo_temperature = 0.0
        retry_args.mimo_top_p = min(float(getattr(args, "mimo_top_p", 1.0) or 1.0), 0.95)
        retry_args.mimo_top_k = int(getattr(args, "mimo_top_k", 0) or 0)
        gen_kwargs = dict(getattr(args, "gen_kwargs", None) or {})
        if engine == "funasr":
            gen_kwargs["repetition_penalty"] = FUNASR_RETRY_REPETITION_PENALTY
            gen_kwargs["repetition_context_size"] = FUNASR_RETRY_REPETITION_CONTEXT_SIZE
        else:
            gen_kwargs["repetition_penalty"] = QWEN_RETRY_REPETITION_PENALTY
            gen_kwargs["repetition_context_size"] = QWEN_RETRY_REPETITION_CONTEXT_SIZE
        retry_args.gen_kwargs = gen_kwargs
    return retry_args


def retry_transcription_is_better(
    current_text: str,
    current_confidence: float | None,
    retry_text: str,
    retry_confidence: float | None,
) -> bool:
    if not retry_text:
        return False
    if not current_text:
        return True
    if retry_confidence is None:
        return False
    if current_confidence is None:
        return len(retry_text) >= max(1, int(len(current_text) * 0.75))
    return retry_confidence >= current_confidence


def transcribe_chunks(
    model,
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    progress_callback: ProgressCallback | None = None,
    speaker_turns: list[tuple[float, float, str]] | None = None,
    speaker_labels: dict[str, str] | None = None,
    rich_metadata_model=None,
    segments: list[Segment] | None = None,
) -> list[Cue]:
    segments = segments if segments is not None else build_segments(
        audio_path,
        duration,
        args,
        speaker_turns,
        speaker_labels,
        progress_callback,
    )
    if segments and speaker_turns is not None and speaker_labels is not None and not any(
        segment.speaker for segment in segments
    ):
        segments = split_segments_by_speaker(segments, speaker_turns, speaker_labels, args)
    if (
        args.diarize_speakers
        and speaker_labeling_uses_acoustic(args)
        and not any(segment.speaker for segment in segments)
    ):
        segments = assign_speakers_with_acoustic_features(
            audio_path,
            segments,
            args,
            progress_callback,
        )
    if (
        args.diarize_speakers
        and speaker_labeling_uses_coreml(args)
        and not any(segment.speaker for segment in segments)
    ):
        segments = assign_speakers_with_coreml_embeddings(
            audio_path,
            segments,
            args,
            progress_callback,
        )
    if (
        args.diarize_speakers
        and speaker_labeling_uses_embeddings(args)
        and not any(segment.speaker for segment in segments)
    ):
        segments = assign_speakers_with_embeddings(
            audio_path,
            segments,
            args,
            progress_callback,
        )
    if args.diarize_speakers and speaker_turns is not None and speaker_labels is not None:
        assigned_segment_count = sum(1 for segment in segments if segment.speaker)
        report_diarization_done(
            progress_callback,
            speaker_labels,
            speaker_turns,
            assignedSegmentCount=assigned_segment_count,
        )
    if args.verbose:
        speech_seconds = sum(segment.duration for segment in segments)
        print(
            f"segments: {len(segments)} "
            f"({speech_seconds:.1f}s speech-like audio, mode={args.segment_mode})",
            file=sys.stderr,
        )
    if progress_callback:
        progress_callback(
            {
                "event": "segments",
                "total": len(segments),
                "speechSeconds": round(sum(segment.duration for segment in segments), 3),
                "mode": args.segment_mode,
                "vadEngine": getattr(args, "resolved_vad_engine", None)
                or resolve_vad_engine(args),
            }
        )
    cues: list[Cue] = []

    with tempfile.TemporaryDirectory(prefix="huz-chunks-") as chunk_dir:
        chunk_root = Path(chunk_dir)

        def chunk_file_for(target: Segment) -> Path:
            return chunk_root / f"chunk_{target.index:04d}.wav"

        # Overlap audio extraction with GPU inference: while one segment is
        # transcribing, a single background worker extracts the next chunk.
        # The copied contextvars keep ffmpeg subprocesses attributed to the
        # owning job so cancellation still reaches them.
        prefetch_executor: ThreadPoolExecutor | None = None
        pending_extractions: dict[int, Future] = {}
        if PREFETCH_CHUNKS and len(segments) > 1:
            prefetch_executor = ThreadPoolExecutor(
                max_workers=1, thread_name_prefix="msub-chunk-prefetch"
            )

        def schedule_extraction(target: Segment) -> None:
            if prefetch_executor is None or target.index in pending_extractions:
                return
            context = contextvars.copy_context()
            pending_extractions[target.index] = prefetch_executor.submit(
                context.run,
                extract_chunk,
                audio_path,
                chunk_file_for(target),
                target.start,
                target.end,
            )

        if segments:
            schedule_extraction(segments[0])
        try:
            cues.extend(
                _transcribe_prepared_segments(
                    model,
                    audio_path,
                    duration,
                    args,
                    segments,
                    chunk_file_for,
                    schedule_extraction,
                    pending_extractions,
                    progress_callback,
                    rich_metadata_model,
                )
            )
        finally:
            if prefetch_executor is not None:
                prefetch_executor.shutdown(wait=True, cancel_futures=True)

    return cues


def _transcribe_prepared_segments(
    model,
    audio_path: Path,
    duration: float,
    args: argparse.Namespace,
    segments: list[Segment],
    chunk_file_for,
    schedule_extraction,
    pending_extractions: dict[int, Future],
    progress_callback: ProgressCallback | None,
    rich_metadata_model,
) -> list[Cue]:
    cues: list[Cue] = []
    for position, segment in enumerate(segments):
        chunk_args = args_for_segment_generation(args, segment)
        if args.verbose:
            print(
                f"chunk {segment.index}/{len(segments)}: "
                f"{segment.start:.1f}s -> {segment.end:.1f}s",
                file=sys.stderr,
            )
        if progress_callback:
            progress_callback(
                {
                    "event": "chunk_start",
                    "index": segment.index,
                    "total": len(segments),
                    "start": segment.start,
                    "end": segment.end,
                    "speaker": segment.speaker,
                }
            )
        chunk_path = chunk_file_for(segment)
        result = None
        chunk_audio_start = segment.start
        try:
            if position + 1 < len(segments):
                schedule_extraction(segments[position + 1])
            pending_extraction = pending_extractions.pop(segment.index, None)
            if pending_extraction is not None:
                pending_extraction.result()
            else:
                extract_chunk(audio_path, chunk_path, segment.start, segment.end)
            result = transcribe_one_streaming(
                model,
                chunk_path,
                chunk_args,
                segment,
                len(segments),
                progress_callback,
            )
            text = clean_text(getattr(result, "text", ""))
            confidence = confidence_from_result(result)
            # Qwen often omits confidence, so generic low-confidence recovery
            # never sees sentence loops. Retry the identical audio once, without
            # expanding timestamps or deleting repeated text after recognition.
            repetition_retry = resolve_asr_engine(chunk_args.model, chunk_args.asr_engine) == "qwen3" and has_phrase_loop(text)
            if repetition_retry:
                if progress_callback:
                    progress_callback({"event": "chunk_retry", "index": segment.index,
                        "total": len(segments), "reason": "repetition", "start": segment.start, "end": segment.end})
                retry_args = retry_args_for_chunk(chunk_args)
                retry_result = transcribe_one_streaming(model, chunk_path, retry_args,
                    segment, len(segments), progress_callback)
                retry_text = clean_text(getattr(retry_result, "text", ""))
                if accept_retry(retry_text):
                    result = retry_result
                    text = retry_text
                    confidence = confidence_from_result(result)
                retry_result = None
            retry_reason = None if repetition_retry else retry_reason_for_chunk(
                text,
                confidence,
                chunk_args,
            )
            if retry_reason and RETRY_PADDING_SECONDS > 0:
                retry_start = max(0.0, segment.start - RETRY_PADDING_SECONDS)
                retry_end = min(duration, segment.end + RETRY_PADDING_SECONDS)
                if retry_end > retry_start and (
                    retry_start < segment.start or retry_end > segment.end
                ):
                    if progress_callback:
                        progress_callback(
                            {
                                "event": "chunk_retry",
                                "index": segment.index,
                                "total": len(segments),
                                "reason": retry_reason,
                                "start": retry_start,
                                "end": retry_end,
                            }
                        )
                    retry_result = None
                    try:
                        extract_chunk(audio_path, chunk_path, retry_start, retry_end)
                        chunk_audio_start = retry_start
                        retry_segment = Segment(
                            index=segment.index,
                            start=retry_start,
                            end=retry_end,
                            speaker=segment.speaker,
                        )
                        retry_args = retry_args_for_chunk(chunk_args)
                        retry_args = args_for_segment_generation(retry_args, retry_segment)
                        retry_result = transcribe_one_streaming(
                            model,
                            chunk_path,
                            retry_args,
                            retry_segment,
                            len(segments),
                            progress_callback,
                        )
                        retry_text = clean_text(getattr(retry_result, "text", ""))
                        retry_confidence = confidence_from_result(retry_result)
                        if retry_transcription_is_better(
                            text,
                            confidence,
                            retry_text,
                            retry_confidence,
                        ):
                            result = retry_result
                            text = retry_text
                            confidence = retry_confidence
                    except Exception as exc:  # noqa: BLE001 - keep original result.
                        if args.verbose:
                            print(
                                f"retry failed for chunk {segment.index}: {exc}",
                                file=sys.stderr,
                            )
                    finally:
                        retry_result = None
                        release_inference_memory_after_chunk(
                            chunk_args,
                            segment.index,
                            len(segments),
                        )
            if not text:
                if progress_callback:
                    progress_callback(
                        {
                            "event": "chunk_done",
                            "index": segment.index,
                            "total": len(segments),
                            "text": "",
                            "skipped": True,
                        }
                    )
                continue
            if (
                chunk_args.min_confidence > 0
                and confidence is not None
                and confidence < chunk_args.min_confidence
            ):
                if args.verbose:
                    print(
                        f"skip low-confidence chunk {segment.index}: {confidence:.3f}",
                        file=sys.stderr,
                    )
                if progress_callback:
                    progress_callback(
                        {
                            "event": "chunk_done",
                            "index": segment.index,
                            "total": len(segments),
                            "text": text,
                            "confidence": confidence,
                            "skipped": True,
                        }
                    )
                continue
            metadata = metadata_from_result(result)
            if rich_metadata_model is not None:
                rich_result = None
                try:
                    if progress_callback:
                        progress_callback(
                            {
                                "event": "rich_metadata_start",
                                "index": segment.index,
                                "total": len(segments),
                            }
                        )
                    rich_metadata = transcribe_emotion_metadata(
                        rich_metadata_model,
                        chunk_path,
                        chunk_args,
                    )
                    metadata["emotion"] = rich_metadata["emotion"] or "neutral"
                    metadata["event"] = rich_metadata["event"]
                except Exception as exc:  # noqa: BLE001 - rich metadata is optional.
                    if args.verbose:
                        print(
                            f"skip emotion metadata for chunk {segment.index}: {exc}",
                            file=sys.stderr,
                        )
                    if progress_callback:
                        progress_callback(
                            {
                                "event": "rich_metadata_unavailable",
                                "index": segment.index,
                                "total": len(segments),
                                "error": str(exc),
                            }
                        )
                finally:
                    rich_result = None
                    release_inference_memory_after_chunk(
                        chunk_args,
                        segment.index,
                        len(segments),
                    )
            speaker = segment.speaker or speaker_from_result(result)
            cue_start, cue_end = segment.start, segment.end
            words = None
            if word_alignment_enabled(args):
                words = align_chunk_words(
                    chunk_path,
                    text,
                    args,
                    offset=chunk_audio_start,
                    max_end=duration,
                    language=metadata["language"],
                )
                if words:
                    cue_start, cue_end = tightened_cue_bounds(
                        words, cue_start, cue_end
                    )
            cues.append(
                Cue(
                    index=len(cues) + 1,
                    start=cue_start,
                    end=cue_end,
                    text=text,
                    confidence=confidence,
                    speaker=speaker,
                    language=metadata["language"],
                    emotion=metadata["emotion"],
                    event=metadata["event"],
                    words=words,
                )
            )
            if progress_callback:
                progress_callback(
                    {
                        "event": "chunk_done",
                        "index": segment.index,
                        "total": len(segments),
                        "text": text,
                        "confidence": confidence,
                        "speaker": speaker,
                        "language": metadata["language"],
                        "emotion": metadata["emotion"],
                        "audioEvent": metadata["event"],
                        "skipped": False,
                    }
                )
        finally:
            result = None
            chunk_path.unlink(missing_ok=True)
            release_inference_memory_after_chunk(
                chunk_args,
                segment.index,
                len(segments),
            )

    return cues


def print_segment_preview(
    segments: list[Segment], duration: float, args: argparse.Namespace
) -> None:
    payload = {
        "duration": round(duration, 3),
        "count": len(segments),
        "segment_mode": args.segment_mode,
        "vad_engine": (
            getattr(args, "resolved_vad_engine", None) or resolve_vad_engine(args)
        )
        if args.segment_mode == "vad"
        else None,
        "vad_threshold_db": args.vad_threshold_db
        if args.segment_mode == "vad"
        else None,
        "firered_vad_threshold": args.firered_vad_threshold
        if args.segment_mode == "vad"
        else None,
        "segments": [
            {
                "index": segment.index,
                "start": segment.start,
                "end": segment.end,
                "duration": round(segment.duration, 3),
                "speaker": segment.speaker,
                "audio_label": segment.audio_label,
                "audio_score": segment.audio_score,
                "audio_labels": segment.audio_labels,
                "speech_score": segment.speech_score,
                "repetition_score": segment.repetition_score,
                "flagged": segment.flagged,
            }
            for segment in segments
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def run(
    args: argparse.Namespace, progress_callback: ProgressCallback | None = None
) -> Path | None:
    normalize_asr_options(args)
    validate_subtitle_options(args)
    configure_speaker_labeling_runtime(args, progress_callback)
    input_path = args.input.expanduser().resolve()
    if not input_path.exists():
        raise FileNotFoundError(f"Input file does not exist: {input_path}")
    if args.no_extract and (args.preview_segments or args.format in {"srt", "vtt"}):
        raise RuntimeError(
            "--no-extract can only be used with untimed txt/json transcription."
        )

    output_path = normalize_output_path(
        input_path, args.output.expanduser() if args.output else None, args.format
    ).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    audio_path: Path
    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    prepared_audio_path = getattr(args, "prepared_audio_path", None)
    prepared_segments = getattr(args, "prepared_segments", None)

    def extract_audio_for_run(target_path: Path) -> None:
        if progress_callback is None:
            extract_audio(input_path, target_path)
            return

        progress_callback({"event": "audio_extract_start"})
        try:
            input_duration = probe_duration(input_path)
        except Exception:
            input_duration = None
        last_fraction = -1.0
        last_report = 0.0

        def report_audio_progress(fraction: float) -> None:
            nonlocal last_fraction, last_report
            fraction = min(max(float(fraction), 0.0), 1.0)
            now = time.time()
            if fraction < 1.0 and fraction - last_fraction < 0.025 and now - last_report < 0.75:
                return
            last_fraction = fraction
            last_report = now
            progress_callback(
                {
                    "event": "audio_extract_progress",
                    "fraction": round(fraction, 4),
                }
            )

        extract_audio(
            input_path,
            target_path,
            progress_callback=report_audio_progress,
            duration=input_duration,
        )
        progress_callback({"event": "audio_extract_done"})

    def prepare_audio_for_run(target_path: Path) -> None:
        if denoise_enabled(args) and denoise_audio_for_run(
            input_path, target_path, args, progress_callback
        ):
            return
        extract_audio_for_run(target_path)

    if prepared_audio_path:
        audio_path = Path(prepared_audio_path).expanduser().resolve()
        if not audio_path.exists():
            raise FileNotFoundError(f"Prepared audio file does not exist: {audio_path}")
        if progress_callback:
            progress_callback({"event": "prepared_input", "segments": prepared_segments is not None})
        # A validated empty plan is a completed segmentation result, not a
        # request to run detection again. Avoid loading ASR/auxiliary models or
        # running punctuation/alignment when there are no speech segments.
        if prepared_segments == [] and not args.no_extract and not args.preview_segments:
            if progress_callback:
                progress_callback({"event": "segments", "total": 0, "speechSeconds": 0.0,
                                   "mode": args.segment_mode, "vadEngine": getattr(args, "vad_engine", None)})
            if progress_callback:
                progress_callback({"event": "output_start"})
            write_output([], output_path, args.format, args.max_chars_per_line, args.sensevoice_rich_info)
            if progress_callback:
                progress_callback({"event": "output_written", "output": str(output_path), "cueCount": 0})
            return output_path
    elif args.no_extract:
        audio_path = input_path
    elif args.keep_audio:
        audio_path = output_base(output_path).with_suffix(".wav")
        prepare_audio_for_run(audio_path)
    else:
        temp_dir = tempfile.TemporaryDirectory(prefix="huz-subtitle-")
        audio_path = Path(temp_dir.name) / f"{input_path.stem}.wav"
        prepare_audio_for_run(audio_path)

    model = None
    rich_metadata_model = None
    model_loaded = False
    speaker_turns: list[tuple[float, float, str]] | None = None
    speaker_labels: dict[str, str] | None = None
    speaker_segments: list[Segment] | None = None
    try:
        if args.preview_segments:
            duration = probe_duration(audio_path)
            if args.diarize_speakers and speaker_labeling_uses_pyannote(args):
                speaker_turns, speaker_labels = load_speaker_turns(
                    audio_path,
                    args,
                    progress_callback,
                )
            segments = build_segments(
                audio_path,
                duration,
                args,
                speaker_turns,
                speaker_labels,
                progress_callback,
            )
            segments = mark_non_lexical_segments(
                audio_path,
                segments,
                args,
                progress_callback,
            )
            if args.diarize_speakers and speaker_labeling_uses_embeddings(args):
                segments = assign_speakers_with_embeddings(
                    audio_path,
                    segments,
                    args,
                    progress_callback,
                )
            if args.diarize_speakers and speaker_labeling_uses_coreml(args):
                segments = assign_speakers_with_coreml_embeddings(
                    audio_path,
                    segments,
                    args,
                    progress_callback,
                )
            if args.diarize_speakers and speaker_labeling_uses_acoustic(args):
                segments = assign_speakers_with_acoustic_features(
                    audio_path,
                    segments,
                    args,
                    progress_callback,
                )
            if speaker_turns is not None and speaker_labels is not None:
                report_diarization_done(
                    progress_callback,
                    speaker_labels,
                    speaker_turns,
                    assignedSegmentCount=sum(1 for segment in segments if segment.speaker),
                )
            print_segment_preview(segments, duration, args)
            return None

        def prepare_speaker_data() -> tuple[
            list[tuple[float, float, str]] | None,
            dict[str, str] | None,
            list[Segment] | None,
        ]:
            turns: list[tuple[float, float, str]] | None = None
            labels: dict[str, str] | None = None
            segments_with_speakers: list[Segment] | None = None
            if speaker_labeling_uses_pyannote(args):
                turns, labels = load_speaker_turns(
                    audio_path,
                    args,
                    progress_callback,
                )
            if speaker_labeling_uses_embeddings(args):
                media_duration = probe_duration(audio_path)
                segments_with_speakers = prepared_segments if prepared_segments is not None else build_segments(
                    audio_path,
                    media_duration,
                    args,
                    progress_callback=progress_callback,
                )
                segments_with_speakers = assign_speakers_with_embeddings(
                    audio_path,
                    segments_with_speakers,
                    args,
                    progress_callback,
                )
            if speaker_labeling_uses_coreml(args):
                media_duration = probe_duration(audio_path)
                segments_with_speakers = prepared_segments if prepared_segments is not None else build_segments(
                    audio_path,
                    media_duration,
                    args,
                    progress_callback=progress_callback,
                )
                segments_with_speakers = assign_speakers_with_coreml_embeddings(
                    audio_path,
                    segments_with_speakers,
                    args,
                    progress_callback,
                )
            if speaker_labeling_uses_acoustic(args):
                media_duration = probe_duration(audio_path)
                segments_with_speakers = prepared_segments if prepared_segments is not None else build_segments(
                    audio_path,
                    media_duration,
                    args,
                    progress_callback=progress_callback,
                )
                segments_with_speakers = assign_speakers_with_acoustic_features(
                    audio_path,
                    segments_with_speakers,
                    args,
                    progress_callback,
                )
            return turns, labels, segments_with_speakers

        speaker_prep_needed = (
            args.diarize_speakers
            and not args.no_extract
            and (
                speaker_labeling_uses_pyannote(args)
                or speaker_labeling_uses_embeddings(args)
                or speaker_labeling_uses_coreml(args)
                or speaker_labeling_uses_acoustic(args)
            )
        )
        # Overlap speaker preparation (diarization / embedding clustering)
        # with ASR model loading; both are independent until transcription.
        speaker_future: Future | None = None
        if speaker_prep_needed and OVERLAP_SPEAKER_PREP:
            prep_executor = ThreadPoolExecutor(
                max_workers=1, thread_name_prefix="msub-speaker-prep"
            )
            prep_context = contextvars.copy_context()
            speaker_future = prep_executor.submit(prep_context.run, prepare_speaker_data)
            prep_executor.shutdown(wait=False)
        elif speaker_prep_needed:
            speaker_turns, speaker_labels, speaker_segments = prepare_speaker_data()

        if args.verbose:
            print(f"loading model: {args.model}", file=sys.stderr)
        if progress_callback:
            progress_callback({"event": "model_loading", "model": args.model})
        cache_info = getattr(load_stt_model, "cache_info", None)
        cache_before = cache_info() if cache_info else None
        model = load_stt_model(args.model)
        cache_after = cache_info() if cache_info else None
        model_loaded = True
        if progress_callback:
            progress_callback({"event": "model_loaded", "model": args.model,
                               "cache": ("hit" if cache_after.hits > cache_before.hits else "miss")
                               if cache_before and cache_after else "unknown"})

        if speaker_future is not None:
            speaker_turns, speaker_labels, speaker_segments = speaker_future.result()

        if should_use_aux_emotion_model(args):
            if progress_callback:
                progress_callback(
                    {"event": "rich_model_loading", "model": args.emotion_model}
                )
            try:
                rich_metadata_model = load_emotion_model(args.emotion_model)
            except RuntimeError as exc:
                if not env_bool("MSUB_SKIP_UNAVAILABLE_AUX_MODELS", True):
                    raise
                if args.verbose:
                    print(f"skipping emotion model: {exc}", file=sys.stderr)
                if progress_callback:
                    progress_callback(
                        {
                            "event": "rich_model_unavailable",
                            "model": args.emotion_model,
                            "error": str(exc),
                        }
                    )
            else:
                if progress_callback:
                    progress_callback(
                        {"event": "rich_model_loaded", "model": args.emotion_model}
                    )

        if progress_callback:
            progress_callback({"event": "recognition_start"})
        if args.no_extract:
            result = None
            rich_result = None
            try:
                result = transcribe_one(model, audio_path, args)
                text = clean_text(getattr(result, "text", ""))
                metadata = metadata_from_result(result)
                if rich_metadata_model is not None:
                    try:
                        rich_metadata = transcribe_emotion_metadata(
                            rich_metadata_model,
                            audio_path,
                            args,
                        )
                        metadata["emotion"] = rich_metadata["emotion"] or "neutral"
                        metadata["event"] = rich_metadata["event"]
                    except Exception as exc:  # noqa: BLE001 - rich metadata is optional.
                        if args.verbose:
                            print(f"skip emotion metadata: {exc}", file=sys.stderr)
                        if progress_callback:
                            progress_callback(
                                {
                                    "event": "rich_metadata_unavailable",
                                    "index": 1,
                                    "total": 1,
                                    "error": str(exc),
                                }
                            )
                cues = [
                    Cue(
                        index=1,
                        start=0.0,
                        end=0.0,
                        text=text,
                        language=metadata["language"],
                        emotion=metadata["emotion"],
                        event=metadata["event"],
                    )
                ] if text else []
            finally:
                result = None
                rich_result = None
                release_inference_memory(force=True)
        else:
            duration = probe_duration(audio_path)
            cues = transcribe_chunks(
                model,
                audio_path,
                duration,
                args,
                progress_callback,
                speaker_turns,
                speaker_labels,
                rich_metadata_model,
                prepared_segments if prepared_segments is not None else speaker_segments,
            )

        if progress_callback:
            progress_callback({"event": "recognition_done"})
            progress_callback({"event": "postprocessing_start"})
        if args.diarize_speakers and speaker_labeling_uses_pyannote(args) and speaker_turns is None:
            model = None
            clear_stt_model_cache()
            model_loaded = False
            cues = apply_speaker_diarization(cues, audio_path, args, progress_callback)
        if args.diarize_speakers and speaker_labeling_uses_embeddings(args) and args.no_extract:
            for cue in cues:
                cue.speaker = "Speaker 1"
            report_diarization_done(
                progress_callback,
                {"Speaker 1": "Speaker 1"},
                [(0.0, 0.0, "Speaker 1")] if cues else [],
                assignedCueCount=len(cues),
            )
        if args.diarize_speakers and speaker_labeling_uses_coreml(args) and args.no_extract:
            for cue in cues:
                cue.speaker = "Speaker 1"
            report_diarization_done(
                progress_callback,
                {"Speaker 1": "Speaker 1"},
                [(0.0, 0.0, "Speaker 1")] if cues else [],
                assignedCueCount=len(cues),
            )
        if args.diarize_speakers and speaker_labeling_uses_acoustic(args) and args.no_extract:
            for cue in cues:
                cue.speaker = "Speaker 1"
            report_diarization_done(
                progress_callback,
                {"Speaker 1": "Speaker 1"},
                [(0.0, 0.0, "Speaker 1")] if cues else [],
                assignedCueCount=len(cues),
            )
        cues = apply_punctuation(cues, args, progress_callback)
        cues = split_cues(cues, args)
        if progress_callback:
            progress_callback({"event": "postprocessing_done"})
            progress_callback({"event": "output_start"})
        write_output(
            cues,
            output_path,
            args.format,
            args.max_chars_per_line,
            args.sensevoice_rich_info,
        )
        if progress_callback:
            progress_callback(
                {
                    "event": "output_written",
                    "output": str(output_path),
                    "cueCount": len(cues),
                }
            )
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()
        if CLEAR_AUX_CACHE_EACH_JOB and not keep_aux_models_requested(args):
            clear_aux_model_caches()
        if model_loaded:
            release_inference_memory(force=True)

    return output_path


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        output_path = run(args)
    except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if output_path is not None:
        print(f"subtitle written: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
