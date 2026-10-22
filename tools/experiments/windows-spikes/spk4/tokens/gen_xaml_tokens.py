#!/usr/bin/env python3
"""Generate the WinUI 3 token ResourceDictionary from the ArkDeck design-system tokens.

Source of truth: docs/design/arkdeck-ds/src/tokens.css (light `:root`, dark
`@media (prefers-color-scheme: dark)`; the `[data-theme]` overrides must repeat those
values and are checked). Output: ArkDeck.Spk4/Themes/ArkDeckTokens.xaml.

Usage:
    python gen_xaml_tokens.py           # rewrite the XAML
    python gen_xaml_tokens.py --check   # exit 1 if the committed XAML is stale

Mapping rules (SPK-4; design §H.1 allows platform fonts and chrome to differ):
- every colour token -> `ArkDeck<Name>Color` + `ArkDeck<Name>Brush` in the Light and Dark
  theme dictionaries, values copied verbatim (rgba alpha -> #AARRGGBB);
- HighContrast: every brush maps to a Windows system colour (never a token hex), and all
  state colours map to the window text colour, because state must be carried by text and
  glyph, not colour (AC-UX-005-01);
- radius -> CornerRadius, space -> x:Double + uniform Thickness, text size -> x:Double
  (CSS px == WinUI effective pixels);
- font families -> the Windows equivalents in FONT_MAP;
- shadows are not mapped: WinUI elevation (ThemeShadow / layer brushes) replaces them.
Standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPIKE = HERE.parent
REPO = SPIKE.parents[2]
CSS = REPO / "docs" / "design" / "arkdeck-ds" / "src" / "tokens.css"
OUT = SPIKE / "ArkDeck.Spk4" / "Themes" / "ArkDeckTokens.xaml"

HC_MAP = {
    "ground": "SystemColorWindowColor",
    "panel": "SystemColorWindowColor",
    "panel-solid": "SystemColorWindowColor",
    "panel-2": "SystemColorWindowColor",
    "chrome": "SystemColorWindowColor",
    "ink": "SystemColorWindowTextColor",
    "ink-2": "SystemColorWindowTextColor",
    "ink-3": "SystemColorWindowTextColor",
    "line": "SystemColorWindowTextColor",
    "accent": "SystemColorHighlightColor",
    "accent-fill": "SystemColorHighlightColor",
    "accent-ink": "SystemColorHighlightTextColor",
    "accent-weak": "SystemColorWindowColor",
    "accent-sel": "SystemColorHighlightColor",
    "ok": "SystemColorWindowTextColor",
    "warn": "SystemColorWindowTextColor",
    "danger": "SystemColorWindowTextColor",
    "danger-fill": "SystemColorHighlightColor",
    "danger-weak": "SystemColorWindowColor",
    "planned": "SystemColorWindowTextColor",
    "simulated": "SystemColorWindowTextColor",
}

FONT_MAP = {
    "font-ui": "Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI",
    "font-mono": "Cascadia Mono, Consolas, Microsoft YaHei UI",
}

UNMAPPED = {"shadow", "control-shadow"}

DECL = re.compile(r"--ad-([a-z0-9-]+)\s*:\s*([^;]+);", re.S)


def block(css: str, selector_regex: str) -> str:
    m = re.search(selector_regex + r"\s*\{", css)
    if not m:
        raise SystemExit(f"tokens.css: selector not found: {selector_regex}")
    depth, i = 1, m.end()
    while depth:
        c = css[i]
        depth += c == "{"
        depth -= c == "}"
        i += 1
    return css[m.end() : i - 1]


def decls(text: str) -> dict[str, str]:
    return {k: " ".join(v.split()) for k, v in DECL.findall(text)}


def pascal(name: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in name.split("-"))


def to_argb(value: str) -> str | None:
    v = value.strip().lower()
    if re.fullmatch(r"#[0-9a-f]{6}", v):
        return "#FF" + v[1:].upper()
    m = re.fullmatch(r"rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)", v)
    if m:
        r, g, b = (int(m.group(i)) for i in (1, 2, 3))
        a = round(float(m.group(4)) * 255)
        return f"#{a:02X}{r:02X}{g:02X}{b:02X}"
    return None


def px(value: str) -> str | None:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)px", value.strip())
    return m.group(1) if m else None


def load() -> tuple[dict[str, str], dict[str, str]]:
    css = re.sub(r"/\*.*?\*/", "", CSS.read_text(encoding="utf-8"), flags=re.S)
    light = decls(block(css, r"(?m)^:root"))
    media = block(css, r"@media \(prefers-color-scheme: dark\)")
    dark = {**light, **decls(block(media, r":root"))}
    for sel, expect in (
        (r':root\[data-theme="dark"\]', dark),
        (r':root\[data-theme="light"\]', light),
    ):
        for k, v in decls(block(css, sel)).items():
            if expect.get(k) != v:
                raise SystemExit(f"tokens.css: {sel} --ad-{k} = {v!r} disagrees with {expect.get(k)!r}")
    return light, dark


def render() -> str:
    light, dark = load()
    colours = [k for k, v in light.items() if to_argb(v)]
    missing_hc = [k for k in colours if k not in HC_MAP]
    if missing_hc:
        raise SystemExit(f"gen_xaml_tokens: add a HighContrast mapping for: {', '.join(missing_hc)}")
    handled = set(colours) | set(FONT_MAP) | UNMAPPED
    handled |= {k for k in light if k.startswith(("radius-", "space-", "text-"))}
    stray = sorted(set(light) - handled)
    if stray:
        raise SystemExit(f"gen_xaml_tokens: no mapping rule for: {', '.join(stray)}")

    out: list[str] = []
    w = out.append
    w('<?xml version="1.0" encoding="utf-8"?>')
    w("<!--")
    w("  GENERATED by windows/spikes/spk4/tokens/gen_xaml_tokens.py from")
    w("  docs/design/arkdeck-ds/src/tokens.css. Do not edit by hand: run the script.")
    w("  The script's check mode and TokenMappingTests fail on drift.")
    w("-->")
    w('<ResourceDictionary')
    w('    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"')
    w('    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">')
    w("    <ResourceDictionary.ThemeDictionaries>")
    for theme, values in (("Light", light), ("Dark", dark)):
        w(f'        <ResourceDictionary x:Key="{theme}">')
        for k in colours:
            n = pascal(k)
            w(f'            <Color x:Key="ArkDeck{n}Color">{to_argb(values[k])}</Color>')
            w(f'            <SolidColorBrush x:Key="ArkDeck{n}Brush" Color="{{StaticResource ArkDeck{n}Color}}" />')
        w("        </ResourceDictionary>")
    w('        <ResourceDictionary x:Key="HighContrast">')
    for k in colours:
        n = pascal(k)
        w(f'            <StaticResource x:Key="ArkDeck{n}Color" ResourceKey="{HC_MAP[k]}" />')
        w(f'            <SolidColorBrush x:Key="ArkDeck{n}Brush" Color="{{ThemeResource {HC_MAP[k]}}}" />')
    w("        </ResourceDictionary>")
    w("    </ResourceDictionary.ThemeDictionaries>")
    w("")
    for k, v in light.items():
        n = pascal(k)
        if k.startswith("radius-"):
            w(f'    <CornerRadius x:Key="ArkDeck{n}">{px(v)}</CornerRadius>')
        elif k.startswith("space-"):
            w(f'    <x:Double x:Key="ArkDeck{n}">{px(v)}</x:Double>')
            w(f'    <Thickness x:Key="ArkDeck{n}Thickness">{px(v)}</Thickness>')
        elif k.startswith("text-"):
            w(f'    <x:Double x:Key="ArkDeck{n}">{px(v)}</x:Double>')
        elif k in FONT_MAP:
            w(f'    <FontFamily x:Key="ArkDeck{n}">{FONT_MAP[k]}</FontFamily>')
    w("</ResourceDictionary>")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="fail if the committed XAML is stale")
    args = ap.parse_args()
    text = render()
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"stale: {OUT.relative_to(REPO).as_posix()} (run gen_xaml_tokens.py)", file=sys.stderr)
            return 1
        print("ok: token XAML matches tokens.css")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(REPO).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
