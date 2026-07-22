# TASK-MECH-004 run — PR allowed-paths diff guard

- Date:2026-07-22;executor:agent(host-only contract/CI;零设备、零 HDC、零
  network dispatch、零 secret)。
- Base:`2c8aacad5ca8bf78e62171d4a71bbc2cabdd9bd0`(fresh `origin/main`)。
- Readiness pin:`.github/workflows/sdd-guard.yml` blob
  `4a44098728cab7ac9752a6c539b28eaeb83ed13f` = **MATCH**;
  `scripts/check_pr_paths.py`/`scripts/test_check_pr_paths.py` 于 base 不存在;
  open PR 扫描为 0,零文件竞争。
- Evidence class:contract + live CI guard-rail;不构成批准/授权、安全边界或
  hardware evidence。

## Deliverables

- `scripts/check_pr_paths.py`:从 `$GITHUB_EVENT_PATH` 读取 PR title/body/head
  ref/base+head full OID,不把不可信字段插入 shell;按 body 独立 `Task:` 行 →
  title token → `agent/task-*` 顺序解析声明,互异声明/未知 task/无或空
  Allowed paths 均具名 fail closed;只扫描 active `chg-*/tasks.md`,archive
  不参与;用 `git diff --no-renames --name-only -z base..head` 与 fnmatch
  校验;未声明 task 的敏感面五类封闭列举。
- `scripts/test_check_pr_paths.py`:合成 fixture 覆盖声明优先级/歧义、exact+
  `**` 跨层 glob、`本 change` 展开、全部五类敏感面、docs-only 通过、未知
  task、Allowed paths 缺失/零 token、archive 跳过、现有 label 变体、复杂
  task header 分段以及 implementation/status/propose 三种形态。
- `.github/workflows/sdd-guard.yml`:保留既有 `guard` job 字节不动;新增只在
  `pull_request` event 执行的 `allowed-paths` job,`contents: read`、
  fetch-depth 0、10 分钟 timeout;先跑 contract tests 再审 live diff。

## Local verification

| Command/check | Result |
| --- | --- |
| `python3 scripts/test_check_pr_paths.py` | PASS:10 tests,0 failures/errors/skips |
| `python3 -m py_compile scripts/check_pr_paths.py scripts/test_check_pr_paths.py` | PASS |
| `ARKDECK_PYTHON=<PRIMARY_CHECKOUT>/.venv-sdd/bin/python ./scripts/check-sdd.sh` | PASS:0 errors,0 warnings,111 acceptance IDs(Python 3.14.6/PyYAML 6.0.3) |
| `git diff --check` | PASS |
| static shell audit | PASS:`subprocess.run` 仅 executable+argv array,零 `shell=True`/`os.system`;workflow 零 PR title/body/head expression 插值 |

首轮曾以 `python3 -m unittest -v scripts/test_check_pr_paths.py` 调用,因该
module 形态不把 `scripts/` 放入 import path 而产生 `ModuleNotFoundError`;
实现随即把 workflow 改为与仓库既有 guard test 相同的直接脚本入口,最终
direct run 10/0。该失败发生在 test harness import 阶段,未计为 guard
contract failure,亦未以强制 success 绕过。

## Active-format compatibility audit

实现前后以同一解析器扫描 active task headers:40 个 active task 中 31 个
符合 readiness 钉定的声明 token grammar;其中 27 个 Allowed paths 行可解析,
4 个会如实 fail closed:TASK-AIN-004 有多个 Allowed paths 行;
TASK-AU-002/TASK-OBS-001/TASK-OBS-002 缺该行。这四项当前均非 ready,未来
readiness 应在成 PR 工作前闭合格式,本任务不越界改写它们。

另有一个**当前 ready lane 的合并顺序风险**:TASK-TR-003 的 Allowed paths
行只有 `Packages/ArkDeckKit/Sources/**` 与 change evidence/tasks 两类
backtick token;其 prose“对应 Tests”不是机器 token,故本 guard 会拒绝
readiness 正文另行钉定的
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/TraceAdapterGoldenTests.swift`。
不得在本实现 PR 内改写 TR-003 readiness。处置须二选一:TR-003 实现 PR
先于本 job 合入,或维护者先批准独立 D1 readiness/allowed-paths 规范化;
拿不准时 fail closed。

## Live evidence / AC state

`MECH-PATH-001`:**candidate,not done**。离线 contract 面已 PASS;实现 PR 的
live `allowed-paths` 绿、越界 canary 红及 implementation/status/propose 三种
真实形态累计须在 push/PR 后追加原始 run 链接。只有绿证据整体不接受;
canary 分支/PR 必须关闭且永不合入。required-status 翻转仍是 out-of-scope
D2 维护者动作;CI 绿不构成批准。

## Deviations and residual risk

- 零 Core/spec/contract/schema/constitution/enforcement 语义改动;archive 零
  改动;本任务不改变 task declaration grammar/readiness pins。
- guard-rail 不防恶意谎报其他 task;批准防线仍是维护者逐 PR review。
- status/propose live 形态只能在对应真实 PR 出现后累计,不以合成 fixture
  冒充;在 evidence gate 未闭合前不得翻 TASK-MECH-004 done。
