#!/usr/bin/env python3
"""Generate the Windows App's icon and MSIX visual assets from the macOS AppIcon.

Source of truth: ArkDeckApp/Resources/Assets.xcassets/AppIcon.appiconset (the macOS App's
icon; Contents.json maps each PNG to its point size and scale, so each file's pixel size is
size x scale, 16 to 1024 px). Outputs, in windows/App/Assets:

- AppIcon.ico: the executable's icon (the window, title bar and taskbar icon of the unpackaged
  App, AppWindow.SetIcon) with 16, 20, 24, 32, 40, 48, 64 and 256 px entries, each a PNG
  entry (ICO has carried PNG entries since Windows Vista);
- the MSIX visual assets Package.appxmanifest names, at scale-100 and scale-200:
  Square44x44Logo (plus the taskbar and Start list's targetsize-16/24/32/48/256 renditions,
  plated and altform-unplated), Square150x150Logo, Wide310x150Logo, StoreLogo, SplashScreen
  and LockScreenLogo.

Nothing is drawn: every pixel is the macOS icon resampled. A square asset is the icon over its
whole square; a tile (150x150) and a wide tile or splash screen carry the icon at two thirds of
their height, centred on transparency (Fluent tile padding). Resampling is an exact area average
over the smallest macOS rendition at least four times the target (the rendition itself when
the size matches), in premultiplied alpha, so edges do not darken.

Usage:
    python windows/scripts/generate-app-icons.py           # rewrite the assets
    python windows/scripts/generate-app-icons.py --check   # exit 1 if a committed asset differs

`--check` compares decoded pixels, sizes and the ICO's entries, not compressed bytes, so a
different zlib cannot fail it. Standard library only (zlib, struct).
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
ICONSET = REPO / "ArkDeckApp" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ASSETS = REPO / "windows" / "App" / "Assets"

# INPUTS: what the generated assets depend on (the CI planner's windows lane selects on them).
INPUTS = ("ArkDeckApp/Resources/Assets.xcassets/AppIcon.appiconset/",)

ICO_SIZES = (16, 20, 24, 32, 40, 48, 64, 256)
TARGET_SIZES = (16, 24, 32, 48, 256)


def outputs() -> dict[str, tuple[int, int, float]]:
    """Each PNG asset: (width, height, the icon's share of the height)."""
    out: dict[str, tuple[int, int, float]] = {}
    for scale, factor in (("100", 1), ("200", 2)):
        out[f"Square44x44Logo.scale-{scale}.png"] = (44 * factor, 44 * factor, 1.0)
        out[f"Square150x150Logo.scale-{scale}.png"] = (150 * factor, 150 * factor, 2 / 3)
        out[f"Wide310x150Logo.scale-{scale}.png"] = (310 * factor, 150 * factor, 2 / 3)
        out[f"StoreLogo.scale-{scale}.png"] = (50 * factor, 50 * factor, 1.0)
        out[f"SplashScreen.scale-{scale}.png"] = (620 * factor, 300 * factor, 2 / 3)
        out[f"LockScreenLogo.scale-{scale}.png"] = (24 * factor, 24 * factor, 1.0)
    for size in TARGET_SIZES:
        out[f"Square44x44Logo.targetsize-{size}.png"] = (size, size, 1.0)
        out[f"Square44x44Logo.targetsize-{size}_altform-unplated.png"] = (size, size, 1.0)
    return out


# ---- PNG (8-bit RGBA, not interlaced: what the macOS iconset holds) ----


def decode_png(data: bytes) -> tuple[int, int, bytes]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, header = 8, [], None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
        pos += 12 + length
    if header is None:
        raise ValueError("PNG without IHDR")
    width, height, depth, colour, _, _, interlace = header
    if (depth, colour, interlace) != (8, 6, 0):
        raise ValueError(f"unsupported PNG: depth {depth}, colour type {colour}, interlace {interlace}")
    raw = zlib.decompress(b"".join(idat))
    stride = width * 4
    out = bytearray(height * stride)
    previous = bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if kind == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = previous[i]
                c = previous[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + predictor) & 0xFF
        elif kind != 0:
            raise ValueError(f"unknown PNG filter {kind}")
        out[y * stride:(y + 1) * stride] = line
        previous = line
    return width, height, bytes(out)


def encode_png(width: int, height: int, rgba: bytes) -> bytes:
    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


# ---- resampling ----


def renditions() -> dict[int, Path]:
    """The macOS iconset's PNGs by pixel size (size x scale, from Contents.json)."""
    contents = json.loads((ICONSET / "Contents.json").read_text(encoding="utf-8"))
    by_size: dict[int, Path] = {}
    for image in contents["images"]:
        points = int(image["size"].split("x")[0])
        pixels = points * int(image["scale"].rstrip("x"))
        by_size.setdefault(pixels, ICONSET / image["filename"])
    return by_size


def weights(source: int, target: int) -> list[list[tuple[int, float]]]:
    """For each target pixel, the source pixels it covers and their coverage (area average)."""
    ratio = source / target
    out = []
    for t in range(target):
        start, end = t * ratio, (t + 1) * ratio
        taps = []
        s = int(start)
        while s < end and s < source:
            cover = min(end, s + 1) - max(start, s)
            if cover > 0:
                taps.append((s, cover / ratio))
            s += 1
        out.append(taps)
    return out


def resample(size: int, rgba: bytes, target: int) -> list[float]:
    """Area-averaged premultiplied RGBA floats, target x target."""
    if size == target:
        pixels = []
        for i in range(0, len(rgba), 4):
            a = rgba[i + 3] / 255
            pixels.extend((rgba[i] * a, rgba[i + 1] * a, rgba[i + 2] * a, rgba[i + 3]))
        return pixels
    taps = weights(size, target)
    # Premultiply, then average rows, then columns.
    pre = [0.0] * (size * size * 4)
    for i in range(0, len(rgba), 4):
        a = rgba[i + 3] / 255
        pre[i], pre[i + 1], pre[i + 2], pre[i + 3] = rgba[i] * a, rgba[i + 1] * a, rgba[i + 2] * a, rgba[i + 3]
    rows = [0.0] * (size * target * 4)
    for y in range(size):
        base = y * size * 4
        for x, tap in enumerate(taps):
            r = g = b = a = 0.0
            for s, w in tap:
                j = base + s * 4
                r += pre[j] * w
                g += pre[j + 1] * w
                b += pre[j + 2] * w
                a += pre[j + 3] * w
            k = (y * target + x) * 4
            rows[k], rows[k + 1], rows[k + 2], rows[k + 3] = r, g, b, a
    out = [0.0] * (target * target * 4)
    for y, tap in enumerate(taps):
        for x in range(target):
            r = g = b = a = 0.0
            for s, w in tap:
                j = (s * target + x) * 4
                r += rows[j] * w
                g += rows[j + 1] * w
                b += rows[j + 2] * w
                a += rows[j + 3] * w
            k = (y * target + x) * 4
            out[k], out[k + 1], out[k + 2], out[k + 3] = r, g, b, a
    return out


class Icon:
    def __init__(self) -> None:
        self.sources = renditions()
        self.decoded: dict[int, tuple[int, bytes]] = {}
        self.cache: dict[int, bytes] = {}

    def square(self, target: int) -> bytes:
        """The icon at target x target, straight RGBA bytes."""
        if target in self.cache:
            return self.cache[target]
        sizes = sorted(self.sources)
        size = target if target in self.sources else next((s for s in sizes if s >= 4 * target), sizes[-1])
        if size not in self.decoded:
            width, height, rgba = decode_png(self.sources[size].read_bytes())
            if width != size or height != size:
                raise ValueError(f"{self.sources[size].name} is {width}x{height}, not {size}x{size}")
            self.decoded[size] = (size, rgba)
        pixels = resample(size, self.decoded[size][1], target)
        out = bytearray(target * target * 4)
        for i in range(0, len(pixels), 4):
            a = pixels[i + 3]
            alpha = min(255, max(0, round(a)))
            if alpha == 0:
                continue
            scale = 255 / a
            out[i] = min(255, max(0, round(pixels[i] * scale)))
            out[i + 1] = min(255, max(0, round(pixels[i + 1] * scale)))
            out[i + 2] = min(255, max(0, round(pixels[i + 2] * scale)))
            out[i + 3] = alpha
        self.cache[target] = bytes(out)
        return self.cache[target]

    def canvas(self, width: int, height: int, share: float) -> bytes:
        """The icon centred on a transparent width x height canvas at share of its height."""
        side = min(width, height) if share >= 1 else round(height * share)
        icon = self.square(side)
        if (width, height) == (side, side):
            return icon
        out = bytearray(width * height * 4)
        left, top = (width - side) // 2, (height - side) // 2
        for y in range(side):
            row = ((top + y) * width + left) * 4
            out[row:row + side * 4] = icon[y * side * 4:(y + 1) * side * 4]
        return bytes(out)


def encode_ico(entries: list[tuple[int, bytes]]) -> bytes:
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory, images = b"", b""
    for size, png in entries:
        edge = 0 if size >= 256 else size
        directory += struct.pack("<BBBBHHII", edge, edge, 0, 0, 1, 32, len(png), offset + len(images))
        images += png
    return header + directory + images


def decode_ico(data: bytes) -> list[tuple[int, int, bytes]]:
    _, kind, count = struct.unpack("<HHH", data[:6])
    if kind != 1:
        raise ValueError("not an icon")
    out = []
    for i in range(count):
        width, height, _, _, _, _, length, offset = struct.unpack("<BBBBHHII", data[6 + 16 * i:22 + 16 * i])
        image = data[offset:offset + length]
        if image[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("an ICO entry that is not a PNG")
        w, h, rgba = decode_png(image)
        if (w, h) != (width or 256, height or 256):
            raise ValueError("an ICO entry whose directory size differs from its image")
        out.append((w, h, rgba))
    return out


def build() -> dict[str, bytes]:
    icon = Icon()
    files = {name: encode_png(w, h, icon.canvas(w, h, share)) for name, (w, h, share) in outputs().items()}
    files["AppIcon.ico"] = encode_ico([(size, encode_png(size, size, icon.square(size))) for size in ICO_SIZES])
    return files


def pixels(name: str, data: bytes) -> object:
    return decode_ico(data) if name.endswith(".ico") else [decode_png(data)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if a committed asset differs")
    args = parser.parse_args()
    files = build()
    stale = sorted(p.name for p in ASSETS.glob("*.png") if p.name not in files)
    if args.check:
        problems = []
        for name, data in files.items():
            path = ASSETS / name
            if not path.exists():
                problems.append(f"missing {name}")
            elif pixels(name, path.read_bytes()) != pixels(name, data):
                problems.append(f"stale {name}")
        problems.extend(f"not generated {name}" for name in stale)
        if problems:
            for problem in problems:
                print(f"windows/App/Assets: {problem}", file=sys.stderr)
            print("run: python windows/scripts/generate-app-icons.py", file=sys.stderr)
            return 1
        print(f"ok: {len(files)} App assets match the macOS AppIcon")
        return 0
    for name in stale:
        (ASSETS / name).unlink()
    for name, data in files.items():
        (ASSETS / name).write_bytes(data)
    print(f"wrote {len(files)} App assets from the macOS AppIcon ({len(stale)} removed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
