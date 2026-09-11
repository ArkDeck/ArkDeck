# Bundle metadata retirement — macOS, 2026-09-11

Integration base: protected main `b315f371`. TASK-XPA-012 remains in progress.
This phase routes the existing `runtime bundle remove` leaf through the typed
`runtime.bundle.remove` RPC and the Rust Bundle registry owner. The operation
retires registry metadata; immutable Bundle content remains retained.

## Behavior and boundary

The RPC accepts exactly `bundle` and `expectedGeneration` strings. Under the
existing Bootstrap lock, the owner decodes the index, resolves the reference,
requires literal expected generation `1`, and performs production native
verification of the target. A record already removed returns the same generation
`2` receipt without publication. Otherwise every one of the nine reference kinds
protects the record; only an unreferenced record changes to removed/generation 2.
Expected generation `2` is refused even after retirement. Lookup and owner/index
failures preserve Swift precedence over generation or native-content failures.

The index uses its unchanged `arkdeck.bootstrap-bundles/1` format and existing
atomic publication primitive. Only target state/generation change; other records,
references and Bundle content remain intact. Known failures before publication
remain structured refusals; uncertain publication/readback is `outcomeUnknown`.
The mutation-capable CLI preserves proved owner errors and treats transport loss
or an inconsistent success receipt as uncertain, with no fallback or auto-replay.
No reference acquisition/release, installation, helper launch, device authority
or Session-directory deletion is added.

The additive RPC has a complete existing Bundle inspection result shape. The
other 99 schemas retain their published shapes/provenance; their shared contract
identity is updated. Health was actually re-recorded from the current Swift
handler. No published Rust pin is advanced from an unmerged contract.

## Actual native producer and cross-language verification

Three default retirement producer tests and one health producer test passed;
two input-dependent retirement tests skip in an ordinary run. Both were then
executed explicitly using real signed helper copies, with zero skips/failures.

Swift registered two signed Bundle copies under the new private root
`/private/tmp/xpa012-bundle-retirement-native-20260911`, retired the first, and
proved repeat generation `1` returns its complete receipt without rewriting the
index. Native inspection still validates the retained content. The second Bundle
was retained available for Rust's independent native retirement.

Rust consumed Swift's retired record and repeat receipt without publication,
retired the second Bundle, reopened its owner, and checked generation `1` retry
and generation `2` refusal. Complete recursive hashes/metadata and membership
outside the index remained unchanged; index metadata/bytes were unchanged on
retry/refusal; the successful index changed only target state/generation. Swift
then inspected and repeated that real Rust receipt with exact equality and no
publication. The real Rust receipt is
`/private/tmp/xpa012-bundle-retirement-rust-native-receipt-20260911.json`, SHA-256
`eea8fe635b9637b7880b4a771e7b1fab6d63087c0d0e348e6bbe53b986519097`.
Raw actual Swift frames are retained under
`bundle-retirement-native-frames-macos-20260911/`. Malformed structural requests
are tested separately and are not used to derive valid request shapes. A seeded
unsigned adversarial fixture records only a real production trust refusal.

Logs:

- `/private/tmp/xpa012-bundle-retirement-swift-oracle-r2.log`: 6 tests, 2 explicit
  input skips, 0 failures. An initial run had a test/build integration error in
  invocation of the existing CLI option helper; it was fixed before recording.
- `/private/tmp/xpa012-bundle-retirement-swift-native.log`: actual Swift native
  producer, 1 test, 0 skips/failures.
- `/private/tmp/xpa012-bundle-retirement-native-rust-host.log`: actual native
  cross-owner retirement, 1 test, 0 skips/failures, 36.01 seconds.
- `/private/tmp/xpa012-bundle-retirement-reverse-swift.log`: actual Rust receipt
  consumed by Swift, 1 test, 0 skips/failures.
- `/private/tmp/xpa012-bundle-retirement-owner-tests.log` and
  `/private/tmp/xpa012-bundle-retirement-owner-clippy.log`: four focused owner
  tests and warnings-denied Clippy pass. Pure metadata tests cover all nine
  protected reference kinds; these are not claimed as native positive evidence.
- `/private/tmp/xpa012-bundle-retirement-cli-tests.log` and
  `/private/tmp/xpa012-bundle-retirement-cli-clippy.log`: candidate-100-method
  CLI tests (22 passed) and warnings-denied Clippy. Real producer receipt replay,
  inconsistent receipts and owner error classification are covered. The in-memory
  lost-response/no-replay check is a transport test, not native evidence.

## Final integration

A second actual Swift producer run created an independent source with one
available Bundle for process checks. Process tests copy this source and retain
their new roots. macOS copy quarantine attributes are restored to exact source
bytes on new copies only before native verification, as required by the frozen
content identity. Source registry/content are never changed by process tests.

Actual process checks passed: empty registry (9 control exchanges), native Rust
CLI (10 exchanges) and native Swift CLI against Rust daemon (10 exchanges).
They verify actual retirement, complete receipt equality, restart retry, no
repeat publication, retained content, lock contention, structural refusals and
corrupt index precedence. Logs:
`/private/tmp/xpa012-bundle-retirement-process-empty.log`,
`/private/tmp/xpa012-bundle-retirement-process-native.log`, and
`/private/tmp/xpa012-bundle-retirement-process-swift-cli.log`.
The first unified gate passed Swift and App build-for-testing, then reported
Rust import formatting from using the host formatter rather than the pinned
workspace toolchain. Workspace Cargo formatting fixed that cosmetic drift.
A second run passed Swift/App and identified a redundant optional unwrap in
the new Rust dispatch branch. It now uses a single typed pattern match; full
workspace warnings-denied Clippy passed (log
`/private/tmp/xpa012-bundle-retirement-root-clippy.log`).
The final repository unified gate passed all selected lanes: common checks,
design-system checks, Swift tests, App build-for-testing, and published-99 /
candidate-100 Rust contract views, including dependency policy checks. Log:
`/private/tmp/xpa012-bundle-retirement-full-gate-r3.log`.
No App UI assertions are required because this phase changes no App presentation.
These are isolated host results, not installed activation or device acceptance.
Remaining TASK-XPA-012 work includes registration/selection, other consumers,
installed owner cutover and GJ-1 acceptance.
