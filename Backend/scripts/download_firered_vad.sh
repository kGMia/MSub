#!/bin/sh
set -eu

MODEL_ID="${MSUB_FIRERED_VAD_MODEL_ID:-FireRedTeam/FireRedVAD}"
DEST="${MSUB_FIRERED_VAD_MODEL_DIR:-models/FireRedVAD}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
