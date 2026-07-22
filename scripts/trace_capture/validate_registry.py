#!/usr/bin/env python3
"""Validate the TASK-TR-001 trace registry and byte-exact resource closure.

Stdlib-only and host-only: this script reads repository files and never starts
HDC, opens a device, or accesses the operator-controlled full capture.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_PACK = (
    REPO_ROOT
    / "openspec/integrations/openharmony/trace-probes/1.0.0"
)
RESOURCE_REF_KEYS = {"goldenResource", "rawHeaderResource"}
REQUIRED_PRESET_TAGS = {
    "sched", "freq", "ace", "app", "binder", "disk", "ohos", "graphic",
    "sync", "workq", "ability",
}
SENSITIVE_PATTERNS = (
    re.compile(rb"/(?:Users|home)/[^/\s\x00:]+"),
    re.compile(rb"-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----"),
    re.compile(rb"(?:ssh-rsa|ssh-ed25519) "),
)


class RegistryValidationError(Exception):
    pass


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RegistryValidationError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def _load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_bytes(), object_pairs_hook=_unique_object)
    except (OSError, json.JSONDecodeError) as error:
        raise RegistryValidationError(f"cannot parse {path}: {error}") from None


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _resource_refs(value) -> set[str]:
    refs: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in RESOURCE_REF_KEYS:
                if not isinstance(child, str):
                    raise RegistryValidationError(f"{key} must be a string")
                refs.add(child)
            refs.update(_resource_refs(child))
    elif isinstance(value, list):
        for child in value:
            refs.update(_resource_refs(child))
    return refs


def _require_markers(data: bytes, markers: tuple[bytes, ...], resource_id: str) -> None:
    cursor = 0
    for marker in markers:
        position = data.find(marker, cursor)
        if position < 0:
            raise RegistryValidationError(
                f"{resource_id} lacks ordered marker {marker!r}")
        cursor = position + len(marker)


def validate_pack(pack: pathlib.Path = DEFAULT_PACK) -> dict:
    registry_path = pack / "registry.yaml"
    resources_path = pack / "resources.json"
    registry = _load_json(registry_path)
    manifest = _load_json(resources_path)

    if registry.get("registryId") != "OPENHARMONY-TRACE-PROBES":
        raise RegistryValidationError("unexpected registryId")
    if registry.get("registryVersion") != "1.0.0":
        raise RegistryValidationError("unexpected registryVersion")
    if registry.get("integrationProfile") != "OPENHARMONY-TOOLS@0.4.0":
        raise RegistryValidationError("unexpected integration profile")
    if registry.get("unknownFamilyDisposition") != "unsupported":
        raise RegistryValidationError("unknown families must fail closed")
    if manifest.get("registryId") != registry.get("registryId"):
        raise RegistryValidationError("resource manifest registryId mismatch")
    if manifest.get("registryVersion") != registry.get("registryVersion"):
        raise RegistryValidationError("resource manifest version mismatch")

    resources = manifest.get("resources")
    if not isinstance(resources, list) or not resources:
        raise RegistryValidationError("resources must be a non-empty array")
    by_id = {}
    listed_paths: set[pathlib.Path] = set()
    for resource in resources:
        if not isinstance(resource, dict) or not isinstance(resource.get("id"), str):
            raise RegistryValidationError("malformed resource entry")
        resource_id = resource["id"]
        if resource_id in by_id:
            raise RegistryValidationError(f"duplicate resource id: {resource_id}")
        relative = pathlib.PurePosixPath(resource.get("path", ""))
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise RegistryValidationError(f"unsafe resource path: {relative}")
        path = pack.joinpath(*relative.parts)
        try:
            data = path.read_bytes()
        except OSError as error:
            raise RegistryValidationError(
                f"cannot read resource {resource_id}: {error}") from None
        if resource.get("sizeBytes") != len(data):
            raise RegistryValidationError(f"size mismatch: {resource_id}")
        if resource.get("sha256") != _sha256(data):
            raise RegistryValidationError(f"SHA-256 mismatch: {resource_id}")
        for pattern in SENSITIVE_PATTERNS:
            if pattern.search(data):
                raise RegistryValidationError(
                    f"sensitive bytes in repository resource: {resource_id}")
        by_id[resource_id] = (resource, data)
        listed_paths.add(path.resolve())

    actual_bins = {path.resolve() for path in (pack / "fixtures").glob("*.bin")}
    listed_bins = {
        path for path in listed_paths if path.suffix == ".bin"
    }
    if actual_bins != listed_bins:
        raise RegistryValidationError(
            "fixture closure mismatch: unlisted or missing .bin resource")

    refs = _resource_refs(registry)
    missing_refs = refs - set(by_id)
    if missing_refs:
        raise RegistryValidationError(
            "unknown registry resource refs: " + ", ".join(sorted(missing_refs)))

    hitrace_help = by_id["tr001-hitrace-help-dayu200-oh7"][1]
    bytrace_help = by_id["tr001-bytrace-help-dayu200-oh7"][1]
    hitrace_tags = by_id["tr001-hitrace-tags-dayu200-oh7"][1]
    bytrace_tags = by_id["tr001-bytrace-tags-dayu200-oh7"][1]
    capture_stdout = by_id["tr001-hitrace-capture-success-dayu200-oh7"][1]
    raw_header = by_id["tr001-raw-ftrace-header-dayu200-oh7"][1]
    _require_markers(
        hitrace_help,
        (b"hitrace enter, running_state is SHOW_HELP", b"usage: hitrace", b"-b N", b"-t N", b"-o filename"),
        "tr001-hitrace-help-dayu200-oh7")
    _require_markers(
        bytrace_help,
        (b"bytrace enter, running_state is SHOW_HELP", b"usage: bytrace", b"-b N", b"-t N", b"-o filename"),
        "tr001-bytrace-help-dayu200-oh7")
    _require_markers(
        capture_stdout,
        (b"start capture", b"capture done", b"trace read done, output:", b"TraceFinish done."),
        "tr001-hitrace-capture-success-dayu200-oh7")
    if not raw_header.startswith(b"# tracer: "):
        raise RegistryValidationError("raw ftrace header does not start with tracer marker")
    if any(line and not line.startswith(b"#") for line in raw_header.splitlines()):
        raise RegistryValidationError("raw ftrace header fixture contains a data row")

    registered_tags = set(registry["capabilityMatrix"][0].get("registeredTags", []))
    if not REQUIRED_PRESET_TAGS.issubset(registered_tags):
        raise RegistryValidationError("registered hitrace tags do not cover built-in presets")
    tag_pattern = re.compile(rb"(?m)^\s*([a-z0-9]+)\s+-\s+.+$")
    observed_hitrace_tags = {
        match.group(1).decode("ascii") for match in tag_pattern.finditer(hitrace_tags)
    }
    observed_bytrace_tags = {
        match.group(1).decode("ascii") for match in tag_pattern.finditer(bytrace_tags)
    }
    if observed_hitrace_tags != registered_tags:
        raise RegistryValidationError("registered hitrace tags do not exactly match the golden")
    if observed_bytrace_tags != registered_tags:
        raise RegistryValidationError("bytrace and registered hitrace tag sets differ")

    entries = registry.get("entries")
    if not isinstance(entries, list) or len(entries) != 7:
        raise RegistryValidationError("registry must contain the closed seven-command surface")
    for entry in entries:
        judgement = entry.get("judgement", {})
        if judgement.get("exitCodeAloneIsSuccess") is not False:
            raise RegistryValidationError(
                f"exit-code-only judgement is forbidden: {entry.get('id')}")
        if entry.get("timeout", {}).get("milliseconds") != 60000:
            raise RegistryValidationError(f"timeout drift: {entry.get('id')}")

    for evidence_path in registry.get("provenance", {}).get("redactedManifests", []):
        path = REPO_ROOT / evidence_path
        data = path.read_bytes()
        if b"/Users/" in data:
            raise RegistryValidationError(f"raw user path in redacted manifest: {path}")
        document = _load_json(path)
        for command in document.get("commands", []):
            argv = command.get("argv", [])
            if "-t" in argv and "<connectkey>" not in argv:
                raise RegistryValidationError(
                    f"unredacted target in evidence command: {command.get('commandId')}")

    return {
        "registrySha256": _sha256(registry_path.read_bytes()),
        "resourcesSha256": _sha256(resources_path.read_bytes()),
        "resourceCount": len(resources),
        "entryCount": len(entries),
        "fixtureBytes": sum(len(data) for _, data in by_id.values()),
    }


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    pack = pathlib.Path(arguments[0]).resolve() if arguments else DEFAULT_PACK
    try:
        result = validate_pack(pack)
    except RegistryValidationError as error:
        print(f"trace registry validation failed: {error}", file=sys.stderr)
        return 1
    print(
        "TEST-TRACE-PROV-001 PASS",
        f"entries={result['entryCount']}",
        f"resources={result['resourceCount']}",
        f"fixture_bytes={result['fixtureBytes']}",
        f"registry_sha256={result['registrySha256']}",
        f"resources_sha256={result['resourcesSha256']}",
        "real_device_dispatch=0",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
