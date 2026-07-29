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

### Defect record(2026-07-28,done 后发现;done 历史与 evidence 不改写)

- 缺陷定性:production composition 与 hash pin **不一致**(接线缺陷),非授权门
  语义回退——AC-FLASH-015-01/02 的 fail-closed 行为、本任务 done 结论与 evidence
  均保持原状,不据此重开本任务;修复由下方新增 remediation 任务
  **TASK-AIN-003R** 承载(TASK-AIN-004 Forbidden paths 条款「实现已冻结,发现
  缺陷回 TASK-AIN-003」的落点;形态先例 = 本 change r2 security remediation 的
  「done 历史不改写、新任务闭缺口」,及 TASK-BRC-002R/TASK-SSET-001R)。
- 证据正本 = #676(merge `d17d303714257a6551c8630a460a61f4b2917d1a`)合入的本
  change `evidence/host-prerequisites/installation-runbook.md` §8 第 3 条(源码
  行级)。全部行号已于 2026-07-28 在 main `d17d303` 逐处复核成立
  (`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/` 自 runbook base
  `6383f5b9e8c61e61c798ee7f7cf09035faff2a3d` 起 rev-list 0 commit,零漂移;
  下记 Host/Discovery/Facts 分别 =
  该目录下 `RockchipFlashExecutionHost.swift` / `RockchipDeviceDiscovery.swift` /
  `RockchipAuthorizationFacts.swift`):
  - `RockchipProductionAdmissionPort.admit`(Host:1026)把声明为
    `pinnedProduction`(`executableSHA256` = `038a8a0e…3611`,声明处
    Host:800–806,pin 定义 Discovery:22–29)的 `settings.tool` 交给缺省
    `RockchipDeviceDiscoveryAdapter()`(Host:1039);
  - 缺省 init 钉的是 `pinnedReadOnlyDiscovery`(`bbd7bdc0…9923`,
    Discovery:542–544,pin 定义 Discovery:9–17;类注释 Discovery:4–6 明言
    destructive 身份不被缺省 adapter 接受);
  - 声明性 hash 门 `tool.sha256 == profile.executableSHA256`
    (Discovery:570–572)比较的即上述两个编译期常量,**恒不等** →
    `executableHashMismatch` → admission 于
    `toolOrDeviceObservationUnavailable`(Facts:140–143)fail closed:宿主
    前置装得再全,E2 admission 也结构性不可达;
  - 反向同样堵死:改用 bbd7 实体过不了 Facts:340、345–352 的
    `pinnedProduction` 断言(prepare 期 Host:196–200 同 pin)——两头恒拒。
- 影响边界:仅堵死 E2(admission→dispatch)面的真机可达性
  (AC-FLASH-015-03 realHardware 面,归 TASK-AIN-004);E0 只读面不经该
  composition,不受影响(runbook §8 边界记录)。

### Defect record 2(2026-07-28,宿主前置安装实际执行时发现;done 历史与 evidence 不改写)

- 缺陷定性:宿主前置消费机制对**进程 code-signing 身份**的隐含依赖未被设计与
  实证覆盖(机制缺陷),非授权门语义回退——AC-FLASH-015-01/02 的 fail-closed
  行为、本任务 done 结论与 evidence 均保持原状,不据此重开本任务;修复由下方
  新增 remediation 任务 **TASK-AIN-BKMK-001** 承载(TASK-AIN-004 Forbidden
  paths 条款「实现已冻结,发现缺陷回 TASK-AIN-003」的落点;形态先例 = 上方
  Defect record 与 TASK-AIN-003R)。命名注记:自然名 TASK-AIN-003R2 **不是
  合法任务 token**——`check_pr_paths.TASK_TOKEN_TEXT` 要求结尾
  `-[0-9]{3}[A-Z]?`(至多一个字母尾缀),实测
  `FULL_TASK_RE.fullmatch("TASK-AIN-003R2")` 为 None,`## TASK-AIN-003R2`
  段头将不被守卫识别、其段身(含 Allowed paths 行)会被并入前一任务段并毒化
  其活声明解析,故取家族形 token TASK-AIN-BKMK-001。
- 触发观察(维护者宿主,2026-07-28):按 #676(merge
  `d17d303714257a6551c8630a460a61f4b2917d1a`)runbook §2 安装第 1 项后执行
  §7 探针,`arkdeck flash execute` 报**裸 `NSCocoaErrorDomain Code=259`**
  (NSFileReadCorruptFileError),无任何 `productionConfigurationUnavailable`
  治理文案。
- 根因矩阵(本登记起草时受控复现,2026-07-28,main
  `b00c47ac3fcca63871f5736fe796bb48c7089d42`(#694 merge)树;Apple Swift
  6.3.3,macOS 26.5.2;探针 = 自有最小 install/resolve 程序,只动探针自有
  defaults key,bookmark 字节跨 defaults 域转移逐 base64 比对同一,零产品
  key、零 dispatch、零设备接触):

  | 创建者(签名身份) | 消费者(签名身份) | resolve 实测 |
  | --- | --- | --- |
  | `swift` 解释器(Apple 签名 `swift-frontend`;= runbook §2 helper 形态) | 同解释器再跑一次 | ok(stale=false、scope=true) |
  | 同上 | 编译 ad-hoc 二进制(CDHash `eb29a0815f4faeb11ac1de01d6e743b96c181819`),字节同一数据 | **`NSCocoaErrorDomain Code=259`** |
  | 该 ad-hoc 二进制(自建 bookmark) | 同一二进制新进程(跨进程重启) | ok(stale=false、scope=true) |
  | 同上 | 同源同名重编译产物(实测与原产物**字节级同一**,同 CDHash) | ok |
  | 同上 | 同源异名编译产物(仅签名 Identifier 异,CDHash `6dc6bb58cbaa73580be69c05d1b7fe6d73f22c74`),字节同一数据 | **`NSCocoaErrorDomain Code=259`** |

- 矩阵结论:`.withSecurityScope` bookmark 的 resolve **绑定创建者
  code-signing 身份**(ad-hoc 下 = Identifier+CDHash 粒度:字节级同一的产物
  同身份可解,任何签名身份差异即 259)。r3 D-1 段「非 sandbox CLI 能创建并
  解析 `.withSecurityScope` bookmark」的实证是**同进程自证**,只在同一签名
  身份内成立,未覆盖跨身份消费——该可行性结论对「helper 创建、产品消费」的
  安装途径不成立,runbook §2 helper(解释器进程)途径对产品**永不可行**。
- 产品面事实(同树实测):SwiftPM 构建的 `arkdeck` 为 **ad-hoc 签名**且签名
  Identifier 内嵌 LC_UUID(本次构建实测 Identifier =
  `arkdeck-555549440a814e09db9a394f9ec2b4dd1c28a330`(`55554944` = ASCII
  "UUID"),CDHash `556aab9ebb4fd0370c018e365cced9e8f83e83d1`)——签名身份逐
  (内容不同的)构建漂移,即便产品自建 bookmark,重构建后亦不可解析;且产品
  CLI 子命令全集 = `flash {plan, execute, postflight}`、
  `update-feed {prepare, assemble}`(`ArkDeckCLIMain.swift`:22–31、41–55、
  253–264,default 分支一律 usage 退出),**无任何 bookmark/宿主前置安装
  入口**。
- 行级证据(main `b00c47a` 实测;Host =
  `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`,
  #694 对该文件的两个 hunk 起于旧 997/1036 行,均在 load() 区间之后,
  load() 零漂移):`load()`
  (Host:760–827)的第 1 项消费路径(Host:777–791)中,bookmark 缺失
  (Host:778–781)与 stale/非 file URL/scope 失败(Host:786–791)均有
  `productionConfigurationUnavailable` 治理文案,唯 resolve 调用本身
  (Host:783–785,`try URL(resolvingBookmarkData:options:[.withSecurityScope,
  .withoutUI])`)裸抛 Foundation 错误,经 CLI 顶层 catch-all
  (`ArkDeckCLIMain.swift`:35–37 的 `\(error)` 打印)直出——即维护者看到的
  裸 259。(load() 其余裸抛点 Host:762、768、813、814 属其他前置项的消费,
  非本缺陷面。)
- 影响边界:仅 E2 execute 面。`load()` 为 E2 专用消费面——实测唯一调用链 =
  `arkdeck flash execute --authorization-id`(`ArkDeckCLIMain.swift`:116)→
  `RockchipFlashExecutionHost.init`(Host:17–19)→
  `RockchipProductionExecutionComposition.make()`(Host:669–671)→
  `load()`,Sources 全树零其他引用;E0 面(`scripts/e0_readback/` crib、
  TR-001 harness)零消费,不受影响。本缺陷闭合前 runbook §7 探针恒止于第一站
  (bookmark resolve),D-1 第 1 项不可闭合(runbook §2/§8 已加 dated 勘误
  注记,同 PR)。

## TASK-AIN-003R — production composition 的 discovery profile hash-pin 一致性(remediation)

- Status:done(2026-07-28 completion;仅在维护者 review/merge 本独立
  `ready→done` PR 后生效。**实现载体 = #694**(reviewed head
  `7ce8d57762878a630f8b66cc82390944e2c8254d`,merge
  `b00c47ac3fcca63871f5736fe796bb48c7089d42`):维护者 `lvye` 对 exact head
  APPROVED 并 merge;reviewed head 与 merge 在本任务三项交付文件的 blob
  OID 逐项同值(Host `ace82b11…`、新契约测试 `f58ac01b…`、run
  `d35143cc…`)。方向 A 已按 #690 readiness(merge
  `0d36375f875fae327f32860d60f0c4727b84a58c`)落地:production
  admission 通过 internal 命名 seam 显式注入 `.pinnedProduction`;
  read-only 缺省 adapter、Discovery 两 pin、Facts 真值锚与既有
  AC-FLASH-015-01/02 门均未修改。AIN-COMP-001 的正向独立 64-hex 锚 +
  真实声明门与负向 read-only profile real-fault 两用例均在树。
  **evidence** =
  `evidence/runs/TASK-AIN-003R/run.md`(blob
  `d35143cc27cf7a2de88c992a3d61df6ee18269b3`,SHA-256
  `f0508fe8b0fe5e069c4fc2fd6ce311fa7e8fc6eb37012a0118eff5389c9990c8`)。
  **flip base recheck**(当前 protected main
  `25d504285f60e0b343ed45be2821e88c664102d9`,非 `/private/tmp`
  worktree):#690/#694 均为 ancestor;#694 后 Host/Discovery/Facts/
  新测试/run 五项零 commit、blob 零漂移;焦点
  `RockchipProductionCompositionContractTests` = 2 tests / 0 failures,
  两条 `TEST-AIN-COMP-001` PASS;Swift 全量 = 442 tests / 1 skipped /
  0 failures,且三条 AC-FLASH-015-01/02 canonical PASS 摘要在位;
  `check-sdd` = 0 errors / 0 warnings / 111 acceptance IDs;host_loop
  `done_task_ids` = 106 且含本任务,本任务不再 claimable(status `done`
  非 ready;`Decision-Grade` 仍为 unknown);以本 PR 标题/Task 声明和单文件
  fileset 模拟 `check_pr_paths` = PASS。
  本翻转是确定性 D0 状态推进,单文件且仅改本任务段;任务
  `Decision-Grade` 行仍由维护者亲笔,本 PR 不代写。全程 host-only:
  device/HDC/rkdeveloptool/network/destructive dispatch = 0。
  **不声称** change 已 verified、TASK-AIN-004 E2 已可执行或
  TASK-AIN-BKMK-001 已闭合;后者仍按其独立 blocked→readiness→实现→done
  链推进。)
- Historical Status:ready(r1 readiness = #690 merge
  `0d36375f875fae327f32860d60f0c4727b84a58c`;其一次性实现授权已由 #694
  全额消耗。原 Status 正文如下作历史保留。)
- Historical Status:ready(r1 readiness;仅在维护者对本独立 readiness PR exact head
  review/merge 后生效,生效后一次性授权按下方 Readiness pins(r1)契约的
  实现交付)
- Historical Status:blocked（前置:本登记合入后另起独立 readiness PR;Depends on 的
  TASK-AIN-003 done 已满足。本登记 PR 零实现、不触碰 `Packages/**`）
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)
- Acceptance:change-local AIN-COMP-001(登记于 verification.md Acceptance
  matrix;AC-FLASH-015-01/02 行为不回退是其负向底线)
- Depends on:TASK-AIN-003(done,#292/#293;缺陷见其 Defect record)+ 独立
  readiness
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift`
  - `Packages/ArkDeckKit/Tests/**`
  - 本 change `tasks.md`（仅本任务段的状态/pins/evidence 引用）
  - 本 change `evidence/runs/TASK-AIN-003R/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `scripts/**`
- Risk:medium（production composition 接线与契约测试;零授权门语义变更、零设备
  effect、零新能力）
- Hardware required:no

### Deliverables

- Objective:使 production composition 的 discovery adapter 与 `pinnedProduction`
  tool 的 hash pin 一致——admission 期 adapter 所持 profile 的 `executableSHA256`
  必须与 `RockchipAuthorizationFacts` 断言的
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611` 为同一
  pin(修 composition 或显式注入正确 profile,方向由独立 readiness 钉定,本段
  不预设实现方案;缺陷正本 = TASK-AIN-003 Defect record 与 runbook §8 第 3 条);
- composition/hash-pin 一致性 contract test(正向)+ 错误 profile 注入
  fail-closed contract test(负向,real-fault 注入,TR-002R 先例);
- `evidence/runs/TASK-AIN-003R/` run 记录(全量测试基线对比)。

### Verification

- 正向(二值):契约测试证明 composition 处 adapter 的 profile hash ==
  `RockchipAuthorizationFacts` 的 `pinnedProduction` 断言(Facts:340/349 同一
  常量)→ PASS;
- 负向(二值):错误 profile 注入必须 fail closed(`executableHashMismatch` →
  `toolOrDeviceObservationUnavailable` 语义保持),且不放宽任何既有 admission 门
  (015-01/02 无授权/不匹配 → dispatch=0 逐字保持);
- 零其他语义变更;Swift 全量基线零回归(不低于 AIN-004 r3 基线 400 tests /
  1 skipped / 0 failures)。

### Notes / handoff

- 本任务 done 前,TASK-AIN-004 的 E2 面不可达(其 r4 前置清单第 7 条);E0 面
  不受本缺陷约束(DEC-012 判 (a),#670;runbook §8 边界记录)。
- 独立 readiness 须以当时 main 钉定待改文件 blob(全 OID)与实现方向,并复核
  缺陷仍在——若届时上游已另行修复,如实记录并按实况处置,不重复实现。
- Decision-Grade 行由维护者亲笔(TASK-BRC-002R 先例)。

### Readiness pins(r1,2026-07-28)

- Base(audit base):protected main
  `663eb77788bad86c77704769345d47a01d321c86`(#688 merge)。起草于该 base 的
  独立非 /private/tmp worktree(`~/wt-ain003r-readiness`;CHG-2026-024 r2
  教训:/private/tmp 检出内 Swift 契约测试红绿不可作结论),Apple Swift 6.3.3
  (arm64-apple-macosx26.0);下列全部 OID/行号/基线均为本次于该 base 实测,
  零处引用未实测数字。
- **Approval boundary:pending human merge。**本 readiness 仅在维护者对本独立
  readiness PR 的 exact head review/merge 后生效;载体只改本文件的本任务段。
  生效后一次性授权一个实现交付:按下方钉定方向与验证计划完成实现 + contract
  测试 + `evidence/runs/TASK-AIN-003R/` run 记录,载体 = 另一个标题声明本任务
  的独立 agent/* PR;`ready→done` 翻转再独立,Decision-Grade 行由维护者亲笔
  (任务卡既有条款)。本 readiness 不宣称任何 AC PASS,不触碰
  `verification.md`(AIN-COMP-001 行已由 #681 登记)。
- Dependency gate(逐项实测,均为 audit base ancestor):
  - TASK-AIN-003 done:实现 #292 merge
    `0a5c9fd99c3cc7f6bcf4e44044706de7c9d2215f`、done 载体 #293 merge
    `8b3847279621b49d784c31dbbc2e0bf408636e83`;
  - 本任务与 AIN-COMP-001 的登记正本 #681 merge
    `3e2e4ae63ea991c65c9be0b6ce88a9546403d01d`;
  - 缺陷证据正本 #676 merge
    `d17d303714257a6551c8630a460a61f4b2917d1a`(runbook §8 第 3 条);
  - E0 面边界裁定 DEC-012 判 (a) #670 merge
    `0da31ea74e88ab7f183c7aac593f51f401d9eb70`。
- 缺陷复核(audit base 源码实测:缺陷仍在,无上游另行修复):
  - 漂移面:`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/` 自 `d17d303`
    (#676)至 audit base rev-list 实测 **0 commit**;`3e2e4ae`(#681)至
    audit base 对 `Packages/ArkDeckKit/` 亦 0。Defect record 全部行级引用因此
    在 audit base 重测,逐处命中:
  - Host(`RockchipFlashExecutionHost.swift`):production composition
    `RockchipProductionExecutionComposition.make()`(669–679)把
    `settings.tool`(800–806 按 `pinnedProduction` 声明,804 =
    `.executableSHA256`)交给 admission port(677–679);
    `RockchipProductionAdmissionPort.admit`(1026,类 1000)组装
    `RockchipDiscoveryToolDeviceFactPort`(1037–1040)时用**缺省**
    `RockchipDeviceDiscoveryAdapter()`(1039);prepare 期同 pin(196–200,
    200 = expectedSHA256)。
  - Discovery(`RockchipDeviceDiscovery.swift`):缺省 `public init()` 钉
    `.pinnedReadOnlyDiscovery`(542–545);两 pin 常量 static let 实测区间 =
    9–16(`bbd7bdc0…9923`,行 12)与 21–28(`038a8a0e…3611`,行 24)——
    Defect record 所记 9–17/22–29 与实测区间差一行边界,两 hash 常量行 12/24
    均落在所记区间内、构造逐字同一(目录零漂移),缺陷实质不受影响;声明门
    `tool.sha256 == profile.executableSHA256`(570–572)比较上述两编译期常量
    **恒不等**;类注释 4–6、`permitsPinnedDiscovery`(63–65、573–575)同
    复核成立。
  - Facts(`RockchipAuthorizationFacts.swift`):观测失败 →
    `toolOrDeviceObservationUnavailable`(140–143);
    `expectedToolSHA256 = pinnedProduction.executableSHA256`(340)+
    profileIdentifier / executableIdentity 双断言(345–348、349–352)——换
    bbd7 实体两头恒拒,与 Defect record 逐字一致。
- 修复方向裁定(本 readiness 核心职责;#681 明文不预设,此处钉死):
  - **选定 = 方向 A:composition 处显式注入正确 profile。**Host:1039 的
    `RockchipDeviceDiscoveryAdapter()` 改为经 Discovery:547–553 **既有**
    internal `init(profile:executor:)` 注入 `.pinnedProduction`,并把该组装
    点提为 Host 文件内一个 internal 命名 seam(工厂或常量;1039 为唯一生产
    调用方),使「composition 实际所用 profile」对契约测试可观测(internal
    注入 init 的 @testable 消费先例 =
    `RockchipDeviceDiscoveryContractTests.swift:316`,access 面零变化)。
    Discovery 预期零修改;缺省 init 语义、两 pin 常量、声明门逐字不变。
  - 拒 B(Discovery 增接受 038a 的产品 profile 构造子):触碰面为 A 的严格
    超集(Host:1039 仍必改),且与 547–553 既有注入能力功能重复,零新增
    收益。
  - 拒 C(缺省 init 改钉 038a):放宽 read-only 缺省语义,违 Discovery:4–6
    类注释与本任务底线「不放宽 read-only profile 既有语义」,并将实测翻红
    既有 `testDefaultAdapterUsesOnlyTheCleanReadOnlyDiscoveryIdentity`
    (`RockchipDeviceDiscoveryContractTests.swift:345` 起,pin 缺省 =
    bbd7);E0 面亦被污染。
  - 拒 D(Host:800–806 改声明 bbd7 或双 pin 放行):Facts:340/345–352 双
    断言 + prepare 期 Host:196–200 同 pin 恒拒;Facts 有意不在活声明内
    (断言侧是真值锚,remediation 不得靠改断言过门),不动 Facts 而放行
    bbd7 唯有新增 admission 放行路径,违负向底线。
  - 越界检查:方向 A 全落本任务活声明内(Host + `Tests/**`;
    `Package.swift` 零接触——新用例入 ArkDeckContractTests 既有 target,
    #678 先例)。不存在「必须越出活声明」情形,无停手事由。
  - 测试冲突面(base 实测):`Tests/**` 全量 grep
    `toolOrDeviceObservationUnavailable` **零命中**——无既有用例 pin 当前
    缺陷行为;RockchipFlashExecution{,Fault}ContractTests 经
    `RockchipExecutionAdmissionPort` protocol fake(Recording/Rejecting)
    与 production composition 零耦合;缺省 adapter 语义用例与方向 A 零冲突。
- Input pins(audit base `git ls-tree` 实测完整 blob OID;实现开工须逐项复核
  零漂移,标注 invariant 者实现前后字节不变):

  | File | Git blob OID(audit base) | 性质 |
  | --- | --- | --- |
  | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift` | `50c23bf2b431bcae0fa4beb90f315a456957cc0c` | 待改:仅 1039 组装行 + 同文件 internal seam;196–200/800–806 等其余语义零变更 |
  | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift` | `38e38a2afc479993588a13c3fb10a8c7393eb64b` | 预期零修改;4–6/9–28/542–553/555–575 为行级 invariant |
  | `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift` | `971fe98feb9c9f5debf4abef948420383570f8ef` | invariant:只读真值锚,活声明外,实现禁触 |
  | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift` | `2a8318f6c4a54b44f7f6644d98b5c42825c988c5` | 仅新增用例,既有用例零修改 |
  | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipRockUSBFlashProviderContractTests.swift` | `db5986dda762286bda6872ed1b938299045e08fa` | invariant(015-01/02 腿) |
  | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/StandingAuthorizationContractTests.swift` | `d3750b771062c7ae2b9108cd6e8267772343471f` | invariant(015-01/02 腿) |
  | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift` | `82629470a4e8c16e5935159fa19aa93a0a2cf43a` | invariant(protocol fake 面) |
  | `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionFaultContractTests.swift` | `4a67cf7f7a50b41327049fa176ee84a11d112aba` | invariant(同上) |
  | 本 change `tasks.md`(本 PR 改前) | `6de7ebe1d481be41c74de0f816cda8538fb80d05` | 本 PR 载体 |

  hash 常量行级锚(实测):`038a8a0e…3611` = Discovery:24(定义)、
  Host:804(声明)、Host:200(prepare)、Facts:340(断言,349 消费);
  `bbd7bdc0…9923` = Discovery:12(定义)、Discovery:543(缺省 init 绑定)。
  新契约测试文件若新增,落
  `Packages/ArkDeckKit/Tests/ArkDeckContractTests/` 既有 target 目录。
- 验证计划(全部二值,可直译 XCTest;real-fault = 注入真实错误 profile 实体
  走真实声明门,禁 fake 常量分支,TR-002R 先例):
  1. 正向(AIN-COMP-001 正腿):测试侧以完整 64-hex **字面量**独立 pin
     `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`;
     断言 production seam 返回的 adapter 对按 Host:800–806 形态声明的 tool
     走真实 `processRequest`(Discovery:555–575)成功,返回
     `ProcessIdentityBoundRequest.expectedSHA256` == 该字面量,且该字面量 ==
     `RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256`
     (即 Facts:340 所读同一常量)——composition/Facts/测试三方一致。禁写成
     `pinnedProduction == pinnedProduction` 的套套断言:字面量是测试侧独立
     锚,常量漂移即红。
  2. 负向(AIN-COMP-001 负腿,real-fault):以 Discovery:547–553 init 注入
     `.pinnedReadOnlyDiscovery`(= 今日缺陷组合)对同一声明 tool:
     `processRequest` 抛 `.executableHashMismatch`(570–572);并经
     `RockchipDiscoveryToolDeviceFactPort`(Facts:115,internal init)走
     `observeToolAndDevice()` 抛
     `RockchipAuthorizationFactError.toolOrDeviceObservationUnavailable`
     (Facts:140–143)——错误形态与既有类型逐字一致,不新增任何放行路径;
     声明门失败即 `blockedToolAttempt`(discover 585 起,592)零进程
     spawn,用例封闭。
  3. 015-01/02 不放宽(零修改腿):
     `RockchipRockUSBFlashProviderContractTests.swift` 与
     `StandingAuthorizationContractTests.swift` 的 015-01/02 用例零修改,
     base 实测三条 PASS 行逐字保持:
     `TEST-AC-FLASH-015-01 PASS destructive_dispatch=0 job=policyBlocked handoff=controlled`、
     `TEST-AC-FLASH-015-01 PASS agent=policyBlocked ci=policyBlocked planOnly=allowed dispatch=0`、
     `TEST-AC-FLASH-015-02 PASS mismatch_fields=8 stale_plan_blocked=1 real_dispatch=0 realhardware_evidence=none`。
  4. 全量零回归:base 于本 worktree 实测 **Executed 415 tests, with 1 test
     skipped and 0 failures (0 unexpected)**,exit 0;汇总行取自完整输出
     文件、不经管道截断(AIN-004 r3 方法学注记沿用;`swift test` 末尾
     swift-testing「0 tests in 0 suites」行非汇总权威,以 XCTest Executed
     行为准)。实现后 = 415 + 新增 / 1 skipped / 0 failures,既有用例零
     修改;满足任务卡底线(不低于 400/1/0);实现开工须以届时 main 重测
     基线(在飞 #687 合入会增计数,底线随实测上移)。
- E0/E2 边界:约束 = TASK-AIN-004 r4 前置清单第 7 条(不复述):本任务
  done 前 E2 面不可达,E0 面不受本缺陷约束(DEC-012 判 (a),#670)。本
  readiness 与方向 A 实现均零 E0 面接触(缺省 adapter 语义不动)。
- 交集/环境(起草时实测):open PR = #689(scripts/chg-2026-041 面)与
  #687(chg-2026-022 的 HDC/Process/专属测试文件面)——两者与本 PR 文件集
  及本任务 pinned 实现面全部零交集(gh files 实测);实现开工时须以当时
  在飞集合重测。
- rebase 注记:起草期间 #683(TASK-UD-R2-DIAG-001 实现)合入 main,首推
  判定按当时 main 头把该 merge 的五文件计入本 PR 差集而红;载体遂 rebase
  到 `495c7356081a83d18538ae6fcdb3e3580134dfbf`(#683 merge)。audit
  base → 该 OID 区间实测**仅**五个 chg-2026-008/`scripts/**` 文件,与本
  PR 文件集及本任务 pinned 实现面零交集,`Packages/` 差集为 0;上表九项
  blob pin 已在该 OID 逐项 `ls-tree` 复核同值,行号锚与 Swift/check-sdd
  基线因此可迁移(#678 rebase 注记同型)。
- 守卫与自检(本 head 实测):base 树 `check_pr_paths` 对本任务解析恰得
  5 条声明、全仓 46 个 active 任务解析零异常;编辑后 tasks.md 复跑同值
  (无 AIN-004 型 multiple 声明行形态);本地以 fake event(base = rebase
  后 main 头,head = 本 commit)模拟判定 PASS;`./scripts/check-sdd.sh`
  0 error / 0 warning / 111 acceptance IDs;`git diff --check` 干净。
- stop gate:实现若需上述 pinned 集之外文件(含
  `Packages/ArkDeckKit/Package.swift`、`RockchipAuthorizationFacts.swift`、
  `openspec/specs/**`、`openspec/contracts/**`、`scripts/**`),停手、先以
  独立治理 PR 修订本任务 scope,不得静默扩展(CHG-2026-024 r2 先例)。

## TASK-AIN-BKMK-001 — pinned tool 宿主前置消费与签名身份解耦(remediation)

- Status:done（2026-07-28 implementation completion；仅在维护者
  review/merge 本独立一任务一实现 PR 后生效。实现与证据见
  `evidence/runs/TASK-AIN-BKMK-001/run.md`；本翻转不声称 change verified、
  TASK-AIN-004 E2 ready 或任何 hardware validation。）
- Historical Status:ready（fresh D1 r2；#710 exact head
  `22b2d2985fbf19e296c0b6dab3fb5fa809c7297e` 经 `lvye` APPROVED，并以
  `70739c4c483232ff6a5d094d753811114e3b9702` 合入后生效；该一次性实现
  authority 由本 implementation PR 消耗。）
- Historical Status:blocked（r1 D1 blocked-readiness；#703 exact head
  `e61e99790fe49772cc80614a664585871d5176f1` 经 `lvye` APPROVED，并以
  `20aeee5653d7eece08911c0a84afc92c1fa09702` 合入；三个登记候选当时均不能在
  既有 scope 内同时满足跨身份正向 AC 与 scoped/persistence 语义。合入明确
  不构成 `ready`，其事实与停止边界保留如下。）
- Historical Status:blocked（前置:本登记合入后另起独立 readiness PR；
  Depends on 的 TASK-AIN-003 done 已满足。本登记 PR 零实现、不触碰
  `Packages/**`。）
- Readiness review(r1,2026-07-28):
  - **Approval/dependency gate:satisfied for audit only。**本 remediation 登记
    #697 以 merge `25d504285f60e0b343ed45be2821e88c664102d9` 合入 protected
    main；前置 TASK-AIN-003 与其 composition remediation TASK-AIN-003R 均
    done，后者 #698 以 merge
    `51c1d9e9edf38dcbf77638c3e5ea0eb28bc470a8` 合入。两者都是 audit base
    的祖先；dependency done 只允许本次独立 D1 勘察，不预先接受 bookmark
    机制、scope 扩展或 CHG-2026-036 协调。
  - **Audit base/input pins:closed for blocked-readiness。**audit base =
    protected main
    `f20077a0630147be879acb5a8db5ae780ae79b2a`(#701 merge)。起草期间合入的
    #700/#701 相对先前 main
    `e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec` 只改 CHG-2026-022
    `tasks.md` 与 CHG-2026-042 四个 proposal 文件，下列非载体 pin 逐项未漂移。
    任何后继治理/readiness 必须从本 blocked-readiness merge 重新核验：

    ```yaml pins
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift
      blob: ace82b11bec98474df2fa2e9aa834e408893cfa5
    - path: Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift
      blob: 9267e44e4a8f75e09f8152c2d26ef07a115f4ccc
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift
      blob: 38e38a2afc479993588a13c3fb10a8c7393eb64b
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift
      blob: 87baadf3cd228660acb9923463cf288e90de6934
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift
      blob: 2a8318f6c4a54b44f7f6644d98b5c42825c988c5
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift
      blob: 82629470a4e8c16e5935159fa19aa93a0a2cf43a
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipProductionCompositionContractTests.swift
      blob: f58ac01babeb9990924e34cdbabebd50d31acc5b
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift
      blob: 68904a3f9ac87d70c31547c3242af86c232807a1
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md
      blob: ff90a8a222a8a8bc5278e994d786535b6c884160
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/verification.md
      blob: ecca35cc41ad30286dbafaa0f22d0c26089d2b8a
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2.1-draft.json
      blob: 02c7f27a9d65cbbca6e8fe23535ae8e62e398e7c
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/host-prerequisites/installation-runbook.md
      blob: 26509a32d0419246dbfa6b3e1f6cd98959a4e4aa
    - path: openspec/changes/chg-2026-036-macos-bundled-rockchip-component/tasks.md
      blob: de23d56688e713d90a2b12706e8d44651cffa164
    ```

  - **Primary contract/repository seam gate:binary conflict。**Apple 的
    [security-scoped bookmark creation
    option](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope)
    面向采用 App Sandbox 的进程；其
    [sandbox file-access guidance](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox?language=objc)
    区分「跨进程但无需持久 sandbox access」的普通 bookmark 与持久
    security-scoped bookmark；带
    [security scope 的 resolve
    option](https://developer.apple.com/documentation/foundation/nsurl/bookmarkresolutionoptions/withsecurityscope?changes=_4__5__8)
    只应用创建时已附加的 scope。现仓并非只在 Host `load()` 解一次：
    Host:783–801 以 `[.withSecurityScope,.withoutUI]` resolve、要求
    `startAccessingSecurityScopedResource()`，并构造
    `userSelectedSecurityScopedBookmark`；Discovery:21–29、496–530、561–604
    又要求 `requiresSecurityScopedBookmark=true`、同选项再 resolve 后才可能
    `ld`；Host:540、Storage:791/987–993 与 manifest schema:164–172 则把
    `pathSource=userSelectedSecurityScopedBookmark` 锁进证据。普通 bookmark
    不能只改 Host/CLI 后继续诚实地冒充该类型。
  - **Controlled matrix:ordinary direction proven, scoped replacement not
    proven。**host = macOS 26.5.2(`25F84`) arm64、Apple Swift 6.3.3；自有最小
    probe source SHA-256 =
    `7b7465858f3aef46a507b67524d1f104262f2a273349ccab9757efe5cba97191`，
    只在 `/private/tmp` 编译/读写自有 bookmark 文件，不读写产品 defaults，
    不启动目标工具。目标实体只做 read-only hash，实测
    `~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool` SHA-256 =
    `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
    命中 production pin：

    | 创建者 | 消费者 | bookmark / resolve 实测 |
    | --- | --- | --- |
    | ad-hoc `creator`(Identifier `creator`，CDHash `b5718436dfbb1fe55109d9f761931e75221ea422`) | ad-hoc `consumer`(Identifier `consumer`，CDHash `91367e2a8c4b166652808226f8074138e5794d73`) | 普通 bookmark：`stale=false,file=true,absolute=true,target_match=true,scope=false` |
    | Apple `swift` 解释器 | 上述 `consumer` | 普通 bookmark：同样 PASS |
    | 上述 `creator` | 上述 `consumer` | 同一普通 bookmark 改以 `.withSecurityScope` resolve：`NSCocoaErrorDomain Code=256` |
    | 显式同 Identifier `dev.arkdeck.bookmark-probe`、不同 CDHash `135f610d…` / `92802fe6…` 的两构建 | 跨构建 scoped 验证 | 当前 agent 宿主连 scoped create 都以 Code=256(`Could not open() the item`)失败，故**未形成正向证据** |

    普通 bookmark 的跨身份解析结论可复现于 `/usr/bin/true` 与上述实际 pinned
    tool；`scope=false` 是普通 bookmark 的预期观察，不是 security-scope 成功。
    当前宿主无法创建 scoped bookmark 是勘察环境限制，不能推翻 Defect record 2
    已记录的同身份 scoped 成功/跨身份 Code=259，也不能据此臆断稳定 Identifier
    路线成功。
  - **Candidate (a):BLOCKED by approved scope/contract。**普通 bookmark 已证明
    不依赖创建者签名身份，但要让产品消费，至少必须同时修改 Discovery 的
    path-source/access 模型、Storage/manifest canonical 值、draft schema、对应
    tests 与 runbook。前三项实现/契约面不在当前 Allowed paths，schema 还被
    Forbidden paths 明确禁止；只改 Host/CLI 会在 Discovery 二次 scoped resolve
    失败，或让 persisted evidence 错称 security-scoped，均不可接受。需要先以
    独立治理 PR 明确新的 typed pathSource、scope 与迁移/负向语义并扩充 exact
    paths，不能由本 readiness 静默扩面。
  - **Candidate (b):REJECTED by declared positive AC。**同一构建产物提供 install
    子命令，只能复用同一 code-sign identity；本任务正向要求「签名身份不同的
    两个构建产物先后消费同一已安装第 1 项前置」。把 r4 窗口收窄为同一 binary
    不满足该二值 AC，除非先经治理修改 Objective/Verification；readiness 无权
    降格验收。
  - **Candidate (c):BLOCKED by cross-change dependency/evidence。**稳定签名身份
    方向可保持现有 security-scoped/persistence 语义，但当前 controlled probe
    无法产生其跨构建正向证据；CHG-2026-036 TASK-BRC-003 仍在 D2
    release-environment gate（缺 Developer ID/notary/materialization handoff）
    blocked，TASK-BRC-004 又依赖 BRC-003 done + 独立 D1，尚未迁移
    product-owned composition。按本任务原 handoff，选择该方向前必须先用独立
    治理 PR 协调依赖/scope，不能把未完成的签名/分发 change 当作本任务输入。
  - **Readiness verdict:BLOCKED。**三个候选中不存在一个能在当前批准 scope/
    inputs 下闭合 AIN-BKMK-001。下一步须由独立治理 PR 二选一并经维护者
    review/merge：(A) 扩展本任务 scope/contract，正式采用普通 bookmark typed
    semantics；或 (C) 固定 CHG-2026-036 的前置依赖与可复核稳定签名身份正向
    evidence。若选择其他机制，也必须先修订 Objective/Verification/allowed
    paths。该治理门合入后仍须 fresh D1 readiness；在此之前任务保持 blocked，
    不开 implementation/evidence。
  - **Baseline/effect/concurrency gate:satisfied for blocked-readiness。**
    audit base 全量 `CI=true swift test --package-path Packages/ArkDeckKit` =
    442 tests / 1 skipped / 0 failures；其中 AC-FLASH-015-01/02 canonical
    摘要仍为 dispatch=0。`./scripts/check-sdd.sh` = 0 error / 0 warning /
    111 acceptance IDs，`python3 scripts/test_check_pr_paths.py` = 49/49 PASS，
    `git diff --check` 干净。勘察只编译/签名 `/private/tmp` 自有 ad-hoc probes、
    解析 bookmark 与 read-only hash 工具实体；目标工具 launch、产品 defaults/
    Keychain、产品 Process port/executor dispatch、HDC/USB/device、E1/E2/
    deviceMutation/destructive、network 与 credential/system mutation全为 0。
    `2026-07-28T07:06:39Z` 分页完整查询时，#700/#701 已成为本 audit base，
    open PR 集合为空；两次 merge 与本 readiness 载体及全部 candidate surface
    零交集。本 PR 只修改当前 `tasks.md` 的 TASK-AIN-BKMK-001 section。
- Governance route amendment(r2,2026-07-28;**only effective after maintainer
  review/merge this exact head**):
  - **Route decision:A / ordinary bookmark。**r1 已证明普通 bookmark 可被
    signing identity 不同的进程消费；方向 (b) 不满足既定跨身份 AC，方向 (c)
    仍被 CHG-2026-036 BRC-003/BRC-004 阻断。r2 因此选择 A，但只用于当前
    non-sandbox `arkdeck` CLI 的 `pinnedProduction` execution prerequisite；
    不把普通 bookmark 扩到 sandbox App，不改变 E0 read-only discovery。
  - **Typed access contract:closed。**`RockchipToolPathSource` 新增
    `installedOrdinaryBookmark`；selected tool 的 bookmark bytes 字段必须改为
    中性命名/typed carrier，不能继续称为 `securityScopedBookmark`。
    discovery profile 必须以 closed typed access policy 分别固定
    `pinnedReadOnlyDiscovery → userSelectedSecurityScopedBookmark` 与
    `pinnedProduction → installedOrdinaryBookmark`，不得用单个
    `requiresSecurityScopedBookmark` Bool 或 caller-supplied label 模糊两条路。
    production ordinary 分支只以 `[.withoutUI]` resolve，要求 non-stale、
    absolute file URL、resolved/canonical path 与 selected executable 精确相等；
    该分支不得调用或要求 `startAccessingSecurityScopedResource()`。E0 scoped
    分支继续以 `[.withSecurityScope,.withoutUI]` resolve、要求 scope start，
    其 registry/profile/hash/argv 与既有 tests 逐字保持。
  - **Install/storage contract:closed。**新增唯一 product-owned install 入口
    `arkdeck flash install-tool --path <absolute-path>`。它只接受 regular、
    non-symlink、canonical absolute file，先独立计算并要求 SHA-256 精确等于
    `pinnedProduction`，创建 ordinary bookmark 后以 ordinary options
    self-roundtrip/path-match，再写新 key
    `ArkDeck.Rockchip.ToolOrdinaryBookmarkV1`；任一步失败均不得留下可消费的新
    key。installer 不写 code-trust/quarantine、Keychain、binding、authorization
    或其他 D-1 项，不启动工具/Process port，不接触 USB/device。CLI path 只是
    安装输入，后续 admission 仍以 bookmark resolve + descriptor-bound hash/
    identity receipt 为事实，caller 不获得 launch capability。
  - **Legacy/migration gate:fail closed。**旧 key
    `ArkDeck.Rockchip.ToolBookmark` 只可作为 migration detector，永不再进入
    production resolve；legacy-only、legacy+new 并存、new key 缺失/非 Data/
    corrupt/stale/path mismatch 均在 `load()` 第 1 项阻断并输出受控
    `productionConfigurationUnavailable` 文案，产品 Process port/executor
    dispatch=0。installer 只有在新 bookmark 已 self-check/write/readback 成功
    后才删除 legacy key；中途 crash 最坏留下 dual-key，而 dual-key 必须继续
    fail closed，重跑 installer 可完成恢复。不得把旧 scoped bytes 按 ordinary
    options 猜测消费，也不得回退外部 PATH/Homebrew/裸 path。
  - **Persistence compatibility gate:closed widening。**新产生的 authorized
    Rockchip Manifest `2.1.0` 必须写
    `pathSource:"installedOrdinaryBookmark"`；既有
    `pathSource:"userSelectedSecurityScopedBookmark"` 的历史 2.1 Manifest
    bytes 保持可读、不可改写。change-local
    `manifest.schema.v2.1-draft.json` 与 locked validator 只把这两个值作为 closed
    enum 接受；新 production writer 只能发出新值，未知值继续拒绝。Manifest/
    journal/export 仍禁止绝对 path、bookmark bytes、argv/environment；schema
    version、profile/version/hash/descriptor identity、authorization/usage/
    intent correlation 与 v1/v2 历史语义全部不变。
  - **Security/authority gate:unchanged。**ordinary bookmark 只替换 D-1 第 1 项的
    locator persistence，不授予 authority。platform trust/quarantine、production
    hash pin、descriptor identity、fresh protected-main grant、usage reservation、
    binding/readback、plan/firmware/step pins、intent-before-dispatch 与
    AC-FLASH-015-01/02 dispatch=0 全部原样；bookmark bytes、defaults 与安装 path
    均不得成为 authorization/evidence truth。
  - **Exact implementation surface after fresh readiness:closed。**Route A
    实现只能修改下方扩展后的 Allowed paths；尤其 current specs/contracts、
    RockUSB E0 integration registry、CHG-2026-036、App/Xcode、Package.swift、
    Process/authorization/provider/journal/retention、scripts 与任何设备面均
    read-only。若实现需要这些文件之一，停手并先开新的独立治理 PR，不在
    readiness/implementation 中扩面。
  - **Fresh D1 gate:required。**本治理 PR merge 后仍须独立 readiness：
    从届时 main pin 全部 implementation blobs；重新做 open-PR intersection 与
    production source-reachability，证明 ordinary route 只可由 CLI
    `pinnedProduction` 到达而 E0/App 不可达；钉定 installer/load 可测试 seam、
    同 executable basename/`arkdeck` defaults domain 但
    different-Identifier/CDHash 的 two-product-build matrix、legacy/dual-key/
    crash migration fault matrix、2.1 old/new schema compatibility matrix、
    exact focused/full Swift commands与 run evidence shape。任何 seam 需要超出本 scope，
    或跨身份正向无法在**产品路径**复现，任务继续 blocked。
  - **This governance PR effect/concurrency boundary。**base =
    `02907b69b8fd7d1347ba26822e4a1961415fbc16`(#704 merge)；#703 exact head
    于 `2026-07-28T07:13:51Z` 经 `lvye` APPROVED，并于
    `2026-07-28T07:13:57Z` 由其以
    `20aeee5653d7eece08911c0a84afc92c1fa09702` 合入，且为本 base 祖先。
    起草期间 #704 合入的五个 CHG-2026-022 proposal 文件与本载体/后继
    surface 零交集；`2026-07-28T07:23:10Z` 分页完整查询的 open PR 集合为空。
    本 PR 只修改当前 `tasks.md` 的本任务 section；零 product/schema/runbook
    实现、零 defaults/Keychain/credential/network/process/tool/HDC/USB/device/
    E1/E2/destructive effect，不自行写 `Decision-Grade`。
- Readiness review(r2 fresh D1,2026-07-28；完整可复查记录 =
  `evidence/runs/TASK-AIN-BKMK-001/readiness-r2/run.md`):
  - **Approval/dependency/base gate:satisfied。**Route A 治理 PR #706 的
    `github-actions[bot]` exact head
    `ef2382aef3346a4ec07656b8b3dbd6475174f7d8` 于
    `2026-07-28T07:29:23Z` 经 `lvye` APPROVED，并于
    `2026-07-28T07:30:10Z` 由其合为
    `14b46e3066c52f54568e97545c59b3506ffc62a4`。final fresh audit base =
    `origin/main` =
    `c295d4a45a30ea08d7ab66440c5593d1208f222a`；#706、#703 r1
    blocked-readiness、#697 remediation 登记与 TASK-AIN-003R done merge
    均为其祖先。起草期间 #707/#708/#709 只改
    CHG-2026-042/008/022 七个文件，与本载体、allowed surface 及下列全部 pin
    零交集。
  - **Exact base pins:closed。**实现只能从本 readiness merge 的 main 重新复核
    下列 base blobs；任一漂移或需要列表外实现文件即停手、重做独立 D1：

    ```yaml pins
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift
      blob: ace82b11bec98474df2fa2e9aa834e408893cfa5
    - path: Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift
      blob: 9267e44e4a8f75e09f8152c2d26ef07a115f4ccc
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift
      blob: 38e38a2afc479993588a13c3fb10a8c7393eb64b
    - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift
      blob: 87baadf3cd228660acb9923463cf288e90de6934
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift
      blob: 2a8318f6c4a54b44f7f6644d98b5c42825c988c5
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionContractTests.swift
      blob: 82629470a4e8c16e5935159fa19aa93a0a2cf43a
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionFaultContractTests.swift
      blob: 4a67cf7f7a50b41327049fa176ee84a11d112aba
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipProductionCompositionContractTests.swift
      blob: f58ac01babeb9990924e34cdbabebd50d31acc5b
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipRockUSBFlashProviderContractTests.swift
      blob: db5986dda762286bda6872ed1b938299045e08fa
    - path: Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift
      blob: 68904a3f9ac87d70c31547c3242af86c232807a1
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2.1-draft.json
      blob: 02c7f27a9d65cbbca6e8fe23535ae8e62e398e7c
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/host-prerequisites/installation-runbook.md
      blob: 26509a32d0419246dbfa6b3e1f6cd98959a4e4aa
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md
      blob: 3ff434156a8105196a156946cd684c81bbc8bb76
    - path: openspec/changes/chg-2026-025-ai-native-unattended-device-ops/verification.md
      blob: ecca35cc41ad30286dbafaa0f22d0c26089d2b8a
    - path: Packages/ArkDeckKit/Package.swift
      blob: 292135a2c80c63ddf7182f58e2f81ff7c7d6104d
    - path: Packages/ArkDeckKit/Sources/ArkDeckProcess/ArkDeckProcess.swift
      blob: d68939a5446a7026db7607086b58ba700d642701
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift
      blob: 971fe98feb9c9f5debf4abef948420383570f8ef
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift
      blob: a3fb1711271d32119db861a351ce2f2aa70c94fd
    - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift
      blob: 8a30eb828773260d8b02b854d03a63ecf2da124f
    - path: openspec/integrations/rockchip/rockusb-discovery/1.0.0/registry.yaml
      blob: 394e2a8c588c531208cd3154a1dc8638ad77010e
    ```

    末五项及 integration registry 是 read-only stop pins，不因列入本表获得修改
    authority；Allowed/Forbidden paths 仍为唯一实现边界。
  - **Production reachability:closed to CLI production。**Sources/App 全树
    实测唯一产品链 =
    `ArkDeckCLI:116 RockchipFlashExecutionHost()` →
    `Host:671 RockchipProductExecutionSettings.load()` →
    `Host:1011 RockchipDeviceDiscoveryAdapter(profile:.pinnedProduction)`；
    `ArkDeckApp/**` 零引用。public 缺省 adapter 继续
    `.pinnedReadOnlyDiscovery`，E0 registry 的 scoped pathSource/hash/argv
    保持上述 read-only blob；ordinary 分支不得由 E0/App 到达。
  - **Installer/load/test seam:closed inside scope。**CLI 现有 closed flash
    subcommand + option parser 可容纳唯一 `install-tool --path`；
    Workflows 已依赖 Process，且
    `FoundationProcessExecutor.prepareIdentityBoundLaunch` 是 package seam，
    实测其 `lstat`/`O_NOFOLLOW`/regular/executable/descriptor/hash 门只 prepare
    可关闭 token、无需 spawn。实现将 production-only public installer facade 与
    internal preferences/bookmark-codec/verifier、first-prerequisite loader seams
    放在 Host allowed file；test target 已依赖 Workflows，可用 `@testable`
    覆盖而无需修改 `Package.swift`/Process。Discovery 只把 Bool 改 closed typed
    policy、bookmark 字段改中性 carrier；Foundation process port 删除 scoped URL
    retention；无新 caller hash/pathSource/launch capability。
  - **Same-domain cross-identity host matrix:PASS。**macOS 26.5.2(`25F84`)
    arm64/Swift 6.3.3；checked-in probe SHA-256 =
    `08135e76baff4485235dd50074a20bad3fa68e969dd6e3f012cd3af5f917909b`。
    两个 basename 均为 `arkdeck` 的 ad-hoc build：
    A Identifier `dev.arkdeck.readiness.a` / CDHash
    `94d3566dcfcd45bcf4afcb2cf4af0aea223bb16b`，B Identifier
    `dev.arkdeck.readiness.b` / CDHash
    `235f395b1d6ef047c893948bbc3709b07ed21416`。A 在 `UserDefaults.standard`
    写线程唯一非产品 key 的 1060-byte ordinary bookmark；B 以
    `[.withoutUI]` 得 `stale=false,target_match=true`。B 删除后 A/B 均复查
    `present=false`。目标只做 read-only hash且精确命中
    `038a8a0e…3611`；正式 old/new product key、tool launch 与设备均零触碰。
    本 primitive 不是产品验收；实现 run 必须按记录中 exact harness 由 product A
    `install-tool` 写正式新 key、不同 Identifier/CDHash 的 product B 经真实
    `load()` 到达下一项缺失 quarantine 门，再清理新 key，方可 done。
  - **Fault/schema/test/evidence matrix:closed。**记录逐项钉定 loader 的
    missing/wrong-type/corrupt/stale/path-mismatch/legacy-only/dual-key，installer
    的 path/symlink/hash/create/self-roundtrip/write/readback/legacy-delete，
    dual-key crash + rerun recovery，E0 scoped/production ordinary 混用拒绝，
    2.1 new-writer/historical-byte-stable/unknown 拒绝矩阵；新
    `RockchipToolBookmarkContractTests` 使用隔离 defaults suite 与 single-fault
    seams，全部负向 spawn=0。focused 七套、全量 Swift、check-sdd、path guard、
    diff-check 命令及 run record 字段均已 exact pin。
  - **Baseline/concurrency/effect gate:satisfied。**base 全量
    `CI=true swift test --package-path Packages/ArkDeckKit` =
    442 tests / 1 skipped / 0 failures；`./scripts/check-sdd.sh` =
    0 error / 0 warning / 111 acceptance IDs；
    `python3 scripts/test_check_pr_paths.py` = 49/49 PASS。
    `2026-07-28T07:49:42Z` 分页完整 open PR 集为 `[]`。本 readiness 只改本
    task status/pins/evidence 引用并新增 change-local readiness record/probe；
    `rkdeveloptool_spawn=0,real_device=0,USB=0,E1=0,E2=0,destructive=0`，
    credential/Keychain/network/product formal defaults 均零接触。
  - **Readiness verdict:READY after maintainer merge。**治理依赖、来源可达性、
    scope 内 seam、跨身份宿主机制、故障/兼容/产品 harness 与验证命令均闭合。
    只有维护者 review/merge 本 readiness exact head 后顶部 `ready` 才生效；
    implementation 必须另起 PR，且任一 pin/concurrency/scope 漂移立即停手重做 D1。
- Implementation completion(2026-07-28；完整可复查记录 =
  `evidence/runs/TASK-AIN-BKMK-001/run.md`):
  - **Base/concurrency gate:satisfied。**实现从 protected main
    `f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d` 开始，readiness 全部
    implementation blob 逐项同值；最终 product/test 树 fast-forward 到
    protected main `570fe28c2d6edbad18050cfe873246fd45f0bc40`，push 前再
    依次 rebase 到 #720 `cd3f3e0a7b4c2055746a617110e94b2e1dc791c7` 与
    #721 `54c3a3cfbc455b5eb0ab6710955ad994d5b57eac`（仅 CHG-2026-042
    与 `scripts/host_loop/**`/`scripts/test_check_pr_paths.py`）。区间全部上游文件与本任务 modified paths
    零交集，最终完整 open PR 查询为 `[]`。
  - **Route A implementation:PASS。**唯一 product installer
    `flash install-tool --path` 以 descriptor/hash prepare-only 门验证
    pinned executable，创建/自解析/readback ordinary bookmark 到新 key；
    production `load()` 只消费新键。legacy-only/dual-key/missing/wrong-type/
    corrupt/stale/non-canonical 全受控 fail closed，legacy 删除故障留下 dual
    且重跑可恢复。E0 scoped 与 production ordinary 由 closed typed policy
    分离，production scope start/stop = 0。
  - **Product cross-identity matrix:PASS。**最终 A/B 均为 basename `arkdeck`、
    使用独立 SwiftPM scratch path；A Identifier/CDHash =
    `dev.arkdeck.implementation.a` /
    `171ac1b7b0b85d0956dd3ffe2b4ba6fa08dd4dc3`，B =
    `dev.arkdeck.implementation.b` /
    `2788255be72363f3648b740520672aeb4bc0a229`。old/new/quarantine 三键
    缺席预检后，A 产品入口安装，B 真实 product `load()` 精确到达下一门
    `tool quarantine assessment is absent`；清理新键后 A/B 均回到 ordinary
    bookmark missing，最终三键全缺席。未记录 bookmark bytes/path。
  - **Persistence/migration/security matrix:PASS。**新 Manifest 2.1 writer
    只发 `installedOrdinaryBookmark`，历史 scoped bytes 稳定可读，unknown/
    path/bookmarkData 拒绝；六个新测试覆盖 installer/loader/migration/
    cross-policy single faults，全部 spawn=0。AC-FLASH-015-01/02 canonical
    三行逐字保持 dispatch=0。
  - **Verification/effect gate:PASS。**focused 七套 =
    6/7/2/3/9/60/15 tests，全部 0 failures；最终全量 = 466 tests /
    1 skipped / 0 failures；`check-sdd` = 0 error / 0 warning /
    111 acceptance IDs，#721 后 path guard = 50/50，`git diff --check` 干净。
    `rkdeveloptool_spawn=0,real_device=0,USB=0,E1=0,E2=0,destructive=0`。
    本任务不自行写 `Decision-Grade`，不触碰 verification 状态。
- Platform:macos
- Requirements:REQ-FLASH-015(MODIFIED)
- Acceptance:change-local AIN-BKMK-001(登记于 verification.md Acceptance
  matrix;AC-FLASH-015-01/02 行为不回退是其负向底线)
- Depends on:TASK-AIN-003(done,#292/#293;缺陷见其 Defect record 2)+ r2
  Route A governance merge(done,#706)+ fresh D1 readiness r2(本 PR，合入后满足)
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Tests/**`
  - 本 change `contracts/manifest.schema.v2.1-draft.json`
  - 本 change `evidence/host-prerequisites/installation-runbook.md`
  - 本 change `tasks.md`（仅本任务段的状态/pins/evidence 引用）
  - 本 change `evidence/runs/TASK-AIN-BKMK-001/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/integrations/**`
  - 本 change 其余 `contracts/**`
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashAuthorization.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipAuthorizationFacts.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/Journal*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/RetentionAndExport.swift`
  - `ArkDeckApp/**`
  - `ArkDeck.xcodeproj/**`
  - `openspec/changes/chg-2026-036-macos-bundled-rockchip-component/**`
  - `scripts/**`
- Risk:medium（宿主 locator、CLI install 与 2.1 persistence closed widening；
  零授权门语义变更、零设备 effect、凭据面零接触）
- Hardware required:no

### Deliverables

- Objective:使 pinned tool 的宿主前置(D-1 第 1 项)**不依赖创建者
  code-signing 身份**即可被产品稳定消费——跨进程且跨(签名身份不同的)构建,
  `load()` 对第 1 项的消费不再因创建者/消费者签名身份差异而失败(缺陷正本 =
  TASK-AIN-003「Defect record 2」与 runbook §2/§8 勘误注记)。r2 选择
  **Route A**：non-sandbox CLI 以 product install 入口创建 ordinary bookmark，
  后续不同 signing identity 的 build 仍可消费；E0 security-scoped 与未来
  bundled/App 路线不变。
- closed typed access policy + 新 ordinary bookmark key/installer + legacy
  fail-closed migration；不得把普通 bytes 标成 scoped；
- Manifest 2.1 new writer 发出 `installedOrdinaryBookmark`，历史
  `userSelectedSecurityScopedBookmark` 保持可读不改写；
- 跨签名身份消费的 contract/受控测试(正向)+ 既有 fail-closed 门零放宽的
  负向测试;
- `evidence/runs/TASK-AIN-BKMK-001/` run 记录(全量测试基线对比)。

### Verification

- 正向(二值):同 basename/`arkdeck` defaults domain 的 build A 经 product
  install 入口安装 ordinary bookmark 后，Identifier/CDHash 均不同的 build B
  在**产品 `load()`/Discovery 路径**消费同一已安装第 1 项前置成功；Defect
  record 2 的跨身份红行转绿，且不是 probe-only 或同身份自证（exact harness
  由 fresh readiness 钉定）;
- persistence(二值):新 2.1 Manifest 只发出 `installedOrdinaryBookmark`，历史
  2.1 scoped 值仍可读且 canonical bytes 不改写；unknown pathSource、普通/scoped
  混用与 bookmark bytes/absolute path 入 Manifest 全拒绝;
- migration(二值):legacy-only、legacy+new、new missing/wrong type/corrupt/stale/
  path mismatch、installer hash/symlink/self-roundtrip/write-readback fault 全在
  product spawn 前阻断；重跑 installer 可从 dual-key crash state 恢复;
- 负向(二值):既有 fail-closed 门零放宽——bookmark/前置缺失、stale、实体
  hash 不中等一切既有拒绝路径语义保持,AC-FLASH-015-01/02 无授权/不匹配 →
  dispatch=0 逐字保持,不新增任何 admission 放行路径;
- 零其他语义变更;Swift 全量基线零回归(不低于 TASK-AIN-003R 实现后基线
  442 tests / 1 skipped / 0 failures,#694;以届时 main 实测为准)。

### Notes / handoff

- 命名:本任务即 TASK-AIN-003 第二缺陷(bookmark identity)的 remediation;
  自然名 TASK-AIN-003R2 非合法任务 token(守卫语法要求结尾
  `-[0-9]{3}[A-Z]?`),故取本 token,实测依据见 Defect record 2 命名注记。
- 本任务 done 前:TASK-AIN-004 的 D-1 第 1 项不可闭合,runbook §7 探针恒止于
  第一站(其 r4 前置清单第 8 条);E0 面零消费 `load()`,不受本缺陷约束。
- r2 已选择 ordinary Route A；CHG-2026-036 的 bundled/signed/App 路线保持
  独立且 read-only，不是本任务 dependency，也不得借本任务提前实现其 BRC-004
  composition。
- 独立 fresh D1 readiness r2 已以上述 base/full blob OID、产品 harness 与
  fault/schema matrix 钉定；实现必须以本 readiness merge 后 main 复核全部 pin。
  若上游已修复或任一 pin/并发/scope 漂移，如实停手重做 D1，不重复或越界实现。
- Decision-Grade 行由维护者亲笔(TASK-BRC-002R 先例)。

## TASK-AIN-004 — 首次无人值守真机验收(DAYU200)

- Status:blocked（r2 security review 发现 P0-AUTH/FACT/DISPATCH/CONTRACT 缺口；#296
  readiness 作为历史保留但不得复用。等待 TASK-AIN-005/006/007 全部 done 后，以新的 main
  OID、未过期 authorization、可信执行宿主和独立 PR 重新 readiness。**r3(2026-07-27)已
  完成全部 host 可测量重钉,但三项独立阻断未闭合——D-1 产品执行宿主四项前置在本机全部
  缺席、D-2 ADR-0003/TASK-BRC-004 与本任务争同一 production composition、D-3 hdc 工具
  已漂移;见下「Readiness pins(r3)」。本任务保持 blocked,r3 不授权任何设备操作**）
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
  - 本 change `tasks.md`(仅本任务状态/pins/evidence 引用;readiness 与 done 载体所需)
- Forbidden paths:
  - `Packages/**`(实现已冻结,发现缺陷回 TASK-AIN-003)
- Risk:destructive(本 change 授权模型下由 Agent 无人值守执行;standing authorization 于本任务 readiness PR 承载,恢复路径 = CHG-2026-016 Loader wlx 重刷)
- Hardware required:yes
- Decision-Grade:D2。

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

### Readiness pins(r3 host-complete,2026-07-27)

**状态说明**:本 r3 按 r2 stop gate 的要求以新 base、新载体重新钉定全部 host 可推导
事实,**不复用 #296 readiness,也不复用 `AUTH-2026-025-DAYU200-001`**。r3 **不**使本
任务 ready,**不**授权任何 E0/E1/E2 设备操作:新载体在解析层即 fail closed,且下列
D-1/D-2/D-3 三项阻断全部未闭合。r4(翻 `ready` + 授权设备窗口)必须在三项均由维护者
判定关闭后另起独立 PR。

#### Base 与套件基线(全部本次实测)

- Base:main `6e45a224cc7d5a758fe2f5661effe3c2ae726baf`(#659 merge)。
- guard:`./scripts/check-sdd.sh` 实测 **0 error / 0 warning / 111 acceptance IDs**,
  exit 0。
- Swift 全量:`swift test`(Packages/ArkDeckKit)实测
  **Executed 400 tests, with 1 test skipped and 0 failures**,exit 0
  (AIN-007 done recheck 记的 358 为当时值,本 r3 以 400 为回归底线)。
- E0 crib host 自测:`python3 scripts/e0_readback/capture.py --selftest-host` 实测
  **PASS (15/15)**,exit 0。
- 测量方法学注记:上述 Swift 汇总行取自完整输出文件,**不经 `| tail`**——截断会吃掉
  `Executed N tests...` 汇总行而只留管道退出码(本次起草时先犯后纠,记此防复发)。

#### Provider/plan 面 pins(在 base 上重新实测,非沿用 r1 记忆值)

以 `RockchipRockUSBFlashProvider().makePlan(mode: .execute, archiveValidation: .valid)`
(默认 `planNonce` `rf002`)在 base 树实测,**与 2026-07-22 r1 值逐字相同,零漂移**:

- `planDigestSHA256`
  `c85be3b34ae671ad213781619235a22dcb242d406850d4eb8cef8785487d6cff`
- `stepSetDigestSHA256`
  `075b52c4fc7dc71e422c76c9edd5e1cd26e7641c844fa4cfb4ae79f29d1c8fdb`
- `providerIdentity` `arkdeck.rockchip-rockusb-flash-provider`
- `RockchipFlashProfile.pinnedToolchainFingerprint`
  `rkdeveloptool-1.32@038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
- `RockchipFlashProfile.targetDeviceModel` `DAYU200 (RK3568)`;`archiveSHA256`
  `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`;mapped
  partitions `9`
- 测法:base 树 linked worktree 内加一次性 `@testable` 打印用例读取上述值,读毕删除;
  仓内零残留,`Packages/**` 保持 Forbidden 未改。

#### 物料与 provenance 面 pins(本机实测)

- pinned 镜像:`~/Downloads/version-Daily_Version-OpenHarmony_7.0.0.33-20260713_000751-dayu200_img.tar.gz`
  实测 SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`
  == Profile `archiveSHA256` == 载体 `firmwareArchiveSHA256`,**命中**。
- destructive 面工具:`~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool` 实测 SHA-256
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
  == `RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256`,**命中**。
  注意 `/opt/homebrew/bin/rkdeveloptool` 与 `~/Code/OpenHarmony/rkdeveloptool/rkdeveloptool`
  实测均为 `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`
  = `pinnedReadOnlyDiscovery`(**E0 只读**面),**不得**用于 E2。
- `.github/CODEOWNERS` blob OID 实测 `f4edd22f87965efcfc27ea512283a0c2252bf0fb`
  == `MaintainerMergedAuthorizationResolver.pinnedCodeOwnersBlobOID`,**命中**;有效行
  恰 `* @lvye`,满足 `codeOwnersRequireMaintainer`。
- provenance 载体路径契约:`registryDirectory` =
  `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/authorizations`,
  `registryPath = <registryDirectory>/<authorizationId>.json`。故新载体文件名必须与
  `authorizationId` 逐字一致。
- provenance 身份契约:PR 作者须为 `github-actions[bot]`、merge 者须为 `lvye`、须有
  `lvye` 对 **exact head** 的 approve,且作者 ≠ 合并者 ≠ 批准者(`actorSeparationViolation`
  防线)。这正是 `agent/*` bot auto-PR 载体形态存在的原因。

#### D-1 阻断:产品执行宿主四项前置在本机全部缺席(实测)

`RockchipProductExecutionSettings.load()` 是 production composition root。对本机逐项
实测,**四项前置全部不满足**,故今日即便载体合法,`arkdeck` 也走不到任何 dispatch:

| 前置 | 期望 | 本机实测 | 判定 |
| --- | --- | --- | --- |
| `UserDefaults` `ArkDeck.Rockchip.ToolBookmark` | security-scoped bookmark | 全部真实域(含 `com.arkdeck.desktop`)均无该 key | **缺席** |
| `UserDefaults` `ArkDeck.Rockchip.ToolQuarantinePresent` | 键存在(值可为 false) | 缺席 → `tool quarantine assessment is absent` | **缺席** |
| Keychain `dev.arkdeck.github-provenance` / `protected-main-reader` | 非空 token | `security find-generic-password` 报 item 不存在 | **缺席** |
| `~/Library/Application Support/ArkDeck/rockchip-binding.json` | `revision > 0` + serial + 纯数字 usbTopology + 非空 evidence | 文件不存在(该目录下只有 `Characterization/`、`host-loop/`) | **缺席** |

- 可行性已单独证伪一个常见假设:**非 sandbox CLI 能创建并解析 `.withSecurityScope`
  bookmark**——本机实测 `bookmarkData(options:[.withSecurityScope])` 成功(824 B)、
  `resolvingBookmarkData` 回原路径且 `stale=false`、
  `startAccessingSecurityScopedResource()` 返回 `true`。故第 1 项属"未安装",不属
  "架构上不可能";其余三项同为安装缺口。
- **本 change 全目录零处记载这四项前置由谁、以何步骤安装**(实测 grep:
  `ToolBookmark` / `protected-main-reader` / `rockchip-binding.json` /
  `ToolQuarantinePresent` 在 chg-2026-025 目录内零命中)。这正是 r2 stop gate 所要求的
  「可信执行宿主」证据的空缺处,r4 前必须由独立载体补齐。
- **Keychain token 安装是维护者动作,不由 Agent 执行**(凭据不经 Agent 之手;
  POL-AGENT-001 同向)。
- `rockchip-binding.json` 的 `revision` 必须等于载体 `target.bindingRevision`
  (`RockchipAuthorizationFacts` 实测断言 `durable.reference.revision ==
  authorization.target.bindingRevision`),因此该 pin 只能在 durable 绑定建立后确定,
  不能由 E0 读回臆造——与 r1 结论一致,但机制已由 caller-supplied context 改为 durable
  snapshot。
- **安装载体(2026-07-28)**:四项前置的安装步骤、责任人、装后快照命令与失败/回滚
  注记已入仓 = 本 change `evidence/host-prerequisites/installation-runbook.md`
  ——r4 二值前置第 2 条所要求的「安装步骤与责任人有仓内载体」即该文件(其 §8 并如实
  记载与本表的两处出入:admission 层伴生键 `ArkDeck.Rockchip.ToolCodeTrust` 与
  composition 的 adapter profile 结构性缺口)。本条仅登记载体,不改变 D-1 blocked
  判定:四项在宿主上仍未安装,快照证据届时随 r4 独立载体入仓。

#### D-2 阻断:ADR-0003 / TASK-BRC-004 与本任务争同一 production composition

- `DEC-011` / `ADR-0003`(CHG-2026-035,已 archived;结论录于
  `openspec/platforms/macos/profile.md` §Rockchip tool execution)选定
  `selected:bundledRockchipComponent`,明文「**不使用 user-selected external
  executable**」,并写「任一 gate 未满足,Rockchip execute 保持 blocked」。
- CHG-2026-036 `TASK-BRC-004`(**status blocked**,依赖同为 blocked 的 `TASK-BRC-003`)
  的 Production reachability 链**逐字包含 `RockchipFlashExecutionHost`**,交付物明写
  「删除 production route 对 user-selected executable URL/hash/bookmark … 的输入」——
  即本任务 D-1 表格第 1 行所依赖的那条输入。
- 但本仓实测:`chg-2026-025` 全目录零处提及 ADR-0003 / DEC-011 / CHG-2026-035 /
  CHG-2026-036;`chg-2026-035` 与 `chg-2026-036` 全目录亦零处提及 CHG-2026-025 /
  TASK-AIN-004。**两侧互不可见**(与 chg-026/RKFUI-001G 被 ADR-0003 作废时同型)。
- 因此存在两种同样可辩护的读法,**其取舍是维护者的范围判断,r3 不代为裁决**:
  (a) ADR-0003 的主语是 **Sandboxed macOS App** 的 execute 面(其证据矩阵、候选集、
  entitlement/分发讨论均以 App 为主体,触发事实是 RKFUI-001G),则 chg-025 的 agent
  CLI 面不受其阻断,AIN-004 可在 D-1/D-3 关闭后走 r4;
  (b) ADR-0003 的主语是**任何 product-owned typed workflow 的 Rockchip execute**
  (其原文即用此措辞,而 AIN-007 的执行宿主正是 product-owned typed workflow),则
  AIN-004 的 E2 面须待 BRC-003/004 闭合后方可 readiness。
- **r4 起草前必须先有维护者对 (a)/(b) 的书面裁决**;若判 (b),AIN-004 的 E2 面保持
  blocked,E0 面是否单独放行亦由该裁决界定。

#### D-3 阻断:hdc 工具已漂移,E0 读回的工具身份需重钉

- AIN-004 既有 evidence 与既往采集计划引用 hdc `3.2.0d`
  `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`。
- 本机实测两条路径
  (`/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc`
  与 `~/OpenHarmony/SDK/26.0.0/toolchains/hdc`)**同字节**,均为
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`,与旧 pin 不符。
- 版本号须由**维护者执行 `hdc -v`** 确认后写入(静态 `strings` 提取会得到 handshake
  协议常量而非报告版本,该错法已有先例);Agent 不得调用 installed HDC。
- E0 crib 本身不 pin hdc hash(只把实测值写进 receipt 的 `toolchain.hdcSha256`),故
  crib 不会因漂移而失败——**这正是需要在 r4 显式重钉的原因**:不重钉就没有任何一道门
  会因换工具而变红。

#### 守卫可解析性(本 r3 顺带修复的活缺陷)

- 实测:`check_pr_paths.extract_allowed_patterns` 对 `TASK-AIN-004` 抛
  `task TASK-AIN-004 has multiple Allowed paths lines`——本任务此前有两条
  `- Allowed paths` 声明行(顶部活声明 + 历史 r1 pins 块内一条)。**其后果是任何声明
  `TASK-AIN-004` 的 PR 一律红**,与文件集无关。
- 全仓横扫 42 个 active 任务:该 `multiple` 形态**仅 TASK-AIN-004 一例**;另有三例属
  另一形态 `no Allowed paths line`(`TASK-OBS-001`/`TASK-OBS-002`/
  `TASK-UD-R2-R4-SEAM-001`),不在本任务范围,单独记录待办。
- 本 r3 把历史块那条改写为散文行(历史事实一字不改),使全任务只剩一条活声明;并把
  `本 change tasks.md` 补进活声明,以便后续 readiness/done 载体可合法声明本任务。
- 载体形态因此被实测定死:本 r3 只动 `openspec/**`,**标题不含 `TASK-` token**(无任务
  声明 → 落 SENSITIVE 判定 → `openspec/**` 非敏感 → 通过);`scripts/e0_readback/**`
  属敏感面,必须由**另一个声明 `TASK-AIN-004` 的 PR** 承载,且只能在本 r3 合入后提交。

#### r4 的二值前置(全部为"必须成立",任一不成立即不得 r4)

1. 维护者对 D-2 的 (a)/(b) 裁决落成书面载体(profile/ADR/change 任一,须可引用);
2. D-1 四项前置在目标宿主上逐项可证(bookmark/quarantine/keychain/binding 快照),
   且其安装步骤与责任人有仓内载体;
3. `rockchip-binding.json` 的 `revision` 已确定,并与新载体 `target.bindingRevision`
   逐字相等;
4. hdc 身份与版本经维护者 `hdc -v` 确认并重钉;
5. 届时以**当时的 main OID** 重跑 guard / Swift 全量 / crib 自测,三者均不低于本 r3
   基线(0/0/111、400 tests 0 failures、15/15);
6. 新载体 `AUTH-2026-025-DAYU200-002.json` 经 `github-actions[bot]` 作者、`lvye` 对
   exact head approve 并 merge,`carrier` 字段由 PENDING 改为该 PR 引用。
7. (2026-07-28 增补)TASK-AIN-003R done:#676 runbook §8 第 3 条实测发现
   production composition 把 `pinnedProduction`(`038a8a0e…`)tool 交给缺省
   adapter(钉 `bbd7bdc0…`),声明性 hash 门恒不等,E2 admission 结构性 fail
   closed(缺陷正本与行级证据 = TASK-AIN-003「Defect record」)。本条仅约束
   E2 面:E2 执行前 TASK-AIN-003R 必须 done;仅含 E0 面的 r4 不被本条阻断——
   E0 不经该 composition(runbook §8 边界记录),agent CLI 面适用性已由
   DEC-012 判 (a) 界定(#670)。
8. (2026-07-28 增补)TASK-AIN-BKMK-001 done:维护者按 runbook §2/§7 实际执行
   D-1 安装时,`arkdeck flash execute` 探针于第一站裸报
   `NSCocoaErrorDomain Code=259`;受控矩阵钉死 `.withSecurityScope` bookmark
   的 resolve 绑定创建者 code-signing 身份(ad-hoc = Identifier+CDHash
   粒度),runbook §2 helper 途径对产品永不可行,产品又无 bookmark 安装
   入口——D-1 第 1 项(tool bookmark)的可消费性以 TASK-AIN-BKMK-001 done 为
   前置,其 done 前第 2 条的第 1 项快照不可能取得(缺陷正本与矩阵 =
   TASK-AIN-003「Defect record 2」;runbook §2/§8 dated 勘误注记)。本条仅
   约束 E2 面:`RockchipProductExecutionSettings.load()` 为 E2 execute 面
   专用消费——实测唯一调用链 = `arkdeck flash execute --authorization-id`
   (`ArkDeckCLIMain.swift`:116)→ host init → production composition →
   `load()`,Sources 全树零其他引用;E0 面(`scripts/e0_readback/` crib、
   TR-001 harness)零消费——仅含 E0 面的 r4 不被本条阻断(与第 7 条同界)。

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
- 历史授权面(r2 及执行期,superseded):`evidence/**`(载体、authorizations、runs)+
  `hardware-matrix.md` 新增行;`Packages/**` forbidden(实现已冻结,缺陷回 AIN-003)。
  (本行原为第二条 `- Allowed paths` 声明行,与本任务顶部的活声明重复,使
  `extract_allowed_patterns` 对 TASK-AIN-004 恒抛
  `has multiple Allowed paths lines` — 见 r3 pins「守卫可解析性」。改写为散文后,
  全任务只剩顶部一条活声明;本节其余文字不变,历史事实不改写。)
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

- Status:done
- Done:2026-07-22；实现经 #326 合入 main（merge commit
  `fac1a128903fb17b9aa98273e831eb60be9542bf`；PR head
  `2c03c5990bdbd948ca9d658a08f58e53fbcb128b`；维护者 `lvye` merge）；done recheck
  于最新 main `42cc63123738313d253b25c9de78220e1e6814b5` 复验：焦点 12/0 failures、
  Swift 全量 358/1 skipped/0 failures、`TEST-AIN-DISPATCH-001` canonical 摘要 PASS、
  guard 0/0/111；PR head 到 merge commit、merge commit 到最新 main 在 TASK-AIN-007
  实现范围内 tree diff 均为 0；contractFake/host-only，device/HDC/real rkdeveloptool/network/
  shell/destructive dispatch = 0；evidence =
  `evidence/runs/TASK-AIN-007/2026-07-22-rockchip-executor-implementation.md`
- Platform:macos
- Requirements:REQ-FLASH-008/009/011/012/013/015、POL-WORKFLOW-001、
  POL-RECOVERY-001
- Acceptance:AIN-DISPATCH-001；AC-FLASH-008-01、012-01、013-01、015-03 contract 面
- Depends on:TASK-AIN-005、TASK-AIN-006、TASK-AIN-008
- Readiness reviewed:2026-07-22；base = protected `main`
  `2c2d0d523cb62ecb8c71ed4877b11f7279cef568`（#313 merge，AIN-008 done），审计时
  open PR = 0。TASK-AIN-005/006 已 done；TASK-AIN-008 实现 #312（head
  `ea81120218b004ff9a3193fd7fa24a933a9d4bea`，merge
  `de988f19cf9d1200523370c797ed5f70718eda11`）与 done #313（head
  `c5048baaf2e0cf88a5e30f9e9a6ad202ffedaa54`，merge = 本 base）均已合入，两个
  reviewed head 到各自 merge commit 的 tree diff 均为 0。设计 §13 的 Manifest toolchain
  与 admission executable identity retention 缺口已由 AIN-008 的 exact `2.1.0` contract
  关闭；依赖、文件面、composition、fake-only 验证路径与 current APIs 已重新审计。
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
  - provenance/admission/facts/gate：`AuthorizationProvenance.swift`
    `3f6c18fcece43b5754ec9e4ea4a2149481c1b228`、`AuthorizationAdmission.swift`
    `69fec8990c7cb68c989460ee883bbe358900cc96`、`RockchipAuthorizationFacts.swift`
    `971fe98feb9c9f5debf4abef948420383570f8ef`、`RockchipFlashAuthorization.swift`
    `a3fb1711271d32119db861a351ce2f2aa70c94fd`；
  - Provider/profile/archive/discovery：`RockchipRockUSBFlashProvider.swift`
    `8a30eb828773260d8b02b854d03a63ecf2da124f`、`RockchipFlashProfile.swift`
    `de82a3a008b95ef63148f7c9e4374298e6671328`、`GzipTarArchiveReader.swift`
    `36daf0eea9279790258d1ffaa1d87365cd1489d1`、`RockchipDeviceDiscovery.swift`
    `67f585324d002f80c2682a1bdaa9ae7d11ed035a`、Rockchip integration profile 目录 tree
    `d4c5b3724506013a06a8a5d928e7856a778c6733`（其中 `registry.yaml`
    `f7fa0945f70730bca601f81955a3faea411a19f3`）；
  - process/runtime/storage：`ArkDeckProcess.swift`
    `b1d5f423c004f4ba15b15a8cf862ed2085d8bcc9`、`PowerActivity.swift`
    `9d887070a21eac8140cfca236bbde29492d007a5`、`SleepWake.swift`
    `1fb6972c5690dea6c6cc9465eb83a2edc21c1215`、`ArtifactStorage.swift`
    `635f4da53094305dc52dff6ebdb26e1ccb026ea1`、`AuthorizationUsageLedger.swift`
    `d87d93caf9fba52e34bdfbaa9a5eb6e16c7cc1b9`、`DurableFiles.swift`
    `039fbb891fdc78c3cf19acc47b3f1231b9dde5c0`、`JournalEvent.swift`
    `48103ee11ac7dd343518718df66a65ad987eddb6`、`JournalEventValidation.swift`
    `a038703f88cff61ad5ed23c8dbc02bf6bf79db72`、`JournalReplay.swift`
    `9ea0b4aea122937cc206922a32b13170859e092c`、`SessionManifest.swift`
    `2e168e49abad60e165cec6e49df41d429c5d9ff0`、`SessionLayout.swift`
    `ed48f90a96ee239769e86727ae9272017fea72f7`、`RetentionAndExport.swift`
    `ed53dcd3e911bc8ff968b7f1e22f51cefe5a0d94`、`DeviceBindingJournalAdapter.swift`
    `b07a8c7a8b5d45e335b2ec5dc04dd18cba48dde4`；对应 Process/Runtime/Storage
    source tree 分别 pin `9f039fc495d7334fe2c7173376b322db9cc10f63`、
    `852adaa7cc5aa17dc08eeda7197cab49634293bf`、
    `33dfb05f71e0a4cfc0980178c774992798178ea0`；
  - locked deltas/contracts：provider v2
    `3413edf56811ac30bef833f324cbdf59cff9ce52`、historical journal v2
    `6285acd4ca0350d427aa624afa91be3107769a64`、historical manifest v2
    `9ac334013968a5aba1a0bd77fe2acc982ba0e680`、exact journal 2.1
    `ef71f22c45a7bc06bcde35b0606e94fb6bb79037`、exact manifest 2.1
    `02c7f27a9d65cbbca6e8fe23535ae8e62e398e7c`、usage v1
    `b232db49d2d76fc2eb96fed6b7d0230455d99345`；AIN-008 regression tests
    `AuthorizationAdmissionContractTests.swift`
    `b8cc11c91248437c13b8ce7214759e9bd750243e` 与
    `SessionArtifactStorageContractTests.swift`
    `68904a3f9ac87d70c31547c3242af86c232807a1`。
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
- 顺序固定为 admission(grant→facts→usage reservation)→2.1 `authorizedAgent` jobCreated→gate
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
- 所有 external-effect Step 先 durable intent 后 launch；2.1 jobCreated 与每个 destructive
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
  hash 对应 Profile；2.1 job/intent/outcome/Manifest correlation 全 PASS；handoff/shell/sudo/
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
- fake/production boundary：production initializer 只接受 actual pinned profile/hash/bookmark 与
  descriptor receipt；测试注入仅存在于 package-internal initializer，fixture/port 结果必须显式
  标为 contract/fake，不能生成 realHardware evidence 或 support 声明。2.1 persistence payload
  仍使用 closed production shape；synthetic receipt 只证明相关性规则，不冒充实际生产 tool
  identity，Foundation descriptor/hash/replace 行为由真实 fixture fault tests 单独覆盖。
- readiness baseline（上述 base 实测）：macOS 26.5.2 (25F84)、Xcode 26.6 (17F113)、Swift
  6.3.3；Swift 全量 **346 tests / 1 skipped / 0 failures**，guard **0 errors / 0 warnings /
  111 acceptance IDs**。实现 PR 须运行新增两组焦点测试、现行 Provider/authorization/
  process/runtime/storage/journal 回归与全量 Swift，strict format/diff/scope/privacy/no-live-
  dispatch 审计，并在 `evidence/runs/TASK-AIN-007/` 记录命令、结果、偏差与残余风险；任务
  completion/change verified 仍使用后续独立 PR。

## TASK-AIN-009 — Agent operation 与 human blocker contract freeze

- Status:done（2026-07-28 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效；本翻转不构成 change verified 或 TASK-AIN-010 readiness）
- Done:2026-07-28；实现经 #739 exact head
  `2ae3e741726c23a9d4388ec6d4a0ce2df0cdbba1` 由 `lvye` APPROVED 并合入
  main（merge commit `1b886869a40b730584330b97d8af7ffa54e99415`）；done recheck
  于最新 main `b314d6dd586744480e7a66c2fa71c4d51199ab40` 复验：stdlib validator
  `requests=3/results=4/operations=15/profiles=21/human_blockers=8/negatives=49/
  duplicates=2/core_steps=41` PASS，Swift 聚焦 4 tests / 0 failures，guard
  0 error / 0 warning / 111 acceptance IDs，process/device/HDC/network dispatch
  均为 0；evidence = `evidence/runs/TASK-AIN-009/run.md`
- Historical Status:blocked（r3 proposal revision 尚未合入；该前置已由 #730 exact
  head `1063d693d12e8fc912da7345472e5b29a4b587d8` 的维护者 APPROVED + merge
  `1178c9f351285849499f374cc5712896372600b7` 关闭。#730 只批准 scope/顺序，
  不构成本任务 readiness 或后继实现授权）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009、REQ-DUMP-009、REQ-TRACE-010、
  REQ-DEBUG-008
- Acceptance:AC-WF-003-01/02/03、AC-DEV-009-01、AC-DUMP-009-01、
  AC-TRACE-010-01、AC-DEBUG-008-01/02/03/04
- Depends on:none
- Applicable failure patterns:AF-004、AF-009、AF-014、AF-016
- Production reachability:not applicable（change-local contract/validator，零外部 effect）
- Trusted fact sources:受保护 main 上已批准 r3 delta、current workflow step registry 与
  schema；测试 caller 不能构造 accepted contract version/effect mapping
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-device-operation.schema.v1-draft.json`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/human-action-required.schema.v1-draft.json`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-device-operation-registry.schema.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-device-operation-registry.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceOperationContractTests.swift`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`（仅本任务 status/readiness pins/evidence 引用）
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/ArkDeckKit/Sources/**`
  - `ArkDeckApp/**`
- Risk:low
- Hardware required:no
- Decision-Grade:D1

### Readiness pins(r1,2026-07-28)

- **Approval/dependency gate:satisfied。**r3 proposal #730 的 author =
  `app/github-actions`、base = `main`、reviewer/merger = CODEOWNER `lvye`；
  APPROVED review 精确绑定 head
  `1063d693d12e8fc912da7345472e5b29a4b587d8`，protected-main merge =
  `1178c9f351285849499f374cc5712896372600b7`。readiness carrier #733 的 exact
  head `8f28d65b88d39193f07d2d3bcbef9d3e25d629bd` 亦由 `lvye` APPROVED + merge，
  protected-main merge = `80ce41e2eea89b1746cfb49fa6cdda1033a5bc8e`。本任务
  `Depends on:none`，但 change-level r3 approval 与 carrier 均为开工前置，现已满足；
  本 readiness 审计 base 为 `80ce41e2eea89b1746cfb49fa6cdda1033a5bc8e`。
  期间合入的 #731/#734 仅改 `chg-2026-022-hdc-supervisor-observability/**`，
  与本任务输入零交集；提交前复查 GitHub open PR = 0。
- **Objective/effect gate:fixed。**本任务只冻结 request/result、human blocker 与
  operation/profile mapping 的 machine contract，并用 host-only validator/test 证明二值
  行为。实现不能 import/call `ArkDeckProcess`、`ArkDeckOpenHarmony`、
  `ArkDeckWorkflows` 的 dispatch seam，不能创建 Job/Session/device binding、不能启动
  child process 或访问 HDC/device/network；fixture、schema accept 与 semantic PASS
  只算 `contract` evidence。
- **Draft input pins（完整 Git blob OID + SHA-256；实现开工逐项复核，任一漂移即停回
  readiness）：**

  | File | Git blob OID | File SHA-256 |
  | --- | --- | --- |
  | `contracts/agent-device-operation.schema.v1-draft.json` | `1e76c4a334a0fe0155cb1deb5bc269bd07e69599` | `7773d05d9942e6c214dec4a43810ba9c6b785d5cf16b2d37163562ca7e5b654c` |
  | `contracts/human-action-required.schema.v1-draft.json` | `cea4402b5c0fcabc143294d9aa1e0f3822fc550a` | `60b23fa197d18840efb95b2b47151f048f0c74601f1eaab5647cbca0b478305c` |
  | `design.md` | `bde7c336550bfd9074abf25c2510a1adc5710f1e` | `6501773077d081e294a658b7756e418f52477ef7aac790ce93598ef0ac8e2f95` |
  | `manual-boundary-inventory.md` | `67468b5304704ec62f3a61b5ed247bb2a6190d97` | `07e5cfd4c82d8f89e8e0e7136d6f76364f6bba65cdbcc7225928c4a57920a2af` |

- **Approved delta pins（只读）：**`specs/debug-workbench/spec.md`
  `9b123e8c26a7bee95f702e514f61ea52013d30c1`、
  `specs/device-targeting-auth/spec.md`
  `41fafddb2e8a1233d3bd8ea6517f902fe40bee05`、`specs/trace/spec.md`
  `c7815880d64e4fee6fc67a86a3684c27bd4f8994`、`specs/ui-dump/spec.md`
  `923e3bdc369a3770a8abe96b657452065971bd56`、
  `specs/workflow-journal-recovery/spec.md`
  `a3df2d253b6882538a8e649bc11876a0032270e3`。实现不得修改这些 delta 或
  accepted current specs 来迁就 schema/test。
- **Current Core input pins（只读，漂移即重做 mapping 审计）：**
  `openspec/contracts/workflow-step.schema.json`
  `c510d96478f3192168478b1a1669b5fcd2a848f7`、
  `workflow-step-registry.yaml`
  `d9121ef78531560ab856dfa07468ce1ab4d42df6`（41 个 closed kind）、
  `provider-contracts.md`
  `ceb6709fb405fc46d72ef2126b715e252ac720ab`、
  `journal-event.schema.json`
  `d25b7a55e9970d301558430febd235ccc910d8b7`、
  `WorkflowStep.swift`
  `d96423593978f84a0db7623a1b94863e5d12de26`、
  `JobStateMachine.swift`
  `c7350e2f74fcbb52a6e582c09c063c5dda0f13f6`、
  `StrictJSON.swift`
  `d5df2a82ced6b8a06635c1e9f1887d70c693f005`。其中 Core minimum effect、
  cancellation、binding 与 18 个 JobState 只可被新 contract 原样引用或加强，不能
  降低、重命名或在 test-local model 中另造事实。
- **Version/identity gate:fixed。**定稿文件名保留 `-draft` 直到 archive，但 `$id`
  精确固定为
  `https://arkdeck.dev/schemas/agent-device-operation-1.0.0.json`、
  `https://arkdeck.dev/schemas/human-action-required-1.0.0.json` 与
  `https://arkdeck.dev/schemas/agent-device-operation-registry-1.0.0.json`，
  `schemaVersion` 均为 `1.0.0`，Draft 2020-12，所有 object
  `additionalProperties:false`。旧/未知 version、duplicate member、未知字段与跨
  document 字段混入全部 reject；archive 前不得写入 `openspec/contracts/**`。
- **Request gate:fixed。**request 只允许
  `documentType/schemaVersion/requestId/changeId/taskId/executionMode/durableTargetId/
  operation/authorizationId/requestedOutputs/deadlineUtc`；`operation` 只含
  `id/profileId/configurationId/configurationSha256/artifactLeaseIds`。以下 caller
  字段在任意大小写/嵌套形态均不产生事实并须 reject：
  `submittedBy/executor/executable/argv/shell/command/remotePath/sessionRoot/
  authorizationBytes/authorizationPath/authorizationRef/capability/bindingRevision/
  readback/prerequisites/usage/effect/resolvedEffect/outcome/success`。request 中的
  `authorizationId` 只是 E2 lookup key，不是 authority；profile/configuration digest
  只是 intent pin，不是 accepted registry 事实。
- **Result gate:fixed。**result 是 trusted host 输出而非 request 回显：用
  `jobState` 精确承载 current Core 18-state enum，用 closed `disposition`
  区分 `active|humanActionRequired|policyBlocked|terminal`，并携带
  `resolvedEffect/outcomeCertainty/executor/artifacts`。`executor.kind=agent` 与任何
  `authorizationRef` 只能由 host mint；request 同名字段永远非法。human disposition
  必须同时引用同 Job 的 `humanActionId` 与 `blockerCode`；非 human disposition
  不得夹带该引用。terminal/active disposition、JobState 与 certainty 必须相容，
  `policyBlocked` 不是伪造的 JobState。
- **Authorization-reference gate:fixed。**result 的 `authorizationRef` 是 closed
  discriminated union：E0 `readyTask` 固定
  `changeId/taskId/mainCommitOID/taskBlobOID/approvalPRNumber`；E1
  `deviceCapability` 固定
  `capabilityId/mainCommitOID/capabilityBlobOID/approvalPRNumber`；E2
  `standingAuthorization` 固定并复用 r2 的
  `authorizationId/mainCommitOID/authorizationBlobOID/approvalPRNumber`。全部 OID
  为 40 位小写 full SHA-1、PR number 为正整数，kind 与 resolved effect 必须逐项
  匹配。只有已准入 `execute` result 可携带该 ref；`planOnly/simulated`、未知/拒绝的
  lookup 与 `policyBlocked` 不能借 ref 宣称 authority。
- **Operation/profile registry gate:fixed。**新增 schema + registry 实例，恰好覆盖
  request schema 的 15 个 operation ID，零重复/零遗漏。每个 row 固定
  `minimumEffect/permittedEffects/minimumCancellation/bindingRequirement/
  permittedStepKinds/profilePolicy/escalationPolicy`；profile 必须是受保护 main 上
  registered、exact ID + configuration digest 的 closed descriptor，其 emitted Step
  只能取 row allowlist 与上述 41-kind Core registry 交集。resolved effect/cancellation/
  binding = operation floor、profile 声明与全部 emitted Core Step minimum 的逐维最大值；
  profile 只能加强，不能降低。未知 operation/profile/Step 或 mapping 不完整按
  destructive/unsupported reject，不能先建 effect intent 再补判。
- **Operation effect closure:fixed。**

  | Operation | Effect floor / allowed elevation | Minimum cancellation | Binding | Authority |
  | --- | --- | --- | --- | --- |
  | `observeDevice` | `readOnly` only | `immediate` | `confirmedDevice` | E0 ready-task ref |
  | `captureHilog` | `readOnly` → `deviceMutation` → `destructive`（clear/resize/device persist 逐 profile 提升） | actual Step max | `confirmedDevice` | E0/E1/E2 |
  | `captureUIDump` | `readOnly` → `deviceMutation` | actual Step max | `confirmedDevice` | E0/E1 |
  | `captureTrace` | `readOnly` → `deviceMutation` | actual Step max | `confirmedDevice` | E0/E1 |
  | `installHAP` | `deviceMutation` → `destructive`（data loss/downgrade 等） | `atSafeBoundary` | `confirmedDevice` | E1/E2 |
  | `uninstallHAP` | `destructive` only | `atSafeBoundary` | `confirmedDevice` | E2 |
  | `deployNativeLibrary` | `deviceMutation` → `destructive`（system/vendor/root/remount/no rollback 等） | `atSafeBoundary` | `confirmedDevice` | E1/E2 |
  | `startApplication` / `stopApplication` | `deviceMutation` only | `atSafeBoundary` | `confirmedDevice` | E1 |
  | `sendOwnedFile` | `deviceMutation` only | `atSafeBoundary` | `confirmedDevice` | E1 |
  | `receiveOwnedFile` | `readOnly` only | `immediate` | `confirmedDevice` | E0 |
  | `createPortForward` / `removePortForward` | `deviceMutation` only | `atSafeBoundary` | `confirmedDevice` | E1 |
  | `rebootDevice` | `deviceMutation` only | `atSafeBoundary` | `confirmedDevice` | E1 |
  | `flash` | `destructive` only | `criticalNonInterruptible` | `confirmedDevice` | E2 |

  E0 ref 指向 protected-main ready task/execution policy，E1 ref 指向 accepted
  per-device typed capability，E2 ref 指向 standing authorization；三者均由 host
  解引用。profile 混入更高 effect Step 必须按表提升；表不允许的 elevation 直接拒绝，
  不得拆名或靠 operation label 降级。
- **Human-boundary gate:fixed。**category 精确为
  `physicalConnection/deviceTrustPrompt/osPermission/credentialProvisioning/
  ambiguousIdentity/impactApproval/outcomeUnknownDecision/governanceApproval`，
  `prohibitedAutomation` 精确取现有九项 closed enum。v1
  `resumeProbeOperationId` 是 blocker registry 的 closed read-only probe ID，不是可由
  request 选择的 device operation：物理连接/设备 trust/歧义 identity →
  `observeDevice`，OS permission/credential →
  `probeHostConfiguration`，impact approval → `probeImpactApproval`，
  outcome unknown → `reconcileOutcome`，governance →
  `probeGovernanceApproval`；category/probe 组合漂移即 reject。`minimumActionKey` 是
  本地化 key，不能承载命令/argv/path/secret；human record 的
  `actionId/jobId/stepId` 与 result 引用须一致。只有对应 fresh probe 可转
  `resolvedByFreshProbe`，聊天文本、按钮、elapsed time 或 caller result 不能关闭
  blocker、建 binding 或提升 authority。
- **Vector/semantic gate:fixed。**正例至少覆盖 E0/E1/E2 request+result、15-operation
  registry closure 与八类 human blocker；负例逐字段覆盖 Request gate 的全部禁入面，
  并覆盖 duplicate/unknown version、unknown/duplicate/missing operation、unknown
  profile/Step、effect/cancellation/binding 降级、非法 elevation、result disposition/
  JobState/certainty 漂移、human category/prohibited action/resume probe/cross-reference
  漂移。每个反例只改变一个事实，validator 输出稳定 reason code。
- **Validator/tool gate:fixed。**实现 PR 在
  `AgentDeviceOperationContractTests.swift` 以只读方式加载 change-local bytes，
  复用 `StrictJSON` duplicate gate、Core `WorkflowStepRegistry` 与 `JobState` 做
  semantic closure；不得在 test 中复制一份可漂移的 41-kind minimum table。evidence
  路径可加入 stdlib-only Python closed-schema validator 与 JSON cases 作为独立
  Draft-shape 复验；当前 `/usr/bin/python3` 无 `jsonschema`，因此第三方包、联网、
  `pip`/`pipx` 不得成为 gate。测试/脚本都不得 spawn process 或接触设备。
- **New-file/collision gate:satisfied。**两份 registry 文件、Swift test 与
  `evidence/runs/TASK-AIN-009/` 于 audit base 均不存在；`Package.swift`
  `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 保持 invariant，SwiftPM 自动发现新
  test。若精确 Allowed paths 不足以闭环，须停回 blocked 并先做 scope amendment，
  不能扩到 Sources、Package.swift、current contracts/specs、App 或 scripts。
- **Baseline/review gate:satisfied。**macOS 26.6 (25G72)、Xcode 26.6
  (17F113)、Apple Swift 6.3.3；`CI=true swift test --package-path
  Packages/ArkDeckKit` = **466 tests / 1 skipped / 0 failures**，
  `./scripts/check-sdd.sh` = **0 errors / 0 warnings / 111 acceptance IDs**。实现 PR
  必须复跑新增焦点矩阵、full Swift、guard、strict diff/scope/no-dispatch 审计，并在
  TASK-AIN-009 run evidence 记录 exact base/head、schema/registry SHA-256、canonical
  PASS 行、偏差与残余风险；implementation、`ready→done` 与 TASK-AIN-010 readiness
  各自独立 PR，D1 合入前零投机实现。

### Deliverables

- 定稿 `agent-device-operation` 与 `human-action-required` 1.0.0 draft；
- change-local operation/profile → typed step/effect/cancellation/binding mapping，明确 E0/E1/E2
  及 `.so` deployment 的提升规则；
- 正反 JSON Schema vectors：禁止 executable/argv/shell/path/facts/outcome/effect override，
  strict unknown-field rejection 与跨 contract 引用。

### Verification

- 所有正例 schema/semantic validator accept；每个禁止字段、未知 operation、effect 降级、
  blocker category 漂移反例 reject；
- contract test 只读 change-local bytes，process/device/HDC dispatch=0。

### Notes / handoff

- completion 后在 `evidence/runs/TASK-AIN-009/` 记录 schema/version/hash 与测试输出。

## TASK-AIN-009R — E1 capability 与 execution-authority persistence contract freeze

- Status:done（2026-07-28 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效；本翻转不构成 change verified、E1 capability evidence
  接受、TASK-AIN-010 readiness 或 device dispatch authority）
- Done:2026-07-28；实现经 #750 exact head
  `fdfe74a1aa5f1be4ea4174013e0b34073bc208bf` 由 `lvye` APPROVED 并合入
  protected main（merge commit
  `ec1cf659618edf96bdbfdc09a4a8182276bd3c58`）。在该 fresh main 上复验：
  stdlib validator 与 Swift 聚焦 6 tests / 0 failures 均报告
  `e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3
  process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0`，guard 为
  0 errors / 0 warnings / 111 acceptance IDs；实现 PR 的 Agent PR
  open-pr/allowed-paths、SDD Guard 与 Swift CI 均为 SUCCESS，task-local TODO 为 0，
  十个实现/fixture blob 与 run 记录固定值逐字一致。evidence =
  `evidence/runs/TASK-AIN-009R/run.md`
- Historical Status:blocked（r4 scope proposal 尚未合入；该前置已由 #744 exact head
  `bf52c236b831f31a844167f1998d7121b46a91ac` 的维护者 APPROVED + merge
  `ef33f8f5f4307aebeb7f1fe592459f6787998e48` 关闭。#744 只批准本任务 scope，
  不构成本 readiness）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009、REQ-JOB-002、REQ-JOB-006
- Acceptance:AC-WF-003-02、AC-DEV-009-01、AC-JOB-002-01、AC-JOB-006-01、
  AIN-CAP-CONTRACT-001(change-local,r4)
- Depends on:TASK-AIN-009
- Applicable failure patterns:AF-002、AF-003、AF-004、AF-014
- Production reachability:not applicable（change-local contract/vector；零外部 effect）
- Trusted fact sources:受保护 main/GitHub exact-head review metadata、AIN-009 operation
  registry、current durable binding/Journal/Manifest contracts；fixture caller 不产生
  capability、approval、usage 或 readback 事实
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-device-capability.schema.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-execution-authority.schema.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/agent-authority-usage.schema.v1-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/journal-event.schema.v2.2-draft.json`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/contracts/manifest.schema.v2.2-draft.json`（new）
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceCapabilityContractTests.swift`（new）
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-009R/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`（仅本任务
    status/readiness pins/evidence 引用）
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/ArkDeckKit/Sources/**`
  - `ArkDeckApp/**`
  - `evidence/capabilities/**`、`evidence/authorizations/**` 与任何真实 capability/
    authorization 实例
- Risk:high（Safety authority contract；host-only）
- Hardware required:no
- Decision-Grade:D1

### Readiness pins(r1,2026-07-28)

- **Approval/dependency/base gate:satisfied。**r4 scope PR #744 由
  `github-actions[bot]` 创建，CODEOWNER `lvye` 的 APPROVED review 精确绑定 head
  `bf52c236b831f31a844167f1998d7121b46a91ac`，protected-main merge =
  `ef33f8f5f4307aebeb7f1fe592459f6787998e48`；本 readiness 审计 base 即该 merge。
  TASK-AIN-009 implementation #739 merge
  `1b886869a40b730584330b97d8af7ffa54e99415` 与 done #741 merge
  `e5a4267a062f97d50e0583ff7df1551e27420863` 均为 base 祖先，故 Depends on
  TASK-AIN-009 已满足。当前 open PR #745 只修改 CHG-2026-044 `tasks.md`，与本任务
  全部输入/输出路径零重叠。
- **Objective/effect gate:fixed。**本任务只冻结五份 change-local draft 与一个
  read-only Swift contract test；不实现 resolver/admission/ledger/Journal writer，不创建
  Job/Session/binding，不读取或写入 capability/authorization 实例，不启动 child process、
  HDC/device/network。全部 evidence 分类为 `contract`，process/HDC/device/mutation/
  destructive/network dispatch 均须为 0。
- **Schema identity gate:fixed。**五个文件均使用 JSON Schema Draft 2020-12，
  filename 保留 `-draft` 直到 archive；精确 `$id` / document version 为：
  - capability:
    `https://arkdeck.dev/schemas/agent-device-capability-1.0.0.json` /
    `schemaVersion=1.0.0` / `documentType=agentDeviceCapability`；
  - execution authority:
    `https://arkdeck.dev/schemas/agent-execution-authority-1.0.0.json`
    （inline union，无 caller 可写 document wrapper）；
  - E1 usage:
    `https://arkdeck.dev/schemas/agent-authority-usage-1.0.0.json` /
    `schemaVersion=1.0.0` / `documentType=agentAuthorityUsage`；
  - Journal:
    `https://arkdeck.dev/schemas/journal-event-2.2.0-draft.json` /
    `schemaVersion=2.2.0`；
  - Manifest:
    `https://arkdeck.dev/schemas/session-manifest-2.2.0-draft.json` /
    `schemaVersion=2.2.0`。
  所有 object（含 inline/conditional branch）`additionalProperties:false`；duplicate
  member（含 Unicode escaped 同名）、unknown/missing member、未知 version/kind 与非规范
  OID/SHA/timestamp 在 semantic correlation 前拒绝。schema 只使用仓内相对 ref 或已固定
  `$id`，不得联网解析 `$ref`。
- **Capability carrier top-level gate:fixed。**root required keys 精确为
  `documentType/schemaVersion/capabilityId/changeId/taskId/evidenceRefs/target/tool/
  operationScopes/limits/privilegeRequirements/prohibitedAdjacency/validUntil`；
  `capabilityId` 精确匹配 `^CAP-E1-[A-Z0-9]+(?:-[A-Z0-9]+)*$`，其余 identifier 复用
  AIN-009 closed syntax；`evidenceRefs` 非空、unique、最多 32 项，只是审计链接，不能
  单独产生 authority。carrier 不含 `approvedBy/carrier/path/argv/readback/usage/outcome`
  或 raw serial/connectKey。
- **Target/tool pin gate:fixed。**`target` 精确包含
  `durableTargetId/model/stableIdentitySHA256/originalTargetSHA256/
  acceptedBindingRevision/transport/firmwareBuild/firmwareFingerprintSHA256/
  allowedDeviceModes`；transport 仅 `usb|tcp|uart`，modes 仅
  `normal|recovery|updater` 的非空 unique 子集，所有 digest 为 64 位小写 SHA-256。
  runtime binding 必须 target ID/transport/stable identity/firmware 全匹配，revision
  不小于 accepted revision，且中间 rebind chain 全部 durable、无 ambiguous/rejected gap；
  TCP/UART 仍按 Core fresh 人工 reconfirm，capability 不降低门槛。`tool` 精确为
  `kind=hdc/profileId/reportedVersion/executableSHA256`；路径、bookmark、descriptor、
  caller PATH 或“版本相似”均不是 pin，执行前仍须 product-owned descriptor/hash probe。
- **E1 operation/profile closure:fixed。**`operationScopes` 非空、unique、最多 11 项；
  每项精确含
  `operationId/profileId/configurationId/configurationSha256/effect/dataImpact/
  namespace/recoveryPolicy`，effect 恒为 `deviceMutation`。只允许 AIN-009 registry 中
  下列 11 个 exact tuple；其他 operation/profile、同 operation 的 E0/E2 profile、
  configuration digest 漂移或 emitted Step 超出 registry 均拒绝：

  | Operation/profile | Namespace kind | Data impact | Recovery strategy / minimum typed set |
  | --- | --- | --- | --- |
  | `captureHilog` / `hilog.device-persist-restored.v1` | `captureOwned(hilog)` | `reversibleDeviceConfiguration` | `typedCompensation`:stop/resize/cleanup |
  | `captureUIDump` / `ui-dump.owned-sidecar.v1` | `captureOwned(uiDump)` | `reversibleDeviceConfiguration` | `typedCompensation`:restore/cleanup |
  | `captureTrace` / `trace.owned-capture.v1` | `captureOwned(trace)` | `reversibleDeviceConfiguration` | `typedCompensation`:stop/restore/cleanup |
  | `installHAP` / `hap.install-preserve-data.v1` | `bundle` | `applicationDataPreserving` | `verifiedRollback` |
  | `deployNativeLibrary` / `native-library.app-owned-atomic.v1` | `bundle` | `applicationDataPreserving` | `verifiedRollback` |
  | `startApplication` / `application.start.v1` | `bundle` | `ephemeralOwnedState` | `typedCompensation`:stop |
  | `stopApplication` / `application.stop.v1` | `bundle` | `ephemeralOwnedState` | `typedCompensation`:start |
  | `sendOwnedFile` / `owned-file.send.v1` | `jobOwnedRemote` | `ephemeralOwnedState` | `typedCompensation`:cleanup |
  | `createPortForward` / `port-forward.create.v1` | `portForward` | `ephemeralOwnedState` | `typedCompensation`:remove |
  | `removePortForward` / `port-forward.remove.v1` | `portForward` | `ephemeralOwnedState` | `typedCompensation`:create exact pair |
  | `rebootDevice` / `device.reboot.v1` | `deviceMode` | `reversibleDeviceConfiguration` | `resumeProbeOnly` |

  profile 的 `configurationId/configurationSha256` 必须逐字等于 AIN-009 registry；test
  直接读取 registry，不复制第二份 hash 表。`dataImpact` 风险序固定
  `ephemeralOwnedState < reversibleDeviceConfiguration <
  applicationDataPreserving`；任何 data loss、uninstall/downgrade/clear-data、
  system/vendor/root/remount 或无 verified rollback 均不在 E1 vocabulary。
- **Namespace gate:fixed。**namespace 是 closed union：
  `captureOwned{family:hilog|uiDump|trace,rootPolicyId:jobOwnedRemoteV1}`、
  `bundle{bundleId}`、`jobOwnedRemote{rootPolicyId:jobOwnedRemoteV1}`、
  `portForward{pairs:[{protocol:tcp,hostPort,devicePort}]}`（unique、1...32，
  port 1...65535）或
  `deviceMode{allowedTargetModes:[normal|recovery|updater]}`。operation/profile 与
  namespace kind/family 必须按上表相等；carrier/request 均无 absolute/relative remote
  path、host path、connectKey 或任意 namespace string。
- **Limits/fresh-fact gate:fixed。**`limits` 精确为
  `maximumDataImpact/maximumJobDurationSeconds/maximumConcurrentJobs/maximumUses/
  compensationGraceSeconds`；duration 为 `1...86400`，concurrency 恒为 `1`，
  uses 为 `1...32`，grace 为 `1...1800` 秒，global impact 不得低于 scope impact 且
  不存在 destructive 值。`validUntil` 必须 canonical UTC，晚于 GitHub `mergedAt`
  且不超过 `mergedAt + 31 days`。`privilegeRequirements` 精确为
  `developerMode:required|notRequired`、`root:forbidden`、
  `packageDebuggable:required|notRequired`、`freshProbeProfileId` 与
  `maximumAgeSeconds:1...30`；missing/unknown/stale/permissionDenied 或 runtime root
  状态不符均 dispatch=0。E1 不允许通过 capability 请求 root。
- **Compensation/adjacency gate:fixed。**每个 scope 的 `recoveryPolicy` 精确为
  `strategy/requiredStepKinds/resumeProbeProfileId`；strategy 只允许
  `typedCompensation|verifiedRollback|resumeProbeOnly`，resume probe 固定
  `observe-device.read-only.v1`，required Step 集合按上表及 Core descriptor 校验。
  `prohibitedAdjacency` 必须精确声明：
  - effects:`[destructive]`；
  - destructive-only operations:`[flash,uninstallHAP]`；
  - E2 profiles:`hilog.global-persist.v1`、`hap.install-data-impact.v1`、
    `hap.uninstall.v1`、`native-library.system-publish.v1`、
    `flash.rockchip-authorized.v1`；
  - prohibited Step kinds:`mutateHDCServerLifecycle`、`runApprovedRemoteMutation`、
    `uninstallPackage`、`enterUpdater`、`flashPartition`、`updatePackage`、
    `erasePartition`、`formatPartition`、`unlockDevice`。
  任一遗漏/增改或计划邻接上述面即整体拒绝，不拆分低风险子计划继续。
- **Protected-main provenance gate:fixed。**registry 路径固定为
  `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/capabilities/
  <capabilityId>.json`；009R 不创建该目录/实例。resolver 固定
  `ArkDeck/ArkDeck` + protected `main`，本首版无离线 cache；API/rate-limit/network
  不可用即 fail closed。capability blob 必须与 current main、acceptance PR exact head
  和 merge commit 三者同 OID；PR merged/base=main、author=`github-actions[bot]`、
  merge 为 current main 祖先，reviewer/merger 均 `lvye`，APPROVED review commit =
  exact head，actor separation 成立；CODEOWNERS pin =
  `f4edd22f87965efcfc27ea512283a0c2252bf0fb`（`* @lvye`）。删除、改字节或后续
  supersession/revocation 使旧 ref 失效。carrier 自报 metadata/evidenceRefs 不替代
  GitHub provenance。
- **Execution-authority union gate:fixed。**union 与 AIN-009 result 的三种 ref
  字段集合逐字相等：E0
  `readyTask{changeId,taskId,mainCommitOID,taskBlobOID,approvalPRNumber}`、E1
  `deviceCapability{capabilityId,mainCommitOID,capabilityBlobOID,approvalPRNumber}`、
  E2 `standingAuthorization{authorizationId,mainCommitOID,authorizationBlobOID,
  approvalPRNumber}`。kind/effect 精确为 readyTask/readOnly、
  deviceCapability/deviceMutation、standingAuthorization/destructive。serialized ref
  只是 audit identity，不能反序列化为 dispatch capability。
  - E0 `mainCommitOID/taskBlobOID` 指 admission 时 fresh protected-main commit 与
    tasks blob；`approvalPRNumber` 指使该 task ready 的 PR。host 必须解析当前 task
    仍为 ready、依赖仍 done，并证明该 task block 相对 readiness merge 未漂移；
    tasks 文件内其他 block 漂移不授权也不撤销本 block。
  - E1/E2 继续要求 current-main blob 与 acceptance/authorization exact reviewed blob
    相等并分别应用本 readiness 与 r2 provenance rules。caller ref/bytes/path 一律非法。
- **E1 usage/lease gate:fixed。**`agent-authority-usage` 只记录
  `kind=deviceCapability`，E0 无 reservation，E2 继续唯一消费现行
  `authorization-usage 1.0.0`，不得拆成第二套额度。E1 reservation required keys =
  `reservationId/authorizationRef/ordinal/maximumUses/maximumConcurrentJobs/jobId/
  operationDigestSHA256/targetDigestSHA256/reservedAt/forwardLeaseExpiresAt/
  compensationLeaseExpiresAt/terminal`；terminal 为 null 或
  `status:succeeded|failed|cancelled|interrupted|outcomeUnknown` +
  `closedAt/externalIntentEventIds`。规则固定：
  - reserve 在首个 deviceMutation intent 前以 host-wide lock + atomic replace +
    file/directory durability 完成；durable reserve 永久消费 ordinal、不退款；
  - ordinal 从 1 连续唯一且不超过 carrier `maximumUses`；同 stable target 同时最多
    一个 terminal=null E1 reservation；同 reservation retry 仅 exact fields 幂等；
  - `forwardLeaseExpiresAt=min(request deadline,capability validUntil,
    reservedAt+maximumJobDuration)`；过期后零新 forward intent；
    `compensationLeaseExpiresAt=min(capability validUntil+grace,
    forwardLeaseExpiresAt+grace)`，只允许已 durable descriptor 的 exact compensation；
  - reservation 后、首个 effect intent 前崩溃可由同 Job/同 reservation 在 lease 内
    fresh re-admission；任一 E1 intent 无 outcome 则 `outcomeUnknown`，不自动重发或
    猜测 compensation；lease/terminal write 不确定时保留 consumed + blocked。
- **Journal/Manifest 2.2 gate:fixed。**字段名继续使用规范中的
  `authorizationRef`（虽覆盖三种 authority），不另造 caller `authority` 字段。
  - Journal `authorizedAgent` 只允许 `executionMode=execute`；`jobCreated` 必带 exact
    ref，E0 禁止 usage ID，E1/E2 必带 kind-correct durable reservation ID。每个
    `effect>=readOnly` 的 stepIntent/stepOutcome 及每个 external
    compensationIntent/compensationOutcome 必须携带与 jobCreated 完全相同的 ref/
    usage pair、binding 与反向 correlation；hostOnly event 不得借 ref 派生权限。
  - Manifest 2.2 保留 required nullable root key `authorization`；authorizedAgent 时
    固定为 `{authorizationRef,usageReservationId,externalIntentEventIds}`，E0 usage
    为 null，E1/E2 为 exact string，intent set 精确等于 Journal 中 executed 或
    outcomeUnknown 的 readOnly/deviceMutation/destructive step + external compensation
    intents。其他 executionAuthority 的 authorization 恒为 null。
  - authorizedAgent confirmation actor ref 必须与 root/Journal/usage 完全一致；人类
    blocker/impact/recovery 决策仍为 interactiveUser，Agent ref 不能伪造人类判断。
  - unknown/missing/cross-kind ref、ghost/duplicate intent、usage kind 漂移、mixed
    schema Session 或 final Manifest 隐藏 outstanding intent 全 reject。
- **Compatibility gate:fixed。**

  | Stored version | Reader/authority meaning | Write/migration rule |
  | --- | --- | --- |
  | Manifest/Journal 1.x | current locked semantics；无 autonomous authority success | bytes/hash 不改写，不补 ref |
  | 2.0.0 | r2 E2 authorization correlation | existing reader exact；不转写 2.2 |
  | 2.1.0 | r2 E2 + Rockchip descriptor identity | existing reader exact；不转写 2.2 |
  | 2.2.0 | E0/E1/E2 union + external step/compensation correlation | 新 Agent Job only；不得降写旧版 |

  2.2 reader 可按 declared version 调用对应旧 validator 并在内存暴露 read-only normalized
  view，但 round-trip/export 必须保持原 version 与 canonical bytes；单 Session 版本恒一，
  不允许把 2.0/2.1 E2 ref 猜成 E1、把 v1 standardAgent 猜成 E0，或通过 import 获得
  live authority。2.1 E2 usage 继续由原 ledger 计数，2.2 不重置 ceiling。
- **Pinned authority/contract inputs。**实现开工时下列 full Git blob 任一漂移即停回
  readiness：
  - AIN-009 operation schema `b2f41f6d14f18621561acbe93dbfccc3621405f4`、
    registry schema `f75e5d97130d15f3133cb19b73420438db0bfc18`、registry
    `f101619358b08ffb818ccc8eac72b06c7b2062fe`；
  - r2 authorization usage `b232db49d2d76fc2eb96fed6b7d0230455d99345`、
    Journal 2.0 `6285acd4ca0350d427aa624afa91be3107769a64` / 2.1
    `ef71f22c45a7bc06bcde35b0606e94fb6bb79037`、Manifest 2.0
    `9ac334013968a5aba1a0bd77fe2acc982ba0e680` / 2.1
    `1fdb14da2ea8c0b45f88c3d5eef277b37e540976`；
  - current locked workflow-step schema
    `c510d96478f3192168478b1a1669b5fcd2a848f7` / registry
    `d9121ef78531560ab856dfa07468ce1ab4d42df6`、Journal v1
    `d25b7a55e9970d301558430febd235ccc910d8b7`、Manifest v1
    `1100b951f8c7565e10f403d576acfe260e401155`；
  - approved r4 proposal `88093c32728eebd145ce0713b78af747a48331c1`、design
    `bde7c336550bfd9074abf25c2510a1adc5710f1e`、workflow delta
    `a3df2d253b6882538a8e649bc11876a0032270e3`、device-auth delta
    `41fafddb2e8a1233d3bd8ea6517f902fe40bee05`、verification
    `75a89dbcd4e91b717c374a52dbdd8d1357a4d16b`。
- **Test/tool input gate。**只读 Core `WorkflowStep.swift`
  `d96423593978f84a0db7623a1b94863e5d12de26`、`JobStateMachine.swift`
  `c7350e2f74fcbb52a6e582c09c063c5dda0f13f6`、Storage `StrictJSON.swift`
  `d5df2a82ced6b8a06635c1e9f1887d70c693f005`；现有 test blobs：
  `AgentDeviceOperationContractTests.swift`
  `ed0f22af9341149cf4e812e94ecc5599937aeded`、
  `AuthorizationUsageLedgerContractTests.swift`
  `90e9790eca6bf8f397337b8f4cafa56fc7fb9ef6`、
  `JournalRecoveryContractTests.swift`
  `274cc929d7eee30af2a8b05cae3b92672efe101b`、
  `SessionArtifactStorageContractTests.swift`
  `335dc5fc62a7c30c6d0e209f1539b0c78d0caff8`。009R 只新增自己的 test，
  不修改上述 sources/tests；SwiftPM 自动发现，`Package.swift`
  `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 保持不变。
- **Vector/binary verification gate:fixed。**正例必须覆盖 11 个 E1 tuple、五种
  namespace、三种 authority ref、E1 reservation、E0/E1/E2 Journal+Manifest 2.2
  correlation 与 v1/2.0/2.1 historical read；单事实负例覆盖 capability 每个字段/
  limit/provenance、11-tuple omission/duplicate/drift、namespace mismatch、root、
  destructive adjacency、expiry/lease/usage/concurrency、三类 ref 互换、step 与
  compensation ghost/missing/outcomeUnknown、mixed version。Swift test 复用 StrictJSON/
  Core registry，并可在 run path 增加 stdlib-only Python validator/vectors；不得依赖
  `jsonschema`/pip/联网。canonical PASS 必须报告
  `e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3
  process_dispatch=0 device_dispatch=0 hdc_dispatch=0 network=0`。
- **New-file/baseline/review gate:satisfied。**五份 draft、新 Swift test 与
  `evidence/runs/TASK-AIN-009R/` 在 base 均不存在；`evidence/capabilities/**` 亦不存在且
  为 Forbidden path。macOS 26.6 (25G72)、Xcode 26.6 (17F113)、Apple Swift 6.3.3；
  `CI=true swift test --package-path Packages/ArkDeckKit` =
  **470 tests / 1 skipped / 0 failures**，AIN-009 stdlib validator =
  `requests=3/results=4/operations=15/profiles=21/human_blockers=8/negatives=49/
  duplicates=2/core_steps=41` PASS，guard = **0 errors / 0 warnings /
  111 acceptance IDs**。实现 PR 必须复跑新增焦点、AIN-009、legacy
  usage/Journal/Manifest regression、full Swift、guard、strict diff/scope/privacy/
  no-dispatch 审计并记录 exact base/head/hash/count/偏差/残余风险；implementation、
  `ready→done` 与 TASK-AIN-010 readiness 各自独立 PR，D1 合入前零投机实现。

### Deliverables

- closed per-device capability v1：精确 pin target identity/binding family、transport、
  tool/profile/version/hash、operation IDs/namespace、最大 data impact/duration/concurrency/
  uses/validity、compensation/rollback/resume probe、privilege/developer/root fresh probe 与
  prohibited destructive adjacency；
- protected-main carrier/registry/provenance 闭包：caller 只能给 capability ID，
  capability bytes/path/review/readback/usage 均不得成为事实；result ref 与 AIN-009
  `deviceCapability` 形状逐字段一致；
- E0 ready-task/E1 capability/E2 standing-authorization 的 closed authority union、
  E1 durable usage reservation，以及 Journal/Manifest 2.2 crash/replay correlation；
  2.1 Rockchip historical bytes/语义继续可读且不被 2.2 伪装；
- 正反 vectors 固定每字段 drift、expiry、usage、concurrency、provenance、unknown
  kind/version、duplicate/unknown member 与 cross-authority substitution。

### Verification

- contract test 逐个加载 change-local schema/vector，正例 round-trip，单事实反例
  fail closed；AIN-009 result authority union 与 2.2 persistence union semantic closure
  完全相等；
- 2.1 fixture bytes hash 不变且仍可读；2.2 缺/错 authority、usage、binding、intent/
  outcome correlation 全 reject；
- process/HDC/device/network dispatch=0，不创建真实 capability/authorization/usage。

### Notes / handoff

- readiness 必须冻结 exact schema IDs/versions、protected-main registry path、usage
  ceiling/lease/recovery 规则和 2.1→2.2 compatibility matrix；这些值不得由实现 Agent
  临场决定。
- completion 后在 `evidence/runs/TASK-AIN-009R/` 记录 schema hash、vector 数量、
  compatibility matrix 与 no-dispatch 结果；done 后 TASK-AIN-010 仍需独立 readiness。

## TASK-AIN-010 — 通用 TrustedDeviceOperationHost 与 admission

- Status:done（2026-07-29 D0 completion；仅在维护者 review/merge 本独立
  `ready→done` PR 后生效；本翻转不构成 change verified、TASK-AIN-011
  readiness/implementation、production control-surface reachability、真实
  capability/authorization 接受或任何 device dispatch authority）
- Done:2026-07-29；实现经 #758 exact head
  `10dafe8d478fb5b3da63c2bb80554bbb35fa4841` 由维护者 `lvye` APPROVED 并合入
  protected main（merge commit
  `7a81662070d5dc9361152a7996ffbd96af73c83f`）。reviewed head 与 merge tree
  零差异；fresh main 上 TASK-AIN-010 聚焦矩阵 = 18 tests / 0 failures，两套
  AIN-009/AIN-009R stdlib validator 均 PASS，`check-sdd` = 0 errors /
  0 warnings / 111 acceptance IDs，路径守卫 = 50/50；实现 PR 的 Agent PR、
  SDD Guard、allowed-paths 与 Swift CI 全部 SUCCESS。evidence =
  `evidence/runs/TASK-AIN-010/run.md`（blob
  `bb60325031f557861dc87209d47f5c3de13f0a1e`）；本次状态复验仍为
  contract/fake-port，真实 process/device/HDC/network dispatch 全部为 0。
- Historical Status:ready（2026-07-28 D1 readiness；仅在维护者 review/merge
  该独立 PR 后生效；该翻转不构成实现、change verified、capability/authorization
  接受、production control-surface reachability 或任何 device dispatch authority）
- Historical Status:blocked（fresh r2 audit 发现 base `Allowed paths` 漏列本 change
  `tasks.md`；已由独立 scope remediation #753 exact head
  `0985ebc4ab1cc9f02e36be6cce345c1b614d8c6f` 经 `lvye` APPROVED 并合入
  protected main（merge `06fad4cad68aeaca28a5714c2e2ecbdd3cc56a9d`）关闭；记录 =
  `evidence/runs/TASK-AIN-010/readiness-blocked-r2.md`）
- Historical Status:blocked（r4 readiness r1 发现 capability/persistence contract、
  authority encoder/replay scope 与 production-reachability ownership 不闭合；前两项已由
  TASK-AIN-009R #750 implementation + #751 done 关闭，reachability 已归 TASK-AIN-015；
  记录 = `evidence/runs/TASK-AIN-010/readiness-blocked-r1.md`。这些合入均不自动构成
  TASK-AIN-010 readiness）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009、REQ-JOB-002、REQ-JOB-005、REQ-JOB-006
- Acceptance:AC-WF-003-02、AC-WF-003-03、AC-DEV-009-01、
  AC-JOB-002-01、AC-JOB-005-01、AC-JOB-006-01
- Depends on:TASK-AIN-009、TASK-AIN-009R
- Applicable failure patterns:AF-002、AF-003、AF-004、AF-014
- Production reachability:`TASK-AIN-010 product host seam → effect resolver/admission →
  journal-backed typed dispatcher`；`ArkDeckCLI/App → host` 的 production control-surface
  composition 由 TASK-AIN-015 独立接线与验收
- Trusted fact sources:protected-main contract/capability resolver、durable binding journal、
  product-owned HDC/tool observation、host storage/journal；caller request 只含 selector/ID
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/HumanActionRequired.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCDeviceCommand.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/AuthorizationUsageLedger.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEvent.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalReplay.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDeviceOperationHostContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HumanActionRequiredContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AuthorizationUsageLedgerContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/JournalRecoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionArtifactStorageContractTests.swift`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-010/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`（仅本任务
    status/readiness pins/evidence 引用）
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `ArkDeckApp/**`
  - 真实 device/HDC/rkdeveloptool dispatch 与 authorization 载体
- Risk:high（真实 effect composition；实现验证仅 fake/fixture）
- Hardware required:no
- Decision-Grade:D1

### Readiness pins(r1,2026-07-28)

- **Approval/dependency/base gate:satisfied。**r4 scope #744、TASK-AIN-009
  implementation #739 / done #741、TASK-AIN-009R implementation #750 / done #751
  以及 scope remediation #753 的 merge
  `ef33f8f5f4307aebeb7f1fe592459f6787998e48` /
  `1b886869a40b730584330b97d8af7ffa54e99415` /
  `e5a4267a062f97d50e0583ff7df1551e27420863` /
  `ec1cf659618edf96bdbfdc09a4a8182276bd3c58` /
  `d029cc4ebb9b91c647e904d943a65bef5ee95001` /
  `06fad4cad68aeaca28a5714c2e2ecbdd3cc56a9d` 均为本 readiness base
  `06fad4cad68aeaca28a5714c2e2ecbdd3cc56a9d` 的祖先（最后一项即 base）；两项 Depends
  on 均已 done。审计时 open PR 数为 0。实现必须从本 readiness merge 后的 fresh main
  起分支；任一 pinned input 漂移即停回 readiness。
- **Objective/effect/reachability gate:fixed。**本任务只交付可供产品 composition 使用的
  generic host seam、trusted admission、structured human blocker、E0/E1/E2 authority
  与 Journal/Manifest 2.2 runtime support；不接 CLI/App submit/status/cancel/reconcile/
  result（TASK-AIN-015），不接具体 UI Dump/Trace/HiLog/HAP/SO argv 或 executor
  （TASK-AIN-011—014），不创建真实 capability/authorization，不新增 GitHub/network
  client，不启动 installed HDC/rkdeveloptool/真实 process/device；protected-main snapshot
  只从 trusted port 消费，production transport composition 属 TASK-AIN-015。本实现验证
  只允许 fixture/fake ports，evidence=`contract`，realHardware/device/HDC/process/
  network dispatch 全为 0。
- **Public binary/request seam:fixed。**`ArkDeckWorkflows` 新增 public
  `AgentDeviceOperationRequest`、`AgentDeviceOperationResult`、
  `AgentDeviceOperationSubmissionError`、`AgentDeviceOperationBlocker` 与
  `TrustedDeviceOperationHost` actor。host 的唯一 public admission 方法为
  `submit(_ requestData: Data) async -> Result<AgentDeviceOperationResult,
  AgentDeviceOperationSubmissionError>`；actor initializer 保持 `package`，executor
  identity 在 host composition 时固定，method 不接受 actor/fact/grant/plan/port。request/
  result 编解码逐字段实现 AIN-009 schema 1.0.0，所有 object closed，duplicate member
  （含 Unicode escaped 同名）、unknown/missing member、未知 version/kind、非规范
  timestamp/OID/SHA 在任何 Session、usage、intent 或 dispatcher 调用前拒绝。malformed
  request 仅返回 closed error code + redacted field path；不得回显 unknown raw value。
- **Request closure:fixed。**request required keys 精确为
  `documentType/schemaVersion/requestId/changeId/taskId/executionMode/durableTargetId/
  operation`，optional 仅 `authorizationId/requestedOutputs/deadlineUtc`；operation 精确为
  `id/profileId/configurationId/configurationSha256` + optional `artifactLeaseIds`。
  executable、argv、command/shell、host/remote path、Session root、capability/
  authorization bytes/path/ref、binding revision/readback/prerequisite/usage、effect/
  outcome/success/executor override 没有任何 API 或 tolerant decode 入口。`authorizationId`
  只可在 registry-resolved destructive/E2 请求中作为 lookup key；E0/E1 携带它、E2 缺失
  或任一 mode/effect 混淆均 fail closed。
- **Registry/plan/effect gate:fixed。**实现只加载 protected-main pinned AIN-009 registry
  的 15 operations / 21 profiles / 8 human blocker rules，不维护第二份可漂移 registry。
  package-owned `AgentDeviceOperationPlan` 只能由 trusted `AgentOperationPlanning` port
  返回 exact typed `WorkflowStep`；无 public initializer，caller request 不能携带 step/
  arguments/plan digest。host 必须逐字匹配 operation/profile/configuration ID+SHA、
  permitted Step kind、binding/cancellation 与 authorityByEffect；resolved effect 取 Core
  Step minimum、operation minimum、profile declared effect 的最大值。unknown operation/
  profile/Step、空/重复 plan、configuration drift、effect downgrade、E0 混入
  cleanup/set/install/send/reboot 或 E1 邻接 destructive surface 均整体
  `policyBlocked`，不得拆分低 effect 子计划继续。
- **Trusted-port gate:fixed。**`AgentDeviceOperations/**` 内仅可定义下列 package-owned
  port families：protected-main ready-task resolver、protected-main E1 capability
  resolver、existing E2 admission adapter、durable binding resolver、product-owned
  HDC/tool/server/device fact observer、artifact-lease resolver、typed plan provider、
  durable Session/Journal/Manifest/usage store 与 typed dispatcher。所有返回 fact/grant/
  permit 类型均 non-Codable、无 public initializer；production defaults 不读取 local
  worktree、caller PATH/cache/path/bytes 或 request 自报值。port unavailable、timeout、
  partial/ambiguous/stale observation 一律 blocker/dispatch=0；测试 fake 只能经
  `package init` 装配，public consumer 不能替换可信源或 dispatcher。
- **Authority-resolution gate:fixed。**storage 新增 closed public audit identity enum
  `AgentExecutionAuthorityReference`，case/字段逐字等于 009R union：E0
  `readyTask(changeId,taskId,mainCommitOID,taskBlobOID,approvalPRNumber)`、E1
  `deviceCapability(capabilityId,mainCommitOID,capabilityBlobOID,approvalPRNumber)`、E2
  `standingAuthorization(authorizationId,mainCommitOID,authorizationBlobOID,
  approvalPRNumber)`；它可由 Journal/Manifest strict reader 重建为 audit identity，但
  永远不是 dispatch capability。现有 E2 `AuthorizationReference` public API/bytes 不改，
  只提供 host-owned 单向 E2→union bridge；legacy reader 的
  `authorizationReference` 对 E0/E1 返回 nil，新增
  `agentExecutionAuthorityReference` 暴露完整 union。
  - E0 fresh resolver 必须证明 repository=`ArkDeck/ArkDeck`、protected `main`、change
    approved、task 当前仍 ready、dependencies done、approval PR exact-head APPROVED/
    merged、task block blob 与 readiness merge 接受的 block 未漂移；tasks 其他 block
    漂移不授予也不撤销本 task。E0 只准 readOnly 且没有 usage reservation。
  - E1 resolver 必须逐项执行 009R capability target/binding/transport/tool/profile/
    operation/namespace/impact/limits/validity/compensation/privilege/adjacency 与
    protected-main provenance pins；request 只能给 operation/target selector，不能给
    capability ID/bytes。匹配 capability 不是唯一或任一 fresh fact 漂移即零 intent。
  - E2 复用现有 `MaintainerMergedAuthorizationResolver`、
    `AuthorizationAdmissionService` 与唯一 `AuthorizationUsageLedger` 的 grant/fact/
    reservation 语义；generic host 不复制 E2额度、不修改 Rockchip carrier/provenance/
    token、不得用 E1 或 E0 fallback。
- **One-shot capability gate:fixed。**host mint package-owned
  `AgentExecutionPermit` reference type；initializer `fileprivate`、non-Codable、无 public
  factory，内部 lock 保证 exact-once consume。permit 固定 request/job/session、typed plan
  digest、durable target+binding revision、fresh fact receipt deadline、authority ref 与
  E1/E2 usage ID；不能复制、encode、从 Journal/ref 复原或跨 Job/plan/target 使用。顺序固定
  为 authority/usage/session `jobCreated` 全部 durable 后 mint，在首个 external Step intent
  前 consume；consume 时重新检查 deadline、binding、tool/server/device receipt 与
  authority validity。consume 失败不写 external intent、不调用 dispatcher。
- **E1 usage runtime gate:fixed。**在现有 allowed
  `AuthorizationUsageLedger.swift` 中新增 `AgentAuthorityUsageReservation`/
  `AgentAuthorityUsageLedgerDocument`/`AgentAuthorityUsageLedger`，逐字段实现 009R
  `agent-authority-usage 1.0.0`；文件固定
  `agent-authority-usage.json`、lock `.agent-authority-usage.lock`、temporary
  `.agent-authority-usage.<UUID>.tmp`、maximum 16 MiB。E2 原
  `authorization-usage.json`/lock/16 MiB 与全部 public behavior 不变。E1 reservation ID
  固定为 `ain010-` + 下列 canonical UTF-8 `|` 拼接的 SHA-256 前 32 hex：
  `capabilityId/mainCommitOID/capabilityBlobOID/approvalPRNumber/jobId/
  operationDigestSHA256/targetDigestSHA256`。host-wide descriptor lock、no
  symlink/hardlink/path substitution、atomic replace、file+directory sync、monotonic
  ordinal/maximumUses、same-target maximumConcurrentJobs=1、exact retry idempotence、
  consumed-never-refunded、forward/compensation lease 与 terminal/outstanding intent 集合
  全按 009R pins；E0 不入 ledger，E2 只入原 ledger。
- **Durable admission/order gate:fixed。**一次 execute admission 的顺序精确为：
  strict request decode → registry/profile lookup → trusted typed plan + max effect →
  fresh binding/tool/server/device/artifact facts → allocate Job/Session/storage claim →
  fresh E0 ready-task resolution或 E1/E2 authority resolution + durable usage reservation →
  append/sync Journal 2.2 `jobCreated` → mint/consume one-shot permit → immediately before each
  external effect append/sync exact 2.2 intent → typed dispatcher → semantic outcome append/sync
  → state/final Manifest。任一步失败不得越过下一 durability/effect boundary；usage reserve
  后、`jobCreated` 前失败保留 consumed reservation 并阻塞同额度，不能退款或生成孤立
  success。planOnly/simulated 不 mint authority/permit、不写 authorizedAgent、不调用
  external dispatcher。
- **Journal/Manifest 2.2 runtime gate:fixed。**`JournalEvent` 新增
  `agentAuthoritySchemaVersion="2.2.0"`，现有 `schemaVersion=1.0.0`、2.0/2.1 constants/
  constructors/bytes 保持。2.2 `authorizedAgent` 只配 `execute`；`jobCreated` 必带 exact
  union ref，E0 usage=nil，E1/E2 usage=kind-correct durable reservation ID。每个
  effect>=readOnly Step intent/outcome 与 external compensation intent/outcome 携带与
  jobCreated 完全相同的 ref/usage/binding/reverse correlation；hostOnly 不得借 ref 获权。
  Manifest 2.2 required nullable `authorization` 精确为
  `{authorizationRef,usageReservationId,externalIntentEventIds}`，intent set 与 Journal
  executed/outcomeUnknown external intents 相等；authorizedAgent confirmation actor ref
  必须相同，human impact/recovery/governance 仍只能是 interactiveUser。unknown/missing/
  cross-kind ref、ghost/duplicate/mixed-version intent、usage drift、final Manifest 隐藏
  outstanding intent 均 reject。
- **Historical compatibility gate:fixed。**Journal/Manifest 1.0、2.0、2.1 reader 与
  canonical bytes/hash 不变，不 migration/rewrite/backfill ref；2.2 仅写新 Agent Job。
  单 Session 版本恒一。2.2 in-memory normalized view 不能把 v1 standardAgent 推断成 E0、
  把 2.0/2.1 E2 ref 推断成 E1，或从 import/replay mint permit；现有 Rockchip 2.1
  `AuthorizationReference`、usage ceiling、toolchain descriptor 与 regression 必须逐字
  保持。
- **HumanActionRequired gate:fixed。**新增 public closed Codable
  `HumanActionRequired` 与 enum category/status/resume/prohibited automation，字段和
  `human-action-required 1.0.0` schema 逐字一致。initial status=`waiting` 且无
  resolution；只有相同 `resumeProbeOperationId` 的 fresh trusted readOnly probe receipt
  可产生 `resolvedByFreshProbe{probeOperationId,probeReceiptId,observedAtUtc}`；expired
  无 resolution。聊天文字、按钮、elapsed time、caller result 不能 resolve、bind、
  confirm outcome 或提升 authority。八类 exact mapping（prohibitedAutomation 为 exact
  set，不接受删减/任意扩写）固定为：

  | Category | reasonCode / minimumActionKey | resumeProbe | prohibitedAutomation |
  | --- | --- | --- | --- |
  | `physicalConnection` | `device.notObserved` / `human.connectOrPowerDevice` | `observeDevice` | `physicalActuation` |
  | `deviceTrustPrompt` | `device.trustPending` / `human.acceptDeviceTrustPrompt` | `observeDevice` | `trustPromptAcceptance` |
  | `osPermission` | `host.permissionOrDriverRequired` / `human.configureHostPermission` | `probeHostConfiguration` | `privilegeEscalation,driverOrHelperInstall,systemRuleMutation` |
  | `credentialProvisioning` | `host.credentialRequired` / `human.provisionCredential` | `probeHostConfiguration` | `credentialExtraction` |
  | `ambiguousIdentity` | `device.identityAmbiguous` / `human.confirmDeviceIdentity` | `observeDevice` | `identityGuess` |
  | `impactApproval` | `policy.impactApprovalRequired` / `human.reviewImpact` | `probeImpactApproval` | `selfApproval` |
  | `outcomeUnknownDecision` | `recovery.outcomeUnknown` / `human.reconcileOrAbandon` | `reconcileOutcome` | `outcomeGuess` |
  | `governanceApproval` | `governance.approvalRequired` / `human.mergeRequiredApproval` | `probeGovernanceApproval` | `selfApproval` |

  非表中人工动作、“请人工运行命令/打开设备窗口/重复点击”或 reason/category/probe map
  漂移必须视为 automation gap/policy blocker，不能生成自由文本命令。public result 只给
  `humanActionId/blockerCode`；结构化 action 由 trusted host 保存并供 TASK-AIN-015 查询。
- **Crash/recovery gate:fixed。**fault points 至少覆盖 request decode、registry/plan、
  each trusted fact、Session claim/create、E1/E2 reserve 的 write/fsync/replace/dir-sync、
  jobCreated append/write/fsync/dir-sync、permit consume、每个 intent/outcome、terminal
  usage close、Manifest temporary/fsync/write-once rename/dir-sync/finalization。首个
  external intent 前任一 fault ⇒ process/device/HDC dispatch=0；durable external intent
  无 matched outcome ⇒ `waitingForRecovery/outcomeUnknown`，不自动 replay、补 outcome、
  猜测 compensation、release lane/claim 或 resurrect permit。只有 declared fresh
  reconcile/resume probe 可推进；本 task 的 reopen 验证只读 fake Journal。
- **Pinned contract/governance inputs。**实现开工时下列 full Git blob 任一漂移即停回
  readiness：
  - operation schema `b2f41f6d14f18621561acbe93dbfccc3621405f4`、registry schema
    `f75e5d97130d15f3133cb19b73420438db0bfc18`、registry
    `f101619358b08ffb818ccc8eac72b06c7b2062fe`、human action
    `4bf28c508b81744a26334b9356d63b70be7bc039`；
  - capability `7199582380c1d308745fd7e5d18616e2db4fa837`、authority union
    `368e936cc4087c5999ba40da905fd40204b373c3`、E1 usage
    `2dc14806c95c678cc9a51dffd31df7c1bf4633b5`、E2 usage
    `b232db49d2d76fc2eb96fed6b7d0230455d99345`；
  - Journal 2.0/2.1/2.2
    `6285acd4ca0350d427aa624afa91be3107769a64` /
    `ef71f22c45a7bc06bcde35b0606e94fb6bb79037` /
    `768140e670c936dd7ae5a4b01dbbd058fa54bdb3`，Manifest 2.0/2.1/2.2
    `9ac334013968a5aba1a0bd77fe2acc982ba0e680` /
    `1fdb14da2ea8c0b45f88c3d5eef277b37e540976` /
    `b90dc291e6f5159781928230ff33841690e84b01`，provider delta
    `3413edf56811ac30bef833f324cbdf59cff9ce52`；
  - r4 proposal/design/workflow delta/device-auth delta/verification
    `88093c32728eebd145ce0713b78af747a48331c1` /
    `bde7c336550bfd9074abf25c2510a1adc5710f1e` /
    `a3df2d253b6882538a8e649bc11876a0032270e3` /
    `41fafddb2e8a1233d3bd8ea6517f902fe40bee05` /
    `75a89dbcd4e91b717c374a52dbdd8d1357a4d16b`，CODEOWNERS
    `f4edd22f87965efcfc27ea512283a0c2252bf0fb`。
- **Pinned runtime/test inputs。**allowed source blobs：HDC command
  `9cf4014a475d21f77670bfe0b000898795e99dcf`、E2 ledger
  `d87d93caf9fba52e34bdfbaa9a5eb6e16c7cc1b9`、Journal event/validation/replay
  `48103ee11ac7dd343518718df66a65ad987eddb6` /
  `a038703f88cff61ad5ed23c8dbc02bf6bf79db72` /
  `9ea0b4aea122937cc206922a32b13170859e092c`、Manifest
  `22e5010f47a654557f84d1514421a71a792147de`。read-only invariants：
  Core `WorkflowStep` `d96423593978f84a0db7623a1b94863e5d12de26`、
  `JobStateMachine` `c7350e2f74fcbb52a6e582c09c063c5dda0f13f6`、
  `DeviceTargeting` `13a052ba2359e90bfe86fed4884b10fa1f4dd5cf`；Storage
  `StrictJSON`/`DurableFiles`/`SessionLayout`/`SessionAudit`
  `d5df2a82ced6b8a06635c1e9f1887d70c693f005` /
  `039fbb891fdc78c3cf19acc47b3f1231b9dde5c0` /
  `ed48f90a96ee239769e86727ae9272017fea72f7` /
  `b55ae041f61f360475eb46a1b78a7ceef8374f02`；Workflows binding/E2 provenance/
  admission/carrier/host `b07a8c7a8b5d45e335b2ec5dc04dd18cba48dde4` /
  `3f6c18fcece43b5754ec9e4ea4a2149481c1b228` /
  `69fec8990c7cb68c989460ee883bbe358900cc96` /
  `ecf9af642ea37926a6ec018fdfd749022e1998bb` /
  `325e95122a6bed3355d0c45867bbc317f26af544`。实现不得为复用 parser/port 扩 scope
  修改这些 read-only 文件；duplicate-key gate 在新 `AgentDeviceOperations/**` 内私有实现。
  existing tests：operation `ed0f22af9341149cf4e812e94ecc5599937aeded`、
  capability `b81e7419255131c67e3ef1f2d3c9cd385a47d292`、usage
  `90e9790eca6bf8f397337b8f4cafa56fc7fb9ef6`、Journal
  `274cc929d7eee30af2a8b05cae3b92672efe101b`、Manifest/storage
  `335dc5fc62a7c30c6d0e209f1539b0c78d0caff8`；SwiftPM 自动发现新文件，
  `Package.swift` `292135a2c80c63ddf7182f58e2f81ff7c7d6104d` 不改。
- **Verification matrix:fixed。**新增 tests 必须覆盖：三类 authority 各一个 positive fake
  plan；15/21/8 registry closure；request 每个 forbidden/unknown/duplicate/missing/
  cross-mode field；unknown profile/Step/effect downgrade；每个 trusted fact/provenance/
  expiry/usage/concurrency/target/binding/tool mismatch；E0↔E1↔E2 ref/usage substitution；
  permit copy/double-consume/reopen；八类 human blocker exact mapping、wrong probe/text-only
  resume；上述 durability fault matrix；v1/2.0/2.1 byte compatibility。测试禁止
  Process/URLSession/installed tool/real device，canonical PASS 固定为：
  `TEST-AIN-HOST-001 PASS operations=15 profiles=21 human_blockers=8
  authority_kinds=3 legacy_versions=3 process_dispatch=0 device_dispatch=0 hdc_dispatch=0
  network=0` 与
  `TEST-AIN-HUMAN-001 PASS categories=8 resume_probes=5 prohibited_automation=9
  text_resume=blocked authority_elevation=0`。
- **New-file/baseline/review gate:satisfied。**`AgentDeviceOperations/**`、
  `HumanActionRequired.swift` 与两份 task-local tests 在 base 均不存在；现有 allowed files
  存在，`Package.swift` 无需变化。macOS 26.6 (25G72)、Xcode 26.6 (17F113)、Apple
  Swift 6.3.3；full Swift = **476 tests / 1 skipped / 0 failures**；AIN-009 validator =
  `requests=3 results=4 operations=15 profiles=21 human_blockers=8 negatives=49
  duplicates=2 core_steps=41` PASS；009R validator =
  `e1_profiles=11 namespaces=5 authority_kinds=3 legacy_versions=3` PASS；guard =
  **0 errors / 0 warnings / 111 acceptance IDs**，path guard = **50/50 PASS**。
  implementation 必须复跑新增聚焦 tests、两套 validator、现有 E2/binding/Journal/
  Manifest regressions、full Swift、guard/path/diff/scope/privacy/no-dispatch audit并记录
  exact base/head/blob/test counts/偏差/残余风险；implementation、`ready→done` 与
  TASK-AIN-011 readiness 各自独立 PR，本 D1 merge 前零投机实现。

### Deliverables

- product-owned host 解析 operation contract、从可信源解析 ready task/binding/tool facts/
  E1 capability/E2 authorization，并 mint one-shot execution capability；
- E0/E1/E2 effect resolver、structured human blocker、durable Job/Session admission；
- public surface 无 executor/argv/path/fact/grant injection；unknown 按 destructive fail closed。
- 本任务公开可供产品 composition 使用的 host seam；CLI/App submit/status/cancel/
  reconcile/result 接线与端到端 production reachability 只由 TASK-AIN-015 完成。

### Verification

- caller field/provenance/fact injection、stale binding、unknown operation、缺/错 E1/E2 permit →
  intent/process/device dispatch=0；
- fake port 正例证明 E0/E1 capability 只能由 trusted host mint 且 intent 在 effect 前 durable；
- crash/finalization fault matrix 保持 outcomeUnknown 不重放。

### Notes / handoff

- 本任务不接具体 Dump/Trace/Debug argv；只交付可被后续 executor 消费的通用 authority。

## TASK-AIN-010P — Agent E0 registration capture for OpenHarmony probes

- Status:blocked（r5 scope proposal；CHG-2026-043 TASK-HSO-002 已由 #760
  implementation + #761 done 合入，但仅在维护者 review/merge r5 后建立本任务，
  之后仍须 fresh D1 readiness。proposal 不批准 exact argv/设备 tuple，不构成
  integration support 或 device dispatch authority）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009；为 REQ-DEBUG-001/007 与
  REQ-ART-001/002/003 的后继 integration/executor 提供 provenance，不声称其 AC 已通过
- Acceptance:AIN-E0-CAPTURE-001(change-local,r5)
- Depends on:TASK-AIN-010 done、CHG-2026-043 TASK-HSO-002 done（均已满足）、
  r5 merge；之后独立 D1 readiness
- Applicable failure patterns:AF-002、AF-003、AF-005、AF-006、AF-011、AF-013、
  AF-014、AF-016、AF-018
- Production reachability:
  `Agent request/task authority → ArkDeckE0ProbeRegistrar → TrustedDeviceOperationHost(E0) →
  durable binding + production HDC candidate/server/device facts → closed typed read-only plan →
  identity-bound process → HostStorageCoordinator local raw Artifact + redacted provenance`
- Trusted fact sources:ready task 来自 protected main resolver；target/binding revision
  来自 durable storage；HDC candidate/executable bytes 来自 production discovery +
  descriptor revalidation；server identity/ownership 来自 TASK-HSO-002 production
  commandless observer；device row 来自 registered exact `list targets -v`。caller 只给
  request/task ID，不能给 executable/argv/endpoint/connectKey/binding/fact/receipt/
  output/support
- Allowed paths after readiness:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/AgentReadOnlyRegistration/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/E0Registration/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckE0ProbeRegistrar/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentE0RegistrationCaptureContractTests.swift`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-010P/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`（仅本任务
    status/readiness pins/evidence 引用）
- Forbidden paths:
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `openspec/integrations/**`、`openspec/platforms/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCProduction.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCReadOnlyProbeRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HDCSupervisorObservationProbeRegistry.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `scripts/m0b_capture/**`、`scripts/trace_capture/**`、`scripts/ud_capture/**`
  - current hardware-evidence V2、change-local V3 schema bytes 与任何 authorization/
    capability instance
  - integration registry/resource/profile/lock、hardware matrix、其他 change tasks/evidence
- Risk:medium（真实设备 E0 + privacy-sensitive live logs；零 mutation/destructive）
- Hardware required:yes（readiness-pinned OpenHarmony device/HDC；人工只允许接线/
  供电、解锁/信任、系统权限/凭据配置与物理断连恢复，Agent 执行全部命令）
- Decision-Grade:D1

### Deliverables

- reusable `ArkDeckE0ProbeRegistrar` package executable 与 closed production-fact session；
  no shell/PATH fallback，无 raw argv/target/receipt/classification 注入口。
- readiness-pinned typed E0 plan：`hilogHelp`、bounded `hilogHostStream`、
  `hidumperHelp`/`hidumperInventory`、`hitraceHelp`/`hitraceTags`、
  `bytraceHelp`/`bytraceTags`；逐 step 与总 time/byte budget、cancel/termination/
  privacy rules。
- plan effect ceiling 固定 readOnly；出现 remote write/cleanup、set/clear/resize/
  persist、send/install/uninstall、reboot、lifecycle/subserver 或 unknown step 时
  whole-plan reject，process/device dispatch=0。
- Agent-executed、change-local V3 schema-valid 的 `realHardwareE0ReadOnly`
  evidence：`executor.kind=agent`、E0 ready-task `authorizationRef`、machine target
  confirmation、pre/post facts、人工 boundary、exact typed command transcript、
  stdout/stderr counts/hashes/result 与全部 effect counters。
- raw HiLog/工具输出只写 HostStorageCoordinator 管理的本地 Artifact；仓内只存脱敏
  receipt、hash/count/redaction statistics 和受控位置引用。connectKey/serial/raw log
  rows/业务文本/用户绝对路径/大二进制不入仓。
- 供后继 independent integration change 消费的 provenance bundle；本任务不创建/
  修改 registry/profile/lock，不把 capture 自动标为 supported。

### Verification

- `AIN-E0-CAPTURE-001` → typed contract/fault suite + Agent real-device run +
  V3 schema/privacy/effect audit → 人工 device command=0；八个 typed probe 全由 Agent
  执行或诚实返回 unsupported/partial；E1/E2/server lifecycle dispatch=0。
- caller target/argv/fact/receipt/support 注入、stale/ambiguous binding、wrong candidate/
  hash/endpoint、server/device drift、timeout/cancel/truncation/invalid UTF-8、ENOSPC/
  privacy rejection → fail closed/partial，禁止 fallback 或自动重放。
- crash 在 terminal receipt 前只允许 outcomeUnknown/partial + reconcile；fresh request/
  facts 前不得再次执行 device command。

### Notes / handoff

- readiness 必须固定 exact device/build/HDC tuple、八个 typed argv、每步与总 budgets、
  HostStorageCoordinator layout、V3 evidence instance、human boundary 和 privacy
  allowlist；缺任一项即保持 blocked。
- implementation/evidence 与 `ready→done` 分离。done 只证明 accepted capture
  provenance 存在；随后仍须独立 integration change 登记/adopt exact family。

## TASK-AIN-011 — E0 observation、HiLog 与 Artifact executor

- Status:blocked（2026-07-29 fresh r1 audit：TASK-AIN-010 已 done，但 current
  integration authority 未登记 exact HiLog/HiDumper/current-Trace E0 family，
  production semantic profile 无对应 lowering，且 base Allowed paths 漏列本 change
  `tasks.md`。等待 r5 scope remediation、TASK-AIN-010P done、后继独立 integration
  change registration/adoption/verification 与再次 scope remediation 后，仍须 fresh
  D1 readiness；记录 =
  `evidence/runs/TASK-AIN-011/readiness-blocked-r1.md`）
- Historical Status:blocked（原始依赖为 TASK-AIN-010 done + 独立 readiness；010
  已由 #758 implementation + #759 done 关闭，但不自动建立本任务 readiness）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEBUG-001、REQ-DEBUG-007、REQ-ART-001、
  REQ-ART-002、REQ-ART-003
- Acceptance:AC-WF-003-01、AC-DEBUG-001-01、AC-DEBUG-007-01、
  AC-ART-001-01、AC-ART-002-01、AC-ART-003-01、AC-DEBUG-008-01
- Depends on:TASK-AIN-010、TASK-AIN-010P、后继独立 OpenHarmony E0 integration
  registration/adoption（change/task ID 待其 proposal 合入后由独立 scope revision 固定）
- Applicable failure patterns:AF-002、AF-005、AF-011、AF-013
- Production reachability:`Agent request → TrustedDeviceOperationHost(E0) → registered
  HDC read-only lowering/HiLog stream → Session Artifact writer`
- Trusted fact sources:durable binding、registered HDC/profile/golden、server identity/
  ownership 与 HostStorageCoordinator；caller target/config 只用于 cross-check
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/AgentReadOnlyOperations/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/E0/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentE0OperationContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-011/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`（仅本任务
    status/readiness pins/evidence 引用）
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `scripts/m0b_capture/**`
  - `scripts/trace_capture/**`
  - `scripts/ud_capture/**`
  - 真实设备 evidence/hardware matrix
- Risk:medium（production E0 composition；实现验证仅 fixture）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- device/tool/help/HiDumper/Trace probe 与 bounded HiLog stream 的 product executor；
- raw stdout/stderr/shards 分离、rotation、partial/ENOSPC、atomic publication、redaction/
  derived processing 与 terminal manifest；
- E0 计划中出现 mutation/destructive step 时整体拒绝，不能静默跳过或降级。

### Verification

- fixture 端到端 `submit→result`，HiLog 超配额仍有界、顺序/hash 完整；
- timeout/truncation/invalid UTF-8/unknown golden/ENOSPC/server drift/binding drift →
  诚实 partial/failed，mutation/destructive dispatch=0。

## TASK-AIN-012 — Agent-owned ArkUI UI Dump 与 Trace E1 executor

- Status:blocked（等待 TASK-AIN-011 done + 独立 readiness PR）
- Platform:macos
- Requirements:REQ-DUMP-002/003/004/005/006/007/009、REQ-TRACE-001/002/003/
  004/005/006/007/008/009/010、REQ-WF-003
- Acceptance:AC-DUMP-002-01、AC-DUMP-003-01、AC-DUMP-004-01、
  AC-DUMP-005-01、AC-DUMP-006-01、AC-DUMP-007-01、AC-DUMP-009-01、
  AC-TRACE-001-01、AC-TRACE-002-01、AC-TRACE-003-01、AC-TRACE-004-01、
  AC-TRACE-005-01、AC-TRACE-006-01、AC-TRACE-007-01、AC-TRACE-008-01、
  AC-TRACE-009-01、AC-TRACE-010-01
- Depends on:TASK-AIN-011
- Applicable failure patterns:AF-002、AF-004、AF-011、AF-013、AF-014
- Production reachability:`Agent request → trusted E0/E1 admission → UI Dump/Trace typed
  plans → journal-backed HDC dispatcher → Artifact/compensation finalization`
- Trusted fact sources:registered Recipe/Trace family、durable binding、per-device E1
  capability、parameter readback、owned-path receipt；caller IDs/analysis 不是 capability
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/UIDumpAgentAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/TraceProbeAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/UIDump/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/Trace/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Trace*.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentUIDumpOperationContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentTraceOperationContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-012/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `scripts/ud_capture/**`
  - `scripts/trace_capture/**`
  - 真实设备 evidence/hardware matrix
- Risk:high（E1 semantics；实现验证仅 fixture）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- 四个 UI Dump Recipe 与 Trace probe/config/capture/receive/postprocess/cleanup/restore 的
  product-owned executor；
- stdout/sidecar/raw/derived origin 隔离，UUID-owned path 与 verified-before-cleanup；
- parameter/reboot/rebind/stop/restore compensation、cancel/safe boundary 与 crash recovery。

### Verification

- fake HDC 完整正例覆盖四 Recipe 与 Trace lifecycle；
- stale/ambiguous sidecar、unsupported tag/flag、readback mismatch、receive interruption、
  restore/cleanup failure、rebind ambiguity、outcomeUnknown 全 fail closed，其他 Session
  remote files untouched。

## TASK-AIN-013 — HiLog、HAP 与应用生命周期 Agent executor

- Status:blocked（等待 TASK-AIN-011 done + 独立 readiness PR）
- Platform:macos
- Requirements:REQ-DEBUG-001/002/003/004/006/007/008、REQ-WF-003
- Acceptance:AC-DEBUG-001-01、AC-DEBUG-002-01、AC-DEBUG-003-01、
  AC-DEBUG-004-01、AC-DEBUG-006-01、AC-DEBUG-007-01、
  AC-DEBUG-008-01、AC-DEBUG-008-02、AC-DEBUG-008-04
- Depends on:TASK-AIN-011
- Applicable failure patterns:AF-002、AF-003、AF-011、AF-014
- Production reachability:`Agent request → trusted E0/E1 admission → package/app/log/forward
  typed lowering → journal-backed HDC dispatcher`
- Trusted fact sources:leased HAP bytes/hash/signature、durable binding、registered output
  family、per-device E1 capability 与 post-install package readback
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/AgentDebugOperations/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/Debug/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDebugOperationContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-013/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - 任意 shell/PTY、未登记 remote command 或真实设备 evidence
- Risk:high（E1 semantics；实现验证仅 fixture）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- HAP install/replace/uninstall、package readback、Ability start/stop、forward create/remove
  与 HiLog 组合 executor；uninstall/clear-data/downgrade/data-loss profile 提升为 E2 或
  impact blocker；
- install/replace/downgrade/clear-data 分离 operation，data impact 与 compensation 可审计；
- semantic parser、multi-device binding、cancel/crash/partial evidence。

### Verification

- HAP pin 全匹配正例 `install→readback→start→HiLog→stop` 完整；
- 错 bundle/version/signature/hash/binding/output family、未授权 downgrade/clear-data、
  invalid port → 后续 dispatch=0；exit 0 缺 semantic marker 不成功。

## TASK-AIN-014 — Profiled native-library deployment

- Status:blocked（等待 TASK-AIN-010、TASK-AIN-013 done + 独立 readiness PR）
- Platform:macos
- Requirements:REQ-DEBUG-008、REQ-WF-003、REQ-JOB-002/004/006
- Acceptance:AC-DEBUG-008-03、AC-DEBUG-008-04、AC-WF-003-02/03、
  AC-JOB-002-01、AC-JOB-004-01、AC-JOB-006-01
- Depends on:TASK-AIN-010、TASK-AIN-013
- Applicable failure patterns:AF-002、AF-003、AF-011、AF-014
- Production reachability:`Agent request → deployment profile/effect resolver → E1 capability
  or E2 standing authorization → staged descriptor-bound publish → verify/rollback`
- Trusted fact sources:host-leased ELF bytes/ABI/build ID/hash、protected-main profile、
  durable target/binding、fresh privilege/target snapshot 与 publish/loader readback
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/NativeDeployment/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/NativeDeploymentAdapter.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentNativeDeploymentContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeHDCFixture/**`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-014/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - caller-provided remote path/argv、自动 root/smode/remount、真实设备 dispatch
- Risk:destructive semantics（实现验证仅 fake；E2 真机另需 standing authorization）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- `.so` profile validator、ABI/ELF/hash/target snapshot、owned staging、atomic publish、
  loader verification、process restart、rollback 与 hazard classification；
- effect promotion：system/vendor/root/remount/no-rollback/boot-runtime impact 恒为 E2；
- E1/E2 authority 与 profile scope 逐项相关，Agent request 不能传 remote path。

### Verification

- app-owned rollback-capable E1 正例与 E2 promotion 正例；
- target replacement、mode/owner/ABI/hash drift、publish/verify/rollback crash windows、
  outcomeUnknown → 不盲目重发，replay dispatch=0，状态/Artifact 如实。

## TASK-AIN-015 — Agent control surface 与有界自动调试闭环

- Status:blocked（等待 TASK-AIN-012/013/014 done + 独立 readiness PR）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009、REQ-DUMP-009、REQ-TRACE-010、
  REQ-DEBUG-008、REQ-JOB-001、REQ-STO-003
- Acceptance:AC-WF-003-01/02/03、AC-DEV-009-01、AC-DUMP-009-01、
  AC-TRACE-010-01、AC-DEBUG-008-01/02/03/04、AC-JOB-001-02/03、
  AC-STO-003-01
- Depends on:TASK-AIN-012、TASK-AIN-013、TASK-AIN-014
- Applicable failure patterns:AF-002、AF-004、AF-005、AF-011
- Production reachability:`arkdeck agent submit/status/cancel/reconcile/result or App local
  surface → TrustedDeviceOperationHost → capability executors`
- Trusted fact sources:host-generated Job/Session IDs、terminal manifest、Artifact store 与
  operation executors；analysis output only drafts the next request
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/ControlPlane/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/DebugLoop/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentControlPlaneContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/AgentDebugLoopContractTests.swift`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-015/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - network listener/remote RPC、arbitrary shell/PTY、真实设备 evidence
- Risk:high（production orchestration；实现验证仅 fixture）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- strict JSON stdin/stdout 或等价同用户本地 IPC 的 submit/status/cancel/reconcile/result；
- bounded typed DAG：observe→optional deploy→start→HiLog+Dump/Trace→analysis→next request；
- budget/deadline/retry ceiling、human blocker、lane/storage coordination 与 terminal result。

### Verification

- fixture 端到端闭环与并发资源竞争；
- analysis 建议越权、旧 capability/readback 复用、循环超预算、取消、crash/restart、
  repeated blocker → fresh admission 或停止，绝不无限重试/自报成功。

## TASK-AIN-016 — E0/E1 Agent 真机验收

- Status:blocked（等待 TASK-AIN-015 done + 独立 D2 readiness；不得复用旧人工窗口）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009、REQ-DUMP-009、REQ-TRACE-010、
  REQ-DEBUG-008
- Acceptance:AC-WF-003-01/02、AC-DEV-009-01、AC-DUMP-009-01、
  AC-TRACE-010-01、AC-DEBUG-008-01/02/03/04
- Depends on:TASK-AIN-015
- Applicable failure patterns:AF-005、AF-006、AF-011、AF-012
- Production reachability:`real Agent control request → production trusted host → pinned HDC/
  device → E0/E1 executor → real Session/evidence`
- Trusted fact sources:fresh real device/tool/server/binding probes、merged E1 capability、
  product journal/Artifact/outcome；人工只完成 allowlisted prerequisite
- Allowed paths:
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-016/**`
  - `openspec/verification/hardware-matrix.md`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md`
- Forbidden paths:
  - `Packages/**`
  - `ArkDeckApp/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:high（真实 E0/E1；E2/native system path dispatch=0）
- Hardware required:yes（pinned OpenHarmony device/HDC/build；人工仅配置/信任/物理动作）
- Decision-Grade:D2

### Deliverables

- Agent 无人值守完成 E0 observation/HiLog、四 Recipe UI Dump、Trace lifecycle、HAP
  install/start/diagnostics/readback 与 rollback-capable app-owned `.so` E1 profile；
- human blocker 实测：首次 trust/物理动作后由 Agent resume probe 自动续跑；
- schema-compliant executor.kind=agent evidence、脱敏 transcript、negative dispatch counts。

### Verification

- 每个 AC 有真实 product-path evidence；人类不复制命令、不运行 capture/deploy harness；
- E1 capability 缺失/漂移、错误 binding/profile/HAP/SO、ambiguous identity、restore/
  rollback fault → effect dispatch=0 或诚实 recovery；
- E2/system/vendor/root/remount/flash dispatch=0（Flash 真机仍归 TASK-AIN-004）。

## TASK-AIN-017 — 移除活跃流程中的非必要 human-only 门

- Status:blocked（等待 TASK-AIN-004 与 TASK-AIN-016 done + 独立 D1 revision PR）
- Platform:macos
- Requirements:REQ-WF-003、REQ-DEV-009
- Acceptance:AC-WF-003-01/02/03、AC-DEV-009-01
- Depends on:TASK-AIN-004、TASK-AIN-016
- Applicable failure patterns:AF-005、AF-006、AF-015、AF-016
- Production reachability:not applicable（governance/runbook revision；零 effect）
- Trusted fact sources:TASK-AIN-004/016 merged realHardware evidence 与 protected-main
  product executor OID；不以 proposal 或 fake test 宣告 human gate 已移除
- Allowed paths:
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/proposal.md`
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/design.md`
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/tasks.md`
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/verification.md`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/proposal.md`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/verification.md`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/capture-runbook.md`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/proposal.md`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/design.md`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/tasks.md`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/verification.md`
  - `scripts/m0b_capture/README.md`
  - `scripts/trace_capture/README.md`
  - `scripts/ud_capture/README.md`
  - `scripts/e0_readback/README.md`
  - `openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/runs/TASK-AIN-017/**`
- Forbidden paths:
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/**`
  - `ArkDeckApp/**`
- Risk:medium（跨 change D1 scope/status revision；零真机 dispatch）
- Hardware required:no
- Decision-Grade:D1

### Deliverables

- 逐项修订 CHG-006/008/026 的未完成 task/runbook：E0/E1 改为 Agent product executor，
  只保留 §16 human-boundary registry 中的人工动作；
- human harness 标注为 historical fixture/provenance，不再是新真机 evidence 的执行入口；
- repository-wide inventory 证明活跃流程无“人工代跑命令/设备窗口”残留；确需人工者均
  引用结构化 blocker category。

### Verification

- 全仓 grep + task dependency/status review + SDD guard；
- 历史 evidence/raw/golden hash 零改写；未取得产品真机 evidence 的 capability 不提前
  标 ready/done/verified。
