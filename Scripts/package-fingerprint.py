"""Fingerprint package inputs without spawning stat/shasum for every file."""
import argparse
import hashlib
import os
import stat
from pathlib import Path


def fingerprint(paths, content=False):
    digest = hashlib.sha256()
    excluded = {"__pycache__", ".git", ".cache", ".pytest_cache", ".mypy_cache", ".ruff_cache"}

    def record(path, metadata=None):
        metadata = metadata if metadata is not None else path.lstat()
        digest.update(os.fsencode(str(path)) + b"\0")
        digest.update(f"{metadata.st_mode}:{metadata.st_size}:{metadata.st_mtime_ns}:{metadata.st_ctime_ns}".encode())
        if stat.S_ISLNK(metadata.st_mode):
            digest.update(os.fsencode(os.readlink(path)))
        elif content and stat.S_ISREG(metadata.st_mode):
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)

    def walk(directory):
        # Reuse DirEntry metadata instead of repeating lstat/is_symlink/is_file
        # for every dependency. Keep the original os.walk ordering and digest.
        try:
            with os.scandir(directory) as entries:
                directories, files = [], []
                for entry in entries:
                    if entry.is_dir():
                        if entry.name not in excluded:
                            directories.append(entry)
                    else:
                        files.append(entry)
        except OSError:
            # Matches os.walk's handling of unreadable directories.
            return
        directories.sort(key=lambda entry: entry.name)
        for entry in directories:
            if entry.is_symlink():
                record(Path(entry.path), entry.stat(follow_symlinks=False))
        for entry in sorted(files, key=lambda entry: entry.name):
            if entry.name == ".DS_Store" or entry.name.endswith((".pyc", ".pyo")):
                continue
            record(Path(entry.path), entry.stat(follow_symlinks=False))
        for entry in directories:
            if not entry.is_symlink():
                walk(entry.path)

    for value in paths:
        root = Path(value)
        if not root.exists() and not root.is_symlink():
            digest.update(os.fsencode(str(root)) + b":missing\0")
            continue
        if not root.is_dir() or root.is_symlink():
            record(root)
            continue
        digest.update(os.fsencode(str(root)) + b":directory\0")
        walk(root)
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content", action="store_true")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    print(fingerprint(args.paths, args.content))
