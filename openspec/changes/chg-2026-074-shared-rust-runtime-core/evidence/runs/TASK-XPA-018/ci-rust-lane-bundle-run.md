# TASK-XPA-018 — CI: the Rust lane for the contract bundle, and workspace tests that do not stop at the first red binary (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This change is to CI only, and the hub
asked for it after the contracts-export slices. Base: `main` `acace84a7`.
It touches the planner, so its own PR runs every lane once.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
CLI, contract input, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change.

## The Rust lane for `openspec/contracts/`

The Rust export renders the machine-contract bundle (S1–S4 merged, S5 under
review). Its test holds every product to
`rust/tests/fixtures/contracts-bundle/owned.json`, or to the committed file.
`check-contracts.py`'s `verify_contract_bundle_digests` holds that table to
the committed bundle.

`plan.py` chose the Rust lane for `rust/`, `spec/`, the Catalog, the
contract fixtures and six named files of `openspec/contracts`, but not for
the rest of that directory. Swift's zero-drift test makes a Swift-only change
regenerate its products in the same PR: an App capability, the error codes
or the command registry, and so `app-product-capability-registry.yaml`,
`cli-feature-coverage.json`, `cli-command-registry.yaml` or the page,
next-action and event schemas. Such a PR ran no Rust lane. So the digest
table and the Rust copies (`command_registry.json`,
`app_capability_registry.json`) could go stale into `main`. The next
unrelated PR to run the Rust lane would then fail on "contract bundle digest
drift", a red delayed to someone else's change.

`plan.py` now chooses the Rust lane for every path under
`openspec/contracts/` (`RUST_BUNDLE_PREFIXES`).

## `--no-fail-fast` for the workspace tests

The Rust lane's workspace tests (`rust/scripts/workspace-tests.py`) ran
`cargo test --workspace`, which stops at the first failing test binary. On
#2191's first run the Linux and Windows lanes stopped at `argv_fixtures`, so
the binaries after it never ran there, and a second red would only have
shown on the next run. The wrapper now passes `--no-fail-fast`.

The trade-off, as the hub accepted it: a red run takes longer, since every
binary still runs, but it shows every failure at once, so one fix-and-rerun
round covers them all. A green run is unchanged. The contract views
(`check-contracts.py`) still stop at their first failing command. Their
commands depend on each other (a view builds, then runs the built binaries),
so running past a failure would add noise.

## Tests

| Test | What it holds |
| --- | --- |
| `test_plan.py::test_every_bundle_contract_selects_rust` | Every committed file under `openspec/contracts/`, and a new one, selects the Rust lane alone |
| `test_contract_checks.py::test_workspace_tests_run_cargo_only_when_the_checkout_matches_its_manifest` | The wrapper runs `cargo test --workspace --no-fail-fast` |

The planner test fails without the new prefix; each file of the directory
outside the six named ones is reported as not selecting Rust.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Planner tests | `python -m unittest scripts/ci/test_plan.py` | 38 tests, OK; with the prefix removed, `test_every_bundle_contract_selects_rust` fails |
| Contract-check tests | `python -m unittest test_contract_checks` in `rust/scripts` | 45 tests, OK |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-ci-pr-sdd.log`) |

Not run: the lanes themselves, which the PR runs in full.

## CI

- This PR: pending. It runs every lane, since it changes the planner.
