#!/usr/bin/env python3
"""Guard the files `.gitattributes` merges with `merge=union`.

A union merge keeps both sides of a conflicting hunk. For the append-only
records this repository unions (`openspec/changes/*/tasks.md`,
`rust/README.md`) that is the right answer for two slices adding lines at the
same anchor, and the wrong answer exactly when both sides carried the same
line — a bullet or a heading then appears twice — or when a conflict was
left unresolved. This check fails on either. It reads the working tree,
takes no options beyond `--self-test`, and never writes.

Exit code: 0 = clean; 1 = a duplicated bullet, a duplicated heading, or a
conflict marker.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFLICT_MARKERS = ("<<<<<<< ", "=======", ">>>>>>> ")


def unioned_files(root: Path) -> list[Path]:
    files = sorted(root.glob("openspec/changes/*/tasks.md"))
    readme = root / "rust" / "README.md"
    if readme.exists():
        files.append(readme)
    return files


# A union of two hunks that both added a line leaves the two copies next to
# each other (the same conflict region), so a repeat is looked for within this
# many lines; the same long bullet legitimately recurs across Task sections.
BULLET_WINDOW = 6


def problems_in(text: str, *, headings: bool, bullets: bool) -> list[str]:
    """The lines that a union merge must never produce."""
    found: list[str] = []
    recent_bullets: list[tuple[int, str]] = []
    seen_headings: dict[str, int] = {}
    for number, line in enumerate(text.split("\n"), start=1):
        if line.startswith(CONFLICT_MARKERS[0]) or line.startswith(CONFLICT_MARKERS[2]):
            found.append(f"line {number}: conflict marker left in place")
            continue
        if line == CONFLICT_MARKERS[1].rstrip():
            found.append(f"line {number}: conflict marker left in place")
            continue
        stripped = line.strip()
        if headings and stripped.startswith("## "):
            first = seen_headings.setdefault(stripped, number)
            if first != number:
                found.append(f"line {number}: heading repeats line {first}: {stripped[:80]}")
        # A record bullet is long; short list items ("- foo") recur legitimately.
        if bullets and stripped.startswith("- ") and len(stripped) >= 120:
            for earlier, text_seen in recent_bullets:
                if text_seen == stripped and number - earlier <= BULLET_WINDOW:
                    found.append(
                        f"line {number}: bullet repeats line {earlier}: {stripped[:80]}…"
                    )
                    break
            recent_bullets.append((number, stripped))
            recent_bullets = recent_bullets[-BULLET_WINDOW:]
    return found


def check(root: Path) -> list[str]:
    errors: list[str] = []
    for path in unioned_files(root):
        text = path.read_text(encoding="utf-8")
        is_readme = path.name == "README.md"
        for problem in problems_in(text, headings=is_readme, bullets=not is_readme):
            errors.append(f"ERROR {path.relative_to(root)}: {problem}")
    return errors


def self_test() -> None:
    clean = "# T\n\n- " + "x" * 130 + "\n- " + "y" * 130 + "\n## A\n## B\n"
    assert problems_in(clean, headings=True, bullets=True) == []
    duplicated = "- " + "x" * 130 + "\n- " + "x" * 130 + "\n"
    assert len(problems_in(duplicated, headings=False, bullets=True)) == 1
    apart = "- " + "x" * 130 + "\n" + "\n" * (BULLET_WINDOW + 1) + "- " + "x" * 130 + "\n"
    assert problems_in(apart, headings=False, bullets=True) == []
    assert problems_in("- ab\n- ab\n", headings=False, bullets=True) == []
    assert len(problems_in("## A\n\n## A\n", headings=True, bullets=False)) == 1
    marked = "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> theirs\n"
    assert len(problems_in(marked, headings=True, bullets=True)) == 3
    print("check_union_merge self-test: ok")


def main(argv: list[str]) -> int:
    if argv[1:] == ["--self-test"]:
        self_test()
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    errors = check(ROOT)
    for error in errors:
        print(error)
    if errors:
        print(f"check_union_merge: {len(errors)} error(s)")
        return 1
    print("check_union_merge: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
