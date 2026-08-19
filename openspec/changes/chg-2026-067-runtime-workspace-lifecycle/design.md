# Design — CHG-2026-067

## 1. 血统收养的精确语义

数据源（全部既有、零迁移）：

- Manifest（`evolution-workspaces/<id>/workspace.json`）：出生证明。
  `baseRevision` + `allowedPaths(+digest)` + `htaskID`（runtime-owned 树为
  `runtime-<jobID>`）。**保持不可变。**
- `WorkspacePatchAttemptStore`：生命史。每条 `WorkspacePatchAttempt` 携
  `projectRef`、`workspaceRevisionBefore/After`、`appliedAtUTC`、
  `revertedAtUTC`（`WorkspaceOperationsProvider.swift:590`）。

推导（纯函数，进合约测试）：

```text
expected(base, attempts) =
  按 appliedAtUTC 升序折叠：
    applied 且未 reverted → current = revisionAfter（前置：revisionBefore == current）
    已 reverted           → current 不变（前置校验同上）
  任一前置失败 → 不可推导
```

收养接受条件：`measured == baseRevision ∨ measured == expected(...)`。
不可推导或不等 → 既有 `"<id>:revision"` 拒绝原样保留。

注入形态：manager 增加 `WorkspacePatchLineageReading` 端口（只读，按
projectRef 列 attempts），组合根以既有 `workspaceRepairConfiguration.attempts`
实现注入；端口可选（nil 时行为 == 今日，测试基线不破）。

## 2. 清扫面的接线

```text
job.submit(workspace.sweep-isolated-copies@1, {retainLatestCount,
                                               minimumQuiescentSeconds, dryRun})
  → admission（host-only，binding: none，闭合输入校验）
  → materialize：engine 枚举持久化工作区 manifest；对每棵树收集
      引用 job 集 = {创建 prepare job} ∪ {inputs.projectRef == 派生 ref 的 job}
      证词 = all terminal ? quiescent(最近终态时刻) : activeJob
             引用集为空 → unreferenced（按 manifest createdAtUTC 计龄）
    证词数组随 typed action 持久化（durable intent 的一部分）
  → RuntimeOwnedWorkspaceDispatcher → manager.sweepTerminalWorkspaces(
      tasks: 证词映射为 EvolutionWorkspaceGCTaskReference,
      retention: EvolutionWorkspaceRetention(minimumTerminalAgeSeconds:
                 minimumQuiescentSeconds, retainLatestTerminalCount:
                 retainLatestCount, dryRun: dryRun))
  → findings JSON artifact（path-free）
```

要点：

- **证词在 materialize 时冻结**：执行阶段不得重算（重算会让审计与行为
  脱钩）；两次执行同一 durable action 幂等地基于同一份证词。
- job 台账扫描有界：现存 job 数量级 ~1.2k，manifest 数 ≤4096（收养同款
  上界）；实现声明扫描上界并在超界时具名拒绝而非静默截断。
- 收养失败的树（metadata/scopes/revision 不可担保）由 manager 现有分类
  retained；本 change 不为其新增摧毁路径。
- disposition 词表沿用既有 `EvolutionWorkspaceGCDisposition`；若需新值
  （如 `unreferencedRetained`），按封闭词表纪律同步其测试。

## 3. 触碰面清单（实现 PR 对账用）

| 面 | 变化 |
| --- | --- |
| `Catalog/operations/workspace.sweep-isolated-copies.v1.json` | 新增（照 prepare-isolated-copy 形态：hostOnly/defaultReadOnly/binding none；concurrencyKey host-exclusive） |
| catalog generator + `RuntimeOperationCatalogGenerated` | 再生，digest 前进恰一个 op |
| `ArkDeckWorkflows` WorkspaceProvider | 新 typed action `sweepIsolatedCopies` 的 descriptor/step kind 注册 |
| `RuntimeJobEngine` | materialize 时的证词求值（只读自家台账） |
| `AgentComposition/EvolutionWorkspaceManager.swift` | 血统端口注入 + 收养推导；sweep 入参映射 |
| `AgentComposition/RuntimeOwnedWorkspaceDispatcher.swift` | sweep action 分发 |
| `ArkDeckAgentDaemonMain/main.swift` | 组合根注入 lineage 端口 |
| 合约测试 | 血统推导纯函数矩阵、收养正/负例（含篡改树仍拒）、dry-run 一致性、活跃树保全、证词冻结、findings path-free、catalog zero-drift |

## 4. 本机存量即实证夹具

这台机器的 daemon state 里现存 AND-002 r2 的
`evo-360b54f898e2575df90fcd90`（baseRevision `701c5bd9…`，一条 applied 未
reverted 的 attempt 到 `aed6966b…`，引用 job 全部终态）：

- 收养修复的验收正例：daemon 重启后该树注册成功、日志不再出现
  `…:revision`；
- 清扫的验收序列：`dryRun` 分类 → 复核 findings → 实扫摧毁 →
  `workspace.json`/attempt manifests/teardown 记录幸存。

Hardware required: no——全部证据来自宿主侧真实存量，不连设备。
