#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${HUZ_MODEL:-mlx-community/FireRedASR2-AED-mlx}"
TARGET_DIR="${1:-models/FireRedASR2-AED-mlx}"

mkdir -p "${TARGET_DIR}"
hf download "${MODEL_ID}" --local-dir "${TARGET_DIR}"

echo "Downloaded ${MODEL_ID} to ${TARGET_DIR}"
