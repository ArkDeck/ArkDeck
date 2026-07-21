# CHG-2026-021 Tasks

> 分期实现;三任务各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零真机、零 evidence。真机采集由人类维护者亲手执行,Agent 零设备
> 命令。

## TASK-TR-001 — trace 工具 provenance 登记(integration 面,device-gated)

- Status:blocked(双前置:① CHG-2026-021 经 approval-only PR 批准;② 独立
  readiness PR——须记录采集 runbook/harness 选型、具名设备窗口、执行时 pins
  (hdc/设备 build)复核)
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

- Status:blocked(双前置:① approve;② 独立 readiness PR——须复核两 catalog
  pins、竞争面与基线)
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
