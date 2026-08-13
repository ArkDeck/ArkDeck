#!/usr/bin/env python3
"""Pinned, unsigned Rockchip component build for TASK-BRC-002.

The produced executable is inspected as data and is never launched. External
commands are always invoked as an executable plus an argument array.
"""

from __future__ import annotations

import argparse
import bz2
import contextlib
import dataclasses
import datetime as dt
import gzip
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Optional, Sequence, Set, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
INTEGRATION_DIR = (
    REPO_ROOT
    / "openspec"
    / "integrations"
    / "rockchip"
    / "bundled-component"
    / "1.0.0"
)
RECIPE_PATH = INTEGRATION_DIR / "recipe.json"
OUTPUT_METADATA = (
    "THIRD-PARTY-NOTICES.txt",
    "source-distribution-manifest.json",
    "sbom.spdx.json",
    "registry.yaml",
)
RKDEVELOPTOOL_CXX_STANDARD = "c++23"
SOURCE_DATE_EPOCH = 1779028641
FIXED_CREATED = "2026-05-17T14:37:21Z"
MAX_ARCHIVE_MEMBER_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 256 * 1024 * 1024
ALLOWED_DOWNLOAD_HOSTS = frozenset(
    {
        "codeload.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "release-assets.githubusercontent.com",
    }
)
SANDBOX_PROFILE = """(version 1)
(allow default)
(deny network*)
(deny file-read* (subpath "/opt/homebrew"))
(deny file-read* (subpath "/usr/local"))
"""
SENSITIVE_MARKERS = (
    "/Users/",
    "/private/tmp/",
    "/var/folders/",
    "BEGIN PRIVATE KEY",
    "AKIA",
    "ghp_",
    "github_pat_",
    "notarytool-password",
)


class BuildError(RuntimeError):
    """A fail-closed build or validation failure."""


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def write_canonical_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json_bytes(value))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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
    return digest.hexdigest()


def git_blob_oid(path: Path) -> str:
    data = path.read_bytes()
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def load_recipe(path: Path = RECIPE_PATH) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildError("recipe is unreadable or invalid JSON: {}".format(error)) from error
    if value.get("schemaVersion") != "1.0.0":
        raise BuildError("unsupported recipe schemaVersion")
    if value.get("recipeId") != "rockchip-component-build@1.0.0":
        raise BuildError("unexpected recipe identity")
    if value["reproducibility"]["normalization"] != "forbidden":
        raise BuildError("output normalization must remain forbidden")
    if value["reproducibility"]["cleanBuilders"] != 2:
        raise BuildError("exactly two clean builders are required")
    return value


def ensure_fresh_directory(path: Path) -> None:
    if path.exists():
        if not path.is_dir():
            raise BuildError("requested root is not a directory")
        if any(path.iterdir()):
            raise BuildError("requested root must be empty")
    else:
        path.mkdir(parents=True)


def assert_under(path: Path, root: Path) -> None:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise BuildError("path escapes the owned build root") from error


def _url_without_query(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def _assert_allowed_https_url(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https":
        raise BuildError("only HTTPS source URLs are allowed")
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_DOWNLOAD_HOSTS:
        raise BuildError("source URL host is not allowlisted: {}".format(host))
    if parsed.username or parsed.password:
        raise BuildError("source URL credentials are forbidden")


class _PinnedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Mapping[str, str],
        newurl: str,
    ) -> Optional[urllib.request.Request]:
        _assert_allowed_https_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _download_asset(asset: Mapping[str, Any], destination: Path) -> Dict[str, Any]:
    url = str(asset["url"])
    _assert_allowed_https_url(url)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        _PinnedRedirectHandler(),
    )
    request = urllib.request.Request(url, headers={"User-Agent": "ArkDeck-TASK-BRC-002/1.0"})
    temporary = destination.with_suffix(destination.suffix + ".part")
    digest = hashlib.sha256()
    size = 0
    try:
        with opener.open(request, timeout=60) as response, temporary.open("wb") as output:
            final_url = response.geturl()
            _assert_allowed_https_url(final_url)
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > int(asset["size"]):
                    raise BuildError("download exceeded pinned size")
                digest.update(chunk)
                output.write(chunk)
    except (OSError, urllib.error.URLError) as error:
        temporary.unlink(missing_ok=True)
        raise BuildError("source download failed: {}".format(error)) from error
    observed = digest.hexdigest()
    if size != int(asset["size"]) or observed != asset["sha256"]:
        temporary.unlink(missing_ok=True)
        raise BuildError("download size/hash did not match the accepted pin")
    os.replace(str(temporary), str(destination))
    return {
        "finalURL": _url_without_query(final_url),
        "filename": destination.name,
        "sha256": observed,
        "size": size,
        "sourceURL": url,
    }


def fetch_inputs(recipe: Mapping[str, Any], input_dir: Path) -> Dict[str, Any]:
    ensure_fresh_directory(input_dir)
    assets: List[Tuple[str, Mapping[str, Any]]] = [
        ("rkdeveloptoolArchive", recipe["inputs"]["rkdeveloptool"]["archive"]),
        ("libusbArchive", recipe["inputs"]["libusb"]["archive"]),
        ("libusbSignature", recipe["inputs"]["libusb"]["signature"]),
        ("libusbKeys", recipe["inputs"]["libusb"]["keys"]),
    ]
    result: Dict[str, Any] = {}
    for name, asset in assets:
        result[name] = _download_asset(asset, input_dir / str(asset["filename"]))
    return result


def verify_file_pin(path: Path, pin: Mapping[str, Any]) -> None:
    if not path.is_file():
        raise BuildError("pinned input is missing: {}".format(path.name))
    size = path.stat().st_size
    digest = sha256_file(path)
    if size != int(pin["size"]):
        raise BuildError("{} size drift".format(path.name))
    if digest != pin["sha256"]:
        raise BuildError("{} SHA-256 drift".format(path.name))


def _closed_gpg_environment(home: Path) -> Dict[str, str]:
    return {
        "GNUPGHOME": str(home),
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TZ": "UTC",
    }


def _run_raw(
    argv: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    timeout: int = 600,
    accepted_exit_codes: Set[int] = frozenset({0}),
) -> subprocess.CompletedProcess:
    completed = subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd else None,
        env=dict(env) if env is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )
    if completed.returncode not in accepted_exit_codes:
        stderr = completed.stderr.decode("utf-8", errors="replace")[-4000:]
        raise BuildError("command failed ({}): {}".format(completed.returncode, stderr))
    return completed


def verify_libusb_signature(recipe: Mapping[str, Any], input_dir: Path, key_home: Path) -> Dict[str, Any]:
    libusb = recipe["inputs"]["libusb"]
    archive = input_dir / libusb["archive"]["filename"]
    signature = input_dir / libusb["signature"]["filename"]
    keys = input_dir / libusb["keys"]["filename"]
    verify_file_pin(archive, libusb["archive"])
    verify_file_pin(signature, libusb["signature"])
    verify_file_pin(keys, libusb["keys"])

    key_home.mkdir(parents=True, mode=0o700)
    os.chmod(str(key_home), 0o700)
    env = _closed_gpg_environment(key_home)
    gpg = recipe["builder"]["gpg"]["absolutePath"]
    gpgv = recipe["builder"]["gpgv"]["absolutePath"]
    _run_raw(
        [
            gpg,
            "--batch",
            "--no-options",
            "--no-autostart",
            "--homedir",
            str(key_home),
            "--import-options",
            "import-minimal",
            "--import",
            str(keys),
        ],
        env=env,
    )
    fingerprints = _run_raw(
        [
            gpg,
            "--batch",
            "--no-options",
            "--no-autostart",
            "--homedir",
            str(key_home),
            "--with-colons",
            "--fingerprint",
            "--fingerprint",
        ],
        env=env,
    ).stdout.decode("utf-8", errors="strict")
    observed_fingerprints = {
        fields[9]
        for line in fingerprints.splitlines()
        if (fields := line.split(":"))[0] == "fpr" and len(fields) > 9
    }
    expected_primary = libusb["signature"]["primaryFingerprint"]
    expected_signing = libusb["signature"]["signingFingerprint"]
    if expected_primary not in observed_fingerprints or expected_signing not in observed_fingerprints:
        raise BuildError("libusb KEYS did not contain both pinned fingerprints")

    status = _run_raw(
        [
            gpgv,
            "--keyring",
            str(key_home / "pubring.kbx"),
            "--status-fd",
            "1",
            str(signature),
            str(archive),
        ],
        env=env,
    ).stdout.decode("utf-8", errors="strict")
    if "[GNUPG:] GOODSIG {}".format(expected_signing[-16:]) not in status:
        raise BuildError("libusb signature did not produce the pinned GOODSIG")
    valid_pattern = re.compile(
        r"^\[GNUPG:\] VALIDSIG {} .+ {}$".format(
            re.escape(expected_signing),
            re.escape(expected_primary),
        ),
        re.MULTILINE,
    )
    if not valid_pattern.search(status):
        raise BuildError("libusb signature did not produce the pinned VALIDSIG")
    return {
        "primaryFingerprint": expected_primary,
        "signingFingerprint": expected_signing,
        "verdict": "GOODSIG+VALIDSIG",
    }


@dataclasses.dataclass(frozen=True)
class ArchiveMember:
    path: str
    kind: str
    mode: int
    size: int


def _canonical_archive_path(name: str) -> Tuple[str, str]:
    if "\x00" in name or "\\" in name:
        raise BuildError("archive path contains forbidden bytes")
    stripped = name[:-1] if name.endswith("/") else name
    if not stripped or stripped.startswith("/"):
        raise BuildError("archive path is empty or absolute")
    normalized_unicode = unicodedata.normalize("NFC", stripped)
    if normalized_unicode != stripped:
        raise BuildError("archive path is not NFC canonical")
    pure = PurePosixPath(stripped)
    if any(part in ("", ".", "..") for part in pure.parts):
        raise BuildError("archive path contains traversal/non-canonical component")
    canonical = str(pure)
    if canonical != stripped:
        raise BuildError("archive path is not canonical")
    key = unicodedata.normalize("NFC", canonical).casefold()
    return canonical, key


def validate_archive(path: Path, expected_root: str) -> List[ArchiveMember]:
    members: List[ArchiveMember] = []
    keys: Set[str] = set()
    roots: Set[str] = set()
    total = 0
    try:
        archive = tarfile.open(path, mode="r:*")
    except (OSError, tarfile.TarError) as error:
        raise BuildError("archive cannot be opened: {}".format(error)) from error
    with archive:
        for member in archive:
            canonical, key = _canonical_archive_path(member.name)
            if key in keys:
                raise BuildError("archive contains duplicate normalized path")
            keys.add(key)
            root = PurePosixPath(canonical).parts[0]
            roots.add(root)
            if roots != {expected_root}:
                raise BuildError("archive contains an unexpected or second root")
            if member.mode & 0o7000:
                raise BuildError("archive member contains privilege mode bits")
            if member.isdir():
                kind = "directory"
                size = 0
            elif member.isfile():
                kind = "file"
                size = int(member.size)
                if size < 0 or size > MAX_ARCHIVE_MEMBER_BYTES:
                    raise BuildError("archive member size is outside the bound")
                total += size
                if total > MAX_ARCHIVE_TOTAL_BYTES:
                    raise BuildError("archive expanded size exceeds the bound")
            else:
                raise BuildError("archive contains a link or special member")
            members.append(ArchiveMember(canonical, kind, member.mode, size))
    if not members or roots != {expected_root}:
        raise BuildError("archive root is missing")
    return members


def extract_archive(path: Path, expected_root: str, destination: Path) -> List[Dict[str, Any]]:
    records = validate_archive(path, expected_root)
    ensure_fresh_directory(destination)
    by_path = {record.path: record for record in records}
    inventory: List[Dict[str, Any]] = []
    with tarfile.open(path, mode="r:*") as archive:
        for member in archive:
            canonical, _ = _canonical_archive_path(member.name)
            record = by_path[canonical]
            target = destination.joinpath(*PurePosixPath(canonical).parts)
            assert_under(target, destination)
            if record.kind == "directory":
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(str(target), 0o755)
                os.utime(str(target), (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise BuildError("regular archive member has no readable bytes")
            with source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            os.chmod(str(target), 0o755 if record.mode & 0o111 else 0o644)
            os.utime(str(target), (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))
            inventory.append(
                {
                    "path": str(PurePosixPath(canonical).relative_to(expected_root)),
                    "sha1": sha1_file(target),
                    "sha256": sha256_file(target),
                    "size": target.stat().st_size,
                }
            )
    return sorted(inventory, key=lambda item: item["path"].encode("utf-8"))


def _decode(completed: subprocess.CompletedProcess, stream: str = "stdout") -> str:
    data = completed.stdout if stream == "stdout" else completed.stderr
    return data.decode("utf-8", errors="replace")


def _require_exact_fact(name: str, observed: Any, expected: Any) -> None:
    if observed != expected:
        raise BuildError(
            "{} drift: observed={!r} expected={!r}".format(
                name,
                observed,
                expected,
            )
        )


def inspect_toolchain(recipe: Mapping[str, Any]) -> Dict[str, Any]:
    expected = recipe["builder"]
    developer_dir = Path(
        os.environ.get(
            "DEVELOPER_DIR",
            _decode(_run_raw(["/usr/bin/xcode-select", "-p"])).strip(),
        )
    ).resolve()
    if str(developer_dir) not in expected["developerDirectoryAllowlist"]:
        raise BuildError("DEVELOPER_DIR is not in the readiness allowlist")
    env = {
        "DEVELOPER_DIR": str(developer_dir),
        "HOME": "/private/tmp",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TZ": "UTC",
    }

    os_version = _decode(_run_raw(["/usr/bin/sw_vers", "-productVersion"], env=env)).strip()
    os_build = _decode(_run_raw(["/usr/bin/sw_vers", "-buildVersion"], env=env)).strip()
    architecture = _decode(_run_raw(["/usr/bin/uname", "-m"], env=env)).strip()
    xcode_lines = _decode(_run_raw(["/usr/bin/xcodebuild", "-version"], env=env)).splitlines()
    xcode_version = xcode_lines[0].removeprefix("Xcode ").strip()
    xcode_build = xcode_lines[1].removeprefix("Build version ").strip()
    sdk_version = _decode(
        _run_raw(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], env=env)
    ).strip()
    sdk_path = Path(
        _decode(_run_raw(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env=env)).strip()
    ).resolve()
    system_version_path = sdk_path / "System/Library/CoreServices/SystemVersion.plist"
    with system_version_path.open("rb") as stream:
        sdk_system_version = plistlib.load(stream)
    sdk_build = sdk_system_version["ProductBuildVersion"]
    tools: Dict[str, str] = {}
    for name in ("clang", "clang++", "ar", "ranlib", "nm", "otool", "strip", "lipo"):
        tools[name] = _decode(
            _run_raw(["/usr/bin/xcrun", "--sdk", "macosx", "--find", name], env=env)
        ).strip()
    standard = recipe["component"].get("cxxLanguageStandard")
    if standard != RKDEVELOPTOOL_CXX_STANDARD:
        raise BuildError("the recipe does not pin rkdeveloptool to C++23")
    _run_raw(
        [
            tools["clang++"],
            "-std={}".format(standard),
            "-x",
            "c++",
            "-fsyntax-only",
            "/dev/null",
        ],
        env=env,
    )
    clang_version = _decode(_run_raw([tools["clang"], "--version"], env=env)).splitlines()[0]
    make_version = _decode(_run_raw(["/usr/bin/make", "--version"], env=env)).splitlines()[0]
    bash_version = _decode(_run_raw(["/bin/bash", "--version"], env=env)).splitlines()[0]
    python_version = "{}.{}.{}".format(*sys.version_info[:3])
    hosted_image = {
        "imageOS": os.environ.get("ImageOS", ""),
        "label": "macos-{}-{}".format(os_version.split(".", 1)[0], architecture),
        "version": os.environ.get("ImageVersion", ""),
    }

    facts = {
        "architecture": architecture,
        "bash": re.search(r"version ([^ -]+)", bash_version).group(1),
        "clang": clang_version,
        "developerDirectory": str(developer_dir),
        "hostedImage": hosted_image,
        "make": make_version,
        "osBuild": os_build,
        "osVersion": os_version,
        "python": python_version,
        "sdkBuild": sdk_build,
        "sdkPath": str(sdk_path),
        "sdkVersion": sdk_version,
        "tools": tools,
        "xcodeBuild": xcode_build,
        "xcodeVersion": xcode_version,
    }
    for key in (
        "architecture",
        "bash",
        "clang",
        "make",
        "osBuild",
        "osVersion",
        "python",
        "sdkBuild",
        "sdkVersion",
        "xcodeBuild",
        "xcodeVersion",
    ):
        _require_exact_fact("toolchain fact for {}".format(key), facts[key], expected[key])
    _require_exact_fact("hosted image", facts["hostedImage"], expected["hostedImage"])

    iconv_header = sdk_path / "usr/include/iconv.h"
    iconv_tbd = sdk_path / "usr/lib/libiconv.2.tbd"
    if sha256_file(iconv_header) != recipe["inspection"]["sdkIconvHeaderSHA256"]:
        raise BuildError("SDK iconv.h drift")
    if sha256_file(iconv_tbd) != recipe["inspection"]["sdkIconvTbdSHA256"]:
        raise BuildError("SDK libiconv.2.tbd drift")
    verifier_tools: Dict[str, Dict[str, str]] = {}
    for tool_name in ("gpg", "gpgv"):
        tool_pin = expected[tool_name]
        tool_path = Path(tool_pin["absolutePath"])
        if not tool_path.is_symlink() or not tool_path.is_file():
            raise BuildError("{} absolute link is unavailable".format(tool_name))
        resolved_path = tool_path.resolve()
        _require_exact_fact(
            "{} realpath".format(tool_name),
            str(resolved_path),
            tool_pin["realPath"],
        )
        version_line = _decode(_run_raw([str(tool_path), "--version"], env=env)).splitlines()[0]
        version = version_line.rsplit(None, 1)[-1]
        _require_exact_fact("{} version".format(tool_name), version, tool_pin["version"])
        verifier_tools[tool_name] = {
            "absolutePath": str(tool_path),
            "realPath": str(resolved_path),
            "sha256": sha256_file(resolved_path),
            "version": version,
        }
    facts["signatureVerifier"] = {
        "packageProvenance": dict(expected["gnupgBottle"]),
        "tools": verifier_tools,
    }
    if not Path("/usr/bin/sandbox-exec").is_file():
        raise BuildError("sandbox-exec is unavailable")
    return facts


class CommandRecorder:
    def __init__(self, replacements: Mapping[str, str]) -> None:
        self._replacements = sorted(replacements.items(), key=lambda item: len(item[0]), reverse=True)
        self.commands: List[Dict[str, Any]] = []

    def sanitize(self, value: str) -> str:
        result = value
        for raw, replacement in self._replacements:
            result = result.replace(raw, replacement)
        return result

    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
        sandboxed: bool = True,
        accepted_exit_codes: Set[int] = frozenset({0}),
    ) -> subprocess.CompletedProcess:
        actual = list(argv)
        if sandboxed:
            actual = ["/usr/bin/sandbox-exec", "-p", SANDBOX_PROFILE] + actual
        completed = subprocess.run(
            actual,
            cwd=str(cwd),
            env=dict(env),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=900,
        )
        stdout = completed.stdout
        stderr = completed.stderr
        sanitized_stdout = self.sanitize(stdout.decode("utf-8", errors="replace")).encode("utf-8")
        sanitized_stderr = self.sanitize(stderr.decode("utf-8", errors="replace")).encode("utf-8")
        self.commands.append(
            {
                "argv": [self.sanitize(str(item)) for item in actual],
                "cwd": self.sanitize(str(cwd)),
                "exitCode": completed.returncode,
                "stderrSHA256": sha256_bytes(sanitized_stderr),
                "stdoutSHA256": sha256_bytes(sanitized_stdout),
            }
        )
        if completed.returncode not in accepted_exit_codes:
            tail = self.sanitize(stderr.decode("utf-8", errors="replace")[-4000:])
            raise BuildError("build command failed ({}): {}".format(completed.returncode, tail))
        return completed

    def digest(self) -> str:
        return sha256_bytes(canonical_json_bytes(self.commands))


def _closed_build_environment(
    work_root: Path,
    toolchain: Mapping[str, Any],
    recipe: Mapping[str, Any],
) -> Dict[str, str]:
    home = work_root / "home"
    temporary = work_root / "tmp"
    home.mkdir()
    temporary.mkdir()
    tools = toolchain["tools"]
    sdk = toolchain["sdkPath"]
    prefix_map = "-fdebug-prefix-map={}=/build".format(work_root)
    file_prefix_map = "-ffile-prefix-map={}=/build".format(work_root)
    common_flags = [
        "-target",
        recipe["component"]["targetTriple"],
        "-arch",
        recipe["component"]["architecture"],
        "-mmacosx-version-min=14.0",
        "-isysroot",
        sdk,
        "-O2",
        "-g0",
        "-fno-ident",
        prefix_map,
        file_prefix_map,
    ]
    return {
        "AR": tools["ar"],
        "ARFLAGS": "cr",
        "CC": tools["clang"],
        "CFLAGS": " ".join(common_flags),
        "CONFIG_SITE": "/dev/null",
        "CPPFLAGS": "",
        "CXX": tools["clang++"],
        "CXXFLAGS": " ".join(common_flags),
        "DEVELOPER_DIR": toolchain["developerDirectory"],
        "HOME": str(home),
        "LANG": recipe["environment"]["LANG"],
        "LC_ALL": recipe["environment"]["LC_ALL"],
        "LDFLAGS": " ".join(
            [
                "-target",
                recipe["component"]["targetTriple"],
                "-arch",
                recipe["component"]["architecture"],
                "-mmacosx-version-min=14.0",
                "-isysroot",
                sdk,
            ]
        ),
        "MAKEFLAGS": "-j1",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "NM": tools["nm"],
        "PATH": "/usr/bin:/bin",
        "PKG_CONFIG": "/usr/bin/false",
        "RANLIB": tools["ranlib"],
        "SDKROOT": sdk,
        "SHELL": "/bin/bash",
        "SOURCE_DATE_EPOCH": recipe["environment"]["SOURCE_DATE_EPOCH"],
        "STRIP": tools["strip"],
        "TMPDIR": str(temporary),
        "TZ": recipe["environment"]["TZ"],
        "ZERO_AR_DATE": recipe["environment"]["ZERO_AR_DATE"],
    }


def rkdeveloptool_compile_arguments(
    *,
    compiler: str,
    source: Path,
    output: Path,
    work_root: Path,
    rk_source: Path,
    libusb_source: Path,
    libusb_build: Path,
    generated_config: Path,
    toolchain: Mapping[str, Any],
    recipe: Mapping[str, Any],
) -> List[str]:
    standard = recipe["component"].get("cxxLanguageStandard")
    if standard != RKDEVELOPTOOL_CXX_STANDARD:
        raise BuildError(
            "rkdeveloptool C++ standard drift: observed={!r} expected={!r}".format(
                standard,
                RKDEVELOPTOOL_CXX_STANDARD,
            )
        )
    if source.suffix != ".cpp":
        raise BuildError("rkdeveloptool compilation requires a .cpp source")
    return [
        compiler,
        "-std={}".format(standard),
        "-target",
        recipe["component"]["targetTriple"],
        "-arch",
        recipe["component"]["architecture"],
        "-mmacosx-version-min=14.0",
        "-isysroot",
        toolchain["sdkPath"],
        "-O2",
        "-g0",
        "-fno-ident",
        "-fno-strict-aliasing",
        "-Wno-deprecated-declarations",
        "-D_FILE_OFFSET_BITS=64",
        "-D_LARGE_FILE",
        "-fdebug-prefix-map={}=/build".format(work_root),
        "-ffile-prefix-map={}=/build".format(work_root),
        "-I",
        str(generated_config.parent),
        "-I",
        str(rk_source),
        "-I",
        str(libusb_source / "libusb"),
        "-I",
        str(libusb_build / "libusb"),
        "-c",
        str(source),
        "-o",
        str(output),
    ]


def _write_generated_config(path: Path, recipe: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True)
    data = recipe["inputs"]["rkdeveloptool"]["generatedConfig"].encode("utf-8")
    path.write_bytes(data)
    os.chmod(str(path), 0o644)
    os.utime(str(path), (SOURCE_DATE_EPOCH, SOURCE_DATE_EPOCH))


def _parse_otool_dependencies(output: str) -> List[str]:
    result: List[str] = []
    for line in output.splitlines()[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        path = stripped.split(" (", 1)[0]
        result.append(path)
    return sorted(set(result))


def _parse_minos(output: str) -> str:
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if line.strip() == "cmd LC_BUILD_VERSION":
            for candidate in lines[index + 1 : index + 12]:
                stripped = candidate.strip()
                if stripped.startswith("minos "):
                    return stripped.split(None, 1)[1]
    raise BuildError("LC_BUILD_VERSION/minos was not found")


def _parse_macho_uuid(output: str) -> str:
    for index, line in enumerate(output.splitlines()):
        if line.strip() != "cmd LC_UUID":
            continue
        for candidate in output.splitlines()[index + 1 : index + 8]:
            match = re.fullmatch(r"uuid ([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})", candidate.strip())
            if match:
                return match.group(1).lower()
        raise BuildError("LC_UUID is malformed")
    raise BuildError("LC_UUID was not found")


def _normalized_symbol_lines(output: str) -> List[str]:
    symbols: List[str] = []
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        fields = stripped.split()
        symbols.append(fields[-1])
    return sorted(set(symbols))


def inspect_artifact(
    binary: Path,
    recorder: CommandRecorder,
    env: Mapping[str, str],
    toolchain: Mapping[str, Any],
    recipe: Mapping[str, Any],
) -> Dict[str, Any]:
    cwd = binary.parent
    tools = toolchain["tools"]
    architecture = _decode(
        recorder.run([tools["lipo"], "-archs", str(binary)], cwd=cwd, env=env)
    ).strip()
    if architecture != recipe["component"]["architecture"]:
        raise BuildError("unsigned artifact architecture drift")
    otool_l = _decode(recorder.run([tools["otool"], "-L", str(binary)], cwd=cwd, env=env))
    dependencies = _parse_otool_dependencies(otool_l)
    expected_dependencies = sorted(recipe["inspection"]["directDependencyAllowlist"])
    if dependencies != expected_dependencies:
        raise BuildError(
            "direct dependency graph drift: observed={} expected={}".format(
                dependencies,
                expected_dependencies,
            )
        )
    load_commands = _decode(recorder.run([tools["otool"], "-l", str(binary)], cwd=cwd, env=env))
    minos = _parse_minos(load_commands)
    if minos not in ("14.0", "14.0.0"):
        raise BuildError("unsigned artifact minimum macOS drift")
    macho_uuid = _parse_macho_uuid(load_commands)
    if macho_uuid == "00000000-0000-0000-0000-000000000000":
        raise BuildError("unsigned artifact LC_UUID is invalid")
    undefined_output = _decode(recorder.run([tools["nm"], "-u", str(binary)], cwd=cwd, env=env))
    exported_output = _decode(recorder.run([tools["nm"], "-gU", str(binary)], cwd=cwd, env=env))
    strings_output = _decode(
        recorder.run(["/usr/bin/strings", "-a", str(binary)], cwd=cwd, env=env)
    )
    if "rkdeveloptool ver %s" not in strings_output or recipe["component"]["version"] not in strings_output:
        raise BuildError("expected version format/literal is absent from the unsigned artifact")
    signature = recorder.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(binary)],
        cwd=cwd,
        env=env,
        sandboxed=False,
        accepted_exit_codes=frozenset({1}),
    )
    signature_text = _decode(signature, "stderr")
    if "code object is not signed at all" not in signature_text:
        raise BuildError("TASK-BRC-002 artifact must remain unsigned")
    undefined_symbols = _normalized_symbol_lines(undefined_output)
    exported_symbols = _normalized_symbol_lines(exported_output)
    return {
        "architecture": architecture,
        "codeSignature": "absent",
        "dependencies": dependencies,
        "exportedSymbolCount": len(exported_symbols),
        "exportedSymbolsSHA256": sha256_bytes(
            ("\n".join(exported_symbols) + "\n").encode("utf-8")
        ),
        "loadCommandsSHA256": sha256_bytes(
            recorder.sanitize(load_commands).encode("utf-8")
        ),
        "machoUUID": macho_uuid,
        "minimumMacOS": minos,
        "sha256": sha256_file(binary),
        "size": binary.stat().st_size,
        "undefinedSymbolCount": len(undefined_symbols),
        "undefinedSymbolsSHA256": sha256_bytes(
            ("\n".join(undefined_symbols) + "\n").encode("utf-8")
        ),
        "versionStringEvidence": {
            "expectedRuntimeOutput": recipe["component"]["expectedVersionString"],
            "staticFormat": "rkdeveloptool ver %s",
            "staticLiteral": recipe["component"]["version"],
        },
    }


def _property_notice(source: Path) -> str:
    text = source.read_text(encoding="utf-8")
    marker = "*/"
    if marker not in text:
        raise BuildError("Property.hpp notice delimiter is missing")
    notice = text.split(marker, 1)[0].rstrip() + "*/\n"
    if "redistribut" not in notice.lower():
        raise BuildError("Property.hpp notice does not contain its redistribution term")
    return notice


def generate_notices(
    output: Path,
    rk_source: Path,
    libusb_source: Path,
    recipe: Mapping[str, Any],
) -> None:
    rk = recipe["inputs"]["rkdeveloptool"]
    libusb = recipe["inputs"]["libusb"]
    sections = [
        "ArkDeck Rockchip Bundled Component — Third-Party Notices\n",
        "Generated from machine-pinned inputs; do not hand edit.\n\n",
        "rkdeveloptool\n",
        "Upstream: https://github.com/rockchip-linux/rkdeveloptool\n",
        "Commit: {}\n".format(rk["commit"]),
        "Source: {}\n".format(rk["archive"]["url"]),
        "Source SHA-256: {}\n".format(rk["archive"]["sha256"]),
        "Package concluded license: GPL-2.0-or-later\n",
        "Upstream source files carrying GPL-2.0+ identifiers are preserved verbatim.\n\n",
        "libusb\n",
        "Version: {}\n".format(libusb["version"]),
        "Source: {}\n".format(libusb["archive"]["url"]),
        "Source SHA-256: {}\n".format(libusb["archive"]["sha256"]),
        "Signature SHA-256: {}\n".format(libusb["signature"]["sha256"]),
        "Signing primary fingerprint: {}\n".format(libusb["signature"]["primaryFingerprint"]),
        "Signing subkey fingerprint: {}\n".format(libusb["signature"]["signingFingerprint"]),
        "Package concluded license: LGPL-2.1-or-later\n",
        "libusb is statically linked into the separate GPL rkdeveloptool child; exact "
        "source and relink scripts accompany distribution.\n\n",
        "libiconv\n",
        "Disposition: Apple system-provided /usr/lib/libiconv.2.dylib.\n",
        "ArkDeck redistributes neither Apple nor GNU libiconv bytes.\n\n",
        "Corresponding source\n",
        "Mode: GPL-2.0 section 3(a), same GitHub Release as the DMG.\n",
        "Availability: max(binary public availability, five years after release issuedAt).\n",
        "Upstream source modifications: none. Repo-owned build plumbing is complete "
        "corresponding source.\n",
        "No warranty is provided beyond the terms of the licenses below.\n\n",
        "===== rkdeveloptool GPL version 2 text =====\n",
        (rk_source / "license.txt").read_text(encoding="utf-8"),
        "\n===== libusb LGPL version 2.1 text =====\n",
        (libusb_source / "COPYING").read_text(encoding="utf-8"),
        "\n===== Rockchip Property.hpp notice =====\n",
        _property_notice(rk_source / "Property.hpp"),
        "\n===== libusb AUTHORS =====\n",
        (libusb_source / "AUTHORS").read_text(encoding="utf-8"),
    ]
    with output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("".join(sections))


def _spdx_file_license(path: str) -> Tuple[str, List[str]]:
    gpl_identifier_files = {
        "RKBoot.cpp",
        "RKComm.cpp",
        "RKDevice.cpp",
        "RKImage.cpp",
        "RKLog.cpp",
        "RKScan.cpp",
        "boot_merger.h",
        "crc.cpp",
        "main.cpp",
    }
    if path in gpl_identifier_files:
        return "GPL-2.0-or-later", ["GPL-2.0-or-later"]
    if path == "Property.hpp":
        return "LicenseRef-Rockchip-Property-permissive", [
            "LicenseRef-Rockchip-Property-permissive"
        ]
    if path == "license.txt":
        return "GPL-2.0-only", ["GPL-2.0-only"]
    return "GPL-2.0-or-later", ["NOASSERTION"]


def _spdx_id_for_path(path: str) -> str:
    return "SPDXRef-File-" + hashlib.sha256(path.encode("utf-8")).hexdigest()[:20]


def generate_spdx(
    output: Path,
    rk_inventory: Sequence[Mapping[str, Any]],
    rk_source: Path,
    artifact: Mapping[str, Any],
    recipe: Mapping[str, Any],
) -> None:
    rk_files: List[Dict[str, Any]] = []
    relationships: List[Dict[str, str]] = []
    verification_inputs: List[str] = []
    license_info: Set[str] = set()
    for item in rk_inventory:
        path = str(item["path"])
        concluded, in_file = _spdx_file_license(path)
        license_info.update(in_file)
        spdx_id = _spdx_id_for_path(path)
        rk_files.append(
            {
                "SPDXID": spdx_id,
                "checksums": [
                    {"algorithm": "SHA1", "checksumValue": item["sha1"]},
                    {"algorithm": "SHA256", "checksumValue": item["sha256"]},
                ],
                "copyrightText": "NOASSERTION",
                "fileName": "./sources/{}/{}".format(
                    recipe["inputs"]["rkdeveloptool"]["archiveRoot"],
                    path,
                ),
                "licenseConcluded": concluded,
                "licenseInfoInFiles": in_file,
            }
        )
        verification_inputs.append(str(item["sha1"]))
        relationships.append(
            {
                "relatedSpdxElement": spdx_id,
                "relationshipType": "CONTAINS",
                "spdxElementId": "SPDXRef-Package-rkdeveloptool-source",
            }
        )
    package_verification = hashlib.sha1(
        "".join(sorted(verification_inputs)).encode("ascii")
    ).hexdigest()
    rk = recipe["inputs"]["rkdeveloptool"]
    libusb = recipe["inputs"]["libusb"]
    packages: List[Dict[str, Any]] = [
        {
            "SPDXID": "SPDXRef-Package-rkdeveloptool-artifact",
            "checksums": [{"algorithm": "SHA256", "checksumValue": artifact["sha256"]}],
            "copyrightText": "NOASSERTION",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "GPL-2.0-or-later",
            "licenseDeclared": "GPL-2.0-or-later",
            "name": "rkdeveloptool-unsigned-macos-arm64",
            "primaryPackagePurpose": "APPLICATION",
            "supplier": "Organization: Rockchip",
            "versionInfo": recipe["component"]["version"],
        },
        {
            "SPDXID": "SPDXRef-Package-rkdeveloptool-source",
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": rk["archive"]["sha256"]}
            ],
            "copyrightText": "NOASSERTION",
            "downloadLocation": rk["archive"]["url"],
            "filesAnalyzed": True,
            "licenseConcluded": "GPL-2.0-or-later AND LicenseRef-Rockchip-Property-permissive",
            "licenseDeclared": "GPL-2.0-or-later",
            "licenseInfoFromFiles": sorted(license_info),
            "name": "rkdeveloptool-source",
            "packageVerificationCode": {
                "packageVerificationCodeValue": package_verification
            },
            "primaryPackagePurpose": "SOURCE",
            "supplier": "Organization: Rockchip",
            "versionInfo": rk["commit"],
        },
        {
            "SPDXID": "SPDXRef-Package-libusb",
            "checksums": [
                {"algorithm": "SHA256", "checksumValue": libusb["archive"]["sha256"]}
            ],
            "copyrightText": "NOASSERTION",
            "downloadLocation": libusb["archive"]["url"],
            "externalRefs": [
                {
                    "referenceCategory": "OTHER",
                    "referenceLocator": "{}#sha256={}".format(
                        libusb["signature"]["url"],
                        libusb["signature"]["sha256"],
                    ),
                    "referenceType": "source-signature",
                },
                {
                    "referenceCategory": "OTHER",
                    "referenceLocator": "{}#sha256={}".format(
                        libusb["keys"]["url"],
                        libusb["keys"]["sha256"],
                    ),
                    "referenceType": "signing-keys",
                },
            ],
            "filesAnalyzed": False,
            "licenseConcluded": "LGPL-2.1-or-later",
            "licenseDeclared": "LGPL-2.1-or-later",
            "name": "libusb",
            "primaryPackagePurpose": "LIBRARY",
            "supplier": "Organization: libusb project",
            "versionInfo": libusb["version"],
        },
        {
            "SPDXID": "SPDXRef-Tool-AppleClang",
            "comment": recipe["builder"]["clang"],
            "copyrightText": "NOASSERTION",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "name": "Apple clang",
            "primaryPackagePurpose": "APPLICATION",
            "supplier": "Organization: Apple Inc.",
            "versionInfo": "21.0.0",
        },
        {
            "SPDXID": "SPDXRef-Tool-macOS-SDK",
            "comment": "macOS SDK {} ({})".format(
                recipe["builder"]["sdkVersion"],
                recipe["builder"]["sdkBuild"],
            ),
            "copyrightText": "NOASSERTION",
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "name": "macOS SDK",
            "primaryPackagePurpose": "SOURCE",
            "supplier": "Organization: Apple Inc.",
            "versionInfo": recipe["builder"]["sdkVersion"],
        },
    ]
    dependency_ids: Dict[str, str] = {}
    for index, dependency in enumerate(recipe["inspection"]["directDependencyAllowlist"], start=1):
        dep_id = "SPDXRef-SystemDependency-{:02d}".format(index)
        dependency_ids[dependency] = dep_id
        packages.append(
            {
                "SPDXID": dep_id,
                "comment": "scope: provided; install-name: {}".format(dependency),
                "copyrightText": "NOASSERTION",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "name": PurePosixPath(dependency).name,
                "primaryPackagePurpose": "LIBRARY",
                "supplier": "Organization: Apple Inc.",
                "versionInfo": "system-provided",
            }
        )
    relationships.extend(
        [
            {
                "relatedSpdxElement": "SPDXRef-Package-rkdeveloptool-artifact",
                "relationshipType": "DESCRIBES",
                "spdxElementId": "SPDXRef-DOCUMENT",
            },
            {
                "relatedSpdxElement": "SPDXRef-Package-rkdeveloptool-source",
                "relationshipType": "GENERATED_FROM",
                "spdxElementId": "SPDXRef-Package-rkdeveloptool-artifact",
            },
            {
                "relatedSpdxElement": "SPDXRef-Package-libusb",
                "relationshipType": "GENERATED_FROM",
                "spdxElementId": "SPDXRef-Package-rkdeveloptool-artifact",
            },
            {
                "relatedSpdxElement": "SPDXRef-Package-libusb",
                "relationshipType": "STATIC_LINK",
                "spdxElementId": "SPDXRef-Package-rkdeveloptool-artifact",
            },
            {
                "relatedSpdxElement": "SPDXRef-Package-rkdeveloptool-artifact",
                "relationshipType": "BUILD_TOOL_OF",
                "spdxElementId": "SPDXRef-Tool-AppleClang",
            },
            {
                "relatedSpdxElement": "SPDXRef-Package-rkdeveloptool-artifact",
                "relationshipType": "BUILD_TOOL_OF",
                "spdxElementId": "SPDXRef-Tool-macOS-SDK",
            },
        ]
    )
    for dependency, dep_id in dependency_ids.items():
        relationships.append(
            {
                "comment": "scope: provided; {}".format(dependency),
                "relatedSpdxElement": dep_id,
                "relationshipType": "DEPENDS_ON",
                "spdxElementId": "SPDXRef-Package-rkdeveloptool-artifact",
            }
        )
    document = {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {
            "created": FIXED_CREATED,
            "creators": [
                "Organization: ArkDeck",
                "Tool: rockchip-component-build@1.0.0",
            ],
            "licenseListVersion": "3.27",
        },
        "dataLicense": "CC0-1.0",
        "documentNamespace": (
            "https://spdx.org/spdxdocs/arkdeck-rockchip-component-1.0.0-"
            "304f073752fd25c854e1bcf05d8e7f925b1f4e14"
        ),
        "files": rk_files,
        "hasExtractedLicensingInfos": [
            {
                "extractedText": _property_notice(rk_source / "Property.hpp"),
                "licenseId": "LicenseRef-Rockchip-Property-permissive",
                "name": "Rockchip Property.hpp permissive notice",
            }
        ],
        "name": "ArkDeck Rockchip bundled component 1.0.0",
        "packages": packages,
        "relationships": sorted(
            relationships,
            key=lambda item: (
                item["spdxElementId"],
                item["relationshipType"],
                item["relatedSpdxElement"],
            ),
        ),
        "spdxVersion": "SPDX-2.3",
    }
    write_canonical_json(output, document)


def _repo_build_file_records() -> List[Dict[str, Any]]:
    relative_paths = [
        "scripts/rockchip_component/README.md",
        "scripts/rockchip_component/build.py",
        "scripts/rockchip_component/test_build.py",
        "openspec/integrations/rockchip/bundled-component/1.0.0/recipe.json",
    ]
    records: List[Dict[str, Any]] = []
    for relative in relative_paths:
        path = REPO_ROOT / relative
        if not path.is_file():
            raise BuildError("required repo-owned build file is missing: {}".format(relative))
        records.append(
            {
                "gitBlob": git_blob_oid(path),
                "path": relative,
                "sha256": sha256_file(path),
                "size": path.stat().st_size,
            }
        )
    return records


def generate_source_manifest(
    output: Path,
    notices: Path,
    sbom: Path,
    recipe: Mapping[str, Any],
) -> None:
    rk = recipe["inputs"]["rkdeveloptool"]
    libusb = recipe["inputs"]["libusb"]
    document = {
        "availabilityWindow": "max(binary public availability, five years after release issuedAt)",
        "buildFiles": _repo_build_file_records(),
        "component": {
            "architecture": recipe["component"]["architecture"],
            "minimumMacOS": recipe["component"]["minimumMacOS"],
            "name": recipe["component"]["name"],
            "version": recipe["component"]["version"],
        },
        "distributionMode": "GPL-2.0-section-3a-same-release-complete-source",
        "generatedAssets": [
            {
                "path": "THIRD-PARTY-NOTICES.txt",
                "sha256": sha256_file(notices),
                "size": notices.stat().st_size,
            },
            {
                "pathTemplate": "ArkDeck-rockchip-component-sbom-<appVersion>.spdx.json",
                "sha256": sha256_file(sbom),
                "size": sbom.stat().st_size,
            },
        ],
        "manifestAlgorithm": "MANIFEST.sha256 covers every other regular file in sorted UTF-8 path order",
        "publicReleasePaths": {
            "binary": "ArkDeck-<appVersion>.dmg",
            "notices": "ArkDeck-rockchip-component-notices-<appVersion>.txt",
            "sbom": "ArkDeck-rockchip-component-sbom-<appVersion>.spdx.json",
            "source": "ArkDeck-rockchip-component-source-<appVersion>.tar.gz",
        },
        "schemaVersion": "1.0.0",
        "sourceAssets": [
            {
                "archivePath": "sources/{}".format(rk["archive"]["filename"]),
                "sha256": rk["archive"]["sha256"],
                "size": rk["archive"]["size"],
                "url": rk["archive"]["url"],
            },
            {
                "archivePath": "sources/{}".format(libusb["archive"]["filename"]),
                "sha256": libusb["archive"]["sha256"],
                "size": libusb["archive"]["size"],
                "url": libusb["archive"]["url"],
            },
            {
                "archivePath": "sources/{}".format(libusb["signature"]["filename"]),
                "sha256": libusb["signature"]["sha256"],
                "size": libusb["signature"]["size"],
                "url": libusb["signature"]["url"],
            },
            {
                "archivePath": "sources/{}".format(libusb["keys"]["filename"]),
                "sha256": libusb["keys"]["sha256"],
                "size": libusb["keys"]["size"],
                "url": libusb["keys"]["url"],
            },
        ],
        "writtenOfferMode": "forbidden",
    }
    write_canonical_json(output, document)


def generate_registry(
    output: Path,
    artifact: Mapping[str, Any],
    toolchain: Mapping[str, Any],
    command_digest: str,
    notices: Path,
    sbom: Path,
    source_manifest: Path,
    recipe: Mapping[str, Any],
) -> None:
    document = {
        "artifact": dict(artifact),
        "build": {
            "commandDigest": command_digest,
            "networkDuringBuild": "denied-by-sandbox-exec",
            "normalization": "forbidden",
            "recipeGitBlob": git_blob_oid(RECIPE_PATH),
            "recipePath": str(RECIPE_PATH.relative_to(REPO_ROOT)),
            "recipeSHA256": sha256_file(RECIPE_PATH),
            "sourceDateEpoch": SOURCE_DATE_EPOCH,
        },
        "builder": {
            key: toolchain[key]
            for key in (
                "architecture",
                "bash",
                "clang",
                "make",
                "osBuild",
                "osVersion",
                "python",
                "sdkBuild",
                "sdkVersion",
                "xcodeBuild",
                "xcodeVersion",
            )
        },
        "component": dict(recipe["component"]),
        "dependencies": {
            "direct": [
                {"installName": item, "scope": "provided"}
                for item in recipe["inspection"]["directDependencyAllowlist"]
            ],
            "libusb": {
                "archiveSHA256": recipe["inputs"]["libusb"]["archive"]["sha256"],
                "linkMode": "static",
                "version": recipe["inputs"]["libusb"]["version"],
            },
            "nonSystemBundledDylibCount": 0,
            "systemReexportAllowlist": recipe["inspection"]["systemReexportAllowlist"],
        },
        "generatedMetadata": {
            "notices": {
                "path": "THIRD-PARTY-NOTICES.txt",
                "sha256": sha256_file(notices),
            },
            "sbom": {
                "format": "SPDX-2.3 JSON",
                "path": "sbom.spdx.json",
                "sha256": sha256_file(sbom),
            },
            "sourceDistributionManifest": {
                "path": "source-distribution-manifest.json",
                "sha256": sha256_file(source_manifest),
            },
        },
        "inputs": {
            "libusb": recipe["inputs"]["libusb"],
            "rkdeveloptool": recipe["inputs"]["rkdeveloptool"],
        },
        "registeredBy": "CHG-2026-036/TASK-BRC-002",
        "registryId": "ARKDECK-BUNDLED-ROCKCHIP-COMPONENT",
        "registryVersion": "1.0.0",
        "schemaVersion": "1.0.0",
        "serializationFormat": "json-compatible-yaml-1.2",
    }
    document["builder"]["hostedImage"] = dict(toolchain["hostedImage"])
    document["builder"]["signatureVerifier"] = dict(toolchain["signatureVerifier"])
    assert_no_sensitive_values(document)
    write_canonical_json(output, document)


def assert_no_sensitive_values(value: Any) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            assert_no_sensitive_values(key)
            assert_no_sensitive_values(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            assert_no_sensitive_values(child)
    elif isinstance(value, str):
        for marker in SENSITIVE_MARKERS:
            if marker in value:
                raise BuildError("generated metadata contains a sensitive/local marker")


def validate_spdx(path: Path) -> None:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("spdxVersion") != "SPDX-2.3":
        raise BuildError("SPDX version drift")
    required_relationships = {
        "BUILD_TOOL_OF",
        "DEPENDS_ON",
        "DESCRIBES",
        "GENERATED_FROM",
        "STATIC_LINK",
    }
    observed_relationships = {
        item["relationshipType"] for item in document.get("relationships", [])
    }
    if not required_relationships.issubset(observed_relationships):
        raise BuildError("SPDX relationship closure is incomplete")
    rk_files = document.get("files", [])
    if not rk_files:
        raise BuildError("SPDX rkdeveloptool file inventory is empty")
    paths = [item["fileName"] for item in rk_files]
    if len(paths) != len(set(paths)):
        raise BuildError("SPDX file inventory contains duplicates")
    if not any(
        item.get("licenseId") == "LicenseRef-Rockchip-Property-permissive"
        for item in document.get("hasExtractedLicensingInfos", [])
    ):
        raise BuildError("SPDX custom Property.hpp license text is missing")
    assert_no_sensitive_values(document)


def validate_registry(path: Path, recipe: Mapping[str, Any]) -> None:
    registry = json.loads(path.read_text(encoding="utf-8"))
    if registry.get("registryVersion") != "1.0.0":
        raise BuildError("registry version drift")
    if registry["artifact"]["dependencies"] != sorted(
        recipe["inspection"]["directDependencyAllowlist"]
    ):
        raise BuildError("registry dependency graph disagrees with the recipe")
    macho_uuid = registry["artifact"].get("machoUUID")
    if not isinstance(macho_uuid, str) or not re.fullmatch(
        r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", macho_uuid
    ) or macho_uuid == "00000000-0000-0000-0000-000000000000":
        raise BuildError("registry LC_UUID is missing or malformed")
    if registry["dependencies"]["nonSystemBundledDylibCount"] != 0:
        raise BuildError("registry contains a bundled non-system dylib")
    if registry["build"]["normalization"] != "forbidden":
        raise BuildError("registry enabled output normalization")
    if registry["build"]["recipeSHA256"] != sha256_file(RECIPE_PATH):
        raise BuildError("registry recipe hash drift")
    assert_no_sensitive_values(registry)


def build_once(builder_id: str, work_root: Path, output_dir: Path) -> Dict[str, Any]:
    recipe = load_recipe()
    ensure_fresh_directory(work_root)
    ensure_fresh_directory(output_dir)
    os.umask(0o022)
    inputs = work_root / "inputs"
    fetch_receipt = fetch_inputs(recipe, inputs)
    toolchain = inspect_toolchain(recipe)
    signature_receipt = verify_libusb_signature(recipe, inputs, work_root / "gnupg")

    extracted = work_root / "extracted"
    extracted.mkdir()
    rk_archive = inputs / recipe["inputs"]["rkdeveloptool"]["archive"]["filename"]
    libusb_archive = inputs / recipe["inputs"]["libusb"]["archive"]["filename"]
    verify_file_pin(rk_archive, recipe["inputs"]["rkdeveloptool"]["archive"])
    rk_inventory = extract_archive(
        rk_archive,
        recipe["inputs"]["rkdeveloptool"]["archiveRoot"],
        extracted / "rk",
    )
    libusb_inventory = extract_archive(
        libusb_archive,
        recipe["inputs"]["libusb"]["archiveRoot"],
        extracted / "libusb",
    )
    rk_source = extracted / "rk" / recipe["inputs"]["rkdeveloptool"]["archiveRoot"]
    libusb_source = extracted / "libusb" / recipe["inputs"]["libusb"]["archiveRoot"]

    build_root = work_root / "build"
    build_root.mkdir()
    env = _closed_build_environment(work_root, toolchain, recipe)
    recorder = CommandRecorder(
        {
            str(work_root): "$WORK_ROOT",
            str(output_dir): "$OUTPUT_DIR",
            toolchain["developerDirectory"]: "$DEVELOPER_DIR",
            toolchain["sdkPath"]: "$SDKROOT",
        }
    )
    libusb_build = build_root / "libusb"
    libusb_build.mkdir()
    recorder.run(
        [
            "/bin/bash",
            str(libusb_source / "configure"),
            *recipe["inputs"]["libusb"]["configureArguments"],
        ],
        cwd=libusb_build,
        env=env,
    )
    recorder.run(
        ["/usr/bin/make", "-j1", "-C", "libusb", "libusb-1.0.la"],
        cwd=libusb_build,
        env=env,
    )
    libusb_static = libusb_build / "libusb/.libs/libusb-1.0.a"
    if not libusb_static.is_file():
        raise BuildError("libusb static archive was not produced")

    generated_config = build_root / "generated/config.h"
    _write_generated_config(generated_config, recipe)
    object_dir = build_root / "objects"
    object_dir.mkdir()
    objects: List[Path] = []
    for source_name in recipe["inputs"]["rkdeveloptool"]["sourceFiles"]:
        source = rk_source / source_name
        if not source.is_file():
            raise BuildError("pinned rkdeveloptool source file is missing")
        obj = object_dir / (Path(source_name).stem + ".o")
        recorder.run(
            rkdeveloptool_compile_arguments(
                compiler=toolchain["tools"]["clang++"],
                source=source,
                output=obj,
                work_root=work_root,
                rk_source=rk_source,
                libusb_source=libusb_source,
                libusb_build=libusb_build,
                generated_config=generated_config,
                toolchain=toolchain,
                recipe=recipe,
            ),
            cwd=build_root,
            env=env,
        )
        objects.append(obj)
    binary = output_dir / recipe["component"]["outputName"]
    recorder.run(
        [
            toolchain["tools"]["clang++"],
            "-target",
            recipe["component"]["targetTriple"],
            "-arch",
            recipe["component"]["architecture"],
            "-mmacosx-version-min=14.0",
            "-isysroot",
            toolchain["sdkPath"],
            "-Wl,-no_adhoc_codesign",
            "-Wl,-dead_strip",
            *[str(item) for item in objects],
            str(libusb_static),
            "-liconv",
            "-lobjc",
            "-framework",
            "IOKit",
            "-framework",
            "CoreFoundation",
            "-framework",
            "Security",
            "-o",
            str(binary),
        ],
        cwd=build_root,
        env=env,
    )
    artifact = inspect_artifact(binary, recorder, env, toolchain, recipe)

    notices = output_dir / "THIRD-PARTY-NOTICES.txt"
    generate_notices(notices, rk_source, libusb_source, recipe)
    sbom = output_dir / "sbom.spdx.json"
    generate_spdx(sbom, rk_inventory, rk_source, artifact, recipe)
    source_manifest = output_dir / "source-distribution-manifest.json"
    generate_source_manifest(source_manifest, notices, sbom, recipe)
    registry = output_dir / "registry.yaml"
    generate_registry(
        registry,
        artifact,
        toolchain,
        recorder.digest(),
        notices,
        sbom,
        source_manifest,
        recipe,
    )
    validate_spdx(sbom)
    validate_registry(registry, recipe)

    metadata = {
        name: {
            "sha256": sha256_file(output_dir / name),
            "size": (output_dir / name).stat().st_size,
        }
        for name in OUTPUT_METADATA
    }
    receipt = {
        "artifact": artifact,
        "builderId": builder_id,
        "commandDigest": recorder.digest(),
        "commands": recorder.commands,
        "effectCounters": {
            "appLaunch": 0,
            "componentLaunch": 0,
            "destructive": 0,
            "device": 0,
            "deviceMutation": 0,
            "e1": 0,
            "e2": 0,
            "hdc": 0,
            "notarize": 0,
            "package": 0,
            "sign": 0,
            "usb": 0,
        },
        "fetch": fetch_receipt,
        "inputInventory": {
            "libusbFileCount": len(libusb_inventory),
            "rkdeveloptoolFileCount": len(rk_inventory),
        },
        "metadata": metadata,
        "recipe": {
            "gitBlob": git_blob_oid(RECIPE_PATH),
            "sha256": sha256_file(RECIPE_PATH),
        },
        "schemaVersion": "1.0.0",
        "signature": signature_receipt,
        "toolchain": {
            key: toolchain[key]
            for key in (
                "architecture",
                "bash",
                "clang",
                "make",
                "osBuild",
                "osVersion",
                "python",
                "sdkBuild",
                "sdkVersion",
                "xcodeBuild",
                "xcodeVersion",
            )
        },
        "verdict": "PASS",
    }
    receipt["toolchain"]["hostedImage"] = dict(toolchain["hostedImage"])
    receipt["toolchain"]["signatureVerifier"] = dict(toolchain["signatureVerifier"])
    assert_no_sensitive_values(receipt)
    write_canonical_json(output_dir / "builder-receipt.json", receipt)
    return receipt


def compare_outputs(builder_a: Path, builder_b: Path, output: Path) -> Dict[str, Any]:
    recipe = load_recipe()
    required = [recipe["component"]["outputName"], *OUTPUT_METADATA, "builder-receipt.json"]
    for root in (builder_a, builder_b):
        for name in required:
            if not (root / name).is_file():
                raise BuildError("builder output is missing {}".format(name))
    compared = [recipe["component"]["outputName"], *OUTPUT_METADATA]
    identities: Dict[str, Dict[str, Any]] = {}
    for name in compared:
        a_hash = sha256_file(builder_a / name)
        b_hash = sha256_file(builder_b / name)
        a_size = (builder_a / name).stat().st_size
        b_size = (builder_b / name).stat().st_size
        if a_hash != b_hash or a_size != b_size:
            raise BuildError("builder outputs are not byte-identical: {}".format(name))
        identities[name] = {"sha256": a_hash, "size": a_size}
    receipt_a = json.loads((builder_a / "builder-receipt.json").read_text(encoding="utf-8"))
    receipt_b = json.loads((builder_b / "builder-receipt.json").read_text(encoding="utf-8"))
    if receipt_a["builderId"] == receipt_b["builderId"]:
        raise BuildError("clean builder identifiers must differ")
    for field in ("artifact", "commandDigest", "metadata", "recipe", "signature", "toolchain"):
        if receipt_a[field] != receipt_b[field]:
            raise BuildError("builder receipts disagree on {}".format(field))
    result = {
        "builderA": receipt_a["builderId"],
        "builderB": receipt_b["builderId"],
        "comparedOutputs": identities,
        "normalization": "forbidden",
        "schemaVersion": "1.0.0",
        "sharedBuildRoot": False,
        "verdict": "PASS-byte-identical",
    }
    assert_no_sensitive_values(result)
    write_canonical_json(output, result)
    return result


def materialize(reference: Path, integration_dir: Path = INTEGRATION_DIR) -> None:
    recipe = load_recipe(integration_dir / "recipe.json")
    for name in OUTPUT_METADATA:
        source = reference / name
        if not source.is_file():
            raise BuildError("reference output is missing {}".format(name))
        destination = integration_dir / name
        destination.write_bytes(source.read_bytes())
    validate_spdx(integration_dir / "sbom.spdx.json")
    validate_registry(integration_dir / "registry.yaml", recipe)


def verify_committed(reference: Path, integration_dir: Path = INTEGRATION_DIR) -> None:
    recipe = load_recipe(integration_dir / "recipe.json")
    for name in OUTPUT_METADATA:
        committed = integration_dir / name
        generated = reference / name
        if not committed.is_file() or not generated.is_file():
            raise BuildError("committed/reference metadata is incomplete")
        if committed.read_bytes() != generated.read_bytes():
            raise BuildError("committed metadata drift: {}".format(name))
    validate_spdx(integration_dir / "sbom.spdx.json")
    validate_registry(integration_dir / "registry.yaml", recipe)


def _parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    build_parser = subparsers.add_parser("build", help="fetch, verify and build once")
    build_parser.add_argument("--builder-id", required=True)
    build_parser.add_argument("--work-root", type=Path, required=True)
    build_parser.add_argument("--output-dir", type=Path, required=True)

    compare_parser = subparsers.add_parser("compare", help="compare two clean builder outputs")
    compare_parser.add_argument("--builder-a", type=Path, required=True)
    compare_parser.add_argument("--builder-b", type=Path, required=True)
    compare_parser.add_argument("--output", type=Path, required=True)

    materialize_parser = subparsers.add_parser(
        "materialize",
        help="copy deterministic metadata from a verified reference output",
    )
    materialize_parser.add_argument("--reference", type=Path, required=True)
    materialize_parser.add_argument("--integration-dir", type=Path, default=INTEGRATION_DIR)

    verify_parser = subparsers.add_parser(
        "verify-committed",
        help="compare committed metadata to a generated reference output",
    )
    verify_parser.add_argument("--reference", type=Path, required=True)
    verify_parser.add_argument("--integration-dir", type=Path, default=INTEGRATION_DIR)
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parse_args(argv)
    try:
        if args.command == "build":
            build_once(args.builder_id, args.work_root, args.output_dir)
        elif args.command == "compare":
            compare_outputs(args.builder_a, args.builder_b, args.output)
        elif args.command == "materialize":
            materialize(args.reference, args.integration_dir)
        elif args.command == "verify-committed":
            verify_committed(args.reference, args.integration_dir)
        else:
            raise BuildError("unsupported command")
    except (BuildError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        print("rockchip-component: FAIL: {}".format(error), file=sys.stderr)
        return 1
    print("rockchip-component: PASS: {}".format(args.command))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
