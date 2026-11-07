#!/usr/bin/env python3
"""Package an immutable shader resource tree, including all companion folders.

Game-derived resources and the returned SHA manifest must stay out of git.
Callers must verify the manifest after extraction, before activating a tree.
"""
import hashlib
from pathlib import Path
import zipfile


def inventory(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Expected a real shader resource directory')
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Shader resource symlinks are not supported: ' + str(path))
        if any(p.startswith('._') or p == '.DS_Store' for p in path.relative_to(root).parts):
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Unsupported shader resource: ' + str(path))
        with path.open('rb') as stream:
            files[path.relative_to(root).as_posix()] = hashlib.file_digest(stream, 'sha256').hexdigest()
    if not files:
        raise ValueError('Empty shader resource tree')
    return files


def package(root, archive, prefix='', *, companions_only=False):
    root, archive = Path(root), Path(archive)
    if prefix and (prefix.startswith('/') or any(p in ('', '.', '..') for p in prefix.split('/'))):
        raise ValueError('Archive prefix must be relative')
    files = inventory(root)
    if companions_only:
        files = {name: digest for name, digest in files.items() if '/' in name}
    if not files:
        raise ValueError('No selected shader resources')
    mapping = {(prefix + '/' if prefix else '') + name: digest for name, digest in files.items()}
    # Exclusive creation prevents overwriting a previous delivery attempt.
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED, compresslevel=1) as output:
        for name in files:
            output.write(root / name, (prefix + '/' if prefix else '') + name)
    verify(archive, mapping)
    return mapping


def verify(archive, files):
    with zipfile.ZipFile(archive) as source:
        names = source.namelist()
        if len(names) != len(set(names)) or set(names) != set(files):
            raise ValueError('Archive omits, duplicates or adds shader resources')
        for name, expected in files.items():
            with source.open(name) as stream:
                digest = hashlib.sha256()
                while block := stream.read(1 << 20):
                    digest.update(block)
                if digest.hexdigest() != expected:
                    raise ValueError('Archive resource hash mismatch: ' + name)
