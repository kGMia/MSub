#!/bin/sh
set -eu

MODEL_ID="${MSUB_SPEAKER_DIARIZATION_COREML_MODEL_ID:-FluidInference/speaker-diarization-coreml}"
DEST="${MSUB_SPEAKER_DIARIZATION_COREML_MODEL_DIR:-models/speaker-diarization-coreml}"

UV_CACHE_DIR="${UV_CACHE_DIR:-.uv-cache}" uv run hf download "$MODEL_ID" --local-dir "$DEST"
