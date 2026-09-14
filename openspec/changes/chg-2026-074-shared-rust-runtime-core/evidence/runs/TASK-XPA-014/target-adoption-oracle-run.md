# TASK-XPA-014 — Target adoption and availability oracle (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `68e8241a`; no stack. The oracle was first recorded on `05e2f553` and then
replayed onto this main. Nothing conflicted, and the fixture is unchanged: the capture answers it
includes did not change. Every request and
answer here is synthetic host data over `/bin/sh` scripts; nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Rust code changes.

This is the r11 Swift-only oracle for the runbook §2 path of milestone M1. A Golden Journey that
starts from a device it has never adopted runs `device candidates`, then `target adopt` from the
exact observation, then `target show` and `target availability`. The control schemas its frames
extend are re-derived from them, so the Rust slices that serve this path change no Swift file.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| The agent execution, lifecycle and physical-assistance oracles (#1925, #1944, #1950), which pre-adopt the fake device through the Target store; lane B's USB relation port and physical-relation proof (#1952); the live HDC status shapes (#1954) | `TargetAdoptionOracleContractTests` and `rust/tests/fixtures/target-adoption/`; `HDCOracleHarness` gives the handler the managed HDC server's startup diagnostics when an oracle names them; the extended control schemas re-derived | The Rust Target observation owner: observation identities and generations, following a reference, adoption and the Target document writer (lane A, next); `runtime.hdc.status` on the Rust daemon (the wiring slice after #1954); the HAR path's raise, resume and human-action routes |

## The oracle

`TargetAdoptionOracleContractTests.testSwiftAdoptsTheSharedFakeDeviceAndAnswersItsAvailability`
composes the daemon's Target observation owner over the harness's provider and dispatcher, on the
oracle's fixed clock (`2026-09-14T00:00:00Z`). No target is adopted before the first exchange. The
handler has the managed HDC server's startup diagnostics (the fake's digest, `3.2.0d` client and
server, `127.0.0.1:8710`, `default`), as the daemon gives it. It has no bootstrap machine: a warm
presentation snapshot schedules background device lists, which would make the fake's calls
nondeterministic.

| Exchange | Method | Answer |
| --- | --- | --- |
| `observe` (mode `normal`, a relation on attachment 30) | `device.observations` | generation 1: the device `Connected` and `relationProven`, observation `<obs-1>`, no target |
| `adopt.invalid`, `adopt.leadingZero` | `target.adopt` | `invalidInput`: no parameters; generation `"01"` |
| `adopt.unknown` | `target.adopt` | `resourceConflict`: an observation the snapshot never held |
| `adopt` | `target.adopt` | `adopted`: `TGT-3ba3f5f43b92` at binding revision 1, the request's snapshot generation 1 |
| `adopt.again` | `target.adopt` | the same receipt, after another bracketed list |
| `observe.adopted` | `device.observations` | generation 2, the adoption's own; the row names its target |
| `availability` | `target.availability` | the binding ready; presence `unresolved`; the tool `ready` with the server's diagnostics; host-scoped operations; profile unresolved |
| `availability.missing`, `availability.unknown` | `target.availability` | `invalidParams`; `notFound` |
| `adopt.readopt` | `target.adopt` | the same target from generation 2's reference; no new binding |
| `observe.unauthorized` (mode `unauthorized`) | `device.observations` | generation 4, the re-adoption having left 3; the row `Unauthorized`, still `relationProven` as `<obs-1>` |
| `adopt.stale` | `target.adopt` | `resourceConflict` at generation 3 |
| `adopt.unauthorized` | `target.adopt` | `targetTrustPending` |
| `observe.unrelated` (mode `normal`, no relation) | `device.observations` | generation 5: `generationScoped`, a new observation `<obs-2>`, no target named |
| `adopt.unrelated` | `target.adopt` | `admissionDenied` |
| `observe.replugged` (attachment 31) | `device.observations` | generation 6: `relationProven`, `<obs-3>` |
| `adopt.drift` (attachment 31, then 32 after two reads) | `target.adopt` | `factsDrifted`: the relation changed during the adoption's readback |
| `observe.bounded` (attachment 32) | `device.observations` | generation 7, `<obs-4>` |
| `adopt.tooMany` (mode `tooMany`: 1,001 rows) | `target.adopt` | `operationUnavailable`, "device snapshot exceeds its bounds", with no reference in its details |
| `observe.tooMany` | `device.observations` | `operationUnavailable` |

Every refusal carries `phase: preAdmission` and `newDispatchCount: 0`, plus the reference when the
refusal names one. The fake received 19 calls: 16 device lists and the tool version read by each of
the three adoptions that got that far.

It was recorded with `ARKDECK_RUST_TARGET_ADOPTION_RECORD=/private/tmp/xpa014-target-adoption-oracle-r1`
and installed as `rust/tests/fixtures/target-adoption/`, 9 files. `cases.json` holds the adopted
target, the managed server's diagnostics and the 21 exchanges. Beside it are:
- the fake, its answers and its 19 calls;
- the Target document, and the display names the adoption handed the target;
- the Job index, which is empty;
- the tree and the provenance.

The four observations read as `<obs-1>` to `<obs-4>`. A second recording (`-r2`) is identical
(`diff -r`).

## The harness change

`composition(...)` takes `hdcRuntimeDiagnostics:`, none by default, and hands it to the handler as
the daemon hands its HDC host's diagnostics (`ArkDeckAgentDaemonMain/main.swift`). The existing
oracles pass none and are unchanged. The driver and `recordOrCompare` do not change.

## The control shapes

Before any re-derivation, every recorded exchange was validated against main's schemas with
jsonschema:
- its parameters against `request`;
- a success against `result`;
- a refusal's code against `errorCode`, and its details against `errorDetails`.

5 of the 21 exchanges fall outside them:
- `target.availability`, 1 of 3: the tool leg `ready`, carrying the server's diagnostics. Main's
  schema admits only the three-member `absent` leg.
- `target.adopt`, 3 of 11: `admissionDenied`, `factsDrifted` and `operationUnavailable` are not
  among its refusal codes.
- `device.observations`, 1 of 7: `operationUnavailable` is not among its refusal codes.

The same check finds all 33 of the physical-assistance oracle's exchanges inside their schemas,
which #1950 re-derived.

The whole Swift suite was then recorded on this branch with `ARKDECK_CONTROL_FRAME_LOG`
(`run-swiftpm.sh test --parallel`, 248 frame files), this oracle among them in compare mode. The
only failing test was `testFramesRecordedByThisRunValidate` against main's schemas, with 10
failures. They are the same 10 that #1950 and #1954 found, shapes other lanes record:
- `artifact.export`, three;
- the request parameters of `health`, three `runtime.bundle.*` methods and three `runtime.tool.*`
  methods.

That check validates only the frames recorded before it runs. So the recording's frames of the
three methods were checked on their own against main's schemas: 58 of `device.observations`, 32 of
`target.adopt` and 7 of `target.availability`. They fail on the same five shapes as the offline
check above.

Only the three schemas are re-derived, by #1925's procedure. Each comes from the recording's frames
of its method together with the method's committed corpus. A structural check (types, properties,
required members, enums, `anyOf`) found that each new schema admits everything main's did, and
that every refusal code a schema publishes has a corpus frame.

| Method | Refusal codes added | Corpus lines |
| --- | --- | --- |
| `device.observations` | `operationUnavailable` | 13 → 15 |
| `target.adopt` | `admissionDenied`, `factsDrifted`, `operationUnavailable` | 5 → 9 |
| `target.availability` | none (the `ready` tool leg) | 3 → 4 |

Every committed corpus line is kept. `rust/scripts/generate-contract.py --write` refreshed the
checkout manifest (`spec/baselines/swift-single-v1.json`): 105 methods, 706 recorded shapes (699
before).

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Oracle, recorded twice | `ARKDECK_RUST_TARGET_ADOPTION_RECORD=/private/tmp/xpa014-target-adoption-oracle-r{1,2} run-swiftpm.sh test --filter TargetAdoptionOracleContractTests` | 1 test, 0 failures each; the two recordings identical (`diff -r`), r1 installed |
| Every oracle on the harness, compare mode | `run-swiftpm.sh test --filter` the agent execution, lifecycle, physical-assistance, observe, capture, debug HAP and native library oracles, and this one against its installed fixture | 8 tests, 0 failures: the harness change leaves the seven others' fixtures unchanged |
| The exchanges against main's schemas, offline | jsonschema over each exchange's parameters, result or refusal | 5 of 21 outside them (above) |
| Whole Swift suite, recorded | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-frames-target-r1 run-swiftpm.sh test --parallel` | 248 frame files: 58 `device.observations`, 32 `target.adopt` and 7 `target.availability` frames. The only failing test is `testFramesRecordedByThisRunValidate` against main's schemas (10 failures, the other lanes' shapes above). This oracle and the seven other harness oracles pass in compare mode on this main. |
| The 97 frames against main's schemas | `ARKDECK_CONTROL_FRAME_LOG=<the 97 frames> run-swiftpm.sh test --filter ControlMethodSchemaContractTests` | 5 tests, 5 failures: the five shapes above |
| Derivation (#1925's procedure) | `generate-control-contract.py --derive-method-schemas` over the recording's frames of the three methods and their corpus, then the structural comparison with main's schemas | all three admit everything main's did; codes as above; every committed corpus line kept |
| The 97 frames under the new schemas | `ARKDECK_CONTROL_FRAME_LOG=<the 97 frames> run-swiftpm.sh test --filter ControlMethodSchemaContractTests` | 5 tests, 0 failures: the committed corpus and the 97 frames are valid |
| Oracles and schemas, compare mode | `ARKDECK_CONTROL_FRAME_LOG=<the 97 frames> run-swiftpm.sh test --filter '(ControlMethodSchemaContractTests\|TargetAdoptionOracleContractTests\|DeviceCandidatesContractTests\|AgentDaemonContractTests)'` | 124 tests, 2 skipped. This oracle, `DeviceCandidatesContractTests` and `AgentDaemonContractTests` pass. The one failure is a `health` frame that `AgentDaemonContractTests` records in the same run, one of the other lanes' shapes above. |
| The exchanges under the new schemas, offline | jsonschema over each exchange's parameters, result or refusal | 0 of 21 outside them |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 706 recorded shapes; the check passes |
| Rust contract and control tests | `cargo test -p arkdeck-contract -p arkdeck-control` | all pass |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `68e8241a`), with `ARKDECK_PYTHON` naming
`.venv-sdd` and the planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema
4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `27c12bd7` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,676 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 2,148 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-target-adoption-oracle-gate-20260914-r1.log`, SHA-256 `0d009bf1969e85b319fab26e1bc3c39836847f11d50b182ef29659403a34536c` |

The amend after r1 only fills in this row.

## Not run, and why

- **No Rust replay yet.** The Rust daemon answers `target.adopt` and `target.availability` with
  the control foundation's refusal, and its `device.observations` mints new identities on every read
  and brackets nothing. Lane A's next slice serves them over lane B's USB relation port (#1952) and
  replays this fixture.
- **Presence from a warm snapshot.** No bootstrap machine is composed, so presence is `unresolved`
  and `deviceInformation` null, the shapes already published. Swift's daemon composes one; its
  presence and device information wait for a deterministic way to record them.
- **A real USB relation.** The relations are the oracle's. On a device, the Rust port reads them
  from `arkforged discoverDevices` (lane D) or a reader the maintainer approves.
- **A restart between observation and adoption.** Receipts and snapshots live in memory, and restart
  semantics stay out of the Rust port until L.1 item 13 is decided.
- No device, no real HDC.
