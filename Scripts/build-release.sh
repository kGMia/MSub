#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
DERIVED_DATA="${MSUB_DERIVED_DATA:-$REPO_ROOT/.xcode-derived-release}"
CONFIGURATION="${MSUB_CONFIGURATION:-Release}"
INCLUDE_MODEL="${MSUB_INCLUDE_MODEL:-0}"
INCLUDE_VENV="${MSUB_INCLUDE_VENV:-1}"
INCLUDE_PYTHON_RUNTIME="${MSUB_INCLUDE_PYTHON_RUNTIME:-$INCLUDE_VENV}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$REPO_ROOT/.swift-module-cache}"
export MSUB_INCLUDE_MODEL="$INCLUDE_MODEL"
export MSUB_INCLUDE_VENV="$INCLUDE_VENV"
export MSUB_INCLUDE_PYTHON_RUNTIME="$INCLUDE_PYTHON_RUNTIME"

xcodebuild \
    -project "$APP_ROOT/MSub.xcodeproj" \
    -scheme MSub \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    clean build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MSub.app"
echo "Built $APP_PATH"

if [ "$INCLUDE_MODEL" != "1" ]; then
    echo "Model weights were not embedded. Re-run with MSUB_INCLUDE_MODEL=1 for a self-contained app bundle."
fi

if [ "$INCLUDE_VENV" != "1" ]; then
    echo "Backend dependencies were not embedded. Re-run with MSUB_INCLUDE_VENV=1 for a self-contained backend."
fi
