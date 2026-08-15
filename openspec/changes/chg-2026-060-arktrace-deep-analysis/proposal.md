---
id: CHG-2026-060-arktrace-deep-analysis
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# 发布 typed ArkTrace deep analysis operation

> **垂直 review 边界**：本 change 新增一个 Catalog operation，属于 `AGENTS.md`
> 明确要求维护者 review 的四类 Repo Plane 变化之一。四件套、Catalog、Runtime、测试与
> evidence 必须在同一 GJ-5 产品 PR 中交付；本文件不构成独立批准。

## 产品问题

`analyzer.summarize-trace@1` 已能从 immutable Trace Artifact 产出确定性 summary，但它的
公开输入只有 `sourceArtifactRef`。Phase 6 需要围绕时间点或范围取得 bounded context，或运行
ArkTrace 的五类确定性分析。把参数塞进 summary、自由字符串或 argv 会破坏既有 operation，
也会把 executable lowering 权限交给 caller。

本 change 发布独立的 `analyzer.analyze-trace@1`：caller 只提交 Artifact lease、闭集 kind、
typed 时间/identity filters 与显式 limits；Provider 仍使用 CHG-2026-058 已审的 pinned ArkTrace
profile，输出 exact validated `trace-analysis.json`。它推进 GJ-5 的
`collect artifact → analyze → typed next request`，不新增治理框架或设备权限。

## 范围

### In scope

- 新 Catalog operation `analyzer.analyze-trace@1`，`hostOnly`、`binding:none`；
- kind 闭集：`context|cpu|scheduling|slices|range|hot-intervals`；
- exactly-one 时间选择：`timestampNs` 或 `startNs+endNs`；timestamp 使用 reviewed 100 ms
  对称窗口，analysis kind 在 Provider 中 overflow-safe 规范化为 range；
- optional `processKey|pid` 与 `threadKey|tid`，stable key 0 拒绝；
- required `timeoutMs/maxRows/maxEvents/maxOutputBytes`，以及 optional typed
  `thresholdNs/limit`；
- 固定 CLI lowering、完整 ArkTrace JSON 1.0 envelope 验证、exact derived Artifact publication；
- 复用 summary profile 的 signed distribution、tool/parser pins、source lease、取消、恢复与
  private namespace；
- summary descriptor、lowering、validator 与 artifact bytes 保持不变。

### Out of scope

- no raw SQL、free-form query、caller executable/path/argv、shell、GUI、HDC 或 RuntimeCapability；
- no new provider/profile/distribution format；
- no Large Trace claim；
- no change to ArkTrace machine contract or existing analyzer operation semantics。

## Requirements

### ATD-REQ-001 — Closed typed request

Runtime SHALL 在 Job admission 前验证 kind、exactly-one time selection、identity mutual
exclusion、stable-key sentinel 与全部 limits。未声明/冲突/越界输入 SHALL 零 dispatch。

### ATD-REQ-002 — Fixed pinned lowering

Provider SHALL 只从 typed request 选择固定的 `context` 或 `analyze` CLI command。argv SHALL
由 reviewed flags + one immutable source path token 构成；caller SHALL NOT 选择 executable、
parser、path、flag name 或 arbitrary value。

### ATD-REQ-003 — Exact result and provenance

Provider SHALL 验证 ArkTrace JSON 1.0 success envelope、command/parameters、limits、Trace
lease hash/bytes、tool/parser/provenance、closed result shape、global row/event/output bounds 与
path-free privacy；成功只发布 exact stdout bytes 为 `trace-analysis.json`。

### ATD-REQ-004 — Lifecycle compatibility

Operation SHALL 复用现有 host-only WAL、source lease、descriptor-bound process、cancel/drain、
restart/reconcile 与 Artifact commit protocol。summary/crash/hilog behavior SHALL 不变。

## Acceptance

- **ATD-AC-1**：Catalog/generator 只新增 `analyzer.analyze-trace@1`；summary descriptor blob 不变。
- **ATD-AC-2**：invalid kind/time/range/identity/limits 在 submit/plan-only 前 typed 拒绝且零 spawn。
- **ATD-AC-3**：context/analyze 每种 typed request 生成 exact argv；路径作为一个 token，无 shell。
- **ATD-AC-4**：profile unavailable/drift 使两个 ArkTrace operation 各自 availability fail closed。
- **ATD-AC-5**：valid context/analysis envelope accepted；wrong command/parameters/limits/trace/
  parser/schema/result/budget/path 全部拒绝。
- **ATD-AC-6**：exact `trace-analysis.json` bytes、source/tool/parser/request lineage 经 restart 保留。
- **ATD-AC-7**：cancel/timeout/crash window 零错误 publication、零 blind redispatch。
- **ATD-AC-8**：现有 summary descriptor、golden、profile 与 analyzer regression 全绿。

## §19 治理循环说明

- 真实安全风险：自由 argv/错误 source/result/provenance 会把不可信分析发布为 durable Artifact。
- 不能只改 Runtime 的原因：这是新 published operation，必须接受 Catalog/living-spec review。
- 推进：GJ-5 的 structured context/deep deterministic analysis。
- 无治理连锁：一个 change、一个 task、一个 implementation PR；不追加 readiness/archive PR。
