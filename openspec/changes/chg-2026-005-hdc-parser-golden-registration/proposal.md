---
id: CHG-2026-005-hdc-parser-golden-registration
revision: 2
status: approved
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos, windows, linux]
---

# Register the complete HDC semantic fixture inputs required by M1-006

## Why

`TASK-M1-006` 认领了 `AC-HDC-005-01`，其 canonical minimum evidence 为
`parserGolden`。M0A 已在
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HDC/HDCFixtures.swift`
留下候选 fixture（当前 SHA-256
`22be193bc03f84fa1484be87128c40b8031a7b9fdbb5478b65c429a046680c7b`），
但 `CORE-CONFORMANCE-2.0.0` 与 `INTEGRATION-PROFILES-0.2.0` 的 fixture
列表仍为空。两份 accepted 输入明确禁止用未经 approved integration
change 的 fixture 判定 parserGolden AC 通过。

原草案只覆盖失败 bytes，但 `TASK-M1-006` 的 fake-hdc matrix 还把 standalone
success、healthy/checkserver 与 version output 当成已支持语义。当前仓库没有为这些
family 提供 approved golden 或可复查真实 evidence；仅登记失败 fixture 不能解除
M1-006 readiness。

本 change 将已有失败候选字节与后续由维护者认可 provenance 的 success/health/version
raw bytes 提升为可独立 review、版本化、hash-pinned 的完整 fixture pack，并同步升级
OpenHarmony integration profile 的精确 mapping。缺任一 provenance/input 时任务保持
blocked；不得由 Agent 猜测真实 HDC 输出或执行已安装 `hdc` 取得样本。

## What changes

### In scope

- 把 M0A 候选 fixture 中已有的 exit-0 + `[Fail]`/E000003/Unauthorized
  与 exit-0 + `[Fail]`/Offline 字节拆分为只读的版本化 raw fixture；
- 仅从维护者认可的 authoritative source 或受控人工 capture 输入中登记 standalone
  success、healthy/checkserver 与 version raw fixture；每个输入必须保留原始 bytes、
  tool/version/command context、source lineage 与 evidence 分类；
- 为每个 raw fixture 记录稳定 ID、version、stream、exit code、expected semantic
  classification、source lineage 与 SHA-256；
- 在 `ArkDeckContractTests` test target 中把 `Fixtures/HDC/Golden` 注册为 SwiftPM
  `.copy` resource tree，并用 `Bundle.module` smoke/hash test 证明版本化目录可构建、可按
  registry path 定位且不会产生 unhandled-file warning；
- 升级 `OPENHARMONY-TOOLS` integration profile，逐 family 声明 probe/semantic mapping；
  未登记 output 继续 `unknown/unsupported`，不得用 exit 0 单独判 success；
- 将 fixture 精确登记到新版本 Integration lock 与 Core conformance shared
  inputs，并使两份登记的 ID/path/version/hash 一致；
- 在 fixture 登记合入后，以独立 readiness/status PR 修订 `TASK-M1-006`
  为只读消费 pinned fixture；只有 M1-005 `DurableSessionAuditAppending`/
  `SessionManifestPublishing` 依赖与 M1-006 r3 design/UI/audit 修订也已合入时，才能恢复
  为 `ready`。

### Out of scope

- 实现或放宽 parser marker/正则；本 change 只登记经批准的 family/mapping，实际 parser
  接线属于 M1-006；
- 改变 `REQ-HDC-005`/`AC-HDC-005-01` 的文本、expected result 或 evidence
  class；
- 实现 HDC supervisor、authorization、endpoint、lifecycle 或 fake-hdc 子进程；
- 执行任何已安装的真实 `hdc`、访问设备、外联网络或产生真机/
  release/conformance 声明；
- 由 Agent 编造 standalone success/health/version bytes，或把 fake-only control protocol
  冒充真实 HDC semantic evidence；
- 修改 Core Requirement/AC、contract/schema、baseline 或 platform profile。

## Scope

- Requirement:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-005`
- Acceptance:`AC-HDC-005-01`(仅解除 fixture prerequisite，本 change 不宣称该
  AC passed)；其他 success/health/version fixtures 仅解除 M1-006 platform matrix 输入
  prerequisite，不宣称其他 HDC AC passed
- Integration inputs:`OPENHARMONY-TOOLS@0.1.0`、
  `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
- Verification inputs:`openspec/verification/core-conformance.yaml`
- Core baseline bump:no

## Safety, privacy, and compatibility

- Failure fixture 来自仓库内已有 M0A 候选字节；success/health/version 只接受维护者认可
  provenance 的原始输入。所有 fixture 不得包含真实设备标识、私钥、用户路径或外部
  Artifact。
- 验证只做字节比对、hash 校验与 SDD lint；HDC/process/network/device/
  destructive dispatch 均为 0。
- 仅修改 integration/conformance 输入登记，不改变任何平台的产品实现或
  conformance status；macOS/Windows/Linux 均不触发平台 revalidation。
- 回滚为在新的 approved integration change 中移除登记；不得在未修订
  dependent task/readiness 的情况下静默删除或改写 pinned fixture。

## Approval gate

本 proposal 合入并转为 `approved`，且 standalone success、healthy/checkserver、version
输入的 provenance 由维护者认可前，`TASK-I5-001` 保持 blocked。`TASK-I5-001` 的完整
fixture/profile/lock 实现合入且经独立 readiness/status PR 确认全部 family hash、M1-005
durable seam 依赖与 M1-006 r3 design/UI/audit 权限全部就绪后，`TASK-M1-006` 才能恢复
`ready`。
