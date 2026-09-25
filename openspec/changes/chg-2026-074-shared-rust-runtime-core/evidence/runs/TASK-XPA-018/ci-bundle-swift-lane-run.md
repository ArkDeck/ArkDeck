# TASK-XPA-018 — CI: the Swift lane for the contract bundle too (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This follows #2193 at the hub's request
and changes CI only. Base: `main` `f7a3b73f7`. It touches the planner, so
its own PR runs every lane once.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
CLI, contract input, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change.

## What changes

#2193 made every path under `openspec/contracts/` select the Rust lane. The
same blind spot runs the other way. Swift's contract tests read the bundle
too: `CLIMachineContractTests` checks it for zero drift, and
`CLIRustCommandRegistryCopyContractTests` checks the registry copy. The
WorkflowStep, JobStateMachine, CurrentDurableStorage, HardwareEvidence and
DiagnosticsAndHAP contract tests read their schemas.

Take a PR that edits only the bundle, say
`app-product-capability-registry.yaml` by hand, and keeps the Rust copies
and `owned.json` consistent with the edit. It would pass the Rust lane
without running Swift's drift check, and the drift would show only at the
next unrelated PR that runs the Swift lane. A bundle is rarely edited
without Swift sources, which select the Swift lane anyway, so the extra lane
costs little.

`plan.py` now selects the Swift lane for every path under
`openspec/contracts/` as well. It selects exactly Rust and Swift, and never
App or DS.

## Tests

| Test | What it holds |
| --- | --- |
| `test_plan.py::test_every_bundle_contract_selects_rust_and_swift` | Every committed file under `openspec/contracts/`, and a new one, selects exactly the Rust and Swift lanes |
| `test_plan.py::test_contract_schema_catalog_and_generator_only_changes_select_rust` | The Catalog, generator and permit-vector inputs still select Rust alone; the contract schemas moved to the test above |

With the Swift half of the rule removed, the first test fails for every file
of the directory.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Planner tests | `python -m unittest scripts/ci/test_plan.py` | 38 tests, OK; without the rule, the new test fails |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-ci-swift-sdd.log`) |

## CI

- This PR: pending. It runs every lane, since it changes the planner.
