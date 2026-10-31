from huz_subtitle.cli import (
    clean_text,
    format_ass_timestamp,
    format_srt_timestamp,
    format_vtt_timestamp,
    iter_ranges,
    merge_ranges,
    prevent_overlaps,
    split_text_by_length,
    split_text_for_subtitles,
    wrap_subtitle_text,
)


def test_srt_timestamp() -> None:
    assert format_srt_timestamp(0.0) == "00:00:00,000"
    assert format_srt_timestamp(3661.5) == "01:01:01,500"


def test_vtt_timestamp() -> None:
    assert format_vtt_timestamp(3661.5) == "01:01:01.500"


def test_ass_timestamp() -> None:
    assert format_ass_timestamp(0.0) == "0:00:00.00"
    assert format_ass_timestamp(3661.505) == "1:01:01.50"
    assert format_ass_timestamp(-1.0) == "0:00:00.00"
    assert format_ass_timestamp(59.999) == "0:01:00.00"


def test_clean_text_strips_tokens_and_whitespace() -> None:
    assert clean_text("<|zh|>你好  世界\ntoken_123 end") == "你好 世界 end"


def test_split_text_by_length() -> None:
    parts = split_text_by_length("abcdefgh", 3)
    assert "".join(parts) == "abcdefgh"
    assert all(len(part) <= 3 for part in parts)


def test_split_text_for_subtitles_roundtrip() -> None:
    text = "今天天气很好我们一起出去玩吧好不好"
    chunks = split_text_for_subtitles(text, 6, 3)
    assert "".join(chunks) == text


def test_wrap_subtitle_text_noop_when_disabled() -> None:
    assert wrap_subtitle_text("hello world", 0) == "hello world"


def test_iter_ranges_covers_duration() -> None:
    ranges = iter_ranges(10.0, 4.0)
    assert ranges[0][0] == 0.0
    assert ranges[-1][1] == 10.0


def test_merge_ranges_and_prevent_overlaps() -> None:
    merged = merge_ranges([(0.0, 1.0), (1.05, 2.0)], 0.2)
    assert merged == [(0.0, 2.0)]
    fixed = prevent_overlaps([(0.0, 1.5), (1.2, 2.0)])
    assert fixed[0][1] <= fixed[1][0]
