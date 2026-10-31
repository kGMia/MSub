import argparse

import pytest

from huz_subtitle.diagnostics import JobDiagnostics


def test_exclusive_nested_stages_pause_and_frozen_completion():
    now = [0.0]
    trace = JobDiagnostics(clock=lambda: now[0])
    now[0] = 2
    trace.running()
    trace.event({"event": "recognition_start"})
    now[0] = 3
    trace.event({"event": "vad_start"})
    now[0] = 5
    trace.pause(True)
    now[0] = 15
    trace.pause(False)
    now[0] = 16
    trace.event({"event": "vad_done"})
    now[0] = 20
    trace.event({"event": "recognition_done"})
    result = trace.finish()
    assert result["stages"] == {"queue": 2, "other": 0, "recognition": 5, "segmentation": 3, "paused": 10}
    assert sum(result["stages"].values()) == result["totalSeconds"] == 20
    now[0] = 50
    assert trace.snapshot() == result


def test_cache_and_fallback_facts_do_not_copy_transcript_or_paths():
    trace = JobDiagnostics()
    trace.running()
    trace.event({"event": "prepared_input", "segments": True})
    trace.event({"event": "model_loaded", "cache": "hit", "model": "/private/model"})
    trace.event({"event": "rich_model_unavailable", "error": "/private/error"})
    trace.event({"event": "chunk_done", "text": "private transcript"})
    assert trace.finish()["facts"] == {"preparedAudio": "reused", "segmentation": "reused",
                                         "modelCache": "hit", "rich_model_unavailable": "fallback"}


@pytest.mark.parametrize("outcome", ["done", "error", "cancelled"])
def test_worker_finishes_diagnostics_and_api_snapshot(tmp_path, monkeypatch, outcome):
    import huz_subtitle.web as web

    job_id = "diagnostics-" + outcome
    output = tmp_path / "out.srt"
    args = argparse.Namespace(input=tmp_path / "input.wav", output=output, model="test")
    web.jobs[job_id] = {"id": job_id, "status": "queued", "workDir": str(tmp_path), "cancelRequested": False}
    monkeypatch.setattr(web, "unload_idle_model_if_needed", lambda: None)

    def run(args, progress_callback):
        progress_callback({"event": "model_loading"})
        if outcome == "error":
            raise RuntimeError("fixture failure")
        if outcome == "cancelled":
            raise web.JobCancelled()
        progress_callback({"event": "model_loaded", "cache": "miss"})
        progress_callback({"event": "output_start"})
        output.write_text("")
        progress_callback({"event": "output_written", "cueCount": 0})
        return output

    monkeypatch.setattr(web, "run", run)
    try:
        web.run_job(job_id, args)
        job = web.get_job(job_id)
        assert job["status"] == outcome
        assert job["diagnostics"]["finished"] is True
        assert "modelLoading" in job["diagnostics"]["stages"]
        assert job_id not in web.job_diagnostics
        assert web.get_job(job_id)["diagnostics"] == job["diagnostics"]
        assert (tmp_path / "status.json").exists()
    finally:
        web.jobs.pop(job_id, None)
        web.job_diagnostics.pop(job_id, None)
