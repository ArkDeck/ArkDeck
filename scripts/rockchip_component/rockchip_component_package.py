#!/usr/bin/env python3
"""Fail-closed ArkDeck Rockchip component release packager.

This tool accepts one explicitly supplied, already-reviewed unsigned component.
It never downloads, rebuilds, launches, installs, or resolves an executable from
PATH.  It stages the component, lets Xcode perform Code Sign On Copy, verifies
the nested code and App independently, creates and signs one DMG, submits that
outermost DMG for notarization, staples it, and verifies Gatekeeper acceptance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


REPO_ROOT = Path(__file__).resolve().parents[2]
INTEGRATION_ROOT = (
    REPO_ROOT / "openspec/integrations/rockchip/bundled-component/1.0.0"
)
PACKAGE_SPEC_PATH = INTEGRATION_ROOT / "package.json"
REGISTRY_PATH = INTEGRATION_ROOT / "registry.yaml"
APP_ENTITLEMENTS_PATH = REPO_ROOT / "ArkDeckApp/ArkDeckApp.entitlements"
COMPONENT_ENTITLEMENTS_PATH = (
    REPO_ROOT / "ArkDeckApp/RockchipComponent.entitlements"
)

SYSTEM_TOOLS = {
    "codesign": Path("/usr/bin/codesign"),
    "ditto": Path("/usr/bin/ditto"),
    "file": Path("/usr/bin/file"),
    "hdiutil": Path("/usr/bin/hdiutil"),
    "lipo": Path("/usr/bin/lipo"),
    "nm": Path("/usr/bin/nm"),
    "otool": Path("/usr/bin/otool"),
    "security": Path("/usr/bin/security"),
    "spctl": Path("/usr/sbin/spctl"),
    "strings": Path("/usr/bin/strings"),
    "xcodebuild": Path("/usr/bin/xcodebuild"),
    "xcrun": Path("/usr/bin/xcrun"),
}

FORBIDDEN_EXECUTABLES = {
    "bash",
    "env",
    "fish",
    "sh",
    "zsh",
}


class PackageError(RuntimeError):
    """A release invariant failed."""


@dataclass(frozen=True)
class CommandResult:
    argv0: str
    exit_code: int
    stdout: str
    stderr: str


class Runner:
    """Runs only absolute executable paths and sanitizes diagnostic failures."""

    def __init__(self, replacements: Mapping[str, str]) -> None:
        self._replacements = sorted(
            ((raw, safe) for raw, safe in replacements.items() if raw),
            key=lambda item: len(item[0]),
            reverse=True,
        )
        self.records: list[dict[str, Any]] = []

    def sanitize(self, value: str) -> str:
        sanitized = value
        for raw, safe in self._replacements:
            sanitized = sanitized.replace(raw, safe)
        sanitized = re.sub(
            r"/Users/[^/\s]+(?:/[^\s:'\"]+)*",
            "<USER_PATH>",
            sanitized,
        )
        return sanitized

    def run(
        self,
        argv: Sequence[str | Path],
        *,
        cwd: Path,
        env: Mapping[str, str],
        accepted: frozenset[int] = frozenset({0}),
        timeout: int = 1800,
    ) -> CommandResult:
        if not argv:
            raise PackageError("empty command is forbidden")
        actual = [str(item) for item in argv]
        executable = Path(actual[0])
        if not executable.is_absolute():
            raise PackageError("command executable must be an absolute path")
        if executable.name in FORBIDDEN_EXECUTABLES:
            raise PackageError("shell or env launcher is forbidden")
        if not executable.is_file():
            raise PackageError(f"required system tool is missing: {executable.name}")
        completed = subprocess.run(
            actual,
            cwd=str(cwd),
            env=dict(env),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
        stdout = completed.stdout.decode("utf-8", errors="replace")
        stderr = completed.stderr.decode("utf-8", errors="replace")
        self.records.append(
            {
                "tool": executable.name,
                "exitCode": completed.returncode,
                "stdoutSHA256": sha256_bytes(
                    self.sanitize(stdout).encode("utf-8")
                ),
                "stderrSHA256": sha256_bytes(
                    self.sanitize(stderr).encode("utf-8")
                ),
            }
        )
        if completed.returncode not in accepted:
            tail = self.sanitize((stderr or stdout)[-3000:])
            raise PackageError(
                f"{executable.name} failed with exit {completed.returncode}: {tail}"
            )
        return CommandResult(
            argv0=executable.name,
            exit_code=completed.returncode,
            stdout=stdout,
            stderr=stderr,
        )


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso8601(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def parse_iso8601(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackageError(f"invalid JSON input: {path.name}") from error
    if not isinstance(value, dict):
        raise PackageError(f"JSON root must be an object: {path.name}")
    return value


def load_plist(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise PackageError(f"invalid plist input: {path.name}") from error
    if not isinstance(value, dict):
        raise PackageError(f"plist root must be a dictionary: {path.name}")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PackageError(message)


def require_exact_keys(
    observed: Mapping[str, Any], expected: Mapping[str, Any], label: str
) -> None:
    require(dict(observed) == dict(expected), f"{label} set or value drift")


def ensure_regular_no_symlink(path: Path, label: str) -> os.stat_result:
    try:
        absolute = Path(os.path.abspath(str(path)))
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise PackageError(f"{label} is missing or unreadable") from error
    require(absolute == resolved, f"{label} contains a symlink or path alias")
    require(not stat.S_ISLNK(metadata.st_mode), f"{label} must not be a symlink")
    require(stat.S_ISREG(metadata.st_mode), f"{label} must be a regular file")
    return metadata


def ensure_outside_repository(path: Path, label: str) -> None:
    absolute = Path(os.path.abspath(str(path)))
    repo = REPO_ROOT.resolve()
    require(
        absolute != repo and repo not in absolute.parents,
        f"{label} must remain outside the repository",
    )


def closed_environment(work_root: Path) -> dict[str, str]:
    home = os.environ.get("HOME")
    require(bool(home), "HOME is unavailable for Keychain-backed release tooling")
    return {
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": str(work_root / "tmp"),
        "TZ": "UTC",
    }


def parse_architectures(output: str) -> list[str]:
    return sorted(set(output.strip().split()))


def parse_minos(output: str) -> str:
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_BUILD_VERSION":
            for candidate in lines[index + 1 : index + 12]:
                stripped = candidate.strip()
                if stripped.startswith("minos "):
                    return stripped.split(None, 1)[1]
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("minos "):
            return stripped.split(None, 1)[1]
    raise PackageError("LC_BUILD_VERSION/minos was not found")


def parse_dependencies(output: str) -> list[str]:
    dependencies: list[str] = []
    for line in output.splitlines()[1:]:
        stripped = line.strip()
        if stripped:
            dependencies.append(stripped.split(" (", 1)[0])
    return sorted(set(dependencies))


def normalize_load_commands(output: str) -> str:
    lines = output.splitlines()
    require(bool(lines), "otool load-command output is empty")
    lines[0] = "$OUTPUT_DIR/rkdeveloptool:"
    return "\n".join(lines) + ("\n" if output.endswith("\n") else "")


def inspect_unsigned_component(
    path: Path,
    *,
    runner: Runner,
    env: Mapping[str, str],
    spec: Mapping[str, Any],
    registry: Mapping[str, Any],
) -> dict[str, Any]:
    metadata = ensure_regular_no_symlink(path, "component input")
    before = (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)
    file_result = runner.run(
        [SYSTEM_TOOLS["file"], "-b", str(path)], cwd=path.parent, env=env
    )
    lipo_result = runner.run(
        [SYSTEM_TOOLS["lipo"], "-archs", str(path)], cwd=path.parent, env=env
    )
    load_result = runner.run(
        [SYSTEM_TOOLS["otool"], "-l", str(path)], cwd=path.parent, env=env
    )
    dependency_result = runner.run(
        [SYSTEM_TOOLS["otool"], "-L", str(path)], cwd=path.parent, env=env
    )
    strings_result = runner.run(
        [SYSTEM_TOOLS["strings"], "-a", str(path)], cwd=path.parent, env=env
    )
    signature_result = runner.run(
        [SYSTEM_TOOLS["codesign"], "-dv", "--verbose=4", str(path)],
        cwd=path.parent,
        env=env,
        accepted=frozenset({1}),
    )
    after_metadata = ensure_regular_no_symlink(path, "component input")
    after = (
        after_metadata.st_dev,
        after_metadata.st_ino,
        after_metadata.st_size,
        after_metadata.st_mtime_ns,
    )
    require(before == after, "component input identity changed during inspection")

    facts = {
        "exists": True,
        "regular": True,
        "symlink": False,
        "size": metadata.st_size,
        "sha256": sha256_file(path),
        "fileType": file_result.stdout.strip(),
        "architectures": parse_architectures(lipo_result.stdout),
        "minimumMacOS": parse_minos(load_result.stdout),
        "loadCommandsSHA256": sha256_bytes(
            normalize_load_commands(load_result.stdout).encode("utf-8")
        ),
        "dependencies": parse_dependencies(dependency_result.stdout),
        "signature": (
            "absent"
            if "code object is not signed at all"
            in (signature_result.stdout + signature_result.stderr)
            else "present"
        ),
        "versionFormatPresent": "rkdeveloptool ver %s" in strings_result.stdout,
        "versionLiteralPresent": str(spec["component"]["version"])
        in strings_result.stdout,
    }
    validate_unsigned_facts(facts, spec, registry)
    return facts


def validate_unsigned_facts(
    facts: Mapping[str, Any],
    spec: Mapping[str, Any],
    registry: Mapping[str, Any],
) -> None:
    expected = spec["component"]
    registered = registry["artifact"]
    require(facts.get("exists") is True, "component input is missing")
    require(facts.get("regular") is True, "component input is not regular")
    require(facts.get("symlink") is False, "component input is a symlink")
    require(facts.get("size") == expected["size"], "component input size drift")
    require(facts.get("sha256") == expected["sha256"], "component input hash drift")
    require(
        "Mach-O 64-bit executable arm64" in str(facts.get("fileType", "")),
        "component input Mach-O type drift",
    )
    require(
        facts.get("architectures") == expected["architectures"],
        "component input architecture drift",
    )
    require(
        facts.get("minimumMacOS") in (expected["minimumMacOS"], "14.0.0"),
        "component input minimum macOS drift",
    )
    require(
        facts.get("loadCommandsSHA256") == registered["loadCommandsSHA256"],
        "component input load-command drift",
    )
    require(
        facts.get("dependencies") == sorted(expected["dependencies"]),
        "component input dependency graph drift",
    )
    require(facts.get("signature") == "absent", "component input must be unsigned")
    require(
        facts.get("versionFormatPresent") is True
        and facts.get("versionLiteralPresent") is True,
        "component input version evidence drift",
    )


def plist_from_codesign_output(output: str) -> dict[str, Any]:
    marker = output.find(b"<?xml")
    if marker < 0:
        marker = output.find(b"bplist")
    require(marker >= 0, "codesign entitlement plist is absent")
    payload = output[marker:]
    if payload.startswith(b"<?xml"):
        end = payload.find(b"</plist>")
        require(end >= 0, "codesign entitlement XML is incomplete")
        payload = payload[: end + len(b"</plist>")]
    try:
        value = plistlib.loads(payload)
    except (ExpatError, plistlib.InvalidFileException, ValueError) as error:
        raise PackageError("codesign entitlement plist is malformed") from error
    require(isinstance(value, dict), "codesign entitlements are not a dictionary")
    return value


def extract_leaf_certificate_sha1(
    target: Path,
    *,
    label: str,
    certificate_root: Path,
    runner: Runner,
    env: Mapping[str, str],
) -> str:
    prefix = certificate_root / f"{label}-"
    runner.run(
        [
            SYSTEM_TOOLS["codesign"],
            "-d",
            f"--extract-certificates={prefix}",
            str(target),
        ],
        cwd=certificate_root,
        env=env,
    )
    leaf = Path(f"{prefix}0")
    ensure_regular_no_symlink(leaf, f"{label} leaf certificate")
    return sha1_file(leaf)


def inspect_signature(
    target: Path,
    *,
    label: str,
    expected_entitlements: Mapping[str, Any] | None,
    certificate_root: Path,
    runner: Runner,
    env: Mapping[str, str],
    extract_certificate: bool = True,
) -> dict[str, Any]:
    details_result = runner.run(
        [SYSTEM_TOOLS["codesign"], "-d", "--verbose=4", str(target)],
        cwd=target.parent,
        env=env,
    )
    details = details_result.stdout + details_result.stderr
    requirement_result = runner.run(
        [SYSTEM_TOOLS["codesign"], "-d", "-r-", str(target)],
        cwd=target.parent,
        env=env,
    )
    verification_args: list[str | Path] = [
        SYSTEM_TOOLS["codesign"],
        "--verify",
        "--strict",
        "--verbose=4",
        str(target),
    ]
    if target.suffix == ".app":
        verification_args.insert(2, "--deep")
    runner.run(verification_args, cwd=target.parent, env=env)

    entitlements: dict[str, Any] | None = None
    if expected_entitlements is not None:
        entitlements_result = runner.run(
            [
                SYSTEM_TOOLS["codesign"],
                "-d",
                "--entitlements",
                ":-",
                str(target),
            ],
            cwd=target.parent,
            env=env,
        )
        entitlement_bytes = (
            entitlements_result.stdout + entitlements_result.stderr
        ).encode("utf-8")
        entitlements = plist_from_codesign_output(entitlement_bytes)

    identifier_match = re.search(r"^Identifier=(.+)$", details, re.MULTILINE)
    team_match = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
    authority_match = re.search(r"^Authority=(.+)$", details, re.MULTILINE)
    timestamp_match = re.search(r"^Timestamp=(.+)$", details, re.MULTILINE)
    certificate_sha1 = None
    if extract_certificate:
        certificate_sha1 = extract_leaf_certificate_sha1(
            target,
            label=label,
            certificate_root=certificate_root,
            runner=runner,
            env=env,
        )
    facts = {
        "identifier": identifier_match.group(1).strip()
        if identifier_match
        else None,
        "teamIdentifier": team_match.group(1).strip() if team_match else None,
        "authority": authority_match.group(1).strip()
        if authority_match
        else None,
        "certificateSHA1": certificate_sha1,
        "hardenedRuntime": bool(re.search(r"flags=.*runtime", details)),
        "timestampPresent": bool(timestamp_match)
        and timestamp_match.group(1).strip().lower() != "none",
        "designatedRequirement": requirement_result.stdout
        + requirement_result.stderr,
        "entitlements": entitlements,
        "strictVerification": True,
    }
    if expected_entitlements is not None:
        require_exact_keys(
            entitlements or {}, expected_entitlements, f"{label} entitlement"
        )
    return facts


def inspect_macho(path: Path, runner: Runner, env: Mapping[str, str]) -> dict[str, Any]:
    lipo_result = runner.run(
        [SYSTEM_TOOLS["lipo"], "-archs", str(path)], cwd=path.parent, env=env
    )
    load_result = runner.run(
        [SYSTEM_TOOLS["otool"], "-l", str(path)], cwd=path.parent, env=env
    )
    return {
        "architectures": parse_architectures(lipo_result.stdout),
        "minimumMacOS": parse_minos(load_result.stdout),
    }


def verify_metadata_bundle(
    app: Path, spec: Mapping[str, Any]
) -> dict[str, str]:
    metadata_root = app / str(spec["metadata"]["bundlePath"])
    require(metadata_root.is_dir(), "bundled metadata directory is missing")
    expected = {
        str(item["name"]): str(item["sha256"])
        for item in spec["metadata"]["files"]
    }
    observed_names = sorted(item.name for item in metadata_root.iterdir())
    require(
        observed_names == sorted(expected),
        "bundled metadata file set drift",
    )
    observed: dict[str, str] = {}
    for name, expected_hash in expected.items():
        bundled = metadata_root / name
        source = INTEGRATION_ROOT / name
        ensure_regular_no_symlink(bundled, f"bundled metadata {name}")
        require(bundled.read_bytes() == source.read_bytes(), f"metadata drift: {name}")
        digest = sha256_file(bundled)
        require(digest == expected_hash, f"metadata hash drift: {name}")
        observed[name] = digest
    return observed


def nested_code_paths(app: Path) -> list[str]:
    paths: list[str] = []
    for candidate in sorted(app.rglob("*")):
        if candidate.is_symlink():
            raise PackageError("App bundle contains a symlink")
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(app).as_posix()
        mode = candidate.stat().st_mode
        if (
            relative.startswith("Contents/MacOS/")
            or relative.startswith("Contents/Frameworks/")
            or candidate.suffix in {".dylib", ".so", ".xpc", ".appex"}
            or bool(mode & 0o111)
        ):
            paths.append(relative)
    return sorted(paths)


def bundle_tree_sha256(root: Path) -> str:
    inventory: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        require(not stat.S_ISLNK(metadata.st_mode), "release tree contains a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            inventory.append({"path": relative + "/", "type": "directory"})
        elif stat.S_ISREG(metadata.st_mode):
            inventory.append(
                {
                    "path": relative,
                    "type": "file",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "size": metadata.st_size,
                    "sha256": sha256_file(path),
                }
            )
        else:
            raise PackageError("release tree contains a non-regular entry")
    return sha256_bytes(canonical_json_bytes(inventory))


def validate_archive_facts(
    facts: Mapping[str, Any], spec: Mapping[str, Any]
) -> None:
    app_expected = spec["app"]
    component_expected = spec["component"]
    signing = spec["signing"]
    app = facts["app"]
    component = facts["component"]

    require(
        component.get("bundlePath") == component_expected["bundlePath"],
        "nested component location drift",
    )
    require(
        component.get("identifier") == component_expected["identifier"],
        "nested component identifier drift",
    )
    require(
        component.get("architectures") == component_expected["architectures"],
        "nested component architecture drift",
    )
    require(
        component.get("minimumMacOS")
        in (component_expected["minimumMacOS"], "14.0.0"),
        "nested component minimum macOS drift",
    )
    require_exact_keys(
        component.get("entitlements") or {},
        component_expected["entitlements"],
        "nested component entitlement",
    )
    require(
        component.get("authority", "").startswith(signing["identityKind"]),
        "nested component signing identity kind drift",
    )
    require(
        component.get("teamIdentifier") == signing["teamIdentifier"],
        "nested component Team ID drift",
    )
    require(
        component.get("certificateSHA1") == signing["certificateSHA1"],
        "nested component certificate drift",
    )
    require(
        component.get("certificateValid") is True,
        "nested component certificate is expired or not yet valid",
    )
    require(
        component.get("chainTrusted") is True,
        "nested component signature chain is untrusted",
    )
    require(
        component.get("timestampPresent") is True,
        "nested component secure timestamp is absent",
    )
    require(
        component.get("hardenedRuntime") is True,
        "nested component Hardened Runtime is disabled",
    )
    require(
        component.get("strictVerification") is True,
        "nested component signature verification failed",
    )
    require(
        "anchor apple generic" in component.get("designatedRequirement", ""),
        "nested component designated requirement drift",
    )

    require(
        app.get("bundleIdentifier") == app_expected["bundleIdentifier"],
        "App bundle identifier drift",
    )
    require(app.get("version") == app_expected["version"], "App version drift")
    require(
        app.get("buildVersion") == app_expected["buildVersion"],
        "App build version drift",
    )
    require(
        app.get("architectures") == app_expected["architectures"],
        "App architecture drift",
    )
    require(
        app.get("minimumMacOS") in (app_expected["minimumMacOS"], "14.0.0"),
        "App minimum macOS drift",
    )
    require_exact_keys(
        app.get("entitlements") or {},
        app_expected["entitlements"],
        "App entitlement",
    )
    require(
        app.get("identifier") == app_expected["bundleIdentifier"],
        "App signing identifier drift",
    )
    require(
        app.get("authority", "").startswith(signing["identityKind"]),
        "App signing identity kind drift",
    )
    require(
        app.get("teamIdentifier") == signing["teamIdentifier"],
        "App Team ID drift",
    )
    require(
        app.get("certificateSHA1") == signing["certificateSHA1"],
        "App certificate drift",
    )
    require(app.get("certificateValid") is True, "App certificate validity failed")
    require(app.get("chainTrusted") is True, "App signature chain is untrusted")
    require(app.get("timestampPresent") is True, "App secure timestamp is absent")
    require(app.get("hardenedRuntime") is True, "App Hardened Runtime is disabled")
    require(
        app.get("strictVerification") is True,
        "App strict/deep signature verification failed",
    )
    require(
        "anchor apple generic" in app.get("designatedRequirement", ""),
        "App designated requirement drift",
    )
    require(
        component.get("teamIdentifier") == app.get("teamIdentifier")
        and component.get("certificateSHA1") == app.get("certificateSHA1"),
        "mixed App/component signing tuple",
    )

    expected_metadata = {
        str(item["name"]): str(item["sha256"])
        for item in spec["metadata"]["files"]
    }
    require(
        facts.get("metadata") == expected_metadata,
        "App metadata tuple drift",
    )
    expected_nested = sorted(
        [
            "Contents/MacOS/ArkDeck",
            str(component_expected["bundlePath"]),
        ]
    )
    require(
        facts.get("nestedCodePaths") == expected_nested,
        "extra or missing nested executable/dylib",
    )


def validate_dmg_facts(facts: Mapping[str, Any], spec: Mapping[str, Any]) -> None:
    signing = spec["signing"]
    distribution = spec["distribution"]
    require(facts.get("valid") is True, "DMG is malformed")
    require(facts.get("signed") is True, "DMG is unsigned")
    require(
        facts.get("rootEntries") == sorted(distribution["rootEntries"]),
        "DMG root layout drift",
    )
    require(
        facts.get("authority", "").startswith(signing["identityKind"]),
        "DMG signing identity kind drift",
    )
    require(
        facts.get("teamIdentifier") == signing["teamIdentifier"],
        "DMG Team ID drift",
    )
    require(
        facts.get("certificateSHA1") == signing["certificateSHA1"],
        "DMG certificate drift",
    )
    require(
        facts.get("timestampPresent") is True,
        "DMG secure timestamp is absent",
    )
    require(
        facts.get("strictVerification") is True,
        "DMG signature verification failed",
    )


def validate_notary_facts(facts: Mapping[str, Any]) -> None:
    require(facts.get("submissionId"), "notary submission ID is absent")
    require(facts.get("logPresent") is True, "notary log is absent")
    require(facts.get("status") == "Accepted", "notary submission was not Accepted")
    require(facts.get("logStatus") == "Accepted", "notary log status is not Accepted")
    require(facts.get("issueCount") == 0, "notary log contains issues")


def validate_final_facts(facts: Mapping[str, Any]) -> None:
    require(facts.get("stapleValid") is True, "staple validation failed")
    require(facts.get("dmgGatekeeper") is True, "DMG Gatekeeper assessment failed")
    require(facts.get("appGatekeeper") is True, "App Gatekeeper assessment failed")
    require(
        facts.get("mountedAppTreeSHA256") == facts.get("archiveAppTreeSHA256"),
        "DMG contained App differs from the verified archive",
    )


def validate_receipt(
    receipt: Mapping[str, Any], spec: Mapping[str, Any]
) -> None:
    require(receipt.get("schemaVersion") == "1.0.0", "receipt schema drift")
    require(receipt.get("packageId") == spec["packageId"], "receipt package ID drift")
    require(receipt.get("verdict") == "PASS", "receipt verdict is not PASS")
    expected_validation = {
        "archive": "PASS",
        "componentInput": "PASS",
        "dmg": "PASS",
        "gatekeeperApp": "PASS",
        "gatekeeperDMG": "PASS",
        "notary": "Accepted",
        "staple": "PASS",
    }
    require(
        receipt.get("validation") == expected_validation,
        "receipt validation matrix drift",
    )
    signing = receipt.get("signing")
    require(
        signing
        == {
            "certificateSHA1": spec["signing"]["certificateSHA1"],
            "hardenedRuntime": True,
            "identityKind": spec["signing"]["identityKind"],
            "secureTimestamp": True,
            "teamIdentifier": spec["signing"]["teamIdentifier"],
        },
        "receipt signing tuple drift",
    )
    source = receipt.get("sourceArtifact")
    require(isinstance(source, dict), "receipt source artifact is absent")
    for key, value in spec["sourceArtifact"].items():
        require(source.get(key) == value, f"receipt source artifact {key} drift")
    require(
        source.get("componentSHA256") == spec["component"]["sha256"],
        "receipt source component hash drift",
    )
    require(
        source.get("componentSize") == spec["component"]["size"],
        "receipt source component size drift",
    )
    tuple_value = receipt.get("tuple")
    require(isinstance(tuple_value, dict), "receipt atomic tuple is absent")
    require(
        tuple_value.get("app", {}).get("bundleIdentifier")
        == spec["app"]["bundleIdentifier"]
        and tuple_value.get("app", {}).get("version") == spec["app"]["version"]
        and tuple_value.get("app", {}).get("buildVersion")
        == spec["app"]["buildVersion"],
        "receipt App tuple drift",
    )
    require(
        tuple_value.get("component", {}).get("identifier")
        == spec["component"]["identifier"]
        and tuple_value.get("component", {}).get("unsignedSHA256")
        == spec["component"]["sha256"],
        "receipt component tuple drift",
    )
    expected_metadata = {
        str(item["name"]): str(item["sha256"])
        for item in spec["metadata"]["files"]
    }
    require(
        tuple_value.get("metadata") == expected_metadata,
        "receipt metadata/source/SBOM/notices tuple drift",
    )
    require(
        tuple_value.get("dmg", {}).get("name")
        == spec["distribution"]["dmgName"],
        "receipt DMG name drift",
    )
    require(
        bool(tuple_value.get("dmg", {}).get("sha256"))
        and int(tuple_value.get("dmg", {}).get("size", 0)) > 0,
        "receipt DMG identity is absent",
    )
    require(
        bool(tuple_value.get("notarySubmissionId")),
        "receipt notary submission ID is absent",
    )
    require(
        receipt.get("tupleSHA256") == sha256_bytes(canonical_json_bytes(tuple_value)),
        "receipt atomic tuple digest drift",
    )
    effects = receipt.get("effectCounters")
    require(
        isinstance(effects, dict)
        and bool(effects)
        and all(value == 0 for value in effects.values()),
        "receipt contains an unauthorized effect",
    )


def preflight_identity(
    *,
    runner: Runner,
    env: Mapping[str, str],
    spec: Mapping[str, Any],
    cwd: Path,
) -> dict[str, Any]:
    result = runner.run(
        [SYSTEM_TOOLS["security"], "find-identity", "-v", "-p", "codesigning"],
        cwd=cwd,
        env=env,
    )
    expected_hash = str(spec["signing"]["certificateSHA1"])
    developer_lines = [
        line
        for line in result.stdout.splitlines()
        if "Developer ID Application:" in line
    ]
    require(
        len(developer_lines) == 1,
        "release environment must expose exactly one Developer ID Application identity",
    )
    require(
        expected_hash in developer_lines[0],
        "Developer ID Application certificate SHA-1 drift",
    )
    now = utc_now()
    not_before = parse_iso8601(str(spec["signing"]["certificateNotBefore"]))
    not_after = parse_iso8601(str(spec["signing"]["certificateNotAfter"]))
    require(not_before <= now < not_after, "Developer ID certificate is not currently valid")
    return {
        "certificateSHA1": expected_hash,
        "certificateValid": True,
        "chainTrusted": True,
        "identityCount": 1,
        "teamIdentifier": spec["signing"]["teamIdentifier"],
    }


def preflight_notary_auth(
    *,
    profile: str,
    runner: Runner,
    env: Mapping[str, str],
    cwd: Path,
) -> None:
    result = runner.run(
        [
            SYSTEM_TOOLS["xcrun"],
            "notarytool",
            "history",
            "--keychain-profile",
            profile,
            "--output-format",
            "json",
        ],
        cwd=cwd,
        env=env,
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PackageError("notary authentication preflight returned invalid JSON") from error
    require(isinstance(payload, dict), "notary authentication preflight failed")


def inspect_app_archive(
    app: Path,
    *,
    work_root: Path,
    identity_facts: Mapping[str, Any],
    runner: Runner,
    env: Mapping[str, str],
    spec: Mapping[str, Any],
) -> dict[str, Any]:
    require(app.is_dir(), "Xcode archive App is missing")
    info = load_plist(app / "Contents/Info.plist")
    app_executable = app / "Contents/MacOS/ArkDeck"
    component = app / str(spec["component"]["bundlePath"])
    ensure_regular_no_symlink(app_executable, "App executable")
    ensure_regular_no_symlink(component, "nested component")

    certificate_root = work_root / "certificates"
    certificate_root.mkdir(mode=0o700)
    app_signature = inspect_signature(
        app,
        label="app",
        expected_entitlements=spec["app"]["entitlements"],
        certificate_root=certificate_root,
        runner=runner,
        env=env,
    )
    component_signature = inspect_signature(
        component,
        label="component",
        expected_entitlements=spec["component"]["entitlements"],
        certificate_root=certificate_root,
        runner=runner,
        env=env,
    )
    app_macho = inspect_macho(app_executable, runner, env)
    component_macho = inspect_macho(component, runner, env)
    metadata = verify_metadata_bundle(app, spec)

    app_facts = {
        **app_signature,
        **app_macho,
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "buildVersion": info.get("CFBundleVersion"),
        "certificateValid": identity_facts["certificateValid"],
        "chainTrusted": identity_facts["chainTrusted"],
    }
    component_facts = {
        **component_signature,
        **component_macho,
        "bundlePath": spec["component"]["bundlePath"],
        "certificateValid": identity_facts["certificateValid"],
        "chainTrusted": identity_facts["chainTrusted"],
    }
    facts = {
        "app": app_facts,
        "component": component_facts,
        "metadata": metadata,
        "nestedCodePaths": nested_code_paths(app),
        "appTreeSHA256": bundle_tree_sha256(app),
    }
    validate_archive_facts(facts, spec)
    return facts


def sanitize_notary_log(
    raw: Mapping[str, Any], submission_id: str, runner: Runner
) -> dict[str, Any]:
    raw_issues = raw.get("issues")
    if raw_issues is None:
        raw_issues = []
    require(isinstance(raw_issues, list), "notary issues field is malformed")
    issues: list[dict[str, Any]] = []
    for issue in raw_issues:
        require(isinstance(issue, dict), "notary issue is malformed")
        issues.append(
            {
                key: runner.sanitize(str(issue[key]))
                for key in (
                    "severity",
                    "code",
                    "path",
                    "message",
                    "docUrl",
                    "architecture",
                )
                if key in issue
            }
        )
    return {
        "archiveSHA256": raw.get("sha256"),
        "issueCount": len(issues),
        "issues": issues,
        "logFormatVersion": raw.get("logFormatVersion"),
        "schemaVersion": "1.0.0",
        "status": raw.get("status"),
        "statusCode": raw.get("statusCode"),
        "statusSummary": raw.get("statusSummary"),
        "submissionId": submission_id,
        "uploadDate": raw.get("uploadDate"),
    }


def attach_dmg(
    dmg: Path,
    mountpoint: Path,
    *,
    runner: Runner,
    env: Mapping[str, str],
) -> str:
    result = runner.run(
        [
            SYSTEM_TOOLS["hdiutil"],
            "attach",
            "-readonly",
            "-nobrowse",
            "-mountpoint",
            str(mountpoint),
            "-plist",
            str(dmg),
        ],
        cwd=dmg.parent,
        env=env,
    )
    try:
        payload = plistlib.loads(result.stdout.encode("utf-8"))
    except plistlib.InvalidFileException as error:
        raise PackageError("hdiutil attach returned malformed plist") from error
    for entity in payload.get("system-entities", []):
        if entity.get("mount-point") == str(mountpoint) and entity.get("dev-entry"):
            return str(entity["dev-entry"])
    raise PackageError("hdiutil attach did not return the requested mount")


def build_release(
    *,
    component_input: Path,
    notary_profile: str,
    output_root: Path,
) -> dict[str, Any]:
    spec = load_json(PACKAGE_SPEC_PATH)
    registry = load_json(REGISTRY_PATH)
    require(
        spec.get("schemaVersion") == "1.0.0",
        "unsupported package contract schema",
    )
    require(
        registry["artifact"]["sha256"] == spec["component"]["sha256"],
        "package/registry component tuple drift",
    )
    require(
        registry["artifact"]["dependencies"]
        == spec["component"]["dependencies"],
        "package/registry dependency tuple drift",
    )
    require_exact_keys(
        load_plist(APP_ENTITLEMENTS_PATH),
        spec["app"]["entitlements"],
        "source App entitlement",
    )
    require_exact_keys(
        load_plist(COMPONENT_ENTITLEMENTS_PATH),
        spec["component"]["entitlements"],
        "source component entitlement",
    )
    ensure_outside_repository(component_input, "component input")
    ensure_outside_repository(output_root, "release output")
    require(not output_root.exists(), "release output must be a fresh path")

    created_output = False
    try:
        output_root.mkdir(parents=False, mode=0o700)
        created_output = True
        with tempfile.TemporaryDirectory(
            prefix="arkdeck-brc-003-", dir="/private/tmp"
        ) as temporary:
            work_root = Path(temporary)
            (work_root / "tmp").mkdir(mode=0o700)
            env = closed_environment(work_root)
            runner = Runner(
                {
                    str(component_input): "<COMPONENT_INPUT>",
                    str(work_root): "<WORK_ROOT>",
                    str(output_root): "<OUTPUT_ROOT>",
                    notary_profile: "<NOTARY_PROFILE>",
                }
            )

            unsigned_facts = inspect_unsigned_component(
                component_input,
                runner=runner,
                env=env,
                spec=spec,
                registry=registry,
            )
            identity_facts = preflight_identity(
                runner=runner, env=env, spec=spec, cwd=work_root
            )
            preflight_notary_auth(
                profile=notary_profile, runner=runner, env=env, cwd=work_root
            )

            staged_component = work_root / "stage/rkdeveloptool"
            staged_component.parent.mkdir(mode=0o700)
            shutil.copyfile(component_input, staged_component, follow_symlinks=False)
            os.chmod(staged_component, 0o755)
            require(
                sha256_file(staged_component) == spec["component"]["sha256"],
                "staged component hash drift before ad-hoc signing",
            )
            runner.run(
                [
                    SYSTEM_TOOLS["codesign"],
                    "--force",
                    "--sign",
                    "-",
                    "--identifier",
                    spec["component"]["identifier"],
                    "--options",
                    "runtime",
                    "--entitlements",
                    COMPONENT_ENTITLEMENTS_PATH,
                    str(staged_component),
                ],
                cwd=work_root,
                env=env,
            )
            adhoc_cert_root = work_root / "adhoc-certificates"
            adhoc_cert_root.mkdir(mode=0o700)
            adhoc = inspect_signature(
                staged_component,
                label="adhoc-component",
                expected_entitlements=spec["component"]["entitlements"],
                certificate_root=adhoc_cert_root,
                runner=runner,
                env=env,
                extract_certificate=False,
            )
            require(
                adhoc["identifier"] == spec["component"]["identifier"],
                "ad-hoc staging identifier drift",
            )
            require(
                adhoc["hardenedRuntime"] is True,
                "ad-hoc staging Hardened Runtime is absent",
            )
            require(
                adhoc["teamIdentifier"] in (None, "not set"),
                "ad-hoc staging unexpectedly has a Team ID",
            )

            derived_data = work_root / "DerivedData"
            source_packages = work_root / "SourcePackages"
            archive = work_root / "ArkDeck.xcarchive"
            runner.run(
                [
                    SYSTEM_TOOLS["xcodebuild"],
                    "-project",
                    REPO_ROOT / spec["xcode"]["project"],
                    "-scheme",
                    spec["xcode"]["scheme"],
                    "-configuration",
                    spec["xcode"]["archiveConfiguration"],
                    "-destination",
                    "generic/platform=macOS",
                    "-derivedDataPath",
                    derived_data,
                    "-clonedSourcePackagesDirPath",
                    source_packages,
                    "-archivePath",
                    archive,
                    "-disableAutomaticPackageResolution",
                    "archive",
                    f"ROCKCHIP_COMPONENT_INPUT={staged_component}",
                    "ARCHS=arm64",
                    "ONLY_ACTIVE_ARCH=NO",
                    "CODE_SIGN_STYLE=Manual",
                    f"CODE_SIGN_IDENTITY={spec['signing']['certificateSHA1']}",
                    f"DEVELOPMENT_TEAM={spec['signing']['teamIdentifier']}",
                    "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
                    "ENABLE_HARDENED_RUNTIME=YES",
                    "OTHER_CODE_SIGN_FLAGS=--timestamp",
                ],
                cwd=REPO_ROOT,
                env=env,
            )
            app = archive / "Products/Applications/ArkDeck.app"
            archive_facts = inspect_app_archive(
                app,
                work_root=work_root,
                identity_facts=identity_facts,
                runner=runner,
                env=env,
                spec=spec,
            )

            dmg_root = work_root / "dmg-root"
            dmg_root.mkdir(mode=0o755)
            runner.run(
                [
                    SYSTEM_TOOLS["ditto"],
                    "--rsrc",
                    "--extattr",
                    "--noqtn",
                    str(app),
                    str(dmg_root / "ArkDeck.app"),
                ],
                cwd=work_root,
                env=env,
            )
            shutil.copyfile(
                INTEGRATION_ROOT / "THIRD-PARTY-NOTICES.txt",
                dmg_root / "THIRD-PARTY-NOTICES.txt",
            )
            os.chmod(dmg_root / "THIRD-PARTY-NOTICES.txt", 0o644)
            source_date_epoch = int(registry["build"]["sourceDateEpoch"])
            for path in sorted(dmg_root.rglob("*"), reverse=True):
                os.utime(path, (source_date_epoch, source_date_epoch), follow_symlinks=False)
            os.utime(
                dmg_root,
                (source_date_epoch, source_date_epoch),
                follow_symlinks=False,
            )
            require(
                sorted(item.name for item in dmg_root.iterdir())
                == sorted(spec["distribution"]["rootEntries"]),
                "DMG staging root layout drift",
            )

            dmg = output_root / spec["distribution"]["dmgName"]
            runner.run(
                [
                    SYSTEM_TOOLS["hdiutil"],
                    "create",
                    "-srcfolder",
                    str(dmg_root),
                    "-volname",
                    spec["distribution"]["volumeName"],
                    "-fs",
                    spec["distribution"]["dmgFilesystem"],
                    "-format",
                    spec["distribution"]["dmgFormat"],
                    "-imagekey",
                    "zlib-level=9",
                    "-ov",
                    str(dmg),
                ],
                cwd=work_root,
                env=env,
            )
            runner.run(
                [
                    SYSTEM_TOOLS["codesign"],
                    "--force",
                    "--sign",
                    spec["signing"]["certificateSHA1"],
                    "--timestamp",
                    str(dmg),
                ],
                cwd=output_root,
                env=env,
            )
            runner.run(
                [SYSTEM_TOOLS["hdiutil"], "verify", str(dmg)],
                cwd=output_root,
                env=env,
            )
            dmg_cert_root = work_root / "dmg-certificates"
            dmg_cert_root.mkdir(mode=0o700)
            dmg_signature = inspect_signature(
                dmg,
                label="dmg",
                expected_entitlements=None,
                certificate_root=dmg_cert_root,
                runner=runner,
                env=env,
            )
            dmg_facts = {
                **dmg_signature,
                "valid": True,
                "signed": True,
                "rootEntries": sorted(spec["distribution"]["rootEntries"]),
            }
            validate_dmg_facts(dmg_facts, spec)

            preflight_notary_auth(
                profile=notary_profile, runner=runner, env=env, cwd=work_root
            )
            submit_result = runner.run(
                [
                    SYSTEM_TOOLS["xcrun"],
                    "notarytool",
                    "submit",
                    str(dmg),
                    "--keychain-profile",
                    notary_profile,
                    "--wait",
                    "--output-format",
                    "json",
                ],
                cwd=output_root,
                env=env,
                timeout=3600,
            )
            try:
                submit = json.loads(submit_result.stdout)
            except json.JSONDecodeError as error:
                raise PackageError("notary submission returned invalid JSON") from error
            submission_id = str(submit.get("id", ""))
            require(submit.get("status") == "Accepted", "notary submission was not Accepted")
            require(bool(submission_id), "notary submission ID is absent")

            raw_log_path = work_root / "notary-log-raw.json"
            runner.run(
                [
                    SYSTEM_TOOLS["xcrun"],
                    "notarytool",
                    "log",
                    submission_id,
                    str(raw_log_path),
                    "--keychain-profile",
                    notary_profile,
                ],
                cwd=work_root,
                env=env,
            )
            raw_log = load_json(raw_log_path)
            sanitized_log = sanitize_notary_log(raw_log, submission_id, runner)
            notary_facts = {
                "submissionId": submission_id,
                "status": submit.get("status"),
                "logPresent": True,
                "logStatus": sanitized_log.get("status"),
                "issueCount": sanitized_log.get("issueCount"),
            }
            validate_notary_facts(notary_facts)

            runner.run(
                [SYSTEM_TOOLS["xcrun"], "stapler", "staple", str(dmg)],
                cwd=output_root,
                env=env,
            )
            runner.run(
                [SYSTEM_TOOLS["xcrun"], "stapler", "validate", str(dmg)],
                cwd=output_root,
                env=env,
            )
            runner.run(
                [
                    SYSTEM_TOOLS["spctl"],
                    "-a",
                    "-t",
                    "open",
                    "--context",
                    "context:primary-signature",
                    "-v",
                    str(dmg),
                ],
                cwd=output_root,
                env=env,
            )

            mountpoint = work_root / "mounted"
            mountpoint.mkdir(mode=0o700)
            device: str | None = None
            mounted_app_tree = ""
            try:
                device = attach_dmg(dmg, mountpoint, runner=runner, env=env)
                mounted_app = mountpoint / "ArkDeck.app"
                runner.run(
                    [
                        SYSTEM_TOOLS["codesign"],
                        "--verify",
                        "--deep",
                        "--strict",
                        "--verbose=4",
                        str(mounted_app),
                    ],
                    cwd=mountpoint,
                    env=env,
                )
                runner.run(
                    [
                        SYSTEM_TOOLS["spctl"],
                        "-a",
                        "-t",
                        "exec",
                        "-v",
                        str(mounted_app),
                    ],
                    cwd=mountpoint,
                    env=env,
                )
                mounted_app_tree = bundle_tree_sha256(mounted_app)
            finally:
                if device is not None:
                    runner.run(
                        [SYSTEM_TOOLS["hdiutil"], "detach", device],
                        cwd=work_root,
                        env=env,
                    )

            final_facts = {
                "stapleValid": True,
                "dmgGatekeeper": True,
                "appGatekeeper": True,
                "archiveAppTreeSHA256": archive_facts["appTreeSHA256"],
                "mountedAppTreeSHA256": mounted_app_tree,
            }
            validate_final_facts(final_facts)

            final_dmg_sha256 = sha256_file(dmg)
            tuple_value = {
                "app": {
                    "bundleIdentifier": spec["app"]["bundleIdentifier"],
                    "version": spec["app"]["version"],
                    "buildVersion": spec["app"]["buildVersion"],
                    "treeSHA256": archive_facts["appTreeSHA256"],
                },
                "component": {
                    "identifier": spec["component"]["identifier"],
                    "unsignedSHA256": unsigned_facts["sha256"],
                    "signedSHA256": sha256_file(
                        app / spec["component"]["bundlePath"]
                    ),
                },
                "dmg": {
                    "name": dmg.name,
                    "sha256": final_dmg_sha256,
                    "size": dmg.stat().st_size,
                },
                "metadata": archive_facts["metadata"],
                "notarySubmissionId": submission_id,
            }
            receipt = {
                "effectCounters": {
                    "appLaunch": 0,
                    "componentLaunch": 0,
                    "deviceMutation": 0,
                    "dmgInstall": 0,
                    "e1Dispatch": 0,
                    "e2Dispatch": 0,
                    "hdcAccess": 0,
                    "releaseUpload": 0,
                    "usbAccess": 0,
                },
                "generatedAt": iso8601(utc_now()),
                "packageId": spec["packageId"],
                "schemaVersion": "1.0.0",
                "signing": {
                    "certificateSHA1": spec["signing"]["certificateSHA1"],
                    "hardenedRuntime": True,
                    "identityKind": spec["signing"]["identityKind"],
                    "secureTimestamp": True,
                    "teamIdentifier": spec["signing"]["teamIdentifier"],
                },
                "sourceArtifact": {
                    **spec["sourceArtifact"],
                    "componentSHA256": unsigned_facts["sha256"],
                    "componentSize": unsigned_facts["size"],
                },
                "tuple": tuple_value,
                "tupleSHA256": sha256_bytes(canonical_json_bytes(tuple_value)),
                "validation": {
                    "archive": "PASS",
                    "componentInput": "PASS",
                    "dmg": "PASS",
                    "gatekeeperApp": "PASS",
                    "gatekeeperDMG": "PASS",
                    "notary": "Accepted",
                    "staple": "PASS",
                },
                "verdict": "PASS",
            }
            validate_receipt(receipt, spec)
            (output_root / "package-receipt.json").write_bytes(
                canonical_json_bytes(receipt)
            )
            (output_root / "notary-log.json").write_bytes(
                canonical_json_bytes(sanitized_log)
            )
            return receipt
    except BaseException:
        if created_output and output_root.exists():
            shutil.rmtree(output_root)
        raise


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build, sign, notarize, staple, and verify the ArkDeck DMG."
    )
    parser.add_argument(
        "--component",
        required=True,
        type=Path,
        help="Absolute path to the exact unsigned rkdeveloptool artifact.",
    )
    parser.add_argument(
        "--notary-profile",
        required=True,
        help="Keychain profile name; treated as a secret and never persisted.",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Fresh output directory outside the repository.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        require(
            arguments.component.is_absolute(),
            "--component must be an absolute path",
        )
        require(arguments.output.is_absolute(), "--output must be an absolute path")
        receipt = build_release(
            component_input=arguments.component,
            notary_profile=arguments.notary_profile,
            output_root=arguments.output,
        )
    except (OSError, PackageError, subprocess.SubprocessError) as error:
        print(f"release packaging failed closed: {error}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {
                "dmgSHA256": receipt["tuple"]["dmg"]["sha256"],
                "notaryStatus": receipt["validation"]["notary"],
                "tupleSHA256": receipt["tupleSHA256"],
                "verdict": receipt["verdict"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
