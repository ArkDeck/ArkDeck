# SVC acceptance on the published `6ba5a0b9` build — 2026-09-08

This is an execution record for `TASK-SVC-005`. It does not mark that Task done
and does not mark CHG-2026-075 verified.

Four product defects were found during the window. All four fixes were reviewed
and merged the same day (#1777, #1778, #1779, #1780), and each was then
re-verified on this host against the real Runtime state it was found in — see
[Re-verification](#re-verification-on-16fe9617). The record keeps the discovery
results attached to the build they were taken on.

## What was installed, and how it was verified

The checkout was clean at protected `main`
`6ba5a0b9f372d088efe36152dd1ab7588790001c` (`git status --porcelain` empty).
`Distribution/macOS/build-local-helpers.sh` built the helper pair from that tree
with the Developer ID identity `8AQTYW5FKR`; nothing else was installed.

| Identity | Value |
| --- | --- |
| Swift commit | `6ba5a0b9f372d088efe36152dd1ab7588790001c` |
| CLI executable SHA-256 | `e7ff344acc077e9ee836a43ef17bedc6ea7c2e12261da2a7b0a82a813a7100fb` |
| Daemon executable SHA-256 | `c1d313a0229d7f756db9adebd8b64b250bae5f8d0f6a6f0ad5e2b01eaad40f45` |
| CLI `buildIdentity` | `sha256:e7ff344acc077e9ee836a43ef17bedc6ea7c2e12261da2a7b0a82a813a7100fb` |
| Installed at | `2026-09-08T07:41:53Z`, `runtime service update --daemon`, exit 0 |
| Control protocol | `1.0.0` |
| Contract identity | `1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d` |
| Runtime Catalog digest | `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` |
| Control JSON blob | `f47372feb9034ba17560b59d5dbde91206cb9aae` |
| Generated Swift blob | `6d3c1fb680d6a338ba59cb80af53aa46505196cb` |
| Method schemas, 96 files | `ebe719ec8423b064e4a751ce98458510e8b1dd005563768295f4a768af359cd5` |
| Frame corpus, 96 files | `769ec0f008f706c07c4dcf995e5ba0d09915ac896c974661618bbe8cdf3ebbb5` |
| Catalog tree, 35 files | `b84ffac89462797d0d5bb4ac2d39d30803d71365af187e0898893135c58d721b` |

Tree digests hash sorted Git object IDs and repository-relative paths, one
trailing newline per row:

```sh
git ls-tree -r 6ba5a0b9f372d088efe36152dd1ab7588790001c \
  --format='%(objectname) %(path)' -- spec/control/methods | LC_ALL=C sort | shasum -a 256
```

`launchAgent.daemonSHA256` read back as `c1d313a0…`, confirming the running
daemon is this build and not the previously installed `0b35d535` one
(`8bb060be…`). The socket was absent for the first two polls after the update
and `daemonHealth.status` reached `ok` on the third. `operation list` returned
30 operations on digest `508783ac…`: 23 `available`, 7 `unavailable`
(`analyzer.extract-crash-signature@1`, `analyzer.summarize-hilog@1`,
`flash.dayu200`, `flash.full-restore@1`, `workspace.inspect-source@1`,
`workspace.sign-openharmony-hap@1`, `workspace.symbolize-crash@1`), each with
its own reason code.

Device: DAYU200 attached in hdc-normal, USB serial
`150100424a544434520325874bbf4900`, idVendor 8711. `device candidates` reports
`TGT-958780b2ffb7`, `bindingRevision: 2`, `authorizationState: Connected`,
`observationContinuity: relationProven`, `OpenHarmony-7.0.0.37`. Job ledger
before the window: 7 Jobs; after: 14.

Immutable captures with per-command arguments, exit codes and output hashes are
under `/private/tmp/arkdeck-gj-headless-20260908b/`.

## Golden Journeys on this build

Four-state per `PRODUCT-LOOP.md` §6. `REAL_DEVICE_PASS` is claimed only where a
current Runtime record on digest `508783ac…` shows it.

| Journey | State | Evidence |
| --- | --- | --- |
| GJ-1 Device Observe | `REAL_DEVICE_PASS` (partial: HAR leg not run) | `agent run --operation observe.device@1` → `job-06c4e41e2f5177afc96b6cd724b1be37`, succeeded, `outcomeUnknown false`, `blockers []`, `actualStepKinds` `[probeHostTool, probeHDCServer, probeDevice, runApprovedRemoteRead]`, 3 verified Artifacts. `capture.diagnostics@1` → `job-39057153d7f0999348a442c2466f5672`, succeeded, 6 Artifacts including an 868 140-byte HiLog. `runtime service restart` then all six Jobs of this window readable through `job show`/`job result`. **§2.1 HAR crash-resume not executed** — it needs a physical USB detach and reattach, which was requested and not yet performed. |
| GJ-2 HAP Debug | `REAL_DEVICE_PASS` | `debug.hap@1` → `job-458fadbe5a6f543ab35832a88ff7093b`, succeeded, `deviceMutation`, `evidence.status verified`, `cleanup []`, all ten step kinds `[probeDevice, runApprovedRemoteRead, sendFile, installPackage, startApplication, verifyRemoteState, captureRemoteStdout, stopApplication, uninstallPackage, cleanupOwnedRemotePath]`, capability `CAP-RT-POLICY-51F798AE3292E1898AE9B95742A0711DA0B42406-G1` reserved and consumed with plan, step-set and Artifact digests. |
| GJ-2 failure compensation (#1773) | `REAL_DEVICE_PASS` | A confirmed failure produced by a bundle whose named Ability does not exist. `job-461b9ade98f8ce0164382eded520ec0b`: `agent run` returned exit 75 with `state finalizing`, `outcomeUnknown false` and `nextAction {kind: reconcile, reasonCode: job.finalizationPending}` and no `retryAfter` — the strict CLI accepted the new variant rather than polling or calling it unreadable. `job reconcile` then returned `failed` with `nextAction readResult`. Compensation actually ran on the device: `actualStepKinds` ends `[… verifyRemoteState, stopApplication, uninstallPackage, cleanupOwnedRemotePath]` and `cleanup []`. |
| GJ-3 Native Debug, positive | `REAL_DEVICE_PASS` | `debug.hap@1` with `cleanupPolicy retain` → `job-33af2af4715f1d158e0aa985c8328cca` left the bundle installed and running. `deploy.native-library.app-owned@1` → `job-a48fdb55ba96e68256b566848d39c538`, succeeded, `verified`, `verification-report.json` reports `loaderVerified true`, `abi armeabi-v7a`, `processIds 1996`, `publishedSha256 15d07bb340003996a6cca6b84a2bb7ab46bffca10c7e92283426ea28abdd0877`. |
| GJ-3 rollback leg | **not passed** | The ghost fixture reached the device: `job-5b91a6a9f87b23fc689aa12584469758` failed with `outcomeUnknown false`, `status artifactIntegrityFailed`, `missingRequiredArtifacts ["verification-report.json"]`, and `publish-report.json` carries the ghost's `publishedSha256 260a533ae2b02e23810aa5ab6ea9c1a5cf4524b19484ede66cb4dc0b7bb86d3a`. The runbook requires the evidence to prove the backup was rolled back and the target process recovered. It does not: the Job published no rollback attestation and no restored-library readback. Recorded unverified rather than passed. |
| GJ-4 Flash Recovery | `BLOCKED_BY_PRODUCT_DEFECT` | Two independent gates. `flash prerequisites` and `flash lane-preview` both refuse with `flash.postFlashHDCBindingConflict: stored alias revision 4 is newer than target revision 2`; `flash bootloader-status` reads `hdcNormal`/`unbound`. Separately `flash.full-restore@1` is `unavailable` in the Catalog (`provider_tool_unavailable`, ArkForge connected for assessment only, no named hardware acceptance campaign). No Flash was submitted. Diagnosis and the delivered mechanism: `chg-2026-059/evidence/runs/TASK-AFA-001/alias-lineage-reissue-20260908.md`. |
| GJ-5 Bounded AI Debug Loop | `NOT_STARTED` | Not attempted in this window. Two of its operations are `unavailable` on this host (`workspace.sign-openharmony-hap@1`, `workspace.symbolize-crash@1`), and GJ-1's HAR leg and GJ-3's rollback leg were prioritised first. |

Import and Artifact export were exercised on this build: `artifact export` of the
committed HAP import returned exit 0, `overwritten false`, 2 679 364 bytes, and
the exported file's SHA-256
`3ab86dc367d00ca533b4b29219e104d60dbfd1f9f95268f570cec3656a82db82` is
byte-identical to the imported source.

## Defects found, and where their fixes are

1. **`agent.run` reported a failed Job's evidence as `verified`.** For
   `job-5b91a6a9f87b23fc689aa12584469758` the Agent surface published
   `status verified` / `blockers []` while `job.evidence` published
   `artifactIntegrityFailed`. Two derivations of one record; the Agent copy
   never checked which required Artifacts were absent. Fixed under TASK-SVC-002.
2. **GJ-3's rollback leg publishes no rollback attestation.** See the row above.
   Not repaired; recorded for the Journey.
3. **The alias revision counter is reissued when the daemon state directory is
   retired**, permanently blocking Flash with a refusal that describes a newer
   route. Mechanism, proof and tests delivered under TASK-AFA-001; the entry
   point needs two additional contract paths and is requested there.
4. **The Session surface refused with a sentence that named nothing.**
   `session list` exits 69 and pointed at `runtime storage status`, which
   publishes only `unaccountedSessionCount: "1"`. Fixed under TASK-SVC-002; a
   second defect surfaced with it, where a readable-name/unreadable-content
   directory was reported as a malformed name.

## SVC-AC results

| ID | Result | Basis |
| --- | --- | --- |
| SVC-AC-01 one control contract | **met on this build** | One `1.0.0`, one contract identity `1054d17b…`, one published method registry read back from the running daemon; CLI, App and Executor all reached it. Negative matrices are SVC-001's contract tests, not re-run here. |
| SVC-AC-02 capability parity | **met on this build** | `arkdeck commands` and `operation list` resolve to one entry point each; every command exercised in this window dispatched through the published surface with no raw HDC, shell or flash command. |
| SVC-AC-03 CLI semantics | **met on this build** | `--output json` used throughout; `agent run` waiting, exit 75 with an explicit continuation and no retry, `job reconcile` read-back, and exit 2 for a failed Job's result all behaved as published. No automatic re-dispatch was observed. |
| SVC-AC-04 strict current requests | **not re-verified** | No negative decode matrix was run against the installed Runtime in this window. SVC-001's contract tests cover it; this record does not restate them as a real-device result. |
| SVC-AC-05 current durable formats | **not met** | No production caller publishes a Session. `SessionStorageTerminalFinalizer` has only test callers, the retention catalog holds `{"entries":[],"generation":0}`, and the seven Jobs run today wrote nothing under the Sessions root. Current Job → formal Session → exact finalized export cannot be demonstrated. |
| SVC-AC-06 old state and recovery | **partially met** | Zero replay and zero new dispatch held throughout: the three pre-existing `waitingForRecovery` Jobs were read, never replayed; GJ-4 refused before any partition write; no state was reset and no directory swapped. The full fault matrix was not re-run on hardware. |
| SVC-AC-07 evidence integrity | **met after #1777** | On `6ba5a0b9` the Agent evidence surface published `verified` for a Job whose authoritative evidence was `artifactIntegrityFailed`. Re-verified on `31142a78`: `agent status --execution-id gj3-rb-20260908b` and `job evidence` for `job-5b91a6a9f87b23fc689aa12584469758` now publish the same `blockers`. |
| SVC-AC-08 internal formats | **not re-verified** | Debug permit/document and bound Provider descriptor paths were not exercised in this window. |
| SVC-AC-09 current configuration | **partially met** | `runtime service update` wrote the current install receipt and preserved the ArkForge lane, ArkTrace descriptor and pinned HDC unchanged. All four App presentation cases passed, including the two that read this build's real Runtime data. The signing-credential legs were not exercised. |
| SVC-AC-10 complete delivery | **not met** | GJ-4 still blocked (its reconciliation entry point is not wired), GJ-5 not started, GJ-1's HAR leg and GJ-3's rollback leg not passed, and Session export has no producer. The four defects found in the window are fixed and merged. |

## App presentation

`sh scripts/ci/run-ui-tests.sh` on a quiet host with its own DerivedData, run
serially. All four cases passed.

| Case | Result |
| --- | --- |
| `SettingsStorageStateTests` (2 cases) | passed |
| `AppShellUITests/testRealRuntimeStorageSettingsMatchReadbackInBothLanguages` | passed, 24.7 s |
| `AppShellUITests/testRealRuntimeHistoryKeepsUnknownFlashEvidenceInspectableInBothLanguages` | passed, 50.7 s |
| `AppShellUITests/testHistoryAndRecoveryContinuousSessionInBothLanguages` | passed on the second attempt, 323.1 s |

The two `RealRuntime` cases skip themselves unless given real Runtime data, and
they read it from the **test runner's** environment, so the variables must carry
xcodebuild's `TEST_RUNNER_` prefix. Without it they skip silently and the run
still reports `** TEST SUCCEEDED **` — a shape worth knowing, because a skipped
case is not a presentation check. They were supplied with:

```text
TEST_RUNNER_ARKDECK_REAL_RUNTIME_UNKNOWN_FLASH_JOB_ID=job-c9274a31cb5ba7c8aad61451416af4f4
TEST_RUNNER_ARKDECK_REAL_RUNTIME_STORAGE_STATUS=<runtime storage status --output json>
```

`job-c9274a31cb5ba7c8aad61451416af4f4` is a real pre-existing `outcomeUnknown`
`flash.full-restore@1` Job on this host whose `actualStepKinds` is `null`, so
the History assertion exercised the genuine unreported-steps presentation in
both English and Chinese. The storage case compared the App's Settings pane
against this build's actual `runtime.storage.status` result, including the
unaccounted-content state.

`testHistoryAndRecoveryContinuousSessionInBothLanguages` failed its first
attempt with "Restarting after unexpected exit, crash, or test timeout" and no
assertion message — the known automation-mode family — and passed on the single
permitted retry. Recorded as passed with the flake noted, not as a product
defect.

## Re-verification on `16fe9617`

All four fixes merged on 2026-09-08. Two further clean protected-`main` helpers
were built and installed through `runtime service update --daemon`, and each
fix was checked against the exact real state it was found in.

| Build | CLI SHA-256 | Daemon SHA-256 | Installed |
| --- | --- | --- | --- |
| `31142a78` (#1777–#1779) | `6f5d2846a836365875c010570beccaa5d2b149b19d97e8ba9dd791a6e8deca1a` | `609b706fa2e84294f2f998c9907c2d4119314549a0c051e4f5232960607d0a29` | `2026-09-08T09:18:01Z` |
| `16fe9617` (#1780) | `50a9d887a51a37784a1cc034ef33d2252d7b09808656f4b717560d6778230d25` | `5bb46f5955c6346764a1568f7027182254a5ea2c7a6cc0a3d79942c6823a3760` | `2026-09-08T09:20:24Z` |

**Defect 1 — Agent evidence.** Same Job, same durable record, both surfaces on
the installed `31142a78` Runtime:

```text
agent.status  status=blocked                  blockers=["artifactIntegrityFailed"]
job.evidence  status=artifactIntegrityFailed  blockers=["artifactIntegrityFailed"]
```

Before the fix the Agent line read `status=verified  blockers=[]` for that same
Job. SVC-AC-07 is met.

**Defect 3 — GJ-4 refusal.** `flash prerequisites --target TGT-958780b2ffb7
--device-profile dayu200` on the installed Runtime now answers:

```text
flash.postFlashHDCAliasLineageReissued: the stored alias names this target and
Loader identity at revision 4 while the live target is at revision 2. The
revision counter was reissued, so the two are not comparable; the stored alias
must be reconciled against fresh device facts before this target can be flashed
```

The host is still blocked — the reconciliation mechanism has no entry point yet
— but the refusal now says which of the two things happened.

**Defect 4 — Session diagnosis.** `session list` on the installed `16fe9617`
Runtime, against the real 2026-08-02 directory:

```text
exit 69  operationUnavailable  phase=sessionOwner  newDispatchCount=0
Session catalog contains unaccounted content:
  2026/08/rockchip-session-42f8e86d-8cbf-4aa0-a411-5e1624e9f291 (unreadable)
```

The reason matches the prediction made when the fix was written. The directory
is untouched: `.session-identity.json` and `journal.jsonl` still carry their
2026-08-02 timestamps and SHA-256
`5b2ac60de1e6359679a5b18edb51513c1817cdaf52cf96420fe0e971d461a2f7` and
`bbc9cac50eb1c32423b0326cdc3f12db741ce9d3fae06ed322a4ce2de800b2d2`, no
`manifest.json` was created, and the catalog still reads
`{"entries":[],"generation":0,"schemaVersion":"1.0.0"}`.

**GJ-1 on the current tip.** `agent run --operation observe.device@1` on
`31142a78` → `job-b9c6159e314f4a445dcda47d981196c9`, succeeded,
`outcomeUnknown false`, `status verified`, `blockers []`, same four step kinds,
target `TGT-958780b2ffb7` still at `bindingRevision 2` on
`OpenHarmony-7.0.0.37`. `doctor --deep --require-healthy` exit 0.

The three pre-existing `waitingForRecovery` Jobs were untouched throughout; the
ledger grew only by the Jobs this window created.

## Not executed, and why

- **GJ-1 §2.1 HAR crash-resume** — needs a physical USB detach and reattach.
  Requested; not yet performed.
- **GJ-4** — blocked by the two gates above. No Flash was submitted, no
  capability requested, and no `--rebind` used.
- **GJ-5** — not attempted.
- **Session publication and export** — no producer exists.
- **Windows** — no Windows 11 x64 host is reachable from this session.

## Final Swift single-v1 baseline for CHG-2026-074

The baseline is protected `main` `16fe9617fb547cca6e5ebcf8f81bce0c377b69c3`.
Every contract identity in the table at the top of this record is **unchanged**
from `6ba5a0b9` — the four merged fixes changed no published shape:

| Identity | Value at `16fe9617` |
| --- | --- |
| Control protocol | `1.0.0` |
| Contract identity | `1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d` |
| Control JSON blob | `f47372feb9034ba17560b59d5dbde91206cb9aae` |
| Generated Swift blob | `6d3c1fb680d6a338ba59cb80af53aa46505196cb` |
| Method schemas, 96 files | `ebe719ec8423b064e4a751ce98458510e8b1dd005563768295f4a768af359cd5` |
| Frame corpus, 96 files | `769ec0f008f706c07c4dcf995e5ba0d09915ac896c974661618bbe8cdf3ebbb5` |
| Catalog tree, 35 files | `b84ffac89462797d0d5bb4ac2d39d30803d71365af187e0898893135c58d721b` |
| Runtime Catalog digest | `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` |

This is a **development** baseline, not a hardware-verified one. GJ-4 and GJ-5
did not pass on it, GJ-1's HAR leg and GJ-3's rollback leg did not, and Session
export has no producer. CHG-2026-074 may consume the contract identity, schema,
corpus and Catalog digests; it may not treat this as a completed real-device
acceptance.
