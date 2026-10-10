#!/bin/bash
# Real inference is opt-in; the supplied WAV must contain speech in its first
# five seconds and use 16 kHz mono PCM. No models or toolchains are downloaded.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: bash Scripts/test-native-mlx.sh /absolute/qwen-model /absolute/16k-mono.wav" >&2
    exit 2
fi
model_path="$1"
audio_path="$2"
[[ "$model_path" = /* && -f "$model_path/config.json" ]] || { echo "Model must be an absolute local directory with config.json" >&2; exit 2; }
[[ "$audio_path" = /* && -f "$audio_path" ]] || { echo "Audio must be an absolute file path" >&2; exit 2; }

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_root="$(cd "$app_dir/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$project_root/.swift-module-cache"
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "Metal Toolchain is missing. Install it using: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

cd "$app_dir"
# Reviewed pinned MLX CudaBuild plugin is a no-op on macOS; Xcode otherwise
# requires GUI plugin trust before this command-line build can proceed.
xcodebuild -project MSub.xcodeproj -scheme MSub -destination platform=macOS \
    -derivedDataPath "$project_root/.xcode-derived" -skipPackagePluginValidation build
swift package resolve
python3 Scripts/patch-mlx-metal.py .build/checkouts
swift test
bin_dir="$(swift build --show-bin-path)"
shader="$project_root/.xcode-derived/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
[[ -f "$shader" ]] || { echo "Xcode build did not produce the expected MLX Metal library: $shader" >&2; exit 1; }
# SwiftPM does not compile Metal resources. Use shaders built from the same
# locked Swift dependency, never a metallib from the Python MLX installation.
cp "$shader" "$bin_dir/MSubPackageTests.xctest/Contents/MacOS/mlx.metallib"
MSUB_NATIVE_TEST_MODEL="$model_path" MSUB_NATIVE_TEST_AUDIO="$audio_path" \
    swift test --skip-build --filter NativeQwenServiceTests.testLocalModelSmoke
