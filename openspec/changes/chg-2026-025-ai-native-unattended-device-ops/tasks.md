# Tasks

每个任务是下面的一个小节;状态直接改本文件,经 PR review 合入生效。全部任务在本
change approved 前保持 blocked;approved 后每任务另需独立 readiness PR 转 ready
(pins 于 readiness 钉定,全 OID/全 hash)。

## TASK-AIN-001 — 治理文档面同步(host-only)

- Status:ready
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

### Readiness pins(r1,2026-07-22)

- Base:main `923e5023de76341297a4274584d3ec5e6a6aae72`(#281 merge,change
  approved);guard 于 base 实测 0 error / 0 warning / 111 acceptance IDs。
- 待改文件 blob(全 OID,漂移即本 readiness 失效重查):
  - `AGENTS.md` `895d93bcdc29c1edc9ffcf7527ffa3c8ebf8cc61`
  - `openspec/governance/enforcement.md` `e0ad08c3fc85616c721256437afb4271d7969180`
  - `openspec/verification/policy.md` `070613b199fbc1124cc2f7398a8ed671e5c90f81`
  - `openspec/verification/hardware-matrix.md` `dcd1b7a272637eee296a5b5db0c0a587978d7761`
  - `openspec/templates/change/tasks.md` `2362b5723a3b2b1d7204daf98d479a7cc88263d7`
  - `openspec/templates/change/evidence-run.md` `226d08a3be2b00f83bfda370f7d19faff68ff03e`
- 只读依据 blob:constitution-delta 与 flashing delta 随 #280 入 main
  (`specs/flashing/spec.md` delta `5fd7ed4df9574e52e822930eff0e824641c0bd5f`);
  改写措辞以 delta 文本为准,不得引入 delta 之外的新语义。
- 改写面清单(base 上 grep 实测,共 7 处,AIN-DOC-001 复核以此为封闭集):
  1. `AGENTS.md` Agent 禁令第 2 条(“不得对真实设备执行 Flash…由人类亲自执行”);
  2. `openspec/governance/enforcement.md` “真实硬件与 destructive 操作”节第 1 条
     (“Agent(以及任何自动化)不得…只能产出 plan 与人工执行步骤”);
  3. 同节第 2 条 operator 表述(操作者(人类)→ executor 语义);
  4. `openspec/verification/policy.md` “真实设备 destructive 操作只能由人类执行”;
  5. `openspec/verification/hardware-matrix.md` 序言“由人类操作者产生”与
     evidence 要求“人类操作者”两行;
  6. `openspec/templates/change/tasks.md` Risk 行注释“destructive 的真实设备步骤
     只能由人类执行”;
  7. `openspec/templates/change/evidence-run.md` “除非 task 明确授权人类执行”。
- 边界确认:`openspec/constitution.md`、`openspec/specs/**`、
  `openspec/baselines/**`、历史 evidence 与 `changes/archive/**` 零接触
  (constitution/spec 正文由 archive PR 合入);hardware-matrix 既有数据行
  (EVD-* 行)一字不动。
- 二值门:完成后同一 grep 面残留矛盾表述 = 0;guard 保持 0/0/111。
- 并行边界:与 TASK-AIN-002(change 目录 `contracts/**`)、TASK-AIN-003
  (`Packages/**`)零文件交集,可并行;三 readiness PR 同改本 tasks.md 不同段,
  后合者如冲突需 rebase(#255/#256 先例)。

## TASK-AIN-002 — hardware-evidence schema 3.0.0 定稿(host-only)

- Status:ready
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

### Readiness pins(r1,2026-07-22)

- Base:main `923e5023de76341297a4274584d3ec5e6a6aae72`(#281 merge,change
  approved);guard 于 base 实测 0 error / 0 warning / 111 acceptance IDs。
- 待定稿 blob:`contracts/hardware-evidence.schema.v3-draft.json`
  `62fc3a733cf0ccdd94297568c9c34c8c2c2f6ae4`。
- 只读 seam blob(零接触,漂移即重查):
  - v2 正本 `openspec/contracts/hardware-evidence.schema.json`
    `98443833b5bef36f4a1e0fdea9dbaaccf057f4d1`(archive PR 才替换);
  - flashing delta `specs/flashing/spec.md`
    `5fd7ed4df9574e52e822930eff0e824641c0bd5f`(evidence 字段语义依据:
    executor/authorizationRef/目标读回)。
- 工具可得性(base 上实测):`.venv-sdd` python 可得;`jsonschema` 第三方库
  **缺失**——校验脚本 SHALL 以 stdlib 实现本 schema 所需的封闭断言集
  (required/enum/pattern/条件 required),不引入第三方依赖、不装包、不联网;
  脚本与正反例入 `evidence/runs/TASK-AIN-002/`。
- 二值门(AIN-SCHEMA-001):正例集全 accept;反例集全 reject(至少含:
  kind=agent 缺 authorizationRef、未知 kind、缺 physicalTargetConfirmation.method、
  method 非法值、serial 疑似原始字节而非摘要的记录说明面);v2 历史实例
  (EVD-RF001/RF002 族)不迁移不改写,兼容性以文字说明入 run 记录。
- 边界确认:只写 change 目录 `contracts/**` 与 `evidence/**`;
  `openspec/contracts/**` 正本零接触。
- 并行边界:与 TASK-AIN-001(根治理文档)、TASK-AIN-003(`Packages/**`)零文件
  交集,可并行;三 readiness PR 同改本 tasks.md 不同段,后合者如冲突需 rebase
  (#255/#256 先例)。AIN-003 只读依赖本任务的 v3 形态:定稿若改变
  `62fc3a73…` 的 executor/confirmation 字段语义,AIN-003 readiness 须重查。

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
