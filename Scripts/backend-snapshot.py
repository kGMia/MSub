"""Track the external backend with the app without moving the development workspace."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

APP = Path(__file__).resolve().parents[1]
SNAPSHOT = APP / 'Backend'
ROOT_FILES = ('pyproject.toml', 'uv.lock', '.python-version', 'README.md', 'README.zh-CN.md')


def inputs(root):
    files = [root / name for name in ROOT_FILES]
    for folder, suffixes in [('src', {'.py'}), ('tests', {'.py'}), ('scripts', {'.py', '.sh'})]:
        files += [p for p in (root / folder).rglob('*') if p.is_file() and p.suffix in suffixes and '__pycache__' not in p.parts]
    for path in files:
        if path.is_symlink():
            raise SystemExit(f'Symlink is not a release source: {path}')
        if not path.is_file():
            raise SystemExit(f'Missing backend source: {path}')
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}


def manifest(files):
    digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return {'schema': 1, 'backendRevision': digest, 'files': files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sync', action='store_true', help='Explicitly replace the tracked snapshot from the workspace')
    parser.add_argument('--workspace', type=Path, help='Also compare the live workspace to the tracked snapshot')
    args = parser.parse_args()
    if args.sync:
        if not args.workspace:
            parser.error('--sync requires --workspace')
        files = inputs(args.workspace)
        for name in ('src', 'tests', 'scripts'):
            if (SNAPSHOT / name).exists():
                shutil.rmtree(SNAPSHOT / name)
        for name in files:
            dest = SNAPSHOT / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.workspace / name, dest)
        (SNAPSHOT / 'manifest.json').write_text(json.dumps(manifest(files), indent=2, sort_keys=True) + '\n')
    expected = json.loads((SNAPSHOT / 'manifest.json').read_text())
    if manifest(inputs(SNAPSHOT)) != expected:
        raise SystemExit('Backend snapshot differs from its manifest; explicitly sync and review before committing.')
    if args.workspace and manifest(inputs(args.workspace)) != expected:
        raise SystemExit('Live backend differs from tracked Backend snapshot. Run Scripts/backend-snapshot.py --sync --workspace <workspace> and commit both together.')
    print('Verified backend revision ' + expected['backendRevision'])

if __name__ == '__main__':
    main()
