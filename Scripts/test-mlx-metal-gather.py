"""Small GPU regression using the actual Xcode-built MLX objects, no models.

Usage: python3 Scripts/test-mlx-metal-gather.py /absolute/DerivedData/MSub-...
Build the MSub scheme first so its compatibility pre-action has run.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    derived = Path(sys.argv[1]).resolve()
    products = derived / 'Build/Products/Debug'
    checkouts = derived / 'SourcePackages/checkouts'
    source = Path(__file__).parent / 'Checks/metal-gather.swift'
    env = dict(os.environ)
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    # Exercise the same assertion path as Xcode's Metal API Validation.
    env['MTL_DEBUG_LAYER'] = '1'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], env=env, text=True).strip()
    with tempfile.TemporaryDirectory(prefix='msub-gather-') as temporary:
        directory = Path(temporary)
        output = directory / 'check'
        args = ['xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-macosx27.0',
                '-I', str(products),
                '-I', str(checkouts / 'mlx-swift/Source/Cmlx/include'),
                '-I', str(checkouts / 'swift-numerics/Sources/_NumericsShims/include'),
                '-module-cache-path', str(directory / 'modules'), str(source)]
        args += [str(products / (name + '.o')) for name in
                 ['MLX', 'Cmlx', 'Numerics', 'RealModule', 'ComplexModule', '_NumericsShims']]
        args += ['-framework', 'Metal', '-framework', 'Accelerate', '-framework', 'Foundation',
                 '-lc++', '-o', str(output)]
        subprocess.run(args, env=env, check=True)
        shutil.copy(products / 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib',
                    directory / 'mlx.metallib')
        subprocess.run([str(output)], env=env, check=True)


if __name__ == '__main__':
    main()
