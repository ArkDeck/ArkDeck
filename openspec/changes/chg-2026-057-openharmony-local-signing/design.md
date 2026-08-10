# Design — CHG-2026-057 OpenHarmony local signing

## One runtime path

```text
Agent / CLI
  → owner-only UDS
  → RuntimeJobEngine (published operation + immutable input lease)
  → existing workspace provider (closed preset/action)
  → identity-bound Java + fixed hap-sign-tool.jar
  → secret-safe PTY (Keychain → exact prompts only)
  → verify-app postflight
  → RuntimeArtifactStore (signed lease + report)
  → existing debug.hap@1
```

The GJ-5 repair route uses this path by default: the WaterFlow build profile
publishes the unsigned Hvigor product, then the deterministic Harness route
inserts the typed signing operation after tests and before `debug.hap@1`.
The durable repair attempt distinguishes unsigned from verify-app-confirmed
output, so recovery cannot skip signing or infer it from a filename.

`deveco-cli`、raw hapsigner shell、raw HDC 与工程脚本都不在 production composition 中。

## Public operation shape

```json
{
  "operation": "workspace.sign-openharmony-hap@1",
  "target": { "targetId": "<source-artifact-target>", "expectedBindingRevision": null },
  "inputs": {
    "projectRef": "demo-app",
    "signingPresetRef": "openharmony-release@1",
    "unsignedHapArtifactLease": "lease-v1:..."
  }
}
```

No other signing field is public. In particular, the request cannot name a path, executable, algorithm,
alias, password, output location or command.

## Preset receipt versus secret

The owner-only receipt contains only:

- preset ID and projectRef;
- canonical absolute Java/JAR/keystore/app-cert/profile paths and SHA-256;
- closed key alias, signing algorithm and compatibility version;
- schema version and install timestamp;
- opaque Keychain account identifiers, never secret values.

The two password values are generic-password items in the current user's login Keychain. The daemon reads
them only after all non-secret facts and the input Artifact have passed admission. `status` uses an
attributes-only query to report presence without returning data.

## PTY protocol

The pinned hapsigner invocation always includes `-pwdInputMode 1` and omits password flags. A Swift PTY
driver accepts exactly one keystore prompt followed by exactly one key prompt, each under a byte/time
budget. It writes one secret plus newline for each prompt and zeroes its mutable buffer after the write.
Any other prompt sequence is a definite refusal. The transcript exposed to Runtime removes interactive
prompt bytes and is scanned against both in-memory secrets before publication.

The verifier invocation needs no secret. It writes certificate-chain and profile readbacks below the same
Job-owned directory; those raw files are not published because a Provision profile can contain device
identifiers. Their hashes and bounded structural facts enter `signing-report.json`.

## Artifact binding

Signing is host-only, so the signing Job itself has no device binding. The input Artifact can be
device-bound: Runtime admits it only when the request target ID equals its source target ID and preserves
the original binding solely as lineage. Publication copies that exact snapshot to `signed.hap`; it never
uses request text or fresh HDC facts to construct one. This makes the existing `debug.hap@1` binding gate
the final authority: a stale/rebound target refuses the lease before device dispatch.

## Crash and cancellation boundaries

Output is created as a fresh file inside a Job-owned `0700` directory and never overwrites input. The
state sequence is `prepared → signing → signedBytesObserved → verifying → verified → published` with a
durable intent before spawn. Recovery never repeats an invocation whose external result is unknown. It
hashes the existing output and runs read-only `verify-app`; exact success permits completion, otherwise
the Job remains failed/unknown and records cleanup debt for its private temporary directory.
