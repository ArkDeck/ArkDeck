# CHG-2026-022 Tasks

> 两任务分期,各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零真机、零 evidence。全程 host-only;真机观察本身属
> TASK-M0B-002(本 change done 后经新 readiness 解锁)。

## TASK-OBS-001 — Kit 仪表化与分类面

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。单文件、
  不含实现、不产生 evidence)
- Readiness review(2026-07-21;host-only,零设备命令):
  - Approve gate:satisfied(#254 squash `1e4a7c4`);design §0 硬不变量与五
    change-local AC 随批准生效。
  - 基座 pins(于 main `1e4a7c4` 实测,= #250 深查四缺口事实成立时点锚定):
    `HDCProduction.swift` blob `3f74aa37…`、`ArkDeckOpenHarmony.swift`
    `2c529869…`、`HDCApplicationDiagnosticsFacade.swift` `1e37e674…`。实现开工
    时任一漂移 → 重查缺口事实后再动工(并行会话防线)。
  - 基线:Swift 全量 302/1 skip/0 failures、check-sdd 0/0/111(均于 `1e4a7c4`
    实测);M1-006 语义不变量由既有全量套件承载,实现须零回归 + 新增门等价
    diff 测试(OBS-OWNERSHIP-001)。
  - 竞争面:复核时 open PR 为 0;**文件级分工**——本任务碰
    `Sources/ArkDeckOpenHarmony/**` 与 `Sources/ArkDeckWorkflows` 的 HDC
    supervisor/presentation 既有文件 + 新增测试,不新增/不触碰 `Trace*` 文件;
    与 TASK-TR-002(只新增 Trace* 新文件)零文件交集,可并行执行;App 面属
    OBS-002 不在本任务。
  - 实现序:计数器(真实调用点 + 变异测试)→ ownership 三证据矩阵 + 门等价
    测试 → endpoint source/child-env 暴露 → 只读设备 fan-out feed(有界缓冲)
    → presentation 透出 → 四 AC contract 测试逐条 PASS → evidence run。
  - Review boundary:本 readiness 只翻转状态并记录 pins/分工/序;实现仍须满足
    全部 change-local AC/verification gate(任何门语义 diff 整体 fail);
    `ready→done` 另用独立状态 PR。
- Objective:supervisor 自动 lifecycle/subserver dispatch 计数器(真实调用点,
  变异可证伪)、ownership `.external` 判定(design §1 三证据,缺一保持 unknown)、
  endpoint source 与 child-env 注入清单暴露、只读设备 fan-out feed(有界环形
  缓冲);presentation 全量透出;contract 测试全绿。
- Requirements/AC:change-local `OBS-COUNTER-001`/`OBS-OWNERSHIP-001`/
  `OBS-ENDPOINT-001`/`OBS-FANOUT-001`(见 acceptance-cases.yaml;canonical Core
  AC 零认领——本 change 不改 Core 面)。
- Depends on:approve;M1-006 done(supervisor 基座,已满足)。
- In scope:`Packages/ArkDeckKit/Sources/**`(OpenHarmony/Workflows 可观察性面)、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Out of scope:任何 lifecycle/dispatch/安全门语义变更;App UI(OBS-002);Core
  contract/schema;M1-009 导出接线。
- Risk:medium(触碰 supervisor 生产文件;不变量 = 零语义变更,须既有全量测试
  零回归 + 新增门语义 diff 测试背书)。
- Hardware required:no。
- Verification:四 change-local AC contract 测试逐条 PASS(计数器变异实验、
  ownership 三证据矩阵、endpoint source/child-env、fan-out 差分);全量基线零
  回归;check-sdd 绿。
- Evidence gate:实现 + evidence run 合入且全部 AC 可判定后,`ready→done` 独立
  状态 PR。

## TASK-OBS-002 — App 观察面与 signed XCUITest

- Status:blocked(三前置:① approve;② TASK-OBS-001 done;③ 独立 readiness
  PR——须钉 OBS-001 交付 hash 与 XCUITest 环境(DevMode/repo 根硬链)复核)
- Objective:HDCStatusView 新增计数/endpoint source/ownership 依据/设备事件列表
  字段(static-text 可访问 id,design §2),signed XCUITest 覆盖;M0B-002 四观察
  点的 App 取证载体就位(design §3 映射)。
- Requirements/AC:change-local `OBS-APPFACE-001`(见 acceptance-cases.yaml)。
- Depends on:approve、TASK-OBS-001 done。
- In scope:`ArkDeckApp/**`、`ArkDeckAppUITests/**`、本 change `evidence/**`、
  本 change `tasks.md`(仅本任务状态)。
- Out of scope:Kit 语义(OBS-001 已定);诊断导出接线;真机观察执行。
- Risk:low-medium(UI 面;XCUITest 环境依赖如实记录)。
- Hardware required:no(XCUITest 用 fixture 门;真机观察属 M0B-002)。
- Verification:`OBS-APPFACE-001` XCUITest PASS(新字段存在+值形态+可访问性)、
  生产路径零 fixture 断言、全量零回归。
- Evidence gate:同 OBS-001 形态;done 后 TASK-M0B-002 具备新 readiness 条件。
