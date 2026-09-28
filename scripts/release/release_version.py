#!/usr/bin/env python3
"""The macOS release's single version source and the copies kept in lockstep.

`scripts/release/release-version.json` names the release: `version` (the
App's CFBundleShortVersionString) and `build` (its CFBundleVersion). The App
and the Rust helper pair must carry exactly these two values: the App holds the
daemon to both in its XPC server requirement
(`Packages/ArkDeckKit/Sources/ArkDeckCore/AgentXPCContract.swift`,
`serverCodeRequirement`), so a helper from another build is a mismatch even at
the same marketing version. The copies:

- `ArkDeck.xcodeproj/project.pbxproj`: every `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` (the App target's Debug and Release);
- `ArkDeckApp/Info.plist`: must keep reading those two build settings;
- `Packages/ArkDeckKit/Distribution/macOS/ArkDeckCLI-Info.plist` and
  `ArkDeckAgent-Info.plist`: CFBundleShortVersionString and CFBundleVersion.
  `check-rust-helpers.py` compares these with the pbxproj pair.

Commands:
  check                 exit 0 when every copy equals the source, 1 naming each drift
  print                 the source as JSON
  bump-build            increment the integer build number and rewrite every copy
  set <version> <build> set both and rewrite every copy

The release version is the maintainer's choice; this tool only keeps the copies
equal. Both values are dot-separated decimal numbers of at most three parts,
the only form the App's server requirement accepts.
"""

from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

RELEASE = Path(__file__).resolve().parent
REPO = RELEASE.parents[1]
SOURCE = RELEASE / "release-version.json"
PROJECT = REPO / "ArkDeck.xcodeproj/project.pbxproj"
APP_INFO = REPO / "ArkDeckApp/Info.plist"
DISTRIBUTION = REPO / "Packages/ArkDeckKit/Distribution/macOS"
HELPER_INFOS = (
    DISTRIBUTION / "ArkDeckCLI-Info.plist",
    DISTRIBUTION / "ArkDeckAgent-Info.plist",
)
NUMBER = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
SETTING = {
    "version": re.compile(r"(\bMARKETING_VERSION = )([^;\s]+)(;)"),
    "build": re.compile(r"(\bCURRENT_PROJECT_VERSION = )([^;\s]+)(;)"),
}
PLIST_KEY = {"version": "CFBundleShortVersionString", "build": "CFBundleVersion"}
APP_INFO_VALUE = {"version": "$(MARKETING_VERSION)", "build": "$(CURRENT_PROJECT_VERSION)"}


class VersionError(RuntimeError):
    pass


def valid(value: object) -> bool:
    return isinstance(value, str) and NUMBER.fullmatch(value) is not None


def load(repo: Path = REPO) -> dict[str, str]:
    source = repo / SOURCE.relative_to(REPO)
    data = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"version", "build"}:
        raise VersionError(f"{source}: exactly the keys version and build are required")
    for key in ("version", "build"):
        if not valid(data[key]):
            raise VersionError(f"{source}: {key} {data[key]!r} is not a dot-separated number")
    return {"version": data["version"], "build": data["build"]}


def plist_pattern(key: str) -> re.Pattern[str]:
    return re.compile(rf"(<key>{key}</key>\s*<string>)([^<]*)(</string>)")


def drift(repo: Path = REPO) -> list[str]:
    """Each copy that differs from the source, named with what it holds."""
    expected = load(repo)
    problems: list[str] = []
    project = (repo / PROJECT.relative_to(REPO)).read_text(encoding="utf-8")
    for key, pattern in SETTING.items():
        values = [match.group(2) for match in pattern.finditer(project)]
        if not values:
            problems.append(f"project.pbxproj carries no {key} setting")
        for value in sorted(set(values)):
            if value != expected[key]:
                problems.append(f"project.pbxproj {key} {value} != {expected[key]}")
    app_info = plistlib.loads((repo / APP_INFO.relative_to(REPO)).read_bytes())
    for key, placeholder in APP_INFO_VALUE.items():
        if app_info.get(PLIST_KEY[key]) != placeholder:
            problems.append(
                f"ArkDeckApp/Info.plist {PLIST_KEY[key]} must stay {placeholder}, "
                f"is {app_info.get(PLIST_KEY[key])!r}"
            )
    for info in HELPER_INFOS:
        values = plistlib.loads((repo / info.relative_to(REPO)).read_bytes())
        for key, plist_key in PLIST_KEY.items():
            if values.get(plist_key) != expected[key]:
                problems.append(f"{info.name} {plist_key} {values.get(plist_key)!r} != {expected[key]}")
    return problems


def write(version: str, build: str, repo: Path = REPO) -> None:
    for key, value in (("version", version), ("build", build)):
        if not valid(value):
            raise VersionError(f"{key} {value!r} is not a dot-separated number of at most three parts")
    target = {"version": version, "build": build}
    project_path = repo / PROJECT.relative_to(REPO)
    project = project_path.read_text(encoding="utf-8")
    for key, pattern in SETTING.items():
        project, count = pattern.subn(lambda match, key=key: match.group(1) + target[key] + match.group(3), project)
        if count == 0:
            raise VersionError(f"project.pbxproj carries no {key} setting to rewrite")
    for info in HELPER_INFOS:
        path = repo / info.relative_to(REPO)
        text = path.read_text(encoding="utf-8")
        for key, plist_key in PLIST_KEY.items():
            text, count = plist_pattern(plist_key).subn(
                lambda match, key=key: match.group(1) + target[key] + match.group(3), text
            )
            if count != 1:
                raise VersionError(f"{info.name} must carry exactly one {plist_key}")
        path.write_text(text, encoding="utf-8")
    project_path.write_text(project, encoding="utf-8")
    (repo / SOURCE.relative_to(REPO)).write_text(
        json.dumps(target, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main(argv: list[str], repo: Path = REPO) -> int:
    try:
        if argv == ["check"]:
            problems = drift(repo)
            for problem in problems:
                print(f"version drift: {problem}", file=sys.stderr)
            if not problems:
                current = load(repo)
                print(f"release version {current['version']} ({current['build']}) in lockstep")
            return 1 if problems else 0
        if argv == ["print"]:
            print(json.dumps(load(repo), sort_keys=True))
            return 0
        if argv == ["bump-build"]:
            current = load(repo)
            if not current["build"].isdigit():
                raise VersionError(f"build {current['build']} is not a single integer; use set")
            write(current["version"], str(int(current["build"]) + 1), repo)
        elif len(argv) == 3 and argv[0] == "set":
            write(argv[1], argv[2], repo)
        else:
            print(__doc__.split("Commands:")[1].split("The release")[0].rstrip(), file=sys.stderr)
            return 2
        problems = drift(repo)
        if problems:
            raise VersionError("; ".join(problems))
        current = load(repo)
        print(f"release version {current['version']} ({current['build']})")
        return 0
    except (VersionError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"release_version: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
