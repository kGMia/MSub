"""Web API tests for the new endpoints (models, SSE events, input_path)."""

import time

import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")

from starlette.testclient import TestClient  # noqa: E402

import huz_subtitle.web as web  # noqa: E402


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(web, "MODELS_DIR", tmp_path / "models")
    return TestClient(web.app)


@pytest.fixture
def loopback_client(tmp_path, monkeypatch):
    monkeypatch.setattr(web, "MODELS_DIR", tmp_path / "models")
    try:
        return TestClient(web.app, client=("127.0.0.1", 50000))
    except TypeError:
        pytest.skip("starlette TestClient does not support client address override")


def test_list_models_reports_registry(client) -> None:
    response = client.get("/api/models")
    assert response.status_code == 200
    payload = response.json()
    names = {entry["name"] for entry in payload["models"]}
    assert "FireRedASR2-AED-mlx" in names
    assert "DeepFilterNet-mlx" in names
    for entry in payload["models"]:
        assert entry["installed"] is False
        assert entry["downloadable"] is True


def test_list_models_includes_unmanaged_dirs(client, tmp_path) -> None:
    extra = tmp_path / "models" / "Some-Custom-Model"
    extra.mkdir(parents=True)
    (extra / "weights.bin").write_bytes(b"x" * 128)
    payload = client.get("/api/models").json()
    entry = next(e for e in payload["models"] if e["name"] == "Some-Custom-Model")
    assert entry["installed"] is True
    assert entry["downloadable"] is False
    assert entry["sizeBytes"] == 128


def test_download_unknown_model_rejected(client) -> None:
    assert client.post("/api/models/download", data={"name": "NoSuchModel"}).status_code == 404


def test_model_name_traversal_rejected(client) -> None:
    assert client.post("/api/models/delete", data={"name": "../evil"}).status_code == 400


def test_delete_missing_model_is_ok(client) -> None:
    response = client.post("/api/models/delete", data={"name": "FireRedPunc"})
    assert response.status_code == 200


def test_input_path_rejected_for_non_loopback(client) -> None:
    response = client.post("/api/preview", data={"input_path": "/tmp/whatever.mp4"})
    assert response.status_code == 403


def test_input_path_unreadable_returns_409(loopback_client) -> None:
    response = loopback_client.post(
        "/api/preview", data={"input_path": "/definitely/not/here.mp4"}
    )
    assert response.status_code == 409


def test_missing_media_returns_400(loopback_client) -> None:
    assert loopback_client.post("/api/preview", data={}).status_code == 400


def test_job_events_stream_ends_at_terminal_status(client) -> None:
    job_id = "test-sse-job"
    with web.jobs_lock:
        web.jobs[job_id] = {
            "id": job_id,
            "status": "done",
            "createdAt": time.time(),
            "updatedAt": time.time(),
            "progressText": "Done",
            "events": [],
        }
    try:
        with client.stream("GET", f"/api/jobs/{job_id}/events") as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            body = b"".join(response.iter_raw())
        lines = [line for line in body.decode().splitlines() if line.startswith("data:")]
        assert len(lines) == 1
        assert '"status": "done"' in lines[0]
    finally:
        with web.jobs_lock:
            web.jobs.pop(job_id, None)


def test_job_events_unknown_job_404(client) -> None:
    assert client.get("/api/jobs/nope/events").status_code == 404


def test_preview_audio_reuses_pcm_and_rejects_remote(loopback_client, client, tmp_path, monkeypatch):
    import json

    monkeypatch.setattr(web, "JOB_DIR", tmp_path)
    preview_id = "a" * 32
    work = tmp_path / preview_id
    work.mkdir()
    audio = work / "preview.wav"
    audio.write_bytes(b"RIFF-test-pcm")
    (work / "preview_plan.json").write_text(json.dumps({"audioPath": str(audio)}))
    result = loopback_client.get(f"/api/preview/{preview_id}/audio")
    assert result.status_code == 200
    assert result.content == audio.read_bytes()
    assert client.get(f"/api/preview/{preview_id}/audio").status_code == 403


def test_preview_audio_rejects_path_escape(loopback_client, tmp_path, monkeypatch):
    import json

    monkeypatch.setattr(web, "JOB_DIR", tmp_path / "jobs")
    preview_id = "b" * 32
    work = web.JOB_DIR / preview_id
    work.mkdir(parents=True)
    outside = tmp_path / "private.wav"
    outside.write_bytes(b"not-preview")
    (work / "preview.wav").symlink_to(outside)
    (work / "preview_plan.json").write_text(json.dumps({"audioPath": str(work / "preview.wav")}))
    assert loopback_client.get(f"/api/preview/{preview_id}/audio").status_code == 404
    assert loopback_client.get("/api/preview/not-an-id/audio").status_code == 404


def test_queued_cancellation_does_not_wait_for_model_slot(monkeypatch):
    import threading

    occupied = threading.Semaphore(0)
    monkeypatch.setattr(web, "job_semaphore", occupied)
    monkeypatch.setattr(web, "shutdown_event", threading.Event())
    cancelled = threading.Event()
    monkeypatch.setattr(web, "cancel_requested", lambda _: cancelled.is_set())
    finished = threading.Event()
    errors = []

    def worker():
        try:
            with web.model_job_slot("queued"):
                errors.append("Cancelled job entered the model slot")
        except web.JobCancelled:
            pass
        except Exception as error:
            errors.append(error)
        finally:
            finished.set()

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    cancelled.set()
    try:
        assert finished.wait(2), "Cancellation waited behind the occupied model slot"
        assert not errors
        assert not occupied.acquire(blocking=False), "Unacquired semaphore was released"
    finally:
        occupied.release()
        thread.join(timeout=2)


def test_model_slot_protects_preview_auxiliary_cache(monkeypatch):
    import threading

    monkeypatch.setattr(web, "job_semaphore", threading.Semaphore(1))
    monkeypatch.setattr(web, "shutdown_event", threading.Event())
    monkeypatch.setattr(web, "model_active_jobs", 0)
    monkeypatch.setattr(web, "model_last_used", 0)
    monkeypatch.setattr(web, "cancel_requested", lambda _: False)
    monkeypatch.setattr(web, "unload_idle_model_if_needed", lambda: None)
    cleared = []
    monkeypatch.setattr(web, "clear_aux_model_caches", lambda: cleared.append("aux"))
    with web.model_job_slot("preview"):
        assert web.model_active_jobs == 1
        assert web.unload_model_cache("test") is False
        assert not cleared
    assert web.model_active_jobs == 0
    assert web.model_last_used > 0
    assert web.job_semaphore.acquire(blocking=False)


def test_sync_preview_runs_off_event_loop_with_model_lifecycle(loopback_client, tmp_path, monkeypatch):
    import threading

    loop_thread = []

    async def resolve(*args, **kwargs):
        loop_thread.append(threading.get_ident())
        return tmp_path / "input.wav"

    def build(*args, **kwargs):
        assert threading.get_ident() != loop_thread[0]
        assert web.model_active_jobs == 1
        return {"count": 0, "segments": []}

    monkeypatch.setattr(web, "resolve_job_input", resolve)
    monkeypatch.setattr(web, "build_preview_payload", build)
    monkeypatch.setattr(web, "job_semaphore", threading.Semaphore(1))
    monkeypatch.setattr(web, "model_active_jobs", 0)
    monkeypatch.setattr(web, "model_last_used", 0)
    monkeypatch.setattr(web, "unload_idle_model_if_needed", lambda: None)
    monkeypatch.setattr(web, "JOB_DIR", tmp_path / "jobs")
    response = loopback_client.post("/api/preview", data={"input_path": str(tmp_path / "input.wav")})
    assert response.status_code == 200
    assert web.model_active_jobs == 0


def test_preview_key_ignores_text_decoding_options_but_keeps_vad():
    fields = dict(
        model="local-model", asr_engine="fireredasr2", language="zh", use_itn=True,
        segment_mode="vad", vad_engine="firered", vad_threshold_db=-35,
        firered_vad_model="vad-model", firered_vad_threshold=0.4,
        firered_vad_smooth_window=5, pyannote_vad_model="pyannote-model",
        pyannote_vad_threshold=0.5, vad_min_speech_seconds=0.2,
        vad_min_silence_seconds=0.3, vad_padding_seconds=0.1,
        vad_max_segment_seconds=20, vad_min_segment_seconds=1,
        vad_split_search_seconds=2, audio_event_filter=False, audio_event_model="",
        audio_event_threshold=0.45, audio_event_filter_type="repetition",
        audio_event_preset="balanced", chunk_seconds=20,
    )
    key = web.preview_key_for_request(**fields)
    assert web.preview_key_for_request(**{**fields, "language": "en", "use_itn": False}) == key
    assert web.preview_key_for_request(**{**fields, "firered_vad_threshold": 0.6}) != key
    assert web.preview_key_for_request(**{**fields, "vad_padding_seconds": 0.2}) != key
    assert web.preview_key_for_request(**{**fields, "audio_event_filter": True}) != key


def _native_pcm(path, rate=16000):
    import wave
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(b"\x00\x00" * rate * 2)


@pytest.mark.parametrize("engine,segments", [
    ("fireredasr2", [{"start": 0.25, "end": 1.75, "index": 8}]),
    ("sensevoice", [{"start": 0.1, "end": 0.9}, {"start": 1.2, "end": 1.9}]),
    ("qwen3", []),
])
def test_native_segments_job_owns_pcm_and_preserves_ranges(loopback_client, tmp_path, monkeypatch, engine, segments):
    import json
    monkeypatch.setattr(web, "JOB_DIR", tmp_path / "jobs")
    monkeypatch.setattr(web, "jobs", {})
    monkeypatch.setattr(web, "job_pause_events", {})
    monkeypatch.setattr(web, "cleanup_jobs", lambda: None)
    captured = []
    monkeypatch.setattr(web, "run_job", lambda job_id, args: captured.append(args))
    pcm = tmp_path / "input.wav"
    _native_pcm(pcm)
    response = loopback_client.post("/api/jobs", data={"input_path": str(pcm), "asr_engine": engine,
        "vad_engine": "firered", "native_segments": json.dumps(segments)})
    assert response.status_code == 200, response.text
    args = captured[0]
    assert args.asr_engine == engine
    assert [(s.start, s.end) for s in args.prepared_segments] == [(s["start"], s["end"]) for s in segments]
    assert [s.index for s in args.prepared_segments] == list(range(1, len(segments) + 1))
    assert args.prepared_audio_path == web.JOB_DIR / response.json()["id"] / "native-input.wav"
    pcm.unlink()
    assert args.prepared_audio_path.exists()
    assert loopback_client.get("/api/config").json()["supportsNativeSegments"] is True


@pytest.mark.parametrize("segments", [
    '[{"start": -0.1, "end": 1}]', '[{"start": 0, "end": 3}]',
    '[{"start": 1, "end": 1}]', '[{"start": NaN, "end": 1}]',
    '[{"start": true, "end": 1}]', '[{"start": 1, "end": 1.5}, {"start": 0, "end": 0.5}]',
    '{}', 'invalid', '[{"start": 2, "end": 2.00001}]',
])
def test_native_segments_reject_invalid_ranges(tmp_path, segments):
    pcm = tmp_path / "input.wav"
    _native_pcm(pcm)
    with pytest.raises(web.HTTPException) as error:
        web.native_segments_from_pcm(pcm, segments)
    assert error.value.status_code == 400


def test_native_segments_reject_wrong_audio_and_conflicting_options(loopback_client, tmp_path, monkeypatch):
    pcm = tmp_path / "input.wav"
    _native_pcm(pcm, rate=8000)
    with pytest.raises(web.HTTPException):
        web.native_segments_from_pcm(pcm, "[]")
    for option in ({"denoise": "true"}, {"audio_event_filter": "true"}, {"diarize_speakers": "true"},
                   {"preview_id": "a" * 32}, {"vad_engine": "energy"}):
        response = loopback_client.post("/api/jobs", data={"input_path": str(pcm), "native_segments": "[]",
                                                        "vad_engine": "firered", **option})
        assert response.status_code == 400


def test_native_empty_plan_does_not_redetect_speech(tmp_path, monkeypatch):
    import argparse
    import huz_subtitle.cli as cli
    def unexpected(*args, **kwargs):
        pytest.fail("Explicit empty plan must not rerun VAD")
    monkeypatch.setattr(cli, "build_segments", unexpected)
    assert cli.transcribe_chunks(None, tmp_path / "unused.wav", 2,
                                 argparse.Namespace(diarize_speakers=False, verbose=False), segments=[]) == []


def test_empty_saved_preview_is_reused_but_corrupt_plan_is_rejected(loopback_client, tmp_path, monkeypatch):
    import json
    monkeypatch.setattr(web, "JOB_DIR", tmp_path / "jobs")
    monkeypatch.setattr(web, "jobs", {})
    monkeypatch.setattr(web, "job_pause_events", {})
    monkeypatch.setattr(web, "cleanup_jobs", lambda: None)
    monkeypatch.setattr(web, "preview_key_for_request", lambda **kw: "matching")
    captured = []
    monkeypatch.setattr(web, "run_job", lambda job_id, args: captured.append(args))
    pcm = tmp_path / "input.wav"
    _native_pcm(pcm)
    preview_id = "e" * 32
    web.write_preview_plan(preview_id, input_path=pcm, audio_path=pcm, duration=2,
                           media_info={}, segments=[], settings_key="matching")
    response = loopback_client.post("/api/jobs", data={"preview_id": preview_id})
    assert response.status_code == 200, response.text
    assert captured[-1].prepared_segments == []
    assert captured[-1].prepared_audio_path == pcm
    plan_path = web.preview_plan_path(preview_id)
    plan = json.loads(plan_path.read_text())
    plan["segments"] = [{"invalid": "row"}]
    plan_path.write_text(json.dumps(plan))
    # Without replacement input a corrupt preview cannot be submitted.
    assert loopback_client.post("/api/jobs", data={"preview_id": preview_id}).status_code == 400
    # With replacement input fall back without the rejected plan's PCM/ranges.
    response = loopback_client.post("/api/jobs", data={"preview_id": preview_id, "input_path": str(pcm)})
    assert response.status_code == 200
    assert captured[-1].prepared_audio_path is None
    assert captured[-1].prepared_segments is None
