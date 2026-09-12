# Rust Session cleanup apply owner

The existing `session.cleanup.apply` method and CLI leaf now delegate to the
Rust Session owner. The operation compares the exact durable preview tuple,
expiry, policy and catalog generations, pins, Artifact references and the
current Job owner's active Session set before publishing applying intent.
An active Job also protects a Session with a nondefault directory identity
through the Session manifest's Job association.

The Job activity guard is held for the complete preview/apply action. Missing
or unreadable Job inventory fails closed; it cannot be substituted with an
empty active set. The integration branch supplies this guard through
`JobStore::with_active_sessions`; this isolated change supplies the typed Host
seam and verifies both refusal and configured behavior.

Cleanup retains the configuration and catalog locks while preparing and applying
an anchored tree removal. Each selected Session's complete directory membership,
owned same-volume identities, regular-file link counts, sizes, timestamps and
SHA-256 values are captured before intent. Validation rejects symlinks, hardlinks,
unsafe permissions, changed bytes, late entries and replaced ancestors. Removal
uses retained descriptors and unlinks only the selected Session descendants;
calendar directories and neighboring Sessions remain. Deletion and final catalog
publication are synchronized. A complete post-delete snapshot must match the
selected plan before the result is durably published and read back.

A proven stale snapshot before the first unlink can restore ready. Any uncertain
intent, deletion, catalog publication or missing result retains applying and
returns `outcomeUnknown`; restart never retries that preview. An applied preview
returns the exact stored receipt. CLI transport/schema/semantic reply failures
for cleanup apply also remain unknown and never enable automatic replay.

## Local verification

- Seven cleanup owner tests passed: active/pinned protection, manifest Job
  association, exact tuple/expiry/pin/policy/lease conflicts, zero-unlink stale
  release, interrupted intent, missing post-delete receipt, restart idempotency,
  unsafe content, root replacement and no-op generation stability.
- Four descriptor-removal tests passed, including a fault after an actual unlink,
  unsafe links/permissions, same-size byte changes and directory replacement.
- Two daemon Host tests passed: missing/unreadable Job owner refusal and guarded
  preview/apply reachability.
- Nine CLI unit tests and eleven current-surface integration tests passed,
  including actual Rust receipt validation, request-tuple binding and unknown
  lost/malformed replies. Eight existing socket endpoint tests initially could
  not bind under the sandbox; their controlled local-socket rerun passed.
- A broader host-store library run passed 97 tests and ignored four explicit
  native-fixture tests. Five pre-existing native HDC trust tests failed because
  native code-signing inspection was denied in the sandbox; those paths were
  not changed or retried here. All 52 Session-only library regression tests passed.
- Platform, host-store and CLI Clippy with `--all-targets -- -D warnings`, Rust
  formatting, Python harness syntax and diff checks passed.
- The checked-in `rust-cleanup-applied.json` files are the unmodified bytes
  copied from an actual Rust owner test's applied record. Set
  `ARKDECK_CLEANUP_RECORD_COPY=/private/tmp/<file>.json` while running the owner
  test to copy another actual record. The inputs are simulated host fixtures.

The coordinated integration run still needs to execute the new Swift producer
and record-reader tests, derive `session.cleanup.apply` from those actual frames,
wire the Job guard, run the expanded cleanup process harness with both CLIs,
and run the unified local gate. Those results belong to the integration follow-up;
this report does not claim installed activation or completion of TASK-XPA-012.

Swift tests in `SessionCleanupContractTests`:

- `testCurrentSwiftOwnerReadsActualRustCleanupAppliedRecord`
- `testCleanupApplyProducerRecordsExactTupleAndArtifactReceipt`
- `testCleanupApplyProducerRecordsPartialDeletionAndRefusesReplay`
- `testCleanupApplyProducerRecordsUnavailableAndUnreadableOwners`

Use `ARKDECK_CONTROL_FRAME_LOG=<directory>` for the producer recording. The
Rust record-reader test uses its checked-in fixture and needs no environment.
`rust/scripts/check-session-cleanup.py` now exercises actual preview, apply,
pinned retention, exact removed Artifact identity, catalog accounting and durable
repeat apply across a daemon restart. It accepts `--record-applied-copy` in
addition to the existing ready-record and control-frame outputs.
