# Tasks

每个任务是下面的一个小节;状态直接改本文件,经 PR review 合入生效。全部任务在本
change approved 前保持 blocked;approved 后每任务另需独立 readiness PR 转 ready
(pins 于 readiness 钉定,全 OID/全 hash)。

> r2 security-remediation：TASK-AIN-001/002/003 的 done 历史保持不改写；复审发现
> authorization provenance、trusted fact source、usage ceiling、locked contracts 与产品内
> dispatch 未闭环，因此 TASK-AIN-004 从 ready 回到 blocked。新增 TASK-AIN-005/006/007
> 均为 blocked，须依次独立 readiness/实现/done；全部完成后 AIN-004 再重新 readiness。

## TASK-AIN-001 — 治理文档面同步(host-only)

- Status:done
- Done:2026-07-22;实现经 #287 合入 main(merge commit `c0d5253389faf8f9e90bceea5dd2c02fec83710b`);done recheck 于合入版 `4621a73001e53277cfb5ca0d718c76145e8f4ac9` 复验:AIN-DOC-001 grep 残留 0、guard 0/0/111;evidence = `evidence/runs/TASK-AIN-001/run.md`
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

- Status:done
- Done:2026-07-22;实现经 #288 合入 main(merge commit `4621a73001e53277cfb5ca0d718c76145e8f4ac9`);done recheck 于合入版复验:AIN-SCHEMA-001 校验器对 9 fixture 复跑全 PASS、guard 0/0/111;executor/confirmation 语义与 readiness 钉定 draft 零变化(AIN-003 无须重查);evidence = `evidence/runs/TASK-AIN-002/run.md`
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

- Status:done
- Done:2026-07-22;实现经 #292 合入 main(merge commit `0a5c9fd99c3cc7f6bcf4e44044706de7c9d2215f`);done recheck 于合入版复验:StandingAuthorization+Rockchip 焦点套件全 PASS(三 AC 门 + 既有 015-01/02 输出逐字不变)、guard 0/0/111;授权载体 JSON 化偏差已记 run;evidence = `evidence/runs/TASK-AIN-003/run.md`
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

- Status:blocked（r2 security review 发现 P0-AUTH/FACT/DISPATCH/CONTRACT 缺口；#296
  readiness 作为历史保留但不得复用。等待 TASK-AIN-005/006/007 全部 done 后，以新的 main
  OID、未过期 authorization、可信执行宿主和独立 PR 重新 readiness）
- Historical readiness r2(2026-07-22,**superseded**):E0 身份读回于设备窗口完成
  (operator lvye,crib exit 0,serial 摘要 `958780b2…` 命中被授权目标;run 记录
  `evidence/runs/TASK-AIN-004/`)。载体当时将 `bindingRevision` -1 → 1、`carrier`
  PENDING → r2 PR 引用，host pin 于合入版 f15c3a8 复核无漂移。该 merge 当时把任务标为
  ready；本 security-remediation 已废止其操作效力，不能据此 dispatch。
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)
- Acceptance:AC-FLASH-015-03(realHardware 面);AC-FLASH-015-01/02 真机负探针
- Depends on:TASK-AIN-001、TASK-AIN-002、TASK-AIN-003、TASK-AIN-005、
  TASK-AIN-006、TASK-AIN-007
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/**`
  - `scripts/e0_readback/**`(E0 只读身份/binding readback crib,host-only 交付物;先例 TR-001 harness `scripts/trace_capture/`)
  - `openspec/verification/hardware-matrix.md`(新增行)
- Forbidden paths:
  - `Packages/**`(实现已冻结,发现缺陷回 TASK-AIN-003)
- Risk:destructive(本 change 授权模型下由 Agent 无人值守执行;standing authorization 于本任务 readiness PR 承载,恢复路径 = CHG-2026-016 Loader wlx 重刷)
- Hardware required:yes

### Deliverables

- **E0 readback crib(host-only,已交付):`scripts/e0_readback/`**——只读身份/模式
  读回,确认物理设备 serial 摘要 == 载体 pin、记录 USB 模式,产出 r2 finalize 的身份
  依据;不读/不臆造 bindingRevision(无 host 读取路径,r2 从 binding journal 定,见
  README)。封闭只读 allowlist、argv 数组无 shell、输出仓外、脱敏门;26 unittest +
  `--selftest-host` host 侧自测绿。
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
- r2 期间禁止调用现行 `--authorization/--unattended-context` 路径执行真实命令；现有
  AUTH 文件由 POL-AGENT-001 保护，本 remediation 不修改它，任务状态与执行门均须阻断。
- 下一次 readiness 不得把现行 gate 的 `dispatch=0 real_device=0` 正例当作产品执行证据；
  必须 pin AIN-DISPATCH-001 的 product-owned fake executor 结果与可信宿主隔离证据。

### Historical readiness pins(r1 host-complete,2026-07-22; superseded)

**状态说明**:本 r1 锁定全部 host 可推导 pin 与 standing authorization 载体的
host 字段;`bindingRevision` 是唯一需一次设备读回才能确定的 pin,故本任务保持
`blocked`,r2(见末尾)一次 E0 读回后翻 `ready`。r1 不构成任何真机执行授权。

- Base:main `0a5c9fd99c3cc7f6bcf4e44044706de7c9d2215f`(#292 merge,AIN-003 done
  载体 #293 在途);guard 于 base 实测 0 error / 0 warning / 111 acceptance IDs;
  Swift 焦点套件复验 015-01/02/03 全 PASS。
- Depends on(DoR):AIN-001 done(#289)、AIN-002 done(#290)、AIN-003 done
  (#293 待合)——r2 提交前须确认三者均在 main。
- **standing authorization 载体** = `evidence/authorizations/AUTH-2026-025-DAYU200-001.json`
  (README 同目录)。host 字段于 base 实测锁定(全 hash):
  - `planDigestSHA256` `c85be3b34ae671ad213781619235a22dcb242d406850d4eb8cef8785487d6cff`
    (合入版 `makePlan(mode:.execute, archiveValidation:.valid)` 实测,与 RF-002
    transcript 逐字一致——AIN-003 未触碰 makePlan);
  - `stepSetDigestSHA256` `075b52c4fc7dc71e422c76c9edd5e1cd26e7641c844fa4cfb4ae79f29d1c8fdb`;
  - `firmwareArchiveSHA256` `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`
    (pinned 参考镜像 7.0.0.33);
  - `toolchainFingerprint` `rkdeveloptool-1.32@038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`;
  - `providerIdentity` `arkdeck.rockchip-rockusb-flash-provider`;
  - `target.model` `DAYU200 (RK3568)`;`transport` usb;`maxRuns` 1;
    `validUntil` 2026-08-31T00:00:00Z;
  - `target.serialSHA256` `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
    = SHA-256 of the DAYU200 serial recorded in-repo by
    `EVD-M0B-DAYU200-20260718-001`(同一物理设备;原始字节不复制入本载体)。
- **唯一待读回 pin**:`target.bindingRevision` 现为 `-1`(fail-closed 占位)——
  `RockchipStandingAuthorization.parse` 对负值直接拒绝,故 r1 载体在解析层即不可
  授权任何 dispatch(有意)。
- Allowed paths(r2 及执行期):`evidence/**`(载体、authorizations、runs)+
  `hardware-matrix.md` 新增行;`Packages/**` forbidden(实现已冻结,缺陷回 AIN-003)。
- 二值门(r2/执行期,不在 r1 交付):
  1. E0 无人值守日志采集到 owned 路径 + 拉取分析(TR-001 harness 复用);
  2. E2 无人值守刷机:门通过(authorizationRef 非空)→ durable intent 落盘 →
     九分区 wlx → rd → postflight 语义判定;
  3. 真机负探针:篡改载体一项 pin 重试 → 实测 policyBlocked、dispatch=0
     (AC-FLASH-015-02 真机面);
  4. 首份 `executor.kind=agent` v3 evidence(authorizationRef 可解引用)+
     hardware-matrix 新行。

### Historical r2 finalize(已完成且已被 security-remediation 废止)

在具名设备窗口对目标 DAYU200 执行一次 E0 只读身份/binding 读回(本 change 生效后
E0 为 agent 可无人值守操作,亦可维护者一行执行),取当前 durable binding revision、
复核 serial 摘要 == `958780b2…7a7e`、USB vid:pid == `0x2207:0x350a`。然后 r2:
当时把载体 `bindingRevision` 从 `-1` 改为读回值、`carrier` 从 PENDING 改为 r2 PR 的
`PR #<n> <path>@<blob-oid>`、本任务翻 `ready`。该记录仅供审计；当前状态以本节顶部
`Status:blocked` 为准，旧载体和旧 readiness 均不得复用。

## TASK-AIN-005 — authorized-agent locked contract closure

- Status:done
- Done:2026-07-22；实现经 #302 合入 main（merge commit
  `c909de882a327a9d4947a61c68735babde4e9685`；reviewed head
  `00c62cf6785c3e9e32f3675c8d141422688e1be0`）；done recheck 于合入版复验：Swift
  全量 330/1 skipped/0 failures，AIN-CONTRACT-001 三项 canonical 摘要全 PASS，三个新增
  schema Draft 2020-12 校验通过，guard 0/0/111；reviewed head 到 merge commit 在
  TASK-AIN-005 实现范围内 tree diff = 0；evidence =
  `evidence/runs/TASK-AIN-005/2026-07-22-contract-implementation.md`
- Readiness review（2026-07-22；host-only 审计，device/HDC/network/external-process
  dispatch 均为 0）：
  - Approval/dependency gate:satisfied。r2 amendment PR #299 已由维护者 `lvye` merge，
    merge commit = `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`；按 V2 `merge = approval`，
    新增 AIN-005/006/007 scope 与 AIN-004 stop gate 已生效。AIN-005 无其他前序任务。
  - Objective/scope gate:satisfied。任务只闭合 change-local locked-contract drafts、Swift
    persistence/semantic validator 与 host-wide usage ledger；不解析 GitHub provenance、不读取
    真实授权载体、不启动产品 executor。实现 Agent 不得在本任务新增 Core/AC、改变 Step
    registry 或决定 device/tool capability。
  - Base/input pins:实现必须基于本 readiness 合入后的 `main`；审计 base = `main`
    `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`。下列只读权威输入任一 blob 漂移即停并重做
    readiness：manifest v1 `1100b951f8c7565e10f403d576acfe260e401155`、journal v1
    `d25b7a55e9970d301558430febd235ccc910d8b7`、provider contract v1
    `ceb6709fb405fc46d72ef2126b715e252ac720ab`、workflow-step v1
    `c510d96478f3192168478b1a1669b5fcd2a848f7`、flashing delta
    `5fd7ed4df9574e52e822930eff0e824641c0bd5f`、r2 design
    `6c2e5e56433aa9a04d922702a1ecde694dcea9b4`。
  - Schema/version gate:fixed。change-local 新版本精确为 manifest `2.0.0`、journal-event
    `2.0.0`、authorization-usage `1.0.0`、provider-contract delta target `2.0.0`；文件名见
    Allowed paths。current `openspec/contracts/**` v1 正本继续只读，v1 历史 bytes/解码/语义
    保持兼容，只有 v2 可表达 `authorizedAgent` destructive success，禁止把 v1 原地改写或
    解释升级。
  - Authorization reference gate:fixed。共享 `authorizationRef` 是封闭对象且只含
    `authorizationId`、40 位小写 full `mainCommitOID`、40 位小写 full
    `authorizationBlobOID`、正整数 `approvalPRNumber`。字符串 carrier、路径、branch/tag、
    缩写 OID 或 caller JSON 不能替代该对象；本任务只验证 shape/correlation，不授予
    production dispatch authority。
  - Manifest/journal gate:fixed。manifest v2 新增 nullable `authorization`；
    `executionAuthority=authorizedAgent` 时必须为
    `{authorizationRef,usageReservationId,destructiveIntentEventIds}`，其中每个实际执行或
    outcomeUnknown 的 destructive Step 对应且只对应一个 durable intent event；其他 authority
    不得借该字段升级。journal v2 的 authorized-agent `jobCreated`、每个 destructive
    `stepIntent` 及其 `stepOutcome` 必须携带同一 `authorizationRef` 与
    `usageReservationId`，outcome 仍须反向引用 intent；缺失、漂移、ghost/duplicate ref、
    mixed v1/v2 Session 全拒绝。`standardAgent`/planOnly/simulated 的既有 destructive
    `notRun` 不变量逐字保持。
  - Confirmation gate:fixed。manifest v2 confirmation `actor` 从字符串升级为封闭对象：
    `{kind:interactiveUser}` 或 `{kind:authorizedAgent,authorizationRef}`；后者仅允许
    `executionAuthority=authorizedAgent`，且 ref 必须与 manifest/journal/usage 完全相同。
    recovery-abandon 的人工确认语义不在本任务放宽。
  - Usage gate:fixed。authorization-usage v1 是
    `{schemaVersion,reservations:[...]}`，reservation 记录
    `reservationId/authorizationRef/ordinal/maxRuns/jobId/planDigestSHA256/targetDigestSHA256/
    reservedAt/terminal`；`terminal` 只能为 null，或
    `{status:succeeded|failed|cancelled|interrupted|outcomeUnknown,closedAt,
    destructiveIntentEventIds}`。同一 authorization 的 ordinal 单调且唯一，`maxRuns>0` 时 reserve
    超限必拒绝。reserve 必须在任何 destructive intent 前，以 host-wide stable lock + 原子
    replace + file/directory durability barrier 完成；durable reserve 即消费额度，crash、失败、
    cancel、outcomeUnknown 均不退款。相同 reservation retry 只能返回相同 receipt，字段漂移
    必拒绝；terminal 只能关闭既有 reservation，不能删除/降 ordinal/补发权限。
  - Implementation seam pins:允许修改的既有 source blobs 为 `SessionManifest.swift`
    `8b31dd1a63bbfb573e51a0457d8a2d944b90ff1a`、`JournalEvent.swift`
    `06e2c7b277df9e75cab99c52621ae1f552a26517`、`JournalEventValidation.swift`
    `bb3db4c2d6183d588509a28e61d62888cd210dc8`、`JournalReplay.swift`
    `48ac1eef0c1a0b9b96159cf918ffe0e5ba322d40`、`RetentionAndExport.swift`
    `7c52f04dfcc73d6eb44c10b3f6cba7bac9f3d887`；焦点 tests 为
    `SessionArtifactStorageContractTests.swift`
    `24e4b67dc0f9db14d7916972136b90170e92d7ca`、`JournalRecoveryContractTests.swift`
    `ce30c3faa6957d22aec19e3790030a8b6e9b0ac2`。只读 storage seam
    `DurableFiles.swift` `039fbb891fdc78c3cf19acc47b3f1231b9dde5c0` 与 `StrictJSON.swift`
    `d5df2a82ced6b8a06635c1e9f1887d70c693f005` 禁止修改；实现复用其 argv-free durable/
    strict-JSON primitives。
  - New-file/collision gate:四个 change-local contract 文件、
    `AuthorizationUsageLedger.swift`、`AuthorizationUsageLedgerContractTests.swift` 与本任务
    run 路径在 base 均不存在；实现只能按 Allowed paths 新建。若上述既有 source 与
    明列的新文件不足以闭环，须停回 blocked 并先做 scope amendment，不能
    扩到 Workflows/CLI/Runtime/current contracts。
  - Binary verification gate:AIN-CONTRACT-001 至少覆盖 v2 正向 round-trip、v1 历史读取、
    standardAgent destructive success、authorizedAgent 缺/漂移 ref、actor ref 漂移、intent/
    outcome/manifest ghost ref、mixed-version Session、usage 并发、同 reservation 漂移重试、
    reserve/replace/fsync crash windows、lock/path/symlink substitution；全部负例拒绝且
    external-process/device dispatch=0。export/redaction round-trip 必须保留非敏感 OID/ID，
    不泄露 target 原始身份字节。
  - Toolchain/baseline gate:satisfied。macOS 26.5.2 (25F84)、Xcode 26.6 (17F113)、
    Apple Swift 6.3.3；全量 Swift **323 tests / 1 skipped / 0 failures**，manifest+journal
    焦点 **87 tests / 0 failures**（JournalRecovery 29 + SessionArtifactStorage 58），
    `check-sdd` **0 errors / 0 warnings / 111 acceptance IDs**。实现 PR 不得降低这些基线，
    并须追加 AIN-CONTRACT-001 canonical PASS 摘要与 run evidence。
  - Concurrency/review gate:satisfied。readiness 审计时 GitHub open PR = 0；本 PR 仅修改本
    `tasks.md` 段落。AIN-005 implementation+evidence、`ready→done`、AIN-006 readiness 各自
    使用独立 PR；AIN-004 与旧授权继续 blocked，真实设备操作始终为 0。
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)、POL-WORKFLOW-001、POL-RECOVERY-001、
  POL-AGENT-002(MODIFIED)
- Acceptance:AIN-CONTRACT-001；AC-FLASH-015-01/02/03 的 persistence 面
- Depends on:r2 amendment approved（#299 / main
  `a2dab4c3f4279cff0ef1a859cdb5297afe9aeb85`）
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/journal-event.schema.v2-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/authorization-usage.schema.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/provider-contracts.v2-delta.md`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-005/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalReplay.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RetentionAndExport.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift`（new）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JournalRecoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AuthorizationUsageLedgerContractTests.swift`（new）
- Forbidden paths:
  - `openspec/contracts/**`（archive PR 才替换正本）
  - `openspec/specs/**`
  - 真实 device/HDC/network/external-process dispatch
- Risk:high（Core persistence/authority contract；host-only）
- Hardware required:no

### Deliverables

- change-local manifest/journal/authorization-usage schema drafts 与 provider-contract delta；
- `authorizedAgent` 只可由 verified grant mint；standardAgent/ordinary CI destructive success
  继续结构性拒绝；
- destructive intent/outcome/manifest/confirmation/usage reservation 的 authorizationRef
  关联与 semantic validator；v1 历史 read compatibility；
- 正反 fixture：缺 ref、ref 漂移、旧 schema 伪装 authorized success、usage correlation 断裂
  全拒绝。

### Verification

- AIN-CONTRACT-001 全分支 PASS；Swift storage/manifest/journal 全量回归；check-sdd 绿；
- fake/simulation/plan-only 与 real-authorized 语义持续可辨识，零真实 dispatch。

## TASK-AIN-006 — trusted authorization provenance, facts and usage gate

- Status:done
- Done:2026-07-22；实现经 #307 合入 main（merge commit
  `acd8ed930c6f008a9ace9cfc23542307b6c7472a`；reviewed head
  `4829bd96528cbc9349c16d882b56f900715f46d0`），证据计数修正经 #308 合入
  （merge commit `c893e19df78523b0377c7893ad4dff3bd2b7ee11`；reviewed head
  `1b9b3011000341006b3cb16c8138b71698c85cb3`）；done recheck 于合入版复验：专项
  12/0 failures、Swift 全量 345/1 skipped/0 failures、四项 canonical 摘要全 PASS、guard
  0/0/111；#307 实现范围与 #308 evidence 的 reviewed head 到各自 merge commit tree diff
  均为 0。fresh-scratch 的两项独立 HDC resource-path fixture 偏差已如实保留在 evidence；
  evidence = `evidence/runs/TASK-AIN-006/2026-07-22-trusted-admission-implementation.md`
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)、POL-TARGET-001、POL-AGENT-001/002
- Acceptance:AIN-AUTH-PROV-001、AIN-FACT-001、AIN-USAGE-001、
  AC-FLASH-015-01/02
- Depends on:TASK-AIN-005
- Readiness reviewed:2026-07-22；base = protected `main`
  `c2342ca363e60bea8d159d6fe8b87e8fca31d8ca`（#305 merge；#301 discovery 后续 hermetic
  test fixture 修复），审计时 open PR = 0。
  TASK-AIN-005 已由实现 #302 与 done recheck #304 合入；#304 reviewed head
  `4c42ec122b4f3d9710fc90aee53521837e3616fc`、merge commit
  `ac54b77c4037b8790b1ecfa31df114c21151f7ec` 均为 current main 祖先。
- Allowed paths（实现 PR 的封闭文件面）：
  - 修改 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/StandingAuthorization.swift`
    `b68e9b92c13f94a0cd935705f2dfcf730dd9f71e`
  - 修改 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`
    `4bc5f5af014a7f765ca6d5c05937a31c68e6ccac`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AuthorizationProvenance.swift`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AuthorizationAdmission.swift`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift`
  - 修改 `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
    `44c5cf7a92e47dcf0f30d2765d0d9209e990afaa`
  - 修改 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/StandingAuthorizationContractTests.swift`
    `e866fb5240d40d6264beb11305166856c3ef6cdf`
  - 新增 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AuthorizationProvenanceContractTests.swift`
  - 新增 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AuthorizationAdmissionContractTests.swift`
  - 新增本 change `evidence/runs/TASK-AIN-006/**`
- Scope clarification:`RockchipFlashAuthorization.swift` 不匹配原草案的
  `Authorization*.swift` glob，但它是当前接受裸 authorization/context 并产出 autonomous
  command surface 的实际 gate。为完成已批准 deliverable“gate 只接受 verified capability”，
  本 readiness 将该既有文件显式纳入；除上述文件外不得借此扩面。
- Forbidden paths:
  - authorization 载体 `evidence/authorizations/**`（不得创建、修改、刷新或批准授权）
  - `openspec/specs/**`、`openspec/contracts/**`、current baselines、change-local contract/schema
  - `Packages/ArkDeckKit/Package.swift` 与除上列外的全部 `Packages/**`
  - 真实 device/HDC/rkdeveloptool/网络调用与 destructive dispatch；external shell/handoff 执行
- Risk:high（authorization root 与 usage ceiling；host/fake only）
- Hardware required:no

### Readiness pins and trust boundary

- **唯一 caller 输入**：autonomous CLI 只接受严格格式的 `authorizationId` 与 typed intent/
  selector；selector（image path、target location 等）从不成为批准、binding、usage、tool 或
  readback 事实。移除并显式拒绝 `--authorization`、`--unattended-context` 及其 JSON
  context；caller bytes/path、环境变量、工作树、ref/branch/tag、历史 commit、imported manifest
  均不得进入信任根。
- **固定解引用**：resolver 固定仓库 `ArkDeck/ArkDeck`、受保护分支 `main` 与 registry
  `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/authorizations/`；
  `authorizationId` 必须满足实现内封闭语法并只能映射同名 `<id>.json`，路径分隔符、`.`/
  `..`、percent encoding、大小写/Unicode 等价替代均拒绝。每次 resolve 现场读取 GitHub
  branch/commit/tree/blob/PR/review/CODEOWNERS metadata；本任务**不实现离线缓存**，网络/API
  不可用、rate-limit 或任一字段不确定即 fail closed。
- **merged-PR provenance**：current protected-main blob 必须与 approving review 的 exact PR
  head 及 merge commit 中 blob 逐字节同 OID；PR 必须 merged、base=`main`、merge commit 为
  current main 祖先，author=`github-actions[bot]`，`mergedBy` 与 APPROVED review 均为
  CODEOWNER `lvye`，review `commit_id` 必须等于该 PR head。CODEOWNERS 只从同一 protected
  main 读取（readiness pin `.github/CODEOWNERS`
  `f4edd22f87965efcfc27ea512283a0c2252bf0fb`，`* @lvye`）；author/reviewer/merger 角色不得
  合并。JSON 的 `approvedBy`/`carrier` 只可作为 display/cross-check 字段，不能产生信任。
- **closed parse + capability**：授权 JSON 拒绝 duplicate key、unknown/missing 字段、非规范
  digest/时间/数字。resolver 由 GitHub 事实导出 AIN-005 的 typed
  `AuthorizationReference`（authorization ID + current full main OID + blob OID + approval PR）
  并 mint `VerifiedAuthorizationGrant`；grant 与最终 admission capability 均 non-Codable、
  无 public initializer，只有 package-owned resolver/admission 可 mint。typed reference 本身
  是可序列化审计引用，**不单独构成 authority**；raw document/context validator 不得再成为
  autonomous gate 的入口。
- **trusted composition**：生产入口只公开 `authorizationId` + typed request；GitHub、clock、
  durable binding、tool/device probe、plan validator、usage ledger 依赖由 product composition
  root 固定持有。测试可通过 `@testable` 注入 package-internal deterministic ports；调用方
  不得通过 public initializer 替换这些 ports 或自行构造 fact/grant/capability。

### Deliverables

- `MaintainerMergedAuthorizationResolver` 按上述 fresh protected-main/GitHub 链产生不可由
  caller 构造的 grant；任一 provenance fault 返回具名 policy block，零 capability、零 usage
  reservation、零 device/process dispatch。
- `RockchipAuthorizationFactCollector` 必须在同一 admission invocation 内自行取得并关联：
  1. `RockchipRockUSBFlashProvider` 对实际 archive 现场生成的 execute plan、archive SHA、
     plan/step-set digest 与 provider/profile identity；caller 不得构造 `RockchipFlashPlan`
     作为事实；
  2. `DeviceBindingJournalAdapter.currentDurableBinding()` 产生的 package receipt，且
     session/job、target ID、revision 与 grant/plan 全部相同；identity snapshot 必须含非空
     `serial` 与 canonical `usbTopology`，serial 只在内存按精确 UTF-8 bytes SHA-256，raw
     bytes 不入日志/evidence；
  3. descriptor-bound tool probe 的实际 executable identity/hash receipt与 pinned
     rkdeveloptool profile；公开可构造的 `ProcessExecutableIdentityReceipt`、
     `RockchipDeviceObservation`/`RockchipDeviceDiscoveryAttempt` 均不可信，collector 必须
     亲自调用 trusted port 并包装为无 public initializer 的 fact；
  4. product-owned typed prerequisite receipts（loader/recoveryPath/unlocked/stablePower 全部
     required 项为 satisfied；missing/unknown/unsatisfied 一律拒绝）；
  5. 目标设备**实际 probe**返回的 serial digest + USB VID/PID/topology readback，匹配
     authorization 与 durable binding，并绑定同一 job/plan/target、单调 observation sequence
     与 `observedAt/deadline`。deadline 最大 30 秒，首个真实 Step 前必须重验；journal 中的
     serial 只能作为 expected value，不能冒充实际 readback。
- #301 的只读 Rockchip discovery seam（source
  `67f585324d002f80c2682a1bdaa9ae7d11ed035a`、integration profile
  `433263fc3f4f15bad798758a29e77740a43ef812`）可为 trusted collector 提供 actual
  `rkdeveloptool ld` descriptor receipt 与 Loader VID/PID/location observation，但其不返回
  serial，**单独不足以** mint machineReadback/final admission。missing serial、多个/歧义
  observation、topology/mode/profile/hash 漂移一律拒绝；不得猜测或从 durable binding 合成
  actual observation。该 seam 本任务只读，修改须另开任务。
- `AuthorizationAdmissionService` 必须先完成 grant + 全部事实验证，再调用 AIN-005
  `AuthorizationUsageLedger`（readiness pin
  `d87d93caf9fba52e34bdfbaa9a5eb6e16c7cc1b9`）在 product-owned fixed host root 做 atomic
  reservation，之后才可返回 package-owned one-shot admission capability。reservation ID
  由 authorizationRef/job/plan/target 确定性导出，同一 retry 幂等；`maxRuns=1` 下并发最多
  一个 durable reservation，atomic replace 后 crash 仍消费、不退款，ledger/lock/fsync/
  decode 不确定时无 capability。
- `RockchipFlashAuthorizationGate` 的 human 路径保留，ordinary CI/standard agent 仍
  `policyBlocked`；autonomous 路径只接受上述 admission capability，不接受 raw
  `RockchipStandingAuthorization`、caller context、typed reference 或任一公开 receipt。
  删除现有 agent 成功后返回 command strings/handoff 的 authority；本任务不得 mint
  stepIntent、不得 spawn/dispatch。
- AIN-007 产品 executor 尚未存在，因此 `arkdeck flash --execute --agent` 必须在 resolver/
  fact/usage 之前以明确 `executorUnavailable` fail closed：不读取授权、不烧 usage、不输出
  可供 external shell 执行的命令。AIN-006 的正例仅在 package-local fake contract 中证明
  admission capability；绝不声明 production approval、realHardware 或实际执行能力。

### Verification

- `TEST-AIN-AUTH-PROV-001`：fresh protected-main 正例只 mint 一份 grant；invalid ID/path、
  worktree/ref/历史-main override、unprotected/moved main、blob/tree/merge ancestry 漂移、PR
  open/wrong base/wrong actor/wrong merge/review/CODEOWNER、duplicate/unknown JSON、stale/offline
  no-cache 全部拒绝，capability/reservation/process/device/destructive dispatch 均 0。
- `TEST-AIN-FACT-001`：caller context/API 已消失；非 durable/wrong job-target-revision binding、
  caller-constructed public receipt、missing serial/topology、tool/profile/plan/archive drift、
  prerequisite unknown/unsatisfied、actual serial/VID/PID/topology/mode mismatch、ambiguous device、
  stale/replayed/expired readback 全拒绝；只有同一 admission 内可信 ports 的全关联正例可进入
  reservation。
- `TEST-AIN-USAGE-001`：直接复用真实 AIN-005 ledger 做并发、lock/append/replace/fsync crash
  window 与 retry fault test；`maxRuns=1` 恰一 durable reservation、retry 不重复、crash 不退款，
  reservation 与 typed authorizationRef/job/plan/target correlation 全匹配。
- API/source assertion：旧 `--authorization`、`--unattended-context`、
  `CLIUnattendedContext` 与 raw-agent gate 入口为 0；外部 test target 不能构造 grant/fact/final
  capability；agent command surface/stepIntent/child launch 恒为 0。保留并复跑
  AC-FLASH-015-01/02、AIN-CONTRACT-001、usage ledger 与 discovery regression。
- 测试只使用本地 deterministic Git/GitHub metadata fixture、真实 host filesystem ledger 与
  fake device/tool/fact ports；network/HDC/rkdeveloptool/device/destructive dispatch = 0，不把
  fixture merge metadata、fake readback 或 plan-only 结果冒充 production approval/hardware。
- Readiness baseline：macOS 26.5.2 (25F84)、Xcode 26.6 (17F113)、Swift 6.3.3；
  `swift test --package-path Packages/ArkDeckKit` **336 tests / 1 skipped / 0 failures**；
  `check-sdd` **0 errors / 0 warnings / 111 acceptance IDs**。实现 PR 运行 full Swift、焦点三
  canonical tests、strict format/diff/scope/privacy/no-network/no-device 审计，并在
  `evidence/runs/TASK-AIN-006/` 记录命令、结果、偏差与残余风险；任务完成/verified 状态仍须
  后续独立 PR，不在实现 PR 自翻。

## TASK-AIN-008 — Rockchip persistence and admission identity closure

- Status:done
- Done:2026-07-22；实现经 #312 合入 main（merge commit
  `de988f19cf9d1200523370c797ed5f70718eda11`；reviewed head
  `ea81120218b004ff9a3193fd7fa24a933a9d4bea`）；done recheck 于合入版复验：Swift 全量
  346/1 skipped/0 failures，`TEST-AIN-ROCKCHIP-PERSISTENCE-001`、AIN-CONTRACT/FACT/USAGE
  regression 全 PASS，两份 schema Draft 2020-12 正反例 1/19 与 1/3 全 PASS，guard
  0/0/111；reviewed head 到 merge commit 全 tree diff = 0；host/fake-only、device/HDC/
  rkdeveloptool/destructive dispatch = 0；evidence =
  `evidence/runs/TASK-AIN-008/2026-07-22-rockchip-persistence-implementation.md`
- Platform:macos
- Requirements:REQ-FLASH-011/012/015、POL-WORKFLOW-001、POL-ARTIFACT-001、
  POL-PRIVACY-001
- Acceptance:AIN-CONTRACT-001 regression；AIN-DISPATCH-001 prerequisite contract 面
- Depends on:TASK-AIN-005、TASK-AIN-006
- Objective:在不改写历史 v1/v2 的前提下，以 Manifest/Journal `2.1.0` 表达诚实的
  descriptor-bound Rockchip toolchain，并把 AIN-006 已验证的 executable identity 保留到
  one-shot admission final facts，使 AIN-007 能逐 spawn 做同一 descriptor identity 再关联。
- Readiness reviewed:2026-07-22；base = protected `main`
  `444547761c3a855cd4db44acb8a50ca54e9a3294`（#310 merge）。AIN-005 已由 #304 done；
  AIN-006 已由 #309 done；审计时 open PR = 0。#310 仅改 `tasks.md`，其 345/1 skipped/0
  failure Swift 与 guard 0/0/111 baseline 对本任务继续有效。
- Blocker provenance:
  - current/Manifest v1 `$defs.toolchain` 只允许 `hdc|none`，locked Manifest v2
    `9ac334013968a5aba1a0bd77fe2acc982ba0e680` 直接引用该定义；
    `SessionManifest.swift` `739859546298a6aa5131221beb795722f49d9df6` 同样硬编码
    `hdc|none`。non-simulated Rockchip run 无诚实可编码值；
  - `RockchipAuthorizationFacts.swift`
    `a5df9a5a5c496b894f59c30a0497f393c5a7fc20` 的 tool fact 含
    `ProcessExecutableIdentityReceipt`，但 final `RockchipTrustedAuthorizationFacts` 未保留它；
    AIN-007 无法满足 #310 声明的 same-admission descriptor identity correlation。
- Allowed paths（实现 PR 的封闭文件面）：
  - 新增 change-local
    `contracts/manifest.schema.v2.1-draft.json` 与
    `contracts/journal-event.schema.v2.1-draft.json`；v1/v2 文件只读；
  - 修改 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift`
    `a5df9a5a5c496b894f59c30a0497f393c5a7fc20`（仅 final facts 保留 collector 已验证的
    executable identity receipt）；
  - 修改 Storage：`JournalEvent.swift`
    `38759bdfd8aa749f107f1cb1f74f2dece8a4c01f`、`JournalEventValidation.swift`
    `bfbff8430c1f5bd12745ec0847f7581165db1dca`、`JournalReplay.swift`
    `3614aaeb5db541ca7009ef6b0c84abdef7bb1c1f`、`SessionManifest.swift`
    `739859546298a6aa5131221beb795722f49d9df6`、`RetentionAndExport.swift`
    `62299802134964d23ecd51c547415257d847b906`；
  - 修改焦点 tests：`AuthorizationAdmissionContractTests.swift`
    `94b5467580dbcf28bdbbbcd52dafd94452f0b4dc`、
    `SessionArtifactStorageContractTests.swift`
    `d7f1c2cfa7f67fc1694e4292a8e60380c8e376b5`；
  - 新增 `evidence/runs/TASK-AIN-008/**`。
- Forbidden paths:
  - current specs/contracts/baseline、既有 Manifest/Journal v1/v2 schema bytes、Provider/Profile、
    Process/Runtime、Authorization admission/provenance/usage ledger、CLI、AIN-007 executor 文件；
  - authorization 载体、AIN-004 evidence、hardware matrix、network/HDC/rkdeveloptool/device/
    external-process dispatch。
- Risk:contract/persistence（host-only；dispatch=0）
- Hardware required:no

### Locked 2.1 contract

- Manifest/Journal schemaVersion 固定 `2.1.0`；v1/v2 decode/encode/canonical bytes、mixed-version
  拒绝、authorizedAgent authorization/usage/destructive intent correlation 原样保持。2.1 Journal
  不增加 caller 字段，只继承 v2 payload semantics，使 terminal Manifest 与 Session journal 保持
  exact schema version。
- 2.1 Manifest toolchain 新增唯一 closed shape：
  `{kind:"rockchip",profileIdentifier,reportedVersion,sha256,pathSource,
  descriptorIdentity:{device,inode,fileSize,mode}}`。`profileIdentifier/reportedVersion/sha256/
  pathSource` 必须与 trusted tool fact/pinned integration profile 一致；数字字段来自 Process port
  实际 descriptor receipt。禁止 absolute path、bookmark bytes、stable descriptor path、caller
  label/argv/environment 与额外字段；existing `hdc|none` shape 原样可读。
- `RockchipTrustedAuthorizationFacts` 仅新增内部
  `executableIdentity:ProcessExecutableIdentityReceipt`，值必须逐字来自同次 collector 的
  `RockchipTrustedToolDeviceFact`。不新增 public initializer/Codable/API，receipt 本身不授予
  dispatch；AIN-006 grant→facts→reserve 顺序和 one-shot consume 不变。
- retention/export allowlist 仅放行上述非敏感 Rockchip identity 字段；本机授权路径、原始 serial、
  bookmark、环境变量、stdout/stderr 不得进入 Manifest 或 export。

### Verification

- `TEST-AIN-ROCKCHIP-PERSISTENCE-001`：2.1 authorizedAgent positive round-trip + terminal
  journal/Manifest exact correlation；toolchain profile/version/hash/descriptor identity 全保留，
  absolute path/bookmark/argv/extra field 均不存在；export round-trip 只保留 allowlist 字段。
- negatives：缺/漂移 profile、version、hash、pathSource、device/inode/size/mode，伪 path/bookmark、
  v2 填 rockchip、2.1 mixed v1/v2 event、authorization/usage/intent drift/ghost/duplicate 全拒绝。
- admission：collector verified receipt 与 final facts/one-shot consumed capability 完全相等；tool fact
  drift 仍在 reserve 前拒绝，capability reuse 不变；public target 仍不能构造 final facts/grant。
- regression：AIN-CONTRACT-001、AIN-GATE-001、AIN-USAGE-001、全部 manifest/journal/storage/export
  tests 与 full Swift；新增两份 schema 做 Draft 2020-12 positive/negative validation；strict format/
  diff/scope/privacy/no-live-dispatch 审计；run evidence 记录命令、结果、偏差与残余风险。
- 实现完成后使用独立 status PR 标 AIN-008 done；AIN-007 另做新 readiness，重新 pin main、
  2.1 schema 与 modified facts/storage OID，不能复用 #310 readiness。

## TASK-AIN-007 — product-owned Rockchip typed executor

- Status:blocked（#310 readiness 在实现前 recheck 发现 Manifest toolchain 表达与 admission
  executable identity retention 两项 P0 缺口，见 TASK-AIN-008/设计 §13；#310 作为历史保留但
  不得用于实现或 dispatch。等待 AIN-008 done 后以新 main/OID 独立重做 readiness）
- Platform:macos
- Requirements:REQ-FLASH-008/009/011/012/013/015、POL-WORKFLOW-001、
  POL-RECOVERY-001
- Acceptance:AIN-DISPATCH-001；AC-FLASH-008-01、012-01、013-01、015-03 contract 面
- Depends on:TASK-AIN-005、TASK-AIN-006、TASK-AIN-008
- Readiness reviewed:2026-07-22；base = protected `main`
  `ce7b48e9ed5bd135ce6e77e0b43d32e21efe8e06`（#309 merge，AIN-006 done），审计时
  open PR = 0。TASK-AIN-005 已由 #304 done；TASK-AIN-006 实现 #307、evidence 修正
  #308 与 done #309 均已合入；#309 head
  `7082b9f7d41128862650d94973e8524ab6a42d0f` 到 merge commit 在 `tasks.md` tree
  diff = 0。
- Allowed paths（实现 PR 的封闭文件面）：
  - 修改 `Packages/ArkDeckKit/Package.swift`
    `dc2374629ac6b0235302312b59717e0f565c7ed2`（仅给 `ArkDeckWorkflows` 增加
    `ArkDeckRuntime` 依赖，并登记 `ArkDeckFakeRockchipFixture` test executable/依赖）
  - 修改 `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
    `b1671da1682a877fcc2c8e7e870c43a4ce1a10b9`（移除 AI 分支的
    `executorUnavailable`，只路由 high-level typed request；human handoff 面保持）
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecution.swift`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionLowering.swift`
  - 新增 `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionStaging.swift`
  - 新增 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift`
  - 新增 `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionFaultContractTests.swift`
  - 新增 `Packages/ArkDeckKit/Tests/ArkDeckFakeRockchipFixture/main.swift`
  - 新增本 change `evidence/runs/TASK-AIN-007/**`
- Read-only implementation inputs（不得修改；任一 blob 漂移即本 readiness 失效重查）：
  - admission/facts/gate：`AuthorizationAdmission.swift`
    `69fec8990c7cb68c989460ee883bbe358900cc96`、`RockchipAuthorizationFacts.swift`
    `a5df9a5a5c496b894f59c30a0497f393c5a7fc20`、`RockchipFlashAuthorization.swift`
    `a3fb1711271d32119db861a351ce2f2aa70c94fd`；
  - Provider/profile/archive/discovery：`RockchipRockUSBFlashProvider.swift`
    `8a30eb828773260d8b02b854d03a63ecf2da124f`、`RockchipFlashProfile.swift`
    `de82a3a008b95ef63148f7c9e4374298e6671328`、`GzipTarArchiveReader.swift`
    `36daf0eea9279790258d1ffaa1d87365cd1489d1`、`RockchipDeviceDiscovery.swift`
    `67f585324d002f80c2682a1bdaa9ae7d11ed035a`、Rockchip integration profile
    `433263fc3f4f15bad798758a29e77740a43ef812`；
  - process/runtime/storage：`ArkDeckProcess.swift`
    `b1d5f423c004f4ba15b15a8cf862ed2085d8bcc9`、`PowerActivity.swift`
    `9d887070a21eac8140cfca236bbde29492d007a5`、`ArtifactStorage.swift`
    `635f4da53094305dc52dff6ebdb26e1ccb026ea1`、`AuthorizationUsageLedger.swift`
    `d87d93caf9fba52e34bdfbaa9a5eb6e16c7cc1b9`、`DurableFiles.swift`
    `039fbb891fdc78c3cf19acc47b3f1231b9dde5c0`、`JournalEvent.swift`
    `38759bdfd8aa749f107f1cb1f74f2dece8a4c01f`、`JournalEventValidation.swift`
    `bfbff8430c1f5bd12745ec0847f7581165db1dca`、`JournalReplay.swift`
    `3614aaeb5db541ca7009ef6b0c84abdef7bb1c1f`、`SessionManifest.swift`
    `739859546298a6aa5131221beb795722f49d9df6`、`SessionLayout.swift`
    `ed48f90a96ee239769e86727ae9272017fea72f7`、`DeviceBindingJournalAdapter.swift`
    `b07a8c7a8b5d45e335b2ec5dc04dd18cba48dde4`；
  - locked deltas：provider v2 `3413edf56811ac30bef833f324cbdf59cff9ce52`、journal v2
    `6285acd4ca0350d427aa624afa91be3107769a64`、manifest v2
    `9ac334013968a5aba1a0bd77fe2acc982ba0e680`、usage v1
    `b232db49d2d76fc2eb96fed6b7d0230455d99345`。
- Forbidden paths:
  - 除上列文件外的全部 `Packages/**`，尤其 Core/Process/Runtime/Storage、现行
    Provider/Profile/admission/facts/gate/discovery；需要修改即停止并另提 scope amendment
  - current specs/contracts/baselines、change-local contract/schema 与 authorization 载体
  - AIN-004 evidence、hardware matrix、真实 device/HDC/rkdeveloptool/network dispatch；
    implementation/verification 只准运行 repository-built fake descriptor executable
- Risk:destructive semantics（实现与验证仅 fake descriptor executor，真实 dispatch=0）
- Hardware required:no

### Readiness trust and composition boundary

- public/CLI 输入只含 strict `authorizationId`、archive URL 与 target location selector；archive
  path 只是待现场 hash/stage 的内容位置，selector 只是 cross-check。CLI flag、环境变量、工作树、
  caller executable/tool path、argv、journal/Manifest、fact receipt 或 handoff command 均不能成为
  authority、tool/device fact 或 dispatch primitive；继续拒绝 retired `--authorization`、
  `--unattended-context` 及新增的 `--tool`/`--argv`/`--executable` 类注入面。
- `RockchipFlashExecutionHost` 的 production initializer 不公开依赖注入：fresh protected-main
  source、product-owned tool/bookmark、binding/session/storage roots、clock、power、probe 与
  `FoundationProcessExecutor` 由 composition root 固定持有；仅 `@testable` package-internal
  initializer 可注入 deterministic ports/fake descriptor。Agent/CLI 永远拿不到 admission、
  prepared launch、open descriptor 或 raw executor。
- 顺序固定为 admission(grant→facts→usage reservation)→v2 `authorizedAgent` jobCreated→gate
  plan correlation→one-shot admission consume(validUntil/readback deadline 再验)→逐 Step durable
  intent→descriptor-bound spawn→raw Artifact + semantic result→durable outcome→postflight→
  terminal Manifest。任一阶段不确定即停止；reservation 不退款，未知 destructive intent 不重放。
- `RockchipHumanHandoff` 只保留 human/diagnostic 路径；autonomous branch 不读取其 commandLines、
  不输出可执行 handoff、不调用 host shell/sudo，也不把 `controlledHardwareLab` 或 public
  `ProcessExecutableIdentityReceipt` 升级成 authorized-agent authority。

### Closed staging, lowering and persistence

- archive 只流式提取 Profile 精确列出的九个 regular members；duplicate、absolute/`..` 路径、
  link/special member、尾随 sibling、size/hash/member-set 漂移全部在 spawn 前拒绝。staging 位于
  owned Session root，目录/文件 owner-only；每个 image 以 no-follow descriptor 确认 inode/
  size/hash，child 结束前保留 descriptor，argv 只出现稳定 descriptor path，不出现 caller
  archive/member 路径。空间 claim、写入、fsync/rename/cleanup 不确定时 fail closed；crash/
  outcomeUnknown 保留恢复所需 staging，不猜测清理。
- typed lowering 是封闭表：Loader gate=`["ld"]`，partition-table precheck=`["ppt"]`，每个
  `flashPartition/rockusb.wlx-write`=`["wlx", partition, stagedDescriptorPath]`（按 Provider 九分区
  顺序），reset=`["rd"]`；`wl` fallback、未知 operation/kind/argument、额外 option 与 caller
  argv 恒拒绝。每次 spawn 都用同一 product-pinned executable SHA-256 做
  `executeIdentityBound`，并与 admission tool fact receipt 对同一 descriptor identity 再关联。
- Loader 与 15-row ppt parser、每个 wlx success marker、rd marker、postflight typed readback 均
  必须语义通过；exit 0 单独永不成功。stdout/stderr 分流写 bounded raw Artifact；Manifest 只在
  journal replay、Artifact hash、exact plan、九个 write outcomes、reset 与 postflight 全关联后
  原子发布。
- 所有 external-effect Step 先 durable intent 后 launch；v2 jobCreated 与每个 destructive
  wlx intent/outcome 携带同一 `authorizationRef`/`usageReservationId`，Manifest 的
  authorizedAgent actor/intent set 与 journal 精确相等。fake run 只能标 contract/fake，绝不
  产生 v3 realHardware evidence 或 hardware support 声明。
- 首个 device Step 前取得 idle-sleep activity，直到 postflight 或稳定 recovery/terminal 全路径
  释放；sleep/wake 只触发 durable event + reconcile。wlx 为 `criticalNonInterruptible`：取消/
  exit 先 durable 记录，绝不 force-kill 当前 child，到 semantic safe boundary 后阻断后续 Step；
  disconnect、identity drift、缺 outcome 或 postflight mismatch 进入 `waitingForRecovery`/
  `outcomeUnknown`，不得标 failed/succeeded 或自动重放。

### Verification

- `TEST-AIN-DISPATCH-001`：真实 AIN-005/006 contract 类型 + repository-built fake descriptor
  端到端；process argv 精确为 1×ld、1×ppt、9×wlx、1×rd，九个 image descriptor 的 bytes/
  hash 对应 Profile；v2 job/intent/outcome/Manifest correlation 全 PASS；handoff/shell/sudo/
  caller-command dispatch=0，real device/HDC/rkdeveloptool/network=0。
- admission negatives：无 grant、伪 carrier、fact/plan/readback/tool identity drift、expired/
  exhausted usage、capability reuse、CLI injection 全部在首个 fake spawn 前拒绝；usage 已 reserve
  的后续失败不退款。public API/source assertion 证明外部 target 不能构造 admission、host、
  prepared launch 或注入 executor/argv/path。
- persistence/crash matrix：jobCreated、intent append/write/fsync、spawn 前 descriptor recheck
  失败 → launch=0；durable intent 后/child side effect 后/outcome append/fsync/Manifest publish
  crash → reopened state 只能是 `waitingForRecovery/outcomeUnknown`，destructive replay=0，且
  authorization/intent correlation 不丢失。
- semantic/recovery matrix：ld/ppt/wlx/rd 各覆盖 nonzero、exit0 缺 marker、stderr/oversize/
  invalid UTF-8；九个 partition 中途 failure、disconnect、identity drift、postflight mismatch
  均停止后续 dispatch并产生诚实 recovery；只有全 marker + postflight 正例可 succeeded。
- cancellation/power/staging matrix：九个 critical window 逐一 cancel/exit，当前 child
  force-kill=0、后续 dispatch=0、activity 全路径归零；sleep/wake、ENOSPC、archive traversal/
  duplicate/link、stage path replacement、executable inode/hash replacement全部 fail closed。
- readiness baseline（上述 base 实测）：macOS 26.5.2 (25F84)、Xcode 26.6 (17F113)、Swift
  6.3.3；Swift 全量 **345 tests / 1 skipped / 0 failures**，guard **0 errors / 0 warnings /
  111 acceptance IDs**。实现 PR 须运行新增两组焦点测试、现行 Provider/authorization/
  process/runtime/storage/journal 回归与全量 Swift，strict format/diff/scope/privacy/no-live-
  dispatch 审计，并在 `evidence/runs/TASK-AIN-007/` 记录命令、结果、偏差与残余风险；任务
  completion/change verified 仍使用后续独立 PR。
