from __future__ import annotations

import argparse
import importlib.util
import platform
import shutil
import sys


def check_module(name: str) -> str:
    return "ok" if importlib.util.find_spec(name) else "missing"


def check_mlx_runtime() -> tuple[str, bool]:
    if not importlib.util.find_spec("mlx"):
        return "missing", False
    try:
        import mlx.core as mx

        value = mx.array([1.0])
        mx.eval(value)
        return "metal ok", True
    except Exception as exc:  # noqa: BLE001 - show runtime availability clearly.
        message = str(exc).splitlines()[0]
        return f"runtime unavailable: {message}", False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check Huz Subtitle environment.")
    parser.add_argument(
        "--runtime",
        action="store_true",
        help="Also import MLX and run a tiny Metal evaluation.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runtime_status, runtime_ok = (
        check_mlx_runtime() if args.runtime else ("skipped", True)
    )
    checks = {
        "python": sys.version.split()[0],
        "machine": platform.machine(),
        "ffmpeg": shutil.which("ffmpeg") or "missing",
        "mlx": check_module("mlx"),
        "mlx_runtime": runtime_status,
        "mlx_audio": check_module("mlx_audio"),
        "sentencepiece": check_module("sentencepiece"),
    }

    for key, value in checks.items():
        print(f"{key}: {value}")

    failed = [
        key
        for key, value in checks.items()
        if value == "missing" or (key == "machine" and value != "arm64")
    ]
    if not runtime_ok:
        failed.append("mlx_runtime")
    if failed:
        print("failed:", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
