#!/usr/bin/env python3
"""Compare the Rust host-store candidates against the actual Swift store readers.

Every store lives in a fresh test-owned temporary directory. Document snapshots
reach Rust over stdin; Trace inventory reads the explicit isolated cache root.
The runner never selects an installed Runtime or App cache.
Receipts contain hashes and case names, never filter strings or snapshot bytes.
A local run is not a nightly day or hardware evidence. Scheduled receipts must
be matched to their actual Actions run before any cutover gate can consume them.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STEP_KINDS = (
    "probeHostTool", "probeHDCServer", "mutateHDCServerLifecycle", "probeDevice", "captureRemoteStdout",
    "captureRemoteFile", "stopRemoteCapture", "sendFile", "receiveFile", "snapshotParameter", "setParameter",
    "restoreParameter", "waitForDisconnect", "waitForReconnect", "verifyRemoteState", "verifyArtifact",
    "preflightHostStorage", "preflightDeviceStorage", "hashFile", "postprocessArtifact", "cleanupOwnedRemotePath",
    "requestConfirmation", "installPackage", "uninstallPackage", "startApplication", "stopApplication",
    "createPortForward", "removePortForward", "injectPointerInput", "clearLogBuffer", "resizeLogBuffer",
    "startDeviceLogPersist", "runApprovedRemoteRead", "runApprovedRemoteMutation", "rebootDevice", "enterUpdater",
    "flashPartition", "updatePackage", "erasePartition", "formatPartition", "unlockDevice", "finalizeSession",
    "inspectWorkspaceSource", "prepareWorkspaceIsolation", "sweepWorkspaceIsolation", "applyWorkspacePatch",
    "buildWorkspaceOpenHarmony", "signWorkspaceOpenHarmonyHap", "runWorkspaceTests", "symbolizeWorkspaceCrash",
    "revertWorkspacePatch", "inspectWorkspaceGitStatus", "inspectWorkspaceDiff", "readWorkspaceSourceRange",
    "createWorkspaceCheckpoint", "runDeterministicAnalyzer",
)
EXPECTED = {
    **{f"inventory-semantics-{name}": "equal" for name in ("valid", "effect-understated", "cancellation-understated", "binding-understated",      "unknown-kind", "unknown-effect", "unknown-cancellation", "unknown-binding", "unknown-disposition",      "unknown-certainty", "unknown-result", "executed-not-run", "skipped-confirmed", "skipped-valid",      "unknown-terminal", "failed-success", "failed-failed", "missing-binding", "unknown-binding-revision",      "negative-duration", "maximum-duration", "null-duration", "overflow-exit", "minimum-exit",      "source-without-trigger", "trigger-without-source", "duplicate-step", "standard-executed",      "standard-skipped-success", "standard-skipped-cancelled", "plan-executed", "plan-skipped")},
    **{f"inventory-audit-{name}": "equal" for name in (
        "readonly-hdc", "readonly-arkforge", "capability-hdc", "capability-arkforge", "hdc-label", "arkforge-label",
        "artifact-digest", "maximum-ordinal", "unordered-times", "hdc-extra-field", "hdc-cross-branch-field", "readonly-declared-compensation",
        "capability-compensation", "missing-audit", "unknown-audit-kind", "extra-audit-field", "missing-audit-field", "empty-reference",
        "invalid-admitted-date", "invalid-valid-until", "empty-reservation", "zero-ordinal", "overflow-ordinal", "digest-shape",
        "artifact-digest-shape", "readonly-consumption", "mutation-with-readonly", "readonly-artifact", "label-wrong-provider",
        "label-wrong-step", "label-without-capability", "unknown-provider", "host-tool-audit", "planonly-provider",
        "simulated-provider", "host-provider-target", "readonly-compensation-mutation")},
    **{f"inventory-recovery-{name}": "equal" for name in (
        "interrupted", "failed", "cancelled", "unknown-mode", "guide-automatic", "failed-no-attention", "last-confirmed-null",
        "recovery-of-pair", "unexecuted", "unexecuted-duplicate", "unknown-step", "notStarted", "notRunning", "stoppedAtSafeBoundary",
        "stillRunningUnknown", "notApplicable", "success-recovery", "planned-recovery", "interrupted-no-audit",
        "interrupted-no-confirmation", "interrupted-no-attention", "interrupted-no-reason", "empty-reason", "missing-key", "extra-key",
        "duplicate-audit", "bad-audit-id", "unknown-last-step", "invalid-recovery-of", "hazard-extra", "hazard-bad-severity",
        "hazard-empty-summary", "device-mode-extra", "device-mode-empty-evidence", "unknown-process", "guide-empty-steps",
        "guide-empty-item", "guide-extra", "confirmation-actor", "confirmation-date", "confirmation-missing-key",
        "undeclared-compensation", "mismatched-compensation", "unexecuted-bad-hash")},
    "graphemes-unicode-16.0.0": "equal", "graphemes-unicode-17.0.0": "equal", "graphemes-indic-properties": "equal",
    **{f"inventory-argument-{name}": "equal" for name in (
        "identifier-boundary", "identifier-overflow", "scalar-boundary", "scalar-overflow",
        "relative-unicode-length", "relative-combining-slash", "relative-prepend-dot", "remote-combining-slash",
        "remote-prepend-slash", "remote-empty-segments", "remote-traversal", "remote-ascii-control", "remote-c1-control",
        "optional-hash-null", "optional-generation-null", "optional-generation-maximum", "pointer-null-optionals",
        "swipe-missing-endpoint", "swipe-boundary", "swipe-duration-underflow", "options-null-scalar", "options-null-array",
        "options-array-boundary", "options-array-overflow", "options-unsafe-key", "options-nested-object",
        "frames-untyped-null", "frames-unsafe-key", "forbidden-action", "signing-preset-reference", "signing-preset-empty",
        "diagnostics-id-newline", "diagnostics-id-overflow", "diagnostics-fault-newline", "diagnostics-fault-path",
        "diagnostics-hilog", "diagnostics-hilog-filter", "argument-extra-field")},
    **{f"inventory-compensation-{kind}-{variant}": "equal" for kind in
        ("stopRemoteCapture", "restoreParameter", "cleanupOwnedRemotePath", "removePortForward", "stopApplication", "uninstallPackage")
        for variant in ("executed", "with-step", "executed-failed", "unknown-result", "not-run", "step-trigger-mismatch",
                        "undeclared-step", "duplicate-descriptor", "duplicate-record", "unknown-source", "hash-mismatch",
                        "record-mismatch", "missing-failure", "not-run-with-failure")},
    **{f"inventory-step-{kind}-{variant}": "equal" for kind in STEP_KINDS
        for variant in ("valid", "extra-field", "missing-argument", "wrong-hash")},
    **{f"inventory-confirmation-{name}": "equal" for name in ("deviceMutation", "destructive",
        "serverLifecycle", "recoveryAbandon", "securityBoundary", "rejected", "unknown-kind",
        "unknown-decision", "unknown-actor", "actor-extra-field", "extra-field", "invalid-id",
        "invalid-hash", "invalid-date", "unknown-step", "duplicate-id")},
    **{f"inventory-parameter-{kind}-{bound}": "equal" for kind in
        ("crlf", "combining", "flag", "hangul", "indic", "skin-tone", "prepend") for bound in ("boundary", "too-long")},
    **{f"inventory-parameter-{name}": "equal" for name in ("restored", "missing-before", "unreadable-before",
        "empty-value", "unicode-boundary", "failed-session", "different-bytes", "restored-missing-before",
        "desired-missing", "value-too-long", "unicode-too-long", "state-extra-field", "success-failed-restore", "unreadable-empty-reason")},
    **{f"inventory-{name}": "equal" for name in ("empty", "unregistered", "registered", "pinned", "leap-second",
        "unscoped", "corrupt-manifest", "symlink", "corrupt-catalog", "missing-catalog",
        "fresh-catalog", "reconcile-policy", "duplicate-identity", "reconcile-removed",
        "unscoped-retains-missing", "identity-mismatch", "extra-catalog-field",
        "artifact-hash-mismatch", "artifact-lineage-cycle", "artifact-invalid-path")},
    **{f"timestamp-accepted-{i}": "equal" for i in range(10)},
    **{f"timestamp-refused-{i}": "refused" for i in range(10)},
    **{f"history-{state}-{index}": "equal" for state in ("saved", "deleted") for index in range(3)},
    "history-maximum-generation": "equal",
    **{f"history-invalid-{name}": "refused" for name in (
        "status", "mode", "time-range", "activity", "search-bound", "search-control", "session-empty", "target-bound", "search-format-control", "session-leading-space")},
    **{f"names-invalid-{name}": "refused" for name in (
        "unordered-targets", "duplicate-target", "duplicate-candidate", "stage-unpaired", "stage-mismatch", "target-identifier", "candidate-empty", "candidate-bound",
        "observation-empty", "observation-bound", "candidate-key-collision",
        "name-empty", "name-bound", "name-space", "name-format-control", "canonical-duplicate-candidate")},
    "history-extra-query-field": "refused",
    "history-extra-document-field": "refused",
    **{f"trace-{state}": "equal" for state in ("empty", "unaccounted", "ready-inactive", "key-contended", "lease-contended")},
    "trace-entry-symlink": "refused", "trace-entry-overflow": "refused",
    **{f"session-{state}": "equal" for state in ("policy", "custom-root", "maximum-quota")},
    "session-extra-policy-field": "refused", "session-extra-document-field": "refused",
    **{f"names-{state}": "equal" for state in ("targets", "tombstone", "candidate", "decomposed-unicode", "canonical-stage", "embedded-null-candidate")},
    "names-extra-record-field": "refused", "names-extra-index-field": "refused",
    **{f"{kind}-{state}": "equal" for kind in ("bundle", "tool") for state in ("available", "retained", "removed")},
    **{f"{kind}-extra-{level}-field": "refused" for kind in ("bundle", "tool") for level in ("record", "index")},
}
INPUTS = [
    "rust/scripts/generate-swift-grapheme-tables.py",
    "rust/crates/arkdeck-hoststore/UNICODE-LICENSE",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Unicode/GraphemeBreakTest-16.0.0.txt",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Unicode/GraphemeBreakTest-17.0.0.txt",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Unicode/DerivedCoreProperties-17.0.0.txt",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Unicode/LICENSE.txt",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostStoreStepShadowFixtures.swift",
    ".github/workflows/swift-slow-lanes.yml",
    "Packages/ArkDeckKit/Scripts/run-swiftpm.sh",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/SessionStorage/SessionStorageFixtures.swift",
    "rust/scripts/test_hoststore_shadow.py",
    "rust/Cargo.lock", "rust/Cargo.toml", "rust/rust-toolchain.toml",
    "Packages/ArkDeckKit/Package.swift", "Packages/ArkDeckKit/Package.resolved",
    "rust/crates/arkdeck-hoststore/Cargo.toml",
    "rust/crates/arkdeck-hoststore/src/lib.rs",
    "rust/crates/arkdeck-hoststore/src/main.rs",
    "rust/crates/arkdeck-hoststore/src/registry.rs",
    "rust/crates/arkdeck-hoststore/src/session.rs",
    "rust/crates/arkdeck-hoststore/src/trace.rs",
    "rust/crates/arkdeck-platform/src/host_store.rs",
    "Packages/ArkDeckKit/Sources/ArkDeckTraceAdapter/ArkDeckTraceConfiguration.swift",
    "Packages/ArkDeckKit/Tests/ArkDeckTraceAdapterTests/HostStoreTraceShadowTests.swift",
    "rust/crates/arkdeck-hoststore/src/display_names.rs",
    "rust/scripts/hoststore-shadow.py",
    "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryFilterStore.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeSessionStorageStore.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionRetentionCatalog.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/RuntimeTargetDisplayNameStore.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/CanonicalDigests.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckCore/ArkDeckHelperIdentity.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapBundleRegistry.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolRegistry.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolTrust.swift",
    "Packages/ArkDeckKit/Sources/ArkDeckBootstrap/BootstrapToolFiles.swift",
    "Packages/ArkDeckKit/Tests/ArkDeckContractTests/HostStoreShadowContractTests.swift",
]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes() -> dict[str, str]:
    # Include transitive local implementations, not just the top-level decoders.
    paths = set(INPUTS)
    for module in ("ArkDeckCore", "ArkDeckStorage", "ArkDeckWorkflows", "ArkDeckBootstrap", "ArkDeckTraceAdapter"):
        paths.update(str(path.relative_to(ROOT)) for path in
                     (ROOT / "Packages/ArkDeckKit/Sources" / module).rglob("*.swift"))
    paths.update(str(path.relative_to(ROOT)) for path in (ROOT / "rust/crates").rglob("*.rs"))
    paths.update(str(path.relative_to(ROOT)) for path in (ROOT / "rust/crates").glob("*/Cargo.toml"))
    return {path: digest((ROOT / path).read_bytes()) for path in sorted(paths)}


def validate_cases(directory: Path) -> list[dict]:
    files = sorted(directory.glob("*.json"))
    if {path.stem for path in files} != set(EXPECTED):
        raise ValueError("missing or unexpected cross-language cases; no receipt published")
    cases = []
    for path in files:
        case = json.loads(path.read_bytes())
        if set(case) != {"case", "store", "outcome", "inputSHA256", "projectionSHA256", "oracleBinarySHA256"}:
            raise ValueError("unexpected case shape")
        expected_store = {"history": "history-filter", "bundle": "bundle-registry", "tool": "tool-registry", "names": "display-names", "session": "session-configuration", "trace": "trace-cache", "timestamp": "session-timestamp", "inventory": "session-storage", "graphemes": "session-graphemes"}[path.stem.split("-", 1)[0]]
        if (case["case"] != path.stem or case["store"] != expected_store
                or case["outcome"] != EXPECTED[path.stem]):
            raise ValueError("case identity or outcome mismatch")
        for key in ("inputSHA256", "projectionSHA256", "oracleBinarySHA256"):
            if len(case[key]) != 64 or any(c not in "0123456789abcdef" for c in case[key]):
                raise ValueError("invalid digest")
        cases.append(case)
    if len({case["oracleBinarySHA256"] for case in cases}) != 1:
        raise ValueError("Swift oracle binary changed between cases")
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="new digest-only receipt; existing files are never replaced")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output already exists")
    started = datetime.now(timezone.utc).isoformat()
    hashes = source_hashes()
    subprocess.run([os.environ.get("ARKDECK_PYTHON", "python3"), "rust/scripts/generate-swift-grapheme-tables.py",
                    "--input", "Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Unicode/DerivedCoreProperties-17.0.0.txt",
                    "--output", "rust/crates/arkdeck-hoststore/src/session_grapheme_tables.rs", "--check"],
                   cwd=ROOT, check=True, timeout=30)
    subprocess.run(["cargo", "build", "--locked", "-p", "arkdeck-hoststore"],
                   cwd=ROOT / "rust", check=True, timeout=600)
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked"], cwd=ROOT / "rust"))
    binary = Path(metadata["target_directory"]) / "debug/arkdeck-hoststore"
    binary_hash = digest(binary.read_bytes())
    with tempfile.TemporaryDirectory(prefix="arkdeck-shadow-results-") as results:
        env = dict(os.environ, ARKDECK_HOSTSTORE_SHADOW_BINARY=str(binary),
                   ARKDECK_HOSTSTORE_SHADOW_RESULTS=results)
        subprocess.run(["sh", "Packages/ArkDeckKit/Scripts/run-swiftpm.sh", "test", "-j", "4",
                        "--filter", "HostStoreShadowContractTests|HostStoreTraceShadowTests"], cwd=ROOT, env=env,
                       check=True, timeout=900)
        cases = validate_cases(Path(results))
    if source_hashes() != hashes or digest(binary.read_bytes()) != binary_hash:
        raise ValueError("source or binary changed during comparison; no receipt published")
    receipt = {
        "schemaVersion": "arkdeck.hoststore-shadow-run/1",
        "kind": "isolated-host-differential",
        "startedAtUTC": started,
        "completedAtUTC": datetime.now(timezone.utc).isoformat(),
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "sourceFiles": hashes,
        "sourceDirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "sourceDiffSHA256": digest(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT)),
        "binarySHA256": binary_hash,
        "swiftOracleBinarySHA256": cases[0]["oracleBinarySHA256"],
        "host": {"system": platform.system(), "version": platform.mac_ver()[0],
                 "machine": platform.machine()},
        "toolchains": {
            "swift": subprocess.check_output([os.environ.get("ARKDECK_SWIFT_EXECUTABLE", "swift"), "--version"],
                                             cwd=ROOT, text=True, timeout=30).strip(),
            "rust": subprocess.check_output(["rustc", "--version", "--verbose"],
                                            cwd=ROOT / "rust", text=True, timeout=30).strip(),
            "xcode": subprocess.check_output(["xcodebuild", "-version"],
                                             cwd=ROOT, text=True, timeout=30).strip(),
        },
        "cases": cases,
        "coveredStores": ["history-filter", "bundle-registry", "tool-registry", "display-names", "session-configuration", "trace-cache"],
        "remainingStores": ["session-storage"],
        "remainingCoverage": ["complete Session manifest branches and scan failure matrix", "full semantic refusal parity", "tool published identity/selection", "filesystem ownership and cutover"],
        "cutoverEligible": False,
        # These are provenance hints, not trusted approval or seven-day proof.
        "actions": {key: os.environ.get(key) for key in (
            "GITHUB_REPOSITORY", "GITHUB_EVENT_NAME", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")},
    }
    # Exclusive publication means a rerun cannot silently overwrite its earlier evidence.
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"Compared {len(cases)} cases; digest-only receipt: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
