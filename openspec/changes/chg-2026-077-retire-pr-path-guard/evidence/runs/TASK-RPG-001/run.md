# TASK-RPG-001 run record — retire the PR allowed-paths guard

- Date: 2026-09-13
- Evidence class: `platform` (repository tooling and CI workflows; no device, Runtime or fake path)
- Core baseline: `CORE-3.0.0`
- Scope: RPG-AC-01, RPG-AC-02, RPG-AC-03, RPG-AC-04, RPG-AC-05
- Base: protected `main` `ea0107cb47bc16665f49f6fdb660063470eee1af` (CHG-2026-077 proposal merged
  as #1876 on 2026-09-12; the implementation branch `agent/retire-pr-path-guard-20260912` was
  rebased onto this OID after the merge).
- Input pins: the readiness pins of `tasks.md` (main `1fd85b93…`, the seven blobs) were the
  state the deletions and edits started from; every pinned file was either deleted or rewritten
  by this PR, so the pins describe the input, not the result.
- Producer → consumer: `.github/workflows/agent-pr.yml` → `scripts/agent_pr_identity.py`
  (create-or-find, identity read-back, commit task); `.github/workflows/sdd-guard.yml` `guard` →
  `scripts/test_agent_pr_identity.py`; `scripts/host_loop/worker.py` → `REQUIRED_PR_CHECKS`.
  End to end: the pull request of this branch is opened by the new workflow itself.
- Evidence currency: `current`
- Delivered in one PR: deletions of `scripts/check_pr_paths.py`, `scripts/test_check_pr_paths.py`
  and `scripts/automation_config.json`; `scripts/agent_pr_identity.py` and
  `scripts/test_agent_pr_identity.py`; `.github/workflows/agent-pr.yml` (one job, no preflight)
  and `.github/workflows/sdd-guard.yml` (no `allowed-paths` job, helper tests in `guard`);
  `scripts/test_agent_pr_workflow.py`; `scripts/host_loop/worker.py` and its tests;
  `scripts/agent-guides/contributing.md`, `scripts/README.md`, `openspec/README.md`,
  `openspec/changes/README.md`, `openspec/templates/change/tasks.md`, `PRODUCT-LOOP.md` §16,
  `docs/design/cli-golden-journey-headless-runbook.md`, `docs/design/ui-consistency-audit-task.md`,
  `docs/design/viewer-ui-implementation-task.md`, `openspec/planning/agent-failure-patterns.md`
  (AF-001 automation status and the two other automation-status notes that cited the diff check),
  `docs/design/cross-platform/rust-core-cross-platform-architecture.md` (row 41),
  `docs/design/arkdeck-ds/scripts/check-tokens.mjs` (header comment); this record and the Task
  status.

## Environment

- macOS reference host: Python 3.14.6 (`python3`, and the shared `.venv-sdd` with PyYAML 6.0.3 for
  check-sdd / catalog checks), Git 2.x, Node v26.6.0.
- The retired checker for the live probe was taken from `main` before this PR
  (`git show 1fd85b93:scripts/check_pr_paths.py` and `…:scripts/automation_config.json` into a
  scratch directory, so the config sits next to the script as it expects).

## Work completed

1. Deletions — done. Nothing else in the repository imported `check_pr_paths` except
   `scripts/host_loop/test_pr_envelope.py` (which sampled a task through it and ran the guard end
   to end in one test) and `scripts/host_loop/test_token_parity.py`; both now use the helper or
   `host_loop.test_support.first_task_id`, and the end-to-end guard test is gone with the guard.
2. `scripts/agent_pr_identity.py` — the identity functions carried over unchanged in behaviour
   (`select_unique_pull_request_number`, `validate_pull_request_identity`,
   `pull_request_context_from_object`), `commit_task_declaration` (first `TASK_TOKEN_TEXT` match
   of `git show -s --format=%s <oid>`, `None` otherwise; non-UTF-8 read with replacement rather
   than refused), CLI modes `--pull-list [--allow-zero]`, `--pull-request --expected-*`,
   `--commit-task <revision>`, expectation flags refused outside `--pull-request`.
3. `scripts/test_agent_pr_identity.py` — pull-list matrix (zero / one / two, cross-page two,
   non-array, string / bool / zero number, non-object, unparsable), identity matrix (number, number
   type, state, merged, merged missing, base ref, base repo, head ref, head repo, head sha, author,
   short OID, null title; case-insensitive but full-length head OID; shape errors), the two CLI
   read-back tests, `--commit-task` cases (first token, none, suffixed and multi-segment tokens, a
   token no `tasks.md` declares, body tokens ignored, unknown revision), flag-combination refusals,
   token boundaries, and the `scripts/README.md` boundary-map coverage test carried over.
4. Workflows — `agent-pr.yml` keeps `open-pr` with `contents: read` + `pull-requests: write`; the
   `Task:` line is written before the pull request is created, from `--commit-task`; the read-back
   prints the response's number. `sdd-guard.yml` keeps `push` + `pull_request: [reopened, edited]`,
   `guard` runs `test_agent_pr_identity.py` after `test_check_sdd.py`. `test_agent_pr_workflow.py`
   requires exactly one job in the Agent PR workflow, the new tokens and their order, refuses the
   retired names (`check_pr_paths`, `automation_config`, `--preflight`, `--infer-task`,
   `--allow-bootstrap`, `Scope-Extension`, an `allowed-paths` job) in both workflows, and requires
   the helper tests in `guard`; six mutation cases cover these.
5. host_loop — `REQUIRED_PR_CHECKS = ("guard",)`. The verdict table runs under a patched two-name
   fixture set (the functions read the module constant at call time) so every multi-name invariant
   still executes; `ProductionRequiredSet` pins `("guard",)`, `[guard success]` → green,
   `[guard success (push), guard failure (edited)]` → failed, `[guard success, guard in_progress]`
   → pending, and a leftover `allowed-paths` run behaves as any non-required run. Worker fixtures
   use in-flight or duplicate `guard` runs where they used the retired name; the nested-marker
   dispatch test now starts from an in-flight guard, because an executed guard is green and
   dispatches nothing.
6. Documentation — as listed above; the template's Allowed paths line says it is a planning
   declaration, not read by CI, and only a precondition for host_loop auto-claim.

## Commands and results

| Command | Result |
| --- | --- |
| `python3 scripts/test_agent_pr_identity.py` | 14 tests OK |
| `python3 scripts/test_agent_pr_workflow.py` | 12 tests OK |
| `python3 -m unittest discover -s host_loop -t .` (in `scripts/`) | 588 tests OK, 1 expected failure (pre-existing) |
| `./scripts/check-sdd.sh` | 0 error(s), 0 warning(s), 121 acceptance IDs |
| `.venv-sdd/bin/python scripts/test_check_sdd.py` | 66 tests OK |
| `python3 scripts/ci/test_plan.py` | 31 tests OK |
| `.venv-sdd/bin/python -m unittest discover -s scripts/catalog_gen -p 'test_*.py'`; `generate.py --check` | 49 tests OK; check exit 0 |
| `node docs/design/arkdeck-ds/scripts/check-tokens.mjs` | matches the design docs (v1.6) |
| `python3 scripts/ci/plan.py --repo-root . --base-revision <proposal tip> --head-revision HEAD --merge-base` | all four lanes selected (`scripts/test_agent_pr_workflow.py` is in the planner's self-validation set); Swift, App, ds-interactions and Rust lanes not run locally — left to CI |
| `git grep` residue (RPG-AC-01) | see below |

### Residue of the retired names outside archive, evidence, historical change documents, `docs/design/references` and `.design-sync`

- Named on purpose: the header comment of `.github/workflows/agent-pr.yml`; `scripts/README.md`;
  `scripts/agent-guides/contributing.md`; the forbidden-token list and mutation cases of
  `scripts/test_agent_pr_workflow.py`; comments and the retired-name test in `scripts/host_loop`;
  `PRODUCT-LOOP.md` §16; `openspec/README.md` step 5; the AF-001 title and the three
  automation-status notes in `openspec/planning/agent-failure-patterns.md`; row 41 of the
  cross-platform inventory.
- Left as found: `ArkDeckApp/Documentation/macos-ui-implementation-proposal.md` (a historical
  proposal quoting the preflight command; outside this Task's paths); `scripts/check_sdd.py:304`
  (a comment citing the retired checker's colon class; outside this Task's paths);
  `docs/design/cli-golden-journey-headless-runbook.md:353` and the CHG-2026-055 evidence, which
  name the Runtime's isolated-workspace `--workspace-allowed-paths` admission — a different
  mechanism, untouched.

## Live probe with the retired checker

The implementation commit was first stacked on the proposal branch tip `dacb3855` (before #1876
merged), then rebased onto `main` `ea0107cb` after the merge. Each run: `--preflight
--head-revision HEAD --expected-head-ref agent/retire-pr-path-guard-20260912`.

1. Base `dacb3855` (the proposal tip; the base tree carries `TASK-RPG-001`):

```text
exit 0
stdout: TASK-RPG-001
```

2. Base `origin/main` at `1fd85b93` (before #1876; no `TASK-RPG-001` in the base tree):

```text
exit 1
check_pr_paths: ERROR: declared task TASK-RPG-001 does not exist in an active change at the base
commit; archive-only tasks are not authority, and neither is a task created or restored by the
pull request under review; closest base-tree task(s): TASK-XPA-002 (outside:
.github/workflows/agent-pr.yml, .github/workflows/sdd-guard.yml, PRODUCT-LOOP.md,
openspec/README.md, openspec/changes/README.md, ... (+24)); TASK-XPA-007 (…); TASK-XPA-017 (…)
```

   The same with the workflow's `--allow-bootstrap --infer-task`: the same refusal. This is the
   two-step the change retires, shown once more on itself.

3. After #1876 merged, rebased head, base `origin/main` at `ea0107cb`:

```text
exit 0
stdout: TASK-RPG-001
```

   With `--allow-bootstrap --infer-task` (the exact old workflow invocation): `TASK-RPG-001`,
   exit 0. The declaration in `tasks.md` covers the complete diff of 30 paths (2 added, 3
   deleted, 25 modified), so the old workflow would have admitted this PR; the new workflow does
   not read paths at all.

## AC conclusion

| AC | Method | Result |
| --- | --- | --- |
| RPG-AC-01 guard retired | residue list above; `test_agent_pr_workflow.py` mutations "second job", "retired guard script", "retired job in SDD Guard", "identity tests dropped from guard" | passed |
| RPG-AC-02 PR identity fail-closed | `PullListTests`, `IdentityTests`, `CommandLineTests` (read-back with the comparison suspended prints the response's number) | passed |
| RPG-AC-03 `Task:` is traceability | `CommitTaskTests` (first token / none / undeclared token / body ignored); the workflow writes it before creation and never validates it | passed |
| RPG-AC-04 host loop | `ProductionRequiredSet`, the two-name table, `CheckDispatch`, `CheckClassification`; suite 588 OK | passed |
| RPG-AC-05 documentation and live probe | `contributing.md`, `PRODUCT-LOOP.md` §16, `openspec/README.md`, the template carry no preflight or scope-PR instruction; probe 1–3 above; `check-sdd` green | passed |

## Deviations and residual risk

- `openspec/planning/agent-failure-patterns.md`: only the automation-status notes were changed, as
  declared; AF-001's preflight steps 3–4 (plan shared contract tables into the declared paths,
  route adjacent defects to their own remediation) are planning advice and were left as written.
- Two mentions outside the declared paths were left (see residue); both are historical or a code
  comment.
- Not run locally: the Swift, App build, ds-interactions and Rust lanes the planner selects for a
  `test_agent_pr_workflow.py` change; CI runs them on the pull request head.
- Behaviour change accepted in the host loop: with one required name, a push head whose `guard`
  executed successfully is `CHECKS_GREEN` without a check dispatch; a head whose `guard` is still
  in flight still receives exactly one dispatch, and the merge-ref `guard` run can still fail the
  round.
- Destructive dispatch count: 0.
