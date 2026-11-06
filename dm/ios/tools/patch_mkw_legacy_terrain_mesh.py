"""Build the two verified Mario Kart World terrain mesh variants for iOS Metal 3.

Inputs are generated MSL and reflection from the existing, local shader build.
The exact source digests keep this repair away from other games and revisions.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


VARIANTS = {
    "0f972afb8a9dbd9a_b": (
        "232401b587386f29fe6d783e5cd0eeb49f42fb925f52afd23ecdfdbb1764f468", 0, 4,
    ),
    "11ed01f0618a65a3_b": (
        "5d308fd2d89c9957bf9f7293b8a69f2e1220702f28ac100c88c7ee4836e1d9df", 1, 12,
    ),
}
RECIPE = "mkw-isolated-terrain-raw-storage-pointer-v1"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def transform(source, metadata, key):
    expected, slot, count = VARIANTS[key]
    if (sha(source) != expected or metadata["key"] != key or metadata["stage"] != "ms"
            or metadata["composite_provenance"]["source_sha256"] != expected):
        raise ValueError(f"{key}: unexpected terrain shader provenance")
    bindings = metadata["bindings"]
    storage = bindings[3] if len(bindings) == 4 else {}
    if ([b["reg"] for b in bindings] != [0, 2, 1, slot]
            or (storage.get("kind"), storage.get("arg_id"), storage.get("msl_type"))
            != ("sbuf", 3, "const device _27*")):
        raise ValueError(f"{key}: unexpected terrain storage binding")
    source = source.decode()
    if source.count("const device _27* cp_s0") != 1:
        raise ValueError(f"{key}: missing one-element storage declaration")
    source = source.replace("const device _27* cp_s0", "const device uint* cp_s0")
    source, changed = re.subn(
        r"\(\*spvDescriptorSet0\.cp_s0\)\._m0\[int\((_[0-9]+)\)\]",
        r"spvDescriptorSet0.cp_s0[\1]", source,
    )
    if changed != count:
        raise ValueError(f"{key}: expected {count} accesses, found {changed}")
    return source


def build(input_dir, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)
    names = [key + ext for key in VARIANTS for ext in (".json", ".metallib")]
    if any((output_dir / name).exists() or (output_dir / name).is_symlink() for name in names):
        raise FileExistsError("Use an empty output directory; originals are never replaced")
    with tempfile.TemporaryDirectory(dir=output_dir) as stage_name:
        stage = Path(stage_name)
        for key in VARIANTS:
            metadata = json.loads((input_dir / (key + ".json")).read_bytes())
            source = transform((input_dir / (key + ".metal")).read_bytes(), metadata, key)
            msl, air, lib = (stage / (key + ext) for ext in (".metal", ".air", ".metallib"))
            msl.write_text(source)
            subprocess.run([
                "xcrun", "-sdk", "iphoneos", "metal", "-target", "air64-apple-ios16.1",
                "-std=metal3.0", "-fpreserve-invariance", "-fmetal-math-mode=relaxed",
                "-fmodules-cache-path=" + str(stage / "module-cache"), "-c", msl, "-o", air,
            ], check=True)
            subprocess.run(["xcrun", "-sdk", "iphoneos", "metallib", air, "-o", lib], check=True)
            raw = lib.read_bytes()
            if not raw.startswith(b"MTLB"):
                raise ValueError(f"{key}: invalid Metal library")
            provenance = metadata["composite_provenance"]
            parent = provenance["library_sha256"]
            provenance.update(source_sha256=sha(msl.read_bytes()), library_sha256=sha(raw),
                              parent_library_sha256=parent, recipe=RECIPE)
            metadata["bindings"][3]["msl_type"] = "const device uint*"
            (stage / (key + ".json")).write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        for name in names:
            (stage / name).rename(output_dir / name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Directory with the two original .metal/.json pairs")
    parser.add_argument("output", type=Path, help="New directory for repaired Metal 3 libraries")
    args = parser.parse_args()
    build(args.input, args.output)
