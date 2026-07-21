# CHG-2026-021 Tasks

> 分期实现;三任务各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零真机、零 evidence。真机采集由人类维护者亲手执行,Agent 零设备
> 命令。

## TASK-TR-001 — trace 工具 provenance 登记(integration 面,device-gated)

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。单文件、
  不含实现、不产生 evidence、不执行真机)
- Readiness review(2026-07-21;host-only,零设备命令):
  - Approve gate:satisfied(#253 squash `684c42c`);design §0 候选命令面、§4
    登记形态随批准生效。
  - 执行时 pins(本 readiness 实测复核):hdc = DevEco toolchains 路径,SHA-256
    `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`、
    `Ver: 3.2.0d`(与 M0B/I15 pinned tuple 逐字一致);设备 = DAYU200 OpenHarmony
    7.0.0.34(M0B evidence `EVD-M0B-DAYU200-20260718-001`)。采集前须再复核,
    任一漂移即停。
  - runbook/harness:属本任务实现交付物(in scope 既列)——封闭白名单
    (hitrace/bytrace 存在/help/tag-list 探测 + 最小 capture + recv)在实现 PR
    起草并经维护者 review 后方可用于窗口;形态复用 m0b/ud harness 信任链
    (argv 无 shell、分流 byte-exact、敏感自检、redacted manifests)与既有
    redaction 工具链;白名单外命令零授权。
  - 具名设备窗口:维护者自选的连续设备窗口,窗口内无其他设备操作并行(与
    TASK-M0B-002、chg-008 Phase B 等互斥,可同日先后);执行前在 run.md 记录
    实际日期/时段。
  - 执行模型:维护者亲手跑 runbook,Agent 零设备命令、只起草/核验/起草
    evidence;trace 采集含 deviceMutation 级 capture(非 destructive),参数
    set/restore 若用须逐项确认+readback+恢复;中止如实记录 blocked-attempt。
  - Review boundary:本 readiness 只翻转状态并记录 pins/窗口/执行模型;实现
    (runbook+采集+登记)仍须满足 TRACE-PROV-001 与 verification gate;
    `ready→done` 另用独立状态 PR。
- Objective:在 DAYU200 真机受控采集 hitrace/bytrace 的存在/help/tag-list/最小
  capture 输出,登记版本化 trace probe/golden registry(design §4 形态),bump
  OPENHARMONY-TOOLS 与 INTEGRATION-PROFILES.lock。
- Requirements/AC:change-local `TRACE-PROV-001`(见 acceptance-cases.yaml);为
  TASK-TR-003 的 `AC-TRACE-001-01`/`AC-TRACE-007-01`(parserGolden)提供 fixture
  事实前置。
- Depends on:approve;M0B-001 done(设备/授权/工具链事实,已满足);采集 harness
  (scripts/ud_capture 或 m0b_capture 复用评估归 readiness)。
- In scope:采集 runbook(Agent 起草、维护者执行)、registry + golden fixtures +
  hash closure + redacted manifests、integration profile/lock bump、evidence run。
- Out of scope:adapter 实现(TR-003);Core/spec 改写;trace 之外命令。
- Allowed paths(approve/readiness 后细化):`openspec/integrations/**`、
  `scripts/**`(采集 harness 若需新增)、本 change `evidence/**`、本 change
  `tasks.md`(仅本任务状态)。
- Risk:medium(真机在场;采集含 deviceMutation 级 capture 与可选参数 set/restore,
  非 destructive;设备窗口与其他设备任务互斥)。
- Hardware required:yes(物理 DAYU200 + USB;操作者=维护者)。
- Verification:registry/golden 逐文件 SHA-256 closure、redaction 自检、
  `TRACE-PROV-001` documentReview;中止如实记录 blocked-attempt。

## TASK-TR-002 — host contract 面(typed trace workflow,零设备)

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。单文件、
  不含实现、不产生 evidence)
- Readiness review(2026-07-21;host-only,零设备命令):
  - Approve gate:satisfied(#253 squash `684c42c`);三任务 scope/design 约束/
    认领面随批准生效。
  - 基座 pins(于 main `1e4a7c4` 实测):catalog `trace-presets`@1.0.0
    (`12c0f050…`)与 `attachment-debug-profile`@1.0.0(`10ee4c38…`)已登记
    INTEGRATION-PROFILES.lock 0.4.0;所需 WorkflowStep kind 全部在 CORE-2.1.0
    契约在案(design §1 映射)。实现时 catalog hash 漂移即停。
  - 基线:Swift 全量 302/1 skip/0 failures、check-sdd 0/0/111(均于 `1e4a7c4`
    实测)。
  - 竞争面:复核时 open PR 为 0;**文件级分工**——本任务只在
    `Sources/ArkDeckWorkflows` 新增 `Trace*` 前缀新文件 + 对应 Tests 新文件,
    不触碰 `HDC*`/`Rockchip*`/`Simulated*` 既有文件;与 TASK-OBS-001
    (CHG-2026-022,supervisor 既有文件面)零文件交集,可并行执行;与 chg-008
    线零交集。
  - 实现序:typed trace workflow(catalog 消费/capability 受限配置 → 参数
    snapshot/set-readback/restore(catalog 绑定收紧,design §3)→ 隔离接收/
    partial → progress/completeness → reboot/rebind 面)→ 7 条 contract AC 测试
    逐条 PASS → evidence run。fake/fixture 一律显式标注,不冒充已登记 adapter
    形态(TR-001 未 done,不实现任何真实输出解析)。
  - Review boundary:本 readiness 只翻转状态并记录 pins/分工/序;实现仍须满足
    全部认领 AC/verification gate;`ready→done` 另用独立状态 PR。
- Objective:实现 typed trace workflow 的 host contract 面:capability 受限配置
  (trace-presets catalog)、参数 snapshot/set-readback/restore(绑定
  attachment-debug-profile,design §3 收紧)、隔离接收/partial、honest progress、
  artifact completeness、reboot→binding 恢复;contract 测试全绿。
- Requirements/AC:认领 `AC-TRACE-002-01`/`003-01`/`004-01`/`005-01`/`006-01`/
  `008-01`/`009-01`(7 条,canonical method 均 contract);复用 M1 seam(design §1)
  不改其语义。
- Depends on:approve;两 catalog 已登记(lock 0.4.0,满足);无 TR-001 依赖
  (不实现真实 adapter 解析)。
- In scope:Sources/ArkDeckWorkflows trace workflow + 对应 contract 测试 + evidence
  run;fake/fixture 一律显式标注,不冒充已登记 adapter 形态。
- Out of scope:hitrace/bytrace 真实输出解析(TR-003);CLI/UI 接入(独立后续);
  Core kind/schema 变更。
- Allowed paths(approve/readiness 后细化):`Packages/ArkDeckKit/Sources/**`、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low-medium(host-only;deviceMutation 语义面须 fail-closed 方向)。
- Hardware required:no。
- Verification:7 AC contract 测试逐条 PASS 行、全量基线零回归、check-sdd 绿。

## TASK-TR-003 — adapter golden 面(hitrace/bytrace 识别与 ftrace 过滤)

- Status:blocked(三前置:① approve;② TASK-TR-001 done(golden fixture/registry
  在案);③ 独立 readiness PR——须钉 TR-001 登记的 registry/fixture hash)
- Objective:实现 adapter 选择(help family 识别,未知 fail-closed)与 ftrace
  header 保留过滤,against TR-001 golden fixture;parserGolden 测试全绿。
- Requirements/AC:认领 `AC-TRACE-001-01`/`AC-TRACE-007-01`(parserGolden)。
- Depends on:approve、TASK-TR-001 done、TASK-TR-002 done(workflow 骨架)。
- In scope:adapter family 解析器 + golden 测试 + evidence run。
- Out of scope:未登记 family 的任何支持声明;新固件族。
- Allowed paths(approve/readiness 后细化):`Packages/ArkDeckKit/Sources/**`、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(host-only,golden 驱动)。
- Hardware required:no(fixture 已由 TR-001 登记)。
- Verification:2 AC parserGolden 测试 PASS、fixture hash 与 registry closure 一致。
