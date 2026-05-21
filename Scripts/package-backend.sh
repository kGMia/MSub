#!/bin/sh
set -eu

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    echo "Xcode build environment not found; skipping backend packaging."
    exit 0
fi

REPO_ROOT="$(cd "${SRCROOT}/../.." && pwd)"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/backend"
MODEL_SOURCE="$REPO_ROOT/models/FireRedASR2-AED-mlx"

mkdir -p "$DEST"
rm -rf "$DEST/.uv-cache"

rsync -a --delete --delete-excluded \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    --exclude "*.pyo" \
    --exclude ".DS_Store" \
    --exclude ".git" \
    --exclude ".mypy_cache" \
    --exclude ".pytest_cache" \
    --exclude ".ruff_cache" \
    "$REPO_ROOT/src" \
    "$DEST/"

cp "$REPO_ROOT/pyproject.toml" "$DEST/pyproject.toml"
cp "$REPO_ROOT/uv.lock" "$DEST/uv.lock"
cp "$REPO_ROOT/README.md" "$DEST/README.md"
cp "$REPO_ROOT/.python-version" "$DEST/.python-version"

mkdir -p "$DEST/output"

INCLUDE_MODEL="${MSUB_INCLUDE_MODEL:-${HUZ_INCLUDE_MODEL:-0}}"
INCLUDE_VENV="${MSUB_INCLUDE_VENV:-1}"
INCLUDE_PYTHON_RUNTIME="${MSUB_INCLUDE_PYTHON_RUNTIME:-$INCLUDE_VENV}"
SOURCE_MODEL_JSON="null"

if [ -f "$MODEL_SOURCE/model.safetensors" ] && [ -f "$MODEL_SOURCE/config.json" ]; then
    SOURCE_MODEL_JSON="\"$MODEL_SOURCE\""
fi

if [ "$INCLUDE_VENV" = "1" ]; then
    if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
        echo "MSUB_INCLUDE_VENV=1 but $REPO_ROOT/.venv/bin/python was not found." >&2
        exit 1
    fi

    echo "Copying backend Python virtual environment."
    rsync -a --delete --delete-excluded \
        --exclude "__pycache__" \
        --exclude "*.pyc" \
        --exclude "*.pyo" \
        --exclude ".DS_Store" \
        --exclude "_editable_impl_*.pth" \
        "$REPO_ROOT/.venv" \
        "$DEST/"

    if [ "$INCLUDE_PYTHON_RUNTIME" = "1" ]; then
        PYTHON_ROOT="$("$REPO_ROOT/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
        if [ -z "$PYTHON_ROOT" ] || [ ! -d "$PYTHON_ROOT" ]; then
            echo "Could not locate the base Python runtime for $REPO_ROOT/.venv." >&2
            exit 1
        fi

        echo "Copying backend Python runtime from $PYTHON_ROOT."
        rsync -a --delete --delete-excluded \
            --exclude "__pycache__" \
            --exclude "*.pyc" \
            --exclude "*.pyo" \
            --exclude ".DS_Store" \
            "$PYTHON_ROOT/" \
            "$DEST/python/"
    else
        rm -rf "$DEST/python"
    fi
else
    rm -rf "$DEST/.venv" "$DEST/python"
    echo "Skipping venv copy. Set MSUB_INCLUDE_VENV=1 to embed backend dependencies in the app bundle."
fi

if [ "$INCLUDE_MODEL" = "1" ]; then
    mkdir -p "$DEST/models"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$MODEL_SOURCE" \
        "$DEST/models/"
else
    echo "Skipping model copy. Set MSUB_INCLUDE_MODEL=1 to embed local weights in the app bundle."
fi

cat > "$DEST/backend-manifest.json" <<EOF
{
  "name": "MSub backend",
  "includeModel": "$INCLUDE_MODEL",
  "includeVenv": "$INCLUDE_VENV",
  "includePythonRuntime": "$INCLUDE_PYTHON_RUNTIME",
  "sourceModelPath": $SOURCE_MODEL_JSON,
  "modelPath": "models/FireRedASR2-AED-mlx",
  "entrypoint": "msub-web"
}
EOF
