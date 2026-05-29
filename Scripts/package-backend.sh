#!/bin/sh
set -eu

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    echo "Xcode build environment not found; skipping backend packaging."
    exit 0
fi

REPO_ROOT="$(cd "${SRCROOT}/../.." && pwd)"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/backend"
MODEL_SOURCE="$REPO_ROOT/models/FireRedASR2-AED-mlx"
SENSEVOICE_MODEL_SOURCE="$REPO_ROOT/models/SenseVoiceSmall"
MIMO_MODEL_SOURCE="$REPO_ROOT/models/MiMo-V2.5-ASR-MLX-4bit"
MIMO_TOKENIZER_SOURCE="$REPO_ROOT/models/MiMo-Audio-Tokenizer"
FIRERED_VAD_MODEL_SOURCE="$REPO_ROOT/models/FireRedVAD"
DIARIZATION_MODEL_SOURCE="$REPO_ROOT/models/pyannote-speaker-diarization-community-1"

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
INCLUDE_SENSEVOICE_MODEL="${MSUB_INCLUDE_SENSEVOICE_MODEL:-0}"
INCLUDE_MIMO_MODEL="${MSUB_INCLUDE_MIMO_MODEL:-0}"
INCLUDE_FIRERED_VAD_MODEL="${MSUB_INCLUDE_FIRERED_VAD_MODEL:-1}"
INCLUDE_DIARIZATION_MODEL="${MSUB_INCLUDE_DIARIZATION_MODEL:-0}"
INCLUDE_VENV="${MSUB_INCLUDE_VENV:-1}"
INCLUDE_PYTHON_RUNTIME="${MSUB_INCLUDE_PYTHON_RUNTIME:-$INCLUDE_VENV}"
SOURCE_MODEL_JSON="null"
SOURCE_SENSEVOICE_MODEL_JSON="null"
SOURCE_MIMO_MODEL_JSON="null"
SOURCE_MIMO_TOKENIZER_JSON="null"
SOURCE_FIRERED_VAD_MODEL_JSON="null"
SOURCE_DIARIZATION_MODEL_JSON="null"

if [ -f "$MODEL_SOURCE/model.safetensors" ] && [ -f "$MODEL_SOURCE/config.json" ]; then
    SOURCE_MODEL_JSON="\"$MODEL_SOURCE\""
fi

if [ -f "$SENSEVOICE_MODEL_SOURCE/config.json" ] && { ls "$SENSEVOICE_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$SENSEVOICE_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_SENSEVOICE_MODEL_JSON="\"$SENSEVOICE_MODEL_SOURCE\""
fi

if [ -f "$MIMO_MODEL_SOURCE/config.json" ] && { ls "$MIMO_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$MIMO_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_MIMO_MODEL_JSON="\"$MIMO_MODEL_SOURCE\""
fi

if [ -f "$MIMO_TOKENIZER_SOURCE/config.json" ] && { ls "$MIMO_TOKENIZER_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$MIMO_TOKENIZER_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_MIMO_TOKENIZER_JSON="\"$MIMO_TOKENIZER_SOURCE\""
fi

if [ -f "$FIRERED_VAD_MODEL_SOURCE/VAD/model.pth.tar" ] && [ -f "$FIRERED_VAD_MODEL_SOURCE/VAD/cmvn.ark" ]; then
    SOURCE_FIRERED_VAD_MODEL_JSON="\"$FIRERED_VAD_MODEL_SOURCE\""
fi

if [ -f "$DIARIZATION_MODEL_SOURCE/config.yaml" ]; then
    SOURCE_DIARIZATION_MODEL_JSON="\"$DIARIZATION_MODEL_SOURCE\""
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

if [ "$INCLUDE_SENSEVOICE_MODEL" = "1" ]; then
    if [ "$SOURCE_SENSEVOICE_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_SENSEVOICE_MODEL=1 but $SENSEVOICE_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$SENSEVOICE_MODEL_SOURCE" \
        "$DEST/models/"
else
    echo "Skipping SenseVoice model copy. Set MSUB_INCLUDE_SENSEVOICE_MODEL=1 to embed local SenseVoiceSmall weights."
fi

if [ "$INCLUDE_MIMO_MODEL" = "1" ]; then
    if [ "$SOURCE_MIMO_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_MIMO_MODEL=1 but $MIMO_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    if [ "$SOURCE_MIMO_TOKENIZER_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_MIMO_MODEL=1 but $MIMO_TOKENIZER_SOURCE is not a valid MiMo audio tokenizer directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$MIMO_MODEL_SOURCE" \
        "$DEST/models/"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$MIMO_TOKENIZER_SOURCE" \
        "$DEST/models/"
else
    echo "Skipping MiMo model copy. Set MSUB_INCLUDE_MIMO_MODEL=1 to embed local MiMo weights and tokenizer."
fi

if [ "$INCLUDE_FIRERED_VAD_MODEL" = "1" ]; then
    if [ "$SOURCE_FIRERED_VAD_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_FIRERED_VAD_MODEL=1 but $FIRERED_VAD_MODEL_SOURCE/VAD is not a valid FireRedVAD model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$FIRERED_VAD_MODEL_SOURCE" \
        "$DEST/models/"
else
    echo "Skipping FireRedVAD model copy. Set MSUB_INCLUDE_FIRERED_VAD_MODEL=1 to embed local FireRedVAD weights."
fi

if [ "$INCLUDE_DIARIZATION_MODEL" = "1" ]; then
    if [ ! -f "$DIARIZATION_MODEL_SOURCE/config.yaml" ]; then
        echo "MSUB_INCLUDE_DIARIZATION_MODEL=1 but $DIARIZATION_MODEL_SOURCE/config.yaml was not found." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    rsync -a --delete --delete-excluded \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        "$DIARIZATION_MODEL_SOURCE" \
        "$DEST/models/"
else
    echo "Skipping diarization model copy. Set MSUB_INCLUDE_DIARIZATION_MODEL=1 to embed local pyannote weights."
fi

cat > "$DEST/backend-manifest.json" <<EOF
{
  "name": "MSub backend",
  "includeModel": "$INCLUDE_MODEL",
  "includeSenseVoiceModel": "$INCLUDE_SENSEVOICE_MODEL",
  "includeMiMoModel": "$INCLUDE_MIMO_MODEL",
  "includeFireRedVADModel": "$INCLUDE_FIRERED_VAD_MODEL",
  "includeDiarizationModel": "$INCLUDE_DIARIZATION_MODEL",
  "includeVenv": "$INCLUDE_VENV",
  "includePythonRuntime": "$INCLUDE_PYTHON_RUNTIME",
  "sourceModelPath": $SOURCE_MODEL_JSON,
  "sourceSenseVoiceModelPath": $SOURCE_SENSEVOICE_MODEL_JSON,
  "sourceMiMoModelPath": $SOURCE_MIMO_MODEL_JSON,
  "sourceMiMoTokenizerPath": $SOURCE_MIMO_TOKENIZER_JSON,
  "sourceFireRedVADModelPath": $SOURCE_FIRERED_VAD_MODEL_JSON,
  "sourceDiarizationModelPath": $SOURCE_DIARIZATION_MODEL_JSON,
  "modelPath": "models/FireRedASR2-AED-mlx",
  "senseVoiceModelPath": "models/SenseVoiceSmall",
  "mimoModelPath": "models/MiMo-V2.5-ASR-MLX-4bit",
  "mimoTokenizerPath": "models/MiMo-Audio-Tokenizer",
  "fireRedVADModelPath": "models/FireRedVAD",
  "diarizationModelPath": "models/pyannote-speaker-diarization-community-1",
  "entrypoint": "msub-web"
}
EOF
