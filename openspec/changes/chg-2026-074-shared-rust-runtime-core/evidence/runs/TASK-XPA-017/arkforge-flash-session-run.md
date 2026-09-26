# The ArkForge lane's Flash session: one correlated job driven as Swift drives it (TASK-XPA-017, F6 S3)

This slice ports Swift's `ArkForgeFlashSession` to `arkdeck-provider-arkforge`.
It is the loop that drives one daemon job that was already correlated with an
ArkDeck Job before any permit was signed:

- it polls the job's events;
- it answers admissions through the execution authority (S1);
- it answers control requests through a performer and the managed-control
  port (S2).

It decides nothing itself. Completion is stated only by the daemon's
`outcomeClassified`, and silence is never an answer. The lane host (S4) will
drive it. The ArkForge pin stays at `eee5787`: the controller calls used here
exist there.

Developed stacked on S1 (branch head `a5c2486a5`), which was stacked on S2
(#2251). Rebased onto `20130b631`: S1 merged as #2252 (`f9d6cac06`) with the
same content for this crate, and #2254 changes none of this slice's files.
After the rebase, the checks below marked "after the rebase" were run again.
No contract input, Catalog or `tasks.md` changes. No device, and nothing here
is device evidence.

## What is ported (`flash_session.rs`)

### The daemon and the performer

- **`SessionDaemon`** is Swift's `Daemon`, narrowed to the calls a correlated
  job's drive makes: a poll of the job's events, the permit and control
  receipt submissions, and the cancel.
- **ArkForge's `ControllerClient` implements it directly.** A drift between
  the two is therefore a compile error, as Swift's empty conformance intends.
  A client error reads as `<code>: <message>`. Swift's client also names the
  API and status, which ArkForge's Rust error does not carry.
- **`ControlPerformer`** is Swift's: it takes the whole request, since a read
  names the fact it needs confirmed.

### `run_existing` (Swift `runExisting(jobID:)`)

1. The daemon's job is adopted into the authority. No job is ever started, so
   recovering the controller cannot create a replacement destructive attempt.
2. Each poll reads the job's events after the last sequence answered, in
   order, and stops at a terminal classification. Another job's event, and one
   at or below the cursor, is skipped.
3. Admissions are answered first, then control requests, each in event order.
4. A signed permit whose receipt has not arrived is owed evidence.
5. A quiet poll waits 500 ms. After 4200 consecutive quiet polls the outcome
   is unknown: `arkforged produced no explicit terminal outcome for 2100s`,
   followed by ` while a signed permit still owed evidence` when one is owed.

### Admissions

- **A signed permit** goes to the daemon under the admission's request id.
- **A daemon rejection** is recorded, then:
  - `SNAPSHOT_EXPIRED`, the rejection that heals itself, is not fatal;
  - any other rejection stops the drive: `arkforged rejected the permit for
    <step>: <code> <message>`.
- **A refusal is sent, not withheld.** It is recorded as
  `<step>: <reason>`.

### Control requests

- **A performer failure** travels as an unaccepted observation:
  `control action did not complete: <error>`.
- **A receipt the port refuses to build** is never sent. The drive stops with
  the port's words.
- **A rejected receipt** is answered with Swift's cancel, and the drive stops
  in Swift's words. Swift's `cancelJob(jobID:)` names no journal sequence. The
  cancel here is `cancel(job, 0)`, which ArkForge's encoder writes as exactly
  that request, since it omits a zero field (`wire::write_uint64`). At the pin
  the daemon refuses it: `cancel_job` requires field 2 and answers
  `EXPECTED_SEQUENCE_REQUIRED` (`crates/arkforged/src/service.rs` 1536-1545).
  As Swift's `try?` does, the refusal is ignored, so the daemon's job waits
  for its request's deadline, as it did on the GJ-4 bench. The coordinating
  session ruled this on 2026-09-26: a port does not change this path's
  observable result. Whether a cancel should take effect here is a separate
  decision for the maintainer (F3).
- **An accepted observation** that the daemon took extends the authority's
  mode lineage.

### `observe_terminal` (Swift `observeTerminal(daemon:jobID:)`)

- One poll from the start, for this job only.
- It never admits, performs or cancels anything.
- A later classification supersedes an earlier `outcomeUnknown`.
- `None` means there is no classification.

### The terminal table

- `succeeded` completes.
- `confirmedFailed` fails.
- `outcomeUnknown` and `recoveryAssessable` are unknown.
- `cancelledSafe` is a safe cancellation.
- No outcome fact, or any other value, is unknown, in Swift's words.
- The detail is the first `reason` fact, else every other fact as
  `key=value`.

### Declared differences

- **An event kind or control action this build does not know** fails to
  decode in ArkForge's Rust client, so the whole poll is an error and the drive
  stops. Swift skips an unknown event kind. Only a newer daemon can send one.
- **Swift's test-only `run` and `cancel` have no counterpart.** Production
  starts a job through the lane host and drives it only through
  `runExisting`.

## Tests (`flash_session/tests.rs`)

The scripted daemon polls as Swift's `ScriptedDaemon` does:

- every poll returns the whole script;
- a script without a terminal answer ends in `succeeded` once the session has
  read all of it;
- a staged event is published only after a control receipt was taken.

Swift's loop cases, adapted to start from a correlated job:

- a matching admission is signed;
- the correlated job is driven to its own completion;
- passive observation touches nothing, and a later classification supersedes
  an earlier one;
- an empty poll between a receipt and the next admission is not completion
  (the gap seen after DEVICE_RESET);
- a refusal is sent;
- a control request's observation is relayed, and a failed one is not
  "nothing happened";
- a rejected permit stops the drive, while `SNAPSHOT_EXPIRED` does not;
- a rejected receipt cancels the job and stops the drive;
- the daemon's unknown and failed classifications carry its reason, and an
  unknown wire value fails closed;
- the receipt shape is carried through unchanged.

Beyond Swift:

- an accepted control observation admits the Loader admission that follows,
  and without it the same admission is refused;
- a receipt the port refuses is not sent;
- the whole terminal table;
- the quiet bound, with and without a permit owed, in 4200 waits;
- quiet polls count only while consecutive;
- admissions are answered before controls within a poll;
- another job's events and answered ones are skipped;
- a daemon error stops the drive in its own words.

## Mutations

`s3-mutations.py` applied each mutation to the tree, ran the session's tests,
restored the source and checked it against its digest. The restored tree
exited 0.

| mutation | caught by |
|---|---|
| an answered event read again | six cases, including the skip and order cases |
| another job's event answered | the skip case |
| controls answered before admissions | the order case |
| silence counted across events | the consecutive-quiet case |
| `SNAPSHOT_EXPIRED` made fatal | the snapshot-expired case |
| a refusal withheld | the refusal case |
| a rejected receipt not answered with Swift's cancel | the rejected-receipt case |
| a cancel that names a sequence, which would take effect | the rejected-receipt case |
| an accepted observation not recorded | the Loader-admission case |
| `confirmedFailed` completing | the confirmed-failure case and the table |
| the owed permit not named | the quiet-bound case |

## Verification

**Local targeted checks.** Main worktree, target
`/private/tmp/arkdeck-m4-rust-target` (`-win` and `-linux` for the cross
checks), `CARGO_BUILD_JOBS=2`. Logs are under the session's scratchpad
`s3-logs/`.

| check | result |
|---|---|
| `cargo fmt --all --check` | exit 0 |
| `cargo clippy --all-targets -- -D warnings`, host: `arkdeck-provider-arkforge` and its dependents `-hoststore`, `-agentd`, `-cli`, `-soak` | exit 0 (`r2-clippy.log`). The first run refused a test's `% 2 == 0` in favour of `is_multiple_of`, which was changed. |
| the same for Windows and Linux: `arkdeck-provider-arkforge` | exit 0 each (`r2-clippy-*.log`) |
| `cargo test -p arkdeck-provider-arkforge` | exit 0: 74 unit tests (23 new), the lane, device access and permit vector binaries (`r2-test.log`) |
| `rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv), after `cargo build -p arkdeck-cli -p arkdeck-agentd` | exit 0 |
| `cargo deny --locked check`, `cargo vet --locked --no-registry-suggestions` | exit 0 each |
| the eleven mutations | each caught as above; the restored tree exit 0 (`mutations.log`) |
| `sh scripts/check-sdd.sh` | exit 0 |
| after the rebase: fmt; clippy `arkdeck-provider-arkforge`, `-hoststore`, `-agentd`, `-cli`, `-soak`; `cargo test -p arkdeck-provider-arkforge`; check-sdd | exit 0 each; the same 74 unit tests (`rebased-*.log`) |

Not run:

- Tests of the dependents: nothing of theirs changed or calls the new
  module. Their clippy above compiles them.
- Swift: nothing of it changed.
- `generate-contract.py --check`: no contract input changed.
- A real `arkforged`: the session is driven over a scripted daemon.
  ArkForge's own client is its production daemon, and that is checked at
  compile time.

**CI.** Pending.

The CI of #2252 (S1) was green before it merged as `f9d6cac06`.
