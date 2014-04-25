# This file is part of ZS
# Copyright (C) 2013-2014 Nathaniel Smith <njs@pobox.com>
# See file LICENSE.txt for license information.

from __future__ import absolute_import

from libc.stddef cimport size_t
from libc.stdint cimport uint8_t, uint32_t, uint64_t
from libc.stdlib cimport malloc, free, realloc
from libc.string cimport memcpy
from cpython.ref cimport PyObject
from cpython.bytes cimport PyBytes_AsStringAndSize, PyBytes_FromStringAndSize

import six

import zs

# These files were generated by pycrc32 0.8.1, as:
#   python pycrc.py --model crc-64-xz --algorithm table-driven --symbol-prefix pycrc_crc64xz_ --generate h -o pycrc-crc64xz.h
#   python pycrc.py --model crc-64-xz --algorithm table-driven --symbol-prefix pycrc_crc64xz_ --generate c -o pycrc-crc64xz.c
# If for some reason this turns out to be too slow, then there's a wicked fast
# version in liblzma (public domain, x86 asm or slice-by-4, accessible by
# calling lzma_crc64). It's ~3x faster in my tests, but harder to steal than
# just dropping these two files here...
cdef extern from "pycrc-crc64xz.h":
    ctypedef uint64_t pycrc_crc64xz_t
    pycrc_crc64xz_t pycrc_crc64xz_init()
    pycrc_crc64xz_t pycrc_crc64xz_update(pycrc_crc64xz_t crc,
                                         uint8_t *data,
                                         size_t data_len)
    pycrc_crc64xz_t pycrc_crc64xz_finalize(pycrc_crc64xz_t crc)
# To save on compilation hassles, we just #include the code in here directly.
cdef extern from "pycrc-crc64xz.c":
    pass

# We use uint64's internally, and this should be enough for anyone. So don't
# bother supporting uleb128's that are larger than this. That means that the
# longest possible uleb128 is 10 bytes, because 64 / 7 = 9.1.
DEF _MAX_ULEB128_LENGTH = 10
MAX_ULEB128_LENGTH = _MAX_ULEB128_LENGTH

def crc64xz(data):
   cdef uint8_t * c_data
   cdef Py_ssize_t length
   PyBytes_AsStringAndSize(data, <char **> &c_data, &length)
   cdef pycrc_crc64xz_t result = pycrc_crc64xz_init()
   result = pycrc_crc64xz_update(result, c_data, length)
   return pycrc_crc64xz_finalize(result) & 0xffffffffffffffff

################################################################

cdef int buf_write_uleb128(uint64_t value, uint8_t * buffer):
    cdef int written = 0
    cdef uint8_t byte
    while True:
        byte = (value & 0x7f)
        value >>= 7
        if value:
            byte |= 0x80
        buffer[written] = byte
        written += 1
        if not value:
            break
    return written

def cython_test_buf_write_uleb128():
   cdef uint8_t buf[_MAX_ULEB128_LENGTH]
   for (value, expected) in [(0, b"\x00"),
                             (0x10, b"\x10"),
                             (0x81, b"\x81\x01"),
                             (0x7f, b"\x7f"),
                             (0x107f, b"\xff\x20"),
                             (1 << 43, b"\x80\x80\x80\x80\x80\x80\x02"),
                             ]:
      print("--- start %s ---" % (value,))
      assert buf_write_uleb128(value, buf) == len(expected)
      for i in range(len(expected)):
         print(six.indexbytes(expected, i), buf[i])
         assert six.indexbytes(expected, i) == buf[i]
      print("--- end %s ---" % (value,))

def write_uleb128(value, f):
   cdef uint8_t buf[_MAX_ULEB128_LENGTH]
   cdef int written
   written = buf_write_uleb128(value, buf)
   assert written <= _MAX_ULEB128_LENGTH
   data = PyBytes_FromStringAndSize(<char *> buf, written)
   f.write(data)

cdef uint64_t buf_read_uleb128(uint8_t * buf, size_t buf_len, size_t * offset) except? 0:
    cdef uint64_t value = 0
    cdef int shift = 0
    cdef uint8_t byte
    while True:
        if offset[0] >= buf_len:
            raise zs.ZSCorrupt("hit end of buffer while decoding uleb128")
        byte = buf[offset[0]]
        offset[0] += 1
        if shift + 7 > 64:
            raise zs.ZSCorrupt("uleb128 integer overflowed uint64")
        value |= (<uint64_t>(byte & 0x7f)) << shift
        if not (byte & 0x80):
            # An all-zeros byte means that we have encoded this value into a
            # longer-than-necessary string -- unless the value actually is
            # zero and this is the first byte.
            if not byte and shift > 0:
                raise zs.ZSCorrupt("unnormalized uleb128")
            return value
        shift += 7

def cython_test_buf_read_uleb128():
    from binascii import hexlify
    cdef uint8_t * buf
    cdef size_t offset
    for (string, integer, length) in [(b"\x00", 0, 1),
                                      (b"\x10\x10", 0x10, 1),
                                      (b"\x81\x01", 0x81, 2),
                                      (b"\x7f", 0x7f, 1),
                                      (b"\xff\x20", 0x107f, 2),
                                      (b"\x80\x80\x80\x80\x80\x80\x02",
                                       1 << 43, 7),
                              ]:
        for prefix in [b"", b"asdf"]:
            for suffix in [b"", b"fdsa"]:
                # Need to stash this into a python variable to hold the
                # memory before casting to char*
                buf_handle = prefix + string + suffix
                buf = buf_handle
                offset = len(prefix)
                print "want: %s[%s:] -> %s (%s)" % (hexlify(buf_handle),
                                                    offset,
                                                    hex(integer),
                                                    length)
                got = buf_read_uleb128(buf, len(buf_handle), &offset)
                print "got %s (%s)" % (hex(got), offset)
                assert got == integer
                assert offset == len(prefix) + length
    buf = b"\x80\x80"
    offset = 0
    try:
        buf_read_uleb128(buf, 2, &offset)
    except zs.ZSCorrupt:
        pass
    else:
        assert False, "buf_read_uleb128 overran end of buf"
    # This is 2**64, which is 1 larger than the largest uint64 value.
    buf = b"\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02"
    offset = 0
    try:
        buf_read_uleb128(buf, len(buf), &offset)
    except zs.ZSCorrupt:
        pass
    else:
        assert False, "buf_read_uleb128 failed to catch integer overflow"
    # This is the value 1, encoded into two bytes.
    buf = b"\x81\x00"
    offset = 0
    try:
        buf_read_uleb128(buf, len(buf), &offset)
    except zs.ZSCorrupt:
        pass
    else:
        assert False, "buf_read_uleb128 failed to catch unnormalized encoding"

def read_uleb128(f):
   """Read a uleb128 from file-like object 'f'.

   Returns value, or else None if 'f' is at EOF."""
   cdef uint8_t buf[_MAX_ULEB128_LENGTH]
   cdef size_t written = 0
   cdef size_t read = 0
   cdef uint64_t value
   cdef bytes byte
   cdef uint8_t * byte_p
   while True:
      byte = f.read(1)
      if not byte:
         if written == 0:
            return None
         else:
            raise zs.ZSCorrupt("unexpectedly ran out of data while "
                                 "reading uleb128")
      byte_p = byte
      buf[written] = byte_p[0]
      written += 1
      if not buf[written - 1] & 0x80:
         break
   value = buf_read_uleb128(buf, _MAX_ULEB128_LENGTH, &read)
   assert read == written
   return value

################################################################

def pack_data_records(list records, size_t alloc_hint=65536):
    return _pack_records(records, None, None, alloc_hint)

def pack_index_records(list records, list offsets, list lengths,
                       size_t alloc_hint=65536):
    return _pack_records(records, offsets, lengths, alloc_hint)

cdef bytes _pack_records(list records,
                         list offsets,
                         list block_lengths,
                         size_t alloc_hint):
    if offsets is not None:
        if len(records) != len(offsets):
            raise ValueError("len(records) == %s, len(offsets) == %s"
                             % (len(records), len(offsets)))
        if len(records) != len(block_lengths):
            raise ValueError("len(records) == %s, len(block_lengths) == %s"
                             % (len(records), len(block_lengths)))
    cdef size_t written = 0
    cdef size_t bufsize = alloc_hint
    cdef size_t new_bufsize
    cdef int n_records = len(records)
    cdef int i = 0
    cdef char * c_data
    cdef Py_ssize_t c_length
    cdef uint8_t * buf
    if bufsize == 0:
        bufsize = 1
    buf = <uint8_t *>malloc(bufsize)
    try:
        for i in range(n_records):
            PyBytes_AsStringAndSize(records[i],
                                    &c_data, &c_length)
            if i > 0:
                if records[i - 1] > records[i]:
                    raise zs.ZSError("records are not sorted: %r > %r"
                                       % (records[i - 1], records[i]))
            new_bufsize = bufsize
            while (new_bufsize - written) < (3 * _MAX_ULEB128_LENGTH
                                             + c_length
                                             # in case of off-by-one errors:
                                             + 10):
                new_bufsize *= 2
            if new_bufsize != bufsize:
                buf = <uint8_t *>realloc(buf, new_bufsize)
                bufsize = new_bufsize
            written += buf_write_uleb128(c_length, buf + written)
            memcpy(buf + written, c_data, c_length)
            written += c_length
            if offsets is not None:
                written += buf_write_uleb128(offsets[i], buf + written)
                if i > 0:
                    if offsets[i - 1] >= offsets[i]:
                        raise zs.ZSError("blocks are not sorted: offset %s "
                                           "comes after %s"
                                           % (offsets[i], offsets[i - 1]))
                written += buf_write_uleb128(block_lengths[i], buf + written)
            previous_c_data = c_data
            previous_c_length = c_length
        return PyBytes_FromStringAndSize(<char *>buf, written)
    finally:
        free(buf)

################################################################

def unpack_data_records(bytes data_block):
    return _unpack_records(False, data_block)[0]

def unpack_index_records(bytes index_block):
    return _unpack_records(True, index_block)

cdef tuple _unpack_records(bint is_index, bytes block):
    cdef uint8_t * buf
    cdef Py_ssize_t buf_len
    PyBytes_AsStringAndSize(block, <char **> &buf, &buf_len)
    cdef size_t buf_offset = 0
    cdef uint64_t record_length, offset, block_length
    cdef list records = []
    cdef list offsets = None
    cdef list block_lengths = None
    if is_index:
        offsets = []
        block_lengths = []
    while buf_offset < buf_len:
        record_length = buf_read_uleb128(buf, buf_len, &buf_offset)
        if buf_offset + record_length > buf_len:
            raise zs.ZSCorrupt("record extends past end of block "
                                 "(%s bytes remaining in block, "
                                 "%s bytes in record)"
                                 % (buf_len - buf_offset, record_length))
        records.append(PyBytes_FromStringAndSize(<char *>(buf + buf_offset),
                                                 record_length))
        buf_offset += record_length
        if is_index:
            offset = buf_read_uleb128(buf, buf_len, &buf_offset)
            offsets.append(offset)
            block_length = buf_read_uleb128(buf, buf_len, &buf_offset)
            block_lengths.append(block_length)
    assert buf_offset == buf_len
    if len(records) == 0:
       raise zs.ZSCorrupt("empty block")
    return records, offsets, block_lengths
