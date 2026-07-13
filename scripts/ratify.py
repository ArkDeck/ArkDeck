#!/usr/bin/env python3.14
"""ArkDeck ratification orchestrator.

Executes the hash-ordered mechanics of ratification on explicit human
instruction. The human decision itself is expressed by signing with the
approval key held outside the repository; this tool only sequences edits,
computes subject hashes and invokes ssh-keygen for the signatures.

Subcommands:
  install                 copy verifiers into the trust host dir, print hashes
  bundle                  write the trust-root bundle for the CURRENT policy
  axes --approver ID      accept trust policy + 4 axis locks, write approvals
  change --change DIR --approver ID --base COMMIT
                          approve one change and flip its packets to ready
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

from sdd_protected_set import require_sdd_runtime

require_sdd_runtime()

import yaml

ROOT = Path(__file__).resolve().parent.parent
APPROVALS = ROOT / "openspec/approvals"
VERIFIER_SOURCES = ROOT / "openspec/governance/verifiers"
VERIFIER_NAMES = ["verify-approval.py", "verify-claim-service.py", "verify-identity-ledger.py"]
ROOT_ID = "ORG-ARKDECK-ROOT-1"
REPOSITORY_ID = "ORG-ARKDECK-REPOSITORY-1"
APPROVAL_SUBJECT_TYPES = [
    "trustPolicy", "baseline", "integrationLock", "platformLock",
    "platformReleaseSubject", "conformanceSuite", "change", "taskPacket",
    "taskRun", "taskSupersession", "labExecutionAuthorization",
    "platformConformance", "changeVerification", "evidence",
    "hardwareEvidence", "archiveSourceVerification", "archive",
]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def head() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout.strip()


def edit(path: Path, replacements: list[tuple[str, str, int]]) -> None:
    text = path.read_text(encoding="utf-8")
    for pattern, replacement, count in replacements:
        text, hits = re.subn(pattern, replacement, text, count=count, flags=re.MULTILINE)
        if hits != count:
            if replacement in text:
                continue  # already applied on a previous run
            raise SystemExit(f"ERROR: edit {path.name}: pattern {pattern!r} matched {hits}, expected {count}")
    path.write_text(text, encoding="utf-8")


def verifier_entries(trust: Path) -> list[dict]:
    entries = []
    meta = {
        "verify-approval.py": ("ORG-PROTECTED-REVIEW-VERIFIER", ["detachedSignature"], APPROVAL_SUBJECT_TYPES),
        "verify-claim-service.py": ("ORG-PROTECTED-CLAIM-SERVICE-VERIFIER", ["protectedClaimService"],
                                    ["taskClaim", "taskRunLease", "resourceIdentitySet", "changeSupersessionBarrier"]),
        "verify-identity-ledger.py": ("ORG-PROTECTED-IDENTITY-LEDGER-VERIFIER", ["protectedIdentityLedger"],
                                      ["identityLedger"]),
    }
    for name in VERIFIER_NAMES:
        installed = trust / "verifiers" / name
        vid, mechanisms, subjects = meta[name]
        entries.append({
            "id": vid, "mechanisms": mechanisms, "subject_types": subjects,
            "executable_path": str(installed), "sha256": sha(installed),
        })
    return entries


def cmd_install(trust: Path) -> None:
    (trust / "verifiers").mkdir(parents=True, exist_ok=True)
    for name in VERIFIER_NAMES:
        target = trust / "verifiers" / name
        shutil.copyfile(VERIFIER_SOURCES / name, target)
        target.chmod(target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        print(f"installed {target} sha256={sha(target)}")


def cmd_bundle(trust: Path) -> None:
    policy = ROOT / "openspec/governance/trust-policy.yaml"
    bundle = {
        "root_id": ROOT_ID,
        "repository_id": REPOSITORY_ID,
        "trust_policy_sha256": sha(policy),
        "external_verifiers": verifier_entries(trust),
    }
    target = trust / "bundle.yaml"
    target.write_text(yaml.safe_dump(bundle, sort_keys=False, width=100), encoding="utf-8")
    print(target)


def sign_subject(trust: Path, subject: Path) -> str:
    subprocess.run(
        ["ssh-keygen", "-Y", "sign", "-f", str(trust / "keys/approval"),
         "-n", "arkdeck-approval", str(subject)],
        capture_output=True, check=True,
    )
    sig = subject.with_name(subject.name + ".sig")
    text = sig.read_text(encoding="utf-8")
    sig.unlink()
    return text


def write_approval(trust: Path, *, approval_id: str, subject: Path, subject_type: str,
                   subject_id: str, revision: int, base: str, approver: str) -> None:
    APPROVALS.mkdir(parents=True, exist_ok=True)
    record = {
        "schemaVersion": "1.0.0",
        "approvalId": approval_id,
        "subjectType": subject_type,
        "subjectId": subject_id,
        "subjectRevision": revision,
        "subjectSha256": sha(subject),
        "baseRevision": base,
        "decision": "approved",
        "approver": {"kind": "human", "id": approver},
        "approvedAt": now(),
        "mechanism": "detachedSignature",
        "approvalRef": f"arkdeck-trust:{ROOT_ID}:{approval_id}",
        "signature": sign_subject(trust, subject),
    }
    target = APPROVALS / f"{approval_id}.json"
    target.write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")
    print(f"approval {approval_id} -> {subject.relative_to(ROOT)}")


def cmd_axes(trust: Path, approver: str) -> None:
    base = head()
    date = dt.date.today().isoformat()
    policy = ROOT / "openspec/governance/trust-policy.yaml"
    verifier_yaml = yaml.safe_dump(
        {"external_verifiers": verifier_entries(trust)}, sort_keys=False, width=100
    ).rstrip("\n")
    edit(policy, [
        (r"^status: unconfigured$", "status: accepted", 1),
        (r"^execution_gate: closed$", "execution_gate: open", 1),
        (r"^bootstrap_root_id: null$", f"bootstrap_root_id: {ROOT_ID}", 1),
        (r"^ratification:\n  approval_ref: null$",
         "ratification:\n  approval_ref: APR-TRUST-POLICY-1", 1),
        (r"^external_verifiers: \[\]$", verifier_yaml, 1),
    ])
    integration = ROOT / "openspec/integrations/INTEGRATION-PROFILES.lock.yaml"
    edit(integration, [
        (r"^status: review$", "status: accepted", 1),
        (r"^accepted_at: null$", f"accepted_at: {date}", 1),
        (r"^execution_gate: closed$", "execution_gate: open", 1),
        (r"^  status: pending-protected-human-review$", "  status: accepted", 1),
        (r"^  approval_ref: null$", "  approval_ref: APR-INTEGRATION-LOCK-1", 1),
    ])
    platform = ROOT / "openspec/platforms/PLATFORM-PROFILES.lock.yaml"
    edit(platform, [
        (r"^status: review$", "status: accepted", 1),
        (r"^execution_gate: closed$", "execution_gate: open", 1),
        (r"^accepted_at: null$", f"accepted_at: {date}", 1),
        (r"^  status: pending-protected-human-review$", "  status: accepted", 1),
        (r"^  approval_ref: null$", "  approval_ref: APR-PLATFORM-LOCK-1", 1),
    ])
    conformance = ROOT / "openspec/verification/core-conformance.yaml"
    edit(conformance, [
        (r"^status: review$", "status: accepted", 1),
        (r"^execution_gate: closed$", "execution_gate: open", 1),
        (r"^  approval_ref: null$", "  approval_ref: APR-CONFORMANCE-SUITE-1", 1),
    ])
    # The conformance suite pins the Integration lock bytes; repin after edits.
    edit(conformance, [
        (r"(  integration_lock:\n    id: [^\n]+\n    path: openspec/integrations/INTEGRATION-PROFILES\.lock\.yaml\n    sha256: )[a-f0-9]{64}",
         rf"\g<1>{sha(conformance_integration_sha := integration)}", 1),
    ])
    # Draft packets pin the conformance suite bytes; refresh them so
    # unapproved drafts do not go stale (cmd_change re-pins approved packets).
    for packet_path in sorted(ROOT.glob("openspec/changes/*/task-packets/*.json")):
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        if packet.get("status") == "draft" and packet.get("conformanceSuite", {}).get("sha256"):
            packet["conformanceSuite"]["sha256"] = sha(conformance)
            packet_path.write_text(
                json.dumps(packet, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
    # Protected files changed: refresh the manifest while the baseline is
    # still a candidate, then accept the baseline.
    subprocess.run([sys.executable, str(ROOT / "scripts/relock_baseline.py")],
                   check=True, capture_output=True)
    baseline = ROOT / "openspec/baselines/CORE-1.0.0.lock.yaml"
    edit(baseline, [
        (r"(platform_revalidation_context:\n  platform_lock: PLATFORM-PROFILES-0\.1\.0\n  revision: 1\n  sha256: )[a-f0-9]{64}",
         rf"\g<1>{sha(platform)}", 1),
        (r"^status: review$", "status: accepted", 1),
        (r"^accepted_at: null$", f"accepted_at: {date}", 1),
        (r"^  status: pending-protected-human-review$", "  status: accepted", 1),
        (r"^  approval_ref: null$", "  approval_ref: APR-BASELINE-CORE-1.0.0", 1),
        (r"^  execution_gate: closed$", "  execution_gate: open", 1),
    ])
    cmd_bundle(trust)
    write_approval(trust, approval_id="APR-TRUST-POLICY-1", subject=policy,
                   subject_type="trustPolicy", subject_id="ARKDECK-TRUST-1.0.0",
                   revision=1, base=base, approver=approver)
    write_approval(trust, approval_id="APR-INTEGRATION-LOCK-1", subject=integration,
                   subject_type="integrationLock", subject_id="INTEGRATION-PROFILES-0.1.0",
                   revision=1, base=base, approver=approver)
    write_approval(trust, approval_id="APR-PLATFORM-LOCK-1", subject=platform,
                   subject_type="platformLock", subject_id="PLATFORM-PROFILES-0.1.0",
                   revision=1, base=base, approver=approver)
    write_approval(trust, approval_id="APR-CONFORMANCE-SUITE-1", subject=conformance,
                   subject_type="conformanceSuite", subject_id="CORE-CONFORMANCE-1.0.0",
                   revision=1, base=base, approver=approver)
    write_approval(trust, approval_id="APR-BASELINE-CORE-1.0.0", subject=baseline,
                   subject_type="baseline", subject_id="CORE-1.0.0",
                   revision=1, base=base, approver=approver)


def canonical_urn(kind: str, *parts: str) -> str:
    """Canonical exclusive-resource URN per architecture/exclusive-resources.md."""
    seed = {"hdc-server": "arkdeck-hdc-server-v1",
            "device-binding": "arkdeck-device-binding-v1",
            "host-volume": "arkdeck-host-volume-v1"}[kind]
    digest = hashlib.sha256("\x00".join((seed, *parts)).encode("utf-8")).hexdigest()
    return f"arkdeck-resource:{kind}:{digest}"


# Ready packets must carry canonical sha256 URNs for shared host resources.
# The canonical inputs (endpoint+generation / stable device identity+revision /
# volume identity) are recorded here and must be reused verbatim by the claim
# service when it issues the matching resourceIdentitySet attestation.
CANONICAL_RESOURCES = {
    "arkdeck-resource:hdc-server:isolated-m0a": canonical_urn("hdc-server", "127.0.0.1:19710", "1"),
    "arkdeck-resource:hdc-server:m0a-trust-matrix": canonical_urn("hdc-server", "127.0.0.1:29710", "1"),
    "arkdeck-resource:hdc-server:m0a-lab-endpoint": canonical_urn("hdc-server", "127.0.0.1:8710", "1"),
    "arkdeck-resource:device-binding:m0a-usb-uart-tcp-hardware": canonical_urn("device-binding", "m0a-lab-device", "1"),
    "arkdeck-resource:host-volume:m0a-trust-output": canonical_urn("host-volume", "m0a-trust-output-volume"),
    "arkdeck-resource:host-volume:m0a-output-volume": canonical_urn("host-volume", "m0a-lab-output-volume"),
}


def cmd_change(trust: Path, approver: str, change_dir: str, base: str) -> None:
    change_root = ROOT / "openspec/changes" / change_dir
    change_id = change_dir.replace("chg-", "CHG-", 1)
    baseline = ROOT / "openspec/baselines/CORE-1.0.0.lock.yaml"
    platform_lock = yaml.safe_load(
        (ROOT / "openspec/platforms/PLATFORM-PROFILES.lock.yaml").read_text(encoding="utf-8")
    )
    profile_hash = {
        entry["id"]: (entry["profile_path"], entry["profile_sha256"])
        for entry in platform_lock["profiles"]
    }
    integration_lock = yaml.safe_load(
        (ROOT / "openspec/integrations/INTEGRATION-PROFILES.lock.yaml").read_text(encoding="utf-8")
    )
    integration_hash = {p["id"]: sha(ROOT / p["path"]) for p in integration_lock["profiles"]}
    conformance_sha = sha(ROOT / "openspec/verification/core-conformance.yaml")

    packets = sorted((change_root / "task-packets").glob("*.json"))
    for packet_path in packets:
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        packet["status"] = "ready"
        packet["approvalId"] = f"APR-{packet['taskId']}-R1"
        packet["baseRevision"] = base
        packet["coreBaseline"]["sha256"] = sha(baseline)
        profile_id = packet["platformProfile"]["id"]
        packet["platformProfile"]["sha256"] = sha(ROOT / profile_hash[profile_id][0])
        for pin in packet["integrationProfiles"]:
            pin["sha256"] = integration_hash[pin["id"]]
        packet["conformanceSuite"]["sha256"] = conformance_sha
        packet["exclusiveResources"] = [
            CANONICAL_RESOURCES.get(item, item) for item in packet["exclusiveResources"]
        ]
        packet_path.write_text(json.dumps(packet, indent=2, ensure_ascii=False) + "\n",
                               encoding="utf-8")

    lock_files = ["proposal.md", "scope.yaml", "spec-impact.md", "design.md",
                  "verification.md", "review.md", "ready-review.md", "acceptance-cases.yaml"]
    lock_lines = [
        f"change_id: {change_id}",
        "revision: 1",
        "status: approved",
        f"approval_id: APR-CHANGE-{change_id.upper()}-R1",
        "hash_algorithm: sha256",
        "files:",
    ]
    for name in lock_files:
        target = change_root / name
        if target.is_file():
            lock_lines.append(f"  - path: openspec/changes/{change_dir}/{name}")
            lock_lines.append(f"    sha256: {sha(target)}")
    change_lock = change_root / "change-lock.yaml"
    change_lock.write_text("\n".join(lock_lines) + "\n", encoding="utf-8")

    write_approval(trust, approval_id=f"APR-CHANGE-{change_id.upper()}-R1", subject=change_lock,
                   subject_type="change", subject_id=change_id, revision=1,
                   base=base, approver=approver)
    for packet_path in packets:
        task_id = json.loads(packet_path.read_text(encoding="utf-8"))["taskId"]
        write_approval(trust, approval_id=f"APR-{task_id}-R1", subject=packet_path,
                       subject_type="taskPacket", subject_id=task_id, revision=1,
                       base=base, approver=approver)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["install", "bundle", "axes", "change"])
    parser.add_argument("--trust-dir", default="/Users/Shared/arkdeck-trust")
    parser.add_argument("--approver", default="lvye")
    parser.add_argument("--change")
    parser.add_argument("--base")
    options = parser.parse_args()
    trust = Path(options.trust_dir)
    if options.command == "install":
        cmd_install(trust)
    elif options.command == "bundle":
        cmd_bundle(trust)
    elif options.command == "axes":
        cmd_axes(trust, options.approver)
    elif options.command == "change":
        if not options.change or not options.base:
            raise SystemExit("change requires --change and --base")
        cmd_change(trust, options.approver, options.change, options.base)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
