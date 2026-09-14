# TASK-XPA-014 — M2 run record: the pointer-gesture and port-rule oracles

Change: CHG-2026-074-shared-rust-runtime-core@r11. Milestone M2 (GJ-2), lane B recording the
T0 oracles of the interactive operations — `input.tap@1`, `input.long-press@1`,
`input.swipe@1`, `port-forward.create@1`, `port-forward.remove@1` — from Swift, over the shared
fake HDC driver, so that the Rust provider slices that follow change no Swift file and prove
argv parity by replay. Host measurement only — not hardware, platform or conformance evidence
(POL-VERIFY-001, POL-MODE-001). No device, no HDC server, no daemon process; the standalone
daemon's engine is composed in-process by `HDCOracleHarness`.

Base: protected main `68e8241a` (#1954). Branch `agent/xpa-014-pointer-port-forward-oracle-20260914`,
no stack. Files: `PointerInputOracleContractTests.swift` (new), `PortForwardOracleContractTests.swift`
(new), `rust/tests/fixtures/pointer-input/` (new, 51 files), `rust/tests/fixtures/port-forward/`
(new, 200 files), this record. No Rust, Catalog, spec, schema or production Swift change;
`HDCOracleHarness` and `HDCOracleFake` are used as they are.

## What was missing

The interaction map (lane B, 2026-09-14) found the five operations fully implemented in Swift
(`HDCPointerInputSpec`, `HDCPortForwardSpec`, their lowerings, verdicts, persisted forms and
reconciliation, the engine's port-rule readback gate and compensation) and covered by Swift's
contract tests, but with no oracle: nothing under `rust/tests/fixtures/` held them, and the
shared fake answered no `uinput`, `fport` or `rport` call. Under r11 (tasks.md, "The T0
oracles for M1 and M2 are recorded once, in a Swift-only PR against the fake HDC fixture")
that recording comes before the port.

## What Swift now records

Both oracles adopt one device (`aaaa…` × 32, tool 3.2.0d) on the harness's fixed clock
(`2026-09-14T00:00:00Z`), plan every case's request through `job.plan`, admit and run the cases
with a mode under the runtime's default policy capability while the fake answers in that mode,
then read every Job's `job.result`, `job.evidence` and `artifact.list`, and the capability store
last. A case with an `admission` is submitted and refused with that code; a case with neither
only plans.

### `rust/tests/fixtures/pointer-input/` — `PointerInputOracleContractTests`

The frame of the 2026-08-25 device measurement (1280x2832, `TASK-IDC-002`), captured on the
oracle's clock (`screenEpochUtc` `2026-09-14T00:00:00.000Z`).

| Case | Operation | Inputs | Mode | Ends | Fake's `uinput` answer |
| --- | --- | --- | --- | --- | --- |
| tap | input.tap | 640,1500 | normal | succeeded | `   click coordinate: (640, 1500)` + interval line + the boundary hint |
| longPress | input.long-press | 12,700, durationMs 1200, displayId 2 | normal | succeeded | `touch down 12 700` / `touch up 12 700` + hint |
| swipe | input.swipe | 100,2200 → 100,1200, durationMs 500 | normal | succeeded | `startX:100, startY:2200, endX:100, endY:1200` + hint |
| rejected | input.tap | 640,1500 | rejected | failed | `parameter error, unable to run` |
| expired | input.tap | screenEpochUtc 2000 ms old | — | admission refused `invalidInput` ("typed plan preflight failed before authorization: inputExpired: …") | nothing sent |
| outOfFrame | input.tap | 1280,1500 | — | admission refused `invalidInput` ("… outOfBounds(field: \"pointer\", detail: \"inside the declared 1280x2832 frame\")") | nothing sent |
| otherGesture | input.tap | 640,1500 | otherGesture | waitingForRecovery (`outcomeUnknown`, `awaitRuntimeReconciliation`) | a swipe's acknowledgement |
| afterUnknown | input.tap | 640,1500 | — | admission refused `admissionDenied` ("automatic Runtime target lineage is blocked: lineageBlocked(… outcome outcomeUnknown)") | nothing sent |
| shortHold | input.long-press | durationMs 400 | — | plan refused `invalidInput` ("input durationMs is below minimum 500") | — |
| swipeWithoutDuration | input.swipe | no durationMs | — | plan refused `invalidInput` ("required input durationMs is absent") | — |

Two facts the recording settled that the map did not have: the typed plan's preflight
(`pointerInputSpec`, the freshness gate included) runs at `job.plan` and `job.submit`, not only
at dispatch — a stale or out-of-frame gesture is refused before admission with nothing sent;
and an unknown gesture outcome parks the Job in `waitingForRecovery` and blocks the automatic
capability's lineage, so the next Job admitted under it is refused. After the first Job the
model and firmware reads are session-carried (`confirmationMethod:
machineReadbackSessionCarried`), so the driver's log is 12 lines: `list targets -v`, the two
`param get` reads and the tap; then `list targets -v` and the gesture for each later Job.

42 exchanges (10 plans, 8 submissions, 5 runs, 5 results, 5 evidence reads, 5 Artifact lists,
the capability list and 3 inspections); 51 files.

### `rust/tests/fixtures/port-forward/` — `PortForwardOracleContractTests`

The fake keeps the device's rule table in marker files between Jobs; `fport ls` lists it one
rule per line as `<key>    tcp:A tcp:B    [Forward|Reverse]`.

| Case | Operation | Rule | Mode | Ends | Device calls after the preflight |
| --- | --- | --- | --- | --- | --- |
| createForward | create | forward 23451→34561 | normal | succeeded | `fport tcp:23451 tcp:34561`; `fport ls` |
| removeForward | remove | forward 23451→34561 | normal | succeeded | `fport rm tcp:23451 tcp:34561`; `fport ls` |
| createReverse | create | reverse 23452→34562 | normal | succeeded | `rport tcp:34562 tcp:23452`; `fport ls` |
| removeReverse | remove | reverse 23452→34562 | normal | succeeded | `fport rm tcp:34562 tcp:23452`; `fport ls` |
| createRefused | create | forward 23453→34563 | createRefused | failed (`portForwardFailed`) | `fport …` exits 1 |
| removeMissing | remove | forward 23454→34564 | normal | failed (`portForwardFailed`) | `fport rm …` exits 1 (the device never had it) |
| ruleUnlisted | create | forward 23455→34565 | ruleUnlisted | failed (`portForwardReadbackMismatch`), compensated | `fport …`; `fport ls` (nothing listed); `fport rm …`; `fport ls` |
| readbackUnanswered | create | forward 23456→34566 | readbackUnanswered | waitingForRecovery (`outcomeUnknown`) | `fport …`; `fport ls` exits 1 |
| afterUnknown | create | forward 23459→34569 | — | admission refused `admissionDenied` (lineage blocked) | nothing sent |
| privilegedPort | create | localPort 80 | — | plan refused `invalidInput` ("input localPort is below minimum 1024") | — |
| unknownDirection | create | direction sideways | — | plan refused `invalidInput` ("input direction value is outside its enum") | — |
| withoutDevicePort | remove | no remotePort | — | plan refused `invalidInput` ("required input remotePort is absent") | — |

The four completed rules each left `port-rule-readback.json` (451 bytes, `present` among the
summary keys) under their Job; the compensated Job ran `compensate-port-rule` and
`verify-port-rule-compensation` after its readback mismatch, as the engine's compensation
promises. Here every Job reads the model and firmware again (the preflight is not
session-carried), so the driver's log is 40 lines.

62 exchanges (12 plans, 9 submissions, 8 runs, 8 results, 8 evidence reads, 8 Artifact lists,
the capability list and 8 inspections); 200 files.

## Measurement

```
swift test --filter 'PointerInputOracleContractTests|PortForwardOracleContractTests'
  record (ARKDECK_RUST_POINTER_INPUT_RECORD / ARKDECK_RUST_PORT_FORWARD_RECORD)   2 tests, 0 failures
  record again into fresh directories                                             identical byte for byte
  compare against the checked-in fixtures                                         2 tests, 0 failures
```

The first recording drove the same calls (the driver's logs are identical) with two case
expectations that the recording corrected: an unknown outcome ends in `waitingForRecovery`,
not a terminal state, and the frame guards refuse at admission. Both oracles hold the fixed
root `/private/tmp/arkdeck-hdc-oracle` under its lock and remove it afterwards; nothing touches
the installed daemon's state (`CFFIXED_USER_HOME` pointed at a scratch home for the runs).

## What stays with other owners

- The Rust provider port — `pointer_input` and `port_forward` in `arkdeck-provider-hdc`
  replaying these fixtures argv for argv — is lane B's next slice (TASK-XPA-016).
- The engine half — the `job.plan`/`job.submit` typed-plan preflight, the port-rule readback
  gate (`portForwardReadbackMismatch`) and `compensate-port-rule`, the lineage block after an
  unknown outcome, the persistent shell channel routing of pointer injection — and the
  daemon-level replay of both fixtures through `check-corpus-replay.py` are lane A's.
