#!/usr/bin/env python3
"""Run equal Rust conformance checks on published and candidate Swift inputs.

Only temporary, task-owned source views are generated. The checkout's pin and
generated Rust remain unchanged. Both views use the current Rust implementation;
they are independent host tests, never installed Runtime or device acceptance.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def load_module(name: str, path: Path, contents: bytes | None = None):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    if contents is None:
        spec.loader.exec_module(module)
    else:
        exec(compile(contents, str(path), "exec"), module.__dict__)
    return module


contract = load_module("arkdeck_contract_generator", ROOT / "rust/scripts/generate-contract.py")


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def catalog_rust(inputs, info: dict, generator=None) -> str:
    if generator is None:
        generator = load_module("arkdeck_catalog_generator", ROOT / "scripts/catalog_gen/generate.py")
    operations = [json.loads(data) for path, data in inputs.files.items()
                  if path.startswith("Catalog/operations/") and path.endswith(".json")]
    return contract.formatted(generator.generate_rust(operations, info["catalogDigest"]))


def copy_rust(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns("target", "__pycache__"))


def rust_digest(source: Path) -> str:
    files = {}
    for directory, subdirectories, names in os.walk(source):
        subdirectories[:] = sorted(name for name in subdirectories if name not in ("target", "__pycache__"))
        for name in sorted(names):
            path = Path(directory) / name
            files[path.relative_to(source).as_posix()] = contract.sha(path.read_bytes())
    return contract.sha(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())


def materialize(destination: Path, inputs, info: dict, published_info: dict,
                rust_source: Path | None = None, catalog_source: str | None = None) -> None:
    """All fixture readers and include_str! consumers see the same input view."""
    copy_rust(rust_source or ROOT / "rust", destination / "rust")
    for path, contents in inputs.files.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
    write_json(destination / "spec/baselines/swift-single-v1.json", published_info)
    if info["kind"] == "candidate":
        write_json(destination / "spec/baselines/swift-candidate-inputs.json", info)
    generated = destination / "rust/crates/arkdeck-contract/src"
    (generated / "control_generated.rs").write_text(
        contract.formatted(contract.generate(info, inputs)), encoding="utf-8", newline="\n")
    (generated / "catalog_generated.rs").write_text(
        catalog_source if catalog_source is not None else catalog_rust(inputs, info),
        encoding="utf-8", newline="\n")


def commands(view: Path, output: Path, *, owners: bool = False) -> list[tuple[list[str], Path]]:
    rust = view / "rust"
    result = [
        (["cargo", "clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"], rust),
        (["cargo", "test", "--workspace", "--locked"], rust),
        (["cargo", "run", "--package", "arkdeck-platform", "--example", "windows_spk3",
          "--locked", "--", "process-selftest"], rust),
        (["cargo", "build", "--workspace", "--bins", "--locked"], rust),
        ([sys.executable, str(rust / "scripts/check-readonly.py"),
          "--bin-dir", str(rust / "target/debug"), "--output-dir", str(output / "recordings")], view),
    ]
    # New current-owner schemas are candidate inputs until their reviewed pin is
    # published. The old published-input view still tests its read-only surface.
    if owners and sys.platform == "darwin":
        result.append(([sys.executable, str(rust / "scripts/check-history-owner.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-session-owner.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-session-resources.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-session-cleanup.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-session-export.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-trace-cache-owner.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
    return result


def run_view(view: Path, output: Path, info: dict, published_info: dict, run=subprocess.run) -> None:
    write_json(output / "inputs.json", info)
    provenance = {"schemaVersion": "arkdeck.rust-contract-check/1", "kind": "host-test",
                  "inputKind": info["kind"], "inputDigest": info["inputDigest"],
                  "publishedBaselineCommit": published_info["commit"],
                  "sourceRevision": contract.git("rev-parse", "HEAD").decode().strip(),
                  "generatedRustSourceDigest": rust_digest(view / "rust"),
                  "deviceAcceptance": False, "completed": False, "commands": []}
    path = output / "provenance.json"
    write_json(path, provenance)
    # Each view owns its compilation artifacts, even if the caller uses a shared
    # Cargo target. No binary from the other view can reach the frame checker.
    environment = os.environ.copy()
    environment["CARGO_TARGET_DIR"] = str(view / "rust/target")
    try:
        for argv, cwd in commands(view, output, owners=info["kind"] == "candidate"):
            print(f'+ [{info["kind"]}] ' + " ".join(argv), flush=True)
            record = {"argv": argv, "completed": False}
            provenance["commands"].append(record)
            write_json(path, provenance)
            result = run(argv, cwd=cwd, env=environment, check=True)
            record.update(completed=True, exitCode=result.returncode)
            write_json(path, provenance)
        provenance.update(completed=True, result="pass")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        provenance.update(result="fail", error=str(error))
        raise
    finally:
        write_json(path, provenance)


def check(output_root: Path) -> Path:
    published, published_info = contract.verify_published()
    current = contract.working_inputs()
    current_info = contract.candidate(
        current, published_info["commit"], contract.git("rev-parse", "HEAD").decode().strip())
    # Unsupported candidate vocabulary or stale current Catalog output remains a
    # failure. Regeneration in isolation must not hide a stale committed Catalog.
    contract.generate(current_info, current)
    catalog_path = ROOT / "scripts/catalog_gen/generate.py"
    catalog_bytes = catalog_path.read_bytes()
    catalog_generator = load_module("arkdeck_catalog_snapshot", catalog_path, catalog_bytes)
    catalogs = {"published": catalog_rust(published, published_info, catalog_generator),
                "candidate": catalog_rust(current, current_info, catalog_generator)}
    catalog = ROOT / "rust/crates/arkdeck-contract/src/catalog_generated.rs"
    if catalog.read_bytes() != catalogs["candidate"].encode():
        raise ValueError("candidate Catalog generated input drift")
    output = output_root.resolve() / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=False)
    failures = []
    source_digest = rust_digest(ROOT / "rust")
    # A short task-owned path also bounds Cargo's native Windows build paths.
    temporary_root = ROOT / "rust/target/contract-check"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="views-", dir=temporary_root) as directory:
        rust_source = Path(directory) / "source-rust"
        copy_rust(ROOT / "rust", rust_source)
        if rust_digest(rust_source) != source_digest:
            raise ValueError("Rust sources changed while taking the validation snapshot")
        for name, inputs, info in [("published", published, published_info),
                                   ("candidate", current, current_info)]:
            view = Path(directory) / name
            try:
                materialize(view, inputs, info, published_info, rust_source, catalogs[name])
                run_view(view, output / name, info, published_info)
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                failures.append({"view": name, "error": str(error)})
    # Catch inputs changing during a check; the recorded hashes describe the
    # snapshot actually tested, not a later revision of the source workspace.
    if contract.describe_inputs(contract.working_inputs()) != contract.describe_inputs(current):
        failures.append({"view": "candidate", "error": "source inputs changed during validation"})
    if rust_digest(ROOT / "rust") != source_digest:
        failures.append({"view": "source", "error": "Rust sources changed during validation"})
    if catalog_path.read_bytes() != catalog_bytes:
        failures.append({"view": "source", "error": "Catalog generator changed during validation"})
    contract.verify_published()
    write_json(output / "summary.json", {
        "schemaVersion": "arkdeck.rust-dual-contract-check/1", "kind": "host-test",
        "deviceAcceptance": False, "publishedBaselineCommit": published_info["commit"],
        "sourceRustDigest": source_digest,
        "catalogGeneratorSHA256": contract.sha(catalog_bytes),
        "candidateInputDigest": current_info["inputDigest"], "completed": not failures,
        "failures": failures,
    })
    if failures:
        raise ValueError(f"contract checks failed: {failures}; recordings: {output}")
    print(f"Published and candidate contract checks passed; recordings: {output}", flush=True)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "rust/target/readonly-check")
    args = parser.parse_args()
    check(args.output_dir)


if __name__ == "__main__":
    main()
