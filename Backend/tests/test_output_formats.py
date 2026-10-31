import json
from pathlib import Path

from huz_subtitle.cli import Cue, write_output


def sample_cues() -> list[Cue]:
    return [
        Cue(
            index=1,
            start=0.5,
            end=2.0,
            text="你好世界",
            speaker="Speaker 1",
            words=[("你好", 0.6, 1.0), ("世界", 1.1, 1.8)],
        ),
        Cue(index=2, start=2.5, end=4.0, text="Hello world"),
    ]


def test_write_srt(tmp_path: Path) -> None:
    out = tmp_path / "out.srt"
    write_output(sample_cues(), out, "srt", 0)
    content = out.read_text(encoding="utf-8")
    assert "00:00:00,500 --> 00:00:02,000" in content
    assert "你好世界" in content


def test_write_vtt(tmp_path: Path) -> None:
    out = tmp_path / "out.vtt"
    write_output(sample_cues(), out, "vtt", 0)
    content = out.read_text(encoding="utf-8")
    assert content.startswith("WEBVTT")
    assert "00:00:00.500 --> 00:00:02.000" in content


def test_write_ass(tmp_path: Path) -> None:
    out = tmp_path / "out.ass"
    write_output(sample_cues(), out, "ass", 0)
    content = out.read_text(encoding="utf-8")
    assert "[Script Info]" in content
    assert "[V4+ Styles]" in content
    assert "Dialogue: 0,0:00:00.50,0:00:02.00,Default,Speaker 1,0,0,0," in content
    assert content.count("Dialogue:") == 2


def test_write_ass_escapes_newlines(tmp_path: Path) -> None:
    out = tmp_path / "out.ass"
    cue = Cue(index=1, start=0.0, end=2.0, text="第一行第二行内容较长需要换行")
    write_output([cue], out, "ass", 5)
    content = out.read_text(encoding="utf-8")
    assert "\\N" in content


def test_write_json_includes_words_only_when_present(tmp_path: Path) -> None:
    out = tmp_path / "out.json"
    write_output(sample_cues(), out, "json", 0)
    payload = json.loads(out.read_text(encoding="utf-8"))
    first, second = payload["segments"]
    assert first["words"] == [
        {"text": "你好", "start": 0.6, "end": 1.0},
        {"text": "世界", "start": 1.1, "end": 1.8},
    ]
    assert "words" not in second
    assert payload["text"].startswith("Speaker 1")
