# DEC-016 complete-overwrite recovery of a Flash on the Rust Runtime, the epoch fields widened from Swift's witness frames (TASK-XPA-017, M4-F5)

The Swift Flash run oracle (`rust/tests/fixtures/flash-run`) records two
DEC-016 stories that the previous change left unreplayed: `recovery`, the
canonical operation asked for the complete overwrite after an unknown Flash,
and `recoveryAlias`, the compatibility alias asked for it. This change serves
both on the Rust Runtime byte for byte. With it all eight stories replay.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The oracle (#2223); a Flash admitted, run, parked and reconciled (#2231) | DEC-016 admission, the distinct recovery run and its superseding epoch; the epoch in every read that names it; seven method schemas widened from Swift witness frames; the recovery story's `job.show` and `job.list` reads | The production lane and the Rockchip host (F6, waiting for the ArkForge client change); the CLI's `flash install-binding` (F8b) |

The production daemon still composes no lane and admits no Flash
(`FlashAdmitter { executes: false }`). Nothing here reaches a device,
`arkforged` or an installed service; the replay composes the lane's fakes.

## DEC-016 as Swift decides it

`flash_recovery.rs` ports Swift's `completeOverwriteAdmission`,
`establishSupersedingRecoveryEpoch` and `recoveryEpochIndexes` over the Job
owner's state root:

- An unresolved destructive intent on a Target binding blocks every later
  Flash of that binding but its complete overwrite. It is an outstanding or
  unknown `flash-partitions` intent in a Job's journal, or a destructive
  capability use whose outcome is not settled and that no journal names.
- A complete, verified later recovery Flash already in history is recognized:
  its epoch is appended and nothing is dispatched. Recognition needs the
  recovery's provider executable digest, so only a later recovery can be
  recognized.
- Otherwise only a distinct recovery may be admitted: the exact reviewed
  operation and profile (`dayu200`), every covered partition and full
  verification. Anything less is refused as Swift refuses it: incomplete
  requested coverage, or an unbounded or unsupported effect.
- Every recovery counts against the shared budget: four hours, or an
  operator-named hardware acceptance campaign, and sixteen epochs.
- The recovery's admission evidence keeps its context: the covered intents,
  the uncertain and covered effect sets, the coverage contract and the
  destructive epoch ordinal. Its capability is its own: the Runtime issues it
  under the recovery policy's fingerprint, one use for the exact plan.
- The run consumes that capability, then enters `recoveringByCompleteOverwrite`
  ("distinct complete-overwrite capability reserved; original intents not
  replayed"). A recovery that confirms its write and every verification step
  establishes the epoch that covers the unknown intents, and ends
  `recovered`. The covered Jobs' own outcomes stay unknown; they are never
  replayed.
- Swift's one crash window: the epoch is durable and `finalizing -> recovered`
  is not. At restart the recovery completes journal-only against its durable
  epoch, with nothing dispatched.

The reads name the epoch as Swift names it:

- `job.status`, `job.show` and `job.list` (with `current` too): the recovery
  Job's `recoveryEpochId`, and each covered Job's `supersededByRecoveryEpochId`.
- `job.evidence` and `job.result`: the epoch that names the Job as its
  recovery Job, as `recoveryEpoch`, both in the evidence and in its
  authority. Before this change the Rust evidence degraded such a Job to
  `recordUnreadable`, since the published schema pinned the field to `null`.
- `job.reconcile` answers every status without the epoch, on both sides.
  Swift's reconcile returns `status(of:)`, whose epoch parameters default to
  `nil`; only `status(jobID:)` and `jobReadSnapshot` read the indexes
  (`RuntimeJobEngine.swift` 5319, 5234). This Runtime's reconcile answers
  `JobRecord::status()` (`job_record.rs`), which carries both as `null`.

## Safety conditions and their tests

| Condition | Test |
| --- | --- |
| After an unknown Flash, a request short of a complete overwrite is refused before issuance: nothing issued, admitted or dispatched | `a_flash_after_an_unknown_one_is_admitted_only_as_its_complete_overwrite`; `recovery`'s `basic.submit` |
| The unknown intent is never replayed: the recovery is a distinct Job with its own capability, and the covered outcomes stay unknown | `a_complete_overwrite_supersedes_an_unknown_flash_as_swifts` (the covered Job's journal and status, byte for byte) |
| The recovery's capability is the Runtime's own, one use, bound to the exact plan | `recovery`'s `capabilities.admitted` and `capabilities` reads |
| A restart inside the epoch's crash window completes the recovery journal-only and dispatches nothing | `a_recovery_interrupted_after_its_epoch_completes_at_restart` |
| The alias is admitted as the same recovery | `the_alias_recovers_an_unknown_canonical_flash_as_swifts` |

## The contract

Seven schemas published a recovery's fields as `null`, or refused a
refusal without details. Each is widened only as far as a Swift witness
frame shows (the frames `FlashRunOracleContractTests` sends with
`ARKDECK_CONTROL_FRAME_LOG` set):

| Method | Witnesses | Widened |
| --- | --- | --- |
| `job.status` | 3 | `recoveryEpochId`, `supersededByRecoveryEpochId`: `null` to string or `null` |
| `job.run` | 2 | `recoveryEpochId` |
| `job.result` | 1 | `job.recoveryEpochId`; `evidence.recoveryEpoch` and `evidence.authority.recoveryEpoch`: `null` to the epoch object or `null` |
| `job.evidence` | 1 | `recoveryEpoch`, `authority.recoveryEpoch` |
| `job.submit` | 1 | `errorDetails` no longer requires `phase` and `newDispatchCount`: Swift's handler answers a post-admission internal failure (here the alias's short partition plan) with empty details |
| `job.list` | 2 | `items[].recoveryEpochId`, `items[].supersededByRecoveryEpochId` |
| `job.show` | 2 | `job.recoveryEpochId`, `job.supersededByRecoveryEpochId` |

How:

- A witness is a recorded frame the committed schema refuses. The corpus
  keeps every line and appends the 12 witnesses verbatim.
- Each schema is the generator's own derivation over its final corpus
  (`generate-control-contract.py`'s `derive_method_schemas` into scratch). Its
  error codes are kept as a union with the committed ones: `job.submit`
  publishes `inputTooLarge`, whose frame exceeds the corpus's 64 KiB sample
  limit, so a corpus-only derivation would have dropped it.
- Each committed corpus reproduces its committed `$defs`, but for that one
  code. Every recorded frame of the seven methods validates against the
  widened schemas (jsonschema 4.26; `ControlMethodSchemaContractTests` over
  the recorded frames). The diff is exactly the table above.
- `spec/baselines/swift-single-v1.json` is regenerated: 1027 to 1039 recorded
  shapes. The contract identity and the generated bindings are unchanged.
- `flash.bind-current-loader`'s `settledJobId` stays pinned to `null` (F7,
  below).

The Control passes each recorded witness as the Job owner answered it,
never rewritten as `internalError`
(`read_only.rs` `every_recorded_recovery_epoch_answer_reaches_the_caller_as_the_job_owner_answered_it`).
In check-contracts' published view the merge base's corpus holds none of
them, and the test holds there too.

## The oracle

The `recovery` story gains four reads once the epoch stands: `job.show` of
the covered Job and of the recovery, then `job.list` with and without
`includeCurrent`. The Job list pager writes a snapshot under a random
revision on every page (`store/cli-job-snapshots/snapshot-<uuid>.json`), which
the oracle labels as it labels the Artifact pager's. The other seven stories
are unchanged; the re-recording compared equal to them.

The CLI lane's evidence oracle (`CLIDomainExecutorEvidenceOracleContractTests`,
`rust/tests/fixtures/domain-executor-evidence`) makes every recorded
`job.evidence` answer one of its cases, so the witness appended here is its
new `recorded21`: the recovery's evidence, which Swift's client-side
executor decodes to trusted facts. It is re-recorded; its other 74 cases are
unchanged, and the Rust CLI's replay (`domain_executor.rs`) replays the new
one as Swift decodes it.

## The replay

All eight stories, 122 exchanges, replay byte for byte: every answer, both
call logs, the Job index, the tree and every file.

| Story | Exchanges |
| --- | --- |
| `admission` | 11 |
| `canonical` | 19 |
| `alias` | 7 |
| `failures` | 33 |
| `reconcile` | 21 |
| `recovery` | 17 |
| `recoveryAlias` | 6 |
| `cancel` | 8 |

This Runtime keeps both pagers' snapshots below the Job root; the replay
checks it kept as many as Swift's two pagers together.

A Flash record's timeline measures how long its run waited for the lane's
prewarm (`consume wait <ms> ms`), which the oracle labels. The Job index's
`recordSHA256` hashes the record as stored, so under load a row differed
(reproduced on the third of ten runs beside six busy loops). The replay now
holds such a row to Swift's digest by the wait that reproduces it, every
other byte unchanged; ten runs under the same load passed. #2231 carries the
same fix.

## Declared differences

- **The same ordinary request after the epoch** is refused (`lineageBlocked`),
  as Swift refuses it: the ordinary policy's last generation still holds the
  unknown use. Reported for the maintainer's ruling; recorded as Swift answers
  it.
- **A resident Job in `recoveringByCompleteOverwrite`**: Swift's `job.run`
  continues it; this Runtime refuses and dispatches nothing (fail closed).
  After a restart both park it in `waitingForRecovery`.
- **Agent evidence** (`agent.run`, `agent.status`) keeps `recoveryEpoch` as
  `null`: no witness frame shows those results for a recovery Job, and their
  schemas pin it.
- **F7, the Loader binding settlement, is not ported** (the coordinating
  session's ruling of 2026-09-26). No current Swift engine creates a Job it
  would settle: with a lane, `enter-loader-mode` is the lane's own plan; without
  one, planning refuses at `flash-partitions`. Only a Job the engine left
  before the ArkForge lane can await it. This Runtime names such a Job at
  start, keeps its outcome unknown, and refuses `flash.bind-current-loader`
  before writing anything while it waits. Today's cutover preflight carries
  a parked Job over whatever it awaits (`job_state_preflight.rs`
  `cutover_job_class`); lane A adds a mechanical refusal of a parked DAYU200
  Flash whose only outstanding intent is `enter-loader-mode` (PR pending).
  - **For the operator**: if the cutover preflight refuses because of such a
    Job, settle it on the old Swift Runtime with `arkdeck flash bind-loader`
    (`flash.bind-current-loader`), then run the preflight again.
- **Incidental files**: as the oracle's change declares them.

## Tests

| Test | What it holds |
| --- | --- |
| `flash_run.rs` `a_complete_overwrite_supersedes_an_unknown_flash_as_swifts`, `the_alias_recovers_an_unknown_canonical_flash_as_swifts` | The two DEC-016 stories byte for byte |
| `flash_run.rs` `a_recovery_interrupted_after_its_epoch_completes_at_restart` | Swift's crash window, completed journal-only |
| `flash_run.rs` `a_flash_after_an_unknown_one_is_admitted_only_as_its_complete_overwrite` | The lineage after an unknown Flash |
| `read_only.rs` (control) `every_recorded_recovery_epoch_answer_reaches_the_caller_as_the_job_owner_answered_it` | The widened answers pass the Control unchanged |
| `recovery_epoch.rs` (unit) | The Job store reads which epoch names a Job as its recovery |
| `ControlMethodSchemaContractTests` (Swift) | The corpus and every recorded frame against the widened schemas |

Mutation check, baseline passing, each restored and its digest checked
after (`/private/tmp/arkdeck-m4-f5-mutations.log`):

- the evidence's epoch projected as `null`: both DEC-016 replays and the
  crash window fail;
- `job.show` without the epoch indexes: the same two fail;
- a basic-verification request admitted as a recovery: the two replays and
  `a_flash_after_an_unknown_one_is_admitted_only_as_its_complete_overwrite`
  fail;
- `job.status`'s `recoveryEpochId` narrowed back to `null`: the Control test
  fails.

## Local targeted checks

On `main` `76dcad2e9` (#2231 merged as `562a04441`),
`CARGO_TARGET_DIR=/private/tmp/arkdeck-m4-rust-target CARGO_BUILD_JOBS=2
CARGO_INCREMENTAL=0`, logs `/private/tmp/arkdeck-m4-f5-*.log`:

| Check | Result |
| --- | --- |
| Swift: `ARKDECK_RUST_FLASH_RUN_RECORD=<fresh> ARKDECK_CONTROL_FRAME_LOG=<fresh> run-swiftpm.sh test --filter FlashRunOracleContractTests`, then the same without either variable | exit 0, exit 0 (`…-swift-record.log`, `…-swift-compare.log`) |
| Swift: `run-swiftpm.sh test --filter ControlMethodSchemaContractTests`, then with the recorded frames as `ARKDECK_CONTROL_FRAME_LOG` | 5 tests (1 skipped), then 5 tests: exit 0 each |
| `generate-contract.py --write`, `--check`; `generate-control-contract.py --check`; `refresh-contract-digests.py --check` (validation venv) | exit 0 each; 1039 recorded shapes |
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -D warnings` for `arkdeck-contract`, `-control`, `-hoststore`, `-agentd`, `-soak`, `-cli`, `-provider-arkforge`: macOS, `x86_64-pc-windows-msvc`, `x86_64-unknown-linux-gnu` (their own target directories) | exit 0 each |
| `cargo test` for each of those seven crates (after `cargo build -p arkdeck-cli`) | exit 0 each (hoststore 88 test binaries, agentd 21, cli 61) |
| The replay under load: `flash_run` ten times beside six busy loops | 10/10 |
| `sh scripts/check-sdd.sh` | exit 0 |

Rebased onto `main` `a66520ca6` (#2234 and #2240, the Session proof's journal
replay and cache): `generate-contract.py --check` (1039 shapes), `cargo fmt
--check`, `cargo clippy` for hoststore, agentd and control, `cargo test -p
arkdeck-hoststore` and the Control's `read_only`: exit 0 each
(`/private/tmp/arkdeck-m4-f5-r2-*.log`).

The first CI run (`swift-tests`) found the CLI lane's evidence oracle out of
date, its cases shifted by the appended witness. Re-recorded:
`ARKDECK_RUST_DOMAIN_EXECUTOR_EVIDENCE_RECORD=<fresh> run-swiftpm.sh test
--filter CLIDomainExecutorEvidenceOracleContractTests`, then without the
variable, then the five oracles that read these corpora or schemas together
(`CLIDomainExecutorOracle`, `CLIDiagnosticsInspectOracle`,
`CLIDomainExecutorEvidenceOracle`, `ControlMethodSchema`, `FlashRunOracle`):
exit 0 each (`/private/tmp/arkdeck-m4-f5-ev-*.log`). `cargo test -p
arkdeck-cli --test domain_executor`: 2 passed
(`/private/tmp/arkdeck-m4-f5fix-domain-executor.log`).

## CI

- #2243, first run 36203617314: `swift-tests` failed on the evidence oracle
  above; fixed in this head.

Host-process evidence only: the ArkForge lane and the Rockchip host are
scripted, no `arkforged` runs, no device was used and no installed service
was touched.
