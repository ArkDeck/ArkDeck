# TASK-XPA-009 — the code-sign helper test inside check-contracts' views

Change: CHG-2026-074-shared-rust-runtime-core. This follows #2407. Host: the Windows 11 x64
reference host. No device, HDC or board was used.

## Cause

`arkdeck-agentd/tests/windows_code_sign_helper_process.rs` (#2407) reads the checked-in helper
resource at `Packages/ArkDeckKit/Resources/OpenHarmonyNativeCodeSign/arkdeck-code-sign-enable`,
beside `rust/`. The views `rust/scripts/check-contracts.py` builds (`rust/target/contract-check/
<view>`) carry `rust/`, the contract inputs and the App review projection, but not that resource.
So on a PR whose contract inputs differ from the published base, the candidate view runs the
workspace tests with the Windows signer, and the two helper tests fail with `NotFound`. This is
the same class of bug as #2378/#2392, and it is what turned #2428's Windows contract-parity lane
red.

The census assertions also named the whole owner line, so any new owner on main broke them.

## Fix

- **The view.** `check-contracts.py`'s `materialize` copies the helper resource into every view
  at its repository path (`CODE_SIGN_HELPER`), as it already copies the review projection. The
  test (and provider-hdc's helper-facts test, and agentd's operation-availability test, which
  skipped without it) now run for real in a view. `test_contract_checks.py` checks that the
  resource is copied when the checkout has it, and that its absence is not an error.
- **The census.** The test reads each census against a baseline: the same daemon started with no
  helper beside it. With the helper, the census must be that baseline with `codeSignHelper`
  inserted at its macOS position: before the first of the owners the macOS census lists after it
  (`flashAliasReconciler` … `readOnlyHdcProvider`) that is present, else last. With a helper that
  does not verify, the census must be the baseline unchanged. Owners that main adds later no
  longer break it.

## Verified

- **Before the fix.** `ARKDECK_RUST_STABLE_VIEWS=1 rust/scripts/check-contracts.py` built and kept
  the candidate view. In it, main's test failed as CI did: both helper tests panicked on the
  resource read (NotFound).
- **After the fix.** The rebuilt candidate view holds the resource, and in it
  `cargo test -p arkdeck-agentd --test windows_code_sign_helper_process` passed (3 tests), and so
  did provider-hdc's `native_library::tests` (9 tests, the helper-facts test included).
  `check-contracts.py` itself exited 0.
- **In the checkout.** The helper test passed (3 tests), and so did the new
  `test_contract_checks.py` test.
- **Unrelated on Windows.** `RunDirectoryTests.test_a_passing_run_removes_its_directory_without_a_word`
  asserts POSIX mode bits and fails on this host on main as well. It is untouched here.
