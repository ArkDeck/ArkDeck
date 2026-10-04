# TASK-WHR-002 — carry the integration registries into check-contracts' views, 2026-10-04

## The bug

#2472 added `arkdeck-provider-hdc/tests/windows_hdc_registration.rs`, which reads files outside
`rust/` at their repository paths:

- `openspec/integrations/openharmony/windows-probes.yaml`, the macOS registries beside it, and
  `profile.md`;
- `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`.

`rust/scripts/check-contracts.py` builds views (`rust/target/contract-check/<view>`) that hold only
`rust/`, the contract inputs and the resources `materialize` copies. When a PR changes contract
inputs, the candidate view runs the workspace tests, and 5 of the 8 registration tests failed
with "No such file or directory". This was seen on #2488's CI: ubuntu run 37195415505, job
111416377852.

#2472's own CI was green because its contract inputs equalled the published base, so no candidate
view ran its tests. This is the same class of bug as #2407/#2438, the code-sign helper resource.

## The fix

`materialize` copies `openspec/integrations` (16 files, 151 KB) into every view at its repository
path, beside the code-sign helper, whenever the checkout has it. No test is made to skip.

`test_contract_checks.py::test_views_carry_the_integration_registries_when_the_checkout_has_them`
checks two cases:

- a view of a checkout without the directory has none;
- a view of a checkout with it carries the registry and lock bytes unchanged.

## Verification (Windows 11 x64)

A candidate view was materialized exactly as `check()` does (`materialize` with the working
inputs and the published baseline). Then
`cargo test -p arkdeck-provider-hdc --test windows_hdc_registration --test swift_fixture_parity`
was run inside it:

| | Result |
| --- | --- |
| On `main` (before) | The view has no `windows-probes.yaml`. `windows_hdc_registration`: 3 passed, **5 failed** (os error 3 on `windows-probes.yaml` and `readonly-probes.yaml`), the same five tests as the CI failure. `swift_fixture_parity`: 11 passed |
| With this change (after) | The view has the registries. `windows_hdc_registration`: 8 passed. `swift_fixture_parity`: 11 passed |

Other checks:

- `python -m unittest -k carry rust/scripts/test_contract_checks.py`: 2 passed (the existing
  helper test and the new one). The full `test_contract_checks.py` result is in the PR
  description.
- check-sdd and `git diff --check` are clean.

A full `check-contracts.py` run with `ARKDECK_RUST_STABLE_VIEWS=1` was not used here, because this
branch changes no contract input, so it builds no candidate view. The materialized view above is
the same view.
