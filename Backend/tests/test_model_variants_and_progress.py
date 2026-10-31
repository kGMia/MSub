"""Targeted integration checks without downloading weights or running MLX."""
import pytest

import huz_subtitle.web as web


def test_japanese_variant_download_registry_and_local_resolution(tmp_path, monkeypatch):
    monkeypatch.setattr(web, "MODELS_DIR", tmp_path)
    def variant():
        qwen = next(m for m in web.model_catalog() if m["engine"] == "qwen3")
        return qwen, next(v for v in qwen["variants"] if v["repo"] == web.QWEN3_JA_MODEL_ID)
    general, ja = variant()
    original_default = general["defaultModel"]
    assert ja["language"] == "ja"
    assert not ja["localModelAvailable"]
    assert any(m["repo"] == ja["repo"] and m["dir"] == web.QWEN3_JA_MODEL_DIR for m in web.MODEL_REGISTRY)
    folder = tmp_path / web.QWEN3_JA_MODEL_DIR
    folder.mkdir()
    (folder / "config.json").write_text('{"model_type":"qwen3_asr"}')
    assert not variant()[1]["localModelAvailable"]
    (folder / "model.safetensors").touch()
    general, ja = variant()
    assert ja["localModelAvailable"]
    assert ja["localModel"] == str(folder)
    assert general["defaultModel"] == original_default


def test_progress_coalesces_disk_only_and_flushes_boundaries(monkeypatch):
    job_id = "progress-coalescing-fixture"
    monkeypatch.setattr(web, "jobs", {job_id: {"status": "running", "cancelRequested": False}})
    monkeypatch.setattr(web, "job_progress_persisted_at", {})
    monkeypatch.setattr(web, "job_diagnostics", {})
    writes = []
    monkeypatch.setattr(web, "persist_job_status", lambda job: writes.append(dict(job)))
    now = [100.0]
    monkeypatch.setattr(web.time, "monotonic", lambda: now[0])
    for token in range(20):
        web.append_event(job_id, {"event": "chunk_progress", "index": 1, "total": 2, "tokens": token})
    assert len(writes) == 1
    assert web.jobs[job_id]["events"][-1]["tokens"] == 19
    now[0] += 0.25
    web.append_event(job_id, {"event": "chunk_progress", "index": 1, "total": 2})
    assert len(writes) == 2
    web.append_event(job_id, {"event": "chunk_done", "index": 1, "total": 2, "text": "日本語"})
    assert len(writes) == 3
    assert writes[-1]["preview"] == "日本語"
    web.jobs[job_id]["cancelRequested"] = True
    with pytest.raises(web.JobCancelled):
        web.append_event(job_id, {"event": "chunk_progress"})
    web.update_job(job_id, status="cancelled")
    assert writes[-1]["status"] == "cancelled"
    assert job_id not in web.job_progress_persisted_at


def test_japanese_variant_uses_external_download_for_bundled_backend(tmp_path, monkeypatch):
    bundled = tmp_path / "bundle-models"
    external = tmp_path / "downloaded-ja"
    external.mkdir()
    (external / "config.json").write_text('{"model_type":"qwen3_asr"}')
    (external / "model.safetensors").touch()
    monkeypatch.setattr(web, "MODELS_DIR", bundled)
    monkeypatch.setenv("MSUB_QWEN3_JA_MODEL", str(external))
    qwen = next(m for m in web.model_catalog() if m["engine"] == "qwen3")
    ja = next(v for v in qwen["variants"] if v["repo"] == web.QWEN3_JA_MODEL_ID)
    assert ja["localModel"] == str(external)
    assert ja["localModelAvailable"]

    entry = next(m for m in web.list_models()["models"] if m["name"] == web.QWEN3_JA_MODEL_DIR)
    assert entry["installed"]
    assert entry["externalPath"] == str(external)
    assert not entry["downloadable"]
    # External weights are not owned by the manager's deletion endpoint.
    web.delete_model(web.QWEN3_JA_MODEL_DIR)
    assert (external / "model.safetensors").exists()
