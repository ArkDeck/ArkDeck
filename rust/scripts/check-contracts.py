#!/usr/bin/env python3
"""Run equal Rust conformance checks on published and candidate Swift inputs.

The published inputs are read from Git at the merge-base with origin/main; the
candidate inputs are this checkout's. Only isolated, task-owned source views
are generated. The checkout's manifest and generated Rust remain unchanged.
Both views use the current Rust implementation; they are independent host
tests, never installed Runtime or device acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import io
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import uuid
import catalog_test_views

ROOT = Path(__file__).resolve().parents[2]
REVIEW_PROJECTION = "Packages/ArkDeckKit/Sources/ArkDeckCore/FlashReviewCatalogGenerated.swift"
# The bundled OpenHarmony code-sign helper the Rust tests verify and compose
# (arkdeck-agentd's code-sign helper process test, the provider's helper
# facts): a checked-in package resource beside rust/, not a protocol input.
CODE_SIGN_HELPER = "Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable"
# The OpenHarmony integration registries, profile and lock that
# arkdeck-provider-hdc's registration tests read (CHG-2026-078): checked-in
# integration inputs beside rust/, not protocol inputs.
INTEGRATIONS = "openspec/integrations"


def review_projection() -> bytes:
    # The candidate companion is snapshotted and checked for concurrent edits.
    # A differing published Catalog receives its immutable original projection.
    return (ROOT / REVIEW_PROJECTION).read_bytes()


def published_catalog_companions(commit: str) -> dict[str, tuple[bytes, int]]:
    """Recorded plan/ledger hashes and the review projection belong to their Catalog.

    Both views still compile the checkout's implementation. When the Catalog
    changes, a published view must replay its original recorded inputs, not
    fixtures re-recorded against the candidate's different plan hashes.
    """
    archive = contract.git("archive", commit, "--", "rust/tests/fixtures", REVIEW_PROJECTION)
    result = {}
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as members:
        for member in members:
            if member.isdir():
                continue
            path = Path(member.name)
            if (not member.isfile() or path.is_absolute() or ".." in path.parts
                    or not (member.name.startswith("rust/tests/fixtures/")
                            or member.name == REVIEW_PROJECTION)):
                raise ValueError(f"unsafe published Catalog companion: {member.name}")
            # This table pins products emitted by the current CLI implementation,
            # not Catalog-bound device/plan recordings. Its bytes are separately
            # checked against the checkout by verify_contract_bundle_digests().
            if member.name.startswith("rust/tests/fixtures/contracts-bundle/"):
                continue
            result[member.name] = (members.extractfile(member).read(), member.mode & 0o777)
    if REVIEW_PROJECTION not in result:
        raise ValueError("published Catalog has no matching App review projection")
    return result


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
ci_workspace = load_module("arkdeck_contract_ci_workspace", Path(__file__).with_name("ci-workspace.py"))


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def catalog_rust(inputs, info: dict, generator=None) -> str:
    if generator is None:
        generator = load_module("arkdeck_catalog_generator", ROOT / "scripts/catalog_gen/generate.py")
    operations = [json.loads(data) for path, data in inputs.files.items()
                  if path.startswith("Catalog/operations/") and path.endswith(".json")]
    return contract.formatted(generator.generate_rust(operations, info["catalogDigest"]))


def historical_catalog_inputs(current):
    """Current protocol/source, plus the exact immutable c6 Catalog input.

    This route remains mandatory after the merge-base itself becomes e4.
    It neither edits persisted authority nor imports an older implementation.
    """
    old, new = catalog_test_views.catalogs(ROOT / "rust")
    operation_paths = {path: json.loads(data) for path, data in current.files.items()
                       if path.startswith("Catalog/operations/") and path.endswith(".json")}
    actual = {f"{row['id']}@{row.get('version', 0)}": row for row in operation_paths.values()}
    if len(operation_paths) != 32 or actual not in (old, new):
        raise ValueError("unclassified complete Catalog for historical test view")
    files, blobs = dict(current.files), dict(current.blobs)
    for path, row in operation_paths.items():
        reference = f"{row['id']}@{row.get('version', 0)}"
        data = (json.dumps(old[reference], indent=2, ensure_ascii=True, sort_keys=True) + "\n").encode()
        files[path] = data
        # ContractInputs records real Git blob identities, even for this
        # synthetic isolated input tree; no old authority/source ID is reused.
        blobs[path] = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    generator = load_module("arkdeck_historical_test_catalog", ROOT / "scripts/catalog_gen/generate.py")
    profiles = [json.loads(data) for path, data in current.files.items()
                if path.startswith("Catalog/profiles/") and path.endswith(".json")]
    matrix_path = "Catalog/generated/effect-authorization-matrix.md"
    actual_digest = catalog_test_views.OLD if actual == old else catalog_test_views.CURRENT
    expected_matrix = generator.generate_matrix(list(actual.values()), profiles, actual_digest)
    if current.files[matrix_path].decode().replace("\r\n", "\n") != expected_matrix:
        raise ValueError("historical input requires the full official Catalog matrix")
    matrix = generator.generate_matrix(list(old.values()), profiles, catalog_test_views.OLD).encode()
    files[matrix_path] = matrix
    blobs[matrix_path] = hashlib.sha1(f"blob {len(matrix)}\0".encode() + matrix).hexdigest()
    return contract.ContractInputs(files, blobs, set(current.directories))


def historical_review_projection(current: bytes) -> bytes:
    """The complete unchanged Flash projection with its proved c6 digest."""
    old, new = catalog_test_views.catalogs(ROOT / "rust")
    for key in old:
        if key.startswith("flash.") and old[key] != new[key]:
            raise ValueError("historical Flash descriptor drift")
    if current.count(catalog_test_views.OLD.encode()) == 1 and catalog_test_views.CURRENT.encode() not in current:
        return current
    if current.count(catalog_test_views.CURRENT.encode()) != 1 or catalog_test_views.OLD.encode() in current:
        raise ValueError("exact current Flash projection Catalog required")
    return current.replace(catalog_test_views.CURRENT.encode(), catalog_test_views.OLD.encode())


def historical_workspace_covers(published, historical) -> bool:
    """Only Catalog JSON whitespace may differ; every other input is exact.

    Published contract/corpus tests still execute in their own view. This
    proof only avoids replaying the same complete c6 owner suites twice.
    """
    if published.directories != historical.directories or published.files.keys() != historical.files.keys():
        return False
    for path, data in published.files.items():
        expected = historical.files[path]
        if path.startswith('Catalog/operations/') and path.endswith('.json'):
            if json.loads(data) != json.loads(expected):
                return False
        elif data != expected:
            return False
    return True


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
                rust_source: Path | None = None, catalog_source: str | None = None,
                review_source: bytes | None = None,
                catalog_companions: dict[str, tuple[bytes, int]] | None = None,
                catalog_generator_source: bytes | None = None) -> None:
    """All fixture readers and include_str! consumers see the same input view."""
    copy_rust(rust_source or ROOT / "rust", destination / "rust")
    # Test-view proof uses the same current source generator, including when
    # only the immutable historical Catalog input is selected.
    source_generator = ROOT / "scripts/catalog_gen/generate.py"
    if catalog_generator_source is not None or source_generator.is_file():
        copied_generator = destination / "scripts/catalog_gen/generate.py"
        copied_generator.parent.mkdir(parents=True, exist_ok=True)
        copied_generator.write_bytes(catalog_generator_source if catalog_generator_source is not None
                                     else source_generator.read_bytes())
    for path, contents in inputs.files.items():
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
    companion = destination / REVIEW_PROJECTION
    companion.parent.mkdir(parents=True, exist_ok=True)
    companion.write_bytes(review_projection() if review_source is None else review_source)
    if catalog_companions is not None:
        # Replace complete historical fixture groups so candidate Artifact IDs
        # do not become unindexed leftovers in the old view. New fixture groups
        # remain for tests of newly added implementation code.
        groups = {Path(path).parts[3] for path in catalog_companions
                  if path.startswith("rust/tests/fixtures/") and len(Path(path).parts) > 4}
        for group in sorted(groups):
            directory = destination / "rust/tests/fixtures" / group
            if directory.is_dir():
                shutil.rmtree(directory)
        for path, (data, mode) in catalog_companions.items():
            file = destination / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
            file.chmod(mode)
        write_json(destination / "catalog-fixture-provenance.json", {
            "sourceCommit": published_info["commit"], "catalogDigest": info["catalogDigest"],
            "files": {path: contract.sha(data) for path, (data, _) in sorted(catalog_companions.items())},
        })
    # The views compile and test the checkout's own Rust, which reads this
    # resource at its repository path.
    helper = ROOT / CODE_SIGN_HELPER
    if helper.is_file():
        copied = destination / CODE_SIGN_HELPER
        copied.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(helper, copied)
    # The integration registries, profiles and lock the provider's
    # registration tests close their hashes over (windows_hdc_registration:
    # the Windows registry beside the macOS ones, the OpenHarmony profile and
    # INTEGRATION-PROFILES.lock.yaml), at their repository paths.
    integrations = ROOT / INTEGRATIONS
    if integrations.is_dir():
        shutil.copytree(integrations, destination / INTEGRATIONS, dirs_exist_ok=True)
    # A development view embeds its own complete selected input baseline.
    # The reconstructed historical JSON bytes may differ from the merge-base's
    # spelling even when every descriptor value is identical. Candidate views
    # retain the separate published baseline for their correlation checks.
    write_json(destination / "spec/baselines/swift-single-v1.json",
               info if info["kind"] == "development" else published_info)
    if info["kind"] == "candidate":
        write_json(destination / "spec/baselines/swift-candidate-inputs.json", info)
    generated = destination / "rust/crates/arkdeck-contract/src"
    (generated / "control_generated.rs").write_text(
        contract.formatted(contract.generate(info, inputs)), encoding="utf-8", newline="\n")
    (generated / "catalog_generated.rs").write_text(
        catalog_source if catalog_source is not None else catalog_rust(inputs, info),
        encoding="utf-8", newline="\n")


def commands(view: Path, output: Path, *, owners: bool = False,
             checkout_tested: bool = False,
             candidate_inputs: bool = False) -> list[tuple[list[str], Path]]:
    rust = view / "rust"
    if checkout_tested:
        # The lane lints and tests the checkout (locally before this script
        # runs; in hosted CI in the workspace job beside this one, and the Rust
        # CI result requires both), and a
        # view of the published inputs compiles the checkout's own sources. It
        # differs only in the two input documents its bindings embed:
        # SWIFT_BASELINE names the merge-base commit and CONTRACT_INPUTS is the
        # candidate document. Of the tests that read them, the arkdeck-contract
        # parity tests assert on their contents, so they run here; arkdeck-cli
        # reads only the kind, and only for a method missing from the registry,
        # which here is main's. Linting and testing the rest again repeated the
        # lane's own two steps, and their flakes, at about two minutes on macOS.
        native = [(["cargo", "test", "--package", "arkdeck-contract", "--locked"], rust)]
        if candidate_inputs:
            # A candidate of drifted inputs is still the checkout's own Rust:
            # the views copy it, and only the two embedded documents differ
            # (CONTRACT_INPUTS of kind `candidate`, SWIFT_BASELINE the merge
            # base). Every other test reads them only to relax an assertion in
            # the published view (`development` with a commit), so it runs as
            # in the lane. arkdeck-cli's resource tests also assert that a
            # candidate exposes what its registry lacks, which only this view
            # can check. Repeating the lane's lint and workspace tests here
            # cost about 15 minutes on Windows (#2545, run 37224202133: the
            # candidate's workspace tests ran out the job's 40 minutes).
            #
            # arkdeck-cli's process tests launch the workspace's binaries
            # beside the CLI (`arkdeck-agentd`, the code-sign helper, ...),
            # which `cargo test -p arkdeck-cli` does not build: they are built
            # first, in this view's own target, so no binary of a cached or
            # other build answers with another contract's digest (#2548's
            # regression: windows_signed_runtime read a stale daemon).
            # Reuse the exact function routes for integration consumers. The
            # router retains --workspace feature unification and all ordinary
            # lib/bin/doc/example defaults; historical cases still execute in
            # the mandatory c6 view, with their own complete receipts.
            native = [([sys.executable, str(rust / "scripts/run-workspace-tests.py"),
                        "--parity-consumers"], rust)]
    else:
        native = [
            (["cargo", "clippy", "--workspace", "--all-targets", "--locked", "--", "-D", "warnings"], rust),
            (["cargo", "test", "--workspace", "--locked"], rust),
        ]
        native[1] = ([sys.executable, str(rust / "scripts/run-workspace-tests.py")], rust)
    result = native + [
        (["cargo", "run", "--package", "arkdeck-platform", "--example", "windows_spk3",
          "--locked", "--", "process-selftest"], rust),
        (["cargo", "build", "--workspace", "--bins", "--locked"], rust),
        ([sys.executable, str(rust / "scripts/check-readonly.py"),
          "--bin-dir", str(rust / "target/debug"), "--output-dir", str(output / "recordings")], view),
    ]
    # New current-owner schemas are candidate inputs until they merge. The
    # merge-base published view still tests its read-only surface.
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
        result.append(([sys.executable, str(rust / "scripts/check-bundle-list.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-bundle-register.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-bundle-retirement.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-hdc-register.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-tool-list.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
        result.append(([sys.executable, str(rust / "scripts/check-tool-retirement.py"),
                        "--bin-dir", str(rust / "target/debug")], view))
    return result


def run_view(view: Path, output: Path, info: dict, published_info: dict, run=subprocess.run,
             *, historical: bool = False, workspace_covered: bool = False) -> None:
    write_json(output / "inputs.json", info)
    provenance = {"schemaVersion": "arkdeck.rust-contract-check/1", "kind": "host-test",
                  "inputKind": info["kind"], "inputDigest": info["inputDigest"],
                  "publishedBaselineCommit": published_info["commit"],
                  "sourceRevision": contract.git("rev-parse", "HEAD").decode().strip(),
                  "generatedRustSourceDigest": rust_digest(view / "rust"),
                  "deviceAcceptance": False, "completed": False, "commands": []}
    if historical:
        provenance['testView'] = 'pinned-historical-catalog'
        provenance['historicalCatalogDigest'] = catalog_test_views.OLD
        provenance['nonCatalogInputSource'] = provenance['sourceRevision']
    if workspace_covered:
        provenance['workspaceCoveredBy'] = 'historical'
    fixture_provenance = view / "catalog-fixture-provenance.json"
    if fixture_provenance.exists():
        fixture_bytes = fixture_provenance.read_bytes()
        (output / "catalog-fixture-provenance.json").write_bytes(fixture_bytes)
        provenance["catalogFixtureProvenanceSHA256"] = contract.sha(fixture_bytes)
    path = output / "provenance.json"
    write_json(path, provenance)
    # Each view owns its compilation artifacts, even if the caller uses a shared
    # Cargo target. No binary from the other view can reach the frame checker.
    environment = os.environ.copy()
    environment["CARGO_TARGET_DIR"] = str(view / "rust/target")
    environment["ARKDECK_RUST_TEST_VIEW"] = 'historical' if historical else "candidate" if info["kind"] == "candidate" else "published"
    environment['ARKDECK_RUST_TEST_REPORT_DIR'] = str(output / 'test-execution')
    # A candidate view is the checkout the lane already linted and tested,
    # whatever its inputs; see commands(). The published view of drifted
    # inputs is the one that compiles the checkout against another contract,
    # and keeps its complete lint and workspace tests.
    checkout_tested = info["kind"] == "candidate" or workspace_covered
    candidate_inputs = (info["kind"] == "candidate"
                        and info["inputDigest"] != published_info["inputDigest"])
    try:
        for argv, cwd in commands(view, output, owners=info["kind"] == "candidate",
                                  checkout_tested=checkout_tested,
                                  candidate_inputs=candidate_inputs):
            print(f'+ [{info["kind"]}] ' + " ".join(argv), flush=True)
            record = {"argv": argv, "completed": False}
            provenance["commands"].append(record)
            write_json(path, provenance)
            result = run(argv, cwd=cwd, env=environment, check=True)
            record.update(completed=True, exitCode=result.returncode)
            write_json(path, provenance)
        provenance.update(completed=True, result="pass")
        if historical:
            receipt = output / 'test-execution/historical/catalog-execution.json'
            value = json.loads(receipt.read_bytes())
            if (value.get('catalogDigest') != catalog_test_views.OLD
                    or value.get('completed') is not True
                    or not any(row.get('execution') == 'actual' and row.get('passed', 0) > 0
                               for row in value['targets'])):
                raise ValueError('mandatory historical owner execution receipt absent or invalid')
            provenance['historicalExecutionReceiptSHA256'] = contract.sha(receipt.read_bytes())
        if candidate_inputs:
            receipt = output / 'test-execution/candidate/catalog-execution.json'
            value = json.loads(receipt.read_bytes())
            if (not isinstance(value, dict) or not isinstance(value.get('targets'), list)
                    or any(not isinstance(row, dict) for row in value['targets'])):
                raise ValueError('candidate consumer execution receipt has an invalid shape')
            executed = set()
            targets = set()
            for row in value['targets']:
                target = row.get('target')
                if (not isinstance(target, str) or not re.fullmatch(r'[A-Za-z0-9_-]+/[A-Za-z0-9_-]+', target)
                        or target in targets):
                    raise ValueError('candidate consumer target is missing, invalid or duplicated')
                targets.add(target)
                if row.get('execution') != 'actual':
                    continue
                selected = row.get('selected')
                passed, ignored = row.get('passed'), row.get('ignored')
                if (row.get('completed') is not True or row.get('coverage') is not True
                        or not isinstance(selected, list) or not selected
                        or any(not isinstance(name, str) or not name for name in selected)
                        or len(set(selected)) != len(selected) or row.get('functions') != selected
                        or type(passed) is not int or passed <= 0
                        or type(ignored) is not int or ignored < 0
                        or passed + ignored != len(selected)
                        or type(row.get('substantivePassed')) is not int
                        or not 0 < row['substantivePassed'] <= passed):
                    raise ValueError('candidate consumer case execution census is incomplete')
                executed.add(target.split('/')[0])
            if (value.get('catalogDigest') != info['catalogDigest']
                    or value.get('completed') is not True
                    or value.get('integrationPackages') != ['arkdeck-cli', 'arkdeck-contract']
                    or executed != {'arkdeck-cli', 'arkdeck-contract'}):
                raise ValueError('mandatory candidate consumer execution receipt absent or invalid')
            provenance['candidateExecutionReceiptSHA256'] = contract.sha(receipt.read_bytes())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        provenance.update(completed=False, result="fail", error=str(error))
        raise
    finally:
        write_json(path, provenance)


def verify_contract_bundle_digests() -> None:
    """Hold the digests the Rust contract export is tested against to the
    committed machine-contract bundle, which the contract views do not carry.
    A checkout without the table owns no products yet (the Rust test embeds
    the table, so a real checkout cannot lose it)."""
    table = ROOT / "rust/tests/fixtures/contracts-bundle/owned.json"
    if not table.exists():
        return
    roots = {
        "contracts": ROOT / "openspec/contracts",
        "fixtures": ROOT / "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI",
    }
    for path, digest in sorted(json.loads(table.read_text()).items()):
        root, _, relative = path.partition("/")
        committed = roots[root] / relative if root in roots else None
        if (committed is None or not committed.is_file()
                or hashlib.sha256(committed.read_bytes()).hexdigest() != digest):
            raise ValueError(f"contract bundle digest drift: {path}")


def check(output_root: Path) -> Path:
    verify_contract_bundle_digests()
    contract.verify_checkout()
    published_commit = contract.published_base()
    published = contract.published_inputs(published_commit)
    published_info = contract.baseline(published, published_commit)
    current = contract.working_inputs()
    current_info = contract.candidate(
        current, published_commit, contract.git("rev-parse", "HEAD").decode().strip())
    historical = historical_catalog_inputs(current)
    historical_info = contract.baseline(historical, json.loads(
        (ROOT / 'rust/tests/fixtures/catalog-lineage-c6-e4/catalogs.json').read_bytes())['oldSourceCommit'])
    if historical_info['catalogDigest'] != catalog_test_views.OLD:
        raise ValueError('mandatory historical input did not reproduce c6')
    published_companions = (published_catalog_companions(published_commit)
                            if published_info["catalogDigest"] != current_info["catalogDigest"]
                            else None)
    # Unsupported candidate vocabulary or stale current Catalog output remains a
    # failure. Regeneration in isolation must not hide a stale committed Catalog.
    contract.generate(current_info, current)
    catalog_path = ROOT / "scripts/catalog_gen/generate.py"
    catalog_bytes = catalog_path.read_bytes()
    catalog_generator = load_module("arkdeck_catalog_snapshot", catalog_path, catalog_bytes)
    catalogs = {"published": catalog_rust(published, published_info, catalog_generator),
                "candidate": catalog_rust(current, current_info, catalog_generator),
                "historical": catalog_rust(historical, historical_info, catalog_generator)}
    catalog = ROOT / "rust/crates/arkdeck-contract/src/catalog_generated.rs"
    if catalog.read_bytes() != catalogs["candidate"].encode():
        raise ValueError("candidate Catalog generated input drift")
    output = output_root.resolve() / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=False)
    failures = []
    source_digest = rust_digest(ROOT / "rust")
    review_source = review_projection()
    # When the working inputs are byte-identical to the published base (the
    # merge-base with origin/main), the published view would be the checkout
    # this lane already linted and tested at top level. Building the same
    # sources again proved nothing more, at 1 to 1.7 minutes per host (the
    # parity step was 2.0, 3.4 and 1.2 minutes on the three hosted runners
    # over #1844..#1873), so the published view is recorded as covered and
    # only the candidate view runs, itself without the lint and workspace
    # tests the lane already ran (see commands()). Any drift keeps both views
    # complete: that is the case the published view exists for.
    published_covered = current_info["inputDigest"] == published_info["inputDigest"]
    # A short task-owned path also bounds Cargo's native Windows build paths.
    temporary_root = ROOT / "rust/target/contract-check"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="views-", dir=temporary_root) as directory:
        rust_source = Path(directory) / "source-rust"
        copy_rust(ROOT / "rust", rust_source)
        if rust_digest(rust_source) != source_digest:
            raise ValueError("Rust sources changed while taking the validation snapshot")
        views = [("published", published, published_info), ("candidate", current, current_info)]
        if published_covered:
            views = views[1:]
            write_json(output / "published/provenance.json", {
                "schemaVersion": "arkdeck.rust-contract-check/1", "kind": "host-test",
                "inputKind": published_info["kind"], "inputDigest": published_info["inputDigest"],
                "publishedBaselineCommit": published_info["commit"],
                "sourceRevision": current_info["sourceRevision"],
                "deviceAcceptance": False, "completed": True, "result": "covered",
                "coveredBy": "candidate", "commands": []})
        views.append(('historical', historical, historical_info))
        for name, inputs, info in views:
            view = Path(directory) / name
            try:
                review = historical_review_projection(review_source) if name == 'historical' else review_source
                materialize(view, inputs, info, published_info, rust_source, catalogs[name], review,
                            catalog_companions=published_companions if name == "published" else None,
                            catalog_generator_source=catalog_bytes)
                if os.environ.get("ARKDECK_RUST_STABLE_VIEWS") == "1":
                    stable = temporary_root / name
                    ci_workspace.sync_tree(view, stable, preserve=(("rust", "target"),))
                    view = stable
                run_view(view, output / name, info, published_info, historical=name == 'historical',
                         workspace_covered=name == 'published' and historical_workspace_covers(published, historical))
            except (OSError, ValueError, subprocess.CalledProcessError) as error:
                failures.append({"view": name, "error": str(error)})
    # Catch inputs changing during a check; the recorded hashes describe the
    # snapshot actually tested, not a later revision of the source workspace.
    if contract.describe_inputs(contract.working_inputs()) != contract.describe_inputs(current):
        failures.append({"view": "candidate", "error": "source inputs changed during validation"})
    if rust_digest(ROOT / "rust") != source_digest:
        failures.append({"view": "source", "error": "Rust sources changed during validation"})
    if review_projection() != review_source:
        failures.append({"view": "source", "error": "App review projection changed during validation"})
    if catalog_path.read_bytes() != catalog_bytes:
        failures.append({"view": "source", "error": "Catalog generator changed during validation"})
    contract.verify_checkout()
    write_json(output / "summary.json", {
        "schemaVersion": "arkdeck.rust-dual-contract-check/1", "kind": "host-test",
        "deviceAcceptance": False, "publishedBaselineCommit": published_info["commit"],
        "sourceRustDigest": source_digest,
        "appReviewProjectionSHA256": contract.sha(review_source),
        "catalogGeneratorSHA256": contract.sha(catalog_bytes),
        "candidateInputDigest": current_info["inputDigest"],
        "publishedView": "covered-by-candidate" if published_covered else "run",
        "historicalCatalogDigest": historical_info['catalogDigest'],
        "historicalView": "mandatory-run",
        "completed": not failures, "failures": failures,
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
