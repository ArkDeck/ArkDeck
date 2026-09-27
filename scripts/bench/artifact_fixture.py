"""Bounded deterministic expansion of the existing synthetic complete archive."""
from __future__ import annotations

import hashlib
import math
import os
import pathlib
import struct
import tarfile
import zlib

from . import clocks

MIB = 1024 * 1024
SIZES = (MIB, 128 * MIB, 1024 * MIB)
VERSION = 'input-artifact-stored-gzip-v1'
TEMPLATE = pathlib.Path(__file__).resolve().parents[2] / 'rust/tests/fixtures/flash-archive/archives/complete.tar.gz'


def generate(path, count, budget_seconds=120):
    """Write exact archive bytes with bounded memory; no sparse or fake payload."""
    if count not in SIZES:
        raise ValueError('artifact fixture size must be 1, 128 or 1024 MiB')
    deadline = clocks.Deadline(budget_seconds)
    members = []
    with tarfile.open(TEMPLATE, 'r:gz') as archive:
        for member in archive:
            if not member.isfile() or member.size > MIB or len(members) >= 32:
                raise ValueError('unexpected baseline archive member')
            members.append((member.name, archive.extractfile(member).read()))
    if len(members) != 17 or sum(name == 'userdata.img' for name, _ in members) != 1:
        raise ValueError('unexpected complete archive template')
    # RFC1951 stored blocks have deterministic 5-byte overhead. A bounded
    # RFC1952 extra field fills the residual bytes without changing tar content.
    raw_count = ((count - 20 - 5 * math.ceil(count / 65535)) // 512) * 512
    extra = count - raw_count - 5 * math.ceil(raw_count / 65535) - 20
    if not 0 <= extra <= 65500:
        raise ValueError('gzip header padding outside fixed bound')
    fixed = 1024 + sum(512 + (0 if name == 'userdata.img' else (len(data) + 511) // 512 * 512)
                       for name, data in members)
    userdata_size = raw_count - fixed
    if userdata_size <= 0 or userdata_size % 512:
        raise ValueError('invalid expanded tar size')

    def pieces():
        for name, data in members:
            size = userdata_size if name == 'userdata.img' else len(data)
            item = tarfile.TarInfo(name)
            item.size, item.mode, item.mtime = size, 0o644, 0
            item.uid = item.gid = 0
            yield item.tobuf(format=tarfile.USTAR_FORMAT)
            if name == 'userdata.img':
                block = bytes(range(256)) * 256
                remaining = size
                while remaining:
                    piece = block[:min(remaining, len(block))]
                    yield piece
                    remaining -= len(piece)
            else:
                yield data
                yield b'\0' * ((-len(data)) % 512)
        yield b'\0' * 1024

    digest = hashlib.sha256()
    written = 0
    with pathlib.Path(path).open('xb') as output:
        os.chmod(path, 0o600)
        def write(data):
            nonlocal written
            if deadline.expired():
                raise TimeoutError('artifact generation deadline')
            if written + len(data) > count:
                raise ValueError('artifact generator exceeded disk bound')
            output.write(data)
            digest.update(data)
            written += len(data)
        write(b'\x1f\x8b\x08\x04' + b'\0' * 4 + b'\0\xff' + struct.pack('<H', extra) + b'\0' * extra)
        pending = bytearray()
        raw_written = 0
        checksum = 0
        for piece in pieces():
            pending.extend(piece)
            while len(pending) >= 65535:
                block = bytes(pending[:65535])
                del pending[:65535]
                raw_written += len(block)
                checksum = zlib.crc32(block, checksum)
                write(bytes([int(raw_written == raw_count)]) + struct.pack('<HH', len(block), 65535 ^ len(block)) + block)
        if pending:
            raw_written += len(pending)
            checksum = zlib.crc32(pending, checksum)
            write(b'\x01' + struct.pack('<HH', len(pending), 65535 ^ len(pending)) + pending)
        if raw_written != raw_count:
            raise ValueError('tar stream size differs')
        write(struct.pack('<II', checksum & 0xffffffff, raw_count & 0xffffffff))
        output.flush()
        os.fsync(output.fileno())
    if written != count:
        raise ValueError('archive byte count differs')
    return {'fixtureVersion': VERSION, 'byteCount': count, 'sha256': digest.hexdigest(),
            'templateSha256': hashlib.sha256(TEMPLATE.read_bytes()).hexdigest(),
            'userdataBytes': userdata_size, 'gzipEncoding': 'stored-deflate-with-bounded-extra'}
