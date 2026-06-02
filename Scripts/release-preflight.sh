#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

INCLUDE_MODEL="${MSUB_INCLUDE_MODEL:-0}"
INCLUDE_SENSEVOICE_MODEL="${MSUB_INCLUDE_SENSEVOICE_MODEL:-0}"
INCLUDE_MIMO_MODEL="${MSUB_INCLUDE_MIMO_MODEL:-0}"
INCLUDE_FIRERED_VAD_MODEL="${MSUB_INCLUDE_FIRERED_VAD_MODEL:-1}"
INCLUDE_DIARIZATION_MODEL="${MSUB_INCLUDE_DIARIZATION_MODEL:-0}"
INCLUDE_SPEAKER_RECOGNITION_MODEL="${MSUB_INCLUDE_SPEAKER_RECOGNITION_MODEL:-0}"
INCLUDE_EMOTION_MODEL="${MSUB_INCLUDE_EMOTION_MODEL:-0}"
INCLUDE_VENV="${MSUB_INCLUDE_VENV:-1}"
INCLUDE_PYTHON_RUNTIME="${MSUB_INCLUDE_PYTHON_RUNTIME:-$INCLUDE_VENV}"
REQUIRE_OPTIONAL_DEPS="${MSUB_REQUIRE_OPTIONAL_DEPS:-1}"
REQUIRE_SPEAKER_DEPS="${MSUB_REQUIRE_SPEAKER_DEPS:-$REQUIRE_OPTIONAL_DEPS}"
REQUIRE_EMOTION_DEPS="${MSUB_REQUIRE_EMOTION_DEPS:-$REQUIRE_OPTIONAL_DEPS}"
REQUIRE_DIARIZATION_DEPS="${MSUB_REQUIRE_DIARIZATION_DEPS:-$REQUIRE_OPTIONAL_DEPS}"

fail() {
    echo "release preflight failed: $*" >&2
    exit 1
}

note() {
    echo "release preflight: $*"
}

require_file() {
    [ -f "$1" ] || fail "$2 not found: $1"
}

require_dir() {
    [ -d "$1" ] || fail "$2 not found: $1"
}

require_executable() {
    [ -x "$1" ] || fail "$2 is not executable: $1"
}

require_model_dir() {
    directory="$1"
    label="$2"
    require_file "$directory/config.json" "$label config.json"
    if ! find "$directory" -maxdepth 1 \( -name '*.safetensors' -o -name '*.npz' \) | grep -q .; then
        fail "$label weights not found in $directory"
    fi
}

require_nonempty_dir() {
    directory="$1"
    label="$2"
    require_dir "$directory" "$label directory"
    if ! find "$directory" -mindepth 1 -maxdepth 1 | grep -q .; then
        fail "$label directory is empty: $directory"
    fi
}

if [ "$INCLUDE_VENV" = "1" ]; then
    require_executable "$REPO_ROOT/.venv/bin/python" "backend virtualenv Python"

    PREFLIGHT_CACHE="$REPO_ROOT/.release-preflight-cache"
    mkdir -p "$PREFLIGHT_CACHE/matplotlib" "$PREFLIGHT_CACHE/huggingface" "$PREFLIGHT_CACHE/modelscope"
    export MPLCONFIGDIR="$PREFLIGHT_CACHE/matplotlib"
    export HF_HOME="$PREFLIGHT_CACHE/huggingface"
    export MODELSCOPE_CACHE="$PREFLIGHT_CACHE/modelscope"
    export PYTHONNOUSERSITE=1
    export PYTHONDONTWRITEBYTECODE=1
    export MSUB_REQUIRE_SPEAKER_DEPS="$REQUIRE_SPEAKER_DEPS"
    export MSUB_REQUIRE_EMOTION_DEPS="$REQUIRE_EMOTION_DEPS"
    export MSUB_REQUIRE_DIARIZATION_DEPS="$REQUIRE_DIARIZATION_DEPS"

    "$REPO_ROOT/.venv/bin/python" - <<'PY'
import importlib
import os
import sys

groups = {
    "core": [
        "fastapi",
        "uvicorn",
        "multipart",
        "fireredvad",
        "mlx",
        "mlx_audio",
        "huggingface_hub",
    ],
}
if os.getenv("MSUB_REQUIRE_SPEAKER_DEPS", "1") == "1":
    groups["speaker"] = ["funasr", "modelscope", "torch", "torchaudio", "soundfile"]
if os.getenv("MSUB_REQUIRE_EMOTION_DEPS", "1") == "1":
    groups["emotion"] = ["funasr", "modelscope", "torch", "torchaudio", "soundfile"]
if os.getenv("MSUB_REQUIRE_DIARIZATION_DEPS", "1") == "1":
    groups["diarization"] = ["pyannote.audio"]

missing = []
for group, modules in groups.items():
    for module in modules:
        try:
            importlib.import_module(module)
        except Exception as exc:
            missing.append(f"{group}: {module} ({exc})")

if missing:
    print("Missing or broken backend dependencies:", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
PY

    if [ "$INCLUDE_PYTHON_RUNTIME" = "1" ]; then
        PYTHON_ROOT="$("$REPO_ROOT/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
        require_dir "$PYTHON_ROOT" "base Python runtime"
        require_executable "$PYTHON_ROOT/bin/python3.12" "base Python runtime executable"
    fi
else
    note "MSUB_INCLUDE_VENV=0; release will require uv and dependencies on the user's Mac."
fi

require_executable "$APP_ROOT/Sources/MSub/ffmpeg" "bundled ffmpeg"

case "$(file "$APP_ROOT/Sources/MSub/ffmpeg")" in
    *arm64*) ;;
    *) fail "bundled ffmpeg is not arm64; current release defaults to Apple Silicon" ;;
esac

if [ "$INCLUDE_MODEL" = "1" ]; then
    require_model_dir "$REPO_ROOT/models/FireRedASR2-AED-mlx" "FireRedASR2-AED MLX"
else
    note "MSUB_INCLUDE_MODEL=0; users will be prompted to choose or download FireRedASR2-AED MLX weights."
fi

if [ "$INCLUDE_SENSEVOICE_MODEL" = "1" ]; then
    require_model_dir "$REPO_ROOT/models/SenseVoiceSmall" "SenseVoiceSmall"
fi

if [ "$INCLUDE_MIMO_MODEL" = "1" ]; then
    require_model_dir "$REPO_ROOT/models/MiMo-V2.5-ASR-MLX-4bit" "MiMo-V2.5-ASR MLX"
    require_model_dir "$REPO_ROOT/models/MiMo-Audio-Tokenizer" "MiMo Audio Tokenizer"
fi

if [ "$INCLUDE_FIRERED_VAD_MODEL" = "1" ]; then
    require_file "$REPO_ROOT/models/FireRedVAD/VAD/model.pth.tar" "FireRedVAD model"
    require_file "$REPO_ROOT/models/FireRedVAD/VAD/cmvn.ark" "FireRedVAD cmvn"
fi

if [ "$INCLUDE_DIARIZATION_MODEL" = "1" ]; then
    require_file "$REPO_ROOT/models/pyannote-speaker-diarization-community-1/config.yaml" "pyannote diarization config"
fi

if [ "$INCLUDE_SPEAKER_RECOGNITION_MODEL" = "1" ]; then
    require_nonempty_dir "$REPO_ROOT/models/speech_eres2netv2_sv_zh-cn_16k-common" "ERes2NetV2 speaker model"
fi

if [ "$INCLUDE_EMOTION_MODEL" = "1" ]; then
    require_nonempty_dir "$REPO_ROOT/models/emotion2vec_plus_base" "emotion2vec_plus_base"
fi

note "ok"
