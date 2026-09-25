# `flash run` on the Rust CLI (TASK-XPA-017, M4-3b)

`flash run` is a Swift domain leaf. Swift's `runFlash` hands it to
`RuntimeCLI.runDomainOperation(path: ["flash", "run"], …)`, as it hands every
other domain leaf. That handler:

- takes the leaf's registry operation, `flash.full-restore@1`;
- applies no capture preset (`capturePresetExecutionRequest` keeps the
  caller's inputs for every path but its five presets);
- builds the request from `--target`, `--inputs-file`, `--capability` and
  `--execution-id` (`agentExecutionRequest`);
- runs it through the client-side `AgentRuntimeExecutor`, and renders the
  end with `emitAgentOutcome`.

The Rust CLI already serves every other such leaf through that one handler
(`domain_leaves`: C1 #2208, C2–C4 #2212, the capture presets #2228). `flash run`
joins it: one line in the argv table and one name in `SERVED`. It has no
code of its own, in Swift or here.

| Already on `main` | This change | Still remaining (M4 CLI) |
|---|---|---|
| Every other Flash leaf, the Flash invocation broker leaves and the legacy `debug` spellings; every other domain leaf through `domain_leaves` | `flash run` | `flash install-binding`, a legacy in-process leaf, which waits for its own Swift oracle |

## What a Flash run asks of the CLI

`flash.full-restore@1` is destructive. As for every mutation leaf, the CLI:

- forwards only the capability the caller names, as the reference the
  Runtime already holds (`authorization.capabilityId`);
- without `--capability`, submits no authorization at all. The Runtime then
  issues its own one-use capability for the exact plan, or refuses;
- never creates, widens or manages a capability, and never reaches a device
  any other way than through the Runtime's Job.

Against Swift's daemon the leaf runs a Flash as Swift's CLI does. The Rust
daemon composes no ArkForge lane yet (M4-F6), so it refuses a Flash
`job.submit` before any capability is issued (M4-F1), and the leaf reports
that refusal as it reports any other.

Nothing else changes: no daemon change, no contract input, no Swift source
or test. Per the coordinator's ruling of 2026-09-26, no `tasks.md` line;
this record is the evidence.

## Differences from Swift

The domain leaves' own, unchanged (`../TASK-XPA-018/cli-leaf-domain-host-run.md`,
`../TASK-XPA-018/cli-leaf-domain-device-run.md`).

## Tests (the CLI process against a fake Runtime)

| Test | What it holds |
| --- | --- |
| `domain_leaves.rs` `every_leaf_replays_swifts_recorded_runs` | `flash run` is one more served leaf driving Swift's recorded executor scenarios (`rust/tests/fixtures/domain-executor`) in turn, with the operation named as `flash.full-restore@1`: frames, connections, pending records, receipts, refusals and plain failures |
| `domain_leaves.rs` `a_mutation_leaf_forwards_only_the_capability_it_is_given` | Now also `flash run`: with `--capability` the submitted request's `authorization` is exactly `{"capabilityId": …}`; without it, the request carries no `authorization` |
| `argv_fixtures.rs` `every_served_leafs_argv_fixture_replays` | Swift's argv fixture for `flash.run` replays through this parser, with no deviation |
| `argv_fixtures.rs` `commands_lists_the_leaves_this_cli_serves_in_the_registrys_order`, `help_and_completion_render_the_registry_this_cli_serves` | `commands`, help and completion now name `flash run` |

Mutation check, baseline passing, each reverted after:

- `flash.run` left out of `SERVED`: `a_mutation_leaf_forwards_only_the_capability_it_is_given`
  fails.
- the argv line removed: `a_mutation_leaf_forwards_only_the_capability_it_is_given` and
  `every_leaf_replays_swifts_recorded_runs` fail.

(`/private/tmp/arkdeck-m4-f8a-mutations.log`.)

## Counts

- Rust CLI served leaves (`arkdeck commands --output json` on this build): 193/209 → 194/209.

## Local targeted checks

`CARGO_TARGET_DIR=/private/tmp/arkdeck-m4-rust-target CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0`

- `cargo fmt --all --check --manifest-path rust/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` —
  exit 0; also with `--target x86_64-pc-windows-msvc` and `--target x86_64-unknown-linux-gnu`
  (their own target directories) — exit 0 each.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-cli` — exit 0
  (`/private/tmp/arkdeck-m4-f8a-test.log`). No crate depends on `arkdeck-cli`.
- `python rust/scripts/check-readonly.py --bin-dir /private/tmp/arkdeck-m4-rust-target/debug`
  (validation venv) — exit 0, `PASS`.
- `sh scripts/check-sdd.sh` — exit 0.

## CI

Pending.

Host-process evidence only: a fake Runtime answering Swift's recorded
scripts. No device, no `arkforged`, no installed service.
