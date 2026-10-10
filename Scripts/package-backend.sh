#!/bin/bash
set -euo pipefail

# Visible in Xcode's build log, including cache hits and failed packaging runs.
MSUB_PACKAGE_STARTED=$SECONDS
MSUB_PACKAGE_PHASE_STARTED=$SECONDS
MSUB_PACKAGE_PHASE=setup
MSUB_PACKAGE_CACHE=miss
MSUB_PACKAGE_FILTER_DIR=""
package_phase() {
    echo "MSUB_PACKAGE_TIMING phase=$MSUB_PACKAGE_PHASE seconds=$((SECONDS - MSUB_PACKAGE_PHASE_STARTED))"
    MSUB_PACKAGE_PHASE="$1"
    MSUB_PACKAGE_PHASE_STARTED=$SECONDS
}
package_finished() {
    local result=$?
    if [ -n "$MSUB_PACKAGE_FILTER_DIR" ]; then rm -rf "$MSUB_PACKAGE_FILTER_DIR"; fi
    echo "MSUB_PACKAGE_TIMING phase=$MSUB_PACKAGE_PHASE seconds=$((SECONDS - MSUB_PACKAGE_PHASE_STARTED))"
    echo "MSUB_PACKAGE_TIMING total_seconds=$((SECONDS - MSUB_PACKAGE_STARTED)) cache=$MSUB_PACKAGE_CACHE exit=$result"
}
trap package_finished EXIT

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
MEGA_MODEL_SOURCE="$REPO_ROOT/models/Mega-ASR-bf16"
QWEN3_MODEL_SOURCE="$REPO_ROOT/models/Qwen3-ASR-1.7B-8bit"
FUNASR_MODEL_SOURCE="$REPO_ROOT/models/Fun-ASR-Nano-2512"
FIRERED_VAD_MODEL_SOURCE="$REPO_ROOT/models/FireRedVAD-CoreML"
DIARIZATION_MODEL_SOURCE="$REPO_ROOT/models/pyannote-speaker-diarization-community-1"
PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE="$REPO_ROOT/models/Pyannote-Segmentation-MLX"
SPEAKER_DIARIZATION_COREML_MODEL_SOURCE="$REPO_ROOT/models/speaker-diarization-coreml"
SPEAKER_RECOGNITION_MODEL_SOURCE="$REPO_ROOT/models/speech_eres2netv2_sv_zh-cn_16k-common"
EMOTION_MODEL_SOURCE="$REPO_ROOT/models/emotion2vec_plus_base"
EMOTION_MLX_MODEL_SOURCE="$REPO_ROOT/models/emotion2vec-plus-large-mlx"
PANNS_AUDIO_EVENT_MODEL_SOURCE="$REPO_ROOT/models/panns-cnn14-16k-mlx"
AUDIO_EVENT_MODEL_SOURCE="$PANNS_AUDIO_EVENT_MODEL_SOURCE"

mkdir -p "$DEST"

INCLUDE_MODEL="${MSUB_INCLUDE_MODEL:-${HUZ_INCLUDE_MODEL:-0}}"
INCLUDE_SENSEVOICE_MODEL="${MSUB_INCLUDE_SENSEVOICE_MODEL:-0}"
INCLUDE_MIMO_MODEL="${MSUB_INCLUDE_MIMO_MODEL:-0}"
INCLUDE_MEGA_MODEL="${MSUB_INCLUDE_MEGA_MODEL:-0}"
INCLUDE_QWEN3_MODEL="${MSUB_INCLUDE_QWEN3_MODEL:-0}"
INCLUDE_FUNASR_MODEL="${MSUB_INCLUDE_FUNASR_MODEL:-0}"
BACKEND_BUNDLE_PROFILE="${MSUB_BACKEND_BUNDLE_PROFILE:-core}"
if [ -n "${MSUB_INCLUDE_FIRERED_VAD_MODEL+x}" ]; then
    INCLUDE_FIRERED_VAD_MODEL="$MSUB_INCLUDE_FIRERED_VAD_MODEL"
elif [ "$BACKEND_BUNDLE_PROFILE" = "full" ] || [ "$BACKEND_BUNDLE_PROFILE" = "core" ]; then
    INCLUDE_FIRERED_VAD_MODEL=1
else
    INCLUDE_FIRERED_VAD_MODEL=0
fi
INCLUDE_DIARIZATION_MODEL="${MSUB_INCLUDE_DIARIZATION_MODEL:-0}"
if [ -n "${MSUB_INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL+x}" ]; then
    INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL="$MSUB_INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL"
elif [ "$BACKEND_BUNDLE_PROFILE" = "full" ] || [ "$BACKEND_BUNDLE_PROFILE" = "core" ]; then
    INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL=1
else
    INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL=0
fi
INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL="${MSUB_INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL:-0}"
INCLUDE_SPEAKER_RECOGNITION_MODEL="${MSUB_INCLUDE_SPEAKER_RECOGNITION_MODEL:-0}"
INCLUDE_EMOTION_MODEL="${MSUB_INCLUDE_EMOTION_MODEL:-0}"
INCLUDE_EMOTION_MLX_MODEL="${MSUB_INCLUDE_EMOTION_MLX_MODEL:-0}"
INCLUDE_AUDIO_EVENT_MODEL="${MSUB_INCLUDE_AUDIO_EVENT_MODEL:-0}"
INCLUDE_VENV="${MSUB_INCLUDE_VENV:-1}"
INCLUDE_PYTHON_RUNTIME="${MSUB_INCLUDE_PYTHON_RUNTIME:-$INCLUDE_VENV}"
SOURCE_MODEL_JSON="null"
SOURCE_SENSEVOICE_MODEL_JSON="null"
SOURCE_MIMO_MODEL_JSON="null"
SOURCE_MIMO_TOKENIZER_JSON="null"
SOURCE_MEGA_MODEL_JSON="null"
SOURCE_QWEN3_MODEL_JSON="null"
SOURCE_FUNASR_MODEL_JSON="null"
SOURCE_FIRERED_VAD_MODEL_JSON="null"
SOURCE_DIARIZATION_MODEL_JSON="null"
SOURCE_PYANNOTE_SEGMENTATION_MLX_MODEL_JSON="null"
SOURCE_SPEAKER_DIARIZATION_COREML_MODEL_JSON="null"
SOURCE_SPEAKER_RECOGNITION_MODEL_JSON="null"
SOURCE_EMOTION_MODEL_JSON="null"
SOURCE_EMOTION_MLX_MODEL_JSON="null"
SOURCE_AUDIO_EVENT_MODEL_JSON="null"
PACKAGE_STAMP="$DEST/.msub-package-signature"

RUNTIME_FILTER_TOOL="$SRCROOT/Scripts/package-runtime-filter.py"
FINGERPRINT_TOOL="$SRCROOT/Scripts/package-fingerprint.py"
FINGERPRINT_PYTHON="$REPO_ROOT/.venv/bin/python"
if [ ! -x "$FINGERPRINT_PYTHON" ]; then FINGERPRINT_PYTHON="$(command -v python3)"; fi
RUNTIME_STAMP="$DEST/.msub-runtime-signature"
PYTHON_ROOT=""
if [ "$INCLUDE_VENV" = "1" ] && [ "$INCLUDE_PYTHON_RUNTIME" = "1" ]; then
    PYTHON_ROOT="$("$REPO_ROOT/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
fi

directory_signature() {
    "$FINGERPRINT_PYTHON" "$FINGERPRINT_TOOL" "$1"
}

runtime_signature() {
    {
        echo "$BACKEND_BUNDLE_PROFILE:$INCLUDE_VENV:$INCLUDE_PYTHON_RUNTIME:${MSUB_SLIM_VENV:-1}"
        "$FINGERPRINT_PYTHON" "$FINGERPRINT_TOOL" --content \
            "$REPO_ROOT/pyproject.toml" "$REPO_ROOT/uv.lock" \
            "$SRCROOT/Scripts/package-backend.sh" "$FINGERPRINT_TOOL" "$RUNTIME_FILTER_TOOL"
        if [ "$INCLUDE_VENV" = "1" ]; then directory_signature "$REPO_ROOT/.venv"; fi
        if [ -n "$PYTHON_ROOT" ]; then directory_signature "$PYTHON_ROOT"; fi
    } | shasum | awk '{print $1}'
}
package_phase fingerprint
CURRENT_RUNTIME_SIGNATURE="$(runtime_signature)"
RUNTIME_UNCHANGED=0
if [ "${MSUB_FORCE_PACKAGE_BACKEND:-0}" != "1" ] \
    && [ -f "$RUNTIME_STAMP" ] \
    && [ "$(cat "$RUNTIME_STAMP")" = "$CURRENT_RUNTIME_SIGNATURE" ]; then
    if [ "$INCLUDE_VENV" != "1" ] || [ -x "$DEST/.venv/bin/python" ]; then
        RUNTIME_UNCHANGED=1
    fi
fi

package_signature() {
    {
        echo "profile=$BACKEND_BUNDLE_PROFILE"
        echo "runtime=$CURRENT_RUNTIME_SIGNATURE"
        echo "include_model=$INCLUDE_MODEL"
        echo "include_sensevoice=$INCLUDE_SENSEVOICE_MODEL"
        echo "include_mimo=$INCLUDE_MIMO_MODEL"
        echo "include_mega=$INCLUDE_MEGA_MODEL"
        echo "include_qwen3=$INCLUDE_QWEN3_MODEL"
        echo "include_funasr=$INCLUDE_FUNASR_MODEL"
        echo "include_firered_vad=$INCLUDE_FIRERED_VAD_MODEL"
        echo "include_diarization=$INCLUDE_DIARIZATION_MODEL"
        echo "include_pyannote_mlx=$INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL"
        echo "include_coreml_speaker=$INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL"
        echo "include_speaker_recognition=$INCLUDE_SPEAKER_RECOGNITION_MODEL"
        echo "include_emotion=$INCLUDE_EMOTION_MODEL"
        echo "include_emotion_mlx=$INCLUDE_EMOTION_MLX_MODEL"
        echo "include_audio_event=$INCLUDE_AUDIO_EVENT_MODEL"
        echo "include_venv=$INCLUDE_VENV"
        echo "include_python_runtime=$INCLUDE_PYTHON_RUNTIME"
        echo "slim_venv=${MSUB_SLIM_VENV:-1}"
        # One process hashes source contents and paths, including additions and
        # deletions. Runtime/model fingerprints remain separate and metadata-based.
        "$FINGERPRINT_PYTHON" "$FINGERPRINT_TOOL" --content \
            "$REPO_ROOT/src" "$REPO_ROOT/pyproject.toml" "$REPO_ROOT/uv.lock" \
            "$REPO_ROOT/README.md" "$REPO_ROOT/.python-version" \
            "$SRCROOT/Scripts/package-backend.sh" "$REPO_ROOT/.venv/pyvenv.cfg"
        if [ "$INCLUDE_MODEL" = "1" ]; then directory_signature "$MODEL_SOURCE"; fi
        if [ "$INCLUDE_SENSEVOICE_MODEL" = "1" ]; then directory_signature "$SENSEVOICE_MODEL_SOURCE"; fi
        if [ "$INCLUDE_MIMO_MODEL" = "1" ]; then directory_signature "$MIMO_MODEL_SOURCE"; directory_signature "$MIMO_TOKENIZER_SOURCE"; fi
        if [ "$INCLUDE_MEGA_MODEL" = "1" ]; then directory_signature "$MEGA_MODEL_SOURCE"; fi
        if [ "$INCLUDE_QWEN3_MODEL" = "1" ]; then directory_signature "$QWEN3_MODEL_SOURCE"; fi
        if [ "$INCLUDE_FUNASR_MODEL" = "1" ]; then directory_signature "$FUNASR_MODEL_SOURCE"; fi
        if [ "$INCLUDE_FIRERED_VAD_MODEL" = "1" ]; then directory_signature "$FIRERED_VAD_MODEL_SOURCE"; fi
        if [ "$INCLUDE_DIARIZATION_MODEL" = "1" ]; then directory_signature "$DIARIZATION_MODEL_SOURCE"; fi
        if [ "$INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL" = "1" ]; then directory_signature "$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE"; fi
        if [ "$INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL" = "1" ]; then directory_signature "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE"; fi
        if [ "$INCLUDE_SPEAKER_RECOGNITION_MODEL" = "1" ]; then directory_signature "$SPEAKER_RECOGNITION_MODEL_SOURCE"; fi
        if [ "$INCLUDE_EMOTION_MODEL" = "1" ]; then directory_signature "$EMOTION_MODEL_SOURCE"; fi
        if [ "$INCLUDE_EMOTION_MLX_MODEL" = "1" ]; then directory_signature "$EMOTION_MLX_MODEL_SOURCE"; fi
        if [ "$INCLUDE_AUDIO_EVENT_MODEL" = "1" ]; then directory_signature "$AUDIO_EVENT_MODEL_SOURCE"; fi
    } | shasum | awk '{print $1}'
}

CURRENT_PACKAGE_SIGNATURE="$(package_signature)"
if [ "${MSUB_FORCE_PACKAGE_BACKEND:-0}" != "1" ] \
    && [ "$RUNTIME_UNCHANGED" = "1" ] \
    && [ -f "$PACKAGE_STAMP" ] \
    && [ "$(cat "$PACKAGE_STAMP")" = "$CURRENT_PACKAGE_SIGNATURE" ]; then
    MSUB_PACKAGE_CACHE=hit
    echo "Backend package inputs unchanged; skipping virtualenv and model copy."
    exit 0
fi

# A failed refresh may leave partially replaced files. Never let a later
# reversion of the inputs reuse the signature from before that refresh.
rm -f "$PACKAGE_STAMP"
if [ "$RUNTIME_UNCHANGED" != "1" ]; then rm -f "$RUNTIME_STAMP"; fi

package_phase source
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

copy_model_dir() {
    source_dir="$1"
    dest_dir="$2"
    rsync -a --delete --delete-excluded \
        --exclude ".cache" \
        --exclude ".gitattributes" \
        --exclude ".incomplete" \
        --exclude ".DS_Store" \
        --exclude "__pycache__" \
        --exclude "*.pth" \
        "$source_dir" \
        "$dest_dir/"
}

case "$BACKEND_BUNDLE_PROFILE" in
    core|full) ;;
    *)
        echo "Unknown MSUB_BACKEND_BUNDLE_PROFILE: $BACKEND_BUNDLE_PROFILE (expected core or full)" >&2
        exit 2
        ;;
esac

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

if [ -f "$MEGA_MODEL_SOURCE/config.json" ] && { ls "$MEGA_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$MEGA_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_MEGA_MODEL_JSON="\"$MEGA_MODEL_SOURCE\""
fi

if [ -f "$QWEN3_MODEL_SOURCE/config.json" ] && { ls "$QWEN3_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$QWEN3_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_QWEN3_MODEL_JSON="\"$QWEN3_MODEL_SOURCE\""
fi

if [ -f "$FUNASR_MODEL_SOURCE/config.json" ] && { ls "$FUNASR_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$FUNASR_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_FUNASR_MODEL_JSON="\"$FUNASR_MODEL_SOURCE\""
fi

if [ -f "$FIRERED_VAD_MODEL_SOURCE/FireRedVAD.mlpackage/Data/com.apple.CoreML/model.mlmodel" ] && [ -f "$FIRERED_VAD_MODEL_SOURCE/cmvn.ark" ]; then
    SOURCE_FIRERED_VAD_MODEL_JSON="\"$FIRERED_VAD_MODEL_SOURCE\""
fi

if [ -f "$DIARIZATION_MODEL_SOURCE/config.yaml" ]; then
    SOURCE_DIARIZATION_MODEL_JSON="\"$DIARIZATION_MODEL_SOURCE\""
fi

if [ -f "$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE/config.json" ] && { ls "$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || ls "$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE"/*.npz >/dev/null 2>&1; }; then
    SOURCE_PYANNOTE_SEGMENTATION_MLX_MODEL_JSON="\"$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE\""
fi

if { [ -f "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE/mlpackages/Fbank.mlpackage/Data/com.apple.CoreML/model.mlmodel" ] || [ -d "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE/FBank.mlmodelc" ]; } \
    && { [ -f "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE/mlpackages/Embedding.mlpackage/Data/com.apple.CoreML/model.mlmodel" ] || [ -d "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE/Embedding.mlmodelc" ]; }; then
    SOURCE_SPEAKER_DIARIZATION_COREML_MODEL_JSON="\"$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE\""
fi

if [ -d "$SPEAKER_RECOGNITION_MODEL_SOURCE" ] && [ "$(find "$SPEAKER_RECOGNITION_MODEL_SOURCE" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    SOURCE_SPEAKER_RECOGNITION_MODEL_JSON="\"$SPEAKER_RECOGNITION_MODEL_SOURCE\""
fi

if [ -d "$EMOTION_MODEL_SOURCE" ] && [ "$(find "$EMOTION_MODEL_SOURCE" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    SOURCE_EMOTION_MODEL_JSON="\"$EMOTION_MODEL_SOURCE\""
fi

if [ -f "$EMOTION_MLX_MODEL_SOURCE/emotion2vec_large_config.json" ] && [ -f "$EMOTION_MLX_MODEL_SOURCE/emotion2vec_large.safetensors" ]; then
    SOURCE_EMOTION_MLX_MODEL_JSON="\"$EMOTION_MLX_MODEL_SOURCE\""
fi

if [ -f "$PANNS_AUDIO_EVENT_MODEL_SOURCE/panns_cnn14_16k_config.json" ] && [ -f "$PANNS_AUDIO_EVENT_MODEL_SOURCE/panns_cnn14_16k.safetensors" ]; then
    AUDIO_EVENT_MODEL_SOURCE="$PANNS_AUDIO_EVENT_MODEL_SOURCE"
    SOURCE_AUDIO_EVENT_MODEL_JSON="\"$PANNS_AUDIO_EVENT_MODEL_SOURCE\""
fi

package_phase runtime
if [ "$RUNTIME_UNCHANGED" = "1" ]; then
    echo "Backend runtime unchanged; reusing prepared Python dependencies and binaries."
elif [ "$INCLUDE_VENV" = "1" ]; then
    if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
        echo "MSUB_INCLUDE_VENV=1 but $REPO_ROOT/.venv/bin/python was not found." >&2
        exit 1
    fi

    MSUB_PACKAGE_FILTER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/msub-package-filters.XXXXXX")"
    "$FINGERPRINT_PYTHON" "$RUNTIME_FILTER_TOOL" venv --profile "$BACKEND_BUNDLE_PROFILE" \
        --slim "${MSUB_SLIM_VENV:-1}" > "$MSUB_PACKAGE_FILTER_DIR/venv"
    "$FINGERPRINT_PYTHON" "$RUNTIME_FILTER_TOOL" python --profile "$BACKEND_BUNDLE_PROFILE" \
        --slim "${MSUB_SLIM_VENV:-1}" > "$MSUB_PACKAGE_FILTER_DIR/python"
    echo "Copying backend Python virtual environment (profile=$BACKEND_BUNDLE_PROFILE, exclusions applied before copy)."
    mkdir -p "$DEST/.venv"
    rsync -a --delete --delete-excluded \
        --exclude-from="$MSUB_PACKAGE_FILTER_DIR/venv" \
        "$REPO_ROOT/.venv/" "$DEST/.venv/"

    if [ "$INCLUDE_PYTHON_RUNTIME" = "1" ]; then
        PYTHON_ROOT="$("$REPO_ROOT/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
        if [ -z "$PYTHON_ROOT" ] || [ ! -d "$PYTHON_ROOT" ]; then
            echo "Could not locate the base Python runtime for $REPO_ROOT/.venv." >&2
            exit 1
        fi

        echo "Copying backend Python runtime from $PYTHON_ROOT."
        rsync -a --delete --delete-excluded \
            --exclude-from="$MSUB_PACKAGE_FILTER_DIR/python" \
            "$PYTHON_ROOT/" "$DEST/python/"
        rm -f "$DEST/.venv/bin/python" "$DEST/.venv/bin/python3" "$DEST/.venv/bin/python3.12"
        ln -s "../../python/bin/python3.12" "$DEST/.venv/bin/python"
        ln -s "python" "$DEST/.venv/bin/python3"
        ln -s "python" "$DEST/.venv/bin/python3.12"
    else
        rm -rf "$DEST/python"
    fi

    VENV_SITE=""
    for candidate in "$DEST"/.venv/lib/python*/site-packages; do
        if [ -d "$candidate" ]; then
            VENV_SITE="$candidate"
            break
        fi
    done

    SLIM_VENV="${MSUB_SLIM_VENV:-1}"
    if [ "$SLIM_VENV" = "1" ]; then
        slim_size_before=$(du -sk "$DEST" 2>/dev/null | awk '{print $1}')
        echo "Slimming backend payload (set MSUB_SLIM_VENV=0 to skip)."

        if [ -n "$VENV_SITE" ]; then
            # Non-runtime files were excluded before rsync. Only binary
            # transformations remain here (Apple Silicon distribution).
            thin_arm64_binary() {
                bin="$1"
                [ -f "$bin" ] || return 0
                archs=$(lipo -archs "$bin" 2>/dev/null || echo "")
                case "$archs" in
                    *x86_64*arm64*|*arm64*x86_64*)
                        tmp="$bin.arm64.$$"
                        if lipo "$bin" -thin arm64 -output "$tmp" 2>/dev/null; then
                            mv "$tmp" "$bin"
                            codesign --force --sign - --preserve-metadata=identifier,entitlements "$bin" >/dev/null 2>&1 || \
                                codesign --force --sign - "$bin" >/dev/null 2>&1 || true
                        else
                            rm -f "$tmp"
                        fi
                        ;;
                esac
                return 0
            }

            macho_scan_file="$DEST/.macho-thin-targets.$$"
            : > "$macho_scan_file"
            find "$VENV_SITE" -type f \( -name "*.so" -o -name "*.dylib" \) -print >> "$macho_scan_file" 2>/dev/null || true
            if [ "$INCLUDE_PYTHON_RUNTIME" = "1" ] && [ -d "$DEST/python" ]; then
                find "$DEST/python" -type f \( -name "*.so" -o -name "*.dylib" -o -name "python" -o -name "python3" -o -name "python3.12" \) -print >> "$macho_scan_file" 2>/dev/null || true
            fi
            while IFS= read -r bin; do
                thin_arm64_binary "$bin"
            done < "$macho_scan_file"
            rm -f "$macho_scan_file"

            # Strip local symbols from the largest native libraries, then re-sign adhoc.
            slim_strip_targets=(
                "$VENV_SITE/torch/lib/libtorch_cpu.dylib"
                "$VENV_SITE/torch/lib/libtorch_python.dylib"
                "$VENV_SITE/torch/lib/libc10.dylib"
                "$VENV_SITE/torch/lib/libomp.dylib"
                "$VENV_SITE/llvmlite/binding/libllvmlite.dylib"
                "$VENV_SITE/mlx/lib/libmlx.dylib"
                "$VENV_SITE/mlx/lib/libjaccl.dylib"
                "$VENV_SITE/grpc/_cython/cygrpc.cpython-312-darwin.so"
                "$VENV_SITE/cryptography/hazmat/bindings/_rust.abi3.so"
                "$VENV_SITE/tokenizers/tokenizers.abi3.so"
                "$VENV_SITE/hf_xet/hf_xet.abi3.so"
                "$VENV_SITE/scipy/optimize/_highspy/_core.cpython-312-darwin.so"
                "$VENV_SITE/pydantic_core/_pydantic_core.cpython-312-darwin.so"
            )
            for bin in "${slim_strip_targets[@]}"; do
                [ -f "$bin" ] || continue
                if strip -x "$bin" 2>/dev/null; then
                    codesign --force --sign - --preserve-metadata=identifier,entitlements "$bin" >/dev/null 2>&1 || \
                        codesign --force --sign - "$bin" >/dev/null 2>&1 || true
                fi
            done
        fi

        slim_size_after=$(du -sk "$DEST" 2>/dev/null | awk '{print $1}')
        if [ -n "$slim_size_before" ] && [ -n "$slim_size_after" ]; then
            slim_delta=$((slim_size_before - slim_size_after))
            echo "Backend binary slim after copy exclusions: $((slim_size_before / 1024)) MiB -> $((slim_size_after / 1024)) MiB (saved $((slim_delta / 1024)) MiB)."
        fi
    fi
else
    rm -rf "$DEST/.venv" "$DEST/python"
    echo "Skipping venv copy. Set MSUB_INCLUDE_VENV=1 to embed backend dependencies in the app bundle."
fi

# Publish only after successful preparation. Source-only edits never repeat
# virtualenv copying, thinning or signing of unchanged native dependencies.
package_phase models
printf '%s\n' "$CURRENT_RUNTIME_SIGNATURE" > "$RUNTIME_STAMP.tmp"
mv "$RUNTIME_STAMP.tmp" "$RUNTIME_STAMP"

if [ "$INCLUDE_MODEL" = "1" ]; then
    mkdir -p "$DEST/models"
    copy_model_dir "$MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping model copy. Set MSUB_INCLUDE_MODEL=1 to embed local weights in the app bundle."
fi

if [ "$INCLUDE_SENSEVOICE_MODEL" = "1" ]; then
    if [ "$SOURCE_SENSEVOICE_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_SENSEVOICE_MODEL=1 but $SENSEVOICE_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$SENSEVOICE_MODEL_SOURCE" "$DEST/models"
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
    copy_model_dir "$MIMO_MODEL_SOURCE" "$DEST/models"
    copy_model_dir "$MIMO_TOKENIZER_SOURCE" "$DEST/models"
else
    echo "Skipping MiMo model copy. Set MSUB_INCLUDE_MIMO_MODEL=1 to embed local MiMo weights and tokenizer."
fi

if [ "$INCLUDE_MEGA_MODEL" = "1" ]; then
    if [ "$SOURCE_MEGA_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_MEGA_MODEL=1 but $MEGA_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$MEGA_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping Mega-ASR model copy. Set MSUB_INCLUDE_MEGA_MODEL=1 to embed local Mega-ASR weights."
fi

if [ "$INCLUDE_QWEN3_MODEL" = "1" ]; then
    if [ "$SOURCE_QWEN3_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_QWEN3_MODEL=1 but $QWEN3_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$QWEN3_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping Qwen3-ASR model copy. Set MSUB_INCLUDE_QWEN3_MODEL=1 to embed local Qwen3-ASR weights."
fi

if [ "$INCLUDE_FUNASR_MODEL" = "1" ]; then
    if [ "$SOURCE_FUNASR_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_FUNASR_MODEL=1 but $FUNASR_MODEL_SOURCE is not a valid MLX STT model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$FUNASR_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping Fun-ASR model copy. Set MSUB_INCLUDE_FUNASR_MODEL=1 to embed local Fun-ASR weights."
fi

if [ "$INCLUDE_FIRERED_VAD_MODEL" = "1" ]; then
    if [ "$SOURCE_FIRERED_VAD_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_FIRERED_VAD_MODEL=1 but $FIRERED_VAD_MODEL_SOURCE is not a valid FireRedVAD CoreML model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$FIRERED_VAD_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping FireRedVAD model copy. Set MSUB_INCLUDE_FIRERED_VAD_MODEL=1 to embed local FireRedVAD weights."
fi

if [ "$INCLUDE_DIARIZATION_MODEL" = "1" ]; then
    if [ ! -f "$DIARIZATION_MODEL_SOURCE/config.yaml" ]; then
        echo "MSUB_INCLUDE_DIARIZATION_MODEL=1 but $DIARIZATION_MODEL_SOURCE/config.yaml was not found." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$DIARIZATION_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping diarization model copy. Set MSUB_INCLUDE_DIARIZATION_MODEL=1 to embed local pyannote weights."
fi

if [ "$INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL" = "1" ]; then
    if [ "$SOURCE_PYANNOTE_SEGMENTATION_MLX_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL=1 but $PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE is not a valid Pyannote Segmentation MLX model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping Pyannote Segmentation MLX model copy. Set MSUB_INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL=1 to embed local segmentation weights."
fi

if [ "$INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL" = "1" ]; then
    if [ "$SOURCE_SPEAKER_DIARIZATION_COREML_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL=1 but $SPEAKER_DIARIZATION_COREML_MODEL_SOURCE is not a valid speaker diarization CoreML model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$SPEAKER_DIARIZATION_COREML_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping speaker diarization CoreML model copy. Set MSUB_INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL=1 to embed local CoreML diarization weights."
fi

if [ "$INCLUDE_SPEAKER_RECOGNITION_MODEL" = "1" ]; then
    if [ "$SOURCE_SPEAKER_RECOGNITION_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_SPEAKER_RECOGNITION_MODEL=1 but $SPEAKER_RECOGNITION_MODEL_SOURCE is empty or missing." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$SPEAKER_RECOGNITION_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping ERes2NetV2 speaker model copy. Set MSUB_INCLUDE_SPEAKER_RECOGNITION_MODEL=1 to embed local speaker weights."
fi

if [ "$INCLUDE_EMOTION_MODEL" = "1" ]; then
    if [ "$SOURCE_EMOTION_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_EMOTION_MODEL=1 but $EMOTION_MODEL_SOURCE is empty or missing." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$EMOTION_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping emotion2vec model copy. Set MSUB_INCLUDE_EMOTION_MODEL=1 to embed local emotion weights."
fi

if [ "$INCLUDE_EMOTION_MLX_MODEL" = "1" ]; then
    if [ "$SOURCE_EMOTION_MLX_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_EMOTION_MLX_MODEL=1 but $EMOTION_MLX_MODEL_SOURCE is not a valid emotion2vec MLX model directory." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$EMOTION_MLX_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping emotion2vec MLX model copy. Set MSUB_INCLUDE_EMOTION_MLX_MODEL=1 to embed local MLX emotion weights."
fi

if [ "$INCLUDE_AUDIO_EVENT_MODEL" = "1" ]; then
    if [ "$SOURCE_AUDIO_EVENT_MODEL_JSON" = "null" ]; then
        echo "MSUB_INCLUDE_AUDIO_EVENT_MODEL=1 but no valid PANNs Cnn14_16k MLX model directory was found." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$AUDIO_EVENT_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping audio event model copy. Set MSUB_INCLUDE_AUDIO_EVENT_MODEL=1 to embed local PANNs Cnn14_16k MLX weights."
fi

cat > "$DEST/backend-manifest.json" <<EOF
{
  "name": "MSub backend",
  "includeModel": "$INCLUDE_MODEL",
  "includeSenseVoiceModel": "$INCLUDE_SENSEVOICE_MODEL",
  "includeMiMoModel": "$INCLUDE_MIMO_MODEL",
  "includeMegaModel": "$INCLUDE_MEGA_MODEL",
  "includeQwen3Model": "$INCLUDE_QWEN3_MODEL",
  "includeFunASRModel": "$INCLUDE_FUNASR_MODEL",
  "includeFireRedVADModel": "$INCLUDE_FIRERED_VAD_MODEL",
  "includeDiarizationModel": "$INCLUDE_DIARIZATION_MODEL",
  "includePyannoteSegmentationMLXModel": "$INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL",
  "includeSpeakerDiarizationCoreMLModel": "$INCLUDE_SPEAKER_DIARIZATION_COREML_MODEL",
  "includeSpeakerRecognitionModel": "$INCLUDE_SPEAKER_RECOGNITION_MODEL",
  "includeEmotionModel": "$INCLUDE_EMOTION_MODEL",
  "includeEmotionMLXModel": "$INCLUDE_EMOTION_MLX_MODEL",
  "includeAudioEventModel": "$INCLUDE_AUDIO_EVENT_MODEL",
  "includeVenv": "$INCLUDE_VENV",
  "includePythonRuntime": "$INCLUDE_PYTHON_RUNTIME",
  "backendBundleProfile": "$BACKEND_BUNDLE_PROFILE",
  "sourceModelPath": $SOURCE_MODEL_JSON,
  "sourceSenseVoiceModelPath": $SOURCE_SENSEVOICE_MODEL_JSON,
  "sourceMiMoModelPath": $SOURCE_MIMO_MODEL_JSON,
  "sourceMiMoTokenizerPath": $SOURCE_MIMO_TOKENIZER_JSON,
  "sourceMegaModelPath": $SOURCE_MEGA_MODEL_JSON,
  "sourceQwen3ModelPath": $SOURCE_QWEN3_MODEL_JSON,
  "sourceFunASRModelPath": $SOURCE_FUNASR_MODEL_JSON,
  "sourceFireRedVADModelPath": $SOURCE_FIRERED_VAD_MODEL_JSON,
  "sourceDiarizationModelPath": $SOURCE_DIARIZATION_MODEL_JSON,
  "sourcePyannoteSegmentationMLXModelPath": $SOURCE_PYANNOTE_SEGMENTATION_MLX_MODEL_JSON,
  "sourceSpeakerDiarizationCoreMLModelPath": $SOURCE_SPEAKER_DIARIZATION_COREML_MODEL_JSON,
  "sourceSpeakerRecognitionModelPath": $SOURCE_SPEAKER_RECOGNITION_MODEL_JSON,
  "sourceEmotionModelPath": $SOURCE_EMOTION_MODEL_JSON,
  "sourceEmotionMLXModelPath": $SOURCE_EMOTION_MLX_MODEL_JSON,
  "sourceAudioEventModelPath": $SOURCE_AUDIO_EVENT_MODEL_JSON,
  "modelPath": "models/FireRedASR2-AED-mlx",
  "senseVoiceModelPath": "models/SenseVoiceSmall",
  "mimoModelPath": "models/MiMo-V2.5-ASR-MLX-4bit",
  "mimoTokenizerPath": "models/MiMo-Audio-Tokenizer",
  "megaModelPath": "models/Mega-ASR-bf16",
  "qwen3ModelPath": "models/Qwen3-ASR-1.7B-8bit",
  "funASRModelPath": "models/Fun-ASR-Nano-2512",
  "fireRedVADModelPath": "models/FireRedVAD-CoreML",
  "diarizationModelPath": "models/pyannote-speaker-diarization-community-1",
  "pyannoteSegmentationMLXModelPath": "models/Pyannote-Segmentation-MLX",
  "speakerDiarizationCoreMLModelPath": "models/speaker-diarization-coreml",
  "speakerRecognitionModelPath": "models/speech_eres2netv2_sv_zh-cn_16k-common",
  "emotionModelPath": "models/emotion2vec-plus-large-mlx",
  "emotionMLXModelPath": "models/emotion2vec-plus-large-mlx",
  "audioEventModelPath": "models/$(basename "$AUDIO_EVENT_MODEL_SOURCE")",
  "entrypoint": "msub-web"
}
EOF

echo "$CURRENT_PACKAGE_SIGNATURE" > "$PACKAGE_STAMP"
