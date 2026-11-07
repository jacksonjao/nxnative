"""Synthetic REDengine cache frames, including GLSLC across FZLC chunks."""
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'gfx/tools'))
import redshader
if __package__:
    from .test_unity_text_glslc import glslc_output, ss
else:
    from test_unity_text_glslc import glslc_output, ss


def container(parts, reserve=4):
    blocks = [ss.zstd_mod().compress(p) for p in parts]
    offset = 8 + reserve * 12
    table = bytearray(reserve * 12)
    for i, (part, block) in enumerate(zip(parts, blocks)):
        struct.pack_into('<III', table, i * 12, offset, len(block), len(part))
        offset += len(block)
    return b'FZLC' + struct.pack('<I', len(parts)) + table + b''.join(blocks)


def record(raw):
    block = ss.zstd_mod().compress(raw)
    return struct.pack('<QBII', 12345, 1, len(raw), len(block)) + block


class RedCache(unittest.TestCase):
    def test_cross_chunk_glslc_reaches_real_file_scanner(self):
        raw = glslc_output()
        data = container([raw[:0x400], raw[0x400:]])
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'arbitrary-name.cache'
            path.write_bytes(data)
            result = ss.scan_file((str(path), path.name))
        self.assertEqual(len(result[1]), 1)
        self.assertEqual(next(iter(result[1].values()))[1], 'vs')

    def test_hash_records_and_lookup_tail(self):
        raw = glslc_output()
        data = record(raw) + record(raw) + bytes(32)
        self.assertEqual([r for _, r in redshader.records(data, ss.zstd_mod())], [raw, raw])
        out = []
        ss.scan_blob(data, '/shadernx.cache', out)
        self.assertEqual(len(out), 2)

    def test_fzlc_bad_count_padding_ranges_and_lengths(self):
        good = container([glslc_output()])
        changes = [(4, '<I', 0), (8, '<I', 7), (12, '<I', len(good)), (16, '<I', 1), (16, '<I', (1 << 20) + 1)]
        for offset, form, value in changes:
            with self.subTest(offset=offset, value=value):
                data = bytearray(good); struct.pack_into(form, data, offset, value)
                with self.assertRaises((ValueError, ss.zstd_mod().ZstdError)):
                    redshader.fzlc(data, ss.zstd_mod())
        data = bytearray(good); data[20] = 1
        with self.assertRaises(ValueError): redshader.fzlc(data, ss.zstd_mod())
        with self.assertRaises(ValueError): redshader.fzlc(good + b'x', ss.zstd_mod())

    def test_record_bounds_codec_and_exact_frame(self):
        good = record(glslc_output())
        for offset, value in ((8, 2), (9, 1), (13, len(good))):
            data = bytearray(good)
            struct.pack_into('<B' if offset == 8 else '<I', data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                redshader.records(data, ss.zstd_mod())

    def test_non_cache_is_not_selected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'ordinary'; p.write_bytes(b'ordinary data')
            self.assertEqual(ss.scan_file((str(p), p.name))[1], {})


if __name__ == '__main__': unittest.main()
