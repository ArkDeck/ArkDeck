# Bundle list Runtime owner — macOS, 2026-09-11

Integration base: protected main `b315f371`. TASK-XPA-012 remains in progress.
This independently reviewable phase connects the existing Bundle discovery leaf
to a typed Runtime RPC, the Rust storage owner and both Rust/Swift CLI consumers.
It does not complete Bootstrap writes, service selection or installed cutover.

## Behavior and boundary

`runtime.bundle.list` accepts only optional integer `pageSize` (default 100,
range 1 through 1000) and an optional opaque string `cursor`. Its existing
`arkdeck.cli.page/1` snapshot projection and `bundleRef:asc` order are preserved.
Every row retains the complete existing `runtime.bundle.inspect` shape.
The existing 99 methods retain their original schemas and recorded provenance;
only their shared contract identity changes for the additive RPC. Health frames
were freshly recorded from the actual Swift producer so its advertised identity
and 100-method inventory agree with the candidate contract.

The Rust owner holds the existing Bootstrap lock through full native inventory
validation and snapshot publication/read. As in Swift, every continuation scans
and validates current inventory before page-size or cursor checks. It rechecks
the registered index, root, lock and snapshot directory before returning,
including after pager failures. Only a genuinely empty registry may initialize
its frozen empty index on first list. Existing inspection remains non-initializing.

Private snapshot files use the unchanged `arkdeck.runtime-snapshot/1` pager and
its existing bounds/retention. List is not a zero-filesystem-write operation:
it may initialize metadata and persist discovery pages. It does not change
registered resources, select/execute helpers, launch device jobs or grant
authority. No new Session deletion or pager retention implementation is included.

## Actual producer and native comparison

Four default Swift producer tests passed; two explicit native/readback tests
skip without their required input variables. The native tests were then each
run explicitly and passed with no skips:

- Two real signed helpers were copied from existing immutable Bootstrap bundle
  registrations into `/private/tmp/xpa012-bundle-list-native-20260911`. Their
  references end in `078fc916…9598301` and `a5c9e37f…e0fde5`; each reports actual
  version `0.1.0`. Native validation uses the production helper trust policy.
- Swift emitted a real two-page list. Rust consumed its continuation and matched
  the entire second page. Rust created another snapshot, reopened its owner and
  consumed the continuation; Swift then consumed that actual Rust cursor and
  matched the entire Rust second-page receipt.
- Registered index/content byte hashes and recursive metadata remained unchanged
  in the Rust native test; existing snapshot bytes were preserved. Source helpers
  were read/copied, never selected or executed. The positive oracle has no
  injected trust acceptance. The adversarial stored fixture records only an
  actual production native trust refusal.

The original 14 Swift frames are retained byte-for-byte under
`bundle-list-native-frames-macos-20260911/`. Structural malformed parameter tests
are excluded from typed-request derivation. The bounded snapshot error vocabulary
also preserves existing size-limit refusals even though these native rows are
small. The real Rust receipt is
`/private/tmp/xpa012-bundle-list-rust-native-pages-20260911.json`, SHA-256
`dc1d3494e115f23b131445b6c3bc2f79b6451ca9f4a5ff13d3b90073e2cf229e`.

Logs:

- `/private/tmp/xpa012-bundle-list-swift-oracle-r2.log`: 6 tests, 2 explicit-input
  skips, 0 failures; an earlier attempt had test-only compilation errors.
- `/private/tmp/xpa012-bundle-list-swift-native.log`: actual two-bundle producer,
  1 test, 0 skips/failures.
- `/private/tmp/xpa012-bundle-list-reverse-swift.log`: actual Rust cursor consumed
  by Swift, 1 test, 0 skips/failures.
- `/private/tmp/xpa012-bundle-list-hoststore-tests.log`: 7 focused owner tests;
  native input corruption, lock contention and namespace replacement checks.
- `/private/tmp/xpa012-bundle-list-native-rust-host.log`: actual bidirectional
  native input, 1 test, 0 skips/failures. An initial sandbox native-trust refusal
  passed unchanged with normal host trust-service access.
- `/private/tmp/xpa012-bundle-list-cli-tests.log`: 21 candidate-100-method CLI
  tests, including complete real producer pages and inconsistent-row refusals.
  CLI and hoststore warnings-denied Clippy passed separately.

## Final integration

Actual end-to-end process checks passed for empty inventory and for both Rust
and Swift CLI consumers against the candidate Rust daemon with copied native
inventory. They exercise restart continuations, invalid input/cursor, lock
contention, corrupt inventory precedence and exact registered index preservation.
The original native registry is unchanged. Logs:
`/private/tmp/xpa012-bundle-list-process-empty-r2.log`,
`/private/tmp/xpa012-bundle-list-process-native-r2.log`, and
`/private/tmp/xpa012-bundle-list-process-swift-cli-r2.log`.

The first empty-process attempt used an incorrect expected CLI exit code for
`recordUnreadable`; the test now requires the published exit code 2. Initial
native-copy attempts were correctly refused because macOS file copying changed
quarantine flags on copied provisioning profiles. The test now restores exact
source quarantine bytes only on its new copies before native validation. No
production integrity check changed. Raw malformed process requests are retained
in their logs/recordings but are not added to the closed typed-request corpus.

The initial unified gate exposed an obsolete local-only Bundle-list CLI assertion;
it now checks Runtime routing for list and preserves local routing for other leaves.
The next run passed Swift and App checks but detected stale health corpus identity.
Two actual Swift health frames were re-recorded with empty/HDC provider registries
(1 producer test passed, zero dispatch); no recorded values were fabricated.
The final unified gate passed (exit 0): common checks, design-system checks,
full Swift tests, App build-for-testing, published/candidate Rust contracts and
process checks, Cargo deny and vet. Log:
`/private/tmp/xpa012-bundle-list-full-gate-r3.log`.
App UI assertions were not run because this phase changes no App presentation.
All fixtures are isolated host evidence, not installed activation or device
acceptance. Remaining TASK-XPA-012 work includes registration/selection writes,
other host-store consumers, owner cutover and GJ-1 acceptance.
