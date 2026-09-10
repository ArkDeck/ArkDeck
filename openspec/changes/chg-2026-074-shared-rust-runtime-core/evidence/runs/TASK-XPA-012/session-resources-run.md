# Isolated Rust Session resource owner

This continuation builds on the Session configuration owner in PR #1843 and
connects `session.list`, `session.show`, `session.pin` and `session.unpin` to the
isolated Rust daemon. The existing CLI command names and parameters are preserved.
No Swift child, HDC provider, device job or installed Runtime activation is used.
TASK-XPA-012 still needs Session export/cleanup, the remaining host stores and
final integration/device acceptance; this record does not mark that task complete.

PR #1843 was approved and merged as `a37097dd8f5e69a845833c474092c43702e22312`.
This branch was rebased onto that main commit after verifying that its tree
exactly matched the tested predecessor. The published consumer pin is unchanged.

The configuration lock covers root selection through catalog access. Pin changes
also hold the catalog lock, compare the caller's catalog generation, atomically
publish, and read back both metadata and measured Session content. Generation zero
is valid; an already satisfied pin state leaves the generation unchanged. Stale
CAS, incomplete inventory and lock contention fail before a pin publication.
Publication uncertainty remains `outcomeUnknown`, without automatic CLI replay.
An exact Session read can proceed past unrelated located unregistered leaves;
whole-root discovery and pin changes refuse them. Duplicated identities and
unplaceable content refuse scoped reads as well.

List pages use private immutable snapshots with query-bound random cursors.
They survive restart and changes or loss of the active Session root. Reclaimed,
foreign-query and malformed cursors fail explicitly. Retention is bounded to
32 snapshots and 64 MiB total, with a 16 MiB snapshot and 1 MiB page bound.
Unsafe links/files cannot be read or reclaimed as ordinary snapshot documents.
The implementation reclaims through a held private directory and validates the
inspected document identity before removal.

A real consumer regression was reproduced with two completions in the same
second, at `.100Z` and `.900Z`. Ordering by hidden fractional seconds produced a
page that the CLI correctly refused as `recordUnreadable`. The owner now orders
the public whole-second timestamp and then Session ID. Catalog timestamps retain
their original precision. Both Rust and current Swift CLI consumers pass this
case against the Rust daemon.

Validation on macOS:

- The repository unified entry passed common checks, the full Swift lane,
  published/candidate Rust workspace and contract checks, dependency policy and
  `cargo vet` (26 fully audited dependencies). Each control replay view recorded
  112 responses and seven CLI envelopes. The candidate owner checks passed
  18 History, 21 Session configuration and 21 Session resource exchanges.
- Host-store tests passed all 18 tests, including four snapshot tests for restart
  reads, query binding, reclamation, unsafe files, lock contention and byte bounds.
  CLI tests passed all eight tests, including strict Session projections,
  zero-generation pin parameters and uncertain mutation replies.
- The added Swift CLI test
  `SessionResourceContractTests.testRealCLIProcessReadsRetainedSessionCursorAndRefusesQueryDrift`
  passed and recorded actual non-null cursor and query-drift responses. These and
  actual Rust responses supply the selected current-method corpus. The four
  method schemas also explicitly include the existing Session owner error codes.
- After the unified run, the resource harness was corrected to wait for a real
  `health` response before creating fixture directories. A socket can be listening
  while private owner initialization is still running; creating fixtures then
  could race initialization and make the daemon refuse an unsafe directory.
  The final harness passed 23 actual exchanges (including two readiness health
  responses) plus CLI calls with each of the Rust and current Swift CLI binaries.
  This final harness-only correction did not change product code.

Final direct consumer check binaries (SHA-256):

| Binary | Digest |
| --- | --- |
| Rust CLI | `a68181446635ebdf5f0e983e9e10a036609dd1a2686ea9343b4ffce1967932e2` |
| Rust daemon | `2c9424738406e749ddb088b634d490dab360d117814862ab5e0743570c49cc03` |
| Current Swift CLI | `923a41be56515b55c18e56c9c45e5ab7480255699aa1274daf58aacef3ff41de` |

Reproduce after building the Rust binaries from `rust/`:

```sh
python3 rust/scripts/check-session-resources.py
python3 rust/scripts/check-session-resources.py --cli-path Packages/ArkDeckKit/.build/debug/arkdeck
```

Run these commands from the repository root. All Session manifests in the harness
are explicitly simulated fixture data. These results are host verification,
not hardware evidence, installed ownership acceptance or approval to merge.
