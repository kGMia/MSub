#!/bin/sh
set -eu

MODEL_ID="${MSUB_MIMO_MODEL_ID:-mlx-community/MiMo-V2.5-ASR-MLX-4bit}"
MODEL_DEST="${MSUB_MIMO_MODEL_DIR:-models/MiMo-V2.5-ASR-MLX-4bit}"
TOKENIZER_ID="${MSUB_MIMO_TOKENIZER_ID:-mlx-community/MiMo-Audio-Tokenizer}"
TOKENIZER_DEST="${MSUB_MIMO_TOKENIZER_DIR:-models/MiMo-Audio-Tokenizer}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$TOKENIZER_ID" --local-dir "$TOKENIZER_DEST"
UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$MODEL_DEST"
