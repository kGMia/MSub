#!/bin/bash
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
MEGA_MODEL_SOURCE="$REPO_ROOT/models/Mega-ASR-bf16"
FIRERED_VAD_MODEL_SOURCE="$REPO_ROOT/models/FireRedVAD-CoreML"
DIARIZATION_MODEL_SOURCE="$REPO_ROOT/models/pyannote-speaker-diarization-community-1"
PYANNOTE_SEGMENTATION_MLX_MODEL_SOURCE="$REPO_ROOT/models/Pyannote-Segmentation-MLX"
SPEAKER_DIARIZATION_COREML_MODEL_SOURCE="$REPO_ROOT/models/speaker-diarization-coreml"
SPEAKER_RECOGNITION_MODEL_SOURCE="$REPO_ROOT/models/speech_eres2netv2_sv_zh-cn_16k-common"
EMOTION_MODEL_SOURCE="$REPO_ROOT/models/emotion2vec_plus_base"
EMOTION_MLX_MODEL_SOURCE="$REPO_ROOT/models/emotion2vec-plus-large-mlx"
PANNS_AUDIO_EVENT_MODEL_SOURCE="$REPO_ROOT/models/panns-cnn14-16k-mlx"
AST_AUDIO_EVENT_MODEL_SOURCE="$REPO_ROOT/models/ast-finetuned-audioset-10-10-0.4593"
AUDIO_EVENT_MODEL_SOURCE="$AST_AUDIO_EVENT_MODEL_SOURCE"

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
INCLUDE_MEGA_MODEL="${MSUB_INCLUDE_MEGA_MODEL:-0}"
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
SOURCE_FIRERED_VAD_MODEL_JSON="null"
SOURCE_DIARIZATION_MODEL_JSON="null"
SOURCE_PYANNOTE_SEGMENTATION_MLX_MODEL_JSON="null"
SOURCE_SPEAKER_DIARIZATION_COREML_MODEL_JSON="null"
SOURCE_SPEAKER_RECOGNITION_MODEL_JSON="null"
SOURCE_EMOTION_MODEL_JSON="null"
SOURCE_EMOTION_MLX_MODEL_JSON="null"
SOURCE_AUDIO_EVENT_MODEL_JSON="null"

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
        --exclude "panns-cnn14-16k-pytorch" \
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

if [ -d "$SPEAKER_RECOGNITION_MODEL_SOURCE" ] && [ "$(find "$SPEAKER_RECOGNITION_MODEL_SOURCE" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
    SOURCE_SPEAKER_RECOGNITION_MODEL_JSON="\"$SPEAKER_RECOGNITION_MODEL_SOURCE\""
fi

if [ -d "$EMOTION_MODEL_SOURCE" ] && [ "$(find "$EMOTION_MODEL_SOURCE" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
    SOURCE_EMOTION_MODEL_JSON="\"$EMOTION_MODEL_SOURCE\""
fi

if [ -f "$EMOTION_MLX_MODEL_SOURCE/emotion2vec_large_config.json" ] && [ -f "$EMOTION_MLX_MODEL_SOURCE/emotion2vec_large.safetensors" ]; then
    SOURCE_EMOTION_MLX_MODEL_JSON="\"$EMOTION_MLX_MODEL_SOURCE\""
fi

if [ -f "$PANNS_AUDIO_EVENT_MODEL_SOURCE/panns_cnn14_16k_config.json" ] && [ -f "$PANNS_AUDIO_EVENT_MODEL_SOURCE/panns_cnn14_16k.safetensors" ]; then
    AUDIO_EVENT_MODEL_SOURCE="$PANNS_AUDIO_EVENT_MODEL_SOURCE"
    SOURCE_AUDIO_EVENT_MODEL_JSON="\"$PANNS_AUDIO_EVENT_MODEL_SOURCE\""
elif [ -f "$AST_AUDIO_EVENT_MODEL_SOURCE/config.json" ] && { ls "$AST_AUDIO_EVENT_MODEL_SOURCE"/*.safetensors >/dev/null 2>&1 || [ -f "$AST_AUDIO_EVENT_MODEL_SOURCE/pytorch_model.bin" ]; }; then
    AUDIO_EVENT_MODEL_SOURCE="$AST_AUDIO_EVENT_MODEL_SOURCE"
    SOURCE_AUDIO_EVENT_MODEL_JSON="\"$AUDIO_EVENT_MODEL_SOURCE\""
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

    if [ "$BACKEND_BUNDLE_PROFILE" = "core" ] && [ -n "$VENV_SITE" ]; then
        echo "Applying core backend bundle profile (set MSUB_BACKEND_BUNDLE_PROFILE=full to keep optional Torch-based features)."
        remove_site_packages() {
            for pattern in "$@"; do
                for path in "$VENV_SITE"/$pattern; do
                    [ -e "$path" ] || continue
                    rm -rf "$path"
                done
            done
        }
        remove_site_packages \
            "torch" "torch-"*.dist-info "torchgen" "torchgen-"*.dist-info \
            "torchaudio" "torchaudio-"*.dist-info "torchcodec" "torchcodec-"*.dist-info \
            "torch_complex" "torch_complex-"*.dist-info "functorch" \
            "torchmetrics" "torchmetrics-"*.dist-info "torch_audiomentations" "torch_audiomentations-"*.dist-info \
            "torch_pitch_shift" "torch_pitch_shift-"*.dist-info "pytorch_lightning" "pytorch_lightning-"*.dist-info \
            "pytorch_metric_learning" "pytorch_metric_learning-"*.dist-info \
            "pytorch_wpe.py" "pytorch_wpe-"*.dist-info \
            "pyannote" "pyannote_"*.dist-info "pyannoteai" "pyannoteai_"*.dist-info \
            "julius" "julius-"*.dist-info "primePy" "primePy-"*.dist-info \
            "einops" "einops-"*.dist-info "lightning_utilities" "lightning_utilities-"*.dist-info \
            "funasr" "funasr-"*.dist-info "modelscope" "modelscope-"*.dist-info \
            "editdistance" "editdistance-"*.dist-info "tiktoken" "tiktoken-"*.dist-info "tiktoken_ext" \
            "requests" "requests-"*.dist-info "urllib3" "urllib3-"*.dist-info "charset_normalizer" "charset_normalizer-"*.dist-info \
            "fireredvad" "fireredvad-"*.dist-info \
            "pyaml" "pyaml-"*.dist-info \
            "sounddevice.py" "_sounddevice.py" "_sounddevice_data" "sounddevice-"*.dist-info \
            "httptools" "httptools-"*.dist-info "uvloop" "uvloop-"*.dist-info \
            "watchfiles" "watchfiles-"*.dist-info "websockets" "websockets-"*.dist-info \
            "dotenv" "python_dotenv-"*.dist-info \
            "lightning" "lightning-"*.dist-info "lightning_fabric" "lightning_fabric-"*.dist-info \
            "asteroid_filterbanks" "asteroid_filterbanks-"*.dist-info \
            "speechbrain" "speechbrain-"*.dist-info \
            "numba" "numba-"*.dist-info "llvmlite" "llvmlite-"*.dist-info \
            "librosa" "librosa-"*.dist-info "audioread" "audioread-"*.dist-info "soxr" "soxr-"*.dist-info \
            "lazy_loader" "lazy_loader-"*.dist-info "pooch" "pooch-"*.dist-info "platformdirs" "platformdirs-"*.dist-info \
            "joblib" "joblib-"*.dist-info "threadpoolctl.py" "threadpoolctl-"*.dist-info \
            "decorator.py" "decorator-"*.dist-info "msgpack" "msgpack-"*.dist-info \
            "sklearn" "scikit_learn-"*.dist-info \
            "umap" "umap_learn-"*.dist-info "pynndescent" "pynndescent-"*.dist-info \
            "pandas" "pandas-"*.dist-info "matplotlib" "matplotlib-"*.dist-info "mpl_toolkits" \
            "PIL" "pillow-"*.dist-info "fontTools" "fonttools-"*.dist-info \
            "contourpy" "contourpy-"*.dist-info "cycler" "cycler-"*.dist-info \
            "kiwisolver" "kiwisolver-"*.dist-info "pyparsing" "pyparsing-"*.dist-info \
            "dateutil" "python_dateutil-"*.dist-info "six.py" "six-"*.dist-info "pylab.py" \
            "grpc" "grpcio-"*.dist-info "opentelemetry" "opentelemetry_"*.dist-info \
            "Crypto" "pycryptodome-"*.dist-info \
            "jieba" "jieba-"*.dist-info "jamo" "jamo-"*.dist-info "jaconv" "jaconv-"*.dist-info \
            "hydra" "hydra_core-"*.dist-info "omegaconf" "omegaconf-"*.dist-info \
            "antlr4" "antlr4_python3_runtime-"*.dist-info "textgrid" "textgrid-"*.dist-info \
            "tensorboardX" "tensorboardx-"*.dist-info "oss2" "oss2-"*.dist-info \
            "aliyunsdkcore" "aliyunsdkcore-"*.dist-info "aliyunsdkkms" "aliyun_python_sdk_"*.dist-info \
            "crcmod" "crcmod-"*.dist-info "jmespath" "jmespath-"*.dist-info \
            "cryptography" "cryptography-"*.dist-info \
            "aiohttp" "aiohttp-"*.dist-info "aiohappyeyeballs" "aiohappyeyeballs-"*.dist-info \
            "aiosignal" "aiosignal-"*.dist-info "frozenlist" "frozenlist-"*.dist-info \
            "multidict" "multidict-"*.dist-info "propcache" "propcache-"*.dist-info \
            "yarl" "yarl-"*.dist-info \
            "sqlalchemy" "sqlalchemy-"*.dist-info "SQLAlchemy-"*.dist-info "alembic" "alembic-"*.dist-info \
            "mako" "mako-"*.dist-info "colorlog" "colorlog-"*.dist-info "sortedcontainers" "sortedcontainers-"*.dist-info \
            "optuna" "optuna-"*.dist-info \
            "networkx" "networkx-"*.dist-info \
            "setuptools" "setuptools-"*.dist-info "pkg_resources" "_distutils_hack" "distutils-precedence.pth" \
            "pydevd_plugins"
    fi

    SLIM_VENV="${MSUB_SLIM_VENV:-1}"
    if [ "$SLIM_VENV" = "1" ]; then
        slim_size_before=$(du -sk "$DEST" 2>/dev/null | awk '{print $1}')
        echo "Slimming backend payload (set MSUB_SLIM_VENV=0 to skip)."

        if [ -n "$VENV_SITE" ]; then
            # 1) Drop C/C++ header trees — runtime never needs them.
            find "$VENV_SITE" -depth -type d -name "include" -exec rm -rf {} + 2>/dev/null || true
            # 2) Drop unit-test directories. Leave public `testing` submodules (torch.testing,
            #    sqlalchemy.testing) alone because user code may import them.
            find "$VENV_SITE" -depth -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
            # 3) Drop CMake/man artifacts intended for C/C++ consumers.
            find "$VENV_SITE" -depth -type d \( -name "cmake" -o -path "*/share/cmake" -o -path "*/share/man" -o -path "*/share/doc" \) -exec rm -rf {} + 2>/dev/null || true
            # 4) Drop examples, benchmarks, and docs from installed packages.
            find "$VENV_SITE" -depth -type d \( -name "examples" -o -name "example" -o -name "benchmarks" -o -name "benchmark" -o -name "docs" -o -name "doc" \) -exec rm -rf {} + 2>/dev/null || true
            # 5) Drop build-time source/header/static artifacts and common caches.
            find "$VENV_SITE" -depth -type d \( -name "*.dSYM" -o -name ".cache" -o -name ".pytest_cache" -o -name ".mypy_cache" -o -name ".ruff_cache" -o -name ".ipynb_checkpoints" \) -exec rm -rf {} + 2>/dev/null || true
            find "$VENV_SITE" -type f \( -name "*.a" -o -name "*.la" -o -name "*.o" -o -name "*.c" -o -name "*.cc" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" -o -name "*.pyx" -o -name "*.pxd" \) -exec rm -f {} + 2>/dev/null || true
            # NOTE: never strip *.pyi files. librosa, networkx, scikit-image and
            # recent scipy load them at runtime via lazy_loader.attach_stub().

            # 6) Thin fat Mach-O binaries down to arm64 (project ships Apple Silicon only).
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

            # 7) Strip local symbols from the largest native libraries, then re-sign adhoc.
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

        # 8) Trim the embedded Python runtime stdlib of bits no backend code uses.
        if [ "$INCLUDE_PYTHON_RUNTIME" = "1" ] && [ -d "$DEST/python" ]; then
            for stdlib_path in "$DEST"/python/lib/python*/; do
                [ -d "$stdlib_path" ] || continue
                rm -rf \
                    "$stdlib_path/idlelib" \
                    "$stdlib_path/turtledemo" \
                    "$stdlib_path/tkinter" \
                    "$stdlib_path/lib2to3" \
                    "$stdlib_path/ensurepip" \
                    "$stdlib_path/test" 2>/dev/null || true
                rm -f "$stdlib_path/turtle.py" 2>/dev/null || true
            done
            rm -rf "$DEST/python/include" 2>/dev/null || true
            rm -rf "$DEST/python/share/man" "$DEST/python/share/doc" 2>/dev/null || true
        fi

        slim_size_after=$(du -sk "$DEST" 2>/dev/null | awk '{print $1}')
        if [ -n "$slim_size_before" ] && [ -n "$slim_size_after" ]; then
            slim_delta=$((slim_size_before - slim_size_after))
            echo "Backend slim: $((slim_size_before / 1024)) MiB -> $((slim_size_after / 1024)) MiB (saved $((slim_delta / 1024)) MiB)."
        fi
    fi
else
    rm -rf "$DEST/.venv" "$DEST/python"
    echo "Skipping venv copy. Set MSUB_INCLUDE_VENV=1 to embed backend dependencies in the app bundle."
fi

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
        echo "MSUB_INCLUDE_AUDIO_EVENT_MODEL=1 but no valid PANNs MLX or AST AudioSet model directory was found." >&2
        exit 1
    fi
    mkdir -p "$DEST/models"
    copy_model_dir "$AUDIO_EVENT_MODEL_SOURCE" "$DEST/models"
else
    echo "Skipping audio event model copy. Set MSUB_INCLUDE_AUDIO_EVENT_MODEL=1 to embed local PANNs MLX or AST weights."
fi

cat > "$DEST/backend-manifest.json" <<EOF
{
  "name": "MSub backend",
  "includeModel": "$INCLUDE_MODEL",
  "includeSenseVoiceModel": "$INCLUDE_SENSEVOICE_MODEL",
  "includeMiMoModel": "$INCLUDE_MIMO_MODEL",
  "includeMegaModel": "$INCLUDE_MEGA_MODEL",
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
  "fireRedVADModelPath": "models/FireRedVAD-CoreML",
  "diarizationModelPath": "models/pyannote-speaker-diarization-community-1",
  "pyannoteSegmentationMLXModelPath": "models/Pyannote-Segmentation-MLX",
  "speakerDiarizationCoreMLModelPath": "models/speaker-diarization-coreml",
  "speakerRecognitionModelPath": "models/speech_eres2netv2_sv_zh-cn_16k-common",
  "emotionModelPath": "models/emotion2vec_plus_base",
  "emotionMLXModelPath": "models/emotion2vec-plus-large-mlx",
  "audioEventModelPath": "models/$(basename "$AUDIO_EVENT_MODEL_SOURCE")",
  "entrypoint": "msub-web"
}
EOF
