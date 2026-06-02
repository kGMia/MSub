#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
DERIVED_DATA="${MSUB_DERIVED_DATA:-$REPO_ROOT/.xcode-derived-release}"
CONFIGURATION="${MSUB_CONFIGURATION:-Release}"
BUILD_APP="${MSUB_DMG_BUILD_APP:-1}"
RUN_VALIDATE="${MSUB_DMG_VALIDATE:-1}"
DIST_DIR="${MSUB_DIST_DIR:-$REPO_ROOT/.release}"
APP_PATH="${MSUB_APP_PATH:-$DERIVED_DATA/Build/Products/$CONFIGURATION/MSub.app}"
VOLUME_NAME="${MSUB_DMG_VOLUME_NAME:-MSub}"

fail() {
    echo "dmg packaging failed: $*" >&2
    exit 1
}

note() {
    echo "dmg packaging: $*"
}

if [ "$BUILD_APP" = "1" ]; then
    note "building release app"
    "$SCRIPT_DIR/build-release.sh"
fi

[ -d "$APP_PATH" ] || fail "app bundle not found: $APP_PATH"
[ -x "$APP_PATH/Contents/MacOS/MSub" ] || fail "app executable is missing"

if [ "$RUN_VALIDATE" = "1" ]; then
    "$SCRIPT_DIR/validate-release-bundle.sh" "$APP_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/MSub" 2>/dev/null | tr ' ' '-' || echo "macos")"
DMG_BASENAME="${MSUB_DMG_BASENAME:-MSub-$VERSION-$BUILD-$ARCHS}"
DMG_PATH="${MSUB_DMG_PATH:-$DIST_DIR/$DMG_BASENAME.dmg}"
SHA_PATH="$DMG_PATH.sha256"

WORK_DIR="${TMPDIR:-/tmp}/msub-dmg-$$"
STAGING_DIR="$WORK_DIR/staging"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

rm -rf "$WORK_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

note "staging app"
ditto "$APP_PATH" "$STAGING_DIR/MSub.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/README.txt" <<'EOF'
MSub is currently ad-hoc signed.

If macOS says it cannot verify the developer, Control-click MSub.app and choose
Open, or allow it in System Settings > Privacy & Security.

Model weights are not bundled by default. On first use, MSub will ask you to
choose local model weights or download them.
EOF

rm -f "$DMG_PATH" "$SHA_PATH"

note "creating $DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

note "verifying dmg"
hdiutil verify "$DMG_PATH"

note "writing checksum"
shasum -a 256 "$DMG_PATH" > "$SHA_PATH"

note "ok: $DMG_PATH"
echo "Checksum: $SHA_PATH"
