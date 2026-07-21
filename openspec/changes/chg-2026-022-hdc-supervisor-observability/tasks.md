# CHG-2026-022 Tasks

> 两任务分期,各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零真机、零 evidence。全程 host-only;真机观察本身属
> TASK-M0B-002(本 change done 后经新 readiness 解锁)。

## TASK-OBS-001 — Kit 仪表化与分类面

- Status:blocked(r2 review-remediation candidate；仅在本治理 PR 由维护者
  review/merge 后生效。r1 readiness 与 prototype #265 不可用于开工/合入)
- r1 readiness invalidation(2026-07-21;host-only review):
  - Approved gate 仍为 satisfied：r1 change 经
    `1e4a7c4027ecdd1142ceab2b80f4423eec586d6d` 批准；本 r2 不撤销 change，
    只撤销 TASK-OBS-001 readiness 结论。
  - r1 readiness commit 为
    `f3c9685ea70b32099c20bf7fe022bbc9aa688709`。当时三文件的精确 historical
    Git blob OID / file SHA-256 为：

    | File | Git blob OID | File SHA-256 |
    | --- | --- | --- |
    | `HDCProduction.swift` | `8a2e9599515997508acc03b678fd3a966adec5fe` | `3f74aa37d8d3f95354e2c944f11ceb9bcb6bbf972e5cbc5716da7a518a483c19` |
    | `ArkDeckOpenHarmony.swift` | `0626661efb81db412fff60b85c81adf397dcea85` | `2c529869beed6088b23753d2c36ef2fc6ca1ddbbf601b30e6eb18ea84eedadd3` |
    | `HDCApplicationDiagnosticsFacade.swift` | `9eab3cd5d3aad600b3576e90d059b161eb2987bc` | `1e37e67430b2d5da73dbbffbd5dd0a2897ce8e395977387669230b0dce5bb1cc` |

    r1 的 8-hex + ellipsis 不是精确 pin；上表只修复历史记录，不能作为未来
    readiness base。
  - Blocker FANOUT：macOS/current integration profile 没有任意设备枚举或
    zero-to-many snapshot family；selected-device authorization capture 不具备该
    语义。测试注入缓冲不能解锁 M0B-002。
  - Blocker COUNTER：不存在 automatic production caller；caller-supplied origin
    可伪造且不是唯一 successful-spawn hook。
  - Blocker OWNERSHIP：三证据未排除 active/unreconciled managed provenance，
    允许 registered observation 覆盖既有 managed claim。
  - Prototype PR #265 为 draft/invalidated diagnostics，不得 merge 为 TASK 完成，
    其中测试/evidence 不得被后续 readiness 复用或重判。
- Unblock prerequisites(全部满足后另起独立 `blocked→ready` PR):
  1. 独立 OpenHarmony integration change 已 approved/done，注册参数化 zero-to-many
     device snapshot family，并钉 exact argv/raw family、server identity bracket、
     empty/success/failure/unknown 与隐私语义；macOS profile 已同步。
  2. readiness 逐文件钉 actual implementation base 的完整 commit OID、Git blob OID
     或明确标注的完整 SHA-256；不得用省略前缀。
  3. readiness 复核 design §1 的 opaque confirmed/managed permit、caller 无 origin
     输入、identity-bound successful-spawn 唯一 hook 与 fake-process mutation seam
     均可在 allowed paths 内实现；若需修改 `ArkDeckProcess`，须显式列入文件级范围。
  4. ownership 四证据与 managed→external 禁止矩阵、external/unknown 授权门等价
     diff 测试已写成可执行验证计划。
  5. 重新审计与其他 open PR 的文件交集、Swift/SDD 环境及完整基线；不得引用
     #265 的 PASS 数字作为新 baseline evidence。
- Objective:supervisor 自动 lifecycle/subserver dispatch 计数器(成功 spawn 唯一
  hook + opaque permit + 变异可证伪)、ownership `.external` 判定(design §1 四证据)、
  endpoint source 与 child-env 注入清单暴露、只读设备 fan-out feed(有界环形
  缓冲);presentation 全量透出;contract 测试全绿。
- Requirements/AC:change-local `OBS-COUNTER-001`/`OBS-OWNERSHIP-001`/
  `OBS-ENDPOINT-001`/`OBS-FANOUT-001`(见 acceptance-cases.yaml;canonical Core
  AC 零认领——本 change 不改 Core 面)。
- Depends on:approve;M1-006 done(已满足);上述 integration producer 与 r2
  unblock prerequisites(未满足)。
- In scope:`Packages/ArkDeckKit/Sources/**`(OpenHarmony/Workflows 可观察性面)、
  对应 Tests、本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Out of scope:任何 lifecycle/dispatch/安全门语义变更;App UI(OBS-002);Core
  contract/schema;M1-009 导出接线。
- Risk:medium(触碰 supervisor 生产文件;不变量 = 零语义变更,须既有全量测试
  零回归 + 新增门语义 diff 测试背书)。
- Hardware required:no。
- Verification:四 change-local AC contract 测试逐条 PASS(成功 spawn 计数器
  变异实验、ownership 四证据/managed provenance 矩阵、endpoint source/child-env、
  production-source fan-out 差分);全量基线零
  回归;check-sdd 绿。
- Evidence gate:实现 + evidence run 合入且全部 AC 可判定后,`ready→done` 独立
  状态 PR。

## TASK-OBS-002 — App 观察面与 signed XCUITest

- Status:blocked(三前置:① r2 remediation merged;② TASK-OBS-001 done;③ 独立 readiness
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
