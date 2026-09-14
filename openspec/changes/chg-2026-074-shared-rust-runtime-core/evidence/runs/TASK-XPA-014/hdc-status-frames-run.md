# TASK-XPA-014 — the live HDC status through the Swift daemon's handler (macOS, 2026-09-14)

TASK-XPA-014 remains in progress. Base: protected main `c1cd1ea4`; no stack. Every answer here is
synthetic host data. The observers run over the seams lane B's status oracle recorded, and one test
reads a copy of the installed DevEco hdc without running it. Nothing is device evidence
(POL-VERIFY-001, POL-MODE-001). No Rust code changes.

This is the r11 Swift-only oracle for `runtime.hdc.status` of milestone M1. Every Golden Journey's
preflight (runbook §1) reads `arkdeck runtime hdc status`, and the Rust daemon is to answer it with
lane B's observer (#1947).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for M1 |
| --- | --- | --- |
| Lane B's status oracle and the Rust observer that replays it byte for byte (#1947); the managed HDC server (SPK-6) | `HDCStatusControlFramesContractTests`: the oracle's 22 cases through the daemon's handler, and a registered tool's client version; the `runtime.hdc.status` schema re-derived from what the handler answers | The Rust daemon composing the observer and answering `runtime.hdc.status` (lane A, next); `runtime.hdc.restart` and `runtime.hdc.impact-preview`; `target.adopt` and `target.availability`; the HAR path's observation owner, resume and human-action routes |

## Why

The published schema was derived from three corpus frames: a refusal, a daemon without a tool, and a
configured tool that was never observed. So it pins `generation`, `processId`, `clientVersion`,
`clientVersionSource` and `serverVersion` to `null`, and `signature` to `{state}` or `null`.

Once the observer observes a server, it answers with:
- a decimal generation;
- an integer process identity;
- the five-member signature;
- for a registered tool, its client version.

The Rust control gate rewrites any answer outside its method's schema to `internalError`. So the
Rust daemon's live answers need these shapes published first, from frames the Swift daemon's handler
answered.

## The tests

`HDCStatusControlFramesContractTests.testTheHandlerAnswersEveryCaseOfTheStatusOracleAsItsSnapshot`:
- It takes the oracle's fixed root and lock (`/private/tmp/arkdeck-hdc-status-oracle`), which
  `HDCStatusOracleContractTests` and the Rust replay also serialize on, and writes the shared fake
  driver there.
- It rebuilds each of the 22 cases in `rust/tests/fixtures/hdc-status/cases.json` from the inputs
  the oracle recorded:
  - the tool;
  - the startup facts;
  - the daemon version;
  - the launch record;
  - the identity observation;
  - the managed-process verdict;
  - the disturbance.

  Each observer uses the production signature inspection.
- It composes each observer into `RuntimeControlPlaneHandler` as the daemon composes its HDC host's
  observer; the case without a tool gets none. It then sends a `runtime.hdc.status` frame through
  the handler's line entry.
- Each answer must be the oracle's snapshot byte for byte (`snapshots/NN-<name>.json`), and nothing
  is dispatched.

`testTheHandlerAnswersTheClientVersionOfARegisteredTool` copies the installed DevEco hdc when its
digest is a registered one (here `05b2bf7a…`, 3.2.0f). It answers for that copy through the handler,
observed as launched:
- `clientVersion` `3.2.0f`, from `publishedExecutableDigest`;
- ownership `arkDeckManaged`;
- generation `100000023` and process 42;
- the signature `adHoc`, with identifier `hdc`;
- `serverVersion` still `null`.

A host without DevEco, or with an unregistered hdc, skips it. The frame it records is committed with
the corpus, so the schema check does not need it again.

Both tests passed on their own, 2 tests with 0 failures, and recorded 23 frames.

## The control shapes

The whole Swift suite was recorded with `ARKDECK_CONTROL_FRAME_LOG` (`run-swiftpm.sh test
--parallel`, 247 frame files), this test among them. The only failing test was
`testFramesRecordedByThisRunValidate` against main's schemas, with 10 failures. They are the same 10
#1950 found, shapes other lanes record outside `swift test --parallel`:
- `artifact.export`, three;
- the request parameters of `health`, three `runtime.bundle.*` methods and three `runtime.tool.*`
  methods.

That check validates only the frames recorded before it runs, so the recording's 30
`runtime.hdc.status` frames were then checked on their own. Under main's schema 18 of them fail, all
on their result.

Only `runtime.hdc.status` is re-derived, by #1925's procedure, from the recording's 30 frames of the
method together with its 3 corpus lines. A structural check (types, properties, required members,
enums, `anyOf`) found that the new schema admits everything main's did. No refusal code was added
or removed, and all 3 committed lines are kept.

| Member | Main | Now |
| --- | --- | --- |
| `generation` | `null` | `null` or a string |
| `processId` | `null` | `null` or an integer |
| `clientVersion`, `clientVersionSource` | `null` | `null` or a string |
| `signature` | `{state}` or `null` | `{state, identifier, teamIdentifier, platformTrust, executionAssessment}` or `null`; only `state` required; `identifier` `null` or a string; `teamIdentifier` `null` |

The corpus grows from 3 to 7 lines. The four new ones are:
- a tool that fails its identity check, with every tool fact withdrawn;
- an unknown identity, with the unsigned five-member signature;
- an observed server whose ownership stays unproven: generation `100000023`, process 42;
- the registered tool observed as launched: `3.2.0f`, `arkDeckManaged`, and the `adHoc` signature
  with identifier `hdc`.

`rust/scripts/generate-contract.py --write` refreshed the checkout manifest
(`spec/baselines/swift-single-v1.json`): 105 methods and 699 recorded shapes, up from 695.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| This test, recording | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-hdc-status-frames-probe run-swiftpm.sh test --filter HDCStatusControlFramesContractTests` | 2 tests, 0 failures; 23 frames |
| Whole Swift suite, recorded | `ARKDECK_CONTROL_FRAME_LOG=/private/tmp/xpa014-frames-hdcstatus-r1 run-swiftpm.sh test --parallel` | 247 frame files, 30 `runtime.hdc.status` frames; the only failing test is `testFramesRecordedByThisRunValidate` against main's schemas (10 failures, above) |
| The 30 frames against main's schema | `ARKDECK_CONTROL_FRAME_LOG=<the 30 frames> run-swiftpm.sh test --filter ControlMethodSchemaContractTests` | 5 tests, 18 failures, each a `runtime.hdc.status` result |
| Derivation (#1925's procedure) | `generate-control-contract.py --derive-method-schemas` over the 30 frames and the corpus, then the structural comparison with main's schema | admits everything main's did; codes unchanged; corpus 3 → 7 lines, the 3 committed lines kept |
| Oracles and schemas, compare mode | `ARKDECK_CONTROL_FRAME_LOG=<the 30 frames> run-swiftpm.sh test --filter '(ControlMethodSchemaContractTests\|HDCLiveStatusContractTests\|HDCStatusControlFramesContractTests\|HDCStatusOracleContractTests)'` | 14 tests, 0 failures: the corpus and the 30 frames are valid under the new schema, lane B's oracle still matches its fixture, and the handler answers every snapshot |
| Rust manifest | `rust/scripts/generate-contract.py --write`, then `--check` | 105 methods, 699 recorded shapes; the check passes |
| Rust contract and control tests | `cargo test -p arkdeck-contract -p arkdeck-control` | all pass; `read_only` 15 of 15 |

## Unified local gate

`python scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD
--merge-base --include-worktree --run-local` (merge base `c1cd1ea4`), with `ARKDECK_PYTHON` naming
`.venv-sdd` and the planner run from a virtual environment carrying PyYAML 6.0.3 and jsonschema
4.26.0:

| Run | Head | Result | Log |
| --- | --- | --- | --- |
| r1 | `de6dfd1b` | `gate exit=0`: the common checks and SDD, the Swift lane (full parallel, 2,675 tests, then the serialized lanes), the Rust lane on the development and candidate views (format, Clippy, the workspace tests — 2,067 passed in all over the workspace run and both views, none failed — and the contract checks), `cargo deny --locked check` and `cargo vet --locked --no-registry-suggestions` | `/private/tmp/xpa014-hdc-status-frames-gate-20260914-r1.log`, SHA-256 `beebaa8b9b481b3553f83aa99fc50afe23f1c7b2997e0229010887a5fc271075` |

The amend after r1 only fills in this row.

## Not run, and why

- **The Rust daemon's answer.** The next slice composes the observer and serves the method. Until
  then the Rust control layer answers `runtime.hdc.status` with the foundation's refusal.
- **The supervisor route of the ownership decision.** As in lane B's oracle, no supervisor actor is
  composed.
- **A live server.** The identity observation and the managed-process verdict are the recorded
  seams; no process is observed.
- **A tool signed with a team identifier.** The registered hdc on this host is signed ad hoc, and no
  test answers for a team-signed tool, so `teamIdentifier` stays `null`. The Golden Journeys use the
  registered DevEco toolchain. An answer for a team-signed hdc would still be rewritten until a
  frame records one.
- No device.
