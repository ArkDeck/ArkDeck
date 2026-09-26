#!/usr/bin/env python3
"""Record Swift's pinned-credential refusal without touching the Keychain.

Every private home starts with an owner ledger pin. Swift's owner refuses it
before invoking the preset-store removal closure. Never record a success case
here: changing HOME does not isolate a process from the real Keychain.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-cli", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    executable = args.swift_cli.resolve(strict=True)
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error("--swift-cli must be an executable file")
    ledger = {"schemaVersion": "arkdeck.signing-credential-owner/1",
              "state": "stable", "presetOwners": ["preset-a"]}
    ledger_bytes = json.dumps(ledger, sort_keys=True, separators=(",", ":")).encode()
    cases = []
    for prefix in [["runtime", "signing"], ["signing"]]:
        for mode in [[], ["--output", "json"], ["--json"]]:
            with tempfile.TemporaryDirectory(prefix="arkdeck-signing-remove-oracle-") as temp:
                home = Path(temp).resolve()
                root = home / "Library/Application Support/ArkDeck/Signing/OpenHarmony"
                root.mkdir(parents=True, mode=0o700)
                path = root / "credential-owner-v1.json"
                path.write_bytes(ledger_bytes)
                path.chmod(0o600)
                argv = prefix + ["remove"] + mode
                result = subprocess.run([str(executable), *argv], capture_output=True,
                                        env={"HOME": str(home), "CFFIXED_USER_HOME": str(home)},
                                        timeout=20, check=False)
                expected = b"signing credential is referenced by an active workspace preset"
                if result.returncode != 1 or result.stdout or expected not in result.stderr:
                    raise RuntimeError("Swift did not take the pinned-owner refusal")
                if path.read_bytes() != ledger_bytes:
                    raise RuntimeError("Swift changed the pinned ledger")
                cases.append({"argv": argv, "ledger": ledger, "exit": result.returncode,
                              "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "cases.json").write_text(json.dumps(cases, indent=2, sort_keys=True) + "\n")
    (args.out / "provenance.json").write_text(json.dumps({
        "producer": "record-signing-remove-oracle.py", "swiftCliSha256":
        hashlib.sha256(executable.read_bytes()).hexdigest(), "owners": [
            "RuntimeCLI.runSigning", "OpenHarmonySigningCredentialOwner.remove"]
    }, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
