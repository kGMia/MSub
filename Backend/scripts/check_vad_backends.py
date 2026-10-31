#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
from pathlib import Path

from huz_subtitle.cli import (
    Segment,
    build_segments,
    extract_audio,
    parse_args,
    probe_duration,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MEDIA = REPO_ROOT / "test.mp4"
DEFAULT_MODEL = REPO_ROOT / "models" / "FireRedASR2-AED-mlx"
BOUNDARY_TOLERANCE_SECONDS = 0.45
SPEECH_SECONDS_TOLERANCE = 1.5

BASELINES = {
    "pyannote_mlx": {
        "count": 16,
        "speechSeconds": 52.322,
        "segments": [
            (0.445, 3.392),
            (3.858, 5.837),
            (7.559, 9.215),
            (9.902, 12.56),
            (13.569, 14.835),
            (16.574, 17.806),
            (19.223, 20.726),
            (21.583, 26.503),
            (26.503, 31.07),
            (31.07, 35.433),
            (35.433, 40.424),
            (40.424, 44.869),
            (45.267, 49.508),
            (49.508, 54.003),
            (56.269, 60.509),
            (60.509, 63.328),
        ],
    },
    "firered": {
        "count": 15,
        "speechSeconds": 50.838,
        "segments": [
            (0.54, 5.82),
            (7.65, 9.21),
            (10.03, 12.5),
            (13.91, 14.81),
            (16.67, 17.72),
            (19.31, 20.64),
            (21.7, 26.7),
            (26.7, 31.69),
            (31.69, 36.65),
            (37.09, 41.11),
            (41.11, 44.78),
            (45.64, 50.16),
            (50.16, 54.64),
            (56.72, 61.18),
            (61.18, 63.328),
        ],
    },
}


def make_args(media: Path, engine: str):
    return parse_args(
        [
            str(media),
            "--model",
            str(DEFAULT_MODEL),
            "--vad-engine",
            engine,
            "--preview-segments",
        ]
    )


def summarize(segments: list[Segment]) -> dict[str, object]:
    return {
        "count": len(segments),
        "first": [segments[0].start, segments[0].end] if segments else None,
        "last": [segments[-1].start, segments[-1].end] if segments else None,
        "speechSeconds": round(sum(segment.duration for segment in segments), 3),
    }


def assert_count(name: str, segments: list[Segment], expected: int) -> None:
    if len(segments) != expected:
        raise AssertionError(f"{name} expected {expected} segments, got {len(segments)}")


def assert_segment_shape(name: str, segments: list[Segment], duration: float) -> None:
    previous_end = 0.0
    for segment in segments:
        if segment.start < -0.001:
            raise AssertionError(f"{name} segment {segment.index} starts before zero")
        if segment.end > duration + 0.01:
            raise AssertionError(f"{name} segment {segment.index} exceeds media duration")
        if segment.duration < 0.15:
            raise AssertionError(
                f"{name} segment {segment.index} is suspiciously short: {segment.duration:.3f}s"
            )
        if segment.start < previous_end - 0.01:
            raise AssertionError(
                f"{name} segment {segment.index} overlaps previous segment "
                f"({segment.start:.3f} < {previous_end:.3f})"
            )
        previous_end = segment.end


def assert_baseline(name: str, segments: list[Segment], duration: float) -> None:
    baseline = BASELINES[name]
    assert_count(name, segments, int(baseline["count"]))
    assert_segment_shape(name, segments, duration)

    speech_seconds = sum(segment.duration for segment in segments)
    expected_speech_seconds = float(baseline["speechSeconds"])
    if abs(speech_seconds - expected_speech_seconds) > SPEECH_SECONDS_TOLERANCE:
        raise AssertionError(
            f"{name} speech seconds drifted: expected about "
            f"{expected_speech_seconds:.3f}, got {speech_seconds:.3f}"
        )

    expected_segments = baseline["segments"]
    for segment, expected in zip(segments, expected_segments):
        expected_start, expected_end = expected
        if abs(segment.start - expected_start) > BOUNDARY_TOLERANCE_SECONDS:
            raise AssertionError(
                f"{name} segment {segment.index} start drifted: "
                f"expected {expected_start:.3f}, got {segment.start:.3f}"
            )
        if abs(segment.end - expected_end) > BOUNDARY_TOLERANCE_SECONDS:
            raise AssertionError(
                f"{name} segment {segment.index} end drifted: "
                f"expected {expected_end:.3f}, got {segment.end:.3f}"
            )


def main() -> int:
    if not DEFAULT_MEDIA.exists():
        raise FileNotFoundError(f"Missing test media: {DEFAULT_MEDIA}")

    with tempfile.TemporaryDirectory(prefix="msub-vad-check-") as temp_dir:
        wav_path = Path(temp_dir) / "input.wav"
        extract_audio(DEFAULT_MEDIA, wav_path)
        duration = probe_duration(wav_path)

        pyannote_args = make_args(DEFAULT_MEDIA, "pyannote_mlx")
        pyannote_segments = build_segments(wav_path, duration, pyannote_args)
        assert_baseline("pyannote_mlx", pyannote_segments, duration)

        firered_args = make_args(DEFAULT_MEDIA, "firered")
        firered_segments = build_segments(wav_path, duration, firered_args)
        assert_baseline("firered", firered_segments, duration)

        missing_args = make_args(DEFAULT_MEDIA, "firered")
        missing_args.firered_vad_model = "/private/tmp/msub-missing-firered-vad"
        try:
            build_segments(wav_path, duration, missing_args)
        except RuntimeError as exc:
            if "FireRedVAD failed" not in str(exc):
                raise
        else:
            raise AssertionError("explicit FireRedVAD unexpectedly fell back instead of failing")

    print(
        json.dumps(
            {
                "ok": True,
                "pyannote_mlx": summarize(pyannote_segments),
                "firered": summarize(firered_segments),
                "explicitFireredFailure": True,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
