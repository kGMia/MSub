"""End-to-end tests of the segment transcription loop with a stub ASR model.

These run entirely on CPU (no MLX) and cover the chunk-prefetch pipeline,
cue assembly, and progress events.
"""

from types import SimpleNamespace

import pytest

import huz_subtitle.cli as cli
from huz_subtitle.cli import Segment, parse_args, transcribe_chunks


class StubModel:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def generate(self, audio_path: str, **kwargs) -> SimpleNamespace:
        self.calls.append(audio_path)
        return SimpleNamespace(text=f"你好世界{len(self.calls)}")


@pytest.fixture
def stub_args(wav_16k_mono):
    args = parse_args([str(wav_16k_mono), "--asr-engine", "fireredasr2"])
    # Skip the CoreML/MLX VAD availability probe: segments are prepared, and
    # the probe touches macOS-specific paths that do not exist in CI sandboxes.
    args.resolved_vad_engine = "energy"
    return args


@pytest.fixture
def segments() -> list[Segment]:
    return [
        Segment(index=1, start=0.0, end=0.8),
        Segment(index=2, start=0.8, end=1.4),
        Segment(index=3, start=1.4, end=2.0),
    ]


def run_pipeline(wav, args, segments):
    model = StubModel()
    events: list[dict] = []
    cues = transcribe_chunks(
        model,
        wav,
        2.0,
        args,
        progress_callback=events.append,
        segments=segments,
    )
    return model, events, cues


def test_transcribe_chunks_with_prefetch(wav_16k_mono, stub_args, segments) -> None:
    assert cli.PREFETCH_CHUNKS is True
    model, events, cues = run_pipeline(wav_16k_mono, stub_args, segments)
    assert len(cues) == 3
    assert [cue.index for cue in cues] == [1, 2, 3]
    assert cues[0].start == 0.0 and cues[-1].end == 2.0
    assert all(cue.text.startswith("你好世界") for cue in cues)
    done = [event for event in events if event["event"] == "chunk_done"]
    assert len(done) == 3
    assert all(not event["skipped"] for event in done)
    # each segment transcribed exactly once
    assert len(model.calls) == 3


def test_transcribe_chunks_without_prefetch(
    wav_16k_mono, stub_args, segments, monkeypatch
) -> None:
    monkeypatch.setattr(cli, "PREFETCH_CHUNKS", False)
    model, events, cues = run_pipeline(wav_16k_mono, stub_args, segments)
    assert len(cues) == 3
    assert len(model.calls) == 3


def test_prefetch_and_inline_paths_agree(wav_16k_mono, stub_args, segments, monkeypatch) -> None:
    _, _, with_prefetch = run_pipeline(wav_16k_mono, stub_args, segments)
    monkeypatch.setattr(cli, "PREFETCH_CHUNKS", False)
    _, _, without_prefetch = run_pipeline(wav_16k_mono, stub_args, segments)
    assert [(cue.start, cue.end, cue.text) for cue in with_prefetch] == [
        (cue.start, cue.end, cue.text) for cue in without_prefetch
    ]


def test_empty_text_segments_are_skipped(wav_16k_mono, stub_args, segments) -> None:
    class EmptyModel:
        def generate(self, audio_path: str, **kwargs) -> SimpleNamespace:
            return SimpleNamespace(text="")

    events: list[dict] = []
    cues = transcribe_chunks(
        EmptyModel(),
        wav_16k_mono,
        2.0,
        stub_args,
        progress_callback=events.append,
        segments=segments,
    )
    assert cues == []
    done = [event for event in events if event["event"] == "chunk_done"]
    assert all(event["skipped"] for event in done)
