# Rust Job index and record writers — macOS, 2026-09-14

TASK-XPA-014 remains in progress. Base: protected main `25467d32` (the slice was written on
`dfdb6b68` and rebased onto #1889). This slice gives the Rust Job owner the two durable writers
Swift admission uses beside the journal: the SQLite `runtime_job` admission index and the Job-local
`job-record.json`. No daemon, RPC or CLI path writes Jobs yet; no admission order, plan, capability,
recovery or execution is added, and nothing installed changes. Every record is synthetic host data;
nothing here is device evidence.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining for TASK-XPA-014 |
| --- | --- | --- |
| Rust reads the v1 SQLite Job index, stored records, `job.events` and Artifact routing (#1863, #1879) and writes current journals under the Swift replay discipline (#1889) | `JobStore::open_owner`, `lookup`, `admit` and `persist`; the owner connection of the v1 index; `JobRecord::durable_bytes` over a Foundation pretty encoder; a Swift-recorded oracle the Rust owner reproduces, and a Rust-written store Swift reads | admission in the published order, `job.plan` digest parity, the admission sequence across index, journal and record with its crash windows, capability mint/reserve/consume, agent execution, executor hand-off, §G.4 preflight, recovery (after the L.1 item 13 ruling), GJ-1..5 |

## Behaviour

`JobStore::open_owner` opens a state root for the Rust Job owner only; a paired Swift daemon keeps
its own owner, and the exclusive `.rust-job-owner.lock` still refuses a second owner or reader. Every
write holds the store's activity guard, which the Session census requires of any Job writer.

`JobRepository` (`arkdeck-hoststore/src/job_repository.rs`):

- Connection choice, as Swift `RuntimeJobRepository.init`: when `runtime-jobs.sqlite3-shm` exists the
  store is first inspected through a read-only connection, so refusing a future layout never
  checkpoints a pending log; without it there is no pending log, and a write connection opens and
  closes without a checkpoint. A `-wal` or rollback `-journal` with content but no `-shm` is refused
  (Swift would replay it). The Rust reader follows the same rule; before this slice it always opened
  read-only, which fails on a WAL store whose `-shm` is gone (see below).
- The owner then rechecks the layout and every row's ordering and sequence under `BEGIN IMMEDIATE`
  and sets `journal_mode=WAL` and `synchronous=FULL`, as Swift `configure`.
- `lookup` and `admit` are Swift `lookup` and `admit`: an indexed idempotency key answers with its Job
  for the same request hash and with a conflict otherwise; a new key inserts the Job at
  `MAX(admission_sequence) + 1`, version 1, with the creation-time order key, `updated_at_utc` equal
  to the creation time and the exact initial record bytes, in one `IMMEDIATE` transaction.
- `update` is Swift `updateJobState` (state, update time, `version + 1`, record bytes) inside one
  transaction on the row the record describes.
- The table and index statements are Swift's text byte for byte, so `sqlite_schema` of a store Rust
  creates reads as Swift's; layout checks still compare normalized text.

`JobStore::persist` is Swift `persistRuntimeRecord`: it publishes `jobs/<jobID>/job-record.json`
atomically (private temporary file, full sync, rename, directory sync) and then advances the index
row with the same bytes.

`JobRecord::durable_bytes` writes Swift `RuntimeJobRecord.durableData()`: Foundation `JSONEncoder`
with `[.sortedKeys, .prettyPrinted]` — two-space indentation, `" : "`, an empty container as its open
bracket, a blank line and its close, `\/`, lowercase `\u00xx` controls, raw DEL and U+2028, keys in
UTF-8 byte order, Foundation float spelling and no trailing newline, as a Swift probe on this host
printed them. The bytes must decode back to the same record before anything is written.

Deliberate differences from Swift, all toward refusal:

- Before writing, the request hash must be a SHA-256 digest and the record must decode through the
  strict reader, since Rust readers refuse anything else.
- `persist` first checks that the index row describes this Job (idempotency key and creation time):
  an unknown or mismatched Job leaves no directory or file, where Swift writes the file and then fails
  the update. Once the file is published, an index failure is reported as an uncertain outcome.
- A content-bearing `-wal` or `-journal` without `-shm` is refused.
- The SQLite busy timeout stays 0, the Rust store's nonblocking policy, instead of 5 s.
- An interrupted publication leaves `.job-record.json.<nonce>.part` rather than Swift's
  `.job-record.json.<UUID>.tmp`.

## Shared oracle

`rust/tests/fixtures/job-store-writer/` was recorded by Swift `JobStoreRustWriterParityContractTests`
in record mode (`ARKDECK_RUST_JOB_STORE_RECORD`); `provenance.json` lists the SHA-256 of each file and
of the producer sources.

| File | Content |
| --- | --- |
| `records/*.json` | `durableData()` of five records derived from the Swift-produced `job-publication-current` records: admitted; running (escapes, `/`, U+2028, doubles, ring and screen facts, skip reasons); published; a second Job admitted under its own identity; that Job outcome-unknown with a failure |
| `format-probe.json` | Foundation's pretty spelling of empty containers, escapes, integers, doubles and key order |
| `scenario.json` | 10 steps: 4 admissions (admitted, admitted, duplicate, conflict), 3 lookups, 3 persists |
| `index.json` | what a reader observes afterwards: `user_version` 1, `wal`, every `sqlite_schema` row, every index row and each record file's SHA-256 |

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Rust writer | `cargo test -p arkdeck-hoststore --test job_store_writer` | 5 passed: the five Swift records and the two Swift publication records re-encode to their exact bytes; the owner replays the Swift scenario and leaves exactly the Swift index facts, a reopened owner answers the first admission as a duplicate, the reader returns the published record and the Session census counts both Jobs; refusals (a non-digest hash, a persist without an index row, an invalid update time, a creation-time mismatch, a store opened for reading) leave the index and record files unchanged and create no Job directory; a second owner or reader is refused while one is open, and both reopen after a close without writes; a live log with a future `user_version` is refused by owner and reader with the database and log bytes unchanged |
| Pretty encoder | `cargo test -p arkdeck-hoststore --lib session_json` | 2 passed: literal Foundation spellings, and the Swift probe re-encoded to its exact bytes |
| Rust suites | `cargo test -p arkdeck-platform -p arkdeck-hoststore` | every binary passed |
| Clippy | `cargo clippy --workspace --all-targets [--target x86_64-pc-windows-msvc \| x86_64-unknown-linux-gnu] -- -D warnings` | clean on all three targets |
| Swift oracle | `run-swiftpm.sh test --filter JobStoreRustWriterParityContractTests` | recorded once in record mode; in verify mode 2 executed, 0 failures: Swift regenerates exactly the committed oracle |
| Swift reads a Rust-written store | Rust with `ARKDECK_RUST_JOB_STORE_OUTPUT=/private/tmp/xpa014-job-store-rust-state-r1`, then Swift with `ARKDECK_RUST_JOB_STORE_VERIFY` naming that directory | Swift `RuntimeAdmissionService` opens a copy of the Rust-written store: its index facts equal the oracle, both Jobs' `job-record.json` decode through `RuntimeJobRecord.state(in:)` with `durableData()` equal to the index bytes, and lookups answer duplicate and conflict. Without the variable the test skips, as in CI, whose Swift lane builds no Rust |

Logs: the recording is `/private/tmp/xpa014-job-store-oracle-record-r1.log`. The cross-read is
`/private/tmp/xpa014-job-store-crossread-r1.log` (SHA-256
`833a2cb89efd652d4635f850b93e98cc09b7cc61b42f8d6985c88a16a6718739`); its trailing
`cargo fmt --check` step failed on the unformatted new code. After `cargo fmt --all`, formatting,
three-target Clippy and the platform and hoststore suites passed in
`/private/tmp/xpa014-job-store-fmt-checks-r1.log` (ends `checks exit=0`, SHA-256
`c9ccd1585b1f08586dc4f5f90df26c29505b2d190623412fcf0d4cebe5c60fe7`). These ran before the rebase
onto #1889; the unified gate below ran after it.

## Unified local gate

`python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`
on commit `7d451c8b` (merge base `25467d32`), with `ARKDECK_PYTHON` on the SDD venv and the planner
started from a venv holding `PyYAML==6.0.3` and `jsonschema==4.26.0`. The planner classified 19
changed files and selected the common, design-system, Swift and Rust lanes (no App build). Log:
`/private/tmp/xpa014-job-store-gate-20260914-r1.log`.

- Common checks: planner and agent-PR workflow tests, SDD (0 errors, 0 warnings, 121 acceptance IDs),
  catalog generator tests and `--check`, 83 design-system tests.
- Swift full lane: `full-parallel` 2,650 tests exit 0, `full-process-identity-race` 1 test exit 0,
  `full-viewer-scale` 5 tests exit 0.
- Rust lane: `generate-contract.py --check`, `cargo fmt --all --check`, warnings-denied Clippy,
  workspace tests, `test_contract_checks.py` (33 tests OK), `check-contracts.py` passing both views
  with every candidate process harness and `test-macos-facade.py` (7 tests OK), `cargo deny` and
  `cargo vet` (36 fully audited).
- Result: the log ends `gate exit=0`; SHA-256
  `3be029018fbc2b73c829b987ca33654a859b333174834f37c1ca2cc0c1fed81a`.

## Found while building this slice

Apple's system SQLite refuses a read-only connection to a WAL store whose `-shm` is absent
(`SQLITE_CANTOPEN`, 14). A probe measured it after an owner closed a store it had switched to WAL
without writing: the read-only query failed, a write connection's query succeeded, and a read-only
connection opened beside it succeeded once `-shm` existed. The Swift repository already documents
and follows this rule; the Rust reader and owner now do too.

## Not run, and why

- No daemon, RPC or CLI path admits Jobs yet, so there is no process harness or control-frame
  evidence. The first consumer is the Rust admission slice.
- No admission ordering, plan, capability, recovery or execution; ADR-0009 decisions 2/4 (L.1 item
  13) are not ported.
- No device; DAYU200 is not attached to this host.
