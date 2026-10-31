"""Empty prepared plans finish without loading models or rerunning VAD."""
import json

import pytest

import huz_subtitle.cli as cli


def prepared_args(tmp_path, fmt="srt"):
    source = tmp_path / "source.wav"
    source.write_bytes(b"validated by the native/preview input path")
    args = cli.parse_args([str(source), "--format", fmt, "--output", str(tmp_path / f"output.{fmt}")])
    args.prepared_audio_path = source
    args.prepared_segments = []
    return args


@pytest.mark.parametrize("fmt", ["srt", "vtt", "ass", "txt", "json"])
def test_empty_plan_writes_valid_output_without_inference(tmp_path, monkeypatch, fmt):
    args = prepared_args(tmp_path, fmt)
    def unexpected(*a, **kw):
        pytest.fail("Empty plan must not load models, process audio, or punctuate")
    for name in ("load_stt_model", "load_emotion_model", "extract_audio", "build_segments", "apply_punctuation"):
        monkeypatch.setattr(cli, name, unexpected)
    events = []
    output = cli.run(args, events.append)
    assert output == args.output
    text = output.read_text()
    if fmt in {"srt", "txt"}:
        assert text == ""
    elif fmt == "vtt":
        assert text == "WEBVTT\n\n"
    elif fmt == "ass":
        assert text == cli.ASS_HEADER
    else:
        assert json.loads(text) == {"text": "", "segments": []}
    assert [event["event"] for event in events] == ["prepared_input", "segments", "output_start", "output_written"]
    assert events[-1]["cueCount"] == 0


def test_empty_plan_checkpoint_cancels_before_output(tmp_path):
    args = prepared_args(tmp_path)
    class Cancelled(Exception):
        pass
    def checkpoint(event):
        raise Cancelled()
    with pytest.raises(Cancelled):
        cli.run(args, checkpoint)
    assert not args.output.exists()


def test_empty_plan_still_checks_prepared_file(tmp_path):
    args = prepared_args(tmp_path)
    args.prepared_audio_path = tmp_path / "missing.wav"
    with pytest.raises(FileNotFoundError, match="Prepared audio"):
        cli.run(args)


def test_nonempty_plan_still_loads_model(tmp_path, monkeypatch):
    args = prepared_args(tmp_path)
    args.prepared_segments = [cli.Segment(index=1, start=0, end=1)]
    class ModelRequested(Exception):
        pass
    def requested(*a, **kw):
        raise ModelRequested()
    monkeypatch.setattr(cli, "load_stt_model", requested)
    monkeypatch.setattr(cli, "clear_aux_model_caches", lambda: None)
    with pytest.raises(ModelRequested):
        cli.run(args)
