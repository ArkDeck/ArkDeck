# CHG-2026-019 Tasks

## TASK-PI-001 — App-root participant registry 与 production inventory feed

- Status:ready(readiness;仅在维护者 review/merge 本独立状态 PR 后生效。前置 ① 已满足:
  approval-only PR #200 已合入 main squash `94fe6f8`(lvye review/merge);本 PR 即前置 ②,
  单文件、不含实现、不产生 evidence)
- Readiness(2026-07-21,执行时 pins 于 main `94fe6f8` 逐项复核):
  - Approve 链:propose PR #198(squash `10f585e`)→ approval-only PR #200(squash
    `94fe6f8`);design.md 自批准以来零字节变更。
  - 目标代码面零并行改动:`ArkDeckWorkflows`/`ArkDeckContractTests`/`ArkDeckApp*` 的
    最后触碰 commit 仍为 TASK-M1-006 实现合入 `c61e10e`(#191);#193-#200 仅动
    openspec。design.md 引用的 API 基座(`HDCApplicationDiagnosticsHost.compose` 的
    `impactInventory` 参数、`HDCApplicationHostImpactInventory`、facade 的
    `.unavailable` feed)在位。
  - 环境:`DevToolsSecurity -status` = "Developer mode is currently enabled.";signed
    XCUITest 须解锁态执行(M1-006 addendum 21 先例);Swift 基线于 `94fe6f8` 实测
    284 tests / 1 skip / 0 failures;`./scripts/check-sdd.sh` 0/0/111。
  - 竞争面:复核时 open PR 仅 chg-018 治理文件(verify #201),与本任务 allowed paths
    零交集。
  - 实现序:实现 + evidence PR(经维护者 review/merge)→ `done` 独立状态 PR。开工前
    若 main 前进且触及上述目标代码面,readiness 作废须重新起草;仅 openspec 前进则
    复核 approve 链后继续。
- Objective:按 design.md 交付 `HDCApplicationParticipantRegistry` 与 production inventory
  feed,使 `HDCApplicationDiagnosticsHost.compose` 在 production 收到构造性完备的
  `.complete` inventory(当前产品态为空但完备),关闭 TASK-M1-006 closeout 缺口 ①。
- Requirements/AC:零 Core Requirement/AC 变更;交付面由 change-local
  `PI-HDC-INVENTORY-001`、`PI-HDC-INVENTORY-002` 验收(不计入 canonical 111)。
- Depends on:
  - TASK-M1-006 实现合入(#191 squash `c61e10e`;host/inventory/receipt API 是本任务的
    既有基座,本任务不改其安全语义)
  - CHG-2026-018(并行推进;本任务不依赖其 merge,但 M1-006 的后续 closeout 修订需要
    两者都落地)
- In scope:design.md 目标形态;contract 专段;signed Sandbox XCUITest 断言更新;evidence。
- Out of scope:ArkDeckOpenHarmony/Core/Process/Storage Sources;Supervisor 安全不变量
  修改;Flash/Dump 功能接线;TASK-M1-006 状态;specs/contracts/platform/integration 文件。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/**`(registry + facade feed)
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HDCSupervisorContractTests.swift`
  - `ArkDeckApp/App/ArkDeckApp.swift`(仅 root 组合接线)
  - `ArkDeckApp/Features/HDC/HDCStatusView.swift`(仅 unavailable 理由展示适配)
  - `ArkDeckApp/Resources/Localizable.xcstrings`(仅相应 key)
  - `ArkDeckAppUITests/HDC/HDCStatusUITests.swift`
  - `openspec/changes/chg-2026-019-hdc-app-root-participant-inventory/evidence/**`
  - `openspec/changes/chg-2026-019-hdc-app-root-participant-inventory/tasks.md`(仅本任务
    状态与 completion evidence)
- Forbidden paths:`Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/**`、
  `.../ArkDeckCore/**`、`.../ArkDeckProcess/**`、`.../ArkDeckRuntime/**`、
  `.../ArkDeckStorage/**`、`Packages/ArkDeckKit/Package.swift`、
  `openspec/specs/**`、`openspec/verification/**`、`openspec/integrations/**`、
  `openspec/platforms/**`、`openspec/contracts/**`、其他 change 的任何文件,以及上述
  清单以外的一切。
- Risk:medium(App-root 组合层;不触 Supervisor 安全不变量,只满足其 receipt 要求;
  最坏错误方向=假完备,由构造性封闭+contract 静态断言+维护者 review 拦截;验证仅
  fake/loopback/签名本地 build,无真实 hdc/设备/网络)
- Hardware required:no
- Required environment:macOS + 仓库 Swift/Xcode toolchain + 可产生签名 Sandbox test build
  的解锁环境(M1-006 addendum 21 先例);不执行真实 `hdc`,fixture 仅 loopback。
- Deliverables:registry + production feed 实现;contract 专段(计数仪表化);signed
  XCUITest 更新;实现 PR 声明 package/App import contract 与公开 API 变更(若有)。
- Verification:`TEST-PI-HDC-INVENTORY-001`(contract)与
  `TEST-PI-HDC-INVENTORY-002`(platform/signed UI),见本 change
  verification.md/acceptance-cases.yaml。Commands:`swift format lint <changed files>`;
  `CI=true swift test --package-path Packages/ArkDeckKit --filter HDCSupervisorContractTests`;
  `CI=true swift test --package-path Packages/ArkDeckKit`;
  `xcodebuild test -project ArkDeck.xcodeproj -scheme ArkDeck -destination 'platform=macOS'`
  (signed)+ `codesign --verify`;`./scripts/check-sdd.sh`;`git diff --check`。
- Evidence gate:在 `evidence/runs/TASK-PI-001/run.md` 记录 base revision、全部命令结果、
  构造性完备论证与静态断言输出、两 Test ID 二值结论、signed 产物 hash/entitlements、
  与 M1-006 既有 evidence 的边界(不代办其 AC)。缺任一项不得标 `done`;`done` 翻转须
  独立状态 PR。
