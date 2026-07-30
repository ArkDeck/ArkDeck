# GJ-2 HAP Debug — real DAYU200 run (2026-07-30)

## Current result

`GJ-2 HAP Debug`: **IMPLEMENTING**

The production CLI imported a real signed HAP into the daemon-owned Artifact
store, returned an ID-only lease bound to the adopted DAYU200, and resolved the
same Artifact after a daemon restart. A subsequent `debug.hap@1` request
without an E1 capability failed closed before job creation or HDC dispatch.

No person or Agent ran an HDC command directly. No send, install, start, stop,
uninstall or remote cleanup was dispatched in this checkpoint.

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
  AgentDaemonContractTests`: 13 tests, 0 failures after the final public
  binding-readback addition;
- rebased verification on `main@7625d66c2ccdc4a83b50e0377e6970eacea41ad5`:
  `swift test --package-path Packages/ArkDeckKit`: 707 tests, 1 skipped,
  0 failures for the complete import implementation;
- `scripts/check-sdd.sh`: 0 errors, 0 warnings, 114 Acceptance IDs.

## Remaining execution boundary

The Agent cannot create, modify or approve the missing E1 capability. GJ-2
remains `IMPLEMENTING` until a maintainer-accepted capability authorizes
`debug.hap@1` for stable identity
`958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
and bundle `com.example.waterflowdemo`. Once present, the same production Agent
can continue with send/install/readback/start/capture/stop/cleanup; any unknown
mutation outcome remains non-retriable.

This record changes no Acceptance ID, acceptance count, governance state or
OpenSpec change.
