#!/usr/bin/env python3
"""Pack compiled NVN shaders as an optional, verified sibling of b-<chain>."""

import argparse
from hashlib import sha256
import os
from pathlib import Path
import re
import tempfile

from romfs_image import ENT, HEAD, MAGIC, read_index


SHADER = re.compile(r"[a-f0-9]{16}_b[a-z0-9]*\.(json|metallib)")
CHUNK = 1 << 20


def pack(folder: Path, output: Path, skip_pulling: bool = False) -> int:
    stamp = folder / "inputs.tsv"
    if stamp.is_symlink() or not stamp.is_file() or not 0 < stamp.stat().st_size <= 4096:
        raise ValueError("The shader library needs a completed inputs.tsv stamp")
    inputs = stamp.read_text().splitlines()
    if not any(re.fullmatch(r"game\t[a-fA-F0-9]{16}", row) for row in inputs) or not any(
        re.fullmatch(r"inputs\t[a-fA-F0-9]+", row) for row in inputs
    ):
        raise ValueError("inputs.tsv is missing the game or profile digest")
    files = [stamp] + [
        p for p in folder.iterdir()
        if SHADER.fullmatch(p.name) and not (skip_pulling and p.name.endswith("_bp.metallib"))
    ]
    if not any(p.suffix == ".metallib" for p in files):
        raise ValueError("No compiled NVN shader libraries found")
    files.sort(key=lambda p: p.name)
    states = {}
    for p in files:
        if p.is_symlink() or not p.is_file() or p.stat().st_size == 0:
            raise ValueError(f"Invalid shader file: {p.name}")
        states[p] = identity(p.stat())
    fd, temp = tempfile.mkstemp(prefix=output.name + ".", suffix=".part", dir=output.parent)
    try:
        names = bytearray()
        index = bytearray(ENT.pack(1, len(files), 0, 0, 0, 0))
        verified = {}
        with os.fdopen(fd, "w+b") as image:
            image.write(bytes(HEAD.size))
            for path in files:
                name = path.name.encode("ascii")
                offset = image.tell()
                digest = sha256()
                with path.open("rb") as source:
                    if identity(os.fstat(source.fileno())) != states[path]:
                        raise ValueError(f"Shader changed during packing: {path.name}")
                    while data := source.read(CHUNK):
                        digest.update(data)
                        image.write(data)
                size = image.tell() - offset
                if size != states[path][2]:
                    raise ValueError(f"Shader size changed during packing: {path.name}")
                index.extend(ENT.pack(offset, size, len(names), len(name), 1, 0))
                names.extend(name)
                verified[path.name] = offset, size, digest.digest()
            index_offset = image.tell()
            image.write(index)
            image.write(names)
            image.seek(0)
            image.write(HEAD.pack(MAGIC, index_offset, len(index) + len(names), len(files) + 1))
            image.flush()
            actual = read_index(temp)
            if len(actual) != len(verified):
                raise ValueError("Image index is incomplete")
            for name, (offset, size, expected) in verified.items():
                if actual.get(name) != (False, offset, size):
                    raise ValueError(f"Incorrect index entry: {name}")
                image.seek(offset)
                digest = sha256()
                remaining = size
                while remaining:
                    data = image.read(min(CHUNK, remaining))
                    if not data:
                        raise ValueError(f"Truncated image entry: {name}")
                    digest.update(data)
                    remaining -= len(data)
                if digest.digest() != expected:
                    raise ValueError(f"Image readback failed: {name}")
            if any(identity(path.stat()) != states[path] for path in files):
                raise ValueError("Shader files changed while verifying the image")
            os.fsync(image.fileno())
        os.replace(temp, output)
    finally:
        Path(temp).unlink(missing_ok=True)
    return len(files)


def identity(st):
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path, help="Existing compiled b-<chain> directory")
    parser.add_argument("--output", type=Path, help="Defaults to <folder>.img")
    parser.add_argument("--skip-pulling", action="store_true", help="Omit unused pulling vertex libraries")
    args = parser.parse_args()
    folder = args.folder.resolve()
    output = args.output or folder.with_name(folder.name + ".img")
    if not re.fullmatch(r"b-[a-f0-9]+", folder.name):
        parser.error("expected a b-<chain> directory")
    if output.suffix != ".img":
        parser.error("output must use the .img extension")
    print(f"Verified {pack(folder, output, args.skip_pulling)} files in {output}; original files retained")
