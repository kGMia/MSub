#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import resource
import tempfile
import time
from pathlib import Path
from typing import Any
from collections.abc import Callable

from huz_subtitle.cli import (
    Segment,
    args_for_segment_generation,
    build_segments,
    clear_stt_model_cache,
    extract_audio,
    extract_chunk,
    load_stt_model,
    parse_args as parse_msub_args,
    probe_duration,
    release_inference_memory,
    stt_model_cache_info,
    transcribe_one_streaming,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MEDIA = REPO_ROOT / "test.mp4"
DEFAULT_MODEL = REPO_ROOT / "models" / "FireRedASR2-AED-mlx"


def max_rss_mb() -> float:
    value = float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    # macOS reports bytes, Linux reports KiB.
    if value > 10_000_000:
        return round(value / 1024 / 1024, 1)
    return round(value / 1024, 1)


def timed(name: str, metrics: dict[str, Any], callback: Callable[[], Any]) -> Any:
    started = time.perf_counter()
    result = callback()
    metrics[name] = {
        "seconds": round(time.perf_counter() - started, 4),
        "maxRssMB": max_rss_mb(),
    }
    return result


def make_msub_args(media: Path, model: Path | str, vad_engine: str):
    return parse_msub_args(
        [
            str(media),
            "--model",
            str(model),
            "--vad-engine",
            vad_engine,
            "--preview-segments",
        ]
    )


def segment_payload(segment: Segment) -> dict[str, float | int]:
    return {
        "index": segment.index,
        "start": segment.start,
        "end": segment.end,
        "duration": round(segment.duration, 3),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark MSub backend pipeline phases.")
    parser.add_argument("--media", type=Path, default=DEFAULT_MEDIA)
    parser.add_argument("--model", default=str(DEFAULT_MODEL))
    parser.add_argument(
        "--vad-engine",
        choices=["auto", "pyannote_mlx", "firered", "energy"],
        default="auto",
    )
    parser.add_argument(
        "--max-chunks",
        type=int,
        default=0,
        help="Maximum chunks to cut for the chunking benchmark. 0 means all segments.",
    )
    parser.add_argument(
        "--include-model",
        action="store_true",
        help="Also benchmark STT model load and short transcription.",
    )
    parser.add_argument(
        "--transcribe-segments",
        type=int,
        default=1,
        help="Number of leading segments to transcribe when --include-model is set.",
    )
    parser.add_argument(
        "--clear-model-cache",
        action="store_true",
        help="Clear the in-process STT model cache before loading.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    media = args.media.expanduser().resolve()
    if not media.exists():
        raise FileNotFoundError(f"Media file not found: {media}")

    msub_args = make_msub_args(media, args.model, args.vad_engine)
    metrics: dict[str, Any] = {}
    events: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="msub-benchmark-") as temp_dir:
        temp_root = Path(temp_dir)
        wav_path = temp_root / "input.wav"
        timed(
            "extractAudio",
            metrics,
            lambda: extract_audio(media, wav_path, duration=probe_duration(media)),
        )
        duration = timed("probeWavDuration", metrics, lambda: probe_duration(wav_path))
        segments = timed(
            "vad",
            metrics,
            lambda: build_segments(
                wav_path,
                duration,
                msub_args,
                progress_callback=events.append,
            ),
        )

        chunk_limit = len(segments) if args.max_chunks <= 0 else min(args.max_chunks, len(segments))
        chunk_segments = segments[:chunk_limit]
        chunk_root = temp_root / "chunks"
        chunk_root.mkdir(parents=True, exist_ok=True)

        def cut_chunks() -> int:
            total_bytes = 0
            for segment in chunk_segments:
                chunk_path = chunk_root / f"chunk_{segment.index:04d}.wav"
                extract_chunk(wav_path, chunk_path, segment.start, segment.end)
                total_bytes += chunk_path.stat().st_size
            return total_bytes

        chunk_bytes = timed("cutChunks", metrics, cut_chunks)

        transcription_samples: list[dict[str, Any]] = []
        if args.include_model:
            if args.clear_model_cache:
                clear_stt_model_cache()
            model = timed("loadModel", metrics, lambda: load_stt_model(str(msub_args.model)))

            transcribe_limit = max(0, min(args.transcribe_segments, len(segments)))

            def transcribe_sample() -> None:
                for segment in segments[:transcribe_limit]:
                    chunk_path = chunk_root / f"transcribe_{segment.index:04d}.wav"
                    extract_chunk(wav_path, chunk_path, segment.start, segment.end)
                    chunk_args = args_for_segment_generation(msub_args, segment)
                    result = transcribe_one_streaming(
                        model,
                        chunk_path,
                        chunk_args,
                        segment,
                        transcribe_limit,
                    )
                    transcription_samples.append(
                        {
                            "segment": segment_payload(segment),
                            "text": str(getattr(result, "text", "") or "")[:160],
                            "tokens": getattr(result, "total_tokens", None),
                        }
                    )
                    release_inference_memory(force=True)

            timed("transcribeSample", metrics, transcribe_sample)

    payload = {
        "media": str(media),
        "model": str(msub_args.model),
        "vadEngine": getattr(msub_args, "resolved_vad_engine", args.vad_engine),
        "duration": round(float(duration), 3),
        "segments": {
            "count": len(segments),
            "speechSeconds": round(sum(segment.duration for segment in segments), 3),
            "first": segment_payload(segments[0]) if segments else None,
            "last": segment_payload(segments[-1]) if segments else None,
        },
        "chunking": {
            "count": chunk_limit,
            "bytes": chunk_bytes,
        },
        "metrics": metrics,
        "events": {
            "vadProgress": sum(1 for event in events if event.get("event") == "vad_progress"),
            "names": sorted({str(event.get("event")) for event in events if event.get("event")}),
        },
        "modelCache": stt_model_cache_info(),
        "transcriptionSamples": transcription_samples,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
