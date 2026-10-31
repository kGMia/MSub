"""Compile a small native encoder probe using an existing Xcode Debug build.
No dependency resolution, full app rebuild, network access, or GUI launch.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repetition', action='store_true', help='Compare repetition policies on bounded real audio')
    parser.add_argument('--pipeline', action='store_true', help='Test actual service: warm throughput, live cues, odd tail, checkpoint cancellation/retry')
    parser.add_argument('--decode', action='store_true', help='Compare final text using standard, individual-feature and batch-feature decoding')
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--audio', type=Path, required=True, help='At least two windows of mono16k Float32-decodable WAV')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.derived_data.resolve()
    repo = Path(__file__).resolve().parents[1]
    products = root / 'Build/Products/Debug'
    source = repo / 'apps/MSub/Scripts' / ('benchmark-qwen-repetition.swift' if args.repetition else 'benchmark-qwen-pipeline.swift' if args.pipeline else 'benchmark-qwen-decode.swift' if args.decode else 'benchmark-qwen-encoder.swift')
    if not (products / 'MLXAudioSTT.o').is_file():
        parser.error('Build the MSub Debug scheme in Xcode first')
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    def xcrun(*args):
        return subprocess.check_output(['xcrun', *args], env=env, text=True).strip()
    with tempfile.TemporaryDirectory(prefix='msub-native-probe-') as temporary:
        work = Path(temporary)
        executable = work / 'qwen-encoder-probe'
        command = [xcrun('--find', 'swiftc'), '-swift-version', '6', '-parse-as-library',
                   '-target', 'arm64-apple-macos27.0', '-sdk', xcrun('--show-sdk-path'),
                   '-I', str(products), '-module-cache-path', str(work / 'module-cache')]
        for modulemap in (root / 'SourcePackages/checkouts').rglob('module.modulemap'):
            command += ['-Xcc', '-fmodule-map-file=' + str(modulemap)]
        cmlx = root / 'SourcePackages/checkouts/mlx-swift/Source/Cmlx'
        for include in [cmlx / 'include', cmlx / 'mlx-c']:
            command += ['-Xcc', '-I' + str(include)]
        yyjson = root / 'Build/Intermediates.noindex/yyjson.build/Debug/yyjson-t.build/yyjson.modulemap'
        command += ['-Xcc', '-fmodule-map-file=' + str(yyjson), str(source)]
        if args.pipeline or args.repetition:
            command += [str(repo / 'apps/MSub/Sources/MSub' / name) for name in
                        ['NativeQwenService.swift', 'NativeQwenSupport.swift', 'NativeQwenResidency.swift']]
            env.pop('MSUB_NATIVE_QWEN_BATCH_SIZE', None)
            env.pop('MSUB_NATIVE_QWEN_ENCODER_PROBE', None)
            env.pop('MSUB_NATIVE_QWEN_STREAM_REFERENCE', None)
        command += [str(obj) for obj in products.glob('*.o')]
        for framework in ['Metal', 'Accelerate', 'Foundation', 'AVFoundation']:
            command += ['-framework', framework]
        command += ['-lc++', '-o', str(executable)]
        subprocess.run(command, env=env, check=True)
        (work / 'mlx-swift_Cmlx.bundle').symlink_to(products / 'mlx-swift_Cmlx.bundle', target_is_directory=True)
        result = subprocess.check_output([str(executable), str(args.model.resolve()), str(args.audio.resolve())],
                                         env=env, text=True)
        args.output.write_text(result)
        print(result)

if __name__ == '__main__':
    main()
