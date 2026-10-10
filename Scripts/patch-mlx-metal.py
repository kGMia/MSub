"""Apply narrowly scoped compatibility fixes to the pinned mlx-swift checkout.

Metal's pre-C++17 dialect accepts if constexpr as an extension. Keep its
compile-time branch semantics and all other diagnostics. Remove this workaround
when upstream fixes https://github.com/ml-explore/mlx-swift/issues/342.

Gather also needs non-null bindings for scalar-index shape/stride metadata.
The scalar specialization does not read these placeholders, as in Scatter's
existing implementation. Metal API validation must remain enabled.
"""
import hashlib
import os
from pathlib import Path
import stat
import sys

HEADERS = {
    'utils/integral_constant.h': ('b906fa1e66612cf0a90c24a4cbe9b5682aa387f2cc14a6c6c7f93ad543e796db', 'namespace mlx {'),
    'attn/kernels/steel_attention.h': ('a488b87b48b52b30caf8d3052a6cc1206afbbc469a001a833ceb7b57ac3b1003', 'using namespace mlx::steel;'),
}
BEGIN = ('// MSUB_MLX_CONSTEXPR_COMPAT_BEGIN\n'
         '#pragma clang diagnostic push\n'
         '#pragma clang diagnostic ignored "-Wc++17-extensions"\n')
END = '\n#pragma clang diagnostic pop\n// MSUB_MLX_CONSTEXPR_COMPAT_END\n'

GATHER_PATH = 'mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/indexing.cpp'
GATHER_SHA256 = 'dfabee30b3975a0d3836d4a94216755dbc550ca5d68a194cf16d43a7cd3b1c7c'
GATHER_ORIGINAL = '''  // Set index info
  //
  // We don't need to check for empty idx_shapes because gather has a
  // idx_ndim == 0 specialization
  compute_encoder.set_vector_bytes(idx_shapes, 7);
'''
GATHER_FIXED = '''  // Set index info
  // MSUB_MLX_SCALAR_GATHER_COMPAT: the scalar kernel ignores this metadata,
  // but Metal rejects a null setBytes pointer even when its length is zero.
  // Match Scatter's placeholder binding without changing index rank/values.
  if (idx_ndim == 0) {
    idx_shapes.push_back(0);
    idx_strides.push_back(0);
  }
  compute_encoder.set_vector_bytes(idx_shapes, 7);
'''


def patch_scalar_gather(checkouts):
    path = Path(checkouts) / GATHER_PATH
    current = path.read_text()
    original = current.replace(GATHER_FIXED, GATHER_ORIGINAL)
    if hashlib.sha256(original.encode()).hexdigest() != GATHER_SHA256:
        raise RuntimeError(f'MLX Gather source changed; review runtime compatibility before building: {path}')
    if original.count(GATHER_ORIGINAL) != 1:
        raise RuntimeError(f'MLX Gather patch anchor mismatch: {path}')
    updated = original.replace(GATHER_ORIGINAL, GATHER_FIXED, 1)
    if updated == current:
        return
    mode = stat.S_IMODE(path.stat().st_mode)
    try:
        path.chmod(mode | stat.S_IWUSR)
        path.write_text(updated)
    finally:
        path.chmod(mode)
    print('Applied MLX scalar Gather Metal binding compatibility')


def patch(checkouts):
    patch_scalar_gather(checkouts)
    root = Path(checkouts) / 'mlx-swift/Source/Cmlx/mlx-generated/metal/steel'
    for relative, (expected, anchor) in HEADERS.items():
        path = root / relative
        if not path.is_file():
            print(f'warning: MLX compatibility header not found: {path}')
            continue
        current = path.read_text()
        original = current.replace(BEGIN, '').removesuffix(END)
        if hashlib.sha256(original.encode()).hexdigest() != expected:
            print(f'warning: MLX header changed upstream; review compatibility patch: {relative}')
            continue
        updated = original.replace(anchor, BEGIN + anchor, 1) + END
        if updated == current:
            continue
        mode = stat.S_IMODE(path.stat().st_mode)
        try:
            path.chmod(mode | stat.S_IWUSR)
            path.write_text(updated)
        finally:
            path.chmod(mode)
        print(f'Applied scoped MLX Metal compatibility: {relative}')


if __name__ == '__main__':
    if len(sys.argv) == 2:
        checkouts = Path(sys.argv[1])
    else:
        # Xcode scheme pre-action with settings from the MSub buildable.
        build_dir = os.environ.get('BUILD_DIR')
        if not build_dir:
            sys.exit('Usage: patch-mlx-metal.py /path/to/SourcePackages/checkouts')
        checkouts = Path(build_dir).parent.parent / 'SourcePackages/checkouts'
    patch(checkouts)
