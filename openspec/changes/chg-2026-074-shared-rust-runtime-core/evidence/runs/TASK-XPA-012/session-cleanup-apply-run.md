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

## Current validation

The Session-only candidate is based on approved main
`1fd85b931fdef1416d41baebfe8bad0cf8d32b5e`, on branch
`agent/xpa012-session-apply-main-20260912`. Additive conflict resolution preserves
current Target resources, Job events and journal support. The original Session
implementation was preserved at `28ccbc13633b043bb6b1b56b222a9d673fba27f1` and
in `/private/tmp/xpa012-maintenance-before-combine-20260912.bundle` before rebase.
This candidate contains no Trace maintenance implementation.

The following focused checks passed on the Session-only candidate:

- 4 platform Session removal tests: first-unlink faults, unsafe links/modes,
  changed bytes/membership, replaced ancestors and neighbor preservation.
- 53 Session host-store tests: active/pin retention, manifest Job association,
  tuple/expiry/policy drift, zero-unlink stale release, interrupted intent,
  missing results, root replacement, restart receipts and empty plans.
- 6 actual Job owner integration tests, including unreadable records,
  indexed durable-history retention and orphan/unsafe directory refusal.
- 2 daemon Host tests, 13 CLI unit tests and 11 current-surface integration
  tests, including receipt correlation and unknown-noReplay behavior.
- Debug daemon/CLI build and five-package Clippy with
  `--all-targets -- -D warnings` (platform, hoststore, control, agentd, CLI).
- 11 current Swift `SessionCleanupContractTests`, including native producer
  success/refusal/partial-result frames and strict readback of a freshly
  captured actual Rust applied record. The readback test's optional
  `ARKDECK_CLEANUP_APPLIED_RECORD_FIXTURE` input preserves the frozen fixture.
- Current Swift CLI product build, followed by separate Rust CLI and Swift CLI
  runs against the Session-only Rust daemon. Each passed 27 actual RPC
  exchanges plus CLI commands, including default/nondefault manifest Job
  identity, active/unknown/durable-history retention, drift, orphan/unsupported
  row refusals, exact Artifact accounting and restart receipt equality.
- Rust formatting, Python syntax, generated-checkout contract and whitespace
  checks. The final complete unified gate is owned by the main integration
  agent; it is not represented by these targeted checks.

Exact commands/results are recorded in:

- `/private/tmp/xpa012-session-only-current-targeted-20260912.log`
- `/private/tmp/xpa012-session-native-current-20260912.log`
- `/private/tmp/xpa012-session-swift-cli-build-current-20260912.log`
- `/private/tmp/xpa012-session-only-current-rust-cli-20260912.log`
- `/private/tmp/xpa012-session-only-current-swift-cli-20260912.log`

## Raw producer and consumer provenance

`session-cleanup-producer-current-macos-20260912/` retains the complete original
current native recording (10 lines), its nine unchanged `session.cleanup.apply`
lines, current Rust/Swift CLI control recordings, fresh actual Rust durable
output, and the exact raw applied record consumed by the current Swift decoder.
Its provenance records input, source and executable SHA-256 values. Selection
copies whole original lines; no fields or owner records are rewritten.

`session-cleanup-producer-frames-macos-20260912/` separately retains the earlier
native combined recording and source provenance from the original checkpoint.
The optional current readback input changes the test source hash, so that older
hash describes its recorded source revision rather than the new test file.
The existing checked-in `rust-cleanup-applied.json` fixtures remain unchanged.
All Session storage inputs are isolated host fixtures, not hardware evidence.

The apply schema includes success receipts derived from the original native
method frames and existing method corpus. The v2 checkout manifest contains
105 methods and 582 recorded shapes. The published view continues to use the
merge-base with `origin/main`; no baseline-revision override or Scope-Extension
is used. Installed activation, device execution and overall Task012 completion
remain outside this slice.
