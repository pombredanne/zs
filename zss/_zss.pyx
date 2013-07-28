from __future__ import absolute_import

from libc.stddef cimport size_t
from libc.stdint cimport uint8_t, uint32_t, uint64_t
from libc.stdlib cimport malloc, free, realloc
from libc.string cimport memcpy
from cpython.ref cimport PyObject
from cpython.bytes cimport (PyBytes_AsStringAndSize,
                            PyBytes_FromStringAndSize,
                            _PyBytes_Resize)

import zss

cdef extern from "pycrc-crc32c.h":
    ctypedef uint32_t pycrc_crc32c_t
    pycrc_crc32c_t pycrc_crc32c_init()
    pycrc_crc32c_t pycrc_crc32c_update(pycrc_crc32c_t crc,
                                       char *data,
                                       size_t data_len)
    pycrc_crc32c_t pycrc_crc32c_finalize(pycrc_crc32c_t crc)

# To save on compilation hassles, just dump the code in here directly.
cdef extern from "pycrc-crc32c.c":
    pass

# We use uint64's internally, and this should be enough for anyone. So don't
# bother supporting uleb128's that are larger than this. That means that the
# longest possible uleb128 is 10 bytes, because 64 / 7 = 9.1.
DEF _MAX_ULEB128_LENGTH = 10
MAX_ULEB128_LENGTH = _MAX_ULEB128_LENGTH

def crc32c(data):
   cdef char * c_data
   cdef Py_ssize_t length
   PyBytes_AsStringAndSize(data, &c_data, &length)
   cdef pycrc_crc32c_t result = pycrc_crc32c_init()
   result = pycrc_crc32c_update(result, c_data, length)
   return pycrc_crc32c_finalize(result) & 0xffffffff

################################################################

cdef int write_uleb128(uint64_t value, char * buffer):
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

def to_uleb128(uint64_t i):
    cdef char buffer[_MAX_ULEB128_LENGTH]
    cdef int written
    written = write_uleb128(i, buffer)
    assert written <= _MAX_ULEB128_LENGTH
    return PyBytes_FromStringAndSize(buffer, written)

cdef uint64_t read_uleb128(char * buf, size_t buf_len, size_t * offset) except? 0:
    cdef uint64_t value = 0
    cdef int shift = 0
    cdef uint8_t byte
    while True:
        if offset[0] >= buf_len:
            raise zss.ZSSCorrupt("hit end of buffer while decoding uleb128")
        byte = buf[offset[0]]
        offset[0] += 1
        if shift + 7 > 64:
            raise zss.ZSSCorrupt("uleb128 integer overflowed uint64")
        value |= (<uint64_t>(byte & 0x7f)) << shift
        if not (byte & 0x80):
            # An all-zeros byte means that we have encoded this value into a
            # longer-than-necessary string -- unless the value actually is
            # zero and this is the first byte.
            if not byte and shift > 0:
                raise zss.ZSSCorrupt("unnormalized uleb128")
            return value
        shift += 7

def from_uleb128(py_buf):
    """Returns (uleb128 value, number of bytes read).

    Making sure that the buffer contains enough bytes is your problem. Raises
    ZSSCorrupt if it doesn't."""
    cdef char * buf
    cdef Py_ssize_t buf_len
    cdef size_t offset
    PyBytes_AsStringAndSize(py_buf, &buf, &buf_len)
    offset = 0
    cdef uint64_t value = read_uleb128(buf, buf_len, &offset)
    return (value, offset)

def cython_test_read_uleb128():
    cdef char * buf
    cdef size_t offset
    for (string, integer, length) in [(b"\x00", 0, 1),
                                      (b"\x10\x10", 0x10, 1),
                                      (b"\x81\x01", 0x81, 2),
                                      (b"\x7f", 0x7f, 1),
                                      (b"\xff\x20", 0x107f, 2),
                                      (b"\x80\x80\x80\x80\x80\x80\x02",
                                       1 << 43, 7),
                              ]:
        for prefix in ["", "asdf"]:
            for suffix in ["", "fdsa"]:
                # Need to stash this into a python variable to hold the
                # memory before casting to char*
                buf_handle = prefix + string + suffix
                buf = buf_handle
                offset = len(prefix)
                print "want: %s[%s:] -> %s (%s)" % (buf_handle.encode("hex"),
                                                    offset,
                                                    hex(integer),
                                                    length)
                got = read_uleb128(buf, len(buf_handle), &offset)
                print "got %s (%s)" % (hex(got), offset)
                assert got == integer
                assert offset == len(prefix) + length
    buf = b"\x80\x80"
    offset = 0
    try:
        read_uleb128(buf, 2, &offset)
    except zss.ZSSCorrupt:
        pass
    else:
        assert False, "read_uleb128 overran end of buf"
    # This is 2**64, which is 1 larger than the largest uint64 value.
    buf = "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x02"
    offset = 0
    try:
        read_uleb128(buf, len(buf), &offset)
    except zss.ZSSCorrupt:
        pass
    else:
        assert False, "read_uleb128 failed to catch integer overflow"
    # This is the value 1, encoded into two bytes.
    buf = "\x81\x00"
    offset = 0
    try:
        read_uleb128(buf, len(buf), &offset)
    except zss.ZSSCorrupt:
        pass
    else:
        assert False, "read_uleb128 failed to catch unnormalized encoding"

################################################################

def pack_data_records(list records, size_t alloc_hint):
    return _pack_records(records, None, alloc_hint)

def pack_index_records(list records, list offsets, size_t alloc_hint):
    return _pack_records(records, offsets, alloc_hint)

cdef bytes _pack_records(list records,
                         list voffsets,
                         size_t alloc_hint):
    if voffsets is not None:
        if len(records) != len(voffsets):
            raise ValueError("len(records) == %s, len(voffsets) == %s"
                             % (len(records), len(voffsets)))
    cdef size_t written = 0
    cdef size_t bufsize = alloc_hint
    cdef size_t new_bufsize
    cdef int n_records = len(records)
    cdef int i = 0
    cdef char * c_data
    cdef Py_ssize_t c_length
    cdef char * buf = <char *>malloc(bufsize)
    try:
        for i in range(n_records):
            PyBytes_AsStringAndSize(records[i],
                                    &c_data, &c_length)
            if i > 0:
                if records[i - 1] > records[i]:
                    raise zss.ZSSError("records are not sorted: %r > %r"
                                       % (records[i - 1], records[i]))
            new_bufsize = bufsize
            while (new_bufsize - written) < (2 * _MAX_ULEB128_LENGTH
                                             + c_length
                                             # in case of off-by-one errors:
                                             + 10):
                new_bufsize *= 2
            if new_bufsize != bufsize:
                buf = <char *>realloc(buf, new_bufsize)
                bufsize = new_bufsize
            written += write_uleb128(c_length, buf + written)
            memcpy(buf + written, c_data, c_length)
            written += c_length
            if voffsets is not None:
                written += write_uleb128(voffsets[i], buf + written)
                if i > 0:
                    if voffsets[i - 1] >= voffsets[i]:
                        raise zss.ZSSError("blocks are not sorted: offset %s "
                                           "comes after %s"
                                           % (voffsets[i], voffsets[i - 1]))
            previous_c_data = c_data
            previous_c_length = c_length
        return PyBytes_FromStringAndSize(buf, written)
    finally:
        free(buf)

################################################################

def unpack_data_records(bytes data_block):
    return _unpack_records(False, data_block)[0]

def unpack_index_records(bytes index_block):
    return _unpack_records(True, index_block)

cdef tuple _unpack_records(bint is_index, bytes block):
    cdef char * buf
    cdef Py_ssize_t buf_len
    PyBytes_AsStringAndSize(block, &buf, &buf_len)
    cdef size_t offset = 0
    cdef uint64_t record_length, block_voffset
    cdef list records = []
    cdef list voffsets = None
    if is_index:
        voffsets = []
    while offset < buf_len:
        record_length = read_uleb128(buf, buf_len, &offset)
        if offset + record_length > buf_len:
            raise zss.ZSSCorrupt("record extends past end of block "
                                 "(%s bytes remaining in block, "
                                 "%s bytes in record)"
                                 % (buf_len - offset, record_length))
        records.append(PyBytes_FromStringAndSize(buf + offset,
                                                 record_length))
        offset += record_length
        if is_index:
            voffset = read_uleb128(buf, buf_len, &offset)
            voffsets.append(voffset)
    assert offset == buf_len
    return records, voffsets
