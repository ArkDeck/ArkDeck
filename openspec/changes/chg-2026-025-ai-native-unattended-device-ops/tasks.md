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

- Status:ready
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

### Readiness pins(r1,2026-07-22)

- Base:main `923e5023de76341297a4274584d3ec5e6a6aae72`(#281 merge,change
  approved);guard 于 base 实测 0 error / 0 warning / 111 acceptance IDs。
- 待改文件 blob(全 OID,漂移即本 readiness 失效重查):
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`
    `47f07720f9a25c49fbb8ac4834317a967543e492`(现行 gate:policyBlocked/
    RockchipHumanHandoff 面)
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
    `8a30eb828773260d8b02b854d03a63ecf2da124f`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
    `de82a3a008b95ef63148f7c9e4374298e6671328`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
    `c1384a3584ac9b94eed7e7864042ef5938efa08c`(`arkdeck flash` 授权引用参数)
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipRockUSBFlashProviderContractTests.swift`
    `db5986dda762286bda6872ed1b938299045e08fa`(扩展,不删既有断言)
- 新文件面:standing authorization 块解析/逐项校验器/新契约测试为**新增文件**
  (`StandingAuthorization*.swift` 命名族,Trace* 新文件先例);上列五文件之外的
  既有文件零接触。
- 只读契约 seam(满足 Depends on TASK-AIN-002 的 DoR 方式 = 契约已固定):
  - v3-draft `62fc3a733cf0ccdd94297568c9c34c8c2c2f6ae4`(executor/
    physicalTargetConfirmation.method 字段形态;AIN-002 定稿若变更该语义,
    本 readiness 失效重查);
  - flashing delta `5fd7ed4df9574e52e822930eff0e824641c0bd5f`(AC-FLASH-015-01/02/03
    文本依据)。
- 测试基线(base 上 wt 隔离实测):全量 **320 tests / 1 skipped / 2 failures
  (0 unexpected;已知 HDCGolden /private/tmp 环境性,#270/#278 复验同型)**;
  其中 `TEST-AC-FLASH-015-01 PASS destructive_dispatch=0 job=policyBlocked` 与
  `TEST-AC-FLASH-015-02 PASS mismatch_fields=8 … real_dispatch=0` 为**不回退底线**
  (无授权/不匹配路径行为在新门下必须逐字保持)。
- 二值门(实现 PR 逐一对应,real-fault 注入 = 篡改真实授权块字节走真实解析/
  比对路径,禁 fake 常量分支,TR-002R 先例):
  1. 无 standing authorization → policyBlocked + destructive dispatch=0
     (AC-FLASH-015-01,现行为保持);
  2. 授权块逐项篡改(target/binding revision/固件 hash/transport/HDC/Provider/
     Step 集合/plan hash,≥8 字段面)→ dispatch=0(AC-FLASH-015-02);
  3. 授权过期/超次 → dispatch=0(AC-FLASH-015-02);
  4. 设备身份读回与授权 target 不符 → dispatch=0(AC-FLASH-015-02);
  5. 门通过路径(fake executor 层)→ intent 携带 authorizationRef、evidence v3
     字段完整(AC-FLASH-015-03 contract 面;真机面归 TASK-AIN-004)。
- 并行边界:只碰 `Packages/**`,与 TASK-AIN-001(根治理文档)/TASK-AIN-002
  (change 目录)零文件交集,可并行;三 readiness PR 同改本 tasks.md 不同段,
  后合者如冲突需 rebase(#255/#256 先例)。

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
