#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
CONFIGURATION="${MSUB_CONFIGURATION:-Release}"
DEFAULT_APP_PATH="$REPO_ROOT/.xcode-derived-release/Build/Products/$CONFIGURATION/MSub.app"
APP_PATH="${1:-${MSUB_APP_PATH:-$DEFAULT_APP_PATH}}"
REQUIRE_DEVELOPER_ID="${MSUB_REQUIRE_DEVELOPER_ID:-0}"
BACKEND_BUNDLE_PROFILE="${MSUB_BACKEND_BUNDLE_PROFILE:-core}"
if [ -n "${MSUB_REQUIRE_OPTIONAL_DEPS+x}" ]; then
    REQUIRE_OPTIONAL_DEPS="$MSUB_REQUIRE_OPTIONAL_DEPS"
elif [ "$BACKEND_BUNDLE_PROFILE" = "full" ]; then
    REQUIRE_OPTIONAL_DEPS=1
else
    REQUIRE_OPTIONAL_DEPS=0
fi
REQUIRE_SPEAKER_DEPS="${MSUB_REQUIRE_SPEAKER_DEPS:-$REQUIRE_OPTIONAL_DEPS}"
REQUIRE_EMOTION_DEPS="${MSUB_REQUIRE_EMOTION_DEPS:-$REQUIRE_OPTIONAL_DEPS}"
REQUIRE_DIARIZATION_DEPS="${MSUB_REQUIRE_DIARIZATION_DEPS:-$REQUIRE_OPTIONAL_DEPS}"
if [ -n "${MSUB_REQUIRE_FIRERED_VAD_DEPS+x}" ]; then
    REQUIRE_FIRERED_VAD_DEPS="$MSUB_REQUIRE_FIRERED_VAD_DEPS"
elif [ "$BACKEND_BUNDLE_PROFILE" = "full" ] || [ "$BACKEND_BUNDLE_PROFILE" = "core" ]; then
    REQUIRE_FIRERED_VAD_DEPS=1
else
    REQUIRE_FIRERED_VAD_DEPS=0
fi
VALIDATE_BACKEND_START="${MSUB_VALIDATE_BACKEND_START:-0}"
VALIDATE_PORT="${MSUB_VALIDATE_PORT:-8799}"

fail() {
    echo "release bundle validation failed: $*" >&2
    exit 1
}

note() {
    echo "release bundle validation: $*"
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

require_dir "$APP_PATH" "MSub.app"

EXECUTABLE="$APP_PATH/Contents/MacOS/MSub"
RESOURCES="$APP_PATH/Contents/Resources"
BACKEND="$RESOURCES/backend"
require_executable "$EXECUTABLE" "MSub executable"
require_executable "$RESOURCES/ffmpeg" "bundled ffmpeg"
require_dir "$BACKEND" "bundled backend"
require_file "$BACKEND/pyproject.toml" "backend pyproject"
require_file "$BACKEND/uv.lock" "backend lockfile"
require_file "$BACKEND/backend-manifest.json" "backend manifest"
require_file "$BACKEND/src/huz_subtitle/web.py" "backend web module"
require_file "$BACKEND/src/huz_subtitle/cli.py" "backend cli module"

APP_ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
FFMPEG_ARCHS="$(lipo -archs "$RESOURCES/ffmpeg" 2>/dev/null || true)"
if [ -n "$APP_ARCHS" ] && [ -n "$FFMPEG_ARCHS" ]; then
    for arch in $APP_ARCHS; do
        case " $FFMPEG_ARCHS " in
            *" $arch "*) ;;
            *) fail "app contains $arch but bundled ffmpeg only has: $FFMPEG_ARCHS" ;;
        esac
    done
fi

PYTHON="$BACKEND/python/bin/python3.12"
if [ ! -x "$PYTHON" ]; then
    PYTHON="$BACKEND/python/bin/python3"
fi
if [ ! -x "$PYTHON" ]; then
    PYTHON="$BACKEND/python/bin/python"
fi
require_executable "$PYTHON" "bundled Python runtime"

SITE_PACKAGES="$(find "$BACKEND/.venv/lib" -maxdepth 2 -type d -name site-packages 2>/dev/null | head -n 1 || true)"
require_dir "$SITE_PACKAGES" "bundled site-packages"

ARCH_SCAN_FILE="${TMPDIR:-/tmp}/msub-release-native-binaries.$$"
: > "$ARCH_SCAN_FILE"
printf '%s\n' "$EXECUTABLE" "$RESOURCES/ffmpeg" "$PYTHON" >> "$ARCH_SCAN_FILE"
find "$BACKEND" -type f \( -name "*.so" -o -name "*.dylib" \) -print >> "$ARCH_SCAN_FILE" 2>/dev/null || true
while IFS= read -r binary; do
    [ -f "$binary" ] || continue
    archs="$(lipo -archs "$binary" 2>/dev/null || true)"
    case " $archs " in
        *" x86_64 "*)
            rm -f "$ARCH_SCAN_FILE"
            fail "release is Apple Silicon only but native binary contains x86_64 ($archs): $binary"
            ;;
    esac
done < "$ARCH_SCAN_FILE"
rm -f "$ARCH_SCAN_FILE"

VALIDATION_CACHE="$REPO_ROOT/.release-bundle-validation-cache"
mkdir -p "$VALIDATION_CACHE/matplotlib" "$VALIDATION_CACHE/huggingface" "$VALIDATION_CACHE/modelscope"
export MPLCONFIGDIR="$VALIDATION_CACHE/matplotlib"
export HF_HOME="$VALIDATION_CACHE/huggingface"
export MODELSCOPE_CACHE="$VALIDATION_CACHE/modelscope"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$BACKEND/src:$SITE_PACKAGES"
export MSUB_BACKEND_ROOT="$BACKEND"
export MSUB_FFMPEG="$RESOURCES/ffmpeg"
export MSUB_REQUIRE_SPEAKER_DEPS="$REQUIRE_SPEAKER_DEPS"
export MSUB_REQUIRE_EMOTION_DEPS="$REQUIRE_EMOTION_DEPS"
export MSUB_REQUIRE_DIARIZATION_DEPS="$REQUIRE_DIARIZATION_DEPS"
export MSUB_REQUIRE_FIRERED_VAD_DEPS="$REQUIRE_FIRERED_VAD_DEPS"

"$PYTHON" - <<'PY'
import importlib
import os
import shutil
import sys

groups = {
    "core": [
        "fastapi",
        "uvicorn",
        "multipart",
        "mlx",
        "mlx_audio",
        "huz_subtitle.web",
        "huz_subtitle.cli",
        "safetensors",
        "soundfile",
    ],
}
if os.getenv("MSUB_REQUIRE_FIRERED_VAD_DEPS", "0") == "1":
    groups["firered_vad"] = ["coremltools", "kaldi_native_fbank", "kaldiio", "soundfile"]
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

if not shutil.which(os.getenv("MSUB_FFMPEG", "")):
    missing.append("core: bundled ffmpeg is not executable")

if missing:
    print("Bundled backend validation failed:", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)
PY

if [ "$VALIDATE_BACKEND_START" = "1" ]; then
    export MSUB_HOST=127.0.0.1
    export MSUB_PORT="$VALIDATE_PORT"
    export MSUB_MODEL_IDLE_SECONDS=1
    "$PYTHON" -m huz_subtitle.web > "$VALIDATION_CACHE/backend.log" 2>&1 &
    SERVER_PID="$!"
    trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT INT TERM

    "$PYTHON" - <<'PY'
import json
import os
import sys
import time
import urllib.request

port = os.environ["MSUB_PORT"]
deadline = time.time() + 20
url = f"http://127.0.0.1:{port}/api/health"
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            payload = json.loads(response.read().decode("utf-8"))
        if payload.get("ok") is True:
            sys.exit(0)
    except Exception:
        time.sleep(0.25)
print("backend did not become healthy", file=sys.stderr)
sys.exit(1)
PY
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
fi

codesign --verify --deep --strict "$APP_PATH"

if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
    CODESIGN_INFO="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
    echo "$CODESIGN_INFO" | grep -q "Signature=adhoc" && fail "app is ad-hoc signed, not Developer ID signed"
    echo "$CODESIGN_INFO" | grep -q "TeamIdentifier=not set" && fail "app has no TeamIdentifier"
    spctl -a -t exec -vv "$APP_PATH"
fi

note "ok: $APP_PATH"
