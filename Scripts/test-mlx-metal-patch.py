import hashlib
import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mlx_patch', Path(__file__).with_name('patch-mlx-metal.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GatherPatchTests(unittest.TestCase):
    def testPatchIsIdempotentAndPreservesPermissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / module.GATHER_PATH
            path.parent.mkdir(parents=True)
            original = '// fixture\n' + module.GATHER_ORIGINAL
            path.write_text(original)
            path.chmod(0o444)
            with patch.object(module, 'GATHER_SHA256', hashlib.sha256(original.encode()).hexdigest()):
                module.patch_scalar_gather(temporary)
                self.assertIn(module.GATHER_FIXED, path.read_text())
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o444)
                modified = path.stat().st_mtime_ns
                module.patch_scalar_gather(temporary)
                self.assertEqual(path.stat().st_mtime_ns, modified)

    def testUnknownSourceIsRejectedWithoutWriting(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / module.GATHER_PATH
            path.parent.mkdir(parents=True)
            original = '// changed upstream\n' + module.GATHER_ORIGINAL
            path.write_text(original)
            with self.assertRaises(RuntimeError):
                module.patch_scalar_gather(temporary)
            self.assertEqual(path.read_text(), original)


if __name__ == '__main__':
    unittest.main()
