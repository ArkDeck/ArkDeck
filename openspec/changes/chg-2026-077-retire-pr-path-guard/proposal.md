---
id: CHG-2026-077-retire-pr-path-guard
revision: 1
status: proposed
class: implementation-only
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# CHG-2026-077 — Retire the PR allowed-paths guard

> **This file does not approve itself.** The change is approved only if a human maintainer reviews
> and merges this proposal PR into protected `main`. `TASK-RPG-001` may be declared by the
> implementation PR only after that merge: the guard being retired still reads Task definitions
> from the base tree, so the Task has to exist on `main` before the PR that removes the guard can
> declare it. That is the last time the rule applies.
> No product behaviour, Catalog operation, provider, platform profile, Core Requirement or Acceptance
> Scenario changes. The change removes a repository CI guard, its configuration and tests, the two
> workflow jobs that ran it, the host loop's dependence on the guard's check name, and the
> instructions that told agents to stay inside a Task's Allowed paths.

## Why

- **Measured cost.** Between 2026-08-01 and 2026-09-12, 25 of the 895 pull requests merged into
  `main` changed nothing but one `tasks.md` and exist only to declare paths
  (`git log origin/main --since=2026-08-01 -- 'openspec/changes/*/tasks.md'`, single-file commits
  whose subject reads path / scope / declare / widen / authorize; #946 … #1871). `TASK-XPA-003`
  alone needed five of them around one implementation PR (#1828–#1831, #1834). Every one cost a
  maintainer merge, an executor rebase and, in the recorded cases, a paused task. CHG-2026-076
  (merged 2026-09-10) admitted in-band extension for paths outside `never_self_extend`; the pattern
  continued afterwards (#1839, #1840, #1871), because the trust root, the governance texts and the
  security kernel stayed two-step by design and an inferred Task could not extend at all.
- **What the guard protected.** By its own docstring the checker is "a read-only guard against
  accidental scope expansion, not an authorization or approval oracle" (TASK-MECH-004). Approval is
  the CODEOWNER's merge into protected `main` (`openspec/governance/enforcement.md`), and the only
  required status check is `guard`. The guard also carried a documented structural hole
  (CHG-2026-040 B-H2, kept in the module docstring): both workflows run the checker from the head
  checkout, so a pull request that edits the checker or its workflow is judged by its own code. The
  guard could therefore stop an honest agent from touching an adjacent file; it could never stop a
  deliberate bypass. The compensating control was always human review of the diff.
- **Where the cost comes from.** Task definitions are read from the base tree only, so every path a
  task discovers while implementing — a build script, a test registration, a host file, a workflow —
  is a separate maintainer round-trip before the implementation can even open its PR (the preflight
  runs before the pull request is created). The guard treats "register a UI test in the Xcode
  project" exactly like "edit the admission engine", and the reviewer sees the real diff in both
  cases anyway.
- **Decision.** Retire the mechanism. Scope control is the maintainer's review of the real diff;
  Allowed paths in a Task become a planning declaration — the footprint the author expects — that no
  machine enforces and no PR has to extend.

## What changes

- In scope:
  - Delete `scripts/check_pr_paths.py`, `scripts/test_check_pr_paths.py` and
    `scripts/automation_config.json` (the sensitive-path and `never_self_extend` tables have no
    other reader).
  - `.github/workflows/agent-pr.yml`: keep exactly one job, `open-pr`, with its current
    permissions; drop the preflight and the `allowed-paths` job. The create-or-find and the PR
    identity read-back (repository, number, base ref, head ref, head OID, author) move to a
    stdlib-only helper, `scripts/agent_pr_identity.py`, with their tests in
    `scripts/test_agent_pr_identity.py`. The PR body keeps a `Task:` line when the final commit
    subject names a Task; it is traceability, not a lookup.
  - `.github/workflows/sdd-guard.yml`: drop the `allowed-paths` job; keep the
    `pull_request: [reopened, edited]` trigger (the host loop's check dispatch still uses it to
    obtain a merge-ref `guard` run); run the helper's contract tests in the `guard` job.
  - `scripts/host_loop/worker.py`: `REQUIRED_PR_CHECKS` becomes `("guard",)`; the verdict table
    and the worker tests follow. Discovery still requires a declared footprint to auto-claim a
    task (unchanged; see decision 3).
  - `scripts/test_agent_pr_workflow.py`: pin the new workflow shape and refuse the retired names.
  - Documentation that instructed the guard: `scripts/agent-guides/contributing.md`,
    `scripts/README.md`, `openspec/README.md`, `openspec/changes/README.md`,
    `openspec/templates/change/tasks.md`, `PRODUCT-LOOP.md` §16, the headless Golden Journey
    runbook, the two design briefs that quote the preflight command, the header comment of
    `docs/design/arkdeck-ds/scripts/check-tokens.mjs`, the automation status of AF-001 in
    `openspec/planning/agent-failure-patterns.md` and row 41 of the cross-platform architecture
    inventory.
- Out of scope: branch protection and the required `guard` check; the PR authorship policy (the
  bot opens the PR, the local hook refuses opening one by hand); the SDD consistency checker; the
  host loop's discovery gates; archived changes and every historical proposal, evidence record and
  ledger that describes the guard as it was; the Allowed paths blocks already written in active
  `tasks.md` files (they stay as written and now mean "expected footprint").
- Observable behaviour before/after: before, a push to `agent/**` whose diff was not covered by
  one base-tree Task's Allowed paths produced no pull request at all, and a pull request whose
  paths drifted turned `allowed-paths` red; after, every push to `agent/**` opens or updates its
  pull request, the only required check is `guard`, and nothing in CI reads Allowed paths.

## The rule (normative for `TASK-RPG-001`)

1. No file, job, step or required-check name called `check_pr_paths`, `automation_config` or
   `allowed-paths` remains outside `openspec/changes/archive/**` and historical records
   (proposals, evidence, ledgers, notes). `scripts/test_agent_pr_workflow.py` refuses the names in
   both workflows so the guard cannot return unnoticed.
2. `.github/workflows/agent-pr.yml` declares exactly one job. Its identity checks keep failing
   closed: the pushed branch must have exactly one open pull request after create-or-find, and the
   read-back must match repository, number, base `main`, head ref, head OID and author
   `github-actions[bot]`; the number printed is the one carried by the API response, never the
   expectation echoed back. Untrusted title, body and head ref are read from JSON inside Python,
   never interpolated into the shell.
3. The `Task:` line in the PR body is the first task token of the final commit subject, or absent.
   It is not validated against any `tasks.md`; it never blocks the PR.
4. `REQUIRED_PR_CHECKS == ("guard",)`. The verdict lattice (failed > pending > success, every run
   of a name scanned, no asymmetry between required and non-required names) is unchanged and its
   table stays exhaustive under a two-name fixture set.
5. Allowed paths keeps its place in the Task template as a planning declaration and is described
   as such wherever an agent is told what to do with it. No text left in the repository instructs
   an agent to run a path preflight, to stay inside a Task's Allowed paths, or to open a scope PR.
6. Nothing else changes: `guard`, `ds-tokens`, the Swift/Rust lanes, the approval semantics and the
   PR authorship policy keep their current text and tests.

## Scope（涉及的 Requirement/AC）

- Requirements: none of `openspec/specs/**`. Repository governance texts: the PR section of
  `scripts/agent-guides/contributing.md`, `PRODUCT-LOOP.md` §16, `openspec/README.md` step 5,
  `openspec/changes/README.md`, `openspec/templates/change/tasks.md`.
- Acceptance: change-local `RPG-AC-01..05` in [verification.md](verification.md).
- Contracts/schemas: none. `arkdeck-automation-config/v2` is deleted together with its only reader.
- Core baseline bump: none.

## Safety, privacy, and compatibility

- Failure modes: `open-pr` still fails closed on every identity mismatch and on zero or several
  open pull requests for the branch; `guard` is unchanged. A push whose final commit subject has
  no task token opens a pull request without a `Task:` line — that is the intended outcome, not a
  failure.
- Residual risk accepted by approving this change: an agent pull request may touch any path,
  including `scripts/**`, `.github/**`, `AGENTS.md` and the admission/capability/recovery kernel,
  and nothing before review says so mechanically. The reviewer sees every such path in the diff
  and merge remains the approval. This is the posture the repository already had for a deliberate
  change (B-H2); the change makes it the posture for honest ones too.
- Data/schema compatibility: none affected. Existing Allowed paths blocks stay byte-identical.
- Platform impact: none; the guard ran on the hosted runners only.
- Rollback: revert the implementation PR; the checker, its configuration, both jobs and the
  two-name required set return in one revert.

## Maintainer decisions requested

1. Accept the posture: review of the real diff is the scope control; no machine enforces Allowed
   paths.
2. Keep the informational `Task:` line in the PR body (derived from the commit subject, never
   validated), or drop it. The implementation keeps it.
3. Keep the host loop's rule that a task without a declared footprint is not auto-claimable
   (unchanged; the field stays in the template for this reader), or retire it in a later change.
