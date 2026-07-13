#!/usr/bin/env python3
"""ArkDeck approval verifier (mechanism: detachedSignature).

Invoked by the guard as: verify --attestation <approval.json> --subject <file>.
Exit 0 only when the attestation is an approved detachedSignature record whose
subjectSha256 matches the subject bytes and whose signature is a valid ssh
ed25519 signature over the subject bytes by the trusted human approval key.
The trusted public key is embedded; this file's sha256 is pinned by the
external trust-root bundle, so the key is pinned transitively.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile

PRINCIPAL = "arkdeck-human"
NAMESPACE = "arkdeck-approval"
PUBKEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFjwhZq3iSmvVOrKAQarBuLDhldmvvp8RLqwr1qpWa+6 arkdeck-approval"


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] != "verify":
        return 2
    args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    try:
        with open(args["--attestation"], encoding="utf-8") as stream:
            attestation = json.load(stream)
        with open(args["--subject"], "rb") as stream:
            subject = stream.read()
    except (KeyError, OSError, json.JSONDecodeError):
        return 1
    if attestation.get("mechanism") != "detachedSignature":
        return 1
    if attestation.get("decision") != "approved":
        return 1
    if attestation.get("approver", {}).get("kind") != "human":
        return 1
    if attestation.get("subjectSha256") != hashlib.sha256(subject).hexdigest():
        return 1
    signature = attestation.get("signature") or ""
    if "BEGIN SSH SIGNATURE" not in signature:
        return 1
    with tempfile.TemporaryDirectory() as workdir:
        signers = os.path.join(workdir, "allowed_signers")
        sig_path = os.path.join(workdir, "subject.sig")
        with open(signers, "w", encoding="utf-8") as stream:
            stream.write(f"{PRINCIPAL} {PUBKEY}\n")
        with open(sig_path, "w", encoding="utf-8") as stream:
            stream.write(signature)
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", signers, "-I", PRINCIPAL,
             "-n", NAMESPACE, "-s", sig_path],
            input=subject, capture_output=True, timeout=10,
        )
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
