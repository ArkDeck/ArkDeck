# TASK-XPA-014 — the Rust daemon lists the cleanup debt ledger as Swift's `cleanupDebt.list` does: every record not settled, in Swift's order, each with its residue's identity and whether a retry started (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `3e95ac6d` (#2041). The slice was written
over `282d1bdc` (#2035) and moved onto main after #2033–#2043. `cleanup_debt.rs` conflicted with
#2039's `outstanding_jobs`, which sits beside the new list; both were kept. This is the first of two
slices of `cleanupDebt.*` (M2, GJ-2/3), the list. The second, `cleanupDebt.continue`, loads a
continued Job the way restart recovery does: Swift's `continueCleanupDebt` calls
`recover(records:)` for a Job that is not resident, and every terminal Job is not resident. The
maintainer's ruling on design §L.1 item 13 (#2016) orders "the recovered row of
`cleanupDebt.continue`" after the four recovery slices. The recovery port's session is bringing that
per-Job recovery in its slice 2b (`job_recovery.rs`, `recover_jobs`). Both sessions agreed that the
continuation follows it and that this slice adds no continuation semantics. Every answer compared
here is replayed from Swift's oracles and the committed control frames. The ledger is read from
fixed-root host fixtures. None of it is device evidence or installed-Runtime activation
(POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`cleanupDebt.*`) |
| --- | --- | --- |
| The ledger `cleanup-debt.json` as the debug HAP runner (#2005) and the native runner (#2027) write it; `job.result`'s outstanding cleanup rows and `doctor --deep`'s count over it; the schemas and control frames of both methods | `cleanupDebt.list` in the daemon: Swift's `listCleanupDebt` and `encodeCleanupDebt` over the ledger. The ledger decoder now keeps a persisted action with extra members, as Swift's decoder does. The three device oracles' lists and the committed corpus are replayed through it. The CI rows of #2011 and #2027 are added to their run records | `cleanupDebt.continue`, with the recovered row, once the recovery port's per-Job recovery lands; the continuations of the debug HAP and native oracles, and the lists after them; CLI `recovery cleanup` / `cleanup-debt list\|continue` |

## Why

A failed cleanup leaves a remote path or an installed bundle behind. The runners owe it in the ledger.
Until now nothing in the Rust daemon listed the ledger, so an operator could not see what is owed
except through the counts in `job.result` and `doctor`. Swift's list needs no recovery and writes
nothing, so it can ship before the continuation.

## What changes

- **The list** (`cleanup_debt.rs`, `list_cleanup_debt`; Swift `listCleanupDebt`,
  `encodeCleanupDebt`): the ledger decoded whole, as Swift decodes `[CleanupDebtRecord]`.
  - **What is listed.** Every record without `settledAtUTC`, ordered by Job, then remote path (empty
    for a bundle), then when it was owed. Equal keys keep the ledger's order.
  - **Each row.** `jobId`, `stepId`, `remotePath`, `bundleName` (or `null`), `identity` (the path, or
    `bundle:<name>`), `reason`, `recordedAtUtc`, and `retryOutcomeUnknown`: true once a retry's
    outcome was left unknown or a retry ever started.
  - **Refusal.** A ledger that cannot be read or decoded refuses the whole list with the store error
    Swift renders, `indexCorrupted("undecodable cleanup debt ledger: …")`. Swift wraps every failure
    to read or decode the ledger that way, so the reader's own read failure now carries the same
    prefix. That text reaches no other caller: the runners discard it.
- **The decoder.** A persisted action with members beside `kind` and `arguments` now decodes, and
  those members are dropped. Swift's synthesized `Codable` reads the ledger this way. Before, such a
  record made the whole ledger undecodable in Rust.
- **The daemon.**
  - `arkdeck-control` routes `cleanupDebt.list` to a new `HostServices::cleanup_debt`. Its default is
    the read-only foundation's refusal, as before.
  - The isolated host answers from its Artifact owner and maps a store failure to `internalError`,
    as Swift's handler does.
  - The answer passes the compiled method schema like every other.
- **The replays.**
  - The shared harness `tests/support/hdc_oracle.rs` now replays the oracles' list before their
    continuations. It skips `cleanupDebt.continue` and the lists after it: the debug HAP replay
    answers 60 exchanges (59 before), the native one 38 (37).
  - The screen-sequence replay answers its empty list through the owner instead of asserting it (51).

## Checks

- `tests/debug_hap_run.rs` and `tests/native_library_run.rs`, through the shared harness:
  - Each oracle's `debt.list`, recorded after its runs and before its continuations, is answered as
    Swift answered it: the debug HAP's two debts (the staging path of `cleanupDebt` and the bundle of
    `stillInstalled`, listed by Job) and the native one (the staging path of `cleanupFailure`).
  - Everything else the replays check is unchanged: the fake's calls, every file byte for byte, and
    the continued Jobs and the ledger as they stood before the continuations.
- `tests/screen_sequence_run.rs`: its `debt.list` answers `[]` through the owner, and every one of its
  51 exchanges is replayed.
- `cleanup_debt.rs` unit tests:
  - the projection's order, filter and fields: two Jobs, a settled record, a started retry and an
    unknown one, and two bundle debts with equal keys that keep the ledger's order;
  - a missing ledger owes nothing;
  - an undecodable one refuses the whole list with Swift's rendering;
  - a persisted action's extra member is dropped.
- `arkdeck-agentd` `cleanup_debt_control.rs`, through the control layer against the daemon's own host:
  - Each of the three frames of the committed `cleanupDebt.list.jsonl` corpus is answered from a
    ledger that owes its rows. The rows are owed in reverse order beside a settled record.
  - The empty frame's list creates no ledger.
  - A host without an Artifact owner is refused as the read-only foundation.
  - An undecodable ledger answers `internalError` with Swift's store error and no details.

## Local targeted checks

Per `AGENTS.md` since #2015, the unified gate is the PR's GitHub CI. Locally, only targeted checks
ran, in this worktree with its own `rust/target` and `CARGO_BUILD_JOBS=2`. The logs are in
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-native-library-plan-admit-run-ddd5a8/0a1d0f2a-9a16-4e9a-9a87-e55bd44a6bc7/scratchpad/logs/`.

On the rebased head over main `3e95ac6d`, on 2026-09-19 22:24–22:29 CST. The load at the start was
45/54/61. The log is `cleanup-debt-list-targeted-r3.log`, SHA-256
`ba87fe2f86c8d89fa51ee9871b29ca7a5a2a3e0028969842de903474e5e58b57`.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Clippy | `cargo clippy --locked -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | Clean |
| The changed crates | `cargo test --locked --no-fail-fast -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd` (after `cargo build --locked -p arkdeck-cli`, which `import_publication_process` spawns) | 0 | 462 passed, 0 failed, 12 ignored in 58 suites, including `debug_hap_run` 7/7, `native_library_run` 4/4, `screen_sequence_run` 2/2, `artifact_retention` (#2039), `arkdeck-control` `read_only` 19/19 and the five new tests |
| Records | `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings, 121 acceptance IDs; `check_union_merge: ok` |

Two earlier runs used the same commands over `282d1bdc`, before the rebase:
- `cleanup-debt-list-targeted-r2.log`, 22:16–22:21: exit 0, with 451 passed, 0 failed and 12
  ignored in 56 suites.
- `cleanup-debt-list-targeted.log`, 22:03–22:16: three new tests failed with `host snapshot
  refused`, and every other suite passed, the three replays included. The tests had written their
  ledgers with `fs::write`, which gives mode 0644. The host store reads only owner-only files, as
  the Runtime writes them. The tests now set 0600.

## CI

PR #2047, head `a54c4852`, all green. It merged on 2026-09-19 as `aec690f2`.

| Check | Run | Conclusion |
| --- | --- | --- |
| SDD Guard `guard` | 35448949866 | success |
| Swift CI `plan` | 35448949993 | success |
| Rust host-independent checks | 35448949993 | success |
| Rust workspace, `ubuntu-latest` | 35448949993 | success |
| Rust workspace, `macos-26` | 35448949993 | success |
| Rust workspace, `windows-latest` | 35448949993 | success |
| `swift` aggregate | 35448949993 | success |

`swift-tests`, `app-build` and `ds-interactions` were not selected for this diff and were skipped.
These rows were added by the `cleanupDebt.continue` slice, since the PR merged as soon as it was
green.

## Not run

- `cleanupDebt.continue` and the continuations of the two device oracles. They follow the recovery
  port's per-Job recovery, as #2016 orders; the next slice replays them, the recovered row
  included.
- The CLI's `recovery cleanup` and its `cleanup-debt list|continue` alias (XPA-018).
- The dashboard. Its routed-method count is regenerated by the dashboard's owner, and it does not
  change here. Its pattern `"([a-z][a-z.-]+)"` does not match a camel-case method name such as
  `cleanupDebt.list`. The coordinating session will widen it to `[a-zA-Z][a-zA-Z.-]+` at the next
  recount and backfill this route.
- Any device, real HDC server or the installed Runtime.
