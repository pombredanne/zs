# This file is part of ZSS
# Copyright (C) 2013-2014 Nathaniel Smith <njs@pobox.com>
# See file LICENSE.txt for license information.

#!/usr/bin/env python

import os
import shutil
from six import BytesIO, int2byte, byte2int
import zss
from zss.common import *
from zss.writer import _encode_header
from zss._zss import write_uleb128

shutil.copy("../letters-none.zss", "partial-root.zss")
with open("partial-root.zss", "r+b") as f:
    os.ftruncate(f.fileno(),
                 os.stat("partial-root.zss").st_size - 1)

shutil.copy("../letters-none.zss", "bad-magic.zss")
open("bad-magic.zss", "r+b").write(b"Q")

shutil.copy("../letters-none.zss", "incomplete-magic.zss")
open("incomplete-magic.zss", "r+b").write(INCOMPLETE_MAGIC)

shutil.copy("../letters-none.zss", "header-checksum.zss")
with open("header-checksum.zss", "r+b") as f:
    # 28 bytes places us at the beginning of the uuid field, so semantically a
    # bunch of zeros are totally legal here.
    f.seek(28)
    f.write(b"\x00" * 8)

shutil.copy("../letters-none.zss", "root-checksum.zss")
with open("root-checksum.zss", "r+b") as f:
    f.seek(-4, 2)
    f.write(b"\x00" * 4)

# partial length marker
shutil.copy("../letters-none.zss", "truncated-data-1.zss")
with open("truncated-data-1.zss", "ab") as f:
    f.write(b"\x80")

# partial block contents
shutil.copy("../letters-none.zss", "truncated-data-2.zss")
with open("truncated-data-2.zss", "ab") as f:
    f.write(b"\x08" + b"\x00" * 7)

# partial trailing checksum
shutil.copy("../letters-none.zss", "truncated-data-3.zss")
with open("truncated-data-3.zss", "ab") as f:
    f.write(b"\x08" + b"\x00" * 8 + b"\x01" * 3)

def _pack_index_records_unchecked(contents):
    f = BytesIO()
    for key, offset, length in zip(*contents):
        key = key.encode("ascii")
        write_uleb128(len(key), f)
        f.write(key)
        write_uleb128(offset, f)
        write_uleb128(length, f)
    return f.getvalue()

def _pack_data_records_unchecked(contents):
    f = BytesIO()
    for record in contents:
        record = record.encode("ascii")
        write_uleb128(len(record), f)
        f.write(record)
    return f.getvalue()

class SimpleWriter(object):
    def __init__(self, p, metadata={}, codec_name="none"):
        self.f = open(p, "w+b")

        self.f.write(INCOMPLETE_MAGIC)
        self._header = {
            "root_index_offset": 2 ** 63 - 1,
            "root_index_length": 0,
            "uuid": b"\x00" * 16,
            "compression": codec_name,
            "metadata": metadata,
            }
        encoded_header = _encode_header(self._header)
        self._header_length = len(encoded_header)
        self.f.write(struct.pack(header_data_length_format,
                                 len(encoded_header)))
        self._header_offset = self.f.tell()
        self.f.write(encoded_header)
        self.f.write(encoded_crc32c(encoded_header))
        self._have_root = False

    def raw_block(self, block_level, zdata):
        self.f.seek(0, 2)
        offset = self.f.tell()
        contents = int2byte(block_level) + zdata
        write_uleb128(len(contents), self.f)
        self.f.write(contents)
        self.f.write(encoded_crc32c(contents))
        block_length = self.f.tell() - offset
        return offset, block_length

    def data_block(self, records):
        zdata = _pack_data_records_unchecked(records)
        return self.raw_block(0, zdata)

    def index_block(self, block_level, records, offsets, block_lengths):
        zdata = _pack_index_records_unchecked([records, offsets, block_lengths])
        return self.raw_block(block_level, zdata)

    def root_block(self, *args, **kwargs):
        root_offset, root_length = self.index_block(*args, **kwargs)
        self.set_root(root_offset, root_length)
        return root_offset, root_length

    def set_root(self, root_offset, root_length):
        self._header["root_index_offset"] = root_offset
        self._header["root_index_length"] = root_length
        encoded_header = _encode_header(self._header)
        assert len(encoded_header) == self._header_length
        self.f.seek(self._header_offset)
        self.f.write(encoded_header)
        self.f.write(encoded_crc32c(encoded_header))
        self.f.seek(0)
        self.f.write(MAGIC)
        self.f.flush()
        self._have_root = True

    def close(self):
        assert self._have_root
        self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, exc_traceback):
        if exc_type is None:
            self.close()

with SimpleWriter("bad-data-order.zss") as w:
    offset, length = w.data_block(["z", "a"])
    w.root_block(1, ["z"], [offset], [length])

with SimpleWriter("wrong-root-level-1.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    w.root_block(2, ["a", "c"], [o1, o2], [l1, l2])

with SimpleWriter("wrong-root-level-2.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    io, il = w.index_block(1, ["a", "c"], [o1, o2], [l1, l2])
    w.root_block(3, ["a"], [io], [il])

with SimpleWriter("bad-ref-length.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    w.root_block(1, ["a", "c"], [o1, o2], [l1 + 1, l2])

# index key must be <= first entry in referenced block
with SimpleWriter("bad-index-key-1.zss") as w:
    o1, l1 = w.data_block(["a", "c"])
    w.root_block(1, ["b"], [o1], [l1])

# but this doesn't have to be exact
with SimpleWriter("good-index-key-1.zss") as w:
    o1, l1 = w.data_block(["b", "c"])
    w.root_block(1, ["a"], [o1], [l1])

# index key must be >= last entry in block-before-referenced-block
with SimpleWriter("bad-index-key-2.zss") as w:
    o1, l1 = w.data_block(["a", "c"])
    o2, l2 = w.data_block(["e", "g"])
    w.root_block(1, ["a", "b"], [o1, o2], [l1, l2])

with SimpleWriter("good-index-key-2.zss") as w:
    o1, l1 = w.data_block(["a", "c"])
    o2, l2 = w.data_block(["e", "g"])
    w.root_block(1, ["a", "c"], [o1, o2], [l1, l2])

# for references to index blocks, these invariants must be maintained for the
# underlying *data* blocks, not just the keys in the index blocks themselves
with SimpleWriter("bad-index-key-3.zss") as w:
    o1, l1 = w.data_block(["a", "c"])
    o2, l2 = w.data_block(["e", "g"])
    io1, il1 = w.index_block(1, ["a", "e"], [o1, o2], [l1, l2])
    o3, l3 = w.data_block(["i", "k"])
    o4, l4 = w.data_block(["m", "o"])
    io2, il2 = w.index_block(1, ["i", "m"], [o3, o4], [l3, l4])
    # the index blocks this refers to have keys [a, e], [i, m]
    # so the "f" falls in between them.
    # But it *doesn't* fall before the "g" that's in the 2nd data block that
    # the first index block points to.
    w.root_block(2, ["a", "f"], [io1, io2], [il1, il2])

with SimpleWriter("good-index-key-3.zss") as w:
    o1, l1 = w.data_block(["a", "c"])
    o2, l2 = w.data_block(["e", "g"])
    io1, il1 = w.index_block(1, ["a", "e"], [o1, o2], [l1, l2])
    o3, l3 = w.data_block(["i", "k"])
    o4, l4 = w.data_block(["m", "o"])
    io2, il2 = w.index_block(1, ["i", "m"], [o3, o4], [l3, l4])
    w.root_block(2, ["a", "g"], [io1, io2], [il1, il2])

with SimpleWriter("bad-index-order.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    w.root_block(1, ["c", "a"], [o2, o1], [l2, l1])

with SimpleWriter("wrong-root-length.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    ro, rl = w.index_block(1, ["a", "c"], [o1, o2], [l1, l2])
    w.set_root(ro, rl + 1)
    # And we also add another block at the end so that the wrong length
    # doesn't just immediately result in a short-read
    w.data_block(["w", "x"])

with SimpleWriter("wrong-root-offset.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    ro, rl = w.index_block(1, ["a", "c"], [o1, o2], [l1, l2])
    w.set_root(ro + 1, rl)
    w.data_block(["w", "x"])

# unreferenced trailing index block -- it just references the former root, so
# really it is the root. but the header still points to the old root, so this
# is just unreferenced.
with SimpleWriter("unref-index.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    ro, rl = w.root_block(1, ["a", "c"], [o1, o2], [l1, l2])
    w.index_block(2, ["a"], [ro], [rl])

# Two copies of the index block at the end. In addition to being an
# unreferenced block, this creates a bunch of double-references to previous
# blocks.
with SimpleWriter("repeated-index.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    w.root_block(1, ["a", "c"], [o1, o2], [l1, l2])
    w.index_block(1, ["a", "c"], [o1, o2], [l1, l2])

with SimpleWriter("unref-data.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    o2, l2 = w.data_block(["c", "d"])
    w.root_block(1, ["a"], [o1], [l1])

with SimpleWriter("non-dict-metadata.zss", metadata="hi!") as w:
    o1, l1 = w.data_block(["a", "b"])
    w.root_block(1, ["a"], [o1], [l1])

with SimpleWriter("root-is-data.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    w.set_root(o1, l1)

with SimpleWriter("bad-codec.zss", codec_name="XXX-bad-codec-XXX") as w:
    o1, l1 = w.data_block(["a", "b"])
    w.root_block(1, ["a"], [o1], [l1])

# cut off in the middle of a record
with SimpleWriter("partial-data-1.zss") as w:
    o1, l1 = w.raw_block(0, b"\x01a\x02b")
    w.root_block(1, ["a"], [o1], [l1])

# cut off in the middle of a uleb128
with SimpleWriter("partial-data-2.zss") as w:
    o1, l1 = w.raw_block(0, b"\x01a\x80")
    w.root_block(1, ["a"], [o1], [l1])

# simply empty
with SimpleWriter("empty-data.zss") as w:
    o1, l1 = w.raw_block(0, b"")
    w.root_block(1, [""], [o1], [l1])

with SimpleWriter("partial-index-1.zss") as w:
    o1, l1 = w.data_block(["a", "b"])
    assert o1 < 128
    assert l1 < 128
    zdata = b"\x01a" + int2byte(o1) + int2byte(l1)
    w.set_root(*w.raw_block(1, zdata[:-1]))
with SimpleWriter("partial-index-2.zss") as w:
    assert w.data_block(["a", "b"]) == (o1, l1)
    w.set_root(*w.raw_block(1, zdata[:-2]))
with SimpleWriter("partial-index-3.zss") as w:
    assert w.data_block(["a", "b"]) == (o1, l1)
    w.set_root(*w.raw_block(1, zdata[:-3]))
with SimpleWriter("partial-index-4.zss") as w:
    assert w.data_block(["a", "b"]) == (o1, l1)
    w.set_root(*w.raw_block(1, b"0x80"))
with SimpleWriter("empty-index.zss") as w:
    w.data_block(["a", "b"])
    w.set_root(*w.raw_block(1, b""))