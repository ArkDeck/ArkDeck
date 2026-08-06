# Tasks

> 垂直 PR 模型(CHG-2026-046):实现、测试、文档、evidence 与状态翻转
> 由一个实现 PR 交付;E1 capability 由独立维护者审批 PR 签发，真机
> evidence 与发现问题后的产品修复仍随对应 Golden Journey 垂直 PR 同车。

## TASK-DHA-001 — MU-4 垂直交付:Agent runner + Artifact + diagnostics/HAP

- Status:done（2026-07-30 两条真实 DAYU200 Golden Journey 均由 Device
  Runtime Agent 完成；GJ-1 覆盖 observe.device、HiLog、UI Dump、
  Artifact 与 daemon restart，GJ-2 覆盖 HAP send/install/readback/start/
  capture/stop/uninstall/remote cleanup 与 daemon restart。除既有设备信任
  外人工 HDC 命令为 0。#798 及本垂直交付补齐 descriptor-bound HDC、
  Runtime Availability、授权前完整 materialization、stable identity/
  binding revision/plan digest admission、exact-action durable recovery、
  dedicated mutation readback、cleanup debt query/continue、自动 capability
  draft 与真实 HiLog 原始字节 Artifact。remote Trace、strict redaction、
  installFresh、restorePrevious、debugger-default 保持 production unavailable
  并在 capability 消耗前 fail closed）
- Grade:D1(代码/契约/fake 面。真机 host Runtime 由 Device Runtime Agent
  执行;**E1 capability 的签发/接受是 D2 决策**,独立载体,Agent 不得
  自签或自批;人类只提供必要物理协助)
- Platform:macos
- Requirements:兼容实现;POL-AGENT-002 的 E0/E1 分级零弱化
- Acceptance:`DHA-AGENT-001`、`DHA-ART-001`、`DHA-CAP-001`、
  `DHA-HAP-001`(contract/fake,随实现 PR)+ `DHA-HW-001`、
  `DHA-HW-002`(realHardware,Agent 执行后补记;补记前如实标
  hardware-pending)
- Depends on:r2 proposal revision 合并(即 fresh-readiness 批准);
  CHG-2026-046/047/048 已合入，T11 门槛已由 `chg-2026-048` 的
  `BER-HW-001/002` 关闭；`CHG-2026-050/TASK-WSC-001` 已由 PR #789
  合入 `d13dfec6d395dd73662494f16ead9674711fe6ff`(满足)
- Fresh-readiness base:
  `d13dfec6d395dd73662494f16ead9674711fe6ff`
- Readiness input pins:

  ```yaml pins
  - path: Catalog/operations/observe.device.v1.json
    blob: 6efb682bd5e07cd4cab49667b714a889fa44fc56
  - path: Catalog/operations/capture.diagnostics.v1.json
    blob: 37ce723faf58780e00c11f5718f78a4271aef5ae
  - path: Catalog/operations/debug.hap.v1.json
    blob: 1189c9f5d4e73eab71c8ec3d52e7aa53eadf1627
  - path: Catalog/schema/operation.schema.json
    blob: d0320ec62c6346fb59e6fa21d59533e851ce52d0
  - path: openspec/contracts/workflow-step.schema.json
    blob: 91146408bae344df493a1ea21338e2c37114fa45
  - path: openspec/contracts/workflow-step-registry.yaml
    blob: d9121ef78531560ab856dfa07468ce1ab4d42df6
  - path: openspec/contracts/catalogs/diagnostics-stdout.yaml
    blob: 2ba63e79183638bca4202e604bd4816a58014bba
  - path: openspec/contracts/catalogs/remote-operations.yaml
    blob: fe3841d992bbae89bb8f954a1bcdeab0c4f714d1
  - path: openspec/integrations/openharmony/profile.md
    blob: 2ae13490e075f327bb7448ccacf908be5ba7e3aa
  - path: openspec/platforms/macos/profile.md
    blob: b7471666b0bbfbfade3fbd510ad831e45b3cf9b8
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogGenerated.swift
    blob: c4f22f82ab983dc6ae8a119d52598aed50d9f434
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeOperationCatalogTypes.swift
    blob: f51d5f327a12f8f0b681a651c3d435107ccd318e
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift
    blob: 6aae31f911ca56f14676c5ae94fd975576daea0f
  - path: Packages/ArkDeckKit/Sources/ArkDeckCore/RuntimeCapability.swift
    blob: 24563705c73618cd1fec1bc48ef8d26a311c2d1b
  - path: Packages/ArkDeckKit/Sources/ArkDeckStorage/RuntimeCapabilityStore.swift
    blob: 34b38a58d47709ebb706f0b763126bc4896f233d
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/AgentDeviceOperations/RuntimeOperationModelsV2.swift
    blob: 432765beaf932a7d81a926bfd21e9cf170af4e08
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift
    blob: 476c7c8d1654a50b33913a9fbce94eb0d4e868ea
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift
    blob: ad98248aa5b6f28fe0c5a170aa1f76d6a50d912f
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderAdapters.swift
    blob: c9fbd8855cb8214e8d83ffc1faab7f6458d03d99
  - path: Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/HDCE0ActionPack.swift
    blob: 50db01757444f44d3014322e7c915ed729a261d9
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentClient/AgentClient.swift
    blob: f73bf875e9a984cef7ff0563280ed06c25b0d119
  - path: Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/AgentDaemon.swift
    blob: 0d72178c976bf9a1b22648a4ff0ea580ace3be35
  ```
- Scope(四子面,不拆分为独立 PR;实现顺序 T00 → T14 → T12 → T13):
  1. **T00**:one-shot Device Runtime Agent runner(只经 AgentClient/daemon
     typed API) + structured humanAction pause/resume + 脱敏 execution
     receipt;Agent surface 无 HDC/argv/shell 与 capability 管理入口。
  2. **T14**:artifact 元数据模型 + 发布/读取/导出面 + quota/retention/
     GC/cleanup debt + 默认 redaction + manifest;补齐 `observe.device@1`
     四 artifact 落盘(MU-3 递延项);daemon `artifact.*` 方法。
  3. **T12**:`capture.diagnostics@1` 编排(授权前按选中步骤计算 effective
     effect;remote trace/cleanup 升为 E1;含部分成功逐项标注、cancel
     安全边界收取、byte budget 有序截断、远端 cleanup debt)。
  4. **T13**:HDC E1 typed action(send/install/readback/start/stop/
     uninstall/port-forward)+ `debug.hap@1` 编排(readback 判定成功、
     补偿策略、unknown 即停)。
- Verification:见 `verification.md`;contract/fake 随 PR,两条真机由
  Device Runtime Agent 执行后补记
- Stop conditions:任何既有测试无法在不弱化断言的前提下保持通过;
  发现需要修改 `Catalog/` 既有 operation 语义或 `openspec/specs/**`;
  发现 E1 判定无法在不看 exit code 的前提下成立;发现 remote trace/
  cleanup 无法在 dispatch 前升级 effective effect;发现真机 AC 只能靠
  维护者代跑 host CLI——任一命中即停,登记 blocked 并说明
- Resolved blocker(2026-07-29):`CHG-2026-050/TASK-WSC-001` 已将四个
  stdout step 的 exact `actionRef` 写入 reviewed Catalog 与 generated Swift，
  并使 `arkdeck-diagnostics/boundedHilog|componentTree` 在 JSON Schema 和
  Swift validator 中可如实表达。generator/WorkflowStep 合约与 exact merged
  tree 已复验通过；原 blocker 关闭。
- Superseded blocker(2026-07-29,run-r2):合入后的深检发现五类未闭环:
  四类 published
  输入缺真实执行链:①remote trace 的 `file recv` 没有 engine-controlled
  host destination、remote stat/size/hash/header 验证;②strict redaction
  没有独立实现;③`installFresh` 没有安装前 absence readback;④
  `restorePrevious`/`debugger-default` 没有 snapshot/restore 或
  port-forward step。当前实现均在 capability 消耗与 dispatch 前拒绝,
  避免 fake-only 路径或静默降级。⑤cleanup debt 已能持久化和显式
  settle,unknown 也会保留原 typed step,但 runtime reconcile 尚无携带
  原 job authority 的 durable start/outcome/transition 与 typed
  re-observe/remove/settle/continue 流程,不得把 ledger API 或只改
  job-record 冒充自动恢复。
  该结论已被 2026-07-30 产品闭环恢复指令取代：禁止为这些发现新建
  change/proposal；前四类保持 production unavailable / pre-consumption
  fail closed，第五类已在 #798 同车实现 exact-action readback reconcile
  与 cleanup debt query/continue。详见 `run-r2-hardening.md` 续修记录。
- Hardware closure(2026-07-30):旧 attempt#2 仍按原记录保持
  `BLOCKED / NOT CLAIMED`，未被重写或升级。新的产品闭环 GJ-1 由 Runtime
  receipt 原生记录 `executor=agent`、default read-only authority、firmware、
  target confirmation 与 Artifact，并在 daemon restart 后读回；GJ-2 使用
  PR #832 合入的 exact E1 capability，最终 Job
  `job-3a4aa8b2f2d5c46817e4a603582734c2` 为 `succeeded`、
  `outcomeUnknown=false`，install/process/HiLog 三项 Artifact 发布且
  stop、uninstall、remote cleanup 全部完成。详见
  `gj1-device-observe-2026-07-30.md` 与 `gj2-hap-debug-2026-07-30.md`。
- Product follow-up(2026-07-30):为减少同一 E1 typed plan 的重复签发，
  本产品 PR 将 Runtime Capability 落为有界持久 authorization envelope，
  并由 daemon 对 Catalog 允许默认签发的 E1 operation 自动创建、续期和
  持久化；调用者无需 capability JSON、安装命令或 reviewer：
  每代 envelope 有效 30 天/10,000 次且绑定完整 typed-input map，每次
  Job 消费追加绑定 target、binding revision、typed-plan digest 与 effect
  的 hash-linked lineage；
  只有前一节点 outcome confirmed 且范围无漂移时才允许下一次执行。
  pending、legacy-unverified 与 `outcomeUnknown` 均阻止新 reservation，同一
  Job 的 crash/reconcile reservation 保持幂等且不自动重发；E2 仍强制
  one-shot。兼容与测试记录见
  `runtime-authorization-standing-plan-lineage-2026-07-30.md`。该跟进不改变两条
  Golden Journey 状态，也不新增 change、Acceptance 或治理状态。
- Saved-draft handoff:原 `agent/task-dha-001` 工作树保留 10 个 tracked
  修改和 5 个 untracked 新文件，未提交、未计 evidence；与
  `dac5f82..d13dfec` 的 main 改动路径交集为 0。r2 合入后恢复时必须先把
  该草稿迁移到 fresh base，并把 stdout action 构造改为消费 generated
  `CatalogStepDescriptor.actionReference`；禁止保留按 `stepID` 猜
  catalog/action 的 fallback。构造的 `WorkflowStep` 还必须携带
  diagnostics contract 要求的 exact typed parameters/bounds。
- Hardware required:yes(仅 `DHA-HW-*` 两条;contract/fake 面不需要。
  硬件存在不等于人工执行:`DHA-HW-001` 由 Agent 直接走 E0;
  `DHA-HW-002` 在维护者签发/接受 E1 capability 后由 Agent 执行。
  Agent 零签发/零自批;人类仅处理设备信任、歧义选择与物理动作)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/contracts/**`、`openspec/verification/**`(全局)、
    `openspec/integrations/**`、`openspec/platforms/**`、
    `openspec/baselines/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首个 Agent-operated E1 mutation 面——以 plan effective effect、
  capability fail-closed、readback 判定、unknown 即停四层约束;artifact
  面触及磁盘与隐私——以 quota、redaction、privacy class 三层约束)

## TASK-DHA-002 — 清理残留成为一等记录(r3)

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准);
  DHA-RES-001..003 全部 PASS(contract 面,912 tests / 1 skipped / 0 failures);
  **未动 `Catalog/**`** —— proposal r3 的判断成立,没有任何步骤声明变化
- Platform:macos
- Requirements:proposal r3 What 1-5(债务身份推广为残留、记录门改为清理职责且
  覆盖补偿路径、`cleanupDebt.continue` 对 bundle 残留复用 D2 readback、
  job 状态暴露未结清残留、`cleanup-uninstall` 保持 optional)
- Acceptance:change-local `DHA-RES-001`..`DHA-RES-003`,登记于 `verification.md`
- Depends on:TASK-DHA-001(done);r3 proposal 合入即 approved
- Hardware required:no。真机复验**不单开窗口**:该失败模式(uninstall 跑了但
  没生效)难以在真机上稳定构造,contract 面用 scripted dispatcher 覆盖即可;
  若后续窗口自然撞上,按既有先例补记
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`(仅在实现确证需要时;proposal r3 判断大概率不需要)
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/**`
  - `scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(触及持久化债务台账的形状与一个已发布 operation 的失败语义。
  三层约束:既有远端路径债务的行为逐条不变、`succeeded` 的含义不被悄悄收窄
  (残留另行可见而非改终态)、结清仍由 readback 判定而非退出码)

## TASK-DHA-003 — 多包 HAP 按目录安装(r4)

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准);
  DHA-MULTI-001..003 **全部 PASS** —— 其中 003 原定 pending(缺多模块签名 HAP),
  素材当天构建出来后真机跑通(`job-42c0ab9d…`,设备读回
  `installed modules: ['entry', 'feature1']`);
  evidence = `evidence/runs/TASK-DHA-003/run-r4.md`
- Platform:macos
- Requirements:proposal r4 What 1-5(可选 `additionalHapArtifactLeases` 与
  schema 数组型、引擎按序解析 N 条租约并逐条校验绑定、staged 目录 mint-only 与
  `mkdir -p`/`send ×N`/`bm install -p <dir>`/`rm -f ×N`+`rmdir` 的 lowering、
  判定不放宽、清理失败按 r3 residue 记录)
- Acceptance:change-local `DHA-MULTI-001`..`DHA-MULTI-003`,登记于 `verification.md`
- Depends on:TASK-DHA-001、TASK-DHA-002(均 done);r4 proposal 合入即 approved
- Hardware required:**部分**。contract 面不需要;`DHA-MULTI-003` 需要一套
  **多模块签名 HAP**(entry + feature),仓内与当前设备都没有,故该 AC 如实保持
  pending-hardware 且不阻塞任务 done(先例 UDR-AC-4)。**不得**以上次窗口
  "目录里放一个 HAP 成功"冒充多包已验证
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `scripts/catalog_gen/**`(字段类型词表与生成器 pin 必须同 PR 更新)
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/capability-registry.yaml`
  - `scripts/**`(仅上列 `catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(唯一一次同时动**输入 schema 的字段类型**与一个已发布 E1
  operation 的 send/install/cleanup 三条腿。三层约束:未提供附加租约时逐字节
  不变、N 条租约逐条过既有绑定校验且任一不符即零 dispatch、清理只用
  `rm -f`+`rmdir` —— **禁止 `rm -rf`**,沿用 native 族的既有安全形态)

## TASK-DHA-004 — 屏幕截图作为文件型产物(r5)

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准);
  DHA-SHOT-001..003 **全部 PASS**,含真机(`job-27e4878a…`,`screenshot.png`
  449,756 字节 / 720×1280 / PNG 魔数正确);顺带修复 r2 漏登记
  `optionalStepUpstream` 的组件树腿;evidence = `evidence/runs/TASK-DHA-004/run-r5.md`
- Platform:macos
- Requirements:proposal r5 What 1-5(三个 optional 步骤、`uiScreenshot` 输入与
  `screenshot.png` 产物、`-t png` 的真机确认形式与 `.png` owned 后缀、
  设备侧 size + host 侧 size/SHA-256 + PNG 魔数三层判定、file-backed 发布)
- Acceptance:change-local `DHA-SHOT-001`..`DHA-SHOT-003`,登记于 `verification.md`
- Depends on:TASK-DHA-003(done);r5 proposal 合入即 approved
- Hardware required:no(contract 面即可交付)。`DHA-SHOT-003` 需一次真机运行,
  设备与素材均已具备(截图不需要额外素材),预期同车关闭
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/**`
  - `scripts/**`(仅上列 `catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(第三条文件型采集腿,形态与 r2/r4 已验证的两条相同;
  唯一新面是 PNG 魔数校验与"设备按后缀校验类型"这条真机约束。
  三层约束:未请求时逐字节不变、魔数不符不发布、清理失败按 r3 residue 记录)

## TASK-DHA-005 — 崩溃日志作为一等 artifact(r6)

- Status:done
- Done:2026-07-31;随本实现 PR 合入生效(维护者 review + merge 即批准);
  DHA-CRASH-001..003 **全部 PASS**,含真机两次请求闭环(`job-0a7bc0f8…` 取索引、
  `job-62961c6f…` 按条目名取单条,两次均 E0 / defaultReadOnlyPolicy);
  实现对 r6 的 `crashLogName` pattern 有一处偏离(放宽为只约束形状,见 evidence);
  evidence = `evidence/runs/TASK-DHA-005/run-r6.md`
- Platform:macos
- Requirements:proposal r6 What 1-5(两个 readOnly stdout 步骤与对应契约 action、
  `crashLogs`/`crashLogName` 输入与两个产物、effect 不变、`crashLogName` 的
  pattern 收窄、空列表是正常结果而 `invalid parameters.` 是失败)
- Acceptance:change-local `DHA-CRASH-001`..`DHA-CRASH-003`,登记于 `verification.md`
- Depends on:TASK-DHA-004(done);r6 proposal 合入即 approved
- Hardware required:no(contract 面即可交付)。`DHA-CRASH-003` 需一次真机运行,
  **但设备当前被 CHG-2026-054 的 GJ-5 窗口占用** —— 真机复验须与那条道协调,
  不得抢占;协调不成则如实保持 pending-hardware,不阻塞任务 done
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/contracts/catalogs/diagnostics-stdout.yaml`
  - `openspec/contracts/workflow-step.schema.json`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/capability-registry.yaml`
  - `scripts/**`(仅上列 `catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:low(唯一一条**不升 effect** 的新采集腿:两条命令均只读、实测不改设备状态。
  唯一需要盯的是 `crashLogName` 这个调用方字符串 —— 以 pattern 收窄到条目名,
  不含 `/`、不可为路径或 shell 片段)

## TASK-DHA-006 — 发布判定镜像被替换文件的证明等级(r10)

- Status:done
- Done:2026-08-06;随本实现 PR 合入生效(维护者 review + merge 即批准);
  `DHA-VERITY-001`..`DHA-VERITY-003` **全部 PASS** —— 真机那条为
  `job-0ceaecb9fddb3596b564d6ff3549bc55`(DAYU200 / OpenHarmony 7.0.0.37,
  终态 succeeded,设备读回内容 hash 恰为租约值、属主逐项保持、
  publish 报告记 `attestation=matchesReplacedFile:none` 且不带 `fsVerityDigest`);
  evidence = `evidence/runs/TASK-DHA-006/run-r10.md`。
  **严格分支(原文件带 verity)真机未覆盖** —— 该机上不存在能被证明的文件,
  这正是本任务的发现本身;严格分支只由 contract 面覆盖,如实记在 evidence 里
- Platform:macos
- Requirements:proposal r10 What 1-4(替换前单独测量被替换文件的 fs-verity;
  helper `publish` 按该测量选择分支而非按调用结果;判定重述为"至少同等可证"
  且降级仍不可能;摘要如实记录实际达成的证明等级)
- Acceptance:change-local `DHA-VERITY-001`..`DHA-VERITY-003`,登记于 `verification.md`
- Depends on:TASK-DHA-001(done);r10 proposal 合入即 approved
- Hardware required:**是**。`DHA-VERITY-003` 需要一台 DAYU200 与一枚已签名的
  候选库;contract 面(001/002)用 scripted dispatcher 全覆盖,不占设备窗口。
  真机那条**不得**用 contract 结果冒充
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-049-diagnostics-and-hap/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、
    `openspec/verification/**`(全局)、`openspec/baselines/**`、
    `openspec/contracts/**`
  - `Catalog/**`(本任务不动 effect/authorization/步骤集)
  - `scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(改一个已发布 E1 operation 的**发布判定**,而且改的是安全属性那一条。
  三层约束:①原文件带 verity 时的行为逐字节不变,严格分支一条都不许松;
  ②enable 失败仍然到不了 `rename`,活库永远不被未通过校验的文件替换;
  ③"没有 verity"必须在摘要里如实可读,不得用空串或占位 hash 混过去。
  另有一条元约束:分支由**测量**决定,不由"enable 是否碰巧失败"决定——
  后者等价于"试一下,失败就算了",是本任务最想避免的形状)
