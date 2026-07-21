# CHG-2026-020 Tasks

> 分期实现;两 task 各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零 Swift、零真机、零 evidence。真机烧写由人类维护者亲手执行(REQ-FLASH-015),
> Agent 零 destructive 设备命令。

## TASK-RF-001 — 阶段 A:契约/Profile 定义与人工真机正向烧写特征化

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。前置 ① 已满足:
  approval-only PR #226 已合入 main squash `7f5cb1b`(lvye review/merge);本 PR 即前置 ②,
  单文件、不含实现、不产生 evidence、不执行真机)
- Readiness review(2026-07-21;host-only,零设备/写命令 dispatch):
  - Approve gate:satisfied。CHG-2026-020 approved(#226 squash `7f5cb1b`);DEC-002 正向
    决策方向(Rockchip RockUSB Loader 态 `wlx`)、两阶段 scope 与 design §0 封闭命令面、
    `images.tar.gz` 契约/`RockchipFlashProfile` 形态、REQ-FLASH-* 认领面均随批准生效。
  - 书面风险确认(REQ-FLASH-015/RISK 先例):载体 = 维护者 review/merge 本 readiness PR。
    残余风险 = 真机 destructive 写设备可能变砖;**风险显著降低**——恢复路径已经
    CHG-2026-016 attempt #5(#220/#224 verified)真机验证可行(Loader 态 `wlx` over 既有
    分区表),即使正向烧写失败亦可用同一路径恢复。`userdata` 清数据须执行时显式强确认。
  - 具名设备窗口:维护者自选的首个连续设备窗口,窗口内无其他设备操作并行;执行前在
    run.md 记录实际日期/时段。
  - 执行时 pins(本 readiness 于 main `7f5cb1b` 实测复核):
    - `rkdeveloptool`:SHA-256 `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`、
      `-v` = `rkdeveloptool ver 1.32`(与 TASK-RR-001/CHG-016 pinned 一致);
    - 首验 `images.tar.gz`:CHG-2026-003 archived pinned 包(size `732948803`、SHA-256
      `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`,17 成员逐文件
      hash vs archived `member-inventory.json`——阶段 A 首验刻意用已验证 pinned 包,
      = 恢复演练的正向产品化,不引入未验证镜像);
    - 恢复路径:CHG-2026-016 验证的 Loader 态 `wlx` 恢复路线(RecoveryGuide 依据);
    - 地址/分区基线:FA-001 §2(15 行锚定 PD-002 `965e3bf3…`)、PD-002 mapped 9 分区,
      于 main 在案不改写。
  - 实现序:实现 PR 先定义 `images.tar.gz` 契约 + `RockchipFlashProfile`
    (RF-CONTRACT-001 documentReview)→ 据此生成 exact plan → 人类维护者按 design §0
    真机正向烧写(RF-REALFLASH-001,Agent 零设备命令、只起草 crib/核验/起草 evidence)→
    `hardware-matrix.md` supported 行。REQ-FLASH-015 的 exact-plan 人工确认在执行时每个
    真机 Step 前按 design §4 落地。执行前须再复核工具/包 hash(design §1),任一漂移即停。
  - Review boundary:本 readiness 只翻转状态并记录风险确认载体/窗口/pins;实现仍须满足
    全部认领 AC/verification gate;`ready→done` 另用独立状态 PR;真机由维护者亲手执行。
- Objective:定义 `images.tar.gz` 输入契约与 `RockchipFlashProfile`(允许分区/hash/大小/
  写序),并由人类维护者按 design §0 封闭命令面在 DAYU200 真机正向烧写一个 pinned
  `images.tar.gz`,产出 realHardware evidence;`hardware-matrix.md` 新增 DAYU200/Rockchip
  supported 行(REQ-FLASH-014:≥1 设备完整验收)。
- Requirements/AC:认领 `REQ-FLASH-003`(镜像校验/exact plan)、`REQ-FLASH-014`(hardware
  evidence)、`REQ-FLASH-015`(Agent/CI 边界的人工执行面)的 DAYU200 realHardware 面;
  `AC-FLASH-003-01`、`AC-FLASH-014-01`、`AC-FLASH-015-01/02`(逐项 ownership 见
  verification.md);change-local `RF-CONTRACT-001`(契约/Profile documentReview)。
- Depends on:CHG-2026-016 verified(命令面/恢复路径实证,#220/#224)、PD-002 done
  (分区映射)、FA-001 done(地址/寻址语义)、DEC-001 decided(DAYU200)。
- In scope:契约 + Profile 定义文档;人工 crib(正向烧写,恢复演练 crib 的正向产品化,
  Agent 起草/维护者执行);`hardware-evidence.json`(schema 2.0.0)+ 脱敏 transcript +
  postflight 对照;hardware matrix supported 行。
- Out of scope:Swift Provider(TASK-RF-002);产品 CLI;DAYU200 以外设备;改 Core/恢复演练。
- Allowed paths(approve/readiness 后细化):`openspec/changes/chg-2026-020-dayu200-real-flash/**`、
  `openspec/verification/hardware-matrix.md`(仅新增 supported 行,REQ-FLASH-014)。
- Risk:high(写设备 destructive;残余风险=变砖,须 RISK/书面确认;userdata 清数据须显式
  强确认;真机由人类执行,Agent 零设备命令)。
- Hardware required:yes(物理 DAYU200 + USB;操作者=维护者)。
- Verification:见 verification.md;真机由人类执行,Agent 核验/起草 evidence;中止如实记录
  为 blocked-attempt(恢复演练先例)。
- Evidence gate:契约/Profile documentReview + 人工真机正向烧写全流程 evidence(逐命令
  argv/输出/判定、hash 校验、destructive 确认、postflight、operator/窗口/恢复路径)全部
  可判定后合入;`ready→done` 独立状态 PR;hardware matrix supported 行须真实验收背书。

## TASK-RF-002 — 阶段 B:RockchipRockUSBFlashProvider 与 `arkdeck flash` 接入

- Status:blocked(双前置:① 本 change 批准;② 独立 readiness PR;另须 TASK-RF-001 的
  Profile/契约/命令面 evidence 作为实现基座。均须维护者 review/merge)
- Objective:实现 typed `RockchipRockUSBFlashProvider`(`probe`/`validate`/`makePlan`/
  `recover` + typed `FlashStep`),接入 `arkdeck flash images.tar.gz`;落地 destructive
  确认、critical write 安全边界、postflight 语义校验、bounded recovery 与 REQ-FLASH-015
  Agent/CI 边界(execute+真实 binding 并存 fail closed、真机由人类执行、精确人工确认 gate)。
- Requirements/AC:认领 `REQ-FLASH-001/002/004/007/008/012/013/015` 的 DAYU200 Provider
  面(contract + realHardware);逐项 AC ownership 见 verification.md;复用 M1-008 的
  mode/journal/manifest seam,不改其语义。
- Depends on:TASK-RF-001(Profile/契约/命令面 evidence)、M1-008 done(simulated seam)、
  M1-006 done(HDC/process/durable 边界)、CHG-2026-016 verified(recovery 路径)。
- In scope:Swift Provider + typed FlashStep + 安全门 + CLI 接入 + contract 测试 + 人工
  执行 gate 的仪表化证据;真机验收沿用 TASK-RF-001 的人工执行模型。
- Out of scope:改 Core flashing REQ/AC/contract/schema;DAYU200 以外设备;Provider 之外的
  产品功能。
- Allowed paths(approve/readiness 后细化):`Packages/ArkDeckKit/Sources/**`(Flash
  Provider/Workflows 组合)、对应 Tests、App CLI 接入、本 change evidence。
- Risk:high(destructive 产品功能;Agent/CI 边界是核心安全不变量,fail-closed 方向)。
- Hardware required:真机验收 yes(人类执行);contract/simulated 面 no。
- Verification:见 verification.md;Agent/CI destructive dispatch 恒 0(仪表化)、人工确认
  gate 的 mismatch/缺失 fail closed、critical write 安全边界、postflight、recovery honest。
- Evidence gate:contract 全绿 + 真机验收(人类执行)evidence + Agent-boundary 仪表化零
  dispatch 全部在案后合入;`ready→done` 独立状态 PR。
