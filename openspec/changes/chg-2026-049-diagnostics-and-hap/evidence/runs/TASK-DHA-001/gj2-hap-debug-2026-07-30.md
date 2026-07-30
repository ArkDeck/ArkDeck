# GJ-2 HAP Debug — real DAYU200 run (2026-07-30)

## Current result

`GJ-2 HAP Debug`: **IMPLEMENTING**

The production CLI imported a real signed HAP into the daemon-owned Artifact
store, returned an ID-only lease bound to the adopted DAYU200, and resolved the
same Artifact after a daemon restart. A subsequent request without an E1
capability failed closed before job creation or HDC dispatch. The
maintainer-accepted capability from PR #828 was then installed and used for
one real `debug.hap@1` attempt. That attempt exposed an offline-target
admission defect before any mutation; the production fix and regression tests
are included in the same GJ-2 product PR as this record.

No person or Agent ran an HDC command directly. No send, install, start, stop,
uninstall or remote cleanup was dispatched in the failed attempt.

## Runtime and input

| Item | Value |
| --- | --- |
| Source baseline | `main@8f05990f4dea5e855531fc3f1bb0df3f9556c419` |
| Device | DAYU200 (RK3568), USB |
| Durable target | `TGT-958780b2ffb7`, binding revision `1` |
| Stable identity SHA-256 | `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e` |
| HDC | `3.2.0f` |
| Catalog digest | `3455e050c8a6e09c026d784b652be22dc69b5809d448059f7f1c3524e7bf60a2` |
| Runtime state | `/private/tmp/ad-gj1-0435949`, mode `0700` |
| HAP | `entry-default-signed.hap`, 1,512,003 bytes |
| HAP SHA-256 | `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8` |
| Bundle / Ability | `com.example.waterflowdemo` / `EntryAbility` |

## Capability-backed real attempt

PR #828 merged the maintainer-authored
`CAP-RT-DAYU200-HAP-001` capability. The runtime installation returned
`{"installed":true}`. Immediately before the attempt it reported one remaining
use.

The Device Runtime Agent submitted the published `debug.hap@1` operation with
the exact lease, bundle, ability and capability reference. It created
`job-01e0044e411c54372de074c05ca6bad1` and consumed the one authorized use.
Admission recorded:

- effect `deviceMutation`;
- stable target identity and binding revision `1`;
- catalog digest
  `1ee1c1a68486f45f8406fd362770655eb9d5dc983e1da27a87235d95eeb01a94`;
- materialized-plan consumption fingerprint
  `f3bb72ef617976c5fa76b1b3d95a2dcc79cfa30ff445878f8a3bc0bb4c768603`.

The first provider step, `confirm-evidence-target`, returned
`targetNotConnected: matching target state is Offline`. The durable journal
contains only that read-only typed intent and its confirmed failed outcome.
There are zero `send-hap`, `install-hap`, `start-ability`, `stop-ability`,
uninstall or cleanup mutation intents, and `outcomeUnknown` is false.

The terminal timeline incorrectly replaced the primary error with
`evidenceIncomplete: three-step typed preflight is incomplete before
finish-operation`. A separate E0 `observe.device@1` through the product
confirmed the adopted target was Offline; no direct HDC command was used.

## Product fix from the real failure

Two production defects were corrected:

1. `submit` now finishes materializing the complete typed plan, performs a
   pure capability scope/expiry/use check, and persists the job without
   consuming a use. The descriptor-bound target/model/firmware preflight then
   runs through the existing durable write-ahead journal. Only a complete
   verified target binding reaches atomic capability consumption at the last
   safe boundary before the first mutation. Missing, wrong, expired or
   exhausted capability still causes zero provider dispatch.
2. `debug.hap@1` invokes compensation only after a compensable mutation
   actually completed. A pre-mutation provider failure therefore preserves
   its original semantic code and detail in the durable timeline instead of
   manufacturing an incomplete-preflight failure.

Contract regression coverage proves both the offline-before-consume case
(one durable read-only target-confirmation intent, zero consumption and zero
mutation) and target-confirmation mismatch handling (primary reason preserved,
zero mutation and zero false compensation).

## Product defect and fix

`debug.hap@1` correctly rejects arbitrary host paths and requires
`hapArtifactLease`, but the production CLI previously had no way to ingest a
real local HAP and obtain such a lease. Tests could publish one only by calling
the store directly.

The fix adds `arkdeck artifact import-hap --target <id> --file <signed.hap>`.
The CLI opens one non-symlink regular file, bounds it to 64 MiB, detects
mid-read replacement, verifies the ZIP/HAP container prefix and hashes the
exact bytes. It sends bounded 512 KiB chunks over the existing private UDS;
the daemon revalidates name, size, offsets, SHA-256 and container shape,
rechecks stable target identity plus binding revision at commit, and publishes
the bytes through `RuntimeArtifactStore`. The Operation receives only the
resulting ID-only lease.

Incomplete uploads expire and are capacity bounded. Unknown targets,
out-of-order/oversized chunks, digest drift, invalid containers, target
binding drift and Artifact publication failure all fail closed.

## Real product run

The production import returned:

- input job:
  `input-hap-TGT-958780b2ffb7-r1-9453a396e81d55ab`;
- Artifact:
  `ART-8d5b85963670977fa1def2734b77fe67`;
- lease:
  `lease-v1:input-hap-TGT-958780b2ffb7-r1-9453a396e81d55ab:ART-8d5b85963670977fa1def2734b77fe67`;
- byte count and SHA-256 exactly matching the local signed HAP;
- target, binding revision and stable identity exactly matching the adopted
  DAYU200.

After a clean daemon stop and restart, `artifact inspect` returned the same
job ID, Artifact ID, byte count, SHA-256, target, binding revision and stable
identity. No host input path appeared in the lease or Artifact metadata.

`capability list` was empty. Running the production Agent with the lease,
bundle and ability but no capability returned
`authorizationRequired: effect deviceMutation requires a runtime capability`.
The durable job count stayed at three before and after the request, confirming
zero job creation and zero device dispatch.

## Verification

- `swift test --package-path Packages/ArkDeckKit --filter
  DiagnosticsAndHAPContractTests`: 37 tests, 0 failures for the
  pre-consumption target confirmation and primary-failure preservation fix;
- `swift test --package-path Packages/ArkDeckKit`: 710 tests, 1 skipped,
  0 failures on the final product diff;
- `swift test --package-path Packages/ArkDeckKit --filter
  AgentDaemonContractTests`: 13 tests, 0 failures after the final public
  binding-readback addition;
- rebased verification on `main@7625d66c2ccdc4a83b50e0377e6970eacea41ad5`:
  `swift test --package-path Packages/ArkDeckKit`: 707 tests, 1 skipped,
  0 failures for the complete import implementation;
- `scripts/check-sdd.sh`: 0 errors, 0 warnings, 114 Acceptance IDs.

## Remaining execution boundary

The first capability was truthfully consumed by the failed pre-fix attempt and
must not be retried or rewritten. GJ-2 remains `IMPLEMENTING` until this
product fix is merged, the DAYU200 is online, and a new maintainer-authored,
maintainer-accepted one-use capability authorizes `debug.hap@1` for stable identity
`958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
and bundle `com.example.waterflowdemo`. The Agent cannot create, modify or
approve that replacement. Once present, the same production Agent can continue
with send/install/readback/start/capture/stop/cleanup; any unknown mutation
outcome remains non-retriable.

This record changes no Acceptance ID, acceptance count, governance state or
OpenSpec change.
