# TASK-XPA-014 — recovery port, slice 3b: the Rust superseding-recovery-epoch store

Change: CHG-2026-074-shared-rust-runtime-core@r11. Second half of slice 3 of the recovery port the
maintainer ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`): Swift's `RuntimeSupersedingRecoveryStore`
ported unchanged, replaying the oracle slice 3a recorded (`recovery-epoch-oracle-run.md`).
Host-local only: no device, no HDC, no daemon process.

Base: protected main `74c3b2b1` (#2016). Branch `agent/xpa-014-recovery-epoch-20260919`, stacked on
`agent/xpa-014-recovery-epoch-oracle-20260919` (slice 3a, which adds the fixture this slice
reads). Once 3a merges, this branch is rebased onto main with only its own commit. No Swift file
changes here.

## Already on main / delivered here / remaining

| Already on main | Delivered here | Remaining |
| --- | --- | --- |
| `job_owner.rs` probes whether the epoch document exists; `job_result.rs` degrades a Job's evidence whenever it does | `recovery_epoch.rs`: list and append as Swift's store does, byte for byte; the Job owner reads which Job an epoch names as its recovery; evidence degrades only on an unreadable document or an epoch naming the Job | The capability lineage gate's skip of a superseded Job (`validateNoUnresolvedMutationLineage`), `isCurrentJob` and the Job projections' epoch fields: their schemas pin `recoveryEpochId`, `supersededByRecoveryEpochId` and `recoveryEpoch` to null, so Swift-recorded frames come first |
| `mutation_state_continuity.rs` (Swift `RuntimeStateContinuity.requireMutationState`) refuses mutation outside the account's default root or when history there lost its capability checkpoint | The store opens the Job store's own state root, the root continuity already pins | The writers: DEC-016's `completeOverwriteAdmission` and the finalize branch's `establishSupersedingRecoveryEpoch` (M4 flash path); restart replay's `finalizing → recovered` on a matching epoch (slice 2) |

## The store

`rust/crates/arkdeck-hoststore/src/recovery_epoch.rs` (macOS, as the Job owner is):
- `list_recovery_epochs(root)` and `append_recovery_epoch(root, draft)` take the Job store's
  `HostDirectory`. Both hold `.superseding-recovery-epochs.lock` (`wait_lock`: created 0600, owned,
  single-link, `mode & 077 == 0`, `flock`), as Swift's `withExclusiveLock` does.
- Load reads `superseding-recovery-epochs.json` with `HostDirectory::read` (no link followed,
  owned, single-link, `mode & 077 == 0`, at most 1 MiB); absent is empty. It decodes as Swift's
  plain `JSONDecoder` does (every named member of its type, any other member ignored), refuses a
  schema version other than `1.0.0`, validates every epoch (`invalidEpoch`) and checks the chain
  (`corrupt`).
- Append validates the draft before the lock; returns the stored epoch for the same recovery Job,
  intent and covered set when every member matches and refuses a drifted one (`conflictingEpoch`
  naming it); derives the epoch identity from its content and refuses one already taken; chains
  to the last epoch's digest; and rewrites the whole document with `canonicalPretty` through
  `replace_document` (Swift `createOrReplaceAtomically`).
- Strings compare as Swift's `String` does (`same_text`, `text_key`): a draft's equality, the
  covered-intent and effect sets, and `covers`.

**Continuing from the highest existing count** (task §4 wording). Swift keeps no counter: an
epoch's identity is derived from its content and the chain continues after the last epoch in the
document. The store therefore continues any chain it finds in the root it is given; the
`continue-chain` step of the oracle and `a_reopened_store_continues_the_chain_it_finds` pin it.
The rule that a new directory cannot make the same device's intents, reservations and outcomes
disappear stays where it is: `mutation_state_continuity.rs` already refuses a mutation owner
outside the account's default root, and the store opens the Job store's root. A lost document
only re-blocks unknowns an epoch had superseded, which fails closed; nothing new is built for it.

**Evidence.** Swift's `evidenceSnapshot` lists the epochs for every snapshot and fails the read
when they are unreadable; its `recoveryEpoch` is the last epoch whose recovery Job is the Job. The
Rust reader now:
- leaves the evidence whole when no document exists (Swift's read would also create the lock, an
  incidental T2 file this read does not create) or when no epoch names the Job;
- degrades it to `recordUnreadable` when the document is unreadable (as before, and as Swift's
  read fails), or when an epoch names the Job as its recovery Job: the published evidence schema
  pins `recoveryEpoch` to null, so that answer cannot be given yet.
No checked-in oracle store holds an epoch document, so no existing replay changes.

## Tests

- `tests/recovery_epoch.rs`, 2 tests:
  - `the_store_answers_and_leaves_the_files_swift_left`: every step of the oracle (count asserted
    `>=` 32) on the root it names, seeded as Swift seeded it; every answer equal to Swift's and,
    after every step, the root's file names, modes, link counts, sizes, digests and bytes equal to
    Swift's.
  - `a_reopened_store_continues_the_chain_it_finds`: a second store instance chains after the
    first epoch, writes Swift's two-epoch document, and appending the same relation again writes
    nothing.
- `recovery_epoch::tests::the_job_store_reads_which_job_an_epoch_names_as_its_recovery`: no
  document names no Job and creates no lock; the oracle's two-epoch document names its two
  recovery Jobs and not the Jobs they cover; a document open to others is `corrupt`.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI. Locally, with
`CARGO_BUILD_JOBS=2`:

| Command | Exit | Result |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | clean |
| `cargo clippy -p arkdeck-hoststore --all-targets -- -D warnings` | 0 | clean |
| `cargo test -p arkdeck-hoststore` | 0 | 352 passed, 0 failed, 12 ignored, 44 test binaries |

Log: scratchpad `logs/checks-s3b.log`, SHA-256 `5791ec9a0d140c64ec2a3efefeacba6b754407cf5ae00d55c6286b3744a9fa19`.

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2025 (stacked on 3a) | `03f92813` | 35444472234, 35444472281, 35444472520 | 11 checks passed, `app-build` skipped; merged as `0e78428f`, carrying slice 3a with it |

## For the maintainer

- The store's decoder is lenient as Swift's is (3a's record): a member neither type names is
  ignored and dropped on the next append.
- `recovery_epoch_names` makes an epoch naming the Job degrade its evidence rather than answer
  `recoveryEpoch: null`, because Swift would answer it non-null. Answering it needs the frames
  and schema widening listed under Remaining.
