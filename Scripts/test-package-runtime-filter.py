"""Small real-rsync fixtures for the pre-copy runtime filter (no installed models)."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("runtime_filter", Path(__file__).with_name("package-runtime-filter.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@unittest.skipUnless(shutil.which("rsync"), "rsync is required")
class RuntimeFilterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="msub runtime filter ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.dest = self.root / "dest"
        self.source.mkdir()
        self.dest.mkdir()
        self.site = "lib/python3.12/site-packages/"

    def write(self, path):
        file = self.source / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(path)

    def sync(self, target="venv", profile="core", slim=True):
        rules = self.root / "filter"
        rules.write_text("\n".join(module.exclusions(target, profile, slim)) + "\n")
        subprocess.run(["rsync", "-a", "--delete", "--delete-excluded", f"--exclude-from={rules}",
                        f"{self.source}/", f"{self.dest}/"], check=True, capture_output=True)
        return {str(p.relative_to(self.dest)) for p in self.dest.rglob("*") if p.is_file()}

    def test_core_and_slim_preserve_runtime_and_remove_previous_full_payload(self):
        keep = ["bin/python", "pyvenv.cfg", self.site + "mlx/core.so", self.site + "pkg/__init__.pyi",
                self.site + "pkg/testing/helper.py", self.site + "pkg/test.py", self.site + "pkg/weights.bin"]
        trimmed = [self.site + "pkg/tests/test_core.py", self.site + "pkg/deep/include/api.h",
                   self.site + "pkg/native.cpp", self.site + "direct.h", self.site + "pkg/docs/readme.md",
                   self.site + "pkg/lib.a", self.site + "pkg/deep/share/man/info.1",
                   self.site + "tests/test_top.py"]
        core = [self.site + "torch/lib/libtorch.dylib", self.site + "torch-2.0.dist-info/METADATA",
                self.site + "sounddevice.py", self.site + "distutils-precedence.pth"]
        ignored = [self.site + "pkg/__pycache__/module.pyc", self.site + "_editable_impl_demo.pth"]
        for path in keep + trimmed + core + ignored:
            self.write(path)
        self.assertEqual(self.sync(profile="full", slim=False), set(keep + trimmed + core))
        self.assertEqual(self.sync(), set(keep))
        # Restoring full/non-slim settings must also restore omitted files.
        self.assertEqual(self.sync(profile="full", slim=False), set(keep + trimmed + core))
        self.assertEqual(self.sync(slim=False), set(keep + trimmed))
        self.assertEqual(self.sync(profile="full"), set(keep + core))
        (self.source / keep[-1]).unlink()
        self.assertNotIn(keep[-1], self.sync())

    def test_base_python_filter_and_opt_out(self):
        keep = ["bin/python3.12", "lib/python3.12/asyncio/tasks.py", "lib/python3.12/typing.py",
                "lib/python3.12/site-packages/pkg/__init__.pyi", "lib/libpython3.12.dylib"]
        trimmed = ["include/python3.12/Python.h", "share/man/python.1", "share/doc/readme",
                   "lib/python3.12/test/test_math.py", "lib/python3.12/turtle.py",
                   "lib/python3.12/ensurepip/__init__.py", "lib/python3.12/tkinter/__init__.py"]
        for path in keep + trimmed:
            self.write(path)
        self.assertEqual(self.sync(target="python", slim=False), set(keep + trimmed))
        self.assertEqual(self.sync(target="python"), set(keep))

    def test_invalid_policy_fails_before_copy(self):
        with self.assertRaises(ValueError):
            module.exclusions("venv", profile="typo")

    def test_packager_reuses_runtime_for_source_edits_and_invalidates_policy(self):
        repo = self.root / "repository"
        scripts = repo / "apps/MSub/Scripts"
        scripts.mkdir(parents=True)
        for name in ("package-backend.sh", "package-fingerprint.py", "package-runtime-filter.py"):
            shutil.copy2(Path(__file__).with_name(name), scripts / name)
        for name in ("pyproject.toml", "uv.lock", "README.md", ".python-version"):
            (repo / name).write_text("fixture")
        source = repo / "src"
        source.mkdir()
        (source / "backend.py").write_text("print('first')")
        venv = repo / ".venv"
        (venv / "bin").mkdir(parents=True)
        (venv / "bin/python").symlink_to(sys.executable)
        (venv / "pyvenv.cfg").write_text("fixture")
        for name in ("torch/__init__.py", "pkg/__init__.pyi", "pkg/tests/test_pkg.py"):
            path = venv / self.site / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        env = {key: value for key, value in os.environ.items() if not key.startswith(("MSUB_", "HUZ_"))}
        env.update(SRCROOT=str(scripts.parent), TARGET_BUILD_DIR=str(self.root / "build"),
                   UNLOCALIZED_RESOURCES_FOLDER_PATH="MSub.app/Contents/Resources",
                   MSUB_INCLUDE_PYTHON_RUNTIME="0", MSUB_INCLUDE_FIRERED_VAD_MODEL="0",
                   MSUB_INCLUDE_PYANNOTE_SEGMENTATION_MLX_MODEL="0")
        dest = self.root / "build/MSub.app/Contents/Resources/backend"

        def package():
            return subprocess.run(["bash", str(scripts / "package-backend.sh")], env=env,
                                  check=True, capture_output=True, text=True).stdout

        self.assertIn("cache=miss", package())
        self.assertFalse((dest / ".venv" / self.site / "torch").exists())
        self.assertFalse((dest / ".venv" / self.site / "pkg/tests").exists())
        self.assertTrue((dest / ".venv" / self.site / "pkg/__init__.pyi").exists())
        self.assertIn("cache=hit", package())
        (source / "backend.py").write_text("print('updated')")
        self.assertIn("Backend runtime unchanged", package())
        self.assertEqual((dest / "src/backend.py").read_text(), "print('updated')")
        (source / "backend.py").unlink()
        self.assertIn("Backend runtime unchanged", package())
        self.assertFalse((dest / "src/backend.py").exists())
        with (scripts / "package-runtime-filter.py").open("a") as stream:
            stream.write("\n# Changed packaging policy\n")
        self.assertIn("Copying backend Python virtual environment", package())
        env["MSUB_BACKEND_BUNDLE_PROFILE"] = "full"
        self.assertIn("Copying backend Python virtual environment", package())
        self.assertTrue((dest / ".venv" / self.site / "torch/__init__.py").exists())
        env["MSUB_SLIM_VENV"] = "0"
        self.assertIn("Copying backend Python virtual environment", package())
        self.assertTrue((dest / ".venv" / self.site / "pkg/tests/test_pkg.py").exists())
        with (scripts / "package-runtime-filter.py").open("a") as stream:
            stream.write("\nraise RuntimeError('fixture failure')\n")
        with self.assertRaises(subprocess.CalledProcessError):
            package()
        self.assertFalse((dest / ".msub-package-signature").exists())
        self.assertFalse((dest / ".msub-runtime-signature").exists())


if __name__ == "__main__":
    unittest.main()
