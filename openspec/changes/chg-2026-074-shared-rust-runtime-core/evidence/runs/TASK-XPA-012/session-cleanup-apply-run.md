# Rust Session cleanup apply owner

The existing `session.cleanup.apply` method and CLI leaf delegate to the Rust
Session owner. Both cleanup methods directly use the configured `Host.jobs`
owner's `JobStore::with_active_sessions`; there is no injected activity callback.
The guard stays held through exact preview comparison, applying intent, anchored
removal, catalog reconciliation, and durable result publication.

The census strictly decodes every current SQLite Job row. Nonterminal and
`outcomeUnknown` Jobs retain both their `session-{jobId}` identity and any Session
whose validated manifest associates that Job. Directory census is bounded to
100,000 entries: unindexed or unsafe Job directories refuse cleanup. An indexed
Job directory is conservatively retained, including terminal index states,
because journal reconciliation has not migrated yet. No new durable format or
authority semantics are inferred. Missing, unreadable or unsupported inventory
never becomes an empty active set; all such refusals precede Session deletion.

Cleanup compares the exact durable preview tuple, expiry, policy and catalog
generations, pins, Artifact references and current active set. It holds the
configuration and catalog locks while preparing the removal. The selected
Session's complete directory membership, owned same-volume identities, file
link counts, sizes, timestamps and SHA-256 values are captured before intent.
Symlinks, hardlinks, unsafe permissions, changed bytes, late entries and replaced
ancestors refuse. Retained descriptors restrict deletion to the selected Session
descendants; calendar directories and neighboring Sessions survive.

A proven stale snapshot before the first unlink can restore ready. An uncertain
intent, deletion, catalog publication or missing result stays applying and
returns `outcomeUnknown`; restart never replays that preview. Applied previews
return their exact stored receipts. CLI transport, schema and semantic failures
for apply remain unknown and do not enable automatic replay.

## Current validation on f92acd36

The isolated branch is `agent/xpa012-session-apply-main-20260912`, based on the
published Job/Artifact owner merge. The frozen apply implementation was reused
from `d602ca6329a3caa1a8523fa75813683ee88057bc` and composed with that actual owner.

- Session host-store library: 53 passed, including 7 cleanup apply tests for
  active/pin retention, manifest Job association, tuple/expiry/policy drift,
  proven zero-unlink stale release, interrupted intent, missing result,
  anchored unsafe-content/root replacement, restart receipt and empty plan.
- Job owner integration: 6 passed, including the complete activity census,
  malformed row refusal, indexed durable-history retention and orphan/unsafe
  Job directory refusal before the action is entered.
- Daemon Host: 2 passed with actual JobStore instances, including missing owner
  refusal, replaced database refusal and preview/apply reachability.
- CLI: 8 Session unit tests and all 11 current-surface integration tests passed,
  including exact tuple correlation and non-retryable lost/malformed replies.
- The Rust daemon and CLI debug build passed. Targeted output is retained at
  `/private/tmp/xpa012-session-apply-targeted-r1.log` (the initial dependency
  compilation lines precede that captured log).
- Actual process harness passed: 27 control exchanges plus Rust CLI commands,
  with nondefault manifest association, default identity, running Job,
  terminal unknown outcome, retained durable history, Job drift conflict,
  orphan and unsupported row refusals before deletion, pinned retention,
  exact removed Artifact identity/accounting and restart receipt equality.
  Log: `/private/tmp/xpa012-session-apply-process-r1.log`; exact recorded replies:
  `/private/tmp/xpa012-session-apply-process-frames-r1.jsonl`; actual durable
  result: `/private/tmp/xpa012-session-apply-process-applied-r1.json`.
- Rust formatting, Python harness syntax, generated-checkout contract check,
  and diff whitespace checks passed.

## Native producer provenance

The four current Swift producer/readback tests previously passed in the
coordinated native run, with zero failures in
`/private/tmp/xpa-native-union-swift-r1.log`:

- `testCurrentSwiftOwnerReadsActualRustCleanupAppliedRecord`
- `testCleanupApplyProducerRecordsExactTupleAndArtifactReceipt`
- `testCleanupApplyProducerRecordsPartialDeletionAndRefusesReplay`
- `testCleanupApplyProducerRecordsUnavailableAndUnreadableOwners`

`session-cleanup-producer-frames-macos-20260912/` retains the complete original
combined recording, nine original `session.cleanup.apply` lines, and provenance
with SHA-256 values and the exact producer-source hashes. These hashes match the
unchanged Swift test and Rust-applied-record fixture in this branch. Derivation
used only these nine lines plus the method's existing corpus, without rewriting
fields or pulling unrelated methods into this change. The checkout manifest uses
version 2 and contains 105 methods and 580 recorded shapes; the published view
continues to use the merge-base with `origin/main`.

The checked-in `rust-cleanup-applied.json` fixtures remain unmodified output
from the original real Rust owner test; simulated Session inputs are not
hardware evidence. Set `ARKDECK_CLEANUP_RECORD_COPY` when running the cleanup
owner test to preserve another actual record. The process harness also accepts
`--record-applied-copy`, `--record-store-copy`, `--record-frames` and `--cli-path`.

## Coordinated remaining checks

Descriptor-removal tests and warnings-denied Clippy await the shared build
schedule. The first platform filter `host_session_removal` selected zero tests;
the correct filter is `session_removal`, and no platform pass is claimed from
that empty run. Current Swift CLI process consumption and the final unified
Swift/App gate remain with the main agent. No installed activation, real-device
execution, replay, Task completion or new scope authorization is claimed here.
