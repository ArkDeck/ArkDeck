# TASK-XPA-018: the measured-leaves test reads the coverage its build renders. Local run, 2026-09-30

## Failure

#2389 went red on `rust-checks / Rust contract parity (windows-latest)` (job 109855438738). The
cause is on main, from #2378: `crates/arkdeck-cli/tests/windows_signed_runtime.rs`
`windows_statuses()` read `CARGO_MANIFEST_DIR/../../../openspec/contracts/cli-feature-coverage.json`.

`rust/scripts/check-contracts.py` builds each view under `rust/target/contract-check/<view>/`:

- `rust/` is copied into it (`copy_rust`);
- the contract inputs are written into it (`materialize`: `spec/`, the control-frame corpus and the
  rest of `contract.working_inputs()`).

The only `openspec/contracts/` files in a view are the ones among those inputs (for example
`runtime-control-plane.schema.json` and `cli-result.schema.json`). `cli-feature-coverage.json` is
not an input, so it is absent. When a PR's contract inputs differ from the published base, the
candidate view runs the whole workspace's tests. With the signer present on the Windows runner,
`measured_owner_leaves_answer_their_contract_through_the_pipe` then ran, and `std::fs::read`
failed with NotFound (os error 2).

## Fix

`windows_statuses()` now reads the coverage manifest **this CLI renders**
(`arkdeck_cli::machine_contracts::contract_products()`, product `cli-feature-coverage.json`), not
the checkout's file. That is the same product `arkdeck maintainer contracts export` writes.
`tests/machine_contracts.rs` `every_owned_product_is_the_published_bytes` already holds it
byte-for-byte to the committed `openspec/contracts/cli-feature-coverage.json` outside the
published view.

So the assertion is kept, not skipped. Each measured leaf must still be Windows `implemented` in
the coverage the tested build publishes, in the checkout and in every view. The other repo-level
inputs the test reads are all inside the view, so nothing else in the file depends on
`openspec/`:

- the recorded `job.events` page under `Packages/…/ControlFrames`, which `materialize` writes;
- `rust/tests/fixtures/target-adoption`;
- `rust/scripts/windows-dev-identity.ps1`.

## Verification (Windows 11 x64)

1. **The view.** `ARKDECK_RUST_STABLE_VIEWS=1 python rust/scripts/check-contracts.py` built the
   candidate view as CI does and kept it at `rust/target/contract-check/candidate`. Its checks
   passed. On this branch the inputs equal the published base, so the view ran its reduced
   command set.
2. **The failure, reproduced in that view.** With main's `windows_signed_runtime.rs` copied into
   the view, `ARKDECK_DEV_SIGNER_THUMBPRINT=<host signer> cargo test -p arkdeck-cli --test
   windows_signed_runtime` (with `CARGO_TARGET_DIR` set to the view's target) failed exactly as
   CI did: `windows_signed_runtime.rs:447:75: called Result::unwrap() on an Err value: Os { code:
   2, kind: NotFound }`, after `daemon_answered_leaves_run_end_to_end_through_the_pipe ... ok`.
3. **The fix, in the same view.** With this branch's file, all three tests pass:
   `daemon_answered_leaves…`, `measured_owner_leaves_answer_their_contract_through_the_pipe` and
   `ctrl_break…`.
4. **In the checkout:**
   - `cargo test -p arkdeck-cli --test windows_signed_runtime` with the signer: 3 ok;
   - `cargo fmt --all --check`: pass;
   - `cargo clippy -p arkdeck-cli --all-targets -- -D warnings`: exit 0;
   - `PYTHONUTF8=1 sh scripts/check-sdd.sh`: 0 errors, 0 warnings;
   - `git diff --check`: clean.

## CI

To be recorded, not verified.
