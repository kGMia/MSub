#!/usr/bin/env python3
"""Compare MSUB_MLX_CACHE_CLEAR_POLICY settings on a real transcription job.

Runs the same media file through `huz_subtitle.cli` once per policy in a
fresh subprocess (so MLX state never leaks between runs) and reports wall
time and peak memory for each.

Usage (on the Mac, inside the project environment):

    UV_CACHE_DIR=.uv-cache uv run python scripts/benchmark_cache_policy.py test.mp4
    UV_CACHE_DIR=.uv-cache uv run python scripts/benchmark_cache_policy.py test.mp4 \
        --policies always interval job --interval 8 --model ./models/FireRedASR2-AED-mlx

Interpretation: `always` clears the MLX buffer cache and runs gc.collect()
after every chunk (lowest memory, slowest), `interval` clears every N chunks,
`job` clears only at the end (fastest, highest peak memory). If `interval`
or `job` is significantly faster with acceptable peak memory, set
MSUB_MLX_CACHE_CLEAR_POLICY accordingly when launching the backend.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MEDIA = REPO_ROOT / "test.mp4"
_PEAK_RSS_RE = re.compile(r"(\d+)\s+maximum resident set size")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "input",
        type=Path,
        nargs="?",
        default=DEFAULT_MEDIA,
        help=f"Media file to transcribe (default: {DEFAULT_MEDIA}).",
    )
    parser.add_argument(
        "--policies",
        nargs="+",
        default=["always", "interval", "job"],
        help="Cache-clear policies to compare (default: always interval job).",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=8,
        help="Chunk interval used by the 'interval' policy (default: 8).",
    )
    parser.add_argument("--model", default=None, help="ASR model id or local path.")
    parser.add_argument(
        "--extra-args",
        nargs=argparse.REMAINDER,
        default=[],
        help="Extra arguments forwarded to msub-srt after '--extra-args'.",
    )
    return parser.parse_args()


def run_once(
    media: Path,
    policy: str,
    interval: int,
    model: str | None,
    extra_args: list[str],
    output_dir: Path,
) -> tuple[float, int | None, int]:
    """Return (wall_seconds, peak_rss_bytes or None, returncode)."""
    env = os.environ.copy()
    env["MSUB_CLEAR_MLX_CACHE_EACH_CHUNK"] = "1"
    env["MSUB_MLX_CACHE_CLEAR_POLICY"] = policy
    env["MSUB_MLX_CACHE_CLEAR_INTERVAL"] = str(interval)

    command = [
        sys.executable,
        "-m",
        "huz_subtitle.cli",
        str(media),
        "-o",
        str(output_dir / f"bench-{policy}.srt"),
    ]
    if model:
        command += ["--model", model]
    command += extra_args

    time_binary = Path("/usr/bin/time")
    use_time = sys.platform == "darwin" and time_binary.exists()
    if use_time:
        command = [str(time_binary), "-l", *command]

    started = time.perf_counter()
    completed = subprocess.run(command, env=env, capture_output=True, text=True)
    elapsed = time.perf_counter() - started

    peak_rss: int | None = None
    if use_time:
        match = _PEAK_RSS_RE.search(completed.stderr)
        if match:
            peak_rss = int(match.group(1))
    if completed.returncode != 0:
        tail = "\n".join(completed.stderr.strip().splitlines()[-6:])
        print(f"  run failed (exit {completed.returncode}):\n{tail}", file=sys.stderr)
    return elapsed, peak_rss, completed.returncode


def format_bytes(value: int | None) -> str:
    if value is None:
        return "n/a"
    return f"{value / (1024 ** 3):.2f} GiB"


def main() -> int:
    args = parse_args()
    media = args.input.expanduser().resolve()
    if not media.exists():
        print(f"Input file does not exist: {media}", file=sys.stderr)
        return 1

    results: list[tuple[str, float, int | None, int]] = []
    with tempfile.TemporaryDirectory(prefix="msub-cache-bench-") as tmp:
        output_dir = Path(tmp)
        for policy in args.policies:
            print(f"policy={policy} ...", flush=True)
            elapsed, peak_rss, returncode = run_once(
                media, policy, args.interval, args.model, args.extra_args, output_dir
            )
            results.append((policy, elapsed, peak_rss, returncode))
            print(
                f"  wall={elapsed:.1f}s peak_rss={format_bytes(peak_rss)}"
                + ("" if returncode == 0 else f" (exit {returncode})"),
                flush=True,
            )

    ok = [entry for entry in results if entry[3] == 0]
    if len(ok) > 1:
        baseline = ok[0]
        print(f"\nsummary (baseline: {baseline[0]}):")
        for policy, elapsed, peak_rss, _ in ok:
            speedup = baseline[1] / elapsed if elapsed else 0.0
            print(
                f"  {policy:<10} wall={elapsed:8.1f}s ({speedup:4.2f}x) "
                f"peak_rss={format_bytes(peak_rss)}"
            )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
