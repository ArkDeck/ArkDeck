---
id: CHG-2026-005-hdc-parser-golden-registration
revision: 2
status: archived # 2026-07-21 archive PR(先例 #178;M1-006 done/#207 与 CHG-002 verified/#208 后其只读输入引用面收口);verified 于 2026-07-18 closure PR。原注: 2026-07-18 verification closure(先例 #20/#48):七项 I5-HDC-* gate 全 satisfied;AC-HDC-005-01 仍待 M1-006 parserGolden 实证;经本 PR 维护者 review/merge 生效
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

## Verification closure(2026-07-18)

- 批准:approval-only PR #40 合入 main(`3a4d45c`,先例 #14);I5-001 实现+登记
  经 PR #41 合入 main(`4ac288c`,merge 即维护者对 provenance 与登记的正式认可);
  TASK-I5-001 done 经状态 PR #42(`8162004`);TASK-I5-002(恢复 M1-006
  readiness+自身 done)经 PR #43(`e29462c`,严格后于 #42 merge)。
- 七项 `I5-HDC-*` gate 的实际结论以 `evidence/runs/TASK-I5-001/run.md` 与
  `evidence/runs/TASK-I5-002/run.md` 为准,全部 satisfied:failure 字节 M0A 血统
  `cmp`/契约测试逐字节相等(FIXTURE-001);success/healthy/version 均出自维护者
  2026-07-18 受控采集,零 Agent 执行 hdc(FIXTURE-002);五 family closure、未登记
  family 维持 unknown/unsupported(FIXTURE-003);registry/lock/conformance 三方
  SHA-256 独立重算 1/1/1,I5-001 与 I5-002 两次独立复核(FIXTURE-004);guard 绿
  且 M1-006 经 #43 依 readiness 条款恢复 ready(FIXTURE-005);`.copy` 构建无
  unhandled-file warning、Bundle.module 精确集 3/0 测试(RESOURCE-001);零
  dispatch 边界 held(NODISPATCH-001)。
- 上述 PR 的维护者 review/merge 构成 verification confirmation;本文件的
  `status: verified` 仅在包含本状态变更的 verification closure PR 经维护者
  review 并合入 `main` 后生效。verified 不改变 Result gate:本 change 只证明
  fixture/profile/lock prerequisite 已登记且 pinned,**`AC-HDC-005-01` 仍未
  passed**,须由 `TASK-M1-006` 的 canonical `TEST-AC-HDC-005-01` parserGolden run
  二值验证;真实 3.2.0d 无 `[success]` 标记的披露(profile 0.2.0)对 M1-006 接线
  持续有效。本 change 暂不 archive:M1-006 在途会话仍以本 change 的 registry/
  evidence 路径为只读依据,archive 留待 M1-006 done 后独立 PR 裁量(先例
  #21/#49)。
