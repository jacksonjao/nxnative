#!/usr/bin/env python3
"""Build selected hash-bound non-point vertex variants for the iOS Metal 3 fallback."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build(sources: Path, manifest: Path, libraries: Path, keys: Path, output: Path) -> int:
    doc = json.loads(manifest.read_text())
    chain = doc["chain"]
    if doc["schema"] != 1 or not re.fullmatch(r"[0-9a-f]{12}", chain):
        raise ValueError("Invalid source manifest version or chain")
    if libraries.name != f"b-{chain}" or output.exists() or output.is_symlink():
        raise ValueError("Use the exact base library chain and a new output directory")
    selected = sorted(set(keys.read_text().split()))
    if not selected or any(not re.fullmatch(r"[0-9a-f]{16}_b", key) for key in selected):
        raise ValueError("Expected a nonempty list of vertex shader keys")

    flags = ["-target", "air64-apple-ios16.1", "-std=metal3.0", "-fno-fast-math",
             "-fpreserve-invariance"]
    records = {}
    with TemporaryDirectory(prefix=".nonpoint-metal3-", dir=output.parent) as directory:
        tmp = Path(directory)
        stage = tmp / "published"
        stage.mkdir()
        for key in selected:
            record = doc["shaders"][key]
            source = (sources / (key + ".metal")).read_bytes()
            base = (libraries / (key + ".metallib")).read_bytes()
            if digest(source) != record["source_sha256"] or digest(base) != record["library_sha256"]:
                raise ValueError(f"Source or base library hash mismatch for {key}")
            needle = b"[[point_size]]"
            if needle not in source:
                raise ValueError(f"No point-size output for {key}")
            effective = source.replace(needle, b"[[user(dm_unused_point_size)]]")
            msl, air, lib = tmp / (key + ".metal"), tmp / (key + ".air"), stage / (key + ".metallib")
            msl.write_bytes(effective)
            subprocess.run(["xcrun", "-sdk", "iphoneos", "metal", *flags,
                            f"-fmodules-cache-path={tmp / 'modules'}", "-c", msl, "-o", air], check=True)
            subprocess.run(["xcrun", "-sdk", "iphoneos", "metallib", air, "-o", lib], check=True)
            data = lib.read_bytes()
            if not data.startswith(b"MTLB"):
                raise ValueError(f"Invalid metallib for {key}")
            records[key] = {**record, "effective_source_sha256": digest(effective),
                            "offline_sha256": digest(data)}
            msl.unlink()
            air.unlink()
        (stage / "manifest.json").write_text(
            json.dumps({"schema": 1, "chain": chain, "shaders": records}, sort_keys=True) + "\n"
        )
        stage.rename(output)
    return len(records)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True, help="Exported non-point source directory")
    parser.add_argument("--manifest", type=Path, help="Defaults to the source directory's manifest.json")
    parser.add_argument("--libraries", type=Path, required=True, help="Exact b-<chain> directory")
    parser.add_argument("--keys", type=Path, required=True, help="Whitespace-separated vertex shader keys")
    parser.add_argument("--output", type=Path, required=True, help="New nonpoint-metal3-v1 directory")
    args = parser.parse_args()
    try:
        count = build(args.sources, args.manifest or args.sources / "manifest.json",
                      args.libraries, args.keys, args.output)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(f"Built {count} Metal 3 non-point variants")
