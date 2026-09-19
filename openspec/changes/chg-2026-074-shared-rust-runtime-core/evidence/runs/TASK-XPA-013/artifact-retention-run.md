# TASK-XPA-013 — the isolated owner's startup Artifact retention sweep (macOS, 2026-09-19)

TASK-XPA-013 remains in progress. Base: protected main `2af5c806` (#2034); written on `7b5872f1`
(#2029) and rebased without conflict; no stack. Host-only
change: no device, real HDC, installed state or Swift daemon was used, and nothing here is device
evidence (POL-VERIFY-001, POL-MODE-001). No Swift source, control schema, corpus, Catalog,
entitlement, `openspec/specs` or constitution change.

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-013) |
| --- | --- | --- |
| Artifact read/inspect/export (#1856, #1874); Import upload (#1881); `artifact.quota` (#1911); Import commit and publication (#1983); Import leases, reference inspection and release (#1987); the Job products' publication with deadlines and a quota that refuses new products and never evicts (TASK-XPA-014) | The retention sweep Swift's daemon runs once at startup (`collectGarbage`), in the isolated Rust daemon; the Job census and cleanup-ledger reads it keeps by | The canonical alias HDC route; the publish crash-window matrix; owner activation at M5; GJ-1/2/3 re-pass. `cleanupDebt.list`/`continue` stay with `debug.hap@1`'s last slice (TASK-XPA-014) |

## Why

ADR-0007 decision 5: quota refuses new work and never evicts; GC reclaims only entries whose
retention has passed, that no active Job references and that are not pinned. Publication and
Import release already write the deadlines, but nothing in Rust ever reclaimed an expired
Artifact: an isolated root grew into its 8 GiB quota with no way back. Swift's daemon had the same
defect until it gained its one production call, at startup, after Job recovery and before serving
(`ArkDeckAgentDaemonMain/main.swift`).

## What changes

- **The sweep** (`arkdeck-hoststore` `artifact_retention.rs`, a child of `artifact_publication`),
  Swift `RuntimeArtifactStore.collectGarbage(activeJobIDs:nowUTC:)`:
  - The root is classified before any Job is read, as `jobDirectories()` does. The Import
    owner's directory and a regular cleanup ledger are skipped. Any other directory is a Job.
    Anything else refuses the sweep before anything is reclaimed.
  - In each Job not kept, every index row is read as publication reads it (payloads checked).
    Every deadline is parsed as Swift parses it (`format_timestamp_seconds`, the pinned
    `ISO8601Timestamps.parse` port), pinned or not. A row expires at `deadline <= now`. A row
    without a deadline never expires.
  - Expired, unpinned rows go, missing products' rows included. The index is rewritten without
    them first; then each reclaimed published payload is unlinked (`remove_document`, which
    unlinks exactly the inspected file and syncs the directory). A failure after the index
    leaves an unreferenced file, never an index naming missing evidence. The Job directory and
    its index, possibly empty, stay.
  - The sweep holds the Artifact retention guard's lock, which every publication and Trace
    maintenance take (`ArtifactReadStore::with_retention_lock`, new), but not the guard's Trace
    census, which refuses an Artifact tree of more than 4096 entries in total or deeper than
    8 levels. The sweep must still run on a store that has grown past that bound (Finding below).
- **What it keeps** (`RetentionKeep`), never less than Swift keeps:
  - the Jobs the Job owner's census (`job_retention_census.rs`, a child of `job_owner`) cannot
    prove settled. Settled means a decodable, verified row that is terminal, of known outcome,
    whose Job directory holds the same record, and whose journal replays to that state finalized,
    with no torn tail, outstanding intent or unknown outcome. A Job directory no row explains is
    kept too. The census holds the Job activity guard through the sweep;
  - every Job the cleanup ledger says still owes a cleanup (`cleanup_debt::outstanding_jobs`);
  - each exact `(owner, Artifact)` an active Job names as an input lease (`lease-v1:<owner>:<id>`
    anywhere in its inputs), wherever it lives: decision 5's "not referenced by an active Job".
- **The daemon** (`agentd` `main.rs`, `host.rs`): after composing its owners and before its accept
  loop, the isolated daemon runs `Host::collect_expired_artifacts` with the Runtime clock. It
  prints `reclaimed N expired artifact(s)` when it reclaimed anything. A failure prints
  `artifact retention sweep failed; the store may approach its quota: <reason>`, as Swift's
  daemon does, and never stops the daemon. The standalone and facade compositions have no
  Artifact owner and sweep nothing.
- `artifact_publication.rs`: `persist_index` factored out of `upsert`, unchanged.
- `rust/README.md`: one paragraph after `artifact.quota`'s.

## Declared differences from Swift

1. **It keeps more.** Swift keeps only the Jobs its recovery listed non-terminal and the records it
   quarantined. Rust also keeps unverifiable terminal Jobs, Jobs owing a cleanup, unexplained Job
   directories, and Artifacts that active Jobs lease. Every Artifact Swift keeps, Rust keeps.
2. **An incomplete census reclaims nothing.** A row the census cannot decode or whose submission
   does not verify, an unreadable Job store, or an unreadable cleanup ledger refuses the whole
   sweep, since references would be unknown. Swift quarantines an unreadable record and sweeps
   the rest; an unreadable store fails its startup.
3. **Order.** Jobs are swept in name order; Swift sweeps in directory order. Only a failed sweep's
   partial effect can differ.
4. **No startup recovery yet.** Rust's daemon runs no Job recovery before the sweep (design §L.1
   item 13's port is in progress). The census keeps every non-terminal Job anyway, so recovery
   cannot change what is reclaimed. When the port lands, it runs before the sweep (comment in
   `main.rs`).
5. **T2.** Swift's per-Job payload-verification cache is neither written nor forgotten here.
   Refusal texts follow Swift's where the sweep refuses as Swift does and are otherwise Rust's.

## Finding: publication stops at 4096 Artifact-tree entries

`ArtifactReadStore::with_trace_retention`, the guard every Rust publication joins (TASK-XPA-012's
Trace maintenance), walks the whole Artifact tree and refuses once it has visited more than 4096
entries. A capture Job leaves about eight (its directory, index and six payloads), so after
roughly 500 capture Jobs within their week of retention every further publication fails
(`cannot inspect artifact retention`). Swift has no such bound. The sweep here uses the lock
without that walk (`the_sweep_runs_over_a_tree_the_trace_census_refuses`), so a restart can bring
the store back under the bound once enough of it has expired. The bound on publication itself is
pre-existing and left for a separate change: raising or removing it changes what the Trace purge
may conclude.

## Consequence for manual harnesses

Every Swift-recorded Job Artifact under `rust/tests/fixtures/*/artifacts/` carries the deadline
`2026-09-21T00:00:00Z` (oracle clock 2026-09-14 plus a week). `rust/scripts/check-job-plan.py`,
`check-job-submit.py` and `check-job-run.py` seed those trees into daemon roots. From
2026-09-21 00:00 UTC, the Swift daemon they start already reclaims them at its own startup, and
now the Rust daemon does too. Those harnesses will fail until they re-date the seeded rows or
start their daemons over roots the sweep keeps. None of them runs in CI. `check-import-upload-owner.py`
seeds only Import upload records, which the sweep skips. The CI-run daemon tests either write
undated rows (`check-session-owner.py`) or fresh ones, and the in-process fixture replays never
sweep.

## Tests

| Test | What it proves |
| --- | --- |
| `artifact_retention.rs` unit: `only_lapsed_unpinned_rows_go_index_first_and_the_directory_stays` | Default, short-lived, pinned and missing products of two Jobs, published by the Rust publisher at a fixed clock. Nothing goes before a deadline. Short-lived rows go at their deadline exactly. An offset or fractional clock parses as Swift's. A week later, default and missing rows go and the pin stays. Only the index and the pinned payload remain, the kept row unchanged. A later sweep changes nothing |
| `…::kept_jobs_and_leased_artifacts_are_never_reclaimed` | A kept Job is untouched. A leased Artifact survives while its Job's other expired rows go. `lease_all` finds leases in nested inputs and ignores other strings |
| `…::an_unexpected_entry_or_timestamp_refuses_before_anything_is_reclaimed` | A stray root file, or an invalid clock, reclaims nothing |
| `…::the_sweep_runs_over_a_tree_the_trace_census_refuses` | With 4100 more (empty) Job directories, the guard's Trace census refuses, and the sweep still reclaims the six lapsed rows |
| `…::a_job_that_does_not_verify_stops_the_sweep_there` | A payload rewritten at its length stops the sweep at its Job, after the Job before it. An unparsable deadline refuses, even on a pinned row |
| `tests/artifact_retention.rs`: `only_what_the_census_proves_settled_and_nothing_an_active_job_leases_is_reclaimed` | Real analyzer Jobs admitted and cancelled through the Rust owners over the analyzer oracle's source Artifact. Kept: a non-terminal Job, a Job owing a cleanup, a cancelled Job with a torn journal, an unexplained Job directory, and the source that active Jobs lease. Reclaimed: a settled Job's and an unowned directory's rows. Once the active Job settles and the debt is settled, their rows go; the torn Job still keeps the source |
| `…::an_unreadable_cleanup_ledger_reclaims_nothing` | An undecodable ledger refuses the whole sweep |
| `tests/import_upload.rs`: `the_retention_sweep_reclaims_a_released_import_at_its_deadline_and_keeps_its_history` | A released Import goes at its release deadline, not a second before; an unreleased one stays pinned however late. Afterwards the Import record, its receipt and an idempotent release retry across a restart remain. Its Artifact listing is empty, and inspecting the reclaimed Artifact is `resourceNotFound`, matching Swift's `finishImportReleaseIfNeeded`, which already allows for retention having reclaimed the Artifact |
| `agentd/tests/artifact_retention_process.rs` (real daemon) | Before its first answer, the daemon has swept: `artifact.quota` counts only the kept bytes, the lapsed payload is gone, a future-dated row and a pin stay. Stdout is `reclaimed 1 expired artifact(s)\narkdeck-agentd stopped\n`, and a restart prints nothing more. A Job whose payload no longer verifies makes the daemon print the failure, still serve, and reclaim nothing after that Job |

## Local targeted checks

Run again on the head rebased onto `2af5c806`, whose new main commits change both crates
(#2028, #2032, #2033, #2034). The same checks passed on `7b5872f1` before the rebase (438 tests).
Logs are under this session's scratchpad `logs/`. `arkdeck-soak` is the one other crate that
depends on `arkdeck-hoststore`.

| Command | Exit | Log SHA-256 |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `e3b0c442…` (empty) |
| `CARGO_BUILD_JOBS=2 cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets --locked -- -D warnings` | 0 | `ce7435d7…` |
| `CARGO_BUILD_JOBS=2 cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --locked`: 58 test binaries, 440 passed, 0 failed, 12 ignored | 0 | `d6693220…` |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh`: 0 errors, 0 warnings | 0 | `77c17376…` |

## CI

The PR's CI (`guard` + `swift`) is the unified gate. Its run ids and conclusion are recorded by the
next slice or a documentation follow-up, as the coordination rule of 2026-09-19 asks.

## Not run

Any device, real HDC, installed Runtime or Swift daemon; the manual Swift/Rust harnesses above; a
runtime (non-startup) sweep, which Swift does not have either.
