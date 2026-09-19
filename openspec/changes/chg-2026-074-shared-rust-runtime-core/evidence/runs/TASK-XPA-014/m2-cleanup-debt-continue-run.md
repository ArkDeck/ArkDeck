# TASK-XPA-014 — the Rust daemon continues a cleanup debt as Swift's `cleanupDebt.continue` does: the Job loaded as recovery loads it, the residue judged by a read-only readback, one durable retry under the use the Job consumed (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `4680288a` (#2071). This is the second of two slices of
`cleanupDebt.*` (M2, GJ-2/3). The first, the list, merged as #2047. The maintainer's ruling on design
§L.1 item 13 (#2016) orders "the recovered row of `cleanupDebt.continue`" after the recovery port's
four slices. This slice follows the per-Job recovery that the port's slice 2b brought
(`job_recovery.rs`, `recover_jobs`, #2071). While 2b was unmerged, the slice was written over
a local copy of it and moved onto main once 2b merged. Every answer and file compared here is replayed
from Swift's debug HAP and native-library oracles and the committed control frames, recorded over the
shared fake HDC in a fixed-root host fixture. None of it is device evidence, installed-Runtime
activation or GJ-2/3 acceptance (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (`cleanupDebt.*`) |
| --- | --- | --- |
| The ledger as the HAP (#2005) and native (#2027) runners write it; `cleanupDebt.list` (#2047); the per-Job recovery `recover_jobs` (#2071); the providers' readbacks and verdicts (#1951, #1955) | `cleanupDebt.continue`, Swift's `continueCleanupDebt` port. The persisted HDC actions are materialized again (`from_persisted`). The ledger gains its retry's begin, conclusion and settlement. The runner gains the held-use authority check for a Job no run holds. Both device oracles are now replayed whole, and a new test file covers the paths no oracle records | CLI `recovery cleanup` / `cleanup-debt list\|continue` (XPA-018); GJ-2/3 on the isolated daemon (the isolated root has no mutation authority) and on hardware |

## Why

A failed cleanup leaves a remote path or an installed bundle on the device, and the ledger owes it
until a person continues it. The Rust daemon could list the debt (#2047) but not settle it, so the
residue stayed on the device and the Job's residue count stayed up.

## What changes

- **The continuation** (new `cleanup_debt_continue.rs`, a method of `JobRunner`, Swift
  `continueCleanupDebt`):
  - **Parameters.** A remote path names itself, a bundle names `bundle:<name>`, and `jobId` is
    required; otherwise `invalidParams`, as Swift's handler answers. The debt must be outstanding
    for that Job and identity, else `rejected` with `jobNotFound("cleanup-debt:<job>:<identity>")`.
  - **The Job.** A terminal Job whose outcome is known is not resident in Swift's engine, so it is
    loaded through `recover_jobs` with the capability store. A clean journal's record gains
    `recovered: journal clean` and is persisted, and its use's outcome is re-asserted, which
    changes nothing. Any other Job is read as it stands. A Job whose outcome is unknown is answered
    `outcomeUnknown`, "job has an unresolved outcome; cleanup mutation is not resent", and nothing
    is written.
  - **The action.** The debt's persisted action is materialized again and must name the recorded
    residue, as Swift's `cleanupResidue` names it. Otherwise Swift's `internalFailure(…)` is
    returned, as it is for a debt without an action.
  - **The readback first.** The facts must hold for the Target at the Job's binding
    (`validateEvidenceFacts`). The action's read-only readback then runs:
    - confirmed complete settles the debt: "readback confirmed the owned path is already absent";
    - inconclusive stays owed: "path readback inconclusive: …";
    - a readback that cannot run stays owed: "path readback failed: …";
    - only a residue still present goes on.
  - **One retry.** A retry already begun, or one whose outcome was lost, forbids any resend
    (`outcomeUnknown`). Otherwise:
    - the cleanup is lowered, the Job's use is proven again, and the retry is made durable in the
      ledger (`retryAttemptStartedAtUTC`) before it is sent;
    - verified settles the debt: "exact typed cleanup completed";
    - a refuted retry stays owed (`<code>: <detail>`) and clears its attempt, so it may be retried;
    - an unknown or unsupported verdict keeps its outcome unknown for good
      (`…; mutation resend is forbidden`);
    - a dispatch failure answers as Swift's `RuntimeDispatchFailure` renders it.
  - **Settlement.** A settled debt refreshes the Job's residue count and persists its record. The
    Job's journal is never written.
- **The held use** (`mutation_execution.rs`, `continue_held_use`; Swift
  `consumeCapabilityBeforeMutation`'s persisted-evidence arm for a Job no run holds):
  - The mutation owner and a current tool identity are required.
  - The Job's evidence must name its own capability.
  - The fresh typed plan, identity and binding must equal the admitted ones.
  - The mutation state and tool identity are proven again. A debug HAP still `finalizing` or
    `reconciling` also passes Swift's `validateContinuation`.
  - Nothing is consumed.
  - The checks every use shares are one helper now (`fresh_use`), which the runner's consumption
    also calls. Its compensation correlation is one function too (`continuation_correlates`).
  - A Job without evidence is refused. Swift would consume a new use for it, but no Rust runner
    leaves such a Job owing a debt.
- **The ledger** (`cleanup_debt.rs`): Swift's `settleCleanupDebt`, `beginCleanupDebtRetry` and
  `completeCleanupDebtRetry`, with the store's errors rendered as Swift renders them
  (`indexCorrupted`, `ioFailure`, `artifactNotFound`).
- **The providers** (`arkdeck-provider-hdc`): `HapAction::from_persisted` and
  `NativeAction::from_persisted` are Swift `PersistedTypedProviderAction.materialize()` for both
  families.
  - Each reader refuses as its Swift namesake does, in Swift's order: a missing string or integer,
    an optional that is not one, an owned path that no longer matches its components, a package list
    that is missing or malformed.
  - For the native family: an unknown profile, a machine outside `UInt16`, incomplete code-sign or
    helper facts, paths outside the provider-owned namespace.
- **The daemon.** `arkdeck-control` routes `cleanupDebt.continue` beside the list. The isolated host
  continues with the owners `job.run` runs with, and publishes no Session.
- **The replays.** `tests/support/hdc_oracle.rs` replays every exchange of both oracles (debug HAP 63,
  native 40), the continuations in the mode each oracle names over the state its runs left. The
  fake's calls (108, 225) and every file below the root must be Swift's byte for byte, the continued
  Jobs' records and index rows and the settled ledger included. The adjustments the harness made for
  the unreplayed continuations are gone.

## Checks

- `tests/debug_hap_run.rs` (7/7) and `tests/native_library_run.rs` (4/4): the whole oracles.
  - The debug HAP's bundle and path continuations, and the native staging continuation, each answer
    "exact typed cleanup completed" as Swift did, and the lists after them are empty.
  - The fake received Swift's 108 and 225 calls in order. For the native continuation these are the
    five readback `ls -ld`s (211–215) and the ten-command retry (216–225).
  - Each continued Job's record gains `recovered: journal clean` and counts 0 residues, its index
    row advances twice, and the ledger records each retry and settlement, all byte for byte.
- `tests/cleanup_debt_continue.rs` (8), on debts the native oracle's Jobs owe:
  - a residue already gone is settled by the readback alone (five `ls -ld`, no removal, no retry
    recorded);
  - a retry already begun forbids a resend;
  - a refuted retry stays owed with its attempt cleared, and a second continuation settles it;
  - a lost retry keeps its outcome unknown and is never resent;
  - a readback that cannot launch leaves the debt owed and sends nothing;
  - a parked Job is answered without a write;
  - the parameters and the debt are refused before anything is read or sent;
  - without the mutation owner, `recover_jobs` refuses and nothing is written.
- `arkdeck-provider-hdc` unit tests: every HAP and native persisted form materializes back to its
  action, with and without the helper and the code-sign facts, and each refusal is Swift's.
- `arkdeck-agentd` `cleanup_debt_control.rs`, through the control layer against the daemon's own host:
  - the committed `cleanupDebt.continue` refusal frame is answered as recorded;
  - a debt the ledger does not owe is refused with `jobNotFound`;
  - a host without the owners gives the foundation's refusal for both methods;
  - an undecodable ledger gives the store's error for both.
- The contract. Every `cleanupDebt.*` answer the replays and the eight tests give is checked against
  the published method schemas (`assert_conforms`), as the daemon's control layer admits answers.
  This covers each state (`settled`, `outstanding`, `outcomeUnknown`) and each refusal
  (`invalidParams`, `rejected`, `internalError`, never with details). The committed schema
  (`spec/control/methods/cleanupDebt.continue.json`: four required strings) already admits them, so
  no frames are recorded and no schema changes.
- Mutation checks, each reverted, each failing the native replay:
  - without the recovery load (the index row);
  - without the durable retry (the ledger);
  - without the residue refresh (the index row);
  - without the readback (the fake's calls).

## Local targeted checks

Per `AGENTS.md` since #2015, the unified gate is the PR's GitHub CI. Locally, only targeted checks
ran, in this worktree with its own `rust/target` (rebuilt from empty) and `CARGO_BUILD_JOBS=2`, over
main `4680288a`, on 2026-09-20 15:53–16:07 CST. The load at the start was 63/56/44. The log is
`cleanup-debt-continue-targeted-r2.log`, SHA-256
`9fda00d30b58b27fc8aa7c84ac724e61aa6c147c74ac2b4772409a3d103fe5a3`, in
`/private/tmp/claude-501/-Users-fuhanfeng-Dropbox-Code-Github-ArkDeck--claude-worktrees-native-library-plan-admit-run-ddd5a8/0a1d0f2a-9a16-4e9a-9a87-e55bd44a6bc7/scratchpad/logs/`.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Formatting | `cargo fmt --all --check` | 0 | Clean |
| Clippy | `cargo clippy --locked -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | Clean |
| The changed crates | `cargo test --locked --no-fail-fast -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-control -p arkdeck-agentd` (after `cargo build --locked -p arkdeck-cli`) | 0 | 694 passed, 0 failed, 14 ignored in 83 suites, including `cleanup_debt_continue` 8/8, `native_library_run` 4/4, `debug_hap_run` 7/7, `screen_sequence_run` 2/2 and #2071's `job_recovery` 5/5 and `job_reconcile` 1/1 |
| Records | `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings, 121 acceptance IDs; `check_union_merge: ok` |

Clippy also passed for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc` over the whole
workspace before the rebase, where the provider's new decoders compile too. The same checks passed on
2026-09-19 over the local copy of #2071 (640 passed in 78 suites, before this slice's schema
conformance assertions).

## CI

The PR's checks (`guard` and the `swift` aggregate with the rust lane) are the gate. Their run id and
conclusion go into this record with the next slice.

## Not run

- The CLI's `recovery cleanup` and its `cleanup-debt list|continue` alias (XPA-018).
- A continuation beside a run of the same Job: Swift's engine interleaves them at its suspension
  points, and so does this daemon. Neither serializes the residue count's persist against the run's.
- A Job without persisted mutation evidence is refused; Swift would consume a new use for it.
- Any device, real HDC server or the installed Runtime; GJ-2/3 acceptance. The isolated root has no
  mutation authority, so the continuations are proven only in the fixed-root host fixture.
