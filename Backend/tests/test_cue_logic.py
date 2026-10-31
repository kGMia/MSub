import argparse

from huz_subtitle.cli import (
    Cue,
    split_cue,
    split_cues,
    tightened_cue_bounds,
    word_split_end_times,
    word_split_slices,
)


def make_args(**overrides) -> argparse.Namespace:
    values = {"max_cue_chars": 6, "max_cue_duration": 0.0, "min_cue_duration": 0.0}
    values.update(overrides)
    return argparse.Namespace(**values)


def cjk_words(text: str, start: float = 1.0, step: float = 0.5):
    return [
        (char, round(start + i * step, 3), round(start + i * step + 0.4, 3))
        for i, char in enumerate(text)
    ]


def test_split_cue_proportional_without_words() -> None:
    cue = Cue(index=1, start=1.0, end=7.0, text="今天天气很好我们出去玩吧")
    pieces = split_cue(cue, make_args())
    assert len(pieces) == 2
    assert pieces[0].end == 4.0
    assert pieces[1].start == 4.0 and pieces[1].end == 7.0


def test_split_cue_uses_word_times_and_propagates_words() -> None:
    text = "今天天气很好我们出去玩吧"
    words = cjk_words(text)
    cue = Cue(index=1, start=1.0, end=7.0, text=text, words=words)
    pieces = split_cue(cue, make_args())
    assert len(pieces) == 2
    assert pieces[0].end == words[5][2]
    assert pieces[1].start == words[5][2]
    assert pieces[0].words == words[:6]
    assert pieces[1].words == words[6:]


def test_split_cue_keeps_words_when_not_split() -> None:
    words = cjk_words("你好")
    cue = Cue(index=1, start=0.0, end=2.0, text="你好", words=words)
    pieces = split_cue(cue, make_args())
    assert len(pieces) == 1
    assert pieces[0].words == words


def test_word_split_ignores_punctuation() -> None:
    words = cjk_words("今天天气很好我们出去玩吧")
    chunks = ["今天天气很好，", "我们出去玩吧。"]
    assert word_split_end_times(words, chunks) == [words[5][2]]


def test_word_split_rejects_mid_word_boundary() -> None:
    words = [("hello", 0.1, 0.5), ("world", 0.6, 1.0)]
    assert word_split_slices(words, ["hel", "loworld"]) is None
    assert word_split_slices(words, ["hello", "world"]) is not None


def test_word_split_rejects_count_mismatch() -> None:
    words = cjk_words("今天天气")
    assert word_split_slices(words, ["今天", "天气很"]) is None


def test_tightened_cue_bounds_only_shrinks() -> None:
    words = [("你", 2.0, 2.3), ("好", 2.4, 2.8)]
    start, end = tightened_cue_bounds(words, 1.5, 3.5)
    assert 1.5 <= start <= 2.0
    assert 2.8 <= end <= 3.5
    start, end = tightened_cue_bounds(words, 2.1, 2.6)
    assert start >= 2.1 and end <= 2.6


def test_tightened_cue_bounds_keeps_degenerate_alignment() -> None:
    assert tightened_cue_bounds([("x", 0.0, 0.0)], 5.0, 8.0) == (5.0, 8.0)


def test_build_segments_empty_vad_is_graceful(monkeypatch, tmp_path) -> None:
    import huz_subtitle.cli as cli

    monkeypatch.setattr(cli, "detect_speech_ranges", lambda *a, **k: [])
    args = cli.parse_args([str(tmp_path / "in.wav"), "--segment-mode", "vad"])
    events: list[dict] = []
    segments = cli.build_segments(tmp_path / "in.wav", 10.0, args, progress_callback=events.append)
    assert segments == []
    assert any(event["event"] == "no_speech" for event in events)


def test_build_segments_strict_mode_raises(monkeypatch, tmp_path) -> None:
    import pytest

    import huz_subtitle.cli as cli

    monkeypatch.setattr(cli, "detect_speech_ranges", lambda *a, **k: [])
    monkeypatch.setenv("MSUB_STRICT_NO_SPEECH", "1")
    args = cli.parse_args([str(tmp_path / "in.wav"), "--segment-mode", "vad"])
    with pytest.raises(RuntimeError):
        cli.build_segments(tmp_path / "in.wav", 10.0, args)


def test_split_cues_renumbers() -> None:
    cues = [
        Cue(index=9, start=0.0, end=2.0, text="你好"),
        Cue(index=7, start=2.0, end=4.0, text="世界"),
    ]
    result = split_cues(cues, make_args(max_cue_chars=0))
    assert [cue.index for cue in result] == [1, 2]
