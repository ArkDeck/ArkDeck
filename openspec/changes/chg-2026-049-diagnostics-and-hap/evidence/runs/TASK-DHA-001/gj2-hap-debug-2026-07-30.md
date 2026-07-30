# GJ-2 HAP Debug — real DAYU200 run (2026-07-30)

## Current result

`GJ-2 HAP Debug`: **REAL_DEVICE_PASS**

The production CLI imported a real signed HAP into the daemon-owned Artifact
store, returned an ID-only lease bound to the adopted DAYU200, and resolved the
same Artifact after a daemon restart. A subsequent request without an E1
capability failed closed before job creation or HDC dispatch. Four
maintainer-reviewed capabilities then drove a traceable correction sequence:
offline preflight, remote-path install semantics, non-UTF-8 HiLog Artifact
handling, and the final complete run. No uncertain mutation was retried.

The final Runtime Job sent the HAP, installed it with replacement enabled,
verified package presence, started the ability, verified its process, published
the readback and HiLog Artifacts, stopped the ability, uninstalled the package,
cleaned the job-owned remote staging path, and remained queryable after a clean
daemon restart. No person or Agent ran an HDC command directly.

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
| Final authorization main | `0e205b1e68e173c9dab60820bbafba8619413fec` (PR #832) |
| Final capability | `CAP-RT-AUTO-20260730T061514Z-410D442011C6` |
| Final exact plan digest | `791c36c323e5fc25037581b8fc24cc468a12594fdfa1c36d097b3505d70b8813` |
| Final Job | `job-3a4aa8b2f2d5c46817e4a603582734c2` |

## First capability-backed real attempt

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

## Generated authorization and correction sequence

Each authorization came from a maintainer-reviewed protected-main PR. The
Runtime recorded its exact stable target, binding revision, materialized plan
and use. Consumed capabilities were never reset or replayed.

| PR / capability | Durable result | Product finding |
| --- | --- | --- |
| #828 / `CAP-RT-DAYU200-HAP-001` | `job-01e0044e411c54372de074c05ca6bad1`, failed before mutation, `outcomeUnknown=false` | Offline target was detected too late and the primary error was masked; #829 moved consumption to the last verified pre-mutation boundary. |
| #830 / `CAP-RT-AUTO-20260730T045821Z-8A30FD002EFA` | `job-6704ee2391f2264f798957762aa52f7e`, failed package readback, cleanup completed, `outcomeUnknown=false` | Host-path `hdc install` could not consume the job-owned remote path; lowering now uses descriptor-bound `shell bm install -p <same .hap path> -r`. |
| #831 / `CAP-RT-AUTO-20260730T051705Z-0A5CC0F7F3C9` | `job-924cebae44c0e5f9e780761188fda619`, mutation and cleanup succeeded, `outcomeUnknown=false` | Real HiLog contained non-UTF-8 bytes, so the requested diagnostic Artifact was missing; HiLog is now accepted as bounded sensitive raw bytes while UI Dump remains UTF-8 checked. |
| #832 / `CAP-RT-AUTO-20260730T061514Z-410D442011C6` | `job-3a4aa8b2f2d5c46817e4a603582734c2`, succeeded, `outcomeUnknown=false` | Final artifact-complete run; no further product defect was observed. |

## Final authorized real run

At `2026-07-30T06:29:18Z`, the Device Runtime Agent admitted the #832
capability against:

- stable identity
  `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`;
- binding revision `1`;
- exact plan digest
  `791c36c323e5fc25037581b8fc24cc468a12594fdfa1c36d097b3505d70b8813`;
- exact lease, bundle `com.example.waterflowdemo`, ability `EntryAbility`,
  `installOrReplace`, five-second diagnostics and uninstall cleanup;
- consumption fingerprint
  `eec8e888236fc8c5c9f28b7909d4be8907960152e97943d56f4fce74ec54fd8a`.

The complete durable timeline contains typed intents and verified outcomes for
target/model/firmware preflight, HAP send, install plus package readback, start
plus process readback, diagnostics capture, stop, uninstall and remote staging
cleanup. The capability changed from one remaining use to zero immediately
before the first mutation. The terminal receipt reported `actualEffect=E1`,
`succeeded`, `outcomeUnknown=false`, zero evidence blockers and zero human
actions.

Published Artifacts:

| Name | Artifact | Bytes | Privacy / redaction |
| --- | --- | ---: | --- |
| `install-readback.json` | `ART-818f9a0b0ca7e2b379b8f93839ae8fd3` | 460 | standard / false |
| `process-readback.json` | `ART-98db48f407640d6847aba0cf2da95182` | 458 | standard / false |
| `debug-hilog.txt` | `ART-09e6f5afb6701f4cc2311b81310ad4ac` | 673,380 | sensitive / true |

Only Artifact metadata was inspected; sensitive HiLog content was not read or
exported. After a clean daemon stop and restart, the daemon recovered 15
persisted jobs. The same final Job remained `succeeded/outcomeUnknown=false`,
its timeline appended `recovered: journal clean`, all three Artifacts retained
the same IDs, byte counts and hashes, and the capability remained consumed.
There was no automatic mutation replay.

## Verification

- `swift test --package-path Packages/ArkDeckKit`: 713 tests, 1 skipped,
  0 failures;
- focused non-UTF-8 HiLog / UTF-8 UI Dump contract: 1 test, 0 failures;
- HAP non-UTF-8 raw Artifact, readback and required-capture contracts:
  3 tests, 0 failures;
- `scripts/check-sdd.sh`: 0 errors, 0 warnings, 114 Acceptance IDs;
- `git diff --check`: clean.

## Remaining boundary

GJ-2 is complete. The final capability is consumed and will not be reused.
Remote Trace, strict redaction, `installFresh`, `restorePrevious` and
debugger-default remain production unavailable and fail closed before
capability consumption. No new proposal or governance state was created.

This record changes no Acceptance ID, acceptance count, governance state or
OpenSpec change.
