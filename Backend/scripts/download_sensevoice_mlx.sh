#!/bin/sh
set -eu

MODEL_ID="${MSUB_SENSEVOICE_MODEL_ID:-mlx-community/SenseVoiceSmall}"
DEST="${MSUB_SENSEVOICE_MODEL_DIR:-models/SenseVoiceSmall}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
