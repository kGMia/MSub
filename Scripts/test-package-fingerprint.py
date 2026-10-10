import importlib.util
import hashlib
import os
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("fingerprint", Path(__file__).with_name("package-fingerprint.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FingerprintTests(unittest.TestCase):
    def test_digest_contract_for_content_links_exclusions_and_missing_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "source"
            root.mkdir()
            external = base / "external"
            external.mkdir()
            (external / "not-copied").write_text("external")
            (root / "a-link").symlink_to(external, target_is_directory=True)
            (root / "b-broken").symlink_to("missing-target")
            (root / "c.py").write_text("source")
            (root / "lib").mkdir()
            (root / "lib/d.py").write_text("nested")
            (root / "__pycache__").mkdir()
            (root / "__pycache__/ignored").write_text("not an input")
            (root / "ignored.pyc").write_text("bytecode")
            missing = base / "absent"
            # The published digest contract is directories' symlinks, then
            # sorted files, then child directories; symlinks stay opaque.
            records = [root / name for name in ["a-link", "b-broken", "c.py", "lib/d.py"]]
            for content in (False, True):
                digest = hashlib.sha256(os.fsencode(str(root)) + b":directory\0")
                for path in records:
                    info = path.lstat()
                    digest.update(os.fsencode(str(path)) + b"\0")
                    digest.update(f"{info.st_mode}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}".encode())
                    if path.is_symlink():
                        digest.update(os.fsencode(os.readlink(path)))
                    elif content:
                        digest.update(path.read_bytes())
                digest.update(os.fsencode(str(missing)) + b":missing\0")
                self.assertEqual(module.fingerprint([root, missing], content), digest.hexdigest())

    def test_changes_and_deletions_invalidate_but_bytecode_does_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "module.py"
            source.write_text("first")
            first = module.fingerprint([root])
            cache = root / "__pycache__"
            cache.mkdir()
            (cache / "module.pyc").write_bytes(b"compiled")
            self.assertEqual(first, module.fingerprint([root]))
            source.write_text("second version")
            second = module.fingerprint([root])
            self.assertNotEqual(first, second)
            source.unlink()
            self.assertNotEqual(second, module.fingerprint([root]))

    def test_symlink_destination_changes_invalidate(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "python"
            link.symlink_to("runtime-a")
            before = module.fingerprint([directory])
            link.unlink()
            link.symlink_to("runtime-b")
            self.assertNotEqual(before, module.fingerprint([directory]))


if __name__ == "__main__":
    unittest.main()
