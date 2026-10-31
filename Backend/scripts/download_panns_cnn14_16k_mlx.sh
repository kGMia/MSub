#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UV_CACHE_DIR=.uv-cache uv run python scripts/convert_panns_cnn14_16k_to_mlx.py --download "$@"
