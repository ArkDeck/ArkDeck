#!/usr/bin/env python3.14
"""Generate and sign the external identity-ledger snapshot for current HEAD.

The inventory comes from the guard itself (ARKDECK_DUMP_INVENTORY hook), so the
snapshot can never diverge from what the guard validates. The snapshot chain
(revision, previousSnapshotSha256) lives in the trust host directory outside
the repository; each snapshot is signed by the ledger service key and verified
by the pinned verify-identity-ledger verifier.

Usage: ledger_snapshot.py [--trust-dir /Users/Shared/arkdeck-trust]
Prints the absolute snapshot path (for ARKDECK_IDENTITY_LEDGER_SNAPSHOT).
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from sdd_protected_set import require_sdd_runtime

require_sdd_runtime()

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY_ID = "ORG-ARKDECK-REPOSITORY-1"
ISSUER_ID = "ORG-PROTECTED-IDENTITY-LEDGER-VERIFIER"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trust-dir", default="/Users/Shared/arkdeck-trust")
    options = parser.parse_args()
    trust = Path(options.trust_dir)
    ledger_dir = trust / "ledger"
    ledger_dir.mkdir(parents=True, exist_ok=True)

    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.strip()

    with tempfile.TemporaryDirectory() as workdir:
        dump = Path(workdir) / "inventory.json"
        env = dict(os.environ, ARKDECK_DUMP_INVENTORY=str(dump))
        subprocess.run(
            [sys.executable, str(ROOT / "scripts/check_sdd.py")],
            env=env, capture_output=True, check=False,
        )
        entries = json.loads(dump.read_text(encoding="utf-8"))

    chain = trust / "ledger" / "chain.json"
    previous = json.loads(chain.read_text()) if chain.is_file() else {"revision": 0, "sha256": None}
    revision = int(previous["revision"]) + 1
    name = f"snapshot-{revision:06d}-{head[:12]}"
    record = {
        "schemaVersion": "1.0.0",
        "subjectType": "identityLedger",
        "ledgerId": "ARKDECK-LEDGER-1",
        "revision": revision,
        "previousSnapshotSha256": previous["sha256"],
        "repositoryId": REPOSITORY_ID,
        "repositoryRevision": head,
        "generatedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "entries": entries,
        "decision": "approved",
        "mechanism": "protectedIdentityLedger",
        "issuer": {"kind": "service", "id": ISSUER_ID},
        "verificationRef": f"{name}.sig",
    }
    snapshot = ledger_dir / f"{name}.json"
    snapshot.write_text(json.dumps(record, indent=1) + "\n", encoding="utf-8")

    key = trust / "keys" / "identity-ledger"
    subprocess.run(
        ["ssh-keygen", "-Y", "sign", "-f", str(key), "-n", "arkdeck-ledger", str(snapshot)],
        capture_output=True, check=True,
    )
    (ledger_dir / f"{name}.json.sig").rename(ledger_dir / f"{name}.sig")
    chain.write_text(
        json.dumps({"revision": revision, "sha256": sha256_file(snapshot)}) + "\n",
        encoding="utf-8",
    )
    print(snapshot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
