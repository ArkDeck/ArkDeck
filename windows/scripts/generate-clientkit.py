#!/usr/bin/env python3
"""Generate and verify the C# contract bindings of ArkDeck.ClientKit (TASK-XPA-007).

The Windows client reads the same language-neutral inputs the Rust contract
generator (`rust/scripts/generate-contract.py`) reads for its bindings, so the
two clients cannot drift silently:

* `Packages/ArkDeckKit/Contracts/control-protocol.json` — protocol version,
  frame limits and the published method list; the contract identity is the
  SHA-256 of its sorted, compact JSON, as the Rust generator computes it.
* `spec/control/methods/*.json` — one typed schema per method. The ClientKit
  embeds these files and refuses to start if one differs from the SHA-256
  recorded here.
* `spec/baselines/swift-single-v1.json` — cross-check of the identity and the
  method count.
* `rust/crates/arkdeck-contract/src/schema_patterns.json` — the closed pattern
  vocabulary both validators implement.

Typed records are generated for the four methods the Rust generator types
(`health`, `doctor`, `operation.list`, `device.observations`), with the same
naming. `--write` regenerates `windows/ClientKit/Generated/ControlContract.g.cs`;
`--check` fails when the committed file differs from a regeneration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = "Packages/ArkDeckKit/Contracts/control-protocol.json"
METHODS = "spec/control/methods"
BASELINE = "spec/baselines/swift-single-v1.json"
SCHEMA_PATTERNS = "rust/crates/arkdeck-contract/src/schema_patterns.json"
INPUTS = [REGISTRY, METHODS, BASELINE, SCHEMA_PATTERNS]
GENERATED = ROOT / "windows/ClientKit/Generated/ControlContract.g.cs"
# The methods the Rust generator types (rust/scripts/generate-contract.py), same names.
TYPED_METHODS = [("health", "Health"), ("doctor", "Doctor"),
                 ("operation.list", "OperationList"), ("device.observations", "DeviceObservations")]
KEYWORDS = {"type", "properties", "additionalProperties", "required", "items", "enum", "anyOf",
            "oneOf", "const", "pattern", "minLength", "not"}
# Members every generated record already has.
RESERVED_MEMBERS = {"Parse", "ToJson", "Members", "Equals", "GetHashCode", "ToString",
                    "EqualityContract", "Deconstruct", "PrintMembers", "GetType"}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(relative: str) -> bytes:
    path = ROOT / relative
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or symlinked input: {relative}")
    return path.read_bytes()


def csharp_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def pascal(key: str) -> str:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key):
        raise ValueError(f"unsupported property name for a typed record: {key!r}")
    return key[0].upper() + key[1:]


class Generator:
    def __init__(self) -> None:
        self.records: list[str] = []
        self.names: set[str] = set()

    def type_of(self, schema: dict, name: str) -> tuple[str, str, str]:
        """(C# type, parse expression over `v`, JSON expression over `x`)."""
        unknown = schema.keys() - KEYWORDS
        if unknown:
            raise ValueError(f"unsupported schema vocabulary in {name}: {sorted(unknown)}")
        if "anyOf" in schema:
            alternatives = schema["anyOf"]
            nonnull = [s for s in alternatives if s.get("type") not in ("null", ["null"])]
            if len(nonnull) == 1 and len(alternatives) == 2:
                return self.nullable(self.type_of(nonnull[0], name))
            return self.raw()
        kind = schema.get("type")
        if isinstance(kind, list):
            nonnull = [t for t in kind if t != "null"]
            if len(nonnull) == 1 and "null" in kind:
                return self.nullable(self.type_of(dict(schema, type=nonnull[0]), name))
            if not nonnull:
                return ("JsonNull", "TypedJson.Null(v)", "JsonNull.Instance")
            return self.raw()
        if kind == "array":
            item_type, item_parse, item_json = self.type_of(schema["items"], name + "Item")
            return (f"IReadOnlyList<{item_type}>",
                    f"TypedJson.List(v, v => {item_parse})",
                    f"TypedJson.ListJson(x, x => {item_json})")
        if kind == "object":
            if isinstance(schema.get("additionalProperties"), dict):
                return self.raw()
            self.record(schema, name)
            return (name, f"{name}.Parse(v)", "x.ToJson()")
        simple = {
            "string": ("string", "TypedJson.String(v)", "new JsonString(x)"),
            "boolean": ("bool", "TypedJson.Bool(v)", "JsonBool.Of(x)"),
            "integer": ("long", "TypedJson.Int64(v)", "JsonNumber.FromInt64(x)"),
            "number": ("double", "TypedJson.Double(v)", "JsonNumber.FromDouble(x)"),
            "null": ("JsonNull", "TypedJson.Null(v)", "JsonNull.Instance"),
        }
        return simple.get(kind, self.raw())

    @staticmethod
    def raw() -> tuple[str, str, str]:
        return ("JsonValue", "v", "x")

    @staticmethod
    def nullable(inner: tuple[str, str, str]) -> tuple[str, str, str]:
        kind, parse, to_json = inner
        if kind.endswith("?"):
            raise ValueError("nested nullable types are not supported")
        value_types = {"bool", "long", "double"}
        access = "x.Value" if kind in value_types else "x"
        rewritten = to_json.replace("(x)", f"({access})") if kind in value_types else to_json
        return (kind + "?",
                f"v is JsonNull ? ({kind}?)null : {parse}",
                f"x is null ? JsonNull.Instance : {rewritten}")

    def record(self, schema: dict, name: str) -> None:
        if name in self.names:
            raise ValueError(f"duplicate generated type name: {name}")
        self.names.add(name)
        required = schema.get("required", [])
        properties = schema.get("properties", {})
        if schema.get("additionalProperties", True) is not False:
            raise ValueError(f"{name}: typed records need a closed object schema")
        fields = []
        for key, child in properties.items():
            member = pascal(key)
            if member == name or member in RESERVED_MEMBERS:
                raise ValueError(f"{name}.{key}: property name collides with C#")
            kind, parse, to_json = self.type_of(child, name + member)
            optional = key not in required
            if optional and kind.endswith("?"):
                # serde's Option<Option<T>> cannot keep absent apart from null
                # either; refuse instead of modelling it differently.
                raise ValueError(f"{name}.{key}: optional nullable fields are not supported")
            if optional:
                # Absent is null; `to_json` stays the non-null writer and is
                # applied to the pattern variable of `is { } present`.
                kind = kind + "?"
            fields.append((key, member, kind, parse, to_json, optional))
        lines = [
            f"/// <summary>Generated from the `{name}` schema; closed like its Rust twin",
            "/// (`deny_unknown_fields`): an unknown or missing required member is a schema mismatch.</summary>",
            f"public sealed partial record {name}(",
        ]
        lines.append(",\n".join(f"    {kind} {member}" for _, member, kind, *_ in fields) + ")")
        lines.append("{")
        lines.append(f"    private static readonly string[] Members = [{', '.join(csharp_string(k) for k, *_ in fields)}];")
        lines.append("")
        lines.append(f"    public static {name} Parse(JsonValue value)")
        lines.append("    {")
        lines.append("        var o = TypedJson.Object(value, Members);")
        args = []
        for key, member, kind, parse, _, optional in fields:
            accessor = ("OptionalValue" if kind[:-1] in {"bool", "long", "double"} else "OptionalRef")                 if optional else "Required"
            args.append(f"            TypedJson.{accessor}(o, {csharp_string(key)}, v => {parse})")
        lines.append(f"        return new {name}(")
        lines.append(",\n".join(args) + ");")
        lines.append("    }")
        lines.append("")
        lines.append("    public JsonObject ToJson()")
        lines.append("    {")
        lines.append("        var members = new List<KeyValuePair<string, JsonValue>>();")
        for key, member, kind, _, to_json, optional in fields:
            if optional:
                lines.append(f"        if ({member} is {{ }} present{member}) members.Add(new({csharp_string(key)}, TypedJson.Json(present{member}, x => {to_json})));")
            else:
                lines.append(f"        members.Add(new({csharp_string(key)}, TypedJson.Json({member}, x => {to_json})));")
        lines.append("        return new JsonObject(members);")
        lines.append("    }")
        lines.append("}")
        self.records.append("\n".join(lines))


def generate() -> str:
    registry_bytes = read(REGISTRY)
    registry = json.loads(registry_bytes)
    identity = sha256(json.dumps(registry, sort_keys=True, separators=(",", ":")).encode())
    baseline = json.loads(read(BASELINE))
    if baseline["contractIdentity"] != identity or baseline["protocolVersion"] != registry["currentVersion"]:
        raise ValueError("spec/baselines/swift-single-v1.json does not describe the registry")
    methods = registry["methods"]
    if not methods or len(methods) != len(set(methods)) or baseline["methodCount"] != len(methods):
        raise ValueError("registry methods must be nonempty, unique and match the baseline")
    directory = ROOT / METHODS
    files = sorted(p.name for p in directory.iterdir())
    if files != sorted(f"{m}.json" for m in methods):
        raise ValueError(f"method/file set drift: {METHODS}")
    patterns = json.loads(read(SCHEMA_PATTERNS))
    if set(patterns) != {"lowercaseSha256", "nonnegativeInt64Decimal"}:
        raise ValueError("invalid shared schema pattern vocabulary")

    schema_digests = {}
    documents = {}
    for method in methods:
        data = read(f"{METHODS}/{method}.json")
        document = json.loads(data)
        if document.get("x-arkdeck-contractIdentity") != identity:
            raise ValueError(f"schema identity drift: {method}")
        schema_digests[method] = sha256(data)
        documents[method] = document["$defs"]

    generator = Generator()
    codecs = []
    for method, name in TYPED_METHODS:
        for part in ("request", "result"):
            type_name = name + part.title()
            kind, parse, to_json = generator.type_of(documents[method][part], type_name)
            codecs.append(
                f"    /// <summary>`{method}` {part}.</summary>\n"
                f"    public static {kind} Parse{type_name}(JsonValue value) => TypedJson.Parse(value, v => {parse});\n\n"
                f"    public static JsonValue {type_name}Json({kind} value) => TypedJson.Json(value, x => {to_json});\n")

    out = [
        "// <auto-generated>",
        "// Generated by windows/scripts/generate-clientkit.py from",
        f"// {REGISTRY}, {METHODS}/*.json,",
        f"// {BASELINE} and {SCHEMA_PATTERNS}.",
        "// Do not edit; run `python windows/scripts/generate-clientkit.py --write`.",
        "// </auto-generated>",
        "#nullable enable",
        "",
        "namespace ArkDeck.ClientKit.Contract;",
        "",
        "using ArkDeck.ClientKit.Json;",
        "",
        "/// <summary>The single-v1 control contract this client speaks.</summary>",
        "public static class ControlContract",
        "{",
        f"    public const string ProtocolVersion = {csharp_string(registry['currentVersion'])};",
        f"    public const int MaxRequestBytes = {int(registry['maximumRequestFrameBytes'])};",
        f"    public const int MaxResponseBytes = {int(registry['maximumResponseFrameBytes'])};",
        f"    public const string ContractIdentity = {csharp_string(identity)};",
        f"    public const string RegistrySha256 = {csharp_string(sha256(registry_bytes))};",
        "",
        "    /// <summary>The published methods, in registry order (the order `health` must echo).</summary>",
        "    public static readonly IReadOnlyList<string> Methods =",
        "    [",
        *[f"        {csharp_string(m)}," for m in methods],
        "    ];",
        "",
        "    /// <summary>SHA-256 of each embedded `spec/control/methods/&lt;method&gt;.json`.</summary>",
        "    public static readonly IReadOnlyDictionary<string, string> MethodSchemaSha256 = new Dictionary<string, string>(StringComparer.Ordinal)",
        "    {",
        *[f"        [{csharp_string(m)}] = {csharp_string(d)}," for m, d in schema_digests.items()],
        "    };",
        "",
        f"    public const string LowercaseSha256Pattern = {csharp_string(patterns['lowercaseSha256'])};",
        f"    public const string NonnegativeInt64DecimalPattern = {csharp_string(patterns['nonnegativeInt64Decimal'])};",
        "}",
        "",
        "/// <summary>Typed request/result codecs of the methods the Rust contract types.</summary>",
        "public static class TypedMethods",
        "{",
        "\n".join(codecs).rstrip("\n"),
        "}",
        "",
        "\n\n".join(generator.records),
        "",
    ]
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--write", action="store_true", help="regenerate the C# bindings")
    modes.add_argument("--check", action="store_true",
                       help="fail when the committed bindings differ from a regeneration")
    args = parser.parse_args()
    content = generate().encode("utf-8")
    relative = GENERATED.relative_to(ROOT).as_posix()
    if args.write:
        GENERATED.parent.mkdir(parents=True, exist_ok=True)
        GENERATED.write_bytes(content)
        print(f"wrote {relative}")
        return 0
    if not GENERATED.is_file() or GENERATED.read_bytes() != content:
        print(f"generated input drift: {relative}; the contract inputs changed without "
              "regeneration, run `python windows/scripts/generate-clientkit.py --write` "
              "in the same change", file=sys.stderr)
        return 1
    print(f"{relative} matches its inputs ({len(json.loads(read(REGISTRY))['methods'])} methods)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
