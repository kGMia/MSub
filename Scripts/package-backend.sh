#!/bin/sh
set -eu

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    echo "Xcode build environment not found; skipping backend packaging."
    exit 0
fi

REPO_ROOT="$(cd "${SRCROOT}/../.." && pwd)"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/backend"

mkdir -p "$DEST"
rm -rf "$DEST/.venv" "$DEST/.uv-cache"

rsync -a --delete --delete-excluded \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    --exclude ".DS_Store" \
    "$REPO_ROOT/src" \
    "$DEST/"

cp "$REPO_ROOT/pyproject.toml" "$DEST/pyproject.toml"
cp "$REPO_ROOT/uv.lock" "$DEST/uv.lock"

mkdir -p "$DEST/output"

if [ "${HUZ_INCLUDE_MODEL:-0}" = "1" ]; then
    mkdir -p "$DEST/models"
    rsync -a --delete \
        "$REPO_ROOT/models/FireRedASR2-AED-mlx" \
        "$DEST/models/"
else
    echo "Skipping model copy. Set HUZ_INCLUDE_MODEL=1 to embed local weights in the app bundle."
fi
