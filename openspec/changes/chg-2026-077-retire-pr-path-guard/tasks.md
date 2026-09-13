# Tasks — CHG-2026-077

入口：[proposal](proposal.md)、[design](design.md)、[spec impact](spec-impact.md)、[verification](verification.md)。

## Execution contract

- 本文件定义待执行任务，不声明实现完成。只有本 proposal PR 经维护者 review 合入 `main` 后，
  `TASK-RPG-001` 才能被实现 PR 声明（被退役的 checker 仍从 base 树读 Task 定义，这是该规则最后一次生效）。
- D1 Repo 任务，Hardware required:no 不代表 D0，不交给 host_loop 自动领取。
- 一个 Task 一个垂直实现 PR：删除、helper、workflow、host_loop、测试、文档与 run 记录同车。
- 本 Task 的 Allowed paths 写的是实现 PR 预计触及的全部路径；它是给 reviewer 的清单，不是给 checker 的
  ——实现 PR 合入后 checker 不复存在。

## TASK-RPG-001 — Retire the PR allowed-paths guard

- Status:done（2026-09-13: delivered in one PR — the three deletions, `scripts/agent_pr_identity.py` and its tests, both workflows, the workflow contract, the host_loop required set and tests, the documentation list and the live probe in `evidence/runs/TASK-RPG-001/run.md`; the maintainer's merge of that PR confirms decisions 1–3 of the proposal）
- Platform:macos（repository tooling; runs on every hosted runner）
- Decision grade:D1
- Requirements/AC:RPG-AC-01, RPG-AC-02, RPG-AC-03, RPG-AC-04, RPG-AC-05
- Depends on:none（this proposal merged）
- Readiness input pins（instantiated at `main` on 2026-09-12）:

  ```yaml pins
  - path: main
    commit: 1fd85b931fdef1416d41baebfe8bad0cf8d32b5e
  - path: scripts/check_pr_paths.py
    blob: 65a5f9cd4be82f58e077c86f7adfaffeb3c4d4e8
  - path: scripts/test_check_pr_paths.py
    blob: 977aba9d056f5a2e44fc8d01ea6b52722196b028
  - path: scripts/automation_config.json
    blob: 1f65b0c7088c39411f0875500d929307efbacf92
  - path: .github/workflows/agent-pr.yml
    blob: 2c2499d4bd57361985b1df78607e2372cb1de876
  - path: .github/workflows/sdd-guard.yml
    blob: d2d3a5c9d2d432d3a8c41f0f641efd116319e60c
  - path: scripts/test_agent_pr_workflow.py
    blob: 770bc3825ae5162945884c49eb6e10b1f15e2b16
  - path: scripts/host_loop/worker.py
    blob: 606fb63efea9107a1aee6282a11c2635ba15fb69
  ```

- Applicable failure patterns:none（the task removes a repository guard; no device, Runtime or readiness path is involved. AF-001 records the guard's mechanised half and is updated by this task; the reviewer may assign AF IDs）
- Production reachability:not applicable（CI guard and PR-opening workflow; no production composition root, authority or effect dispatch — see design.md）
- Trusted fact sources:the GitHub API read-back of the pull request, pinned to repository, number, base ref, pushed head ref, head OID and bot author, exactly as today; the final commit subject is data written by the pull request under review and only ever yields an informational `Task:` line.
- Allowed paths:
  - `openspec/changes/chg-2026-077-retire-pr-path-guard/**`
  - `.github/workflows/agent-pr.yml`
  - `.github/workflows/sdd-guard.yml`
  - `scripts/check_pr_paths.py`（deleted）
  - `scripts/test_check_pr_paths.py`（deleted）
  - `scripts/automation_config.json`（deleted）
  - `scripts/agent_pr_identity.py`（new）
  - `scripts/test_agent_pr_identity.py`（new）
  - `scripts/test_agent_pr_workflow.py`
  - `scripts/README.md`
  - `scripts/agent-guides/contributing.md`
  - `scripts/host_loop/**`（worker.py required set; the verdict, worker, minter, hardening and token-parity tests; comments in instance.py, pr_envelope.py and the discovery module）
  - `openspec/README.md`
  - `openspec/changes/README.md`
  - `openspec/templates/change/tasks.md`
  - `openspec/planning/agent-failure-patterns.md`（AF-001 automation status only）
  - `PRODUCT-LOOP.md`（§16 CI 机械说明 only）
  - `docs/design/cli-golden-journey-headless-runbook.md`
  - `docs/design/ui-consistency-audit-task.md`
  - `docs/design/viewer-ui-implementation-task.md`
  - `docs/design/cross-platform/rust-core-cross-platform-architecture.md`（inventory row 41 only）
  - `docs/design/arkdeck-ds/scripts/check-tokens.mjs`（header comment only）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/governance/**`、`Catalog/**`
  - `Packages/**`、`ArkDeckApp/**`、`ArkDeckAppUITests/**`、`rust/**`、`scripts/ci/**`、`AGENTS.md`
  - any other `.github/workflows/*.yml`
- Risk:high（trust-boundary change of the PR workflow; reviewed on its own diff）
- Hardware required:no

### Deliverables

1. Deletions: `scripts/check_pr_paths.py`, `scripts/test_check_pr_paths.py`,
   `scripts/automation_config.json`.
2. `scripts/agent_pr_identity.py`: the identity functions of the retired checker, unchanged in
   behaviour (`select_unique_pull_request_number`, `validate_pull_request_identity`,
   `pull_request_context_from_object`), `commit_task_declaration`, `TASK_TOKEN_TEXT`, and a CLI with
   `--pull-list [--allow-zero]`, `--pull-request --expected-*` and `--commit-task <revision>`.
3. `scripts/test_agent_pr_identity.py`: the pull-list matrix, the identity positive / negative
   matrix, the two CLI read-back tests, the `--commit-task` cases, and the `scripts/README.md`
   boundary-map coverage test carried over from the retired suite.
4. `.github/workflows/agent-pr.yml` with one job; `.github/workflows/sdd-guard.yml` without the
   `allowed-paths` job and with the helper's tests in `guard`; `scripts/test_agent_pr_workflow.py`
   pinning the new shape and refusing `check_pr_paths` and an `allowed-paths` job.
5. `scripts/host_loop/worker.py` `REQUIRED_PR_CHECKS = ("guard",)`, the verdict table kept
   exhaustive under a patched two-name set plus a production-set class, the worker / minter /
   hardening fixtures without the retired name, `test_token_parity.py` loading the helper.
6. Documentation listed in the proposal; the Allowed paths line of the Task template annotated as a
   planning declaration.
7. `evidence/runs/TASK-RPG-001/run.md`: commands, results, the `git grep` residue list, and the
   live probe (the retired checker run on the implementation branch against a base carrying this
   proposal → `TASK-RPG-001`; against `origin/main` without it → refusal).

### Verification

- RPG-AC-01 → `git grep -n -e check_pr_paths -e automation_config -e allowed-paths` over the head
  tree, excluding `openspec/changes/archive`, the historical change documents and evidence,
  `docs/design/references` and `.design-sync`, lists only historical prose; the workflow contract
  test refuses a reinserted job or script name.
- RPG-AC-02 → `python3 scripts/test_agent_pr_identity.py`: pull-list `[[]]` / one / two /
  malformed; identity mismatches on each of number, state, merged, base ref, base repo, head ref,
  head repo, head sha, author, short OID, null title; the printed number comes from the response
  (read-back test with the comparison suspended).
- RPG-AC-03 → `--commit-task` on a fixture repository: `fix(TASK-AAA-001): x` → `TASK-AAA-001`;
  `docs: x` → `none`; two tokens → the first; a token absent from every `tasks.md` is still printed.
- RPG-AC-04 → `python3 -m unittest discover -s host_loop -t .` in `scripts/`:
  `REQUIRED_PR_CHECKS == ("guard",)`; `[guard success]` → green; `[guard success (push), guard
  failure (edited)]` → failed; `[guard in_progress]` → pending and one dispatch; the exhaustive
  table green under the two-name fixture set.
- RPG-AC-05 → `contributing.md`, `PRODUCT-LOOP.md` §16, `openspec/README.md` step 5, the
  template: no preflight command, no scope-PR instruction, Allowed paths described as a planning
  declaration; `python3 scripts/test_agent_pr_workflow.py` and `./scripts/check-sdd.sh` green; the
  live probe recorded.

### Completion

All five ACs have reviewable results in `evidence/runs/TASK-RPG-001/run.md`; the maintainer's merge
of the implementation PR confirms decisions 1–3 of the proposal.

### Handoff

- 完成后在 `evidence/runs/TASK-RPG-001/run.md` 记录命令、结果、AC 结论与偏差；本 Task 标 done 后
  `scripts/agent-guides/contributing.md` 的措辞即为执行 AI 的规则。
