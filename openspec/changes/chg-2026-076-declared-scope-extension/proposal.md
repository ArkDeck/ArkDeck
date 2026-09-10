---
id: CHG-2026-076-declared-scope-extension
revision: 1
status: proposed
class: implementation-only
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-076 — Declared scope extension for the PR path guard

> **This file does not approve itself.** The change is approved only if a human maintainer reviews
> and merges this proposal PR into protected `main`; `TASK-DSE-001` may be declared by an
> implementation PR only after that merge (`scripts/check_pr_paths.py` refuses head-only tasks).
> No product behaviour, Catalog operation, provider, platform profile, Core Requirement or Acceptance
> Scenario changes. The change is to the repository's PR path guard, its configuration and tests,
> the agent PR workflow and the PR section of `AGENTS.md`.

## Why

- **Measured cost.** On 2026-09-09/10 `TASK-XPA-003` needed one implementation PR (#1833) and five
  scope PRs — #1828 (two packaging scripts), #1829 (an HDC host lifecycle file and a rollback smoke
  test), #1830 (a read-projection exception), #1831 (a refusal-proof exception), #1834 (registering
  the test file in `project.pbxproj`). Each cost a maintainer merge and an executor rebase, and the
  executor paused the whole task at the first gap.
- **Where the cost comes from.** `scripts/check_pr_paths.py` reads a Task's Allowed paths from the
  base tree only. That is the deliberate closure of the allowlist half of the self-signing loop
  recorded as B-H2 in CHG-2026-040 (a head commit could otherwise widen its own Allowed paths to
  `**` and touch anything in the same breath, and measured live it passed). The closure is right.
  Its side effect is that every adjacent path a task discovers — a build script, a test
  registration, a provider host file — is a separate PR, and the guard treats "register a UI test in
  the Xcode project" exactly like "edit the admission engine".
- **Two kinds of gap.** Adjacent paths can be declared in band and reviewed on the real diff. A
  security-kernel exception (admission, capability, recovery, durable formats, the trust root of
  CI) must stay a separate, reviewed scope change. Today the guard cannot tell them apart.
- **Companion.** CHG-2026-074 r9 widens the macOS-chain tasks' Allowed paths to module granularity;
  this change covers what reconnaissance cannot foresee.

## What changes

- In scope:
  - A **declared scope extension** rule in `scripts/check_pr_paths.py`: paths outside the declared
    Task's base-tree Allowed paths pass only when every condition in "The rule" holds.
  - A `never_self_extend` pattern list in `scripts/automation_config.json` (schema bumped; the key
    is required, validated like `sensitive_paths`, and a malformed list fails every run).
  - Reporting: the preflight prints the extension to stderr, a `--scope-extension-summary <file>`
    option writes a Markdown block, and `.github/workflows/agent-pr.yml` copies the trailers into the
    PR body at creation and the block into `$GITHUB_STEP_SUMMARY` at validation.
  - The test matrix in `scripts/test_check_pr_paths.py` and the workflow contract tests in
    `scripts/test_agent_pr_workflow.py`.
  - One bullet in the PR section of `AGENTS.md` stating the trailer rule.
- Out of scope: the meaning of Allowed paths for undeclared paths (base-tree authority stays), the
  `sensitive_paths` table, the vertical change supplement, the one-time bootstrap, archive rules,
  `--infer-task`, every product source and every archived change.
- Observable behaviour before/after: before, any path outside the base-tree Allowed paths of the
  declared Task fails the guard; after, such a path passes only if the same PR adds it to that Task's
  Allowed paths, the final commit carries a matching `Scope-Extension:` trailer per pattern, the
  pattern is bounded and outside `never_self_extend`, and the PR surfaces the extension.

## The rule (normative for `TASK-DSE-001`)

Let `T` be the declared base-tree Task, `A_base` its Allowed patterns at the base commit, `A_head`
its Allowed patterns in the head checkout, `E = A_head − A_base`, and `O` the changed paths outside
`A_base` after the existing vertical-change supplement has been tried. The extension is admitted
only when all of the following hold; each failure is a `CheckError` naming the condition.

1. `T` is still active in the head tree and `A_base ⊆ A_head` (nothing removed, nothing rewritten).
2. `E` is non-empty, `|E| ≤ 8`, and no pattern in `E` is already covered by `A_base` (no no-op
   entries).
3. The final commit body carries one `Scope-Extension: <pattern>` trailer line per pattern in `E`,
   and the set of trailer patterns equals `E` exactly (no missing, no extra). In event mode the
   same lines are read from the PR body, exactly as `Task:` is; the preflight reads them from the
   head commit; the two sources must agree.
4. Every pattern in `E` is bounded: no leading `/`, not `*`, not `**`; its fixed prefix (the part
   before the first glob character) has at least two path segments and names a directory that
   exists in the base tree, or the pattern is an exact file path whose parent directory exists in
   the base tree.
5. No pattern in `E` overlaps `never_self_extend`: for every `e ∈ E` and every entry `n`, the fixed
   prefix of `e` does not start with the fixed prefix of `n` and vice versa, and no changed path
   covered by `e` matches `n` (case-insensitive on the `never_self_extend` side, as for
   `sensitive_paths`).
6. `E` covers all of `O`; any remaining path is reported as today.
7. The extension is only admitted for an explicitly declared Task; `--infer-task` with a non-empty
   `E` is an error.
8. Nothing else changes: base-tree authority for undeclared paths, the sensitive-path Task
   requirement, the vertical change supplement, archive rules and the bootstrap keep their current
   semantics and tests.

Initial `never_self_extend` (maintainer decision 2): `scripts/**`, `.github/**`, `AGENTS.md`,
`.gitignore`, `.python-version`, `openspec/specs/**`, `openspec/constitution.md`,
`openspec/governance/**`, `openspec/changes/archive/**`, `Catalog/**`, `**/*.entitlements`,
`Packages/ArkDeckKit/LaunchAgents/**`, `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeAdmissionService.swift`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentExecutionCoordinator.swift`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`,
`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AppProductCapabilityRegistry.swift`. These keep
the trust root of CI, the governance texts, the durable formats, the device lowering and the
admission, capability and recovery kernel on the two-step path; everything else that a base-tree
Task already covers is unaffected, and the list is the maintainer's knob.

## Scope（涉及的 Requirement/AC）

- Requirements: none of `openspec/specs/**`; the repository governance rules in `AGENTS.md` (PR
  section) and the guard's own contract (`TASK-MECH-004` lineage, CHG-2026-040 B-H2).
- Acceptance: change-local `DSE-AC-01..06` in [verification.md](verification.md).
- Contracts/schemas: `scripts/automation_config.json` `schema` bumped; no other schema.
- Core baseline bump: none.

## Safety, privacy, and compatibility

- Failure modes: every condition fails closed with a named reason; a missing or malformed
  `never_self_extend` fails every guard run, including task-declared PRs, exactly as a broken
  `sensitive_paths` does today.
- Residual risk accepted by approving this change: for paths outside `never_self_extend`, the
  guard stops being a hard stop before review and becomes an in-band, non-hideable declaration.
  The reviewer sees the extension three times — in the PR body, in the checks summary and in the
  `tasks.md` diff — and merge remains the approval. The self-signing loop stays closed for the trust
  root (`scripts/**`, `.github/**`, `AGENTS.md`), the governance texts and the security kernel.
- Data/schema compatibility: none affected.
- Platform impact: none; the guard runs on the hosted runners only.
- Rollback: revert the implementation PR; removing the config key restores today's behaviour.

## Maintainer decisions requested

1. Accept the posture change: in-band, declared extension for paths outside `never_self_extend`.
2. Confirm or edit the initial `never_self_extend` list above.
3. Confirm the bounds: at most 8 patterns per PR, fixed prefix of at least two segments.
