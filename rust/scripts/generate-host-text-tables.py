#!/usr/bin/env python3
"""Generate the pinned Unicode tables behind arkdeck-platform's host text.

They stand in for CoreFoundation's predefined character sets and its NFC:
`controlCharacters` (Cc, Cf), `alphanumerics` (L*, M*, N*),
`whitespacesAndNewlines` (Z*, U+0009 to U+000D, U+0085), and the canonical
decomposition, combining class and primary composition data that
`CFStringNormalize(kCFStringNormalizationFormC)` applies.

Inputs, both from https://www.unicode.org/Public/17.0.0/ucd/:
  UnicodeData.txt, CompositionExclusions.txt
No network or source audit is performed by this generator.

CoreFoundation does not follow Unicode 17.0.0 everywhere. The differences
below were recorded by comparing every scalar and every composition pair with
CoreFoundation itself on the macOS CI image (xcode-27, macOS 27; PR #2336,
run 36666514795) and are applied here, so the tables answer as the macOS
owner does rather than as the standard does:
- Todhri (U+105C0..U+105FF, new in Unicode 16) is unassigned: not
  alphanumeric, no decompositions.
- The Tangut ideograph ranges (UnicodeData's First/Last range entries
  U+17000..U+187FF and U+18D00..U+18D1E) are not alphanumeric.
- U+200B ZERO WIDTH SPACE is in whitespacesAndNewlines.
- Six Unicode 16 primary composites whose second character is a starter
  (Gurung Khema U+16126..U+16128, Kirat Rai U+16D68..U+16D6A) are kept when
  the text holds them precomposed but never form from separate characters
  (emitted as OWN_SOURCE_ONLY).
"""
import argparse
import hashlib
from pathlib import Path

VERSION = "17.0.0"
PINS = {
    "UnicodeData.txt": "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    "CompositionExclusions.txt": "2f239196ef3b5b61db5cc476e9bd80f534d15aa1b74e1be1dea5d042a344c85f",
}


TODHRI = range(0x105C0, 0x10600)
UNALPHANUMERIC_RANGES = ("Tangut Ideograph", "Tangut Ideograph Supplement")
WHITESPACE_EXTRA = {0x200B}
OWN_SOURCE_ONLY = {0x16126, 0x16127, 0x16128, 0x16D68, 0x16D69, 0x16D6A}


def pinned(directory: Path, name: str) -> str:
    data = (directory / name).read_bytes()
    if hashlib.sha256(data).hexdigest() != PINS[name]:
        raise ValueError(f"{name} does not match the pinned Unicode {VERSION} source")
    return data.decode("utf-8")


def records(text: str):
    """Yield (first, last, fields) with First/Last ranges folded together."""
    first = None
    for line in text.splitlines():
        fields = line.split(";")
        code = int(fields[0], 16)
        if fields[1].endswith(", First>"):
            first = code
            continue
        if fields[1].endswith(", Last>"):
            if first is None:
                raise ValueError("range end without a start")
            yield first, code, fields
            first = None
            continue
        yield code, code, fields


def ranges(points):
    result = []
    for code in sorted(points):
        if result and result[-1][1] + 1 == code:
            result[-1][1] = code
        else:
            result.append([code, code])
    return result


def generate(directory: Path) -> str:
    data = pinned(directory, "UnicodeData.txt")
    exclusions_text = pinned(directory, "CompositionExclusions.txt")
    control, alphanumeric = set(), set()
    whitespace = {0x9, 0xA, 0xB, 0xC, 0xD, 0x85} | WHITESPACE_EXTRA
    combining = {}
    decomposition = {}
    for low, high, fields in records(data):
        if low in TODHRI:
            continue
        category = fields[2]
        tangut = low != high and fields[1].strip("<>").rsplit(",", 1)[0] in UNALPHANUMERIC_RANGES
        for code in range(low, high + 1):
            if category in ("Cc", "Cf"):
                control.add(code)
            if category[0] in "LMN" and not tangut:
                alphanumeric.add(code)
            if category[0] == "Z":
                whitespace.add(code)
            if int(fields[3]):
                combining[code] = int(fields[3])
        mapping = fields[5]
        if mapping and not mapping.startswith("<"):
            if low != high:
                raise ValueError("canonical mapping on a code point range")
            parts = [int(part, 16) for part in mapping.split()]
            if not 1 <= len(parts) <= 2:
                raise ValueError("canonical mapping longer than two scalars")
            decomposition[low] = parts
    excluded = set()
    for line in exclusions_text.splitlines():
        body = line.split("#", 1)[0].strip()
        if body:
            excluded.add(int(body, 16))
    # Full_Composition_Exclusion (UAX #15): listed exclusions, singletons and
    # non-starter decompositions never recompose.
    compositions = []
    for code, parts in decomposition.items():
        if code in excluded or len(parts) == 1:
            continue
        if combining.get(code, 0) or combining.get(parts[0], 0):
            continue
        compositions.append((parts[0], parts[1], code))
    compositions.sort()
    if len({(a, b) for a, b, _ in compositions}) != len(compositions):
        raise ValueError("ambiguous primary composition")
    if not OWN_SOURCE_ONLY <= {c for _, _, c in compositions} or any(c in TODHRI for c in decomposition):
        raise ValueError("recorded CoreFoundation differences no longer apply")
    classes = []
    for code in sorted(combining):
        value = combining[code]
        if classes and classes[-1][1] + 1 == code and classes[-1][2] == value:
            classes[-1][1] = code
        else:
            classes.append([code, code, value])

    lines = [
        "// Generated by rust/scripts/generate-host-text-tables.py; do not edit.",
        f"// Unicode {VERSION} UnicodeData.txt and CompositionExclusions.txt;",
        "// Unicode License v3 (UNICODE-LICENSE). CoreFoundation's recorded",
        "// differences from the standard are applied; see the generator.",
    ]
    lines += [f"// {name} SHA-256: {pin}" for name, pin in PINS.items()]
    lines.append("#[cfg(test)]")
    lines.append(f'pub(super) const UNICODE_VERSION: &str = "{VERSION}";')
    for name, points in (
        ("CONTROL", control),
        ("ALPHANUMERIC", alphanumeric),
        ("WHITESPACE_OR_NEWLINE", whitespace),
    ):
        lines.append(f"pub(super) const {name}: &[(u32, u32)] = &[")
        lines += [f"    (0x{lo:X}, 0x{hi:X})," for lo, hi in ranges(points)]
        lines.append("];")
    lines.append("pub(super) const COMBINING_CLASS: &[(u32, u32, u8)] = &[")
    lines += [f"    (0x{lo:X}, 0x{hi:X}, {value})," for lo, hi, value in classes]
    lines.append("];")
    lines.append("/// Canonical mapping: (scalar, first, second or 0 for a singleton).")
    lines.append("pub(super) const DECOMPOSITION: &[(u32, u32, u32)] = &[")
    for code in sorted(decomposition):
        parts = decomposition[code] + [0]
        lines.append(f"    (0x{code:X}, 0x{parts[0]:X}, 0x{parts[1]:X}),")
    lines.append("];")
    lines.append("/// Composites formed only from one precomposed input character.")
    own = ", ".join(f"0x{c:X}" for c in sorted(OWN_SOURCE_ONLY))
    lines.append(f"pub(super) const OWN_SOURCE_ONLY: &[u32] = &[{own}];")
    lines.append("/// Primary composites: (first, second, composite), sorted by the pair.")
    lines.append("pub(super) const COMPOSITION: &[(u32, u32, u32)] = &[")
    lines += [f"    (0x{a:X}, 0x{b:X}, 0x{c:X})," for a, b, c in compositions]
    lines.append("];")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="directory with the UCD files")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = generate(args.input)
    if args.check:
        if args.output.read_text(encoding="utf-8") != result:
            raise ValueError("generated Unicode tables have drifted")
    else:
        args.output.write_text(result, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
