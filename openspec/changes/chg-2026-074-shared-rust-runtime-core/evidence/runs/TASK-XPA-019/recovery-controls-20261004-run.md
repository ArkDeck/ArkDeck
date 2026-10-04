# macOS recovery controls — host verification

Date: 2026-10-04. Task: TASK-XPA-019. This is host and synthetic-fixture evidence.
It is not device acceptance, approval of a new capability, or an installed-runtime cutover.

The Job Inspector now calls the existing `job.reconcile` for a durable App-owned Job waiting
for recovery, and `job.run` only at a freshly confirmed safe boundary with a known outcome.
ClientKit pins Job, operation, target, Session, state and outcome, rejects current-epoch and
human-wait drift, and never retries an unconfirmed reply or submits a replacement Job.
The authenticated App ingress reopens only the existing closed App request vocabulary from
the durable original submission. Its exclusive continuation claim expires after the owner
returns; Runtime journal and authority checks still decide execution.

A waiting `flash.full-restore@1` record can explicitly verify and bind its own Loader using
`flash.bind-current-loader`. Fresh adopted targets must contain exactly that target once.
Runtime proves the Loader relation; the App validates the returned revision and does not
continue Flash, clear an unknown effect or select another device. This is identity association,
not a TCP/UART confirm-and-resume implementation. UI fixtures never dispatch these controls.
The bilingual prototype preserves all states and reports its actions as unconfirmed UI demos.

## Local targeted checks

Logs are under `/private/tmp/arkdeck-macos-closeout-20261004/`.

- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'RuntimeJobRecoveryApplicationFacadeTests|JobsLocalizationContractTests'`: exit 0;
  7 Swift Testing cases plus 6 XCTest cases, `recovery-controls-swift.log`.
  Cases include exact safe resume, unknown refusal, fresh identity/state/epoch/human drift,
  lost/wrong replies without retry, and missing/duplicate/foreign Loader targets.
- `CARGO_BUILD_JOBS=2 CARGO_TARGET_DIR=<this-worktree>/rust/target cargo clippy
  --manifest-path rust/Cargo.toml -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0, `recovery-controls-clippy-final.log`.
- The same three crates with `cargo test`: exit 0; 264 passing cases and 3 existing ignored
  cases, `recovery-controls-rust-final.log`. New ingress tests exercise the actual gate,
  explicit closed parameters, durable request/state combinations and parallel continuation
  exclusion. They use private fake roots and synthetic peers, never live device authority.
- Earlier compilation exposed private test access, then the existing guard against tests in
  daemon source modules. The final concurrency test uses AppIngress from the binary's test
  module; no production visibility was widened. Logs: `recovery-controls-clippy.log`,
  `recovery-controls-rust-recheck.log`. The initial isolated target also lacked the CLI needed
  by process tests; its same-source CLI prerequisite build passed before the final run
  (`recovery-controls-cli-prerequisite.log`). No assertion was weakened.
- `npm test` in `docs/design/arkdeck-ds`: exit 0, 84 cases,
  `recovery-controls-design-tests-final2.log`. Its first attempt lacked esbuild in the new
  worktree. `npm ci --ignore-scripts --offline` installed the lockfile's cached dependencies
  before the passing run (`recovery-controls-design-deps.log`).
- `ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0, `TEST BUILD SUCCEEDED`,
  `recovery-controls-app-build.log`.
- Shared bilingual string generation/check passes: 1088 keys, including 801 shared keys.
  Rust formatting and diff checks exit 0. `sh scripts/check-sdd.sh` exits 0 with
  0 errors/warnings (`recovery-controls-sdd.log`).

Native UI automation is not claimed: earlier in this request both the initial run and its
single allowed bootstrap retry failed before any assertion while enabling automation mode.
No further identical UI retry, actual Loader binding, reconcile, run or physical-device
operation was performed for this slice.

## CI

This revision is submitted for GitHub's selected checks and maintainer review. Results are
recorded in the PR and subsequent work without amending a green head. The independent
source/batch deployment PR #2466 (head `f987d8d01`) is fully green: Swift CI `37180001882`,
SDD `37180001740`. A green result does not approve or publish device execution.

## Remaining requested work

Audited archive requires its durable Runtime path and is a separate implementation slice.
TCP/UART recovery confirm/abort requires a published operation/profile; no identity proof
is inferred from a user click. The five real-device Golden Journeys remain excluded. The
retained legacy Session continuity blocker to the signed RC3 cutover remains unchanged.


## Main compatibility follow-up

Main `2d85d513d` merged the independent preview, deployment and Windows work.
The recovery branch preserves those changes. Its only textual conflicts were
`spec/ui-semantics/strings.json` and the three derived Windows resources: all
12 recovery-only keys were merged by key against the common baseline, and the
resources were regenerated. No recovery behavior or permission was changed.

### Local targeted checks

`python3 windows/scripts/generate-ui-strings.py --write` and `--check`: exit 0,
1,167 strings (879 shared with macOS) match. `npm test --prefix
docs/design/arkdeck-ds`: 84 passed, exit 0 (`recovery-merge-ds-final.log`). The
first attempt found the new isolated checkout lacked JS dependencies; an offline,
lockfile-based `npm ci --ignore-scripts` installed them before the passing run.
`cargo fmt --all --check --manifest-path rust/Cargo.toml`, `git diff --check` and
`sh scripts/check-sdd.sh`: exit 0 (`recovery-merge-sdd.log`, zero errors/warnings).
`run-swiftpm.sh test --filter 'RuntimeJobRecoveryApplicationFacadeTests|JobsLocalizationContractTests'`: 13 passed, exit 0 (`recovery-merge-swift.log`).
`ARKDECK_XCODE_JOBS=2 sh scripts/ci/run-xcodebuild.sh`: exit 0, TEST BUILD SUCCEEDED (`recovery-merge-app.log`). The recovery Rust guard is byte-equivalent to the previously tested implementation; main only adds its independently reviewed Windows composition around it. Native Windows validation remains in CI.

### CI

PR #2467's previous head was green; compatibility-head CI is pending. The
previous archive PR #2468 head `024511e9` passed Windows and macOS workspace,
Swift and App checks in run `37186647925`; both contract-parity lanes subsequently passed and run `37186647925` concluded success.


## Second current-main compatibility update

### CI

Head `545d4fdee` passed every selected check in Swift CI `37188933420`, including
all three platforms' workspace and contract parity lanes; the `swift` aggregate
and SDD `37188933147` passed. Main then advanced to `1f05dce05` with Windows remote
sources and HDC owner changes, producing a shared-string append conflict.

The merge retains all main changes and all 12 recovery resource keys by a
three-way merge keyed by resource identity, with an assertion against conflicting
values. The three Windows resource consumers are regenerated. The 29-line
`app_job_recovery_allowed` guard is byte-identical; no recovery behavior changes.

### Local targeted checks

- `CARGO_BUILD_JOBS=2 cargo test --manifest-path rust/Cargo.toml -p arkdeck-agentd --bin arkdeck-agentd app_ingress_tests::recovery_tests::`: 3 passed, exit 0, `recovery-main2-rust.log`.
- `python3 windows/scripts/generate-ui-strings.py --check`: 1,261 strings pass. `check-windows-resource-references.py` checks all 46 snapshots, 286 references and literal UI-test resource lookups: pass, exit 0, `recovery-main2-strings.log`. The initial generator invocation omitted its required `--write` mode and exited 2; the explicit write/check succeeded.
- No App, Swift package or prototype file changes from the already-verified head were introduced by this merge; their green checks above remain the relevant local evidence. Native Windows validation and the full combined diff are rechecked by fresh PR CI.

Logs remain under `/tmp/arkdeck-macos-closeout-20261004/`. The compatibility
commit is not an amendment of the green head; fresh CI and maintainer review are
required for its combined tree.
