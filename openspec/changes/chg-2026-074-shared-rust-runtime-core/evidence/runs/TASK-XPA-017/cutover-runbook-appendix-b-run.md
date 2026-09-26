# Read-only verification of the cutover runbook's appendix B, items 11, 12, 18 and 19 (TASK-XPA-017, macOS, 2026-09-26)

TASK-XPA-017 / CHG-2026-074. The cutover window runbook
(`docs/design/cross-platform/macos-rust-cutover-runbook.md`, #2258) leaves open, in its appendix B,
four steps it could not ground in the source:
- **11:** a published path to abandon a pending HDC tool selection;
- **12:** a published path to move a named retained Session out of the Session root;
- **18:** the state a step-2 failure after the snapshot leaves, and the way back;
- **19:** whether the manual `--cutover-preflight` on the account really only reads.

The hub proposed a read-only check, and the coordinator ordered it on 2026-09-26: facts with
file:line evidence for each item, nothing decided in the maintainer's place, and nothing run on the
real account. Where the facts correct the runbook's text, the runbook is changed in the same PR
(listed per item).

Base: protected `main` `784641012`. Read-only: no code, no build, nothing executed on any account.
Swift sources are cited under `Packages/ArkDeckKit/Sources/`, Rust under `rust/crates/`.

## 11. Abandoning a pending HDC tool selection

**Finding: no published command abandons a pending selection.** The Swift daemon settles it itself
when it next starts, and the published way to make it start again is `runtime service restart`.

- **Nothing published fails it.** Only the Swift daemon fails a pending selection
  (`BootstrapToolRegistry.failPendingSelection`, `ArkDeckBootstrap/BootstrapToolRegistry.swift:477`):
  - at its start (`ArkDeckAgentDaemonMain/main.swift:500–545`);
  - when the selection's lifecycle fails before its launch window
    (`ArkDeckWorkflows/RuntimeToolSelectionCoordinator.swift:253`).
- **A second selection is refused** while one is pending: `resourceConflict`, "another tool
  selection is already pending" (`BootstrapToolRegistry.swift:394–397`).
- **The pending window.** A selection is pending from its approval until the next start of the Swift
  daemon.
  - At approval the registry writes it (`prepareSelection`, `BootstrapToolRegistry.swift:386–415`),
    and the daemon restarts into the selected tool; the lifecycle lease is held "until launchd
    replaces this daemon" (`RuntimeToolSelectionCoordinator.swift:230–245`).
  - The next start settles it (`main.swift:474–545`):
    - the start resolves the pending tool (`BootstrapToolRegistry.swift:426–442`);
    - it publishes the selection if that HDC starts (`:503`);
    - otherwise it fails the selection and starts the prior tool again (`:511–513`, `:537–539`).
  - The start settles a selection only when the daemon has a configured HDC (`if let configuredHDC`,
    `main.swift:474`).
- **The published restart.** Swift's `runtime service restart` (registry
  `rust/crates/arkdeck-cli/src/command_registry.json:1020`;
  `ArkDeckCLI/ArkDeckRuntimeCommands.swift:491–560`) restarts the installed daemon. It refuses, exit
  75, while Runtime Jobs are active or unclosed (`:522–527`).
- **The control action's record** is settled afterwards by
  `control-action reconcile --control-action <id>` (registry `:12156`), which reads the registry's
  outcome (`RuntimeToolSelectionCoordinator.swift:357–388`).
- **What the preflight reads.** It reads only the registry's `selection.pending`
  (`rust/crates/arkdeck-bootstrap/src/tool_selection_ledger.rs:147–163`), which publication and
  failure both clear. It therefore clears after that start, whether or not the record is
  reconciled.
- **A transient reading.** A lock-free 1a beside a running Swift daemon can read the pending window
  itself, which ends when the daemon restarts on its own.

**Stays with the maintainer:** whether to restart the old Runtime for a selection that persists.

**Runbook change:** the `pendingToolSelection` row states the above and keeps the maintainer's call.

## 12. A retained Session the continuity proof refuses

**Finding: no published command moves or removes such a Session.** `session cleanup` cannot, and
`runtime storage status` counts it without naming it.

- **Where it is named:**
  - **The preflight's own block.** Its `message` is the Rust continuity proof's: "retained Session
    `<yyyy/mm/name>` has no Manifest and no failed publication of this Runtime accounts for it; …"
    (`arkdeck-hoststore/src/mutation_state_continuity.rs:190–201`).
    - That sentence is this Runtime's own; Swift has none like it. The coordinator put correcting
      it into S41 (2026-09-26), with its tests' expectations.
    - Its clause "runtime storage status and session cleanup name it" holds for cleanup only.
      Status counts the Session and names nothing, in both Runtimes (below and
      `arkdeck-hoststore/src/session_inventory.rs:740`).
  - **Swift's catalog scan** counts such a Session (an identity without a Manifest) as unaccounted
    content, reason `unreadable`: "a missing or unreadable manifest is the common case"
    (`ArkDeckStorage/SessionRetentionCatalog.swift:86–101`).
  - **`runtime storage status`** (registry `:3259`) publishes only
    `usage.unaccountedSessionCount` (`ArkDeckWorkflows/RuntimeSessionStorageStore.swift:23–58`,
    `:1447`).
  - **`session cleanup preview`** (registry `:8118`) names it by refusing. While anything under the
    Sessions root is unaccounted, the whole-root family (list, pin, unpin, cleanup) answers
    `operationUnavailable` "Session catalog contains unaccounted content: `<reference>`
    (`<reason>`)" (`RuntimeSessionStorageStore.swift:869–872`, `:1305–1328`). The Rust port answers
    the same (`session_inventory.rs:366`).
- **Cleanup cannot remove it.** `session cleanup apply` needs a preview's id and digest (registry
  `:8222`; `RuntimeSessionStorageStore.swift:505–516`), and no preview can be made while the
  Session is there.
- **No published command moves or deletes an unaccounted Session.**

**Stays with the maintainer:** moving it out of the Session root by hand, and where to, as the
proof's message asks ("move it out of the Session root once reviewed").

**Runbook change:** the `retainedSessions` row no longer sends the reader to `runtime storage
status` for the name, and states that cleanup cannot remove the Session.

## 18. A step-2 failure after the snapshot, and the way back

**Finding: confirmed, there is no automatic recovery after the snapshot is written.** The way back
the runbook gives is consistent with the source, but no test exercises it from a half-finished
install.

### Before and after the snapshot

`rust/crates/arkdeck-cli/src/runtime_service_install.rs`:
- **Up to and including the snapshot's write, a failure restarts the old service** from its
  unchanged plist, or leaves it stopped if it was not running (`:600–608`). The held pass and the snapshot write both run in `cutover` (`:594–670`), whose
  every failure goes through its `restore` (`:599–625`); the snapshot write is at `:664`.
- **After `cutover` returns, nothing restores.** Each later step fails with exit 1 and the
  underlying error (`failed`, `runtime_service.rs:193–197`), and the old service stays booted out
  (`install`, `:539–580`). The steps are:
  - swapping the bundle (`:544`, `replace_bundle` `:1036–1066`);
  - validating it (`:545`);
  - the plist (`:566`) and the receipt (`:578–579`), each written atomically;
  - `bootstrap` (`:580`).

### The state each failing step leaves

In every case below the old service is booted out and not running.

| Failing step | Installed helper | Replaced helper | Plist and receipt |
| --- | --- | --- | --- |
| Cloning the new bundle to its staging name, or the swap (`:1052`, `:1057`) | unchanged, the old one; the staging copy is removed | — | unchanged |
| After the swap: the `.rollback` directory, the removal of the previous generation, or the rename into `.rollback` (`:1058–1065`) | the new Rust helper | left at `Helpers/.arkdeck-agentd-<UUID>.app`, the staging name; `.rollback` holds the previous generation, or none if its removal completed | unchanged; the old plist names `arkdeck-facade`, which the Rust helper does not carry |
| Validation, mode, launch path, plist document or plist write | the new Rust helper | `Helpers/.rollback/ArkDeckAgent.app` | unchanged |
| Receipt write | the new Rust helper | `.rollback` | new plist, old receipt |
| `bootstrap` | the new Rust helper | `.rollback` | new plist, new receipt |

### The way back (§4 row 3): `runtime service update --daemon "$ROLLBACK"` with the Rust CLI

- **The probe finds Swift without touching state.** It runs `$ROLLBACK`'s `arkdeck-agentd` with
  `--cutover-preflight` (`:750–823`).
  - Swift's daemon parses its arguments before anything else in its top-level code, and answers
    "unknown argument …" with exit 64 before the state directory is opened (`main.swift:183–203`).
  - The update takes that as a Swift helper and passes no preflight gate (`:73`, `:812`).
- **The bundle swap works from every state above.** Nothing is loaded, so there is no bootout
  (`:532–538`).
  - With a helper installed, Swift or Rust, `replace_bundle` swaps `$ROLLBACK`'s copy in and moves
    what was installed into `.rollback`, replacing that generation (`:1057–1065`).
  - With none installed, it renames the copy into place (`:1053–1056`).
- **The plist is written for the Swift helper,** without the production composition (`:552–566`),
  followed by the receipt and `bootstrap`. Nothing below `Agentd` is written.
- **The same gates apply as to any update:** the bundle's signature validation (`:469–470`), the
  signing-preset refusal (`:427`, `:443–456`) and the ArkTrace descriptor rules.
- **A leftover `Helpers/.arkdeck-agentd-<UUID>.app`** (the second row) is left where it is.
- **Evidence and gaps:**
  - The fake-launchd tests cover an update to a Swift helper over an installed one
    (`rust/crates/arkdeck-cli/tests/runtime_service.rs:1845`) and the cutover's own failure paths
    (`:2491`, `:2581`).
  - None covers a failure after the snapshot followed by this update.

**Stays with the maintainer:** accepting this way back (the runbook's "需维护者认可").

**Runbook change:** step 2's failure table names the staging leftover and the exact steps. §4 row 3
cites the probe's behaviour.

## 19. Whether `--cutover-preflight` on the account only reads

**Finding: the lock-free pass (1a) takes no lock and creates no directory or lock document. It
writes no record, journal, ledger, index row or settings. It does create or touch `-wal` and `-shm`
beside the Job index, without changing the database's contents.**

- **What "neither pass writes" means.** #2142's and #2255's records say "neither pass writes"; that
  covers owner data (records, journals, index rows), not these two SQLite files.
- **At the coordinator's direction (2026-09-26)** the runbook now states this plainly, for the
  maintainer to judge. No code changes for it.
- **True zero-write is a separate design choice, listed as open.** It could be had, for example, by
  opening the index `immutable` or by reading a copy of it.

### Before anything is read

- **The mode is dispatched before any composition:** `arkdeck-agentd/src/main.rs:895–917`.
- **Environment checks only** (`cutover_preflight.rs:73–106`; `production.rs:78–121`;
  `facade.rs:30–37`).
- **Which account's state it reads.** The layout comes from `CFFIXED_USER_HOME`, or else the
  running user's passwd entry (`arkdeck-platform/src/account.rs:7–`; `production.rs:198–202`).
  - `HOME` does not choose it.
  - Run as the maintainer, it reads that account's `~/Library/Application Support/ArkDeck/Agentd`,
    `…/ArkDeck/Sessions` and `…/ArkDeck/Bootstrap/v1`.

### What the lock-free pass opens (`preflight`, `cutover_preflight.rs:133–199`, with `hold` false)

Every file and directory is opened read-only, without following a final link. There is no
`flock`, no `O_CREAT` and no write:

| What | How | Evidence |
| --- | --- | --- |
| The state directory | `stat`; then `open(O_RDONLY\|O_DIRECTORY\|O_NOFOLLOW)` after `canonicalize` | `cutover_preflight.rs:137`; `host_store.rs:742–787` |
| `runtime-jobs.sqlite3` and its `-wal`, `-shm`, `-journal` | `lstat` of each; one SQLite connection, then three read-only statements (`PRAGMA user_version`, `sqlite_schema`, `runtime_job` pages) | `job_repository.rs:115–157`, `:158–`, `:235–270` |
| `jobs/<id>/job-record.json`, `journal.jsonl` | read whole; `lstat` of the ArkForge state file | `cutover_facts.rs:165–279` |
| `agent-executions/execution-*.json` | directory listing; each read whole | `agent_execution.rs:1191–1219` |
| `capabilities/` checkpoint and ledger | read whole (`std::fs::read`), links refused | `capability_store.rs:513–545`, `:803–`, `:852–` |
| `Bootstrap/v1/tools.json` | read whole; the store's lock is not taken, and an absent index is not created | `tool_selection_ledger.rs:147–163` |
| `Agentd/session-storage.json` | read whole, without the storage lock | `session_owner.rs:572–606` |
| The Session roots (default and configured) | `lstat` of each ancestor, `canonicalize`, a read-only open; entries listed and read; an absent root is not created | `mutation_state_continuity.rs:295–323`, `:616–623` |

### SQLite: which connection, and its effects (`job_repository.rs:130–157`)

The flags are set at `host_sqlite.rs:126–140`. `NOFOLLOW` and `FULLMUTEX` are always set, `CREATE`
never, and the busy timeout is 0.

- **With `-shm` present** (a Swift daemon, live or stopped, leaves one), the connection is
  `SQLITE_OPEN_READONLY`.
  - It cannot write the database or its log, and it cannot checkpoint.
  - It reads through the shared-memory index, where it may record its read mark: the only byte it
    changes.
  - Any lock contention SQLite reports (`SQLITE_BUSY`) is answered at once, since the busy
    timeout is 0 (`host_sqlite.rs:140`). It becomes an `unreadable` `jobIndex` block, not a wait
    (`cutover_facts.rs:175–190`); a rerun reads again.
- **Without `-shm`**, the connection is `SQLITE_OPEN_READWRITE`. The index is refused unread if
  `-wal` or `-journal` has content (`:139–152`).
  - It runs no write statement. The database bytes stay the same.
  - As the source puts it (`cutover_facts.rs:17–24`), under Apple's persistent write-ahead log it
    may leave an empty `-wal` and a new `-shm` beside the database, in the database's mode.
  - Closing it checkpoints an empty log, which copies nothing.
- **The tests pin this.** `the_job_index_is_read_the_way_swift_inspects_it`
  (`arkdeck-agentd/tests/cutover_preflight.rs:862–`):
  - with `-shm`, the database and log bytes are unchanged;
  - without it, the database bytes are unchanged, and any `-wal` left is empty, any left file
    `0600`.

### The held pass (`--hold-instance-lock`), which only `runtime service update` runs

It adds:
- **`Agentd/instance.lock`:** created empty with mode `0600` if absent (`O_RDWR|O_CREAT|O_EXCL`,
  then `O_RDWR`), then `flock(LOCK_EX|LOCK_NB)`. No byte is written, and the lock is released when
  the process ends (`cutover_preflight.rs:141–157`, `:197`; `host_store.rs:449–483`).
- **A read of every file below `Agentd`** for the snapshot: `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, hashed
  (`cutover_preflight.rs:159–173`, `:287–324`; `tree_snapshot.rs:40–`).

The runbook's 1a runs the lock-free pass only.

### Tests over whole trees

These compare every entry below a test home, before and after, by mode, inode, size, modification
time and content, leaving out directory times and the `-shm` bytes (`tree`,
`cutover_preflight.rs:366–397`):
- `a_swift_state_root_is_refused_by_every_fact_that_blocks_and_carries_the_rest` (`:529`);
- `a_state_with_nothing_in_flight_is_clear_and_the_held_pass_records_its_snapshot` (`:778`, both
  passes);
- `the_preflight_runs_only_as_the_production_layouts_one_shot_read` (`:858`);
- `a_retained_session_the_continuity_proof_refuses_refuses_the_cutover_in_its_own_words` (`:1170`,
  `:1246`).

**Stays with the maintainer:**
- whether touching or creating `-wal` and `-shm` is acceptable;
- running it on the real account (the runbook's "需维护者认可");
- whether a true zero-write read is wanted, a design choice for another slice.

**Runbook change:** 1a's "precise meaning of read-only" lists these effects and how the account is
chosen.

## Runbook changes, one by one

In `docs/design/cross-platform/macos-rust-cutover-runbook.md`:

| Where | Change | Item |
| --- | --- | --- |
| Step 1, 1a, "「只读」的精确含义" | The effects of item 19: no lock, no directory or lock document, the account chosen by `CFFIXED_USER_HOME` or the passwd home. Stated plainly: it creates or touches `-wal`/`-shm` beside the Job index, without changing the database. True zero-write is listed as an open design choice | 19 |
| Step 1, the `pendingToolSelection` row | No published abandon; the Swift start settles; `runtime service restart` and `control-action reconcile`; the restart stays the maintainer's | 11 |
| Step 1, the `retainedSessions` row | Named by the block's message and cleanup's refusal, not by status; cleanup cannot remove it; no published move; moving it stays the maintainer's | 12 |
| Step 2, failure table, third row | Exact lines; restore up to the snapshot's write; the state per failing step, the staging leftover included | 18 |
| §4, third row | The probe of `$ROLLBACK`'s Swift daemon exits at argument parsing, so the update takes no preflight gate | 18 |
| Appendix B, items 11, 12, 18, 19 | Each names this record and what stays with the maintainer | 11, 12, 18, 19 |

## Contract

No contract input, code or `tasks.md` changes.

## Local targeted checks

- `sh scripts/check-sdd.sh` (validation venv): exit 0.
- Not run: builds and tests (no code change), and nothing on any account.

## CI

Pending; recorded by the next slice.
