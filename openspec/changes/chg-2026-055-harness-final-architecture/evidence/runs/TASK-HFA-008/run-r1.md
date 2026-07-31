# TASK-HFA-008 run r1 — 定位证据的 typed 读取面,以及「八个」变成四个的三条依据

- Date:2026-07-31
- Executor:agent(维护者指示:完成全部 HFA;§20 冻结门显式提前解冻)
- Source baseline:`main@58117ed3`
- Hardware:none(host-only,按定义不碰设备)
- Catalog digest:随本 PR 更新(生成器写入,零 drift)

## 1. 交付了什么

四个新 operation,全部 `provider: workspace`、`binding: none`、`effect: hostOnly`:

| operation | argv(逐 token 已在测试中钉死) |
|---|---|
| `workspace.inspect-git-status@1` | `-C <resolved root> status --porcelain=v1 --untracked-files=all` |
| `workspace.inspect-diff@1` | `-C <resolved root> diff --stat <baseRevision> -- <pathScope>` |
| `workspace.read-source-range@1` | `-n <start>,<end>p <resolved root>/<profile-scoped path>` |
| `workspace.create-checkpoint@1` | `-C <resolved root> stash create` |

四条边界是这批 operation 存在的理由,不是描述:

- **根由 provider 解析**:`-C <root>` 永远在最前,调用方给的是 `projectRef`,不是路径;
- **输入不能变成选项**:revision 与 pathScope 经独立校验(禁 `-` 前缀、禁 `..`、禁绝对路径),
  diff 的 `--` 终止符位置本身是断言项;
- **读取有界**:`read-source-range` 的跨度上限 2000 行,倒置区间拒绝——无界的"读"就是
  "把仓库发出去";路径必须命中 ProjectProfile 已声明的 glob;
- **checkpoint 不动任何东西**:`stash create` 写一个 git 对象,不动 ref、index、worktree;
  git 没吐出对象 id 时判 `failed`,因为"以为自己能回滚"比没有 checkpoint 更危险。

## 2. 「八个」为什么按实际能力交付了四个

任务标题原写「八个 typed operation」,来源是终版 §18.3 的表格。逐条对表后,三条依据
(§5:判重以产品结果为准,不以任务名为准):

1. **`searchSource@1` 已经存在** —— 就是 `workspace.inspect-source@1`
   (pinned grep + symbol + fileScope glob,TASK-HTP-007 交付,argv 已逐 token 钉死)。
   再发一个语义相同的 operation 是重复能力,不做。
2. **`inspectSymbol@1` 是组合而不是第三个 operation** —— 「符号上下文」=
   `inspect-source@1` 定位 + 本任务 `read-source-range@1` 取上下文。组合发生在 handler 的
   规划面(TASK-HFA-003),不需要新的执行面。
3. **`parseBuildFailure@1` / `collectBuildOutputs@1` 移交 TASK-HFA-007** —— 两者都
   **消费既有 artifact 并发布 derived artifact**,依赖 analyzer/derived-artifact 流水线与
   artifact input resolver;放在本任务会先造一套只此一处使用的 artifact 消费路径,
   与 007 重复。007 的 Scope 已同 PR 追加这两条。

三条都写进了 `tasks.md` 的 Done 行,可逐条复核。

## 3. 一处命名偏离

终版 §18.3 把产物写作 `git-status.json` / `diff-summary.json`。git 的实际输出是文本
(`--porcelain=v1`、`--stat`),因此产物名用 `.txt`。把文本命名成 `.json` 会让下游按 JSON
解析并失败——那是不实描述,不是格式选择。

## 4. 命令与结果

```text
swift build                                          Build complete
swift test --filter WorkspaceReadOnlyOperationsContractTests
                                                     Executed 14 tests, 0 failures
swift test                                           Executed 973 tests, 1 skipped, 0 failures
.venv-sdd/bin/python3 scripts/catalog_gen/generate.py --write   wrote generated catalog + matrix
.venv-sdd/bin/python3 scripts/catalog_gen/test_generate.py      Ran 39 tests, OK
./scripts/check-sdd.sh                               0 error(s), 0 warning(s), 114 acceptance IDs
```

本任务新增 14 例。词表 lockstep 同 PR 更新:step registry、`workflow-step.schema.json`
(枚举 + 条件 + `$defs`)、`WorkflowStep.swift`(枚举 + metadata + 参数校验)、
`scripts/catalog_gen/test_generate.py` 的 operation 清单 pin、两处 Swift catalog pin
(`RuntimeOperationCatalogTests`、`HostOnlyAdmissionContractTests`)、
`WorkflowStepContractTests` 的整数参数 fixture。

## 5. 未覆盖(如实登记)

- **`expectedWorkspaceRevision` 前置**:终版 §18.3 给这些读取 operation 声明了
  `expectedRevision`。要让它有意义,需要 §18.2 的 WorkspaceRevision digest 成为准入前置
  —— 那是 TASK-HFA-009。本任务不写恒真的占位校验;
- **并发键**:沿用既有 `host-exclusive`。只读操作本可共享,但新增
  `host-shared-read-only` 会再动一处词表 lockstep,与本任务的产品收益无关,留待有真实
  并发需求时再改;
- **真机**:host-only,按定义不碰设备;GJ-5 端到端复验属 TASK-HFA-005。
