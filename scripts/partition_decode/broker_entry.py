"""Narrow same-process CPython entry used only by the signed macOS broker."""

from __future__ import annotations

import hashlib
import json
import os
import sys

import evidence


def run_from_broker_fd(descriptor: int, out_dir: str) -> str:
    if isinstance(descriptor, bool) or not isinstance(descriptor, int):
        raise TypeError("descriptor must be an integer fd")
    if not isinstance(out_dir, str):
        raise TypeError("out_dir must be a string")
    inventory_path = os.path.join(os.path.dirname(__file__), "member-inventory.json")
    evidence.build_core_evidence_from_fd(descriptor, out_dir, inventory_path)
    output_hashes = {}
    for name in evidence.CORE_OUTPUTS:
        with open(os.path.join(out_dir, name), "rb") as handle:
            output_hashes[name] = hashlib.sha256(handle.read()).hexdigest()
    receipt = {
        "coreOutputSha256": output_hashes,
        "embeddedPythonVersion": ".".join(str(value) for value in sys.version_info[:3]),
    }
    return json.dumps(receipt, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
