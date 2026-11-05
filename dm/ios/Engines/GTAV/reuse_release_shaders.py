"""Extract the exact iPhone Metal library from the matching owned release IPA."""
import argparse
import hashlib
from pathlib import Path
import shutil
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("ipa", type=Path)
parser.add_argument("upstream", type=Path)
args = parser.parse_args()
ipa = args.ipa
app = args.upstream / "app"
with ipa.open('rb') as f:
 if hashlib.file_digest(f,'sha256').hexdigest() != '42724954c1daff374919370a0db19976f7e5bf7bb073cb727bb2de06d4d12d34':
  parser.error('IPA does not match the original iOS v1.5.2 release')
leaves=('shaders-iphoneos.metallib','shader-reflection.jsonl')
out=app/'GeneratedResources';out.mkdir(exist_ok=True)
receipt={}
with zipfile.ZipFile(ipa) as z:
 for leaf in leaves:
  dest=out/leaf
  with z.open('Payload/PlayGTA5Native.app/'+leaf) as src,dest.open('xb') as dst:shutil.copyfileobj(src,dst)
  with dest.open('rb') as f:receipt[leaf]=dict(sha256=hashlib.file_digest(f,'sha256').hexdigest(),bytes=dest.stat().st_size)
assert (out/leaves[0]).open('rb').read(4)==b'MTLB'
for leaf, entry in receipt.items():
 print(entry['sha256'], entry['bytes'], leaf)
