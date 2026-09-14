# TASK-XPA-014 — capture.diagnostics@1 Swift oracle and the shared oracle harness (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: lane A's Swift-only oracle PR
(`agent/xpa-014-observe-oracle-20260914`, `e14eef13`, the `observe.device@1` oracle over the shared
fake HDC) on protected main `aa4cc8d8`; this slice is stacked on it and declares that in its commit.
Every request and answer here is synthetic host data over `/bin/sh` scripts; nothing is device
evidence (POL-VERIFY-001, POL-MODE-001). No Rust file changes: this is the r11 "T0 oracles for M1
recorded once in a Swift-only PR" slice for the second operation of Golden Journey 1, so that the
Rust slices that follow change no Swift file.

## Already on main / this slice / still remaining

| Already on main (and on the base PR) | This slice | Still remaining for M1 |
| --- | --- | --- |
| `HDCOracleFake` (the committed POSIX sh fake HDC, one identity for Swift and Rust) and `ObserveDeviceOracleContractTests` with `rust/tests/fixtures/observe-device/` (base PR); the Rust analyzer path, journal/index/record writers and reads (#1889–#1900, #1909, #1911) | `HDCOracleHarness` — the composition, facts port, storage probe, frame sending, recording, index reading and machine-fact labelling every HDC oracle shares — with `ObserveDeviceOracleContractTests` reduced to its own cases, answers and orchestration and its fixture byte for byte unchanged; `CaptureDiagnosticsOracleContractTests` and `rust/tests/fixtures/capture-diagnostics/` | Rust `capture.diagnostics@1` (lane A), the `agent.*`/`human-action.*`/`target.adopt`/`runtime.hdc.*` oracles and their Rust, the M2 oracles (debug, native library, input, port-forward) |

## The harness

Lane A's `ObserveDeviceOracleContractTests` composed the standalone daemon's engine in-process
over the fake (the production daemon refuses an HDC executable whose identity is not registered),
sent one control frame at a time through `RuntimeControlPlaneHandler`, recorded every answer with
the pager's random `snapshotRevision` labelled, and recorded the store the Jobs leave with each Job
record's machine facts (`device`, `inode`, `volumeIdentity`, `admissionGeneration`) labelled. A
second oracle written the same way would drift from the first wherever a copy diverged, so those
parts moved verbatim into `HDCOracleHarness` (beside `HDCOracleFake`), parameterised only by what
an oracle owns: its fixed clock, roots and quota (`Settings`), its fake answers, its producer name,
its frame id, its fixture directory and its record variable. Acceptance of the move: the observe
oracle in compare mode against the unchanged `rust/tests/fixtures/observe-device/` — 1 test, 0
failures (`oracle-observe-compare.log`, run-swiftpm `test --filter
ArkDeckContractTests.ObserveDeviceOracleContractTests`).

## The capture.diagnostics oracle

`CaptureDiagnosticsOracleContractTests.testSwiftCapturesDiagnosticsOfTheSharedFakeDevice` adopts
the fake device (connect key `a`×32, tool version 3.2.0d) and, with the runbook's default input
`{"durationSeconds": 5}` (runbook §2: HiLog and UI dump, no trace, screenshot, crash log or
liveness), plans seven requests and runs four Jobs in order over one store while the fake answers
in a mode per case, then rejects a rerun and reads every Job:

| Case | Fake mode | Ends | What the fake answers differently |
| --- | --- | --- | --- |
| `captured` | `normal` | `succeeded` | — |
| `lowStorage` | `lowStorage` | `failed` | `df -k /data/local/tmp` leaves 16 KiB where the collection needs its 128 MiB budget (`insufficientDeviceStorage`) |
| `otherDevice` | `otherDevice` | `failed` | `list targets -v` lists another device's row (`targetConfirmationMismatch`) |
| `emptyHilog` | `emptyHilog` | `waitingForRecovery` | `hilog -x` answers nothing: the capture's verdict is unknown and the Job parks without replay |
| `staleBinding` | — | refused at plan | `expectedBindingRevision: 2` against revision 1 |
| `unboundRequest` | — | refused at plan | no `expectedBindingRevision` |
| `unadopted` | — | refused at plan | a target never adopted |

The fake's answers (`hdc-answers.sh`, recorded in the fixture) extend the observe fragment with
the three device commands the default input dispatches after the shared evidence preflight:
`df -k /data/local/tmp` (Swift `hdc.observeStorage`), `hilog -x` (`hdc.captureHilog`, 45 s
timeout, 16 MiB budget) and `hidumper -s WindowManagerService -a -a` (`hdc.captureUIDump`), with
the same bytes `DiagnosticsAndHAPContractTests`' scripted dispatcher returns.

Recorded (`ARKDECK_RUST_CAPTURE_DIAGNOSTICS_RECORD=/private/tmp/xpa014-capture-oracle-r1`, then
installed as `rust/tests/fixtures/capture-diagnostics/`, 75 files): `cases.json` (the target, the
four Job ids, 28 exchanges — plan/submit/run per Job, the rerun's `resourceConflict`, and
`job.result`, `job.evidence`, `artifact.list` per Job), the fake and every call it received,
`targets-state/targets.json`, `store/index.json` and every Job file, every Artifact (the captured
Job publishes `hilog.txt` 28 bytes, `ui-dump.json` 15 bytes, `capture.log` 2,029 bytes,
`markers.json`, `artifact-index.json` and `capture-summary.json` with `completeness: complete` and
`missingRequired: []`, the unselected products recorded `missing` with their reason), the Sessions
of the three Jobs that ended and the storage owner, `tree.json` and `provenance.json`. A second run
in compare mode reproduced every file byte for byte (`oracle-capture-compare.log`). Every fixture
path is Windows-safe (no control character, `<>:"|?*\`, trailing dot or space) and no file names
this host, its user or home directory.

## Not run, and why

- No Rust replay: the Rust engine does not serve `capture.diagnostics@1` yet (lane A's next
  slice); lane A's `rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/capture-diagnostics`
  will replay this oracle once it does and until then records the methods it does not serve as
  skipped.
- No device, no real HDC: the fake answers what the daemon asks.
- The other M1 methods (`agent.*`, `human-action.*`, `target.adopt/availability`,
  `runtime.hdc.*`) are not oracled here; their Swift paths are not engine-only and need the
  daemon's agent execution and HDC lifecycle composition.
