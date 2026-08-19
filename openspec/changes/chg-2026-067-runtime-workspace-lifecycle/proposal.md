---
id: CHG-2026-067-runtime-workspace-lifecycle
revision: 1
status: proposed
class: capability
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# CHG-2026-067 — Runtime-owned 隔离工作区补全生命周期：被补丁过的树可收养，安静的树可清扫

> **本文件不构成批准。** 本 proposal 经维护者 review/merge 进 protected `main`
> 后，TASK-RWL-001 方可开始实现 PR。

> **恰四类声明**：本 change 引入**一个新 published operation**
> （`workspace.sweep-isolated-copies@1`，host-only），按 `AGENTS.md` 控制平面
> 条款与 `PRODUCT-LOOP.md` §22 走 OpenSpec + 维护者 PR review/merge，且与
> GJ-5 同车交付。收养修复是纯 runtime 产品缺陷修复，与新 operation 同属
> 「runtime-owned 工作区生命周期」一个问题，合并在同一垂直任务内。

## §19 治理循环四问

1. **对应的真实安全风险**：两条，均命中 `PRODUCT-LOOP.md` §3。
   ① **可恢复性破坏**（§3-6 变体）：`EvolutionWorkspaceManager.
   adoptRuntimeWorkspaces` 只接受测得 revision == 创建时 `baseRevision` 的树
   （`EvolutionWorkspaceManager.swift` 收养循环内的 `:revision` 拒绝）。一棵经
   `workspace.apply-patch@1` 合法修补的树**必然**漂移，daemon 重启后即失去收养
   ——跨重启的修复会话丢工作区，且失败理由把「合法生命史」报成「不可信漂移」。
   2026-08-19 本机实证：`runtime workspace not adopted for
   evo-360b54f898e2575df90fcd90:revision`（AND-002 r2 那棵、生命史完整的树）。
   ② **无界资源增长**：CHG-2026-064 移除任务平面后，
   `sweepTerminalWorkspaces` 的生产调用方为 **0**（原唯一入口
   `arkdeck task workspace-gc` 已删）。每次 `workspace.prepare-isolated-copy@1`
   都在 daemon state 下留下一棵按值拷贝的树，只生不灭。
2. **为什么不能直接通过 Runtime 代码修复**：② 需要新 published operation
   （清扫必须是可审计的 typed 面，不能是 daemon 内的静默定时器——那会重新
   制造一个无人调用面背后的自主副作用）；`AGENTS.md`/§22 要求先批准。
   ① 是纯 runtime 缺陷，但与 ② 同属一条生命周期线，按 §12「结构性改动与
   Golden Journey 同车」合并交付，不单独立项。
3. **推进哪个 Golden Journey**：GJ-5。收养修复让跨 daemon 重启的外部 agent
   修复会话不再丢隔离工作区（有界闭环的 durable 前提）；清扫面让每次 GJ-5
   会话的工作区遗留有界。本 change 不宣称任何 GJ 状态翻转。
4. **为什么不会产生后续连锁任务**：`proposed` 落地，merge 即批准；单个垂直
   任务一个实现 PR（代码 + 合约测试 + 本机真实工作区存量实证 + 最小文档），
   verification 结论写入同一 PR；不建 readiness/status/archive 载体。

## Why（根因：出生有面，生与死没有）

CHG-2026-061 给了 runtime-owned 隔离副本**出生**（`prepare-isolated-copy`：
精确拷贝、manifest 落盘、跨重启收养）。CHG-2026-064 删除任务平面时把
harness 侧的生命周期机器一并退役，并如实登记了两个遗留（064 design.md §5、
LaunchAgents README 操作者注记）。今天的仓内硬事实（2026-08-19 实测）：

- **收养把合法生命史当漂移**：`adoptRuntimeWorkspaces` 测量
  `allowedPaths` 域的当前 revision，与 manifest 的 `baseRevision` 严格相等
  才注册；`apply-patch` 不更新 manifest（by design——manifest 是出生证明）。
  于是「被补丁过」与「被篡改过」在收养面不可区分，都拒。
- **生命史其实已被 runtime 持久化，只是收养不读它**：
  `WorkspacePatchAttempt`（`WorkspaceOperationsProvider.swift:590`）按
  projectRef 持久记录 `workspaceRevisionBefore`/`workspaceRevisionAfter`/
  `appliedAtUTC`/`revertedAtUTC`——从 `baseRevision` 到当前测得值的完整
  修订链就躺在 `WorkspacePatchAttemptStore` 里。
- **清扫机器在、调用面没了**：064 刻意保留了
  `sweepTerminalWorkspaces`（含 retention、按 disposition 分类、审计元数据
  幸存语义）与 `EvolutionWorkspaceGCLifecycle` 中性证词类型，等的就是一个
  runtime-owned 的调用面与证词来源。
- **证词来源现成**：daemon 的 durable job 台账知道每个 job 的终态与其
  `projectRef` 输入——「这棵树还有没有人在用」是 runtime 自己的一等事实，
  不需要任何会话对象来补。

## What changes（单任务两个交付面）

### 1. 收养承认血统（修复，无新面）

`adoptRuntimeWorkspaces` 增加一个注入的只读血统端口（实现 =
`WorkspacePatchAttemptStore`）。测得 revision R 的接受条件从
「R == baseRevision」放宽为：

```text
R == baseRevision
  ∨ 存在该派生 projectRef 的持久 attempt 链，按 appliedAtUTC 顺序、
    经 applied/reverted 状态折叠后，从 baseRevision 精确推导出 R
```

链断裂、多头、或推导结果 ≠ R 时，保持既有具名拒绝（`:revision`）不放宽；
`allowedPathsDigest`/metadata 检查不变。manifest 保持不可变的出生证明。

### 2. `workspace.sweep-isolated-copies@1`（新 operation，host-only）

- **闭合输入**：`retainLatestCount`（0…64）、`minimumQuiescentSeconds`
  （0…7776000，90 天）、`dryRun`（bool）。无路径、无 ID、无 glob。
- **证词由 engine 从自己的台账计算**：materialize 时，engine 为每棵
  持久化工作区求值——引用它的全部 job（创建它的 prepare job + 一切以其派生
  projectRef 为输入的 job）是否全部终态，及最近一次终态转移时刻。据此生成
  `EvolutionWorkspaceGCLifecycle(rawValue:isTerminal:)` 证词
  （`quiescent`/`activeJob`/`unreferenced`），随 typed action **持久化**后
  才执行——证词是审计的一部分，不在执行时重算。
- **执行复用既有机器**：`RuntimeOwnedWorkspaceDispatcher` 把证词交给
  `sweepTerminalWorkspaces`；retention（age + latest-count）语义不变；
  摧毁只及 isolated 树本体，`workspace.json`、attempt manifests 与
  teardown 记录幸存（既有语义）。
- **fail-closed 分类**：活跃 job 的树、收养失败（metadata/scopes/revision
  不可担保）的树、证词缺失的树一律 retained 并具名 disposition，永不摧毁。
- **产物**：path-free findings JSON（workspaceID、disposition、
  reclaimedBytes、证词摘要），经既有 artifact 面发布。
- 调用走既有已发布面（`job.submit`/`agent run`），不新增 CLI 子命令。

## Requirements

### RWL-REQ-001 — 血统收养，fail-closed

收养 SHALL 接受且仅接受「baseRevision 或持久 attempt 链可精确推导」的测得
revision；链不可推导时 SHALL 保持具名拒绝并不注册派生 profile。收养 SHALL NOT
改写 manifest 或 attempt 记录。

### RWL-REQ-002 — 证词只来自 runtime 台账且随 action 持久

清扫的每条生命周期证词 SHALL 由 engine 从 durable job 台账推导（引用 job 的
终态与时刻），SHALL 随 typed action 持久化后再执行；caller SHALL NOT 能提供
或篡改证词。

### RWL-REQ-003 — 清扫永不摧毁不可担保者

`workspace.sweep-isolated-copies@1` 的输入 SHALL 是上述闭合三元组；活跃、
不可收养、无证词或在 retention 窗口内的树 SHALL retained 并具名 disposition；
`dryRun` 与实扫的分类结果 SHALL 逐树一致（仅摧毁动作与 reclaimedBytes 差异）。
主树与任何 caller 路径 SHALL 不可及。

### RWL-REQ-004 — 审计幸存

每次摧毁 SHALL 留存 teardown 记录并保全 `workspace.json` 与 attempt
manifests；findings SHALL path-free。

## Acceptance

`RWL-AC-1..7`，全文见 `verification.md`。

## 强制重复搜索结论（§5）

搜索面 = 活跃 change（061/064/065/066）、`Catalog/operations/`（20 个）、
`WorkspaceProvider/`/`AgentComposition/`、近期合入（#1400–#1407）、
`openspec/**` 全文（`sweep|gc|adoption|lineage|revision`）。结论：061 是本
change 的出生面前置（不重复，是延续）；064 的 design.md §5 与 LaunchAgents
README 已把这两个遗留登记为后续任务，本 change 即该任务；`task.workspace-gc`
按 §16 为历史记录不重启；与 065/066（flash 线）无交集。

## 平台影响

macOS runtime plane only。不触碰设备命令、binding、capability 语义、E2 策略、
主树 git 面（清扫不含任何 git 调用）。不产生新的平台端口义务。

## Out of scope

- 自动/定时清扫（daemon 内定时器）——清扫永远是显式提交的 typed job；
- 主树或非 evolution 工作区的任何清理；
- demo-app hypium 依赖库恢复（独立任务卡）；
- 收养语义之外的 manifest schema 演进。

## Safety, privacy, compatibility and rollback

- **安全**：摧毁的唯一对象是 daemon-owned 隔离树本体，且必须同时通过
  「runtime 台账证词 + retention + 可收养担保」三道门；证词随 durable action
  可审计。收养放宽仅及「链可精确推导」，篡改树仍拒。
- **隐私**：findings 与 teardown 记录 path-free；不新增任何出站面。
- **兼容**：既有 manifest/attempt 记录零迁移；旧的未收养树在修复后自动恢复
  可收养（本机 `evo-360b54f8…` 即实证对象）；catalog digest 增加恰一个
  operation（generator + zero-drift 校验）。
- **回滚**：revert 实现 PR 即回滚；无持久 schema 变化需要清理；已被清扫的
  树不可恢复——这正是三道门与 `dryRun` 存在的原因。
