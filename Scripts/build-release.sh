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
BACKEND_BUNDLE_PROFILE="${MSUB_BACKEND_BUNDLE_PROFILE:-core}"
ARCHS="${MSUB_ARCHS:-arm64}"
RUN_PREFLIGHT="${MSUB_RUN_PREFLIGHT:-1}"
RUN_VALIDATE="${MSUB_RUN_VALIDATE:-1}"
SIGN_AND_NOTARIZE="${MSUB_SIGN_AND_NOTARIZE:-0}"
SIGNING_MODE="${MSUB_SIGNING_MODE:-adhoc}"
CREATE_DMG="${MSUB_CREATE_DMG:-0}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$REPO_ROOT/.swift-module-cache}"
export MSUB_INCLUDE_MODEL="$INCLUDE_MODEL"
export MSUB_INCLUDE_VENV="$INCLUDE_VENV"
export MSUB_INCLUDE_PYTHON_RUNTIME="$INCLUDE_PYTHON_RUNTIME"
export MSUB_BACKEND_BUNDLE_PROFILE="$BACKEND_BUNDLE_PROFILE"

if [ -z "${MSUB_REQUIRE_OPTIONAL_DEPS+x}" ]; then
    if [ "$BACKEND_BUNDLE_PROFILE" = "full" ]; then
        export MSUB_REQUIRE_OPTIONAL_DEPS=1
    else
        export MSUB_REQUIRE_OPTIONAL_DEPS=0
    fi
fi

if [ "$RUN_PREFLIGHT" = "1" ]; then
    "$SCRIPT_DIR/release-preflight.sh"
fi

set -- xcodebuild \
    -project "$APP_ROOT/MSub.xcodeproj" \
    -scheme MSub \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    clean build \
    "ARCHS=$ARCHS" \
    ONLY_ACTIVE_ARCH=NO

if [ -n "${MSUB_PRODUCT_BUNDLE_IDENTIFIER:-}" ]; then
    set -- "$@" "PRODUCT_BUNDLE_IDENTIFIER=$MSUB_PRODUCT_BUNDLE_IDENTIFIER"
fi

case "$SIGNING_MODE" in
    adhoc)
        set -- "$@" \
            CODE_SIGN_STYLE=Manual \
            "CODE_SIGN_IDENTITY=-" \
            CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
            DEVELOPMENT_TEAM= \
            PROVISIONING_PROFILE_SPECIFIER=
        ;;
    automatic)
        set -- "$@" CODE_SIGN_STYLE=Automatic
        if [ -n "${MSUB_DEVELOPMENT_TEAM:-}" ]; then
            set -- "$@" "DEVELOPMENT_TEAM=$MSUB_DEVELOPMENT_TEAM"
        fi
        ;;
    project)
        if [ -n "${MSUB_DEVELOPMENT_TEAM:-}" ]; then
            set -- "$@" "DEVELOPMENT_TEAM=$MSUB_DEVELOPMENT_TEAM"
        fi
        ;;
    *)
        echo "Unknown MSUB_SIGNING_MODE: $SIGNING_MODE (expected adhoc, automatic, or project)" >&2
        exit 2
        ;;
esac

"$@"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/MSub.app"
echo "Built $APP_PATH"

if [ "$RUN_VALIDATE" = "1" ]; then
    "$SCRIPT_DIR/validate-release-bundle.sh" "$APP_PATH"
fi

if [ "$SIGN_AND_NOTARIZE" = "1" ]; then
    MSUB_APP_PATH="$APP_PATH" "$SCRIPT_DIR/sign-notarize-release.sh"
fi

if [ "$CREATE_DMG" = "1" ]; then
    MSUB_APP_PATH="$APP_PATH" \
    MSUB_DMG_BUILD_APP=0 \
    "$SCRIPT_DIR/package-dmg.sh"
fi

if [ "$INCLUDE_MODEL" != "1" ]; then
    echo "Model weights were not embedded. Re-run with MSUB_INCLUDE_MODEL=1 for a self-contained app bundle."
fi

if [ "$INCLUDE_VENV" != "1" ]; then
    echo "Backend dependencies were not embedded. Re-run with MSUB_INCLUDE_VENV=1 for a self-contained backend."
fi

if [ "$BACKEND_BUNDLE_PROFILE" != "full" ]; then
    echo "Torch-based optional backend features were excluded. Re-run with MSUB_BACKEND_BUNDLE_PROFILE=full for a larger all-features bundle."
fi
