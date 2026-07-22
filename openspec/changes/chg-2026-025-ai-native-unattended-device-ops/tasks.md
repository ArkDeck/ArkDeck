# Tasks

每个任务是下面的一个小节;状态直接改本文件,经 PR review 合入生效。全部任务在本
change approved 前保持 blocked;approved 后每任务另需独立 readiness PR 转 ready
(pins 于 readiness 钉定,全 OID/全 hash)。

## TASK-AIN-001 — 治理文档面同步(host-only)

- Status:blocked
- Platform:macos
- Requirements:Constitution POL-AGENT-002(MODIFIED,载体 constitution-delta.md)语义在非 baseline 治理文档中的同步
- Acceptance:change-local AIN-DOC-001(文档面零残留"只能由人类执行"矛盾表述;grep 复核面见 verification.md)
- Depends on:none(change approved 后)
- Allowed paths:
  - `AGENTS.md`
  - `openspec/governance/enforcement.md`
  - `openspec/verification/policy.md`
  - `openspec/verification/hardware-matrix.md`(仅序言的执行模型表述)
  - `openspec/templates/change/tasks.md`
  - `openspec/templates/change/evidence-run.md`
- Forbidden paths:
  - `openspec/constitution.md`(archive PR 合入)
  - `openspec/specs/**`
  - `openspec/baselines/**`
- Risk:low
- Hardware required:no

### Deliverables

- 上列文档中"人类亲手执行/Agent 零设备命令"表述按 E0/E1/E2 分级 + standing
  authorization 模型改写;历史 evidence/archive 文本一字不动。

### Verification

- AIN-DOC-001 → 全仓 grep(排除 archive/、changes/、git 历史)无残留矛盾表述 →
  run 记录附 grep 输出。

### Notes / handoff

- 完成后在 `evidence/runs/TASK-AIN-001/` 追加 run 记录。

## TASK-AIN-002 — hardware-evidence schema 3.0.0 定稿(host-only)

- Status:blocked
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)的 evidence 字段面
- Acceptance:change-local AIN-SCHEMA-001(v3 schema 对合法/非法实例的接受/拒绝行为二值可证)
- Depends on:none(change approved 后)
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/**`
- Forbidden paths:
  - `openspec/contracts/hardware-evidence.schema.json`(archive PR 合入)
- Risk:low
- Hardware required:no

### Deliverables

- v3-draft 定稿(executor 对象;kind=agent 必带 authorizationRef 的条件校验);
- 正反例实例集 + 校验脚本(python jsonschema),证明 v2 合法实例在 v3 下的判定与
  迁移说明。

### Verification

- AIN-SCHEMA-001 → 校验脚本对正例全 accept、反例(agent 无 authorizationRef、
  未知 kind 等)全 reject → run 记录附输出。

### Notes / handoff

- archive PR 将定稿替换 `openspec/contracts/hardware-evidence.schema.json` 并同步
  `verification/core-conformance.yaml` 的 operator 注记。

## TASK-AIN-003 — ArkDeckKit 执行门 standing-authorization 路径

- Status:blocked
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)
- Acceptance:AC-FLASH-015-01、AC-FLASH-015-02、AC-FLASH-015-03(contract 面)
- Depends on:TASK-AIN-002(evidence 字段形态)
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/**`(flash workflow authorization gate 与 CLI 面,readiness 钉定具体文件)
  - `Packages/ArkDeckKit/Tests/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:medium
- Hardware required:no

### Deliverables

- workflow authorization gate 新增 standing-authorization 校验路径(§3 五步序列;
  授权块解析、逐项比对、身份读回接口、intent 携带 authorizationRef);
- 无授权/不匹配路径保持 policyBlocked(AC-FLASH-015-01/02 行为不回退);
- `arkdeck flash` CLI 增授权引用参数;
- 每个比对分支的 real-fault 注入 contract tests(TR-002R 先例,禁 fake 常量注入)。

### Verification

- AC-FLASH-015-01/02 → contract tests(无授权、逐项篡改、过期、超次、读回不符)
  → dispatch=0 + policyBlocked;
- AC-FLASH-015-03 → contract test(fake executor 层验证门通过路径与 evidence
  字段完整性;真机面归 TASK-AIN-004)。

### Notes / handoff

- 完成后在 `evidence/runs/TASK-AIN-003/` 追加 run 记录(全量测试基线对比)。

## TASK-AIN-004 — 首次无人值守真机验收(DAYU200)

- Status:blocked
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)
- Acceptance:AC-FLASH-015-03(realHardware 面);AC-FLASH-015-01/02 真机负探针
- Depends on:TASK-AIN-001、TASK-AIN-002、TASK-AIN-003
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/**`
  - `openspec/verification/hardware-matrix.md`(新增行)
- Forbidden paths:
  - `Packages/**`(实现已冻结,发现缺陷回 TASK-AIN-003)
- Risk:destructive(本 change 授权模型下由 Agent 无人值守执行;standing authorization 于本任务 readiness PR 承载,恢复路径 = CHG-2026-016 Loader wlx 重刷)
- Hardware required:yes

### Deliverables

- E0 面:agent 无人值守采集 hilog/hitrace 到 owned 路径并拉取分析(TR-001 harness
  复用);
- E2 面:agent 依 standing authorization 无人值守执行 pinned plan 刷机(PD-002
  九分区,RF-002 Provider),postflight 回连验证;
- 首份 executor.kind=agent 的 v3 realHardware evidence + hardware-matrix 新行;
- 负探针:篡改一项 pinned 内容重试 → 实测 policyBlocked(AC-FLASH-015-02 真机面)。

### Verification

- AC-FLASH-015-03 → 无人值守执行 transcript(脱敏)+ v3 evidence + postflight →
  passed;
- AC-FLASH-015-01/02 → 真机负探针 dispatch=0 记录 → passed。

### Notes / handoff

- 中止如实记 blocked-attempt(#104/#173 先例);序列号字节只入摘要。
