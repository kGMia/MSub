#!/usr/bin/env bash
set -euo pipefail

MODEL_ID="${MSUB_DIARIZATION_MODEL_ID:-pyannote/speaker-diarization-community-1}"
TARGET_DIR="${1:-models/pyannote-speaker-diarization-community-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v hf >/dev/null 2>&1; then
  HF_BIN="$(command -v hf)"
elif [ -x "${REPO_ROOT}/.venv/bin/hf" ]; then
  HF_BIN="${REPO_ROOT}/.venv/bin/hf"
fi

download_gitee_mirror() {
  if [ "${MODEL_ID}" != "pyannote/speaker-diarization-community-1" ]; then
    echo "Gitee fallback only supports pyannote/speaker-diarization-community-1." >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "Could not find curl for the Gitee fallback download." >&2
    exit 1
  fi

  local base_url="https://gitee.com/hf-models/speaker-diarization-community-1/raw/main"
  mkdir -p "${TARGET_DIR}/embedding" "${TARGET_DIR}/plda" "${TARGET_DIR}/segmentation"
  for file in \
    ".gitattributes" \
    "README.md" \
    "config.yaml" \
    "diarization.gif" \
    "embedding/README.md" \
    "embedding/pytorch_model.bin" \
    "plda/README.md" \
    "plda/plda.npz" \
    "plda/xvec_transform.npz" \
    "segmentation/pytorch_model.bin"
  do
    curl -L -f -o "${TARGET_DIR}/${file}" "${base_url}/${file}"
  done
}

mkdir -p "${TARGET_DIR}"
if [ -n "${HF_BIN:-}" ]; then
  if ! "${HF_BIN}" download "${MODEL_ID}" --local-dir "${TARGET_DIR}"; then
    echo "Hugging Face download failed; falling back to Gitee mirror." >&2
    download_gitee_mirror
  fi
else
  echo "Hugging Face CLI not found; falling back to Gitee mirror." >&2
  download_gitee_mirror
fi

if [ ! -f "${TARGET_DIR}/config.yaml" ]; then
  echo "Downloaded files, but ${TARGET_DIR}/config.yaml was not found." >&2
  exit 1
fi

echo "Downloaded ${MODEL_ID} to ${TARGET_DIR}"
