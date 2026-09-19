# TASK-XPA-014 — recovery port, slice 3a: the superseding-recovery-epoch Swift oracle

Change: CHG-2026-074-shared-rust-runtime-core@r11. Slice 3 of the recovery port the maintainer
ruled on 2026-09-19 (design §L.1 item 13; the Ruling section of
`evidence/adr-0009-decision-package-20260914.md`). This half records, from Swift, the oracle the
Rust store (slice 3b) replays, so that 3b changes no Swift file (r11 rule 10). Host-local only: no
device, no HDC, no daemon, no Job.

Base: protected main `74c3b2b1` (#2016). Branch `agent/xpa-014-recovery-epoch-oracle-20260919`,
no stack. Files:
- `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RecoveryEpochOracleContractTests.swift` (new);
- `rust/tests/fixtures/recovery-epoch/` (new: `cases.json`, `provenance.json`, the root's files after
  each of 32 steps);
- this record.

No Rust, production Swift, Catalog, spec, schema or control-frame change.

## Carrier and what was missing

The package names `Sources/ArkDeckStorage/RecoveryCoordination.swift` twice: §1c ("epoch never
rewrites the Job", lines 93–96) and §2 (`SupersedingRecoveryEpoch` 93–129, `append` 185–253,
`load` 274–300). The file is byte-identical on `74c3b2b1` and `6cf99fb6`.

`RuntimeSupersedingRecoveryStore`, re-read on this base:
- **Files**: `<state directory>/superseding-recovery-epochs.json` and
  `.superseding-recovery-epochs.lock`, beside the Job store.
- **Format**: one document, `{"epochs":[…],"schemaVersion":"1.0.0"}`, rewritten whole on every
  append with `CanonicalJSONEncoders.canonicalPretty()` through
  `DurableFileWriter.createOrReplaceAtomically`. A first epoch has no `previousEpochSHA256` member.
- **Chain**: `epochSHA256` is the SHA-256 of the compact canonical encoding of the epoch without
  it; `previousEpochSHA256` is the preceding epoch's. `epochID` is `recovery-epoch-` and the first
  32 hex digits of the SHA-256 of identity, recovery Job, recovery intent and uncertain-effect
  digest, newline-joined: derived from content, not counted.
- **Append**: the draft is validated before the lock; the same recovery Job, intent and covered
  set returns the stored epoch when every member matches and is refused as
  `conflictingEpoch(<that epoch>)` when any differs; an identity already taken by another relation
  is refused the same way.
- **Load**: under the lock, the document must be an owner-only (`mode & 077 == 0`),
  single-link regular file of at most 1 MiB, opened through no link; a plain `JSONDecoder`
  decodes it; every epoch is validated again (`invalidEpoch`) and its chain checked (`corrupt`).

Rust has no store: `job_owner.rs` only probes whether the document exists, `job_result.rs`
degrades evidence whenever it exists, and the capability lineage gate never skips a superseded
Job. No recorded epoch file existed in the repository.

## The oracle

One store, then one seeded root per load refusal. Every step names the root it ran on (`main`,
or a root of its own) and, when it created that root, how it seeded it (`document` names the step
whose recorded document the root held, plus any widened mode, hard link, padding or open lock).
After every step the oracle records the answer and, for every file in the root, its mode, link
count, size, digest and (up to 64 KiB) bytes.

| Steps | Answer |
| --- | --- |
| `list-empty` | no epochs; the lock is created 0600, the document is not |
| `append-first`, `append-first-again` | the same epoch twice, no predecessor; the document is written once |
| `append-drifted-proof`, `append-identity-taken` | `conflictingEpoch`, naming the first epoch; nothing written |
| `append-second` | a `distinctRecoveryExecution` epoch chained to the first |
| 10 `invalid-*` drafts | `invalidEpoch` before the lock; nothing written |
| `list-two` | both epochs |
| `load-changed-material`, `-reordered`, `-first-removed`, `-schema-version`, `-epoch-member-missing`, `-not-json` | `corrupt` |
| `load-invalid-epoch` | `invalidEpoch` (validation precedes the chain check) |
| `load-epoch-member-unknown`, `load-document-member-unknown` | both epochs: the decoder ignores a member it does not name |
| `load-document-mode-0644`, `-linked`, `-oversized`, `lock-mode-0644-list`, `-append` | `corrupt` |
| `continue-chain` | a third epoch chained to the second, on a root seeded with the two-epoch document |

Message text is T2 and is not recorded, except the epoch identity a conflict names.

**For the maintainer.** `load-epoch-member-unknown` pins what Swift does today: a member the
epoch type does not name is dropped on decode and is not part of the material, so it passes the
hash chain, and the next append rewrites the document without it. Unlike the Journal, Artifact
and capability readers listed in design §G.2, this reader is not strict. The Rust port keeps it
as Swift has it; tightening it would be a Swift-side change first.

## Determinism

The scratch root is a fresh temporary directory; nothing in the recorded bytes depends on it.
Drafts are literals, `establishedAtUTC` included. Two recordings are identical byte for byte, and
with the fixture installed the test compares every file.

## Local targeted checks

Per `AGENTS.md` on main `d732e798` (#2015) the unified gate is the PR's CI; locally:

| Command | Exit | Result |
| --- | --- | --- |
| `ARKDECK_RUST_RECOVERY_EPOCH_RECORD=/private/tmp/arkdeck-recovery-epoch-oracle-r3 sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RecoveryEpochOracleContractTests` | 0 | 1 test, 0 failures (r1 and r2 recorded the same steps before each step named its root; their step files are identical to r3's) |
| the same into `…-r4` | 0 | 1 test, 0 failures; `diff -r` r3 r4 empty |
| `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter RecoveryEpochOracleContractTests` (fixture installed) | 0 | 1 test, 0 failures |

## CI

| PR | Head | Runs | Result |
| --- | --- | --- | --- |
| #2019 | `00e2a23d` | 35444238334, 35444238376, 35444238588 | 11 checks passed, `app-build` skipped; closed unmerged, because #2025 (stacked on it) was squash-merged first and carried this slice's content into main as `0e78428f` |

## Not in this slice

- The Rust store and its readers (slice 3b): the lineage gate's skip of a superseded Job, the
  evidence degradation only on an unreadable document, and the Job projections' epoch fields
  (their schemas pin them to `null`, so frames come first).
- The writers: DEC-016's `completeOverwriteAdmission` and the finalize branch's
  `establishSupersedingRecoveryEpoch` belong to the M4 flash path.
