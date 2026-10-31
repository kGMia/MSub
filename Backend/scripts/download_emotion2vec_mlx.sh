#!/bin/sh
set -eu

MODEL_ID="${MSUB_EMOTION_MLX_MODEL_ID:-mlx-community/emotion2vec-plus-large-mlx}"
DEST="${MSUB_EMOTION_MLX_MODEL_DIR:-models/emotion2vec-plus-large-mlx}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
