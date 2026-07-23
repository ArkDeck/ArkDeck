# CHG-2026-021 Verification Plan

> Status:passed # 2026-07-23；9 Core AC、5 change-local evidence 与全链 OID 见 proposal.md「Verification closure」；仅在维护者 review/merge 本 verification-closure PR 后生效
> Change:CHG-2026-021-trace-adapter-capture@r4
> Core baseline:CORE-2.1.0(零 Core 变更;认领 trace REQ-TRACE-* 的 macOS 面)

本 change 认领 Core `REQ-TRACE-001…009` 的 macOS 面。canonical AC 的 method/
expected result/minimum evidence 以 `openspec/verification/acceptance-cases.yaml`
为准,本 change 不改写。任何在 TR-001 登记前自行发明 argv/marker/fixture 的实现、
任何把 fake/fixture 冒充已登记 adapter 形态的 evidence,整体 fail。

## 认领的 Core AC(逐项 ownership)

| AC | Task | Method(canonical) | 本 change 的面 |
| --- | --- | --- | --- |
| AC-TRACE-001-01 | TR-003 | adapterGolden(parserGolden) | 未知 help family → 不可选、raw 可查、fail-closed |
| AC-TRACE-002-01 | TR-002 | capabilityConfigurationContract | unsupported tag diff、原配置不可执行、未接受 dispatch=0 |
| AC-TRACE-003-01 | TR-002 + TR-002R | parameterStateContract | missing 参数临时恢复禁用；persistent 还须 matching per-device capability + 显式确认 |
| AC-TRACE-004-01 | TR-002 + TR-002R | parameterFaultInjection | mutation 前无 matching capability 则不授权；readback 不一致 → 不 capture、dispatch=0、mismatch 审计 |
| AC-TRACE-005-01 | TR-002 + TR-002R | transportRecoveryContract | 歧义 → awaiting；durable receipt 还须 exact target/candidate/+1 revision 并传入 capture authorization |
| AC-TRACE-006-01 | TR-002 + TR-002R | receiveFaultInjection | partial 位于 storage 契约目录；真实 atomic publish receipt 前 remote cleanup 不可生成 |
| AC-TRACE-007-01 | TR-003 | artifactProperty(parserGolden) | ftrace header 不被固定行删除、raw hash 不变 |
| AC-TRACE-008-01 | TR-002 + TR-002R | progressContract | capability=false 时 caller total 不能提升为 reliable，保持 indeterminate+elapsed |
| AC-TRACE-009-01 | TR-002 | artifactValidationContract | 空 trace exit 0 不进 succeeded、诊断记录 |

## Change-local

| Evidence ID | Method | Expected result |
| --- | --- | --- |
| TRACE-PROV-001 | documentReview | trace probe/golden registry 与 design §4 逐项一致:每命令 exact argv/authority/timeout/成败 marker、help family 与 raw ftrace 头样本、逐文件 SHA-256 closure、redacted manifests(序列号/用户路径零入仓)、OPENHARMONY-TOOLS 与 lock bump 一致;采集由维护者亲手执行且 runbook/argv/输出/判定逐命令在案 |
| TRACE-REBIND-GATE-001 | contract | wrong target、旧/跳号 revision、other candidate 与 identity drift 均不能解除 reboot gate；exact target/candidate/+1 durable binding 才授权，且 authorization/device step 保留新 reference |
| TRACE-ATOMIC-PUBLISH-001 | contract + storage fault injection | receive partial 只在 `artifacts/partial/*.part`；`SessionArtifactStore.publish` 成功且 receipt 匹配前无法生成 cleanup，任一 publication fault 后 remote cleanup dispatch=0 |
| TRACE-PARAM-CAPABILITY-001 | contract | catalog member 但 probe receipt 缺失/unsupported/permissionDenied/needsDeveloperMode/unknown/stale binding/other parameter 时 mutation authorization=none；matching supported receipt 才允许，persistent 另需 capability + confirmation |
| TRACE-PROGRESS-CAPABILITY-001 | contract | capability=false + caller total 仍 indeterminate；只有 capability=true factory 产生的 matching reliable-total receipt 能生成 percent/ETA |

## r2 negative and recovery gates

- reboot:wrong target、same/older/skipped revision、candidate connect key/transport/identity
  mismatch 与 arbitrary durable receipt 全部 capture dispatch 0；
- publication:partial/write/fsync/validation/rename/directory-sync/recovery fault 任一发生时，
  cleanup authority 不产生，owned remote file 保留；
- parameter capability:缺失、过期或不匹配 receipt 在 mutation dispatch 前阻断，不得以
  后续 failed readback 代替 preflight；
- progress:公开输入不能伪造 reliable authority，capability drift 后旧 receipt 失效；
- 所有测试为 host-only deterministic contract/fault injection，真实 device/HDC/network/
  external-process dispatch 恒为 0。

## Archive relocation gate (r4; r3 + scoped link correction)

后续 archive PR 不得重跑真实设备采集或改写历史 TASK-TR-* evidence，并须同时满足：

- r3 已由 #404 merge `2cddc8a83399e643e11dbe93d1852b1e6417a1bd` 批准，且
  CHG-2026-029 已由 #418 merge
  `ac0cfaa2091a4ac2b14bcb0308f8c98388a98d77` 归档；本 r4 也须先由维护者
  review/merge。两次 scope revision 均不授权改写另一 change 的历史 pin。
- 目录精确移动到
  `openspec/changes/archive/2026-07-23-chg-2026-021-trace-adapter-capture/`，
  proposal 同 PR `verified→archived`；无 spec/acceptance baseline/traceability/
  platform-profile 变化。
- living registry 只替换 3 个 `provenance.redactedManifests` path。归一化这三个
  path 后，registry JSON semantic diff 为空；`resources.json` 与 7 个 resource
  bytes/hash/size 逐字节不变。
- registry 从 15,511 bytes /
  `0c093f98b57706b3723a68ae7552bef0db0731a675fb6cc023f69bbe21d6e566`
  精确变为 15,568 bytes /
  `9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613`；
  新 hash 只重钉 OpenHarmony profile、Integration lock 与
  `TraceProbeAdapterProfile.registrySHA256`，三者与实际 registry bytes 全部一致。
- failure-pattern handbook 的 6 个 link target 精确迁移到固定 archive 根；第 6 个
  是 #413 新增的 TASK-TR-002R run 一手 source link。全部链接 anchor 可解析，
  link text、Fact/Inference、完整 OID、taxonomy 与其余文本零变化。
- archive-local evidence/run/tasks/design/verification/acceptance-cases 的历史
  bytes 不变；CHG-2026-029 已归档时，其 carrier 中旧 path+blob 记录也保持不变。
- 对 active tree 的引用扫描除固定 archive path 外，不再发现旧 active root 的
  production provenance 或 living Markdown link；任何新增 active consumer/reference
  都必须先经 D1 scope 修订，不得在 archive PR 临时扩面。
- `python3 -m unittest scripts/trace_capture/test_capture.py
  scripts/trace_capture/test_registry.py -v`、registry validator、
  `TraceAdapterGoldenTests`、Swift 全量、`scripts/check-sdd.sh` 与
  `git diff --check` 全部通过；secret、用户绝对路径、device identifier 与 raw trace
  扫描为 0，真实 device/HDC/network dispatch 为 0。

任一项失败都阻断目录移动。该 gate 只证明归档引用与 hash closure，不重新分类或扩大
既有 9 条 Core AC、5 条 change-local evidence、hardware/support/conformance/release
结论。

## Gate

本 change `verified` 前提:四 task(TASK-TR-001/002/002R/003) done(各有 merged 实现 +
独立 done PR + evidence);9 条 Core AC 有可复查证据(contract 测试 PASS 行 +
parserGolden 对 TR-001 登记 fixture);五条 change-local evidence ID 全部 PASS;
Agent 设备命令 dispatch 恒 0(采集由维护者执行)。不构成任何固件族/设备兼容性或
支持声明;fixture/fake
永不冒充真机形态;traceability trace 行在 change 级 verified 时翻转。
本 r4 archive gate 保留上述 passed 结果，不要求也不允许重判既有 acceptance。
