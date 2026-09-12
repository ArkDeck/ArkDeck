#!/usr/bin/env python3
"""Generate and verify the Rust contract bindings from this checkout's Swift inputs.

The committed manifest `spec/baselines/swift-single-v1.json` describes the
contract inputs of the checkout it is committed in. --write regenerates it and
the Rust bindings from the working tree; --check fails when either differs from
such a regeneration, so a change that edits a consumed input regenerates in the
same change. Nothing here compares the checkout with another commit. The
published-versus-candidate comparison lives in check-contracts.py, whose
published inputs come from the merge-base with origin/main (`published_base`),
never from a committed pointer. Neither input view is a hardware acceptance
certificate.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "Packages/ArkDeckKit/Contracts/control-protocol.json"
METHODS = "spec/control/methods"
CORPUS = "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames"
BASELINE = ROOT / "spec/baselines/swift-single-v1.json"
GENERATED = ROOT / "rust/crates/arkdeck-contract/src/control_generated.rs"
BASE_REF = "origin/main"
INPUTS = [
    REGISTRY,
    "Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/PortableCanonicalJSON.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/CanonicalCBOR.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolContract.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/ControlFrameJSON.swift",
    "openspec/contracts/runtime-control-plane.schema.json",
    "openspec/contracts/cli-canonical-json-vectors.json",
    "openspec/contracts/cli-result.schema.json",
    "openspec/contracts/cli-error-registry.yaml",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/doctor.json",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/operation.list.json",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI/argv/device.candidates.json",
    "openspec/changes/chg-2026-059-arkdeck-arkforge-authority/permit-vectors.md",
    "openspec/contracts/journal-event.schema.json",
    "openspec/contracts/workflow-step.schema.json",
    METHODS,
    CORPUS,
    "Catalog/operations",
    "Catalog/profiles",
    "Catalog/generated/effect-authorization-matrix.md",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC",
]
KEYWORDS = {"type", "properties", "additionalProperties", "required", "items", "enum", "anyOf",
            "oneOf", "const", "pattern", "minLength", "not"}
TYPES = {"null", "boolean", "object", "array", "number", "string", "integer"}
# This is generator vocabulary, not a candidate Swift input. Resolve it from the
# physical script so isolated input roots cannot replace the supported patterns.
SCHEMA_PATTERNS = json.loads((Path(__file__).resolve().parents[1]
                             / "crates/arkdeck-contract/src/schema_patterns.json").read_bytes())
if (not isinstance(SCHEMA_PATTERNS, dict)
        or SCHEMA_PATTERNS.keys() != {"lowercaseSha256", "nonnegativeInt64Decimal"}
        or any(not isinstance(value, str) for value in SCHEMA_PATTERNS.values())
        or len(set(SCHEMA_PATTERNS.values())) != 2):
    raise ValueError("invalid shared schema pattern vocabulary")


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass
class ContractInputs:
    files: dict[str, bytes]
    blobs: dict[str, str]
    directories: set[str]

    def json(self, path: str) -> dict:
        return json.loads(self.files[path])


def base_reference() -> str:
    """The reference that names protected main, fetched shallowly if the checkout lacks it."""
    def resolves(reference: str) -> bool:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet", reference],
                              capture_output=True, check=False).returncode == 0

    if resolves(BASE_REF):
        return BASE_REF
    # A shallow or detached CI checkout may not carry the ref yet.
    subprocess.run(["git", "-C", str(ROOT), "fetch", "--depth=1", "origin", "main"],
                   capture_output=True, check=False)
    for reference in (BASE_REF, "FETCH_HEAD"):
        if resolves(reference):
            return reference
    raise ValueError(f"{BASE_REF} is unavailable, so the published baseline cannot be "
                     "established; fetch main and re-run")


def published_base() -> str:
    """The commit whose inputs are the published baseline: the merge-base with origin/main.

    It is a property of this branch's history alone. Later merges to main do not
    move it, so no branch is invalidated by work that lands elsewhere.
    """
    try:
        return git("merge-base", base_reference(), "HEAD").decode().strip()
    except subprocess.CalledProcessError as error:
        raise ValueError(f"HEAD shares no history with {BASE_REF}, so the published "
                         "baseline cannot be established") from error


def published_inputs(commit: str) -> ContractInputs:
    """Read path types, membership and bytes from Git at a main commit, never from the worktree."""
    if not isinstance(commit, str) or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", commit):
        raise ValueError("published inputs require a full immutable commit ID")
    resolved = git("rev-parse", "--verify", "--end-of-options", commit + "^{commit}").decode().strip()
    if resolved != commit:
        raise ValueError("published inputs require a full immutable commit ID")
    subprocess.check_call(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", commit, base_reference()])
    files, blobs, directories = {}, {}, set()
    for path in INPUTS:
        kind = git("cat-file", "-t", f"{commit}:{path}").decode().strip()
        if kind == "tree":
            directories.add(path)
        elif kind != "blob":
            raise ValueError(f"unsupported published input type: {path}: {kind}")
        rows = git("ls-tree", "-r", commit,
                   "--format=%(objectmode) %(objecttype) %(objectname) %(path)", "--", path)
        if not rows:
            raise ValueError(f"missing published input: {path}")
        for line in rows.decode().splitlines():
            mode, kind, blob, file = line.split(" ", 3)
            if kind != "blob" or mode not in ("100644", "100755"):
                raise ValueError(f"published input must be a regular file: {file}")
            files[file] = git("cat-file", "blob", blob)
            blobs[file] = blob
    return ContractInputs(files, blobs, directories)


def working_inputs() -> ContractInputs:
    files, blobs, directories = {}, {}, set()
    object_format = git("rev-parse", "--show-object-format").decode().strip()
    for relative in INPUTS:
        path = ROOT / relative
        if path.is_symlink() or not path.exists():
            raise ValueError(f"missing or symlinked candidate input: {relative}")
        paths = [path]
        if path.is_dir():
            directories.add(relative)
            paths = sorted(path.rglob("*"))
        for file in paths:
            if file.is_symlink():
                raise ValueError(f"candidate input must be a regular file: {file}")
            if file.is_dir():
                continue
            data = file.read_bytes()
            name = file.relative_to(ROOT).as_posix()
            files[name] = data
            blobs[name] = hashlib.new(object_format, f"blob {len(data)}\0".encode() + data).hexdigest()
    return ContractInputs(files, blobs, directories)


def describe_inputs(inputs: ContractInputs) -> dict:
    files = {path: {"blob": inputs.blobs[path], "sha256": sha(data)}
             for path, data in sorted(inputs.files.items())}
    directories = {
        directory: sha("".join(sorted(
            f"{inputs.blobs[path]} {path}\n" for path in files if path.startswith(directory + "/")
        )).encode()) for directory in sorted(inputs.directories)
    }
    registry = inputs.json(REGISTRY)
    methods = registry["methods"]
    if not methods or len(methods) != len(set(methods)):
        raise ValueError("registry methods must be nonempty and unique")
    for directory, suffix in [(METHODS, ".json"), (CORPUS, ".jsonl")]:
        expected = {f"{directory}/{method}{suffix}" for method in methods}
        actual = {path for path in files if path.startswith(directory + "/")}
        if actual != expected:
            raise ValueError(f"method/file set drift: {directory}")
    counts = {"requests": 0, "successes": 0, "errors": 0}
    method_counts = {}
    for method in methods:
        raw = inputs.files[f"{CORPUS}/{method}.jsonl"]
        if not raw or not raw.endswith(b"\n"):
            raise ValueError(f"empty or torn corpus: {method}")
        method_counts[method] = dict.fromkeys(counts, 0)
        for line in raw[:-1].split(b"\n"):
            row = json.loads(line)
            if (row.get("method") != method or row.get("protocolVersion") != registry["currentVersion"]
                    or type(row.get("ok")) is not bool):
                raise ValueError(f"invalid corpus envelope: {method}")
            for key in ("requests", "successes" if row["ok"] else "errors"):
                method_counts[method][key] += 1
                counts[key] += 1
    identity = sha(json.dumps(registry, sort_keys=True, separators=(",", ":")).encode())
    matrix = inputs.files["Catalog/generated/effect-authorization-matrix.md"].decode()
    match = re.search(r"Catalog digest: `([a-f0-9]{64})`", matrix)
    if match is None:
        raise ValueError("missing Catalog digest")
    return {
        "protocolVersion": registry["currentVersion"],
        "contractIdentity": identity,
        "catalogDigest": match.group(1),
        "methodCount": len(methods),
        "corpusFileCount": len(methods),
        "corpusRecordCounts": counts,
        "corpusMethodCounts": method_counts,
        "inputDigest": sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()),
        "directoryDigests": directories,
        "files": files,
    }


def baseline(inputs: ContractInputs, commit: str | None = None) -> dict:
    """Describe development inputs.

    `commit` is provenance for a view generated from an immutable main commit.
    The committed checkout manifest describes the working tree and carries none:
    it cannot name the commit it is part of, and it needs no other.
    """
    provenance = {} if commit is None else {"commit": commit}
    return {"schemaVersion": "arkdeck.swift-development-baseline/2", "kind": "development",
            **provenance, **describe_inputs(inputs)}


def candidate(inputs: ContractInputs, published_commit: str, source_revision: str) -> dict:
    return {"schemaVersion": "arkdeck.swift-candidate-inputs/1", "kind": "candidate",
            "publishedBaselineCommit": published_commit, "sourceRevision": source_revision,
            **describe_inputs(inputs)}


def check_json_value(value, location: str) -> None:
    """Const and enum contain JSON data; their object keys are not keywords."""
    if value is None or type(value) in (bool, int, str):
        return
    if type(value) is float and math.isfinite(value):
        return
    if type(value) is list:
        for child in value:
            check_json_value(child, location)
        return
    if type(value) is dict and all(isinstance(key, str) for key in value):
        for child in value.values():
            check_json_value(child, location)
        return
    raise ValueError(f"invalid schema value at {location}: expected JSON data")


def check_vocabulary(schema: dict, location: str = "schema") -> None:
    if not isinstance(schema, dict) or any(not isinstance(key, str) for key in schema):
        raise ValueError(f"invalid schema value at {location}: expected an object schema")
    unknown = schema.keys() - KEYWORDS
    if unknown:
        raise ValueError(f"unsupported schema vocabulary at {location}: {sorted(unknown)}")

    def invalid(keyword: str, expected: str) -> None:
        raise ValueError(f"invalid schema value at {location}.{keyword}: expected {expected}")

    if "type" in schema:
        kinds = schema["type"]
        if isinstance(kinds, str):
            kinds = [kinds]
        if (not isinstance(kinds, list) or not kinds
                or any(not isinstance(kind, str) or kind not in TYPES for kind in kinds)
                or len(set(kinds)) != len(kinds)):
            invalid("type", "a known type or a nonempty array of distinct known types")
    if "properties" in schema:
        properties = schema["properties"]
        if not isinstance(properties, dict) or any(not isinstance(key, str) for key in properties):
            invalid("properties", "an object of property schemas")
        for key, child in properties.items():
            check_vocabulary(child, f"{location}.properties.{key}")
    if "required" in schema:
        required = schema["required"]
        if (not isinstance(required, list) or any(not isinstance(key, str) for key in required)
                or len(set(required)) != len(required)):
            invalid("required", "an array of distinct property names")
    if "additionalProperties" in schema and type(schema["additionalProperties"]) is not bool:
        invalid("additionalProperties", "a boolean")
    if "items" in schema:
        check_vocabulary(schema["items"], f"{location}.items")
    for keyword in ("anyOf", "oneOf"):
        if keyword in schema:
            branches = schema[keyword]
            if not isinstance(branches, list) or not branches:
                invalid(keyword, "a nonempty array of object schemas")
            for index, child in enumerate(branches):
                check_vocabulary(child, f"{location}.{keyword}[{index}]")
    if "not" in schema:
        check_vocabulary(schema["not"], f"{location}.not")
    if "enum" in schema:
        variants = schema["enum"]
        if not isinstance(variants, list) or not variants:
            invalid("enum", "a nonempty array of JSON values")
        check_json_value(variants, f"{location}.enum")
    if "const" in schema:
        check_json_value(schema["const"], f"{location}.const")
    if "pattern" in schema and (not isinstance(schema["pattern"], str)
                                or schema["pattern"] not in SCHEMA_PATTERNS.values()):
        raise ValueError(f"unsupported schema pattern at {location}.pattern")
    if "minLength" in schema:
        length = schema["minLength"]
        if type(length) is not int or not 0 <= length <= (1 << 64) - 1:
            invalid("minLength", "a JSON nonnegative integer no greater than u64::MAX")


def generate(info: dict, inputs: ContractInputs) -> str:
    registry = inputs.json(REGISTRY)
    lines = ["// Generated by rust/scripts/generate-contract.py. Do not edit.", ""]
    for key, rust_name in [("currentVersion", "PROTOCOL_VERSION"),
                           ("maximumRequestFrameBytes", "MAX_REQUEST_BYTES"),
                           ("maximumResponseFrameBytes", "MAX_RESPONSE_BYTES")]:
        value = registry[key]
        ty = "&str" if isinstance(value, str) else "usize"
        lines.append(f"pub const {rust_name}: {ty} = {json.dumps(value)};")
    lines.append(f'pub const CONTRACT_IDENTITY: &str = "{info["contractIdentity"]}";')
    lines.append('pub const SWIFT_BASELINE: &str = include_str!("../../../../spec/baselines/swift-single-v1.json");')
    lines.append('pub const CONTRACT_INPUTS: &str = ' + (
        'include_str!("../../../../spec/baselines/swift-candidate-inputs.json");'
        if info["kind"] == "candidate" else 'SWIFT_BASELINE;'))
    lines.append("pub const METHODS: &[&str] = &[")
    lines.extend(f'    "{method}",' for method in registry["methods"])
    lines.append("];\n")
    lines.append("pub const METHOD_SCHEMAS: &[(&str, &str)] = &[")
    schemas = {}
    for method in registry["methods"]:
        document = inputs.json(f"{METHODS}/{method}.json")
        if document["x-arkdeck-contractIdentity"] != info["contractIdentity"]:
            raise ValueError(f"schema identity drift: {method}")
        schemas[method] = document["$defs"]
        for schema in document["$defs"].values():
            check_vocabulary(schema)
        lines.append(f'    ("{method}", include_str!("../../../../{METHODS}/{method}.json")),')
    lines.append("];\n")

    def rust_type(schema: dict, name: str) -> str:
        if "anyOf" in schema:
            alternatives = schema["anyOf"]
            nonnull = [s for s in alternatives if s.get("type") not in ("null", ["null"])]
            if len(nonnull) == 1 and len(alternatives) == 2:
                return f"Option<{rust_type(nonnull[0], name)}>"
            return "serde_json::Value"
        kind = schema.get("type")
        if isinstance(kind, list):
            nonnull = [t for t in kind if t != "null"]
            if len(nonnull) == 1 and "null" in kind:
                return f"Option<{rust_type(dict(schema, type=nonnull[0]), name)}>"
            if not nonnull:
                return "()"
            return "serde_json::Value"
        if kind == "array":
            return f'Vec<{rust_type(schema["items"], name + "Item")}>'
        if kind == "object":
            fields = []
            for key, child in schema.get("properties", {}).items():
                suffix = key[0].upper() + key[1:]
                ty = rust_type(child, name + suffix)
                optional = key not in schema.get("required", [])
                if optional:
                    ty = f"Option<{ty}>"
                field = re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower()
                fields.append(f'    #[serde(rename = "{key}"' +
                              (', skip_serializing_if = "Option::is_none"' if optional else '') +
                              (', deserialize_with = "crate::required_nullable"' if not optional and ty.startswith('Option<') else '') + ')]')
                fields.append(f"    pub {field}: {ty},")
            lines.extend(["#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]",
                          "#[serde(deny_unknown_fields)]", f"pub struct {name} {{", *fields, "}", ""])
            return name
        return {"string": "String", "boolean": "bool", "integer": "i64", "number": "f64", "null": "()"}.get(kind, "serde_json::Value")

    for method, name in [("health", "Health"), ("doctor", "Doctor"),
                         ("operation.list", "OperationList"), ("device.observations", "DeviceObservations")]:
        for part in ("request", "result"):
            type_name = name + part.title()
            actual = rust_type(schemas[method][part], type_name)
            if type_name != actual:
                lines.append(f"pub type {type_name} = {actual};\n")
    return "\n".join(lines)


def formatted(content: str) -> str:
    # The rustup proxy discovers rust/rust-toolchain.toml on a fresh host.
    return subprocess.check_output(
        ["rustfmt", "--edition", "2024", "--config", "newline_style=Unix"],
        input=content.encode("utf-8"), cwd=ROOT / "rust",
    ).decode("utf-8")


def outputs(info: dict, inputs: ContractInputs) -> dict[Path, str]:
    return {
        BASELINE: json.dumps(info, indent=2, sort_keys=True) + "\n",
        GENERATED: formatted(generate(info, inputs)),
    }


def checkout_outputs() -> tuple[ContractInputs, dict, dict[Path, str]]:
    """The manifest and bindings a regeneration from this working tree produces."""
    inputs = working_inputs()
    info = baseline(inputs)
    return inputs, info, outputs(info, inputs)


def verify_checkout() -> tuple[ContractInputs, dict]:
    """The committed manifest and bindings must equal a regeneration from this checkout."""
    inputs, info, expected = checkout_outputs()
    for path, content in expected.items():
        if not path.exists() or path.read_bytes() != content.encode():
            raise ValueError(f"generated input drift: {path.relative_to(ROOT)}; the checkout's "
                             "contract inputs changed without regeneration, run "
                             "`python rust/scripts/generate-contract.py --write` in the same change")
    return inputs, info


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--write", action="store_true",
                       help="regenerate the manifest and Rust bindings from this checkout")
    modes.add_argument("--check", action="store_true",
                       help="verify the committed manifest and bindings equal a regeneration")
    args = parser.parse_args()
    if args.write:
        _, info, expected = checkout_outputs()
        for path, content in expected.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
    else:
        _, info = verify_checkout()
    print(f'Swift development baseline of this checkout: {info["methodCount"]} methods, '
          f'{info["corpusRecordCounts"]["requests"]} recorded shapes, '
          f'contract identity {info["contractIdentity"][:12]}')


if __name__ == "__main__":
    main()
