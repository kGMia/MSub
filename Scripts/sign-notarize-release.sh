#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
CONFIGURATION="${MSUB_CONFIGURATION:-Release}"
DEFAULT_APP_PATH="$REPO_ROOT/.xcode-derived-release/Build/Products/$CONFIGURATION/MSub.app"
APP_PATH="${MSUB_APP_PATH:-$DEFAULT_APP_PATH}"
IDENTITY="${MSUB_DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${MSUB_NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}"
APPLE_ID="${MSUB_NOTARY_APPLE_ID:-${APPLE_ID:-}}"
APPLE_PASSWORD="${MSUB_NOTARY_PASSWORD:-${APPLE_ID_PASSWORD:-}}"
KEYCHAIN_PROFILE="${MSUB_NOTARY_KEYCHAIN_PROFILE:-}"
SKIP_NOTARIZE="${MSUB_SKIP_NOTARIZE:-0}"
ZIP_PATH="${MSUB_NOTARY_ZIP_PATH:-$REPO_ROOT/.release/MSub-notary.zip}"

fail() {
    echo "release signing failed: $*" >&2
    exit 1
}

note() {
    echo "release signing: $*"
}

[ -d "$APP_PATH" ] || fail "MSub.app not found: $APP_PATH"
[ -n "$IDENTITY" ] || fail "set MSUB_DEVELOPER_ID_APPLICATION to your Developer ID Application identity"

mkdir -p "$(dirname "$ZIP_PATH")"

sign_macho_file() {
    file="$1"
    kind="$(file -b "$file" 2>/dev/null || true)"
    case "$kind" in
        *Mach-O*)
            codesign --force --timestamp --options runtime --sign "$IDENTITY" "$file"
            ;;
    esac
}

note "signing nested Mach-O files"
find "$APP_PATH/Contents" -type f | while IFS= read -r file; do
    case "$file" in
        "$APP_PATH/Contents/MacOS/MSub") ;;
        *) sign_macho_file "$file" ;;
    esac
done

note "signing app bundle"
codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$APP_ROOT/MSub.entitlements" \
    --sign "$IDENTITY" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ "$SKIP_NOTARIZE" = "1" ]; then
    note "notarization skipped by MSUB_SKIP_NOTARIZE=1"
    "$SCRIPT_DIR/validate-release-bundle.sh" "$APP_PATH"
    exit 0
fi

note "creating notarization zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if [ -n "$KEYCHAIN_PROFILE" ]; then
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
else
    [ -n "$APPLE_ID" ] || fail "set MSUB_NOTARY_APPLE_ID or MSUB_NOTARY_KEYCHAIN_PROFILE"
    [ -n "$APPLE_PASSWORD" ] || fail "set MSUB_NOTARY_PASSWORD or MSUB_NOTARY_KEYCHAIN_PROFILE"
    [ -n "$TEAM_ID" ] || fail "set MSUB_NOTARY_TEAM_ID or MSUB_NOTARY_KEYCHAIN_PROFILE"
    xcrun notarytool submit "$ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait
fi

xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

MSUB_REQUIRE_DEVELOPER_ID=1 "$SCRIPT_DIR/validate-release-bundle.sh" "$APP_PATH"
note "ok: $APP_PATH"
