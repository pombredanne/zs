# This file is part of ZSS
# Copyright (C) 2013-2014 Nathaniel Smith <njs@pobox.com>
# See file LICENSE.txt for license information.

from contextlib import contextmanager
import math

from six import BytesIO
from nose.tools import assert_raises

from zss import ZSS, ZSSWriter, ZSSError
from zss.common import write_length_prefixed
from .util import tempname

# some of these helpers also used in test_cmdline to test 'make'

# Each of these records is 25 bytes long
records = []
# just in case of bugs, let's make sure to have an empty record
records.append(b"")
for i in xrange(1000):
    records.append((u"THIS IS RECORD # %08i" % (i,)).encode("utf-8"))
# and a duplicate record
records.append(b"ZZZ THIS RECORD IS REPEATED")
records.append(b"ZZZ THIS RECORD IS REPEATED")

def ok_zss(p):
    z = ZSS(p)
    z.validate()
    return z

def temp_zss_path():
    return tempname(".zss", unlink_first=True)

@contextmanager
def temp_writer(**kwargs):
    with temp_zss_path() as p:
        kwargs.setdefault("metadata", {})
        kwargs.setdefault("branching_factor", 2)
        with ZSSWriter(p, **kwargs) as zw:
            yield (p, zw)

def identity(x):
    return x

def test_add_data_block():
    with temp_writer() as (p, zw):
        zw.add_data_block([b"a", b"b"])
        zw.add_data_block([b"c", b"z"])
        zw.finish()

        with ok_zss(p) as z:
            z.validate()
            assert list(z.block_map(identity)) == [[b"a", b"b"],
                                                   [b"c", b"z"]]

def test_write_add_file_contents_terminator():
    for terminator in [b"\n", b"\x00", b"\r\n"]:
        f = BytesIO(terminator.join(records) + terminator)
        with temp_writer() as (p, zw):
            kwargs = {}
            if terminator != b"\n":
                kwargs["terminator"] = terminator
            # approximately 4 records per data block
            zw.add_file_contents(f, 100, **kwargs)
            zw.finish()

            with ok_zss(p) as z:
                assert list(z) == records
                assert len(list(z.block_map(identity))) > len(records) / 5.0

def test_write_add_file_contents_length_prefixed():
    for mode in ["uleb128", "u64le"]:
        f = BytesIO()
        write_length_prefixed(f, records, mode)
        with temp_writer() as (p, zw):
            # approximately 4 records per data block
            zw.add_file_contents(BytesIO(f.getvalue()), 100,
                                         length_prefixed=mode)
            zw.finish()

            with ok_zss(p) as z:
                assert list(z) == records
                assert len(list(z.block_map(identity))) > len(records) / 5.0

def test_write_mixed():
    with temp_writer() as (p, zw):
        zw.add_data_block([b"a", b"b"])
        f = BytesIO(b"c\nd\n")
        zw.add_file_contents(f, 10)
        zw.add_data_block([b"e", b"f"])
        f = BytesIO(b"\x01g\x01h")
        zw.add_file_contents(f, 10, length_prefixed="uleb128")
        zw.finish()

        with ok_zss(p) as z:
            assert list(z) == [b"a", b"b", b"c", b"d", b"e", b"f", b"g", b"h"]

def test_writer_args():
    with temp_zss_path() as p:
        zw = ZSSWriter(p, {"a": 1}, 2, parallelism=2, codec="deflate",
                       codec_kwargs={"compress_level": 3},
                       show_spinner=False, include_default_metadata=False)
        try:
            zw.add_data_block([b"a", b"b"])
            zw.add_data_block([b"c", b"d"])
            zw.finish()
        finally:
            zw.close()

        with ok_zss(p) as z:
            assert z.metadata == {"a": 1}
            assert z.codec == "deflate"

def test_no_overwrite():
    with temp_zss_path() as p:
        f = open(p, "wb")
        f.write("hi\n")
        f.close()

        assert_raises(ZSSError, ZSSWriter, p, {}, 2)

def test_bad_codec():
    with temp_zss_path() as p:
        assert_raises(ZSSError, ZSSWriter, p, {}, 2, codec="SUPERZIP")

def test_trailing_record():
    with temp_writer() as (p, zw):
        assert_raises(ZSSError, zw.add_file_contents,
                      BytesIO(b"a\nb\nc"), 2)

def test_from_file_terminator_long_record():
    with temp_writer() as (p, zw):
        # individual records longer than the approx_block_size
        records = [b"a" * 100, b"b" * 100]
        f = BytesIO(b"\n".join(records + [b""]))
        zw.add_file_contents(f, 10)
        zw.finish()

        with ok_zss(p) as z:
            assert list(z) == records

def test_from_file_length_prefixed_exactly_one_block():
    with temp_writer() as (p, zw):
        zw.add_file_contents(BytesIO(b"\x08aaaaaaaa\x04bbbb"), 10,
                             length_prefixed="uleb128")
        zw.finish()

        with ok_zss(p) as z:
            assert list(z) == [b"a" * 8, b"b" * 4]

def test_closed_is_closed():
    with temp_writer() as (_, zw):
        zw.close()
        assert_raises(ZSSError, zw.add_file_contents, BytesIO(b""), 100)
        assert_raises(ZSSError, zw.add_data_block, [b""])
        assert_raises(ZSSError, zw.finish)

def test_empty():
    with temp_writer() as (_, zw):
        assert_raises(ZSSError, zw.finish)

# empty blocks are silently dropped instead of being added
def test_no_empty_blocks():
    with temp_writer() as (p, zw):
        zw.add_data_block([b"a", b"b"])
        zw.add_data_block([])
        zw.add_file_contents(BytesIO(), 100)
        zw.add_data_block([b"c", b"d"])
        zw.finish()

        # the implicit call to z.validate() here should error out if there are
        # any empty blocks, but let's check anyway.
        with ok_zss(p) as z:
            assert len(list(z.block_map(identity))) == 2

def test_unsorted():
    with temp_writer() as (_, zw):
        with assert_raises(ZSSError):
            zw.add_file_contents(BytesIO(b"b\na\n"), 100)
            zw.finish()
        assert zw.closed

    with temp_writer() as (_, zw):
        with assert_raises(ZSSError):
            zw.add_data_block([b"b", b"a"])
            zw.finish()
        assert zw.closed

    with temp_writer() as (_, zw):
        with assert_raises(ZSSError):
            zw.add_data_block([b"m", b"n"])
            zw.add_data_block([b"a", b"b"])
            zw.finish()
        assert zw.closed

def test_lengths():
    # exercise all the corner cases in the index packing code
    for num_blocks in xrange(1, 2 ** 5):
        for branching_factor in [2, 3]:
            block_tmpls = [(u"%04i" % (i,)).encode("utf-8")
                           for i in xrange(num_blocks)]
            records = []
            with temp_writer(branching_factor=branching_factor) as (p, zw):
                for block_tmpl in block_tmpls:
                    block = [block_tmpl + suffix
                             for suffix in [b"a", b"b", b"c"]]
                    zw.add_data_block(block)
                    records += block
                zw.finish()

                with ok_zss(p) as z:
                    assert list(z) == records
                    assert (max(math.ceil(math.log(num_blocks)
                                          / math.log(branching_factor)),
                                1)
                            == z.root_index_level)

def test_clogged_queue():
    # Failure to sort across blocks causes an error in the write worker, which
    # then stops consuming from its queue. But we don't see it immediately,
    # because the main process doesn't regularly check for errors. Eventually
    # this causes the whole pipeline to stall. This tests that the main
    # process eventually checks for errors under these conditions.
    with temp_writer() as (p, zw):
        zw.add_data_block([b"z"])
        with assert_raises(ZSSError):
            while True:
                zw.add_data_block([b"a"])
