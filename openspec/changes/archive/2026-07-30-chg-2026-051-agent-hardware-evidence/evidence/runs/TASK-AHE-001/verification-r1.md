# TASK-AHE-001 verification closure replay r1

Date:2026-07-29

Classification:`contract` / fake integration. This record is not installed-HDC,
real-device, platform-conformance or `realHardware` evidence.

## Verdict

PR #814 exact head
`7cf1ad90939be8da7e0de74fdcec536ecf406f28` was approved by maintainer
`lvye` and merged as
`858a8d4c272827bcaa2a2a5379115f810e24d915`. Its same-revision
`run.md` records `AC-WF-004-01/02/03` as PASS.

The independent closure replay was executed on that exact protected-main merge
OID. All three AC conclusions remain PASS. This record does not itself approve
`verified`; that state takes effect only if the maintainer reviews and merges
the verification PR.

## Delivery trust chain

- Governing r6 proposal #813 exact head
  `674f4e112e2cb908b8e53fb669a67fe5e31a2696` was approved by maintainer
  `lvye` and merged as
  `1836ab149e1520665cfcbc087552baba1ad212d9`.
- Implementation/evidence #814 exact head
  `7cf1ad90939be8da7e0de74fdcec536ecf406f28` was approved by maintainer
  `lvye` and merged as
  `858a8d4c272827bcaa2a2a5379115f810e24d915`.
- Both PRs' required Agent PR, SDD Guard, allowed-path and Swift CI checks were
  `SUCCESS`.
- Approval/merge facts establish authority. Concrete AC truth remains the
  implementation run and this independent closure replay.

## Replay environment

```text
macOS 26.6 (25G72), arm64
Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101)
SDD interpreter: shared repository .venv-sdd, Python 3.14.6 / pinned PyYAML
```

## Commands and results

| Command/gate | Result |
| --- | --- |
| `CI=true swift test --package-path Packages/ArkDeckKit` | PASS, 666 tests / 1 existing opt-in manual sleep/wake skip / 0 failures |
| `CI=true swift test --package-path Packages/ArkDeckKit --skip-build --filter 'HardwareEvidenceProjectionContractTests\|HardwareEvidenceWorkflowStepContractTests\|RuntimeJobEngineContractTests/testCrashWindowsPreserveUnknownOutcomeAndNeverRedispatch'` | PASS, 11/11 |
| `python3 .../TASK-AHE-001/validate_v3.py` | PASS, 10/10 vectors |
| shared-Python `scripts/catalog_gen/test_generate.py` | PASS, 38/38 |
| `scripts/check-sdd.sh` | PASS, 0 errors / 0 warnings / 111 acceptance IDs |
| evidence Markdown privacy scan | PASS; only policy prose and commit OIDs matched, no raw serial/connectKey value, credential or secret |
| `git diff --check` on replay base | PASS |

The full Swift suite first passed in the normal workspace sandbox. A separate
`--skip-build` summary attempt was refused before test execution because the
user-level Swift module cache was not writable in that sandbox; the same
already-built suite was replayed outside that filesystem boundary and passed
666/666 as recorded above. No product network request, installed HDC or device
command was introduced by either test invocation.

## Acceptance conclusions

- `AC-WF-004-01`:PASS. The focused positive contract projects canonical V3 from
  product-owned Runtime facts and round-trips executor, E0 authority,
  job/target/binding, fresh confirmation, model/firmware, tool/provider/
  transport, actual steps and immutable Artifact references/hashes.
- `AC-WF-004-02`:PASS. Required-fact/correlation, stale/mismatch, caller
  injection, raw identity, unavailable/tampered Artifact, simulation and
  outcome-unknown vectors fail before publication; publication count remains
  zero and legacy V2 bytes remain read-only.
- `AC-WF-004-03`:PASS. The actual-effect × authority matrix accepts only
  E0/defaultReadOnlyPolicy, E1/runtimeCapability and
  E2/standingAuthorization exact provenance. Missing, wrong, expired or
  drifted authority publishes nothing; schema/projector validation has no
  capability-mint or provider/device-dispatch surface.

V3 JSON Schema/Swift semantic parity, sealed remote-action references,
WorkflowStep Swift/JSON registry parity, production-shaped exact-target
preflight, generated-output drift and both WAL crash windows are covered by
the focused, generator, SDD and full-Swift results above.

Closure activity executed contract/fake paths only. It did not intentionally
invoke installed HDC, address a real device, dispatch E1/E2/device mutation or
destructive work, alter RuntimeCapability/standing-authorization state, reuse
`DHA-HW-001` attempt#2, or claim hardware/platform support.

If protected main changes any schema, Catalog/generator, Runtime/projector,
provider/preflight or corresponding test input before this verification PR
merges, the affected replay must be repeated and recorded rather than inferred.
