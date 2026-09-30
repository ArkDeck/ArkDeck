# TASK-XPA-004 — the bootstrap machine, the Target store and the physical-assistance actions on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase WM1, slice CI2-B (part 1 of the
remaining XPA-004 work). Base: protected `main` `565f8b1d` (#2394). Host: the Windows 11 x64
reference host, non-elevated, NTFS. No device was contacted, no `hdc` ran, no Windows HDC tuple
was registered or assumed, and nothing installed was read or written. Host tests are not Windows
acceptance.

## What XPA-004's deliverables needed, and what was already on `main`

The deliverables are: the bootstrap state machine; the targets store with the same JSON; HAR
`physicalConnection` / `needsSelection`; and `waitingForHuman` for unauthorised candidates.

| deliverable | Swift | Rust owner | on Windows |
| --- | --- | --- | --- |
| bootstrap state machine | `DeviceBootstrapMachine` / `TargetObservationCoordinator` (the readiness pin `DeviceBootstrap.swift`) | `TargetObservations` (`arkdeck-provider-hdc::target_observation`), over `Sources { dispatch, relations, targets, now }` | built and composed by #2350. It is proved there over the Swift adoption oracle: adopted once as `TGT-3ba3f5f43b92`; unauthorised → `targetTrustPending`; no serial or two boards with one serial → `generationScoped`, `admissionDenied` with no dispatch |
| targets store, same JSON | `targets.json`, `target-display-names.json` | `TargetStore` under `.targets.lock` / `.target-display-names.lock` | built by #2350 on the NTFS host store, whose locks are `LockFileEx` on the dedicated lock files (SPK-5). Its `targets.json` equals the Swift owner's byte for byte, and the CAS and overlapping-transaction unit tests pass on NTFS. Nothing was left to port |
| HAR `physicalConnection` / `needsSelection`, `waitingForHuman` | `RuntimeAgentHumanAction`, `AgentPhysicalActionKind` | `AgentExecutionStore` / `AgentEngine` raising, `HumanActionResources` listing | the owners were built on Windows by #2391. They were proved there only over the records Swift left, with no observation. The raising path was not proved on Windows: an execution that observes devices and stops for a person. This slice proves it |

`needsSelection` is the bootstrap's outcome for more than one candidate (CHG-2026-048 design).
The agent owner raises it as an `ambiguousIdentity` action whose choices are the candidates.
`waitingForHuman` is the execution state each of these actions puts the run in.

## What this slice adds

`arkdeck-hoststore/tests/windows_agent_human_action_raise.rs` is the Windows replay of
`agent_human_action_raise.rs`, over owners laid down owner-only on NTFS. It covers the 19
exchanges of Swift's physical-assistance oracle (`rust/tests/fixtures/agent-human-action`) that
need no adoption, resume or Job, in their recorded order.

The devices come from an in-process scripted HDC (`HdcDispatch`). It answers `list targets -v` in
the state that the oracle's fake HDC (`hdc-answers.sh`) answered for each exchange's mode:
offline, unauthorised, two devices, one device. No `hdc` process runs, and no Windows HDC tuple
is needed, because the owners are given the dispatch directly. The daemon's own composition
still has no HDC and refuses before admission, as before.

Measured:
- **Answers.** Every answer equals Swift's, once the identities the owners mint read as the
  oracle's labels:
  - `connect.*`: `physicalConnection`, `device.notObserved`, `human.connectOrPowerDevice`,
    `waitingForHuman`, then listed and shown;
  - `trust.*`: `deviceTrustPrompt`, `device.trustPending`, then abandoned, expired and run
    again;
  - `ambiguous.run`: `ambiguousIdentity`, with both candidates as choices;
  - `unproven.run`: `admissionDenied`, `preAdmission`, no new dispatch;
  - each list and show refusal of the human-action owner.
- **Device lists.** The dispatch was asked for exactly the four device lists the oracle's fake
  logged (`hdc-invocations.log` lines 1, 11, 12 and 13), argument for argument.
- **Records.** The `har-unproven`, `har-trust` and `har-ambiguous` records equal Swift's, up to
  the observation identities and generations advanced by Swift's skipped resume. `har-connect`
  still waits, at generation 4 with one action.
- **Target document.** `targets.json` is byte-identical: nothing was adopted.

## Local targeted checks

With `CARGO_TARGET_DIR=D:\cargo-target\ci2-bootstrap` and `CARGO_BUILD_JOBS=4`:

| command | exit |
| --- | ---: |
| `cargo fmt --all --check` | 0 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 0 |
| `cargo test -p arkdeck-hoststore --no-fail-fast` | 0 (234 passed, 0 failed, 4 ignored measurement tests) |
| the same three Windows tests (`windows_agent_human_action_raise`, `windows_agent_human_action_records`, `windows_target_owners`) with `TEMP`/`TMP` set to an 8.3 short path on C: (`…\Temp\AD-SHO~1`) | 0 (7 tests) |
| `PYTHONUTF8=1 sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) |
| `git diff --check` | 0 |

## Left for the next parts of this slice

- The Windows trusted USB relation census behind CHG-2026-078 §4, failing closed until the
  sample fills its `TBD(sample)` fields.
- XPA-002's byte-equality of the Windows `doctor`, `operation list` and `device candidates`
  machine output with the macOS fixtures.

Real-device adoption stays in phase A.

## CI

To be recorded by the follow-up.
