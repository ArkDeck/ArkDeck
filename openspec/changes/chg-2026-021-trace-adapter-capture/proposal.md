---
id: CHG-2026-021-trace-adapter-capture
revision: 1
status: proposed # 本 propose PR 合入仅登记提案;批准须独立 approval-only PR(先例 #55/#89/#171/#195/#226)
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
