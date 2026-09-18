# Rust Import lease lifecycle — macOS

Implementation worktree: `agent/rust-import-lifecycle-20260919`, initially based on
publication commit `c01b23d17596e50be207a30cdccdbf96318e6f59`. This is host implementation
and isolated fixture evidence, not hardware acceptance. Final validation is pending.

## Ownership and behavior

- Exact Import leases are recognized only in Catalog-declared Artifact input slots.
  The Import owner verifies its committed receipt, immutable Artifact identity,
  binding, publication status, retention, length and digest before materialization.
  Generic Job Artifact lease resolution continues to reject Import ownership.
- A private RAII hold bridges materialization through durable Job admission and
  journal initialization. Every return path releases that transient hold. A
  durable Job input, rather than a separately persisted reference counter, protects
  the input after process restart. A retry resolves its original idempotency entry
  before acquiring another hold or reading a changed tool.
- Release holds the Import lifetime mutex and the complete Job activity census
  through its durable closing checkpoint. The lock order is Import lifetime,
  transient-use registry, Job activity, then Artifact retention. Job insertion
  never acquires Import ownership while holding Job activity.
- The census validates every SQLite row, including unrelated terminal history,
  before considering its state. Current Catalog inputs use their typed slots;
  another Catalog conservatively retains lease-shaped strings and arrays.
  Terminal Jobs with unknown outcomes remain active. Invalid history fails closed.
  Rust's record-before-SQLite persistence window is checked against the on-disk
  record; a known terminal directory additionally requires an exact-identity,
  finalized journal with no uncertain/outstanding effects or torn tail.
- Submission verification follows Swift `RuntimeJobRecord.hasVerifiedSubmissionFingerprint`:
  canonical typed `originalSubmissionRequest` (or the exact stored request when no
  original exists) must hash to the SQLite fingerprint. With an original, all
  execution fields must match it except Runtime-added authorization. Rust reuses
  `OperationRequest::canonical_bytes`/`fingerprint`, including the existing
  Foundation-compatible `session_json` encoder; it does not hash ordinary JSON.
- The durable generation-3 release receipt closes the lease before metadata unpin.
  Recovery finishes only that receipt's original bounded deadline, never deletes
  bytes or recreates a reclaimed pin/payload. Generation-2 retries return the same
  receipt. New input use refuses released owners. Historical Artifact reads remain
  available under their original sensitive-access rules and advertise no lease.
- The daemon and host analyzer runner share one Import owner. CLI inspection and
  release consume the existing typed contracts. No capability, trusted Target
  fact, device operation, recovery proof or signing policy changes here.

## Verification in progress

Targeted owner tests already exercised release idempotency and historical reads,
both release checkpoint/unpin failure windows, a barrier-controlled materialization
versus release race, durable admission and restart reference retention, and active,
unknown-terminal, terminal, foreign-Catalog and corrupted submission history.
Targeted results (2026-09-19, `--jobs 2`, `RUST_TEST_THREADS=2`):

- `cargo test -p arkdeck-hoststore --test import_upload`: 30 tests passed.
  Includes simultaneous release receipts, retention drift after release checkpoint,
  original/altered/enriched submission fingerprints, unfinished and wrong-Artifact
  input refusal. The restarted admission test additionally verifies on-disk record
  drift and an orphan Job directory fail closed; its final rerun passed.
- `cargo test -p arkdeck-hoststore --test import_upload sigkill_after_release -- --nocapture`:
  passed both real subprocess SIGKILL windows (0.40 seconds): after the durable
  release checkpoint and after metadata unpin. Fresh owners recover the same
  receipt/deadline with the lease closed. The child-only fixture is ignored during
  ordinary test discovery and invoked explicitly by this test.
- `cargo test -p arkdeck-cli --test import_resources`: 11 tests passed, including
  exact release owner/generation/deadline response validation.
- `cargo build -p arkdeck-cli -p arkdeck-agentd` followed by
  `cargo test -p arkdeck-agentd --test import_publication_process -- --nocapture`:
  passed. Real CLI commands and separate daemon processes exercise all three Import
  formats, restart/lost commit reply, plan and admission from an Import lease, active
  reference rejection of release, restart, and successful host analyzer execution.
  After known completion, all three imports release and retry across another daemon
  restart; Artifact history remains readable and advertises `lease: null`.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-cli --all-targets -- -D warnings`:
  passed. No timeout was increased.

The final repository-wide unified gate is pending; these targeted results are not
reported as its completion.

The native Swift behavior is in `RuntimeImportReferences.swift`,
`RuntimeArtifactStore.acquireImportInputs/releaseImport/finishImportReleaseIfNeeded`,
and `ImportLifecycleContractTests`. In particular its authorized-Job test proves
that authorization enrichment preserves the original canonical submission hash,
while missing or altered original/execution requests cannot clear references.

## Remaining product boundaries

This slice does not deploy HAP/native libraries or execute device mutations. The
host process test's isolated analyzer is an explicit test fixture, never a real
GJ result. Device capability admission, deployed workflows, workspace execution,
installed-runtime cutover and real-device GJ acceptance remain independent work.

## Terminal-directory census follow-up

On the lifecycle branch after merging protected main `98cb3b96`, inspection and
release now reject any terminal SQL Job whose complete durable Job directory is
missing. Rust admission/cancellation/execution create and advance the Journal
before recording a terminal state; no production Job-directory reclamation path
exists. Swift's persisted-row census is not evidence that a missing Rust Journal
safely closes the Rust record-before-SQL crash window.

The regression creates an actual isolated host Job through `JobAdmitter`, cancels
it with `JobCanceller` and publishes its Session, first observes clear references,
then deletes the entire Job directory and reopens the durable owners. Both
inspection and release refuse with `recordUnreadable`; the committed receipt and
Artifact retention remain unchanged. Synthetic terminal-only SQL rows (including
unknown-outcome rows) now also refuse instead of bypassing this proof. No locks
or guards were added: Import lifetime → uses → Job activity order is unchanged;
`ImportUse::drop` still acquires only the uses mutex.

Validation: `RUST_TEST_THREADS=2 cargo test -p arkdeck-hoststore --test import_upload
--jobs 2 -- --nocapture` passed: 32 tests, zero failures, one intentionally ignored
SIGKILL child fixture (exercised by its parent test), 4.74 seconds. This is targeted
host validation, not the pending unified gate or real-device acceptance.
