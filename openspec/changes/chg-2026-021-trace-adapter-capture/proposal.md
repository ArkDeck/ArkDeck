---
id: CHG-2026-021-trace-adapter-capture
revision: 2
status: approved # r1 已由 #253 批准；本 r2 remediation amendment 在维护者 review/merge 前不构成新增任务授权
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# M2 Trace 侧:hitrace/bytrace adapter 采集 MVP

## Why

roadmap M2 = UI Dump/Trace MVP。UI Dump 侧由 CHG-2026-008 承载(采集链进行中);
Trace 侧尚无 change。现状事实(2026-07-21 盘点):

- **认领面完全未动**:`REQ-TRACE-001…009`(9 REQ / 9 AC)在 traceability 全为
  notStarted;canonical minimum_evidence 分布 = **contract × 7 + parserGolden × 2
  (AC-TRACE-001-01/007-01),零 realHardware**——验收面可由确定性 contract 测试 +
  版本化 parser golden fixture 关闭,真机需求只来自 adapter argv/输出族的
  provenance 固定,不来自 AC。
- **seam 与数据面已就位,零 Core 变更需求**:trace 全链所需 WorkflowStep kind
  (captureRemoteFile 的 `trace-presets` catalog、stopRemoteCapture、send/receiveFile、
  snapshot/set/restoreParameter、waitForDisconnect/Reconnect、rebootDevice、
  verifyArtifact/hashFile、preflight*Storage、postprocessArtifact、
  cleanupOwnedRemotePath、requestConfirmation)均已在 CORE 契约与 registry 登记;
  catalog `trace-presets`@1.0.0(6 preset,attachmentPanorama 带 buffer 资源警告)与
  `attachment-debug-profile`@1.0.0(9 参数,snapshot/readback/restore 规则)已入
  INTEGRATION-PROFILES.lock 0.4.0。
- **核心缺口 = provenance**:hitrace/bytrace 在仓内只有散文级说明(integration
  profile "Trace tools" 节),**没有任何版本化 probe/golden registry、exact argv、
  成败 marker、raw ftrace 形态登记**;hardware-matrix 唯一 M0B observed 行明确
  "无 Trace capability 事实";INTEGRATION-PROFILES fixtures 仅 HDC 五族。对比先例:
  HDC 走了 CHG-2026-005(parser golden)+ CHG-2026-015(readonly probe registry)。
  执行者不得自行发明 argv/marker/fake fixture 后让自己的测试通过(CHG-008 r1 教训
  同族)。

## What changes(分期;本 change 首 PR 只 proposal + design,零实现、零真机、零 evidence)

认领 `REQ-TRACE-001…009` 的 macOS/DAYU200 面(9 AC,逐项 ownership 见
verification.md),三任务分期:

- **TASK-TR-001 — trace 工具 provenance 登记(integration 面,device-gated)**:
  在 DAYU200 真机受控采集 hitrace/bytrace 的存在/help/tag-list/最小 capture 输出
  (人工执行模型,M0B/CHG-008 harness 复用),登记版本化 trace probe/golden registry
  (exact argv、help family、成败 marker 非退出码、raw ftrace 头形态、逐文件
  SHA-256 hash closure),bump OPENHARMONY-TOOLS 与 lock(先例 CHG-2026-015)。
- **TASK-TR-002 — host contract 面(零设备、零 provenance 依赖)**:typed trace
  workflow(capability 受限配置、参数 snapshot/set-readback/restore、隔离接收/
  partial、honest progress、artifact completeness、reboot→binding 恢复),认领
  7 条 contract AC(`AC-TRACE-002/003/004/005/006/008/009-01`);只消费已登记的两个
  catalog,不实现真实 adapter 解析。
- **TASK-TR-003 — adapter golden 面(blocked 于 TR-001)**:hitrace/bytrace help
  family 识别与 adapter 选择、ftrace header 保留过滤,against TR-001 登记的 golden
  fixture,认领 2 条 parserGolden AC(`AC-TRACE-001/007-01`)。

## r2 remediation amendment(2026-07-21 candidate)

PR #270 合入的 TASK-TR-002 host contracts(`40cce74ec285a0049364ded00be97fbef1cac9b0`)
在后续 adversarial review 中发现四个 fail-closed 缺口。TASK-TR-002 的 `done` 历史
保持不改写；r2 新增独立 `TASK-TR-002R` 修复并重新验证受影响面：

- reboot capture gate 必须把预期 target、pre-reboot binding revision 和被选 rebind
  candidate 与实际 durable binding receipt 精确关联；revision 必须恰好递增，capture
  authorization 必须携带新的 `DeviceBindingReference`，供后续 device step 使用；
- receive workflow 必须使用 `artifacts/partial/*.part`，并消费
  `SessionArtifactStore.publish` 实际返回的 `PublishedArtifact`。真实原子发布成功前，
  workflow 不得构造 `cleanupOwnedRemotePath`；仅改变内存状态不构成发布 receipt；
- `attachment-debug-profile` catalog membership 只表示候选参数集合，不能替代
  `availability: per-device-probe-required`。任何参数 mutation authorization 前必须有
  与当前 durable binding/参数名匹配的 typed per-device capability evidence；persistent
  change 还须由该 evidence 明确允许；
- reliable byte total 必须通过受 `TraceAdapterCapabilities.reliableByteTotalAvailable`
  gate 的 factory/receipt 产生。capability=false 时，即使 caller 提供 total bytes，
  progress 仍须为 indeterminate。

r2 不改变 Core Requirement、AC、schema、catalog 或 storage contract；它只收紧 macOS
host implementation，使其符合既有 `REQ-TRACE-003/004/005/006/008`。本 amendment
合入只批准 remediation scope；`TASK-TR-002R` 仍须独立 readiness PR 后才可实施。

## Out of scope / Non-goals

- 不修改任何 Core `REQ-TRACE-*`/AC/contract/schema/WorkflowStep kind(零 Core 变更;
  `setParameter` 与 catalog 的绑定收紧在 trace workflow 层实现,见 design §3);
- 内嵌 SmartPerf/Trace Streamer viewer(backlog)、新固件族/厂商工具(roadmap:
  "each new firmware family is separate scope")、Windows/Linux 端口;
- 首 PR 不实现 adapter、不执行真机、不产生 evidence。

## 安全与执行原则

- 真机采集由人类维护者按 runbook 亲手执行(M0B/CHG-008/RF 先例),Agent 零设备
  命令;trace 采集非 destructive,但 `setParameter` 属 deviceMutation——须
  requestConfirmation + readback + 结束恢复(REQ-TRACE-004);
- 设备序列号/用户路径字节不入仓(redaction 工具链复用);
- adapter 未经 TR-001 登记前,任何实现不得宣称兼容性或依据散文说明固定 argv。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;三任务各自
独立 readiness/实现/done PR。TR-002 可在 approve + readiness 后立即执行(零设备);
TR-001 另需具名设备窗口;TR-003 待 TR-001 done。trace capability 为 release
optional 且 `requires: []`,本 change 不影响 required capability 集与依赖闭合。

## Approval

- r1 proposal 经 PR #249 合入 main(squash `90f877d`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171/#195/#226)将本
  change 置为 `approved`;批准由维护者 review/merge 本 PR 构成。merge 即批准:
  - **三任务分期 scope 与边界**:TASK-TR-001(hitrace/bytrace provenance 登记,
    device-gated,CHG-2026-015/005 形态)、TASK-TR-002(host contract 面,认领
    7 条 contract AC,零设备零 provenance 依赖)、TASK-TR-003(adapter golden 面,
    认领 2 条 parserGolden AC,blocked 于 TR-001)的 objective/scope/allowed-paths;
  - **design 约束**:§0 候选命令面的"TR-001 登记前不得实现 adapter/不得据散文固定
    argv"、§3 参数 mutation 绑定 attachment-debug-profile catalog 的 workflow 层
    收紧(零 Core 变更)、§4 provenance 登记形态(exact argv/成败 marker 非退出码/
    hash closure/redacted manifests);
  - **认领面**:`REQ-TRACE-001…009` 的 9 条 canonical AC + change-local
    `TRACE-PROV-001`;trace capability 保持 release optional、requires:[]。
- 本批准不产生任务执行:三任务保持 `blocked`,各须独立 readiness PR 转 `ready`;
  TR-001 另需具名设备窗口 + 人工执行模型;TR-002 在 readiness 后即可 host-only
  执行。本批准不构成任何固件族/设备兼容性或支持声明;fixture/fake 永不冒充真机
  形态。

## r2 approval boundary

- r2 只起草 `TASK-TR-002R` 的 remediation scope、design 与 verification gates；
  维护者 review/merge 本 amendment 后才构成 scope 批准。
- scope 批准不等于 task ready。readiness 必须另行钉住 main commit、三份待改 source
  blob、storage publication seam、测试基线和 allowed-path overlap。
- remediation implementation+evidence、`ready→done` 与 change `verified` 分别使用
  独立 PR；任何一步都不得回写或删除 TASK-TR-002 的历史 evidence。
