#!/usr/bin/env python3
"""ArkDeck identity-ledger verifier (mechanism: protectedIdentityLedger).

The guard passes the ledger snapshot as both attestation and subject. The
detached ssh signature lives in the sibling file named by `verificationRef`
(a bare filename, so the signed bytes are self-stable). Exit 0 only when the
signature over the snapshot bytes verifies against the pinned ledger service
key and the record identifies itself correctly.
"""
import json
import os
import subprocess
import sys
import tempfile

PRINCIPAL = "arkdeck-ledger-service"
NAMESPACE = "arkdeck-ledger"
ISSUER_ID = "ORG-PROTECTED-IDENTITY-LEDGER-VERIFIER"
PUBKEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSG7deM74InWJ9w9MPyorjYC1aELPmI+qL5Z1HfSsu6 arkdeck-identity-ledger"


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] != "verify":
        return 2
    args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    try:
        subject_path = args["--subject"]
        with open(subject_path, "rb") as stream:
            subject = stream.read()
        record = json.loads(subject.decode("utf-8"))
    except (KeyError, OSError, ValueError):
        return 1
    if record.get("mechanism") != "protectedIdentityLedger":
        return 1
    if record.get("subjectType") != "identityLedger":
        return 1
    if record.get("decision") != "approved":
        return 1
    if record.get("issuer", {}).get("id") != ISSUER_ID:
        return 1
    reference = os.path.basename(str(record.get("verificationRef") or ""))
    if not reference:
        return 1
    sig_source = os.path.join(os.path.dirname(os.path.abspath(subject_path)), reference)
    if not os.path.isfile(sig_source):
        return 1
    with tempfile.TemporaryDirectory() as workdir:
        signers = os.path.join(workdir, "allowed_signers")
        with open(signers, "w", encoding="utf-8") as stream:
            stream.write(f"{PRINCIPAL} {PUBKEY}\n")
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", signers, "-I", PRINCIPAL,
             "-n", NAMESPACE, "-s", sig_source],
            input=subject, capture_output=True, timeout=10,
        )
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
