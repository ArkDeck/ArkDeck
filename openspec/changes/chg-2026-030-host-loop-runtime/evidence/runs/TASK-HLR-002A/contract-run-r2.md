# TASK-HLR-002A Contract Run r2 — bootstrap namespace partition

- Date:2026-07-23（Asia/Shanghai）。
- Executor:`agent`。
- Base:protected `main`
  `e69a0c23b327571327bfce4a87d5e50f406db256`（TASK-HLR-002A
  re-readiness r2 #417 merge；reviewed head =
  `cdda3cc144cb66335097fd7b3cb8130f00d3fc9c`）。
- Branch:`agent/hlr-002a-bootstrap-partition-r2`。
- Classification:`contract`，host-only/offline；零真实设备、HDC、credential、
  identity/secret/scheduler、Issue/ref/lease、网络/API 或外部副作用。
- Historical failure boundary:#412 已关闭且 `merged=false`；本 run 不复用其
  branch、head 或 checks。
- Task state boundary:本 implementation/evidence run 不翻 `ready→done`；
  post-merge live control/canary 与 completion 各走独立 PR。

## Deliverables

- `.github/workflows/agent-pr.yml`：保留 `agent/**` include，并按序增加
  `!agent/host-loop/**`，隔离 host-loop reserved namespace。
- `scripts/test_agent_pr_workflow.py`：Python standard-library 封闭 extractor、
  ordered glob evaluator、workflow filter 正反 contract，以及 task/lease/probe
  reserved grammar 正反矩阵；不执行 network、subprocess 或 shell。
- `scripts/check_pr_paths.py`：单一 `TASK_TOKEN_TEXT`
  `TASK-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}[A-Z]?` 同时驱动 token、Task line、
  full task 与 task header grammar。
- `scripts/test_check_pr_paths.py`：覆盖 suffix/numeric title/body 正例，以及
  lowercase、双字符 suffix、缺三位数字、邻接污染、多个不一致 Task、unknown
  active task 与描述性 branch slug 的 fail-closed 行为。

## Offline commands and results

| Command | Result |
| --- | --- |
| `python3 scripts/test_agent_pr_workflow.py` | PASS，6 tests |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/host_loop -p 'test_*.py'` | PASS，17 tests |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_check_pr_paths.py` | PASS，21 tests |
| `PYTHONDONTWRITEBYTECODE=1 <existing-sdd-python> scripts/test_check_sdd.py` | PASS，19 tests；interpreter 绝对路径按 privacy 边界不入 evidence |
| `ARKDECK_PYTHON=<existing-sdd-python> ./scripts/check-sdd.sh` | PASS，0 errors / 0 warnings / 111 acceptance IDs |
| `git diff --check` | PASS |

## Scope and pin audit

- Allowed implementation diff 仅为 workflow、两个 path-checker 文件、新 workflow
  test 与本 evidence。
- `.github/workflows/sdd-guard.yml` blob =
  `809147e462512d970813d1992a3fcdf41f8b4b10`；
  `.github/workflows/swift-ci.yml` blob =
  `640065f3f3849e1add0cc6bfa92078873eb315ef`。
- `scripts/host_loop/**`、task/change 状态、identity/secret/scheduler、产品
  source/tests 与其他 change diff = 0。

## Repository integration gate

- First-source commit =
  `fe2de6e1f3458c5803fb8cb6afe3452321684008`，subject =
  `feat(TASK-HLR-002A): partition suffix-compatible bootstrap`。
- 同一 exact head 的 push runs 均 terminal success：
  Agent PR `29996251679`（created `2026-07-23T09:40:07Z`，updated
  `09:40:17Z`）、SDD Guard `29996251870`（updated `09:40:18Z`）、
  Swift CI `29996251655`（updated `09:42:44Z`）。
- Agent PR run 唯一创建 #419：state=`open`、draft=`false`、author =
  `github-actions[bot]`、base =
  `e69a0c23b327571327bfce4a87d5e50f406db256`、head 恰为 first-source
  commit；created `2026-07-23T09:40:14Z`。
- `2026-07-23T09:43Z` all-state exact-branch query 返回 count = 1，唯一项
  为 #419；未手工创建或修改 PR，未复用 #412。
- first-source head 的 pull-request SDD Guard `29996264791` 与 Swift CI
  `29996264969` 被 GitHub 标为 `action_required`；此事实不冒充 success，最终
  synchronize head 仍须取得真实 PR-event terminal success。
- Synchronize-head facts:pending；PR 创建后只允许在本文件追加 first-source
  facts 的 evidence-only commit，再核验 pull-request `guard`、`allowed-paths`、
  Swift CI 与 Agent PR 幂等性。
- 以上 pending 不声明 PASS，也不是 post-merge live canary；不得以 elapsed time
  或 #412 checks 替代真实 exact-head repository evidence。
