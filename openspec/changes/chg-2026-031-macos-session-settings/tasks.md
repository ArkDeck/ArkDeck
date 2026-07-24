# CHG-2026-031 Tasks

> proposal、approval、readiness、implementation/evidence、done、verified 分离。
> 两项任务均 host-only，测试只使用临时 Session fixture；不得读取或删除用户真实
> Session。proposal 合入不使任何任务 ready。

## TASK-SSET-001 — Settings、retention catalog 与 production storage wiring

- Status:blocked（前置：change approval + 独立 readiness PR；readiness 须钉定
  DEC-006、Storage/manifest contracts、production root、Xcode/Swift 基线、精确
  allowed-path consumers 与临时 fixture 边界）
- Platform:macos
- Requirements:`REQ-ART-001`、`REQ-ART-006`、`REQ-STO-001`、
  `REQ-STO-003`、`REQ-STO-004`
- Acceptance:`AC-ART-006-02`、`AC-STO-001-01`、`AC-STO-003-01`、
  `AC-STO-004-01`、`SSET-CONFIG-001`、`SSET-CATALOG-001`、
  `SSET-RETENTION-001`
- Depends on:change approval
- Readiness input pins:由独立 readiness PR 固定，不在 proposal 预填未来 OID
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-007`、`AF-008`、
  `AF-010`、`AF-017`
- Production reachability:
  `RockchipFlashExecutionHost.init` → `SessionStorageApplicationRuntime`
  settings/root lease/shared coordinator → `SessionStore.createSession`；
  App Settings facade → generation-bound user confirmation →
  `SessionRetentionController.apply`。本任务无 device effect。
- Trusted fact sources:locked manifest 生产 `sessionID/completedAt`；Storage
  descriptor/filesystem probes 生产 root/size/volume；versioned catalog 生产 pin 与
  generation；UserDefaults 只搬运 settings/bookmark，不自证可访问性，bookmark 每次由
  URL/security scope 重新验证。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionManifest.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/SessionRetentionCatalog.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/HostStorage.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionHost.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SessionSettings/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/ArkDeckContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/SessionSettingsContractTests.swift`
  - `openspec/changes/chg-2026-031-macos-session-settings/evidence/**`
  - `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `ArkDeckApp/**`
  - `ArkDeckAppUITests/**`
  - `ArkDeck.xcodeproj/**`
- Risk:medium（host-local delete 与 production root composition；所有删除只在临时
  fixture 验证，真实 App effect 留给用户确认）
- Hardware required:no

### Deliverables

- typed settings snapshot/store、default/custom root access lease 与具名错误；
- secure retention catalog、versioned pin metadata、保守 size/unknown classification；
- shared storage runtime、preview/confirm/apply/rescan/admission state machine；
- Rockchip production Session root/shared coordinator wiring；
- hermetic contract/fault tests 与 task run evidence。

### Verification

- `SSET-CONFIG-001`：默认值、合法持久化、损坏配置、bookmark reopen/stale/path
  mismatch/reset contract；
- `SSET-CATALOG-001`：valid/partial/pinned/unknown/symlink/identity mismatch/overflow
  fixture matrix；
- `SSET-RETENTION-001` 与 canonical AC：expired-first、oldest-first、pin protection、
  generation drift、confirm-before-apply、partial failure/rescan、actual admission state；
- production composition contract 证明 settings root 被真实 `SessionStore` consumer
  使用，断开 bookmark/confirmation 时 create/delete effect = 0；
- `swift test --package-path Packages/ArkDeckKit`、`scripts/check-sdd.sh`、
  `git diff --check` 全绿。

### Notes / handoff

- implementation/evidence PR 不翻 `ready→done`；done 使用独立 D0 状态 PR。
- 如果需要 locked schema、自动删除、用户真实目录或 task allowed paths 之外的消费者，
  立即 blocked 并修订 change，不在实现 PR 扩 scope。

## TASK-SSET-002 — macOS Settings UI 与 signed UI contract

- Status:blocked（前置：change approval、TASK-SSET-001 done、独立 readiness PR；
  readiness 须固定 facade API、Xcode project groups/target、String Catalog、signed
  Sandbox entitlement 与 UI fixture 零 delete-port 证明）
- Platform:macos
- Requirements:`REQ-ART-006`
- Acceptance:`AC-ART-006-02`、`SSET-UI-001`
- Depends on:change approval、TASK-SSET-001 done
- Readiness input pins:由独立 readiness PR 固定，不在 proposal 预填未来 OID
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-007`、`AF-010`、
  `AF-013`、`AF-017`
- Production reachability:
  `ArkDeckApp.body Settings scene` → `SessionSettingsApplicationFacade.make()` →
  TASK-SSET-001 runtime；fixture facade 的
  `retentionApplyIsProductionComposed=false` 且没有 delete port。
- Trusted fact sources:UI 只呈现 facade snapshot；root/bookmark、catalog、size、pin、
  plan/admission 事实均来自 TASK-SSET-001，accessibility label 或 fixture text 不作为
  production authority。
- Allowed paths:
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/Settings/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Settings/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-031-macos-session-settings/evidence/**`
  - `openspec/changes/chg-2026-031-macos-session-settings/tasks.md`
- Forbidden paths:
  - `AGENTS.md`
  - `openspec/constitution.md`
  - `openspec/governance/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `openspec/changes/archive/**`
  - `Packages/ArkDeckKit/Sources/**`
  - `Packages/ArkDeckKit/Tests/**`
- Risk:medium（用户可见删除确认 UI；fixture 与 production dispatch 必须结构隔离）
- Hardware required:no

### Deliverables

- Settings scene、view model、输出根 picker/reset、quota/margin/days validation；
- Session/pin/unknown/admission 列表、exact cleanup preview 与二次确认；
- 中英文 strings、accessibility identifiers、signed XCUITest；
- UI task run evidence。

### Verification

- `SSET-UI-001` signed XCUITest：默认值、validation、choose/reset、relaunch bookmark
  presentation、pin/unpin、preview/cancel/confirm、stale/reselection、blocked-heavy-writer
  文案与 accessibility；
- fixture route 静态/运行时断言 production delete dispatch 不可达，production facade
  composition test 证明按钮只在真实 facade + fresh confirmation 时可用；
- signed Debug build entitlement 包含既有 app-scope bookmark 与 user-selected
  read-write，entitlement 集不扩大；
- UI suite、全量 Swift suite、`scripts/check-sdd.sh`、`git diff --check` 全绿。

### Notes / handoff

- UI implementation PR 不携带 TASK-SSET-001 source 修改或状态翻转。
- signed UI evidence 只证明 macOS host UI/permission contract，不是用户数据删除证据，
  更不是 hardware evidence。
