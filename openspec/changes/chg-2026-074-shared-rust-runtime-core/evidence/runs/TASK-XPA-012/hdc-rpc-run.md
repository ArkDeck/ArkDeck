# HDC registration Rust Runtime/CLI phase — 2026-09-11

Integration base: protected main `956c3a30987345888df7e1bce2ee326093012224`.
TASK-XPA-012 remains in progress. This PR delivers only the Rust HDC registration
RPC phase; installed activation and the remaining macOS migration are pending.

The Rust CLI accepts `runtime tool register --kind hdc --file <absolute-path>`
and sends `{kind: "hdc", file: <absolute-path>}` to `runtime.tool.register`.
The closed CLI/handler validation rejects wrong-role paths, extra fields, missing
paths, NUL and dot components before owner entry. The fixed-root Runtime handler
calls the existing `ToolRegistryStore::register`; capture, native inspection,
shared locking, quotas, immutable content publication and atomic index writes
are unchanged. Registration does not select or execute a tool. Duplicate
registration preserves the reference, timestamp, retained content and saved
selection/reference metadata. Staging can change only the registry root's
directory timestamps during a duplicate; retained child metadata and index bytes
remain identical.

The CLI preserves `outcomeUnknown` for a lost, malformed, mismatched or
inconsistent registration response. The existing handler maps unclassified,
unbounded and schema-inconsistent post-owner receipts to `outcomeUnknown`.
Neither path reconnects or replays the registration. `newDispatchCount: 0`
is about device dispatch, not proof that host metadata was unwritten.

## Scope and contract inputs

All implementation and process harness changes use `rust/**`. The existing
inspection/registration scope for `spec/control/methods/*.json`, tests scope for
`Packages/ArkDeckKit/Tests/**`, change evidence scope and exact published-pin
path cover the other files. No Allowed paths are added and no Scope-Extension
trailer is required. The DevEco-only Swift CLI/export annotations are not used
as HDC authorization: no Swift CLI, command-registry export, Catalog, durable
format or authority-kernel file changes in this phase.

The method registry remains at 102 methods with identity
`993f6b374b44dd5096e127d8f8d524063143dfb212f170de7b8a6aca935d53fe`.
Only the registration and inspect method definitions/corpora change. Native
quarantine digests and unsigned dependency signature fields require string/null
alternatives; otherwise the prior inspect schema would reject records the
existing native owner can legitimately write. No native validation is relaxed.
The shared top-level protocol/export vocabulary and all other method schemas
are unchanged. The Rust published pin/generated input is refreshed to the
integration base, while candidate generation remains in isolated source views.
The published consumer refuses HDC before connecting until its contract includes
the reviewed HDC request. Candidate behavior is tested separately, as required
by the repository's dual-input contract checks.

The unmodified new producer rows are in
[the raw Rust recording](hdc-rpc-producer-frames-macos-20260911/rust-native.jsonl)
and [the unsigned native inspect recording](hdc-rpc-producer-frames-macos-20260911/rust-unsigned-inspect.jsonl).
They contain actual daemon responses; only transport correlation IDs are
projected out by the harness, using the same format as the existing DevEco
recorder. No successful result or signature result is injected.

The repository generator consumes the base's 22 registration corpus rows,
all 83 original `runtime.tool.inspect` rows from
`bootstrap-rpc-native-frames-macos-20260911/*.jsonl`, and the new typed rows.
Only new registration rows whose parameter keys are exactly `kind,file` enter
the typed corpus. The other malformed-key requests remain negative evidence
in the raw recording and handler tests. This preserves the original inspection
error vocabulary instead of re-deriving it from its shape-minimized corpus.
The generated sample counts are 29 registration requests and 85 inspect requests.
All old corpus rows are retained byte-for-byte; seven registration and two inspect
rows are appended. The normal generator remains unchanged.

The native variants use test-owned copies for quarantine and signature removal.
The saved-selection case seeds the same offline metadata preservation fixture
as the existing storage tests, before starting its isolated daemon. It does not
call a selection operation or change installed selection. These cases prove
storage/response behavior, not hardware or execution authority.

## Host validation

- Python was checked before builds in `/private/tmp/xpa012-hdc-rpc-venv`:
  `PyYAML==6.0.3`, `jsonschema==4.26.0`.
- Rust CLI/Control checks passed the CLI parser/projection/one-request suites,
  including both DevEco and HDC malformed/lost response cases. A schema
  re-derivation initially omitted old inspect error codes; restoring all
  original producer inputs fixed that failure. The final Control test target
  passed 10 tests.
- Existing HDC owner tests ran: 6 cases (the explicit native-source opt-in case
  skips without its environment variable); the actual HDC source is exercised
  by the process checks below. The owner cases cover malformed/retained state,
  locks, staging quota, duplicates and content/index publication interruption.
- Existing native capture integration tests passed all 7 cases, including inode
  replacement, source/quarantine changes, immutable destinations, links and size
  failures. Log: `/private/tmp/xpa012-hdc-rpc-fault-tests.log`.
- Real HDC CLI/daemon oracle run passed using a new temporary registry, original
  installed HDC bytes and its libusb sibling only as read-only sources.
  The source and installed Bootstrap metadata fingerprints were unchanged.
  The actual lost-response proxy forwarded one first registration, read its
  successful durable receipt and dropped the response. The CLI returned
  `outcomeUnknown`; a separate inspect read the retained record, with no retry.
  Oracle root: `/private/tmp/arkdeck-hdc-rpc-dbmv9gel`.
- Swift's existing strict native readback test passed: 1 test, 0 failures,
  0 skips, complete receipt equality and unchanged recursive registry metadata.
  The first test invocation used an incorrectly shaped harness receipt file;
  a new derived wrapper supplied the expected root/result fields without
  modifying the raw response or registry. Passing log:
  `/private/tmp/xpa012-hdc-rpc-swift-readback-r2.log`.

Final candidate process checks passed:

- HDC: `/private/tmp/arkdeck-hdc-rpc-p74qht4_`, 9 actual CLI commands plus
  typed exchanges, first/duplicate/restart reads, locks, corruption, staging
  quota, source-size refusal, native metadata variants and one lost published
  response with independent inspect. Log:
  `/private/tmp/xpa012-hdc-rpc-final-native.log`.
- DevEco: `/private/tmp/arkdeck-deveco-register-pnpvl9uw`, 6 actual CLI commands
  and 4 typed exchanges, native first/repeat/restart registration and inspect,
  closed requests, unchanged source roles and installed metadata, zero retries
  after uncertainty. Log: `/private/tmp/xpa012-hdc-rpc-deveco-regression.log`.
- Both use the same final candidate daemon/CLI binaries. Daemon SHA-256:
  `3749eb928363eacb11f3f6366a2707f8e82601b3e4a4992b76ae8e8ca83b36d3`;
  CLI SHA-256:
  `4807b23427ab1275c5454f2eba098cc56545909c1d6134c63d7ae3df197ac03a`.

Every process check starts and stops only its own temporary daemons.
No source executable is launched, no device operation or Session deletion is
performed, and no installed Runtime is switched. Full TASK-XPA-012, macOS
cutover and GJ-1 hardware acceptance remain pending.


## Final repository gate

The required unified local gate passed against the integration base with
`--merge-base --include-worktree --run-local`: common checks, 83 design-system
tests, the full Swift lane (2613 parallel tests plus 1 serialized identity-race
and 5 Viewer-scale tests), Rust format and warnings-denied Clippy, workspace
checks, published/candidate contract checks and real owner process checks,
cargo deny and cargo vet (26 fully audited). The new HDC process check is part
of the candidate macOS owner checks. The planner selected `app: false`.
No App build, UI or device acceptance is claimed.

Unified log: `/private/tmp/xpa012-hdc-rpc-unified-gate.log`, SHA-256
`cf459f008861afdeeb12cb86ba3692274751f12d8d6881448232209bab9d3130`.
Dual-contract recordings:
`rust/target/readonly-check/0b8c53b5078440758579107655bba6f6`.

A pre-push fetch confirmed the integration base is still current and the open
PR list is empty, so there is no outstanding PR conflict or earlier-head CI
failure to resolve before this phase PR. Final commit path preflight and the
latest push checks remain the publication gates; no nightly wait is added.
