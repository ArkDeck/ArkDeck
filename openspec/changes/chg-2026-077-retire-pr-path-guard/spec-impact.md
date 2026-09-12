# Spec impact — CHG-2026-077

- **`openspec/specs/**`**: zero changes. No Requirement, Scenario, state machine, safety policy or
  schema field is added, relaxed, tightened or renumbered; `core_change_level: none`.
- **`scripts/agent-guides/contributing.md` (提交与 PR)**: loses the preflight command, the
  `Scope-Extension:` trailer rule and the sensitive-path Task requirement; states that Allowed paths
  is a planning declaration and that the maintainer's review of the diff is the scope control.
- **`PRODUCT-LOOP.md` §16, `openspec/README.md` step 5, `openspec/changes/README.md`,
  `openspec/templates/change/tasks.md`**: the same statement in each place that mentioned the guard.
- **`.github/workflows/agent-pr.yml`, `.github/workflows/sdd-guard.yml`**: the `allowed-paths` jobs
  and the preflight are removed; no permission widens.
- **`scripts/**`**: the checker, its tests and its configuration are deleted; the identity helper
  and its tests are added; `scripts/host_loop/worker.py` requires only `guard`.
- **Platform profiles, Catalog, contracts, integrations**: untouched.
