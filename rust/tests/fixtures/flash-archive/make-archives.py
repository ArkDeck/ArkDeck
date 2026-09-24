#!/usr/bin/env python3
"""Writes the synthetic DAYU200 flash bundles in `archives/`.

The Swift oracle `FlashBundleArchiveOracleContractTests` reads each one the
way Swift's production flash-bundle Import policy reads a bundle, and records
what it sees in `oracle/`. The Rust replay reads the same bytes. Together the
archives cover:

- the one streaming pass's gzip header, DEFLATE payload and tar records;
- the partition table and the version scan;
- the board's structural checks.

The archives are checked in. This script records how they were made; the
bytes, not the script, are the oracle's input.
"""
import io
import os
import struct
import tarfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "archives")

TABLE = (
    "0x00002000@0x00002000(uboot),0x00002000@0x00004000(misc),"
    "0x00002000@0x00006000(resource),0x00030000@0x00008000(boot_linux:bootable),"
    "0x00002000@0x00038000(ramdisk),0x00400000@0x0003a000(system),"
    "0x00100000@0x0043a000(vendor),0x00018000@0x0053a000(sys-prod),"
    "0x00018000@0x00552000(chip-prod),0x00018000@0x0056a000(updater),"
    "0x00010000@0x00582000(chip_ckm),0x00010000@0x00592000(eng_system),"
    "0x00010000@0x005a2000(eng_chipset),0x00001000@0x005b2000(bootctrl),"
    "-@0x005b3000(userdata:grow)"
)


def parameter(table=TABLE, newline="\n", command_line_first=False):
    lines = [
        "FIRMWARE_VER: 11.0",
        "MACHINE_MODEL: RK3568",
        "MACHINE_ID: 007",
        "MANUFACTURER: RK3568",
        "MAGIC: 0x5041524B",
        "TYPE: GPT",
        "CMDLINE: mtdparts=rk29xxnand:" + table,
        "uuid:system=614e0000-0000-4b53-8000-1d28000054a9",
    ]
    if command_line_first:
        lines.insert(0, lines.pop(6))
    return (newline.join(lines) + newline).encode()


def system_image(tail=b"const.ohos.fullname=OpenHarmony-7.0.0.36\n"):
    return b"\0" * 1024 + b"ro.boot.fake=1\n" + tail + b"const.product.model=ohos\n" + b"\0" * 512


def members(**changes):
    """The seventeen names of a DAYU200 daily, each with small content."""
    contents = {}
    for name in [
        "boot_linux.img", "chip_ckm.img", "chip_prod.img", "config.cfg", "daily_build.log",
        "manifest_tag.xml", "MiniLoaderAll.bin", "parameter.txt", "ramdisk.img",
        "resource.img", "sys_prod.img", "system.img", "uboot.img", "updater_binary",
        "updater.img", "userdata.img", "vendor.img",
    ]:
        contents[name] = (name + "\n").encode() * 3
    contents["parameter.txt"] = parameter()
    contents["system.img"] = system_image()
    for name, value in changes.items():
        name = name.replace("__", ".")
        if value is None:
            contents.pop(name, None)
        else:
            contents[name] = value
    return list(contents.items())


def info(name, size, kind=tarfile.REGTYPE):
    item = tarfile.TarInfo(name)
    item.size = size
    item.type = kind
    item.mtime = 0
    item.mode = 0o644 if kind != tarfile.DIRTYPE else 0o755
    item.uid = item.gid = 0
    item.uname = item.gname = ""
    return item


def tar(entries, fmt=tarfile.USTAR_FORMAT):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=fmt) as archive:
        for entry in entries:
            if isinstance(entry, tarfile.TarInfo):
                archive.addfile(entry)
            else:
                name, content = entry
                archive.addfile(info(name, len(content)), io.BytesIO(content))
    return buffer.getvalue()


def raw_tar(entries):
    """Headers and padded content only, no end-of-archive blocks."""
    out = b""
    for name, content in entries:
        out += info(name, len(content)).tobuf(format=tarfile.USTAR_FORMAT)
        out += content + b"\0" * ((512 - len(content) % 512) % 512)
    return out


def gz(data):
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = compressor.compress(data) + compressor.flush()
    header = b"\x1f\x8b\x08\x00" + struct.pack("<I", 0) + b"\x02\xff"
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return header + payload + trailer


def gz_with_fields(data, name=b"images.tar"):
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    payload = compressor.compress(data) + compressor.flush()
    header = b"\x1f\x8b\x08" + bytes([0x04 | 0x08 | 0x10 | 0x02]) + struct.pack("<I", 0)
    header += b"\x02\xff"
    extra = b"AB" + struct.pack("<H", 4) + b"data"
    header += struct.pack("<H", len(extra)) + extra + name + b"\0" + b"synthetic bundle\0"
    header += struct.pack("<H", zlib.crc32(header) & 0xFFFF)
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return header + payload + trailer


def rechecksum(block):
    block = bytearray(block)
    block[148:156] = b" " * 8
    block[148:156] = b"%06o\0 " % sum(block)
    return bytes(block)


def patch_first(data, patch):
    """`data` with its first header block patched, its checksum recomputed."""
    block = bytearray(data[:512])
    patch(block)
    return rechecksum(block) + data[512:]


def write(name, data):
    with open(os.path.join(OUT, name), "wb") as out:
        out.write(data)


def main():
    os.makedirs(OUT, exist_ok=True)
    complete = tar(members())
    write("complete.tar.gz", gz(complete))
    write("gzip-optional-fields.tar.gz", gz_with_fields(complete))
    write("gzip-name-over-64k.tar.gz", gz_with_fields(complete, name=b"n" * (70 * 1024)))
    write("multi-member.tar.gz", gz(complete) + gz(tar([("extra.bin", b"extra\n")])))
    write("ustar-prefix.tar.gz", gz(tar(
        members(daily_build__log=None) + [("d" * 90 + "/daily_build.log", b"log\n")])))
    pax = tar(
        [info("extras", 0, tarfile.DIRTYPE)]
        + members()
        + [("x" * 120 + ".txt", b"long name\n")],
        fmt=tarfile.PAX_FORMAT)
    write("pax-directory.tar.gz", gz(pax))
    link = info("link-to-system", 0, tarfile.SYMTYPE)
    link.linkname = "system.img"
    write("symlink.tar.gz", gz(tar(members() + [link])))
    write("trailer-trimmed.tar.gz", gz(raw_tar(members())))
    straddle = bytearray(b"\0" * (3 * 512 * 1024))
    key = b"const.ohos.fullname=OpenHarmony-7.0.0.36\n"
    start = (1 << 20) - 10 - 512
    straddle[start:start + len(key)] = key
    write("version-straddles-window.tar.gz", gz(tar(
        [("system.img", bytes(straddle))] + members(system__img=None))))
    write("long-noise-then-version.tar.gz", gz(tar(members(system__img=system_image(
        b"const.ohos.fullname=" + b"A" * 300 + b"\njunk\n"
        + b"const.ohos.fullname=OpenHarmony-7.0.0.37\n")))))
    write("version-at-member-end.tar.gz", gz(tar(members(
        system__img=b"\0" * 64 + b"const.ohos.fullname=OpenHarmony-7.0.0.36"))))
    write("no-version.tar.gz", gz(tar(members(system__img=b"\0" * 2048))))
    write("no-parameter.tar.gz", gz(tar(members(parameter__txt=None))))
    write("oversized-parameter.tar.gz", gz(tar(members(
        parameter__txt=parameter() + b"#" * (1 << 20)))))
    write("parameter-crlf.tar.gz", gz(tar(members(parameter__txt=parameter(newline="\r\n")))))
    write("parameter-crlf-command-line-first.tar.gz", gz(tar(members(
        parameter__txt=parameter(newline="\r\n", command_line_first=True)))))
    write("parameter-no-mtdparts.tar.gz", gz(tar(members(
        parameter__txt=b"FIRMWARE_VER: 11.0\nCMDLINE: console=ttyFIQ0\n"))))
    write("parameter-no-device-prefix.tar.gz", gz(tar(members(
        parameter__txt=b"CMDLINE: mtdparts=0x2000@0x2000(uboot)\n"))))
    write("parameter-bad-entry.tar.gz", gz(tar(members(
        parameter__txt=parameter(TABLE.replace("(uboot)", "uboot"))))))
    write("parameter-bad-hex.tar.gz", gz(tar(members(
        parameter__txt=parameter(TABLE.replace("@0x00002000(uboot)", "@0xZZ(uboot)"))))))
    write("parameter-signed-hex.tar.gz", gz(tar(members(
        parameter__txt=parameter(TABLE.replace("0x00002000@0x00002000(uboot)",
                                               "+0x2000@-10(uboot)"))))))
    write("parameter-not-utf8.tar.gz", gz(tar(members(
        parameter__txt=parameter() + b"\xff\xfe\n"))))
    write("parameter-empty-list.tar.gz", gz(tar(members(
        parameter__txt=b"CMDLINE: mtdparts=rk29xxnand:,,\n"))))
    write("no-system-image.tar.gz", gz(tar(members(system__img=None))))
    nonconforming_table = TABLE.replace(
        "0x00018000@0x0056a000(updater),", "").replace(
        "-@0x005b3000(userdata:grow)", "0x10@0x005b3000(extra),-@0x005b4000(userdata:grow)")
    write("nonconforming.tar.gz", gz(tar(members(
        vendor__img=None, parameter__txt=parameter(nonconforming_table)))))
    write("duplicate-member.tar.gz", gz(tar(members() + [("uboot.img", b"again\n")])))
    write("plain.tar", complete)
    method = bytearray(gz(complete))
    method[2] = 7
    write("method-7.tar.gz", bytes(method))
    reserved = bytearray(gz(complete))
    reserved[3] |= 0x20
    write("reserved-flag.tar.gz", bytes(reserved))
    whole = gz(complete)
    write("truncated-deflate.tar.gz", whole[: len(whole) * 3 // 5])
    write("garbage-deflate.tar.gz", whole[:10] + b"\xff" * 64)
    write("header-only.gz", whole[:5])
    write("empty.gz", b"")
    bad_checksum = bytearray(complete)
    bad_checksum[148] = ord("7")
    write("bad-checksum.tar.gz", gz(bytes(bad_checksum)))
    write("bad-octal-size.tar.gz", gz(patch_first(
        complete, lambda block: block.__setitem__(slice(124, 136), b"00000000009\0"))))
    write("bad-checksum-digit.tar.gz", gz(
        complete[:148] + b"0000x0\0 " + complete[156:]))
    write("huge-size.tar.gz", gz(patch_first(
        complete, lambda block: block.__setitem__(
            slice(124, 136), b"\x80" + (0x7FFFFFFFFFFFFF00).to_bytes(11, "big")))))
    write("size-overflow.tar.gz", gz(patch_first(
        complete, lambda block: block.__setitem__(slice(124, 136), b"\xff" + b"\xff" * 11))))
    first_size = len(members()[0][1])
    write("base256-size.tar.gz", gz(patch_first(
        complete, lambda block: block.__setitem__(
            slice(124, 136), b"\x80" + first_size.to_bytes(11, "big")))))
    cut = raw_tar(members())
    system_offset = cut.index(b"ro.boot.fake=1")
    write("truncated-tar.tar.gz", gz(cut[:system_offset]))
    write("empty-name.tar.gz", gz(patch_first(
        complete, lambda block: block.__setitem__(slice(0, 100), b"\0" * 100))))


if __name__ == "__main__":
    main()
