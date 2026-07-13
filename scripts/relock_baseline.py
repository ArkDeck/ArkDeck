#!/usr/bin/env python3.14
"""Regenerate an unratified candidate Core baseline's protected-file pins."""

from __future__ import annotations

import hashlib
import re
import sys
from datetime import date
from pathlib import Path
from typing import NoReturn

from sdd_protected_set import require_sdd_runtime, sdd_protected_files


require_sdd_runtime()

import yaml


ROOT = Path(__file__).resolve().parent.parent


def abort(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


config = yaml.safe_load((ROOT / "openspec/config.yaml").read_text(encoding="utf-8"))
baseline_id = config["current_core_baseline"]
lock_path = ROOT / f"openspec/baselines/{baseline_id}.lock.yaml"
if not lock_path.is_file():
    abort(f"ERROR: baseline lock not found: {lock_path}")

lock_text = lock_path.read_text(encoding="utf-8")
lock = yaml.safe_load(lock_text)

# --- candidate-only guard rails -------------------------------------------
ratification = lock.get("ratification", {})
violations: list[str] = []
if lock.get("status") == "accepted":
    violations.append("lock status is 'accepted' (must not be 'accepted')")
if lock.get("accepted_at") is not None:
    violations.append("lock has accepted_at set")
if ratification.get("approval_ref") is not None:
    violations.append("ratification approval_ref is set")
if ratification.get("execution_gate") != "closed":
    violations.append("execution gate is not closed")
if violations:
    abort(
        "ERROR: refusing to relock a non-candidate baseline:\n  - "
        + "\n  - ".join(violations)
        + "\nAfter acceptance, create an approved Core change and a new "
        "CORE-x.y.z baseline instead."
    )

manifest_ref = lock["file_manifest"]
manifest_path = ROOT / manifest_ref["path"]

# --- read previous manifest for the drift report ---------------------------
previous: dict[str, str] = {}
if manifest_path.is_file():
    previous_doc = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    for entry in previous_doc.get("files") or []:
        previous[entry["path"]] = entry["sha256"]

# --- regenerate manifest ----------------------------------------------------
files = sdd_protected_files(ROOT)
current = {path: sha256_file(ROOT / path) for path in files}

today = date.today().isoformat()
manifest_lines = [
    "---",
    f"baseline: {baseline_id}",
    "status: candidate",
    f"generated_at: '{today}'",
    "hash_algorithm: sha256",
    f"file_count: {len(files)}",
    "files:",
]
for path in files:
    manifest_lines.append(f"- path: {path}")
    manifest_lines.append(f"  sha256: {current[path]}")
manifest_content = "\n".join(manifest_lines) + "\n"
manifest_path.write_text(manifest_content, encoding="utf-8")
manifest_hash = hashlib.sha256(manifest_content.encode("utf-8")).hexdigest()

# --- re-pin manifest hash and generated_at inside the lock ------------------
manifest_rel = manifest_ref["path"]
pin_pattern = re.compile(
    rf"(path: {re.escape(manifest_rel)}\n\s*sha256: )[a-f0-9]{{64}}"
)
if pin_pattern.search(lock_text) is None:
    abort(f"ERROR: could not locate file_manifest pin inside {lock_path}")
updated_lock = pin_pattern.sub(rf"\g<1>{manifest_hash}", lock_text, count=1)
updated_lock = re.sub(
    r"^generated_at: .*$", f"generated_at: {today}", updated_lock, count=1, flags=re.MULTILINE
)
lock_path.write_text(updated_lock, encoding="utf-8")

# --- drift report -----------------------------------------------------------
added = [path for path in files if path not in previous]
removed = [path for path in previous if path not in current]
changed = [path for path in files if path in previous and previous[path] != current[path]]

print(f"Relocked {baseline_id}: {len(files)} protected files.")
if added:
    print(f"  added   ({len(added)}): {', '.join(added)}")
if removed:
    print(f"  removed ({len(removed)}): {', '.join(removed)}")
if changed:
    print(f"  changed ({len(changed)}): {', '.join(changed)}")
print(f"  manifest sha256: {manifest_hash}")
print(
    "Review the drift above, run scripts/check-sdd.sh and "
    "scripts/guard_selftest.py, then commit."
)
