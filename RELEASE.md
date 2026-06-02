# MSub Release Checklist

MSub can be packaged as a self-contained macOS app for Apple Silicon Macs, with
the Python backend and runtime embedded in the app bundle. By default, model
weights are not embedded; users are prompted to choose local weights or allow a
download on first use.

## Developer Account

The current release strategy is ad-hoc signing. You can build and share an
ad-hoc signed app without joining the Apple Developer Program. This is suitable
for personal use and trusted testers, but it is not a Developer ID signed or
notarized public release. Users may see Gatekeeper warnings and may need to
Control-click `MSub.app`, choose Open, or approve the app in System Settings >
Privacy & Security.

For normal distribution outside the Mac App Store, use Developer ID signing and
Apple notarization. This requires Apple Developer Program membership and a
Developer ID Application certificate.

## Build

```sh
MSUB_SIGNING_MODE=adhoc apps/MSub/Scripts/build-release.sh
```

The default release build:

- Builds `Release` for `arm64`.
- Uses ad-hoc signing.
- Embeds `.venv` and the standalone Python runtime.
- Embeds the bundled `ffmpeg`.
- Embeds FireRedVAD by default.
- Does not embed ASR model weights by default.
- Runs preflight and bundle validation.

Useful flags:

```sh
MSUB_INCLUDE_MODEL=1 apps/MSub/Scripts/build-release.sh
MSUB_INCLUDE_SENSEVOICE_MODEL=1 apps/MSub/Scripts/build-release.sh
MSUB_INCLUDE_MIMO_MODEL=1 apps/MSub/Scripts/build-release.sh
MSUB_INCLUDE_SPEAKER_RECOGNITION_MODEL=1 apps/MSub/Scripts/build-release.sh
MSUB_INCLUDE_EMOTION_MODEL=1 apps/MSub/Scripts/build-release.sh
MSUB_REQUIRE_OPTIONAL_DEPS=0 apps/MSub/Scripts/build-release.sh
```

Set `MSUB_SIGNING_MODE=automatic` only if you intentionally want Xcode to use a
configured Apple development team. Set `MSUB_SIGNING_MODE=project` to leave the
project signing settings untouched.

## DMG Packaging

Build the app and package it as a DMG in one command:

```sh
MSUB_SIGNING_MODE=adhoc \
MSUB_CREATE_DMG=1 \
MSUB_INCLUDE_MODEL=0 \
apps/MSub/Scripts/build-release.sh
```

To package an existing built app without rebuilding:

```sh
MSUB_DMG_BUILD_APP=0 apps/MSub/Scripts/package-dmg.sh
```

The DMG is written to `.release/` by default, together with a `.sha256` checksum.
The DMG contains:

- `MSub.app`
- An `Applications` shortcut.
- `README.txt` with the current ad-hoc Gatekeeper opening note.

Useful DMG flags:

```sh
MSUB_DIST_DIR=/path/to/dist apps/MSub/Scripts/package-dmg.sh
MSUB_DMG_VOLUME_NAME="MSub" apps/MSub/Scripts/package-dmg.sh
MSUB_DMG_BASENAME="MSub-0.1.0-arm64" apps/MSub/Scripts/package-dmg.sh
MSUB_APP_PATH=/path/to/MSub.app MSUB_DMG_BUILD_APP=0 apps/MSub/Scripts/package-dmg.sh
```

## Future Developer ID Release

After joining the Apple Developer Program, you can sign and notarize in a second
step:

```sh
MSUB_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
MSUB_NOTARY_KEYCHAIN_PROFILE="MSubNotary" \
apps/MSub/Scripts/sign-notarize-release.sh
```

Or as part of the release build:

```sh
MSUB_SIGN_AND_NOTARIZE=1 \
MSUB_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
MSUB_NOTARY_KEYCHAIN_PROFILE="MSubNotary" \
apps/MSub/Scripts/build-release.sh
```

Create the notarytool keychain profile once:

```sh
xcrun notarytool store-credentials MSubNotary \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

## Validate Existing Bundle

```sh
apps/MSub/Scripts/validate-release-bundle.sh \
  /path/to/MSub.app
```

To also launch the embedded backend and check `/api/health`:

```sh
MSUB_VALIDATE_BACKEND_START=1 \
apps/MSub/Scripts/validate-release-bundle.sh \
  /path/to/MSub.app
```

To require Developer ID signing during validation:

```sh
MSUB_REQUIRE_DEVELOPER_ID=1 \
apps/MSub/Scripts/validate-release-bundle.sh \
  /path/to/MSub.app
```
