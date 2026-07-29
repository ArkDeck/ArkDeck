---
id: CHG-2026-050-diagnostics-step-contract
revision: 1
status: approved # 合并本 PR 即维护者批准；合并前不产生实现授权
class: core
core_change_level: minor
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos, windows, linux]
---

# Close the Catalog → typed stdout-step contract

## Why

`TASK-DHA-001` 在实现 `capture.diagnostics@1` 时命中其显式 stop
condition：published Catalog 已声明 HiLog、UI Dump 与 post-run diagnostics
为 `captureRemoteStdout`，但 current `workflow-step.schema.json` 与 Swift
`WorkflowStepValidator` 只允许：

```text
catalogId = arkui-ui-dump
actionId ∈ nodeSummary | elementTree | fullDefaultTree |
           componentDetail | renderTreeLegacy
```

因此 HiLog 无法生成一个如实且 schema-valid 的 durable intent。若以任一
UI Dump action 冒充 HiLog，journal 的 action identity、arguments hash 与后续
recovery evidence 都会失真；若绕过 `WorkflowStepValidator`，则违反
`REQ-WF-001`、`REQ-JOB-002` 与 `POL-WORKFLOW-001`。

根因不只是少一个 enum：operation Catalog 目前只校验 step kind 是否存在于
registry，没有为 catalog-backed stdout step 携带 action identity，也无法在生成
阶段检查该 action 是否能被 workflow-step contract 表达。结果是 Catalog、
JSON Schema、Swift validator 可以分别通过，却在 production 编排处才发现无合法
交集。

## What changes

In scope:

- `Catalog/schema/operation.schema.json` 的 step 增加 closed
  `actionRef { catalogId, actionId }`；对 `captureRemoteStdout` 必填，
  其他 kind 暂不允许携带，避免把它变成任意命令载体。
- 为现有四个 stdout step 补齐 action identity：
  - `capture.diagnostics@1/capture-hilog` → bounded HiLog；
  - `capture.diagnostics@1/capture-ui-dump` → component-tree UI Dump；
  - `debug.hap@1/capture-diagnostics` → bounded HiLog；
  - `flash.dayu200@1/capture-post-flash-diagnostics` → bounded HiLog。
- 新增 closed diagnostics stdout recipe contract，仅声明 bounded HiLog 与
  component-tree UI Dump 所需的 typed parameters、bounds 与 output mode；
  不接受 executable、argv、shell、raw command 或 caller-supplied remote path。
- `scripts/catalog_gen` 在发布/生成前验证：
  1. 每个 `captureRemoteStdout` 都有 actionRef；
  2. catalog/action pair 已登记；
  3. 非 stdout step 不能偷带 actionRef；
  4. 生成的 Swift descriptor 保留同一 pair，drift check 双向一致。
- `workflow-step.schema.json` 与 Swift `WorkflowStepValidator` 同步接受上述
  diagnostics action pair，并继续拒绝未知 catalog/action、越界 typed
  parameters、raw command 字段和 schema/Swift 分歧。
- `REQ-WF-001` 增加一个 fail-closed Scenario：published stdout step
  若缺失、未知或与 workflow-step contract 不可表示，则 Catalog
  validation/generation 失败，外部 dispatch 为 0。

Observable behavior:

- Before：Catalog 可发布一个只有 kind、没有可表达 action identity 的 stdout
  step；问题直到 Runtime 构造 WAL intent 才暴露。
- After：stdout step 的 action identity 是 Catalog 的 machine-readable 数据；
  缺失、未知或 schema/Swift 不闭合时在生成阶段失败。Runtime 只消费生成的
  typed actionRef，不根据 stepID 猜测 action。

## Out of scope

- 不改变任何 operation 的 effect、authorization、binding、cancellation、
  optional/compensation、输入输出或步骤顺序；
- 不执行真实设备采集，不创建/签发 E1 capability，不触碰 E2；
- 不把所有 typed step 一次性迁移到 actionRef；本 change 只关闭已实际命中的
  `captureRemoteStdout` 缝隙，其他 kind 的参数闭包另需独立 change；
- 不实现 `TASK-DHA-001` 的 artifact、diagnostics 或 HAP 功能；本 change 合入并
  完成后，CHG-2026-049 需重新 readiness，再从保存的实现草稿继续；
- 不修改 current `openspec/specs/**` 或全局 acceptance registry；这些只在
  verified 后的独立 archive PR 精确合入。

## Scope

- Requirement:`REQ-WF-001` (MODIFIED，保留 `AC-WF-001-01`，新增
  `AC-WF-001-02`)
- Acceptance:`AC-WF-001-01` (保留)、`AC-WF-001-02` (ADDED)
- Contracts/schemas:
  - `Catalog/schema/operation.schema.json`
  - `openspec/contracts/workflow-step.schema.json`
  - new diagnostics stdout recipe catalog
  - generated Swift Catalog descriptor
- Core baseline bump:需要，archive 时 `CORE-2.1.0 → CORE-2.2.0`
  (MINOR：收紧 published Catalog 的 fail-closed 校验并新增 action identity，
  不放宽既有 safety invariant)

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | implementation + contract reverify | 当前 Runtime 实现平台，需验证 Catalog→Swift→WAL 构造闭包 |
| Windows / Linux | not started / contract applies | 共用 Core Catalog 与 workflow contract；不产生平台支持声明 |

## Safety, privacy, and compatibility

- Failure mode：actionRef 缺失、未知、kind 不匹配、Catalog/Schema/Swift drift
  一律 build-time fail closed；Runtime 不 fallback 到 stepID 猜测或通用 shell。
- Compatibility：现有 operation ID/version、effect 与输入输出不变；新增
  actionRef 是同版本 Catalog 的安全补全，因为这些 steps 在 current contract 下
  尚不可执行，不存在可保持的成功生产行为。
- Privacy：只新增 action identity 与参数规则，不采集或提交原始日志。
- Rollback：revert implementation PR 后恢复为 blocked 状态；不得通过移除
  `AC-WF-001-02` 或放宽 validator 来“修复”回归。

## Approval and flow

本 proposal PR 合并即批准 `TASK-WSC-001`。实现 PR 完成 schema、Catalog、
generator、Swift parity 与 contract evidence 后，另起 verification/archive
载体。`TASK-DHA-001` 在本 change 完成且经 fresh readiness 前保持 blocked。
