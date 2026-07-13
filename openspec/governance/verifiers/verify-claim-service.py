#!/usr/bin/env python3
"""ArkDeck claim-service verifier (mechanism: protectedClaimService).

Attests taskClaim / taskRunLease / resourceIdentitySet /
changeSupersessionBarrier sidecars. The detached ssh signature covers the
ATTESTATION file bytes (which bind the subject via its recorded sha256) and
lives in the sibling file named by `attestationRef`/`verificationRef`.
"""
import json
import os
import subprocess
import sys
import tempfile

PRINCIPAL = "arkdeck-claim-service"
NAMESPACE = "arkdeck-claim"
ISSUER_ID = "ORG-PROTECTED-CLAIM-SERVICE-VERIFIER"
PUBKEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOxlGWoQcFbiIvURzsbZIPkUc/FcEoRTX197uBd2T4mQ arkdeck-claim-service"
SUBJECT_TYPES = {"taskClaim", "taskRunLease", "resourceIdentitySet", "changeSupersessionBarrier"}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] != "verify":
        return 2
    args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    try:
        attestation_path = args["--attestation"]
        with open(attestation_path, "rb") as stream:
            attestation_bytes = stream.read()
        attestation = json.loads(attestation_bytes.decode("utf-8"))
    except (KeyError, OSError, ValueError):
        return 1
    if attestation.get("mechanism") != "protectedClaimService":
        return 1
    if attestation.get("subjectType") not in SUBJECT_TYPES:
        return 1
    if attestation.get("issuer", {}).get("id") != ISSUER_ID:
        return 1
    reference = os.path.basename(
        str(attestation.get("attestationRef") or attestation.get("verificationRef") or "")
    )
    if not reference:
        return 1
    sig_source = os.path.join(
        os.path.dirname(os.path.abspath(attestation_path)), reference
    )
    if not os.path.isfile(sig_source):
        return 1
    with tempfile.TemporaryDirectory() as workdir:
        signers = os.path.join(workdir, "allowed_signers")
        with open(signers, "w", encoding="utf-8") as stream:
            stream.write(f"{PRINCIPAL} {PUBKEY}\n")
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", signers, "-I", PRINCIPAL,
             "-n", NAMESPACE, "-s", sig_source],
            input=attestation_bytes, capture_output=True, timeout=10,
        )
    return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
