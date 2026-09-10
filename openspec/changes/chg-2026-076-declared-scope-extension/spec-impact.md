# Spec impact — CHG-2026-076

- **`openspec/specs/**`**: zero changes. No Requirement, Scenario, state machine, safety policy or
  schema field is added, relaxed, tightened or renumbered; `core_change_level: none`.
- **`AGENTS.md` (提交与 PR)**: gains one bullet: a PR may touch a path outside its declared Task's
  base-tree Allowed paths only by adding the path to that Task in the same PR and declaring it with a
  `Scope-Extension:` trailer, within the bounds and the `never_self_extend` list the guard enforces.
- **`scripts/automation_config.json`**: `schema` bumped; new required key `never_self_extend`.
- **`.github/workflows/agent-pr.yml`**: copies trailers into the PR body and the block into the step
  summary; no permission change.
- **Platform profiles, Catalog, contracts, integrations**: untouched.
