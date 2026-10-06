#!/usr/bin/env python3
"""Generate the Windows App's string resources from the shared bilingual source.

Source of truth: spec/ui-semantics/strings.json (TASK-XPA-007; design
rust-core-cross-platform-architecture.md §590: one bilingual source generates both the
macOS `.xcstrings` and the Windows `.resw`). Outputs:

- windows/App/Strings/en-US/Resources.resw and windows/App/Strings/zh-Hans/Resources.resw:
  every entry, the resource name being the key with "." replaced by "_" (MRT reads a "."
  in a .resw name as an x:Uid property path);
- windows/App.Core/Generated/UiStrings.g.cs: the keys as C# constants, so App code cannot
  name a key the catalogue lacks;
- ArkDeckApp/Resources/<table>.xcstrings: every entry that names a macOS table must have
  exactly the source's en and zh-Hans values there (values unchanged). `--write` rewrites
  only a value that differs and leaves every other byte and key of the table alone.

Entries whose table is null are Windows-only surfaces and are not written to any
`.xcstrings`. Format placeholders stay in the macOS printf form (%@, %lld, %1$@) in both
outputs; the App's Localizer formats them.

Usage:
    python windows/scripts/generate-ui-strings.py --write
    python windows/scripts/generate-ui-strings.py --check   # exit 1 on any drift

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "spec" / "ui-semantics" / "strings.json"
XCSTRINGS_DIR = REPO / "ArkDeckApp" / "Resources"
RESW = {
    "en": REPO / "windows" / "App" / "Strings" / "en-US" / "Resources.resw",
    "zh-Hans": REPO / "windows" / "App" / "Strings" / "zh-Hans" / "Resources.resw",
}
KEYS_CS = REPO / "windows" / "App.Core" / "Generated" / "UiStrings.g.cs"
LANGUAGES = ("en", "zh-Hans")
KEY = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*$")
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d)")

# INPUTS: what the generated files and the check depend on (the CI planner's windows lane
# selects on each; scripts/ci/test_plan.py loads this tuple).
INPUTS = (
    "spec/ui-semantics/strings.json",
    "ArkDeckApp/Resources/Localizable.xcstrings",
    "ArkDeckApp/Resources/HistoryLocalizable.xcstrings",
    "ArkDeckApp/Resources/JobsLocalizable.xcstrings",
    "ArkDeckApp/Resources/SettingsLocalizable.xcstrings",
    "ArkDeckApp/Resources/DebugLocalizable.xcstrings",
    "ArkDeckApp/Resources/FlashLocalizable.xcstrings",
    "ArkDeckApp/Resources/TraceLocalizable.xcstrings",
    "ArkDeckApp/Resources/TraceViewerLocalizable.xcstrings",
    "ArkDeckApp/Resources/UIDumpLocalizable.xcstrings",
    "ArkDeckApp/Resources/DiagnosticsLocalizable.xcstrings",
    "ArkDeckApp/Resources/DeviceLocalizable.xcstrings",
)


class SourceError(Exception):
    pass


def resource_name(key: str) -> str:
    return key.replace(".", "_")


def placeholders(value: str) -> list[tuple[int, str]]:
    found, position = [], 0
    for m in PLACEHOLDER.finditer(value):
        position += 1
        index = int(m.group(1)) if m.group(1) else position
        kind = "@" if m.group(2) == "@" else "d"
        found.append((index, kind))
    return sorted(found)


def load() -> list[dict]:
    doc = json.loads(SOURCE.read_text(encoding="utf-8"))
    if doc.get("schemaVersion") != "arkdeck.ui-semantics.strings/1":
        raise SourceError("strings.json: unknown schemaVersion")
    if tuple(doc.get("languages", ())) != LANGUAGES:
        raise SourceError(f"strings.json: languages must be {list(LANGUAGES)}")
    seen, names = set(), {}
    for entry in doc["entries"]:
        if set(entry) != {"key", "table", "en", "zh-Hans"}:
            raise SourceError(f"strings.json: entry members must be key, table, en, zh-Hans: {entry}")
        key = entry["key"]
        if not KEY.match(key):
            raise SourceError(f"strings.json: malformed key {key!r}")
        if key in seen:
            raise SourceError(f"strings.json: duplicate key {key}")
        seen.add(key)
        name = resource_name(key)
        if name in names:
            raise SourceError(f"strings.json: {key} and {names[name]} map to one resource name {name}")
        names[name] = key
        table = entry["table"]
        if table is not None and f"ArkDeckApp/Resources/{table}.xcstrings" not in INPUTS:
            raise SourceError(f"strings.json: {key} names table {table}; add its .xcstrings to INPUTS")
        if table is None and not key.startswith("windows."):
            raise SourceError(f"strings.json: Windows-only key {key} must start with 'windows.'")
        if table is not None and key.startswith("windows."):
            raise SourceError(f"strings.json: {key} names a macOS table but uses the Windows-only prefix")
        for language in LANGUAGES:
            if not isinstance(entry[language], str) or not entry[language].strip():
                raise SourceError(f"strings.json: {key} has no {language} value")
        if placeholders(entry["en"]) != placeholders(entry["zh-Hans"]):
            raise SourceError(f"strings.json: {key}: en and zh-Hans placeholders differ")
    return doc["entries"]


def render_resw(entries: list[dict], language: str) -> str:
    out = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!--",
        "  GENERATED by windows/scripts/generate-ui-strings.py from spec/ui-semantics/strings.json.",
        "  Do not edit by hand: edit the source and run the script (its check mode fails on drift).",
        "-->",
        "<root>",
        '  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>',
        '  <resheader name="version"><value>2.0</value></resheader>',
        '  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>',
        '  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089</value></resheader>',
    ]
    for entry in entries:
        origin = f"{entry['table']}.xcstrings" if entry["table"] else "Windows only"
        out.append(f'  <data name="{resource_name(entry["key"])}" xml:space="preserve">')
        out.append(f"    <value>{escape(entry[language])}</value>")
        out.append(f"    <comment>{escape(entry['key'])} ({escape(origin)})</comment>")
        out.append("  </data>")
    out.append("</root>")
    return "\n".join(out) + "\n"


def pascal(key: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[.]", key))


def render_keys(entries: list[dict]) -> str:
    out = [
        "// <auto-generated>",
        "// GENERATED by windows/scripts/generate-ui-strings.py from spec/ui-semantics/strings.json.",
        "// Do not edit by hand.",
        "// </auto-generated>",
        "",
        "namespace ArkDeck.App.Core.Strings;",
        "",
        "/// <summary>The keys of the shared bilingual catalogue (spec/ui-semantics/strings.json).</summary>",
        "public static class UiStrings",
        "{",
    ]
    for entry in entries:
        out.append(f'    public const string {pascal(entry["key"])} = "{entry["key"]}";')
    out.append("")
    out.append("    /// <summary>Every key, in catalogue order.</summary>")
    out.append("    public static readonly IReadOnlyList<string> All =")
    out.append("    [")
    for entry in entries:
        out.append(f"        {pascal(entry['key'])},")
    out.append("    ];")
    out.append("}")
    return "\n".join(out) + "\n"


def xcstrings_drift(entries: list[dict], write: bool) -> list[str]:
    problems: list[str] = []
    by_table: dict[str, list[dict]] = {}
    for entry in entries:
        if entry["table"] is not None:
            by_table.setdefault(entry["table"], []).append(entry)
    for table, rows in sorted(by_table.items()):
        path = XCSTRINGS_DIR / f"{table}.xcstrings"
        if not path.exists():
            problems.append(f"{path.relative_to(REPO).as_posix()}: missing")
            continue
        text = path.read_text(encoding="utf-8")
        strings = json.loads(text)["strings"]
        changed = False
        for entry in rows:
            key = entry["key"]
            if key not in strings:
                problems.append(f"{table}.xcstrings: no key {key}")
                continue
            localizations = strings[key].setdefault("localizations", {})
            for language in LANGUAGES:
                unit = localizations.setdefault(language, {}).setdefault("stringUnit", {})
                if unit.get("value") != entry[language]:
                    problems.append(f"{table}.xcstrings: {key} [{language}] is {unit.get('value')!r}, source says {entry[language]!r}")
                    if write:
                        text = replace_value(text, key, language, unit.get("value"), entry[language])
                        changed = True
        if write and changed:
            path.write_text(text, encoding="utf-8", newline="\n")
    return problems


def replace_value(text: str, key: str, language: str, old: str | None, new: str) -> str:
    """Replaces one stringUnit value in place, so the table's own formatting is kept."""
    start = text.index(json.dumps(key, ensure_ascii=False))
    lang_at = text.index(json.dumps(language), start)
    old_json = json.dumps(old, ensure_ascii=False)
    value_at = text.index(old_json, lang_at)
    return text[:value_at] + json.dumps(new, ensure_ascii=False) + text[value_at + len(old_json):]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    args = ap.parse_args()
    try:
        entries = load()
    except SourceError as error:
        print(error, file=sys.stderr)
        return 1
    outputs = {RESW[language]: render_resw(entries, language) for language in LANGUAGES}
    outputs[KEYS_CS] = render_keys(entries)
    stale = []
    for path, text in outputs.items():
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current != text:
            stale.append(path.relative_to(REPO).as_posix())
            if args.write:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8", newline="\n")
    drift = xcstrings_drift(entries, write=args.write)
    if args.check:
        for path in stale:
            print(f"stale: {path} (run windows/scripts/generate-ui-strings.py --write)", file=sys.stderr)
        for problem in drift:
            print(f"drift: {problem}", file=sys.stderr)
        if stale or drift:
            return 1
        shared = sum(1 for e in entries if e["table"])
        print(f"ok: {len(entries)} strings ({shared} shared with the macOS App, values unchanged; "
              f"{len(entries) - shared} Windows-only) match the .resw and .xcstrings")
        return 0
    for path in stale:
        print(f"wrote {path}")
    for problem in drift:
        print(f"updated {problem}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
