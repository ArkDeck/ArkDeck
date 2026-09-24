# TASK-XPA-018 — the §G.4 cutover preflight: `arkdeck-agentd --cutover-preflight`

G5 queue slice 7 (M5 prerequisite, lane A), second PR, part a. The second PR is
split in two, as the coordinator allowed: this part adds the offline preflight
that `runtime service update` runs; part b carries `runtime service
install|update|uninstall`, the snapshot file, the rollback retention of the
replaced helper bundle and `verify` without `--job`.

Rulings (协调会话受托裁定 2026-09-24, delegated by the maintainer) this part
implements:

1. The offline cutover preflight is a one-shot, read-only `arkdeck-agentd
   --cutover-preflight` over the production layout, never under the facade's
   name. The CLI runs it twice: lock-free before `bootout` (a refusal then
   changes nothing), and again holding the instance lock after `bootout` (a
   refusal then bootstraps the old plist back unchanged). The CLI does not link
   `arkdeck-hoststore`. Coverage: all thirteen blocking states of #2026's
   table, unresolved intents and journals, running agent executions, reserved
   but unsettled capability uses, and no pending tool selection.
4. (its first half) The snapshot summary: relative path, size and SHA-256 of
   every file under `Agentd`, and a root digest. Part b writes it to
   `LaunchAgent/cutover-snapshots/` and keeps the replaced bundle one generation
   in `Helpers/.rollback/`.

Rulings 2 (`ARKDECK_ANALYZER_PATH` refused fail-closed by name until
`--analyze-crash-ledger` is ported), 3 (`update` refused while a signing receipt
exists, until the Rust signing owner, Q8) and 5 (`verify` without `--job` as an
agent run through the daemon plus the reopen) are part b's.

Development base: protected main `5b1df34ee` (#2141). Branch:
`agent/xpa-018-cutover-preflight`.

## What a caller sees

`arkdeck-agentd --cutover-preflight [--hold-instance-lock]`, with
`ARKDECK_RUNTIME_COMPOSITION=production` and nothing else of another
composition (`ARKDECK_DEVELOPMENT_STATE_ROOT`, `ARKDECK_ENDPOINT`, the facade
pairing, `ARKDECK_HDC_SHA256`, `ARKDECK_APP_INGRESS`), answers before any
composition is considered and exits:

- 0 with one canonical `arkdeck.cutover-preflight/1` document and a newline on
  stdout, clear or not;
- 64 for any other argument list or without the production composition;
- 69 under the facade's executable name, beside another composition's input,
  or without an account home;
- 70 or 74 if the document cannot be encoded or written.

Refusals print one stderr line and nothing on stdout.

The document: `stateDirectory`; `instanceLockHeld`; `clear` (no block);
`blocks` — the held pass's own first (`runtimeRunning`, or an unreadable state
directory, lock or snapshot), then the shared classifier's in its order, then
the pending selection and the unreadable sources; `carriedOver` (`parkedJobIds`,
`terminalJobCount`, `outcomeUnknownUseCount`); `counts` (`jobs`,
`agentExecutions`, `capabilityUses`); `snapshot` (`null` unless the held pass
holds the lock or finds no state directory).

| Block `kind` | When | Fields |
| --- | --- | --- |
| `jobState` | the most conservative of the states the Job's index row, record and journal give is blocking or unlisted | `jobId`, `state` (the first blocking one) |
| `unresolvedJournal` | the journal holds an outstanding intent, an unknown outcome or a torn tail, or does not replay, and the Job is not parked | `jobId` |
| `activeAgentExecution` | the execution is active by the table, unless it is `jobOwned` by a parked or terminal Job | `executionId`, `state` |
| `unsettledCapabilityUse` | the use's current outcome is `pending` or unlisted | `capabilityId`, `useOrdinal`, `jobId` |
| `pendingToolSelection` | `Bootstrap/v1/tools.json` holds `selection.pending` | `controlActionId` |
| `runtimeRunning` | held pass only: another process holds `Agentd/instance.lock` | `reason` |
| `unreadable` | a source could not be read: `jobs`, `jobIndex`, `agentExecutions`, `capabilities`, `toolSelection`, `stateDirectory`, `instanceLock`, `snapshot` | `source`, `reason` |

The held pass opens the state directory, takes `instance.lock` with
`flock(LOCK_EX|LOCK_NB)` exactly as the daemons do (`HostDirectory::lock_document`,
creating it owner-only if absent), records the snapshot, then reads the facts,
and keeps the lock until the process ends. The snapshot
(`arkdeck.cutover-snapshot/1`): `stateDirectory`, `stateDirectoryPresent`,
`takenAtUtc`, `entries` in byte order of their relative path (`file` with
`byteCount` and `sha256`, `directory`, `symlink` with its `target`, `socket`,
`other`), `fileCount`, `byteCount`, and `rootSha256`, the SHA-256 of the entries'
canonical JSON. No link is followed, and a file that changes while it is
measured refuses the snapshot (`arkdeck_platform::snapshot_tree`).

## How each fact is read, without an owner

`arkdeck_hoststore::cutover_facts` reads beside or instead of the owners and
never fails as a whole; each source it cannot read is named.

- **Jobs.** The index `Agentd/runtime-jobs.sqlite3` through the connection
  Swift's `RuntimeJobRepository` inspects with: read-only through an existing
  shared-memory index; without one, a connection that never writes; a log or
  rollback journal with content but no index is refused (it would be replayed).
  The layout must be the current one (`user_version` 1, the four statements, the
  two automatic indexes); every row's `(job_id, state)` is paged in identity
  order. Then every entry of `Agentd/jobs/`: names that are no Job identity and
  plain files are skipped; `job-record.json` (16 MiB bound) decodes as a
  `JobRecord` and gives its state; `journal.jsonl` (64 MiB bound) is replayed by
  the journal replay and gives its current state and whether an intent is
  outstanding, an outcome unknown or the tail torn. A directory that cannot be
  opened as the owner's, or a record that does not decode, gives the state
  `unreadableRecord`; a directory no source gives a state for gives
  `missingRecord`. Neither name is in the table, so both block.
- **Agent executions.** `Agentd/agent-executions/execution-*.json`, bounded as
  the owner bounds them, each decoded as its record and named by its own
  identity.
- **Capability uses.** The checkpoint and the ledger of `Agentd/capabilities`,
  read unlocked (a torn last ledger line dropped, as the owner drops it),
  applied and validated as the owner does; each consumption's current outcome.
- **Tool selection.** `Bootstrap/v1/tools.json` decoded by its bounded schema
  (not through the ledger path, which would publish an empty index); its
  `selection.pending.actionID`.

Neither pass writes a record, journal, ledger or index row, takes a store
owner's lock or marks a lock document; the held pass takes only the Runtime's
instance lock, creating `instance.lock` if it is absent, as either daemon
would. The Job index's SQLite connection has only the effects any reader of it
has: beside a shared-memory index it may record its read mark there; without
one it opens the database and, under Apple's persistent write-ahead log, leaves
an empty log and a new index beside it with the database's own mode (the
database bytes stay identical).

## Declared differences

- Swift has no offline cutover preflight to compare with: the table and its
  classifier (`spec/recovery/job-state-preflight.json`, #2026) are the shared
  oracle, and this mode supplies the facts. `unreadableRecord` and
  `missingRecord` are this reader's names for states it cannot establish; they
  block as any unlisted state does.
- The lock-free pass is advisory (it may race the running Runtime); only the
  held pass is taken to prove the state quiescent.

## Tests

- `crates/arkdeck-agentd/tests/cutover_preflight.rs` (9) runs the real
  `arkdeck-agentd` with a cleared environment over temporary homes below
  `/private/tmp` (`CFFIXED_USER_HOME`), seeded with Swift-recorded Jobs
  (`screen-sequence` succeeded and `waitingForRecovery`, `job-submit-analyzer`
  `preflight`, `readback-reconcile` `resumeAtConfirmedSafeBoundary`), an index
  with Swift's schema, the `agent-lifecycle` executions (completed, abandoned,
  orchestrating), the `capture-diagnostics-file-legs` and `capability-resolve`
  capability stores and the `tool-selection-registry` indexes. Covered: the
  seeded root's exact blocks, carried-over sets and counts, with the tree below
  the home unchanged; each of the table's thirteen blocking states, and an
  unlisted one, on an otherwise terminal Job's index row; a parked lane
  carried over whatever its row says; a torn journal on a terminal Job refused
  and on the parked lane carried; an undecodable record (`unreadableRecord`)
  and an unreplayable journal; a Job named only by `jobs/` or only by the index;
  plain files and non-identities skipped; an empty Job directory
  (`missingRecord`); the one unsettled use by identity, ordinal and Job; an
  undecodable ledger line and a foreign index file as `unreadable`; a clear
  root; the held pass's snapshot (an entry's size and digest, the root digest
  recomputed, the same state measured the same); `runtimeRunning` while the test
  process holds the instance lock, with the lock-free pass unaffected; no state
  directory (clear, empty snapshot, nothing created); the facade name,
  missing composition, malformed arguments and another composition's input
  refused with empty stdout; the index read through an existing shared-memory
  index (database and log bytes unchanged), without one (database unchanged,
  new log empty, both owner-only) and refused with a log but no index.
- `crates/arkdeck-platform` `tree_snapshot`: a tree with a file, an empty file,
  a symlink and a socket measured without following the link, twice alike; a
  symlinked root refused.
- Nine mutations, each caught by a test failure (not a build error) and
  restored by checksum (`/private/tmp/arkdeck-s18-mutants-2a.log`): the index
  ignored, a torn tail ignored, an unreplayable journal read as resolved, the
  pending selection ignored, `missingRecord` dropped, plain files read as Jobs,
  the capability ledger left unapplied, the snapshot taken without the lock,
  the preflight run beside another composition's input.

No test ran `launchctl`, touched the account's `gui/<uid>` domain, its
LaunchAgent plist or `~/Library/Application Support/ArkDeck`, the installed
agentd or its HDC server, or a device.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s18-2a-*.log`. The changed crates are `arkdeck-platform`,
`arkdeck-hoststore` and `arkdeck-agentd`; with the platform's and the store's
direct dependents the checked set is `arkdeck-platform`, `arkdeck-client`,
`arkdeck-cli`, `arkdeck-hoststore`, `arkdeck-provider-hdc`,
`arkdeck-provider-workspace`, `arkdeck-agentd` and `arkdeck-soak`.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s18-2a-fmt.log` |
| `cargo clippy --all-targets -- -D warnings` for the eight crates | 0 | `arkdeck-s18-2a-clippy.log` |
| the same for `arkdeck-platform`, `arkdeck-hoststore` and `arkdeck-agentd` with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` (every new module is macOS-only) | 0, 0 | `arkdeck-s18-2a-clippy-{linux,windows}.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test --no-fail-fast` for the eight crates | 101: 157 result lines, 1,261 passed, 1 failed, 18 existing ignored | `arkdeck-s18-2a-tests.log` |
| the one failure, `arkdeck-provider-hdc --test lifecycle` `a_confirmed_stop_ends_in_an_unavailable_endpoint` ("the fake server ended before it listened": the fake HDC's `bind` lost the port it had been handed to a parallel test), rerun alone three times | 0: 7 of 7 each time | `arkdeck-s18-2a-lifecycle-rerun.log` |
| `cargo test -p arkdeck-agentd --test cutover_preflight` | 0: 9 passed (also inside the run above) | `arkdeck-s18-cutover-test.log` |
| nine mutations through `scratchpad/s18/mutate.py`, each caught by a test failure (not a build error) and restored by checksum | caught ×9 | `arkdeck-s18-mutants-2a.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s18-2a-sdd.log` |

The lifecycle failure meets the four conditions of an invalid run: it is outside
this change (no file of `arkdeck-provider-hdc` changed, and the platform gained
only a new module), it is the known port race of a fake server binding a port
handed to it earlier, it passes alone, and nothing in the diff touches ports or
the HDC lifecycle.

Afterwards no temporary home (`/private/tmp/acp-*`, `/private/tmp/ats-*`) or
test process was left, and the installed agentd (PID 10694) and HDC server
(PID 10798) were the same processes as before the session.

Not run: `generate-contract.py --check` and `check-contracts.py` (no contract
input, argv corpus or crate edge changed; the Rust lane runs them in CI), Swift
or App tests (no Swift or App file changed), the full local gate, any installed
service or device.

## CI

Pending.
