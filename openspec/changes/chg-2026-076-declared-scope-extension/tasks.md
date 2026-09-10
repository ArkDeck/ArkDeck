# Tasks — CHG-2026-076

入口：[proposal](proposal.md)、[design](design.md)、[spec impact](spec-impact.md)、[verification](verification.md)。

## Execution contract

- 本文件定义待执行任务，不声明实现完成。只有本 proposal PR 经维护者 review 合入 `main` 后，
  `TASK-DSE-001` 才能被实现 PR 声明；不另开 readiness/status-only PR。
- D1 Repo 任务，Hardware required:no 不代表 D0，不交给 host_loop 自动领取。
- 一个 Task 一个垂直实现 PR：检查器、配置、workflow、测试、`AGENTS.md` 措辞与 run 记录同车。
- 本 Task 的 Allowed paths 全部是敏感路径；实现 PR 的最终 commit subject 必须声明 `TASK-DSE-001`，
  且不得触碰表外路径（本 Task 交付的机制对本 Task 自身不适用：`scripts/**` 与 `.github/**` 在
  `never_self_extend` 内）。

## TASK-DSE-001 — Declared scope extension in the PR path guard

- Status:done（2026-09-10: delivered in one PR — guard rule, `never_self_extend` table, reporting, workflow wiring, test matrix, `AGENTS.md` wording and the live probe in `evidence/runs/TASK-DSE-001/run.md`; the maintainer's merge of that PR confirms decision 2, the initial list）
- Platform:macos（repository tooling; runs on every hosted runner）
- Decision grade:D1
- Requirements/AC:DSE-AC-01, DSE-AC-02, DSE-AC-03, DSE-AC-04, DSE-AC-05, DSE-AC-06
- Depends on:none（this proposal merged）
- Readiness input pins（instantiated at `main` on 2026-09-10）:

  ```yaml pins
  - path: main
    commit: b21549aaf1a0a96f1a3416d3019a00c6cf2d2b42
  - path: scripts/check_pr_paths.py
    blob: 5dcb0a31bcb4dd8635ad363188b23f20a5a97992
  - path: scripts/test_check_pr_paths.py
    blob: 48bf30bbdda3dc5c4662681ec63681d3de2b77d7
  - path: scripts/automation_config.json
    blob: a934e73264cb960f3090f964100a81f9b09780eb
  - path: .github/workflows/agent-pr.yml
    blob: a2fb2e343c8b98465b655f287f3defcd1166c010
  ```

- Applicable failure patterns:none（the task changes a repository guard, not a device or Runtime path; the reviewer may assign AF IDs）
- Production reachability:not applicable（CI guard; no production composition root, authority or effect dispatch — see design.md）
- Trusted fact sources:the base-tree Task definition read from immutable Git objects; the head checkout's `tasks.md`; the head commit message; the PR identity checks that already pin head OID, base ref, author and repository. A PR can construct its own trailers and its own `tasks.md` lines, which is why those only ever *declare* an extension and never authorise one — merge by the CODEOWNER does.
- Allowed paths:
  - `openspec/changes/chg-2026-076-declared-scope-extension/**`
  - `scripts/check_pr_paths.py`
  - `scripts/test_check_pr_paths.py`
  - `scripts/automation_config.json`
  - `scripts/test_agent_pr_workflow.py`
  - `.github/workflows/agent-pr.yml`
  - `AGENTS.md`（the "提交与 PR" section only: one bullet stating the trailer rule）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/governance/**`、`Catalog/**`
  - `Packages/**`、`ArkDeckApp/**`、`rust/**`、`scripts/ci/**`、`scripts/host_loop/**`
  - any other `.github/workflows/*.yml`
- Risk:high（trust-boundary change of the PR guard; reviewed on its own diff）
- Hardware required:no

### Deliverables

1. `declared_scope_extension()` in `scripts/check_pr_paths.py`, called from `check_paths()` after the
   vertical-change supplement returns `None`; conditions 1–7 of the proposal, one named
   `CheckError` each; `CheckResult.scope_extension`; the trailer parser shared by the preflight
   (head commit body) and event mode (PR body).
2. `never_self_extend` in `scripts/automation_config.json` with the initial list of the proposal,
   the schema bump and loader validation mirroring `sensitive_paths`.
3. Reporting: the preflight prints `scope-extension: <n> pattern(s)` and the list to stderr;
   `--scope-extension-summary <file>` writes a Markdown block; `agent-pr.yml` copies the
   `Scope-Extension:` lines into the PR body when it creates the PR and appends the block to
   `$GITHUB_STEP_SUMMARY` in the validation job.
4. Tests: the positive case, the negative matrix (one case per condition), the two-source
   agreement cases, the config matrix and the updated shipped-config anchor in
   `scripts/test_check_pr_paths.py`; the workflow text pinned in `scripts/test_agent_pr_workflow.py`.
5. Documentation: one bullet in the "提交与 PR" section of `AGENTS.md`; the module docstring of
   `scripts/check_pr_paths.py` updated; a live probe on a synthetic commit recorded in
   `evidence/runs/TASK-DSE-001/run.md`.

### Verification

- DSE-AC-01 → fixture repository: base Task with `a/**`; head `tasks.md` adds `b/c/**`; commit with
  `Scope-Extension: b/c/**`; changed paths under `a/` and `b/c/` → the Task is returned,
  `scope_extension == ("b/c/**",)`.
- DSE-AC-02 → each of: missing trailer, extra trailer, pattern absent from head `tasks.md`, base
  pattern removed in head, Task archived in head, `never_self_extend` overlap in either direction,
  a changed path matching `never_self_extend`, `**`/`*`/leading `/`, one-segment prefix,
  non-existent prefix directory, nine patterns, a no-op pattern, an uncovered offender,
  `--infer-task` with a non-empty extension → `CheckError` naming the condition.
- DSE-AC-03 → preflight and event mode on the same fixture: agree → pass; PR body without the
  trailer the commit has, or vice versa → error.
- DSE-AC-04 → missing key, empty list, non-string entry, duplicate entry, old schema → every guard
  run fails, including a task-declared PR with no offenders; the shipped file parses to the anchor.
- DSE-AC-05 → stderr block present exactly when `E` is non-empty; the summary file contents; the
  workflow contract tests pin the new steps.
- DSE-AC-06 → `python3 scripts/test_check_pr_paths.py` and `python3 scripts/test_agent_pr_workflow.py`
  fully green; `AGENTS.md` bullet present; the unified gate `python3 scripts/ci/plan.py --run-local`.

### Completion

All six ACs have reviewable results in `evidence/runs/TASK-DSE-001/run.md`, the live probe shows one
in-band extension admitted and one `never_self_extend` attempt refused on real commits, and the
maintainer has confirmed the initial list (decision 2) in the review.

### Handoff

- 完成后在 `evidence/runs/TASK-DSE-001/run.md` 记录命令、结果、AC 结论与偏差；本 Task 标 done 后
  `AGENTS.md` 的措辞即为执行 AI 的规则。
