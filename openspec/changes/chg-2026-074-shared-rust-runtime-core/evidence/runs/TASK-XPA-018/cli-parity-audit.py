#!/usr/bin/env python3
"""Classify every cli-feature-coverage.json entry against the Rust CLI (TASK-XPA-018).

Run from the repository root after `cargo build -p arkdeck-cli` in rust/:
    python3 openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/\
TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck
Read-only. Inputs, all from the checkout at the repository root:
- openspec/contracts/cli-feature-coverage.json (the 256 entries);
- rust/crates/arkdeck-cli/src/command_registry.json (Swift's registry projection);
- the Rust CLI's own `arkdeck commands --output json` (the leaves it serves), from
  the binary given as argv[1];
- rust/crates/arkdeck-cli/tests/argv_fixtures.rs (the pinned argv deviations);
- rust/crates/arkdeck-control/src/lib.rs (the isolated daemon's routed methods).
Prints the per-entry table and the summary as Markdown.
"""
import collections
import json
import re
import subprocess
import sys

CLI = sys.argv[1]
coverage = json.load(open("openspec/contracts/cli-feature-coverage.json"))
registry = json.load(open("rust/crates/arkdeck-cli/src/command_registry.json"))
leaves = {entry["command"]: entry for entry in registry["commands"]}
served_answer = json.loads(subprocess.check_output([CLI, "commands", "--output", "json"]))
served = {entry["command"] for entry in served_answer["result"]["commands"]}

tests = open("rust/crates/arkdeck-cli/tests/argv_fixtures.rs").read()
deviations = collections.defaultdict(list)
for leaf, case in re.findall(r'\("([a-z.-]+)", "([A-Za-z]+)", (?:true|false)\)', tests):
    deviations[leaf].append(case)

control = open("rust/crates/arkdeck-control/src/lib.rs").read()
match = control.split("let response = match request.method.as_str() {", 1)[1]
match = match.split("\n            _ => Response::failure", 1)[0]
routed = set()
for line in match.splitlines():
    if re.match(r'^ {12}("|\| ")', line):
        routed.update(re.findall(r'"([a-zA-Z][a-zA-Z.-]+)"', line.split("=>")[0]))

# The methods each Swift handler sends, for the Runtime leaves the Rust CLI does
# not serve (ArkDeckRuntimeCommands.swift and its siblings). Domain leaves — a
# registry `catalogOperation` — all go through `runDomainOperation`, whose
# one-shot executor (AgentRuntimeExecutor) reads health, the operation, the
# Targets and device observations, may adopt, then submits, runs, cancels on a
# non-terminal answer and reads evidence.
DOMAIN = ["health", "operation.describe", "target.list", "device.observations",
          "target.adopt", "job.submit", "job.run", "job.cancel", "job.evidence"]
SWIFT_METHODS = {
    "runtime.health": ["health"],
    "operation.validate": ["health", "operation.describe"],
    "device.wait": ["device.observations"],
    "device.list": ["target.list"],
    "device.show": ["target.list"],
    "trace.probe": ["trace.probe"],
    "trace.inspect": ["trace.inspect"],
    "trace.export": ["artifact.inspect", "artifact.export"],
    "job.wait": ["job.status"],
    "job.watch": ["job.events", "job.status"],
    "job.reconcile": ["job.reconcile"],
    "recovery.cleanup.list": ["cleanupDebt.list"],
    "recovery.cleanup.continue": ["cleanupDebt.continue"],
    "cleanup-debt.list": ["cleanupDebt.list"],
    "cleanup-debt.continue": ["cleanupDebt.continue"],
    "recovery.flash-invocation.list": ["recovery.flash-invocation.list"],
    "recovery.flash-invocation.start": ["debug.start"],
    "recovery.flash-invocation.evaluate": ["debug.evaluate"],
    "recovery.flash-invocation.status": ["debug.status"],
    "debug.start": ["debug.start"],
    "debug.evaluate": ["debug.evaluate"],
    "debug.status": ["debug.status"],
    "debug.probe": ["debug.probe"],
    "diagnostics.inspect": ["job.show", "artifact.list", "artifact.read"],
    "diagnostics.preview": ["job.show", "artifact.list", "artifact.read"],
    "diagnostics.export": ["job.show", "artifact.list", "artifact.read"],
    "ui-dump.inspect": ["artifact.list", "artifact.read"],
    "ui-dump.hit-test": ["artifact.list", "artifact.read"],
    "workspace.continuation.inspect": ["health", "job.show", "target.show"],
    "workspace.continuation.submit": ["health", "job.show", "target.show", "job.submit"],
    "workspace.continuation.run": ["health", "job.show", "target.show", "job.submit", "job.run"],
    "flash.device-access": ["flash.device-access"],
    "flash.bootloader-status": ["flash.bootloader-status"],
    "flash.prerequisites": ["flash.prerequisites"],
    "flash.lane-preview": ["flash.lanePlanPreview"],
    "flash.reconcile-alias": ["flash.reconcile-alias"],
    "flash.bind-loader": ["flash.bind-current-loader"],
}
# Local leaves (no Runtime connection) and the host subsystem each runs in the
# Swift CLI's own process, where one has no Rust port yet.
HOST_SUBSYSTEM = {
    "runtime.service.install": "LaunchAgent service (maintainer gate)",
    "runtime.service.update": "LaunchAgent service (maintainer gate)",
    "runtime.service.restart": "LaunchAgent service (maintainer gate; record only)",
    "runtime.service.status": "LaunchAgent service (maintainer gate; record only)",
    "runtime.service.verify": "LaunchAgent service (maintainer gate; record only)",
    "runtime.service.uninstall": "LaunchAgent service (maintainer gate)",
    "runtime.signing.install": "signing credentials and Keychain (XPA-015, SPK-10)",
    "runtime.signing.install-sdk-release": "signing credentials and Keychain (XPA-015, SPK-10)",
    "runtime.signing.migrate-deveco": "signing credentials and Keychain (XPA-015, SPK-10)",
    "runtime.signing.remove": "signing credentials and Keychain (XPA-015, SPK-10)",
    "runtime.signing.status": "signing credentials and Keychain (XPA-015, SPK-10)",
    "runtime.support-bundle.preview": "support bundle (ClientKit, #2057)",
    "runtime.support-bundle.export": "support bundle (ClientKit, #2057)",
    "runtime.update.check": "updater (ClientKit, #2054)",
    "runtime.update.download": "updater (ClientKit, #2054)",
    "runtime.update.handoff": "updater (ClientKit, #2054)",
    "runtime.update.status": "updater (ClientKit, #2054)",
    "runtime.update.cancel": "updater (ClientKit, #2054)",
    "runtime.update.cleanup": "updater (ClientKit, #2054)",
    "maintainer.update-feed.prepare": "update-feed signing (maintainer tooling)",
    "maintainer.update-feed.assemble": "update-feed signing (maintainer tooling)",
    "maintainer.contracts.export": "contract bundle export (XPA-018 acceptance)",
    "maintainer.contracts.check": "contract bundle export (XPA-018 acceptance)",
}
# The Catalog operations the isolated Rust daemon runs end to end
# (evidence/macos-remaining.md, Operations), and those it plans, admits and
# runs only against the account-fixed default root.
EXECUTABLE = {"analyzer.extract-crash-signature@1", "observe.device@1", "capture.diagnostics@1"}
FIXED_ROOT_ONLY = {"input.tap@1", "input.long-press@1", "input.swipe@1", "port-forward.create@1",
                   "port-forward.remove@1", "debug.hap@1", "deploy.native-library.app-owned@1",
                   "capture.screen-sequence@1"}
# CLI spec §12's migrations of a deprecated or legacy spelling to a tombstone.
TOMBSTONE_PLAN = {
    "agentd": "next major: `runtime service ...` (alias warns until then)",
    "signing": "next major: `runtime signing ...`",
    "update-feed": "next major: `maintainer update-feed ...`",
    "device.list": "next major: `commandRemoved`, replacement `target list`",
    "device.show": "next major: `commandRemoved`, replacement `target show --target <id>`",
    "debug.start": "next major: named tombstone, replacement `recovery flash-invocation start`",
    "debug.evaluate": "next major: named tombstone, replacement `recovery flash-invocation evaluate`",
    "debug.status": "next major: named tombstone, replacement `recovery flash-invocation status`",
    "flash.install-binding": "tombstone once the current Loader binding path closes",
}


def leaf_of(pattern):
    if not pattern:
        return None
    words = []
    for word in pattern.split()[1:]:
        if word.startswith(("-", "(", "<", "[", "...", "|")):
            break
        words.append(word)
    name = ".".join(words)
    assert name in leaves, (pattern, name)
    return name


def operation_note(operation):
    if operation in EXECUTABLE:
        return f"`{operation}` runs on the isolated daemon"
    if operation in FIXED_ROOT_ONLY:
        return f"`{operation}` runs only against the default root; the isolated daemon reports it unavailable"
    return f"`{operation}` has no Rust runner, so the isolated daemon does not execute it"


def classify(entry):
    leaf = leaf_of(entry["targetCommand"])
    if leaf is None:
        return "implemented", None, "presentation only: no CLI leaf"
    spec = leaves[leaf]
    if leaf in served:
        note = ""
        if deviations.get(leaf):
            note = "argv deviates: " + ", ".join(sorted(deviations[leaf]))
        return "implemented", leaf, note
    family = leaf.split(".")[0]
    plan = TOMBSTONE_PLAN.get(leaf) or TOMBSTONE_PLAN.get(family)
    if spec["kind"] == "tombstone":
        return "tombstone", leaf, "removed: Swift answers `commandRemoved`; Rust must answer the same"
    if spec["lifecycleStatus"] in ("deprecated", "legacy") and plan:
        return "tombstone", leaf, f"{spec['lifecycleStatus']}: {plan}"
    if not spec["connectsToRuntime"]:
        if leaf in HOST_SUBSYSTEM:
            return "unrouted", leaf, "local; " + HOST_SUBSYSTEM[leaf] + " has no Rust port"
        what = "refused stub" if spec["kind"] == "refused" else "local"
        return "routed", leaf, f"{what}: needs no Runtime"
    operation = spec["catalogOperation"]
    methods = DOMAIN if operation else SWIFT_METHODS[leaf]
    missing = [method for method in methods if method not in routed]
    if missing:
        return "unrouted", leaf, "not routed: " + ", ".join(f"`{m}`" for m in missing)
    if operation:
        return "routed", leaf, "domain leaf; " + operation_note(operation)
    return "routed", leaf, "methods: " + ", ".join(f"`{m}`" for m in methods)


LABEL = {"implemented": "1 implemented", "routed": "2 leaf missing, daemon routed",
         "unrouted": "3 daemon or host owner missing", "tombstone": "4 tombstone per §12"}
rows = []
counts = collections.Counter()
for entry in coverage["entries"]:
    category, leaf, note = classify(entry)
    counts[category] += 1
    rows.append((entry["feature"], entry["classification"], entry["lifecycle"],
                 f"`{leaf}`" if leaf else "—", LABEL[category], note))

print("| Category | Entries |")
print("| --- | --- |")
for category in ("implemented", "routed", "unrouted", "tombstone"):
    print(f"| {LABEL[category]} | {counts[category]} |")
print(f"| total | {sum(counts.values())} |")
print()
print(f"Rust CLI serves {len(served)} leaves; the isolated daemon routes {len(routed)} of "
      f"105 methods.")
print()
print("| Feature | Classification | Lifecycle | Target leaf | Category | Note |")
print("| --- | --- | --- | --- | --- | --- |")
for row in rows:
    print("| " + " | ".join(row) + " |")

# Every registry leaf the Rust CLI does not serve, by the same rules: the work
# list, including leaves no coverage entry targets (equivalents and aliases).
print()
print(f"| Registry leaf not served ({len(leaves) - len(served)} of {len(leaves)}) | Kind, lifecycle | Category | Note |")
print("| --- | --- | --- | --- |")
by_category = collections.Counter()
for name, spec in leaves.items():
    if name in served:
        continue
    category, _, note = classify({"targetCommand": "arkdeck " + " ".join(spec["path"])})
    by_category[category] += 1
    print(f"| `{name}` | {spec['kind']}, {spec['lifecycleStatus']} | {LABEL[category]} | {note} |")
print()
print("| Registry leaves not served, by category | Leaves |")
print("| --- | --- |")
for category in ("routed", "unrouted", "tombstone"):
    print(f"| {LABEL[category]} | {by_category[category]} |")
