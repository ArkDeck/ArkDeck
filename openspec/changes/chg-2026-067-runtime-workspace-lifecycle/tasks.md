# Tasks — CHG-2026-067

单任务垂直交付。`ready` 只有在本 proposal PR 经维护者 review/merge 进入
protected `main` 后生效；合入前不得开始实现 PR。实现 PR 必须以
`scripts/check_pr_paths.py --preflight` 用本文件 base-tree 的 Allowed paths
覆盖完整 diff，不得在同一实现 PR 内扩张本声明。

## TASK-RWL-001 — Runtime-owned 工作区生命周期：血统收养 + 清扫面

- Status:done（2026-08-19；血统收养与清扫面全链实现并在生产 daemon 的真实
  存量上取证——`evo-360b54f8…` 由血统收养恢复注册后经 dry/wet 清扫送走
  （18MB 回收、审计三件套幸存），54 棵 harness 遗留树 fail-closed 保全；
  证词合成点的实施勘误见 design.md §5 与 evidence run-r1.md）
- Golden Journey:GJ-5（跨重启修复会话的 durable 前提 + 会话遗留有界；
  本任务不翻转任何 GJ 状态）
- Platform:macos
- Requirements:`RWL-REQ-001..004`
- Acceptance:`RWL-AC-1..7`（见 verification.md）
- Depends on:本 proposal merge；CHG-2026-061 的出生面与 CHG-2026-064 的
  移除收官（均已在 `main`）
- Applicable failure patterns:
  - `AF-002`（production reachability）——清扫必须经真实
    `job.submit → admission → dispatcher → manager` 全链取证，不得以
    manager 单元直调冒充生产可达；
  - `AF-008`（信任边界对抗）——caller 供词/篡改树/链断裂各要有否定用例：
    证词字段不在输入 schema、篡改树收养仍拒、断链不可推导；
  - `AF-011`（exit 0 ≠ 成功）——摧毁以文件系统 readback（树不存在 +
    审计幸存者存在）取证，不以 job succeeded 为唯一证据。
- Production reachability:
  `caller → job.submit(workspace.sweep-isolated-copies@1) → host-only
   admission → materialize(证词自 durable job 台账) → durable typed action
   → RuntimeOwnedWorkspaceDispatcher → EvolutionWorkspaceManager.sweep →
   findings artifact`；收养链：`daemon 启动 → adoptRuntimeWorkspaces →
   血统端口(WorkspacePatchAttemptStore) → 派生 profile 注册`
- Trusted fact sources:工作区身份/revision 来自 manifest 与
  `WorkspaceProviderSupport.workspaceRevision` 度量；生命史来自
  `WorkspacePatchAttemptStore` 持久记录;引用与终态来自 durable job 台账；
  caller 只提供闭合三元组输入，SHALL NOT 提供证词、路径或 ID
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckRuntime/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/**`（Core 侧的 operation 名册、
    step 词表锁定与逐 kind 构造样例都在此 target；新增 operation/step kind
    必然触碰，起草时漏列——与上一行同为测试目录授权）
  - `Packages/ArkDeckKit/APIBaseline/**`
  - `Catalog/**`
  - `scripts/catalog_gen/**`
  - `docs/**`
  - `Packages/ArkDeckKit/LaunchAgents/README.md`（交付项 4 的操作者注记载体，
    起草时漏列；本行是精确单文件扩权）
  - `openspec/contracts/workflow-step-registry.yaml`（新 step kind 的封闭
    注册表；单文件精确扩权，承 CHG-2026-061 TASK-RIW-001 同款先例——generator
    fail-closed 要求 step kind 先登记）
  - `openspec/contracts/workflow-step.schema.json`（注册表的孪生契约：step
    kind 词表 enum 与 per-kind 参数 schema 由 `WorkflowStepContractTests`
    与 Core 枚举三方锁定，新 kind 必须同步三处；第一轮扩权只列了 yaml，
    CI 全量套件暴露此文件后补——step 词表的完整落点 = Core 枚举 +
    registry.yaml + schema.json，三处一体）
  - `openspec/changes/chg-2026-067-runtime-workspace-lifecycle/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`（上列 `workflow-step-registry.yaml` 单文件除外）、
    其他 change 目录、`AGENTS.md`、`PRODUCT-LOOP.md`、`.github/**`
  - `tests/waterflow-demo/**`（主树夹具不参与本任务）
  - 既有 daemon state 的手工改写（存量树只经产品路径收养/清扫）
- Risk:medium（新增 host-only operation 与收养放宽；三道门 + dryRun +
  证词持久化钉死破坏面；设备面零触碰）
- Hardware required:no（宿主侧真实存量取证：本机 `evo-360b54f8…`）
- Decision-Grade:D1（新 published operation 的 exact Catalog materialization
  随实现 PR 由维护者 review/merge 批准）
- 交付内容:
  1. 血统端口 + 收养推导（含纯函数推导矩阵测试与篡改负例）；
  2. `workspace.sweep-isolated-copies@1` 全链（catalog、typed action、
     engine 证词求值、dispatcher、manager 映射、findings artifact）；
  3. 本机存量实证：`evo-360b54f8…` 收养成功 + dryRun/实扫序列，记录进
     `evidence/runs/TASK-RWL-001/`（path-free）；
  4. LaunchAgents README 的 064 操作者注记补一行「存量树的收养与清扫已有
     产品路径」；docs 最小更新。
