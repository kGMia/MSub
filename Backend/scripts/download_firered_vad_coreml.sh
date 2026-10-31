#!/bin/sh
set -eu

MODEL_ID="${MSUB_FIRERED_VAD_COREML_MODEL_ID:-illitan/FireRedVAD-CoreML}"
DEST="${MSUB_FIRERED_VAD_COREML_MODEL_DIR:-models/FireRedVAD-CoreML}"
CMVN_MODEL_ID="${MSUB_FIRERED_VAD_CMVN_MODEL_ID:-FireRedTeam/FireRedVAD}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$CMVN_MODEL_ID" Stream-VAD/cmvn.ark --local-dir "$DEST/.cmvn-source"
cp "$DEST/.cmvn-source/Stream-VAD/cmvn.ark" "$DEST/cmvn.ark"
rm -rf "$DEST/.cmvn-source"
