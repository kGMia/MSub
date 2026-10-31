#!/bin/sh
set -eu

MODEL_ID="${MSUB_PYANNOTE_SEGMENTATION_MLX_MODEL_ID:-aufklarer/Pyannote-Segmentation-MLX}"
DEST="${MSUB_PYANNOTE_SEGMENTATION_MLX_MODEL_DIR:-models/Pyannote-Segmentation-MLX}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
