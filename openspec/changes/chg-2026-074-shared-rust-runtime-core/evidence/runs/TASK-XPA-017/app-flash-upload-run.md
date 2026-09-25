# The App's flash bundle upload on the Rust Runtime (TASK-XPA-017, M4-4b2)

`FlashApplicationFacade` uploads the DAYU200 images archive before it plans
a Flash. Swift's App transport admits that upload (`AgentXPCListener`: a HAP,
a native library or a flash bundle). The Rust App ingress refused it before
the owner, pending the Flash composition; with #2158 the owner validates a
bundle as Swift's production policy does, so the ingress now admits it.

Doing so exposed a contract gap older than this lane. The Import schemas were
derived from corpora that held no flash bundle, so four of them had narrowed:

- `metadata.deviceProfile` could only be `null` in `artifact.import.inspect`,
  `list`, `inspection` and `abort`;
- `receipt.validation` had no `deviceProfile` in `inspect`, `inspection` and
  `list`;
- `list` did not allow an item that is still in progress, whose `receipt`
  is `null`.

The Rust control layer therefore answered those views of any flash bundle,
and `list` with an in-progress Import, with `internalError` ("the result does
not conform to the current contract"), where Swift's daemon answers them.

Base: protected `main` `8bd64581` (#2158, M4-4b1, after #2157). Routed
methods stay **101/105**, and executable operations 15/30. The four schemas
widen and their corpora gain eight lines; the Swift baseline now counts 991
shapes.

| Already on `main` | This change | Still remaining (M4) |
|---|---|---|
| The Import owner validating a flash bundle at commit (#2158) | The App ingress admitting the App's flash bundle upload; the four Import schemas widened as Swift answers; the Swift frames of every Import view of a flash bundle | The two Flash operations' plan (`job.plan`), admission and `debug.start`/`debug.evaluate` (observe, stop); `flash.lanePlanPreview` and the Flash run, after the upstream ArkForge client change |

## The frames

`FlashBundleImportViewsContractTests` drives Swift's
`RuntimeControlPlaneHandler` with `FlashBundleImportPolicy.production`
through every Import view of a flash bundle, recording the frames with
`ARKDECK_CONTROL_FRAME_LOG` (17 frames):

- `begin` and `append`;
- `inspect`, by Import and by request, before and after the commit;
- `list`, unfiltered and by Target and state;
- `commit`, then `inspection`;
- `abort` of a second bundle;
- a third bundle that does not fit the board, refused at its commit and
  inspected in progress.

The bundles are the synthetic archives of #2158's oracle. Against the
committed schemas nine of the frames were refused, all by the gaps above;
against the widened ones, none.

## The contract change

- **Corpora, append-only.** The committed lines are kept verbatim. One frame
  per new shape was appended: `inspect` +3, `list` +3, `inspection` +1,
  `abort` +1. `begin`, `append` and `commit` had every shape already.
- **Schemas, widened only.**
  - `generate-control-contract.py --derive-method-schemas` ran over the four
    corpora, as a check.
  - The same widening was then applied by hand to the committed schemas,
    asserted equal to the derivation's `$defs`.
  - Their sample counts grew by the appended lines.
- **Generated.** `generate-contract.py --write` refreshed
  `spec/baselines/swift-single-v1.json` (991 shapes); `--check` passed.

## The ingress

`app_ingress/imports.rs` admits `flash-bundle` beside the HAP and the native
library. The ingress test uploads a bundle as the App does:

- it is committed with Swift's facts, and its bytes are published;
- the views the local client reads carry the profile;
- an unfit bundle is refused at the owner, stays in progress with nothing
  published, and the App aborts it.

In check-contracts' published view, the merge base's older schemas are
compiled in. There the test expects the control layer's refusal instead of
the views. That view was simulated here: the base schemas restored and the
view forced, the test passed, and everything was restored by digest.

## Verification

**Local targeted checks.** `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0`, own
target `/private/tmp/arkdeck-m4-rust-target`, logs
`/private/tmp/arkdeck-m4-app-flash-*.log`.

| Check | Command | Result |
|---|---|---|
| Swift frames | `ARKDECK_CONTROL_FRAME_LOG=<fresh> run-swiftpm.sh test --filter FlashBundleImportViewsContractTests` | exit 0; 17 frames (`swift.log`) |
| Frames against the schemas | jsonschema (validation venv), before and after the widening | 9 refusals, then 0 |
| Schema derivation | `generate-control-contract.py --derive-method-schemas` over the four corpora, as a check | differs only by the widening applied and the sample counts |
| Contract | `generate-contract.py --write`, then `--check` | exit 0; 105 methods, 991 shapes |
| Swift schema contract | `ARKDECK_CONTROL_FRAME_LOG=<frames> run-swiftpm.sh test --filter 'ControlMethodSchemaContractTests\|FlashBundleImportViewsContractTests\|DurableImportContractTests'` | exit 0; 29 tests (`swift-schema.log`) |
| Ingress | `cargo test -p arkdeck-agentd --bin arkdeck-agentd app_ingress` | 29 passed; with the old `inspect` schema the new test fails on the view's `internalError`, as it must |
| Published view | `published-view-sim-app-flash.sh` (merge base's four schemas, the view forced) | passed; restored by digest |
| fmt, clippy | `cargo fmt --all --check`; `cargo clippy -p <crate> --all-targets -- -D warnings` for `arkdeck-contract`, `arkdeck-control`, `arkdeck-hoststore`, `arkdeck-agentd`, `arkdeck-cli` | exit 0 (`fmt.log`, `clippy.log`) |
| Crate tests | `cargo test --no-fail-fast -p <crate>` for the same five | exit 0 each: contract 52, control 29, hoststore 575, agentd 153, cli 252 (`test-<crate>.log`) |
| Read-only host check | `rust/scripts/check-readonly.py --bin-dir <this build>` (validation venv) | PASS on macOS; 135 control responses (`readonly.log`) |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | exit 0 (`sdd.log`) |

**CI.** Pending.

**#2158 (M4-4b1), recorded here.**

- *Head `57ce2466`.* Every check passed on the first run: SDD Guard run
  36071961921, and Swift CI run 36071962251, whose `swift` aggregate and Rust
  lanes on ubuntu, macos-26 and windows passed.
- *Merged* as `8bd64581`.

No device, installed service, real `arkforged` or App was used, and nothing
here is device evidence. The bundles are synthetic.
