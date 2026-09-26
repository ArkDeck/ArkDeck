# TASK-XPA-017 — the cutover preflight refuses two states the Rust Runtime would hold stuck (macOS, 2026-09-26)

Base: protected `main` `f9d6cac06` (#2252); developed on `9428277e3` (#2242). M5 cutover preflight
(`arkdeck-agentd --cutover-preflight [--hold-instance-lock]`, design §G.4,
[#2142's record](../TASK-XPA-018/runtime-service-cutover-preflight-run.md)), two
refusals the coordinator ruled on 2026-09-26 (the F7 re-ruling and the
failed-publication recognition ruling). Host evidence only: temporary homes
below `/private/tmp`, the real `arkdeck-agentd` binary with a cleared
environment; no installed service, `launchctl`, device, trusted fact,
capability, reservation or `~/Library/Application Support/ArkDeck` was touched.
No Catalog operation, contract input (`spec/**`, `control-protocol.json`,
ControlFrames, CLI argv corpus), schema, `tasks.md` or task status changes.

## What a caller sees

Two new `blocks[].kind` values of `arkdeck.cutover-preflight/1`, in both passes:

- `loaderTransitionAwaitingBinding` `{jobId, targetId, expectedBindingRevision}`:
  a parked DAYU200 Flash Job, never driven by an ArkForge lane, whose record and
  journal hold exactly the enter-Loader transition Swift's
  `flash.bind-current-loader` settles. `runtime service update|install` renders
  it as `Job <id> awaits a Loader binding of target <t> at binding revision <n>
  to settle its enter-Loader transition, which the Rust Runtime does not
  settle: settle it first on the old Swift Runtime with `arkdeck flash
  bind-loader --target <t> --expected-binding-revision <n>`
  (flash.bind-current-loader), then run the preflight again`. Every other
  parked Job is carried over as before.
- `retainedSessions` `{sessionsRoot, code, message}`: the first refusal of a
  device mutation's continuity proof of the retained Sessions, in that proof's
  own code and words — e.g. `recordUnreadable: Runtime mutation state
  continuity cannot be proved: retained Session 2026/09/session-<job> has no
  Manifest and no failed publication of this Runtime accounts for it; …`.
  Rendered as `the retained Sessions under <root> are refused as a device
  mutation's continuity proof refuses them: <code>: <message>`. Session storage
  settings that cannot be read add `unreadable` with `source: sessionStorage`.

Before this change the Rust CLI already parsed either kind (its `probe` checks
only `schemaVersion`, `clear`, `blocks[]` and `instanceLockHeld`) but rendered
an unknown kind as raw JSON (`kind: {…}`); the two arms render them as above.
The document has no published schema (none under `openspec/contracts/` or
`spec/`); its other reader, `check-rust-helpers.py`, checks only that an empty
home is clear and unwritten.

## Where the rules live (checked before any change)

- `spec/recovery/job-state-preflight.json` is read by Swift's
  `JobStatePreflightTableContractTests` (Job states, agent-execution states and
  capability-use outcomes are held to Swift's enums; the restart oracle and the
  byte-for-byte copy `rust/tests/fixtures/job-state-preflight/table.json` with
  its provenance digest are recorded there). Its `cutover.blockingWhen` is prose
  that neither implementation reads, and it enumerates no refusal kinds; the
  Rust table reader takes only `states`, `unlistedState`,
  `agentExecutionStates` and `capabilityUseOutcomes`. Neither new rule classes
  a Job state (one reads journal content, the other Session storage), so the
  table is unchanged: no contract slot, no Swift re-record. Its
  `cutover.blockingWhen` prose now lists fewer refusals than the daemon makes;
  syncing that prose is a separate contract-slot change if wanted.
- Rule 1 is a new `CutoverBlock::LoaderTransitionAwaitingBinding`, decided in
  `arkdeck_contract::cutover_preflight` (only for a Job whose class is parked)
  from a new `CutoverJob.loader_transition` fact that
  `arkdeck_hoststore::cutover_facts` reads. Rule 2 is a hoststore fact
  (`CutoverFacts.retained_sessions`) the daemon renders beside the pending tool
  selection, as that one is.

## Rule 1 — a Loader transition only Swift's Runtime settles

Swift's `flash.bind-current-loader` handler (`AgentDaemon.swift` 678–690) and its
start-up (`main.swift` 1342–1356) settle a Job with
`RuntimeJobEngine.settleLoaderTransitionAfterBinding` (6019) once
`loaderTransitionAwaitingBinding` (5989) finds it and `pendingLoaderTransition`
(6123) accepts its journal. This Runtime does not port the settlement (F7); its
bind refuses while such a Job waits (`loader_binding.rs`), so a Job carried
over would refuse that binding until a complete overwrite recovers it.

The rule refuses exactly the Jobs Swift would settle, for the Target and binding
revision their own request names — the coordinator's three conditions plus the
rest of Swift's predicate:

| Condition | Source |
| --- | --- |
| The request names `flash.full-restore@1`, `flash.dayu200` or `flash.dayu200@1` | `JobRecord::dayu200_flash` (Swift `isDayu200Flash`) |
| Parked (the most conservative of index row, record and journal) | `cutover_job_class`; the record's own state is `waitingForRecovery` |
| The record keeps its outcome unknown at an `enter-loader-mode` intent | `outcomeUnknown`, `recoveryStepID`, `recoveryIntentEventID` (Swift 5997–6000) |
| The journal is whole, waits for recovery, holds no unknown outcome and exactly one outstanding intent: that one, `enter-loader-mode`, attempt > 0, `deviceMutation`, at the binding revision the request expects | Swift 6142–6151 |
| No step intent in the journal was ever destructive | Swift 6152–6154 (`ReplayState::holds_destructive_step_intent`, new) |
| No ArkForge lane held it: no `jobs/<id>/arkforge-runtime-state.json` | with a lane, Swift delegates `enter-loader-mode` to the lane's plan and writes no intent for it (`RuntimeJobEngine.swift` 2490–2499; Rust `flash_run.rs` `OWNED_MODE`) |

The record-level filter is now one function, `job_owner::loader_transition_candidate`,
shared with the Rust bind's refusal (`loader_transitions_awaiting_binding`), so
the two cannot drift.

Narrower than "the journal's only unresolved device-mutation intent is
`enter-loader-mode`" on purpose: a Job outside Swift's predicate (another
outstanding intent of any effect, the transition's outcome recorded as unknown,
a destructive step before it, a torn tail, a record that does not keep the
outcome unknown or names another revision) is not settled by
`flash bind-loader` on Swift either — Swift refuses that bind as ambiguous or
binds without settling — exactly as this Runtime does. Carrying it over adds no
trap, and refusing it with the bind-loader hint would send the user round a
loop. The mutation that drops "exactly one outstanding intent" is caught by
the "another intent is outstanding" case below.

## Rule 2 — the retained Sessions' continuity proof, run before the cutover

The coordinator asked for `JobStore::require_retained_sessions` (#2242) to be
called directly. That method needs a `JobStore` over the old state, and every
constructor writes into it: `JobRepository::open_mode` creates
`.rust-job-owner.lock` (`O_CREAT|O_EXCL`), takes its exclusive `flock` and writes
the initialized mark into it (`mark_catalog_initialized`), and
`JobStore::open_with` creates `cli-job-snapshots/`; with no index the dedicated
placement refuses a state root that holds other owners' entries and the
state-root placement creates one. The preflight guarantees neither pass writes
or marks a lock document (#2142; its tests compare every entry below the home),
and the first pass runs beside the live Swift daemon.

So the preflight runs the same scan without an owner: the continuity proof's
`failed_publication` reads its three facts of the Job store — a Job's durable
record from its index row, its Journal, its Manifest proposal — through
`PublicationSource`, either the owner (`JobStore`, unchanged) or the state root
read without one (`Inspected`: the directory and the index opened through
`InspectedIndex`, the connection Swift's repository inspects with, which the
preflight's index read already used; `cutover_index_states` is now
`InspectedIndex::states`, and a row is decoded by the one `job_row` the owner's
reads use too). `check_sessions`, `inspect_named_children`,
`failed_publication` and the refusal texts are the same code for both.
`require_retained_sessions` itself now calls the shared `retained_sessions`.
The mutation that opens a `JobStore` over the old state before the scan shows
the cost: `Agentd/.rust-job-owner.lock` (one byte, the initialized mark) and
`Agentd/cli-job-snapshots/` appear, and #2142's unchanged-state tests fail.

Session roots: the default `ArkDeck/Sessions`, then the one the storage
settings (`Agentd/session-storage.json`) select, in the order the proof reads
them (`MutationAuthority::require_state` → `require_mutation_state`'s
`BTreeSet`); the settings are read as `StorageHold::configured_root` reads them
(shared `configured_root_in`), without the storage lock.

Lock environment (the coordinator's question):

- No `JobStore` exists, so its `activity` mutex is never taken; no store
  owner's file lock is taken either.
- First pass: no lock at all. Beside a running Swift daemon, a Session that
  daemon is publishing in place at that instant can read as one a publication
  left short, and be named; such a refusal changes nothing and the pass can be
  run again.
- Held pass: only `Agentd/instance.lock`, which the process takes before the
  snapshot; the scan reads files and the index and waits on nothing.

## Tests

- `arkdeck-contract` `a_parked_loader_transition_only_swift_settles_refuses_the_cutover`:
  parked with the fact → the block (whichever source parks it); its owning
  execution still carried; another parked Job carried; blocking or terminal
  class → only the table's blocks.
- `arkdeck-hoststore` `tests/failed_publication_recognition.rs`: every case of
  #2242's test (the failed publication's Session as left, stopped mid-copy,
  stopped before the Journal; seven unaccounted variants; a published Session cut
  back) now also asserts that the owner-free scan
  (`cutover_retained_sessions`) answers exactly as `require_retained_sessions`
  and `require_mutation_state` do.
- `arkdeck-agentd` `tests/cutover_preflight.rs` (real daemon, temporary homes):
  - `a_parked_flash_only_swift_can_settle_at_its_loader_transition_refuses_the_cutover`:
    the Rockchip start-up oracle's engine-driven Flash, its journal cut at the
    `enter-loader-mode` intent and parked, for each of the three spellings →
    both passes refuse with exactly the block; the parked screen-sequence lane
    is still carried; nothing below the home changed.
  - `a_parked_flash_swift_would_not_settle_is_carried_over_as_every_parked_job_is`:
    ten cases carried (clear) — lane sidecar present; another outstanding
    intent (reading the device); another outstanding device mutation; the
    transition's outcome recorded as unknown; a destructive step before it; a
    torn tail; the record not keeping the outcome unknown; another expected
    binding revision; not a Flash; the record parked at another step — each
    journal checked to replay and wait for recovery, each record to decode, so
    none is carried for being unreadable; and the same Job with a blocking index
    row → only `jobState` and `unresolvedJournal`.
  - `a_retained_session_the_continuity_proof_refuses_refuses_the_cutover_in_its_own_words`:
    identity-only Session → both passes refuse with the code and message
    `JobStore::require_mutation_state` answers over the same state, nothing
    changed; the same Session with a clean Journal → clear (and the proof
    passes); a failed publication's Session (Swift-recorded
    `job-publication-current/failed` record, its index row and Journal) → clear,
    `failed_publication_accounts_for` true, both passes, nothing changed.
  - `the_session_root_the_settings_select_is_proved_too`: a custom root selected
    by the settings holding an identity-only Session → refused with the proof's
    answer over that root; unreadable settings → `unreadable`/`sessionStorage`
    and the default root still proved.
- `arkdeck-cli` `tests/runtime_service.rs`
  `a_cutover_names_what_only_the_swift_runtime_can_settle`: a first pass
  answering both kinds → exit 75 with both rendered, nothing changed, no
  launchd call but `print`.

Mutations (each applied alone, the named tests re-run, then reverted):

| Mutation | Caught by |
| --- | --- |
| Rule 1 takes the `enter-loader-mode` intent among others (no "exactly one outstanding intent") | `…would_not_settle…`: "another intent is outstanding, reading the device" is refused |
| Rule 1 ignores the ArkForge lane | `…would_not_settle…`: "its ArkForge lane holds the transition" is refused |
| Rule 1 ignores a destructive step in the journal | `…would_not_settle…`: "a destructive step ran before it" is refused |
| Rule 1 for a Job of any class (contract) | `a_parked_loader_transition_only_swift_settles_refuses_the_cutover`: a running Job also gets the Loader block |
| The retained Sessions not scanned | both rule-2 tests: the passes are clear |
| The scan through an owner of the old Job store (`JobStore::open(state)` first) | `a_state_with_nothing_in_flight…`, `a_swift_state_root_is_refused…` and the rule-1 test: the preflight created `Agentd/.rust-job-owner.lock` (1 byte, the initialized mark, 0600) and `Agentd/cli-job-snapshots/` (0700) |

Each source was restored by digest afterwards (`shasum -a 256 -c`: OK).

## Local targeted checks

Worktree `/private/tmp/arkdeck-s22-lane`, target `/private/tmp/arkdeck-1330-rust-target`,
`CARGO_BUILD_JOBS=2`, none started before 09:05 (the host's quiet window); logs
`/private/tmp/arkdeck-s36-logs/` (first round, on `9428277e3`) and
`/private/tmp/arkdeck-s36-logs/rebased/` (after rebasing onto `8bddca654`, #2249,
whose nine new commits touch `job_owner.rs`, `session_owner.rs`, `lib.rs` and
`rust/README.md` away from these changes; everything below ran again there):

- `cargo fmt --all --check`: exit 0.
- `cargo clippy --all-targets -- -D warnings` for `arkdeck-contract`,
  `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-cli` and the direct dependents
  of the first two (`arkdeck-bootstrap`, `-client`, `-control`,
  `-provider-arkforge`, `-provider-hdc`, `-soak`): exit 0; the four changed
  crates for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`: exit 0
  each. (The first run found one `cloned_ref_to_slice_refs` in the new test,
  fixed.)
- `cargo test --no-fail-fast -p <crate>` after `cargo build -p arkdeck-cli -p
  arkdeck-agentd`, exit 0 each: `arkdeck-contract` 60 passed;
  `arkdeck-agentd` 191; `arkdeck-cli` 406; `arkdeck-hoststore` 664 passed and
  18 ignored (first round: 60, 186, 401, 656 and 18). Targeted first:
  `cutover_preflight` 13 (the 9 before and 4 new), `failed_publication_recognition`,
  `loader_binding_jobs`, `rockchip_startup`, `pointer_input_run`, the CLI's
  `runtime_service` 42. Two of the new tests were corrected in their setup
  before passing: the owner's first read is made before the state is measured
  (it leaves the index's log and shared memory, as a Swift daemon's do, which
  the inspection connection would otherwise leave on the first pass, #2142's
  documented effect), and the failed publication's Job gets the succeeded
  capture's Journal with only `jobId`/`sessionId` renamed (renaming inside the
  step arguments broke their `argumentsHash`).
- The six mutations above, on the first-round tree.
- `rust/scripts/check-readonly.py --bin-dir <target>/debug`: exit 0, PASS.
- `sh scripts/check-sdd.sh` (validation venv): exit 0, 0 errors, 0 warnings.
- No stand-in, daemon or temporary home left behind (`/private/tmp/acp-*`
  none); the installed service, `launchctl`, devices and the account's
  `Application Support` were not touched.
- Rebased once more onto `f9d6cac06` (#2252; its two commits touch only
  `arkdeck-provider-arkforge`, its run records and one script): `cargo fmt
  --all --check`, clippy of the four changed crates (host), `cutover_preflight`
  (13) and the two hoststore tests above, exit 0 each
  (`/private/tmp/arkdeck-s36-logs/rebased2/`).
- Not run: `generate-contract.py --check` (no contract input changed), Swift
  (no Swift change; the Swift test that reads the shared table sees it
  unchanged), App builds.

## Remaining

- `spec/recovery/job-state-preflight.json`'s `cutover.blockingWhen` prose does
  not list the two refusals; syncing it is a contract-slot change (Swift's
  table test re-records the copy and its provenance digest).
- There is no cutover runbook file yet; the operator step for
  `loaderTransitionAwaitingBinding` (the board attached in Loader, `arkdeck
  flash bind-loader --target <t> --expected-binding-revision <n>` on the old
  Swift Runtime, then the preflight again) is in the CLI's refusal and here, and
  belongs in the 20c cutover record.
- The settings read takes `rootPath` as `StorageHold::configured_root` does;
  the storage status's own checks (a canonical path, a default kind naming the
  default root) are not repeated, so settings that fail only those still let
  the preflight pass while the Rust Runtime's admission would refuse on its
  status read.

## CI

Pending (PR not yet opened when this record was written).
