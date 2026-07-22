# Tasks — CHG-2026-026 macOS Rockchip Flash UI

> PR #297 只登记 proposal；本独立 governance/readiness PR 同时起草 change
> `proposed→approved` 与 TASK-RKFUI-001 `blocked→ready`，仅在维护者 review/merge 后生效。
> 其余任务继续 `blocked`。每个实现任务单独 PR，不混入 readiness/status PR。

## TASK-RKFUI-001 — RockUSB discovery contract 与 signed Sandbox E0 access spike

- Status:ready（仅在维护者 review/merge 本独立 governance/readiness PR 后生效；只允许
  contract/fake 与具名窗口内 E0/read-only access spike，零 mode switch、零
  mutation/destructive）
- Readiness review（2026-07-22；host-only 审计，真实 `rkdeveloptool ld`/HDC/device
  dispatch 0）：
  - Approval gate:on merge。PR #297 仅登记 `status: proposed` proposal；本 PR 明确承载
    CHG-2026-026 `proposed→approved` 与本任务 `blocked→ready`，两者由维护者一次 review
    后同时生效。批准的 `REQ-FLASH-015` 解释、E0-only 边界与其他任务继续 blocked 见
    `proposal.md` 的 Approval and readiness boundary。
  - Objective/scope gate:satisfied。目标只包括 strict `ld` discovery contract、固定 executable
    URL + argv adapter 与 signed Sandbox 非提权 E0 spike；in/out scope、allowed/forbidden
    paths、两条 canonical AC、deliverables 与二值 verification 均已固定，不需要执行 Agent
    新做产品或 Safety 决策。
  - Base/input pins:proposal base = `main`
    `88dee1dc83d4e9e4675ea36803d5b261f1cdf3da`；实现必须基于本 readiness 合入后的
    `main`，开始前重核下列 SHA-256，任一漂移即停并重做 readiness：
    - `Packages/ArkDeckKit/Package.swift` =
      `60bd68200aa8d25eb209e5fdd6f9d1e20594af07743849841f31defa4b9b5175`；
    - read-only Provider/Profile/Authorization inputs 分别为
      `81ff71a69f4dd3556de38d5fdf15526e57015529f23384d0fe6832ca32f86eee`、
      `62c51f992654303ed0237b27c1642462dd1d8531b4d4a29661e718c962c2537b`、
      `e3b6cdc334410b67d93782184c705ab55cdefb2cd4340f8c6fe0b35970552edb`；
      本任务只读消费，禁止修改；
    - discovery source/test、Rockchip fixtures/registry、integration directory 与 E0 probe
      script 在 base 均不存在（零路径碰撞）；实现只能在 Allowed paths 新建。
  - Toolchain gate:satisfied。维护者选择的仓库外 executable 于 readiness 重核为
    `rkdeveloptool ver 1.32`、SHA-256
    `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`，与已归档
    CHG-2026-016/TASK-RR-001 pin 一致，来源为官方 upstream commit
    `304f073752fd25c854e1bcf05d8e7f925b1f4e14`。实现/真机 E0 只能由用户显式选择并经
    security-scoped access 获取该 exact identity；禁止 PATH lookup，版本/hash/source
    任一不符即 fail closed。
  - Environment gate:satisfied。macOS 26.5.2、Xcode 26.6 (17F113)、Apple Swift 6.3.3
    可用；任务本身负责生成 signed Sandbox 目标并验证 direct non-elevated access，若目标
    交付形态不能在零 sudo/helper/install/ACL/group/rule modification 下执行，则如实记录
    blocked result，TASK-RKFUI-003 继续 blocked。
  - Hardware/window gate:satisfied for spike。目标为维护者 @lvye 控制的 DAYU200 + USB；
    使用本 readiness 合入后维护者明确开始的首个连续 E0 窗口，并与其他设备任务互斥。
    维护者只负责按已验证物理序列把设备置于 Loader；Agent/App 不发送进态命令。spike 仅可
    执行 exact `["ld"]` 并只接受 semantic `0x2207:0x350a + Loader`；normal/HDC、
    `0x5000`、Maskrom、未知、多候选或权限失败均阻断，不允许用 VID/PID/单设备假设补全身份。
  - Verification/evidence gate:satisfied。contract/golden/fault tests 覆盖 success、malformed、
    multi-device、Maskrom 与相似 family；真实 E0 run 记录 tool identity、signed target、
    entitlements、direct invocation、USB result 与 typed verdict，serial 仅留摘要。fake/simulation
    与 realHardware 分类分离；E1 dispatch、E2 dispatch、sudo/helper/system mutation 计数必须为 0。
  - Concurrency/review gate:satisfied。readiness 审计时 GitHub open PR = 0；本 PR 只修改本
    change 的 `proposal.md`/`tasks.md` 状态与 review record，不携带实现/evidence，也不改变
    其他任务状态。TASK-RKFUI-001 implementation+evidence 与后续 `ready→done` 各用独立 PR。
- Platform:macos
- Requirements:`REQ-FLASH-001`、`REQ-UX-007`、`POL-WORKFLOW-001`
- Acceptance:`AC-FLASH-001-01`、`AC-UX-007-01`
- Depends on:CHG-2026-026 approved（本 PR merge 后满足）；无前序任务
- Allowed paths:
  - `openspec/integrations/rockchip/**`
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipDeviceDiscovery.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipDeviceDiscoveryContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/Rockchip/**`
  - `scripts/rockchip_e0_probe/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - `ArkDeckApp/**`
- Risk:medium（E0/read-only 真机 probe；零 mode switch、零 mutation/destructive）
- Hardware required:yes（E0 窗口；contract/fixture no）

### Deliverables

- 版本化 `rkdeveloptool ld` output registry + success/malformed/multi-device/Maskrom fixtures。
- strict parser 与 executable URL + `["ld"]` adapter；shell/sudo/elevation 调用结构性为 0。
- signed Sandbox host/device spike：记录 tool path source/version/hash/trust、entitlements、
  direct non-elevated invocation、USB access result 和 typed DeviceAccessAdvisor verdict。

### Verification

- AC-FLASH-001-01 → golden + real-fault parser tests → 非 RockUSB/Maskrom/未知/畸形 family
  preflight blocked，相似命令 dispatch 0。
- AC-UX-007-01 → signed Sandbox E0 run → permission/driver/offline 可区分，sudo/helper/install/
  ACL/group/rule 修改调用数 0。
- Execute readiness gate：只有 direct non-elevated `ld` 在目标交付形态可用且 tool identity
  pinned 时 TASK-RKFUI-003 才可进入 ready；否则它保持 blocked。

### Notes / handoff

- 完成后在 `evidence/runs/TASK-RKFUI-001/` 追加 contract 与 E0 run；真实 serial 只记摘要。

## TASK-RKFUI-001A — DAYU200 HDC→Loader E1 capability characterization

- Status:blocked（等待 CHG-2026-026 approval、TASK-RKFUI-001 done、具名 E1 设备窗口、
  per-device typed capability/人工授权和精确 HDC/firmware/tool pin）
- Platform:macos
- Requirements:`REQ-FLASH-002`、`REQ-FLASH-007`、`REQ-FLASH-010`、
  `REQ-DEV-001`、`REQ-DEV-002`、`REQ-DEV-003`、`REQ-DEV-006`、`REQ-DEV-008`、
  `POL-WORKFLOW-001`
- Acceptance:`AC-FLASH-002-01`、`AC-FLASH-007-01`、`AC-FLASH-010-01`、
  `AC-DEV-001-01`、`AC-DEV-002-01`、`AC-DEV-002-02`、`AC-DEV-003-01`、
  `AC-DEV-003-02`、`AC-DEV-006-01`、`AC-DEV-008-01`
- Depends on:TASK-RKFUI-001
- Allowed paths:
  - `scripts/rockchip_loader_transition_probe/**`
  - `openspec/integrations/rockchip/**`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `Packages/**`
  - `ArkDeckApp/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:medium（E1/deviceMutation reboot；flash/erase/format/unlock/update/destructive dispatch 0）
- Hardware required:yes（精确 DAYU200/HDC/firmware/rkdeveloptool/USB topology 窗口）

### Deliverables

- 只允许固定 typed intent：`hdc -t <durable-connect-key> shell reboot loader`；不得接受 caller
  shell/argv。运行前后记录 HDC identity、binding revision、tool hashes 和 mutation lane。
- 逐时捕获 command receipt/exit/stdout/stderr、HDC disconnect、USB VID:PID/topology、bounded
  `rkdeveloptool ld` observations，判定是否直达 `0x2207:0x350a Loader`。
- 对 already Loader（HDC dispatch 0）、HDC unsupported/offline、`0x5000`/wrong mode、timeout、
  多候选与 physical fallback 分别形成诚实结论；不得执行 `ppt/wlx/rd`。
- 给出 exact combination 的 capability verdict：`supported | unsupported | unknown`，以及
  normal→Loader evidence 是否满足 Core auto-rebind threshold；不满足时产品必须人工确认。

### Verification

- 软件进态成功面最多一次 E1 reboot dispatch，destructive dispatch 0；Loader observation
  必须是 semantic `0x350a + Loader`，不能只看 HDC exit 0。
- 取消影响确认、binding mismatch、错误 target、多设备/多候选任一项 → HDC mutation 0。
- transition 失败后按 CHG-2026-016 physical sequence 可进入只读 mode observation；fallback
  不得被记录为 App 自动进态。

### Notes / handoff

- 本任务仅 characterization，不修改产品代码、不扩大 hardware support；run 放在
  `evidence/runs/TASK-RKFUI-001A/`。若 exact combination 未证明 supported，后续产品默认
  physical fallback。

## TASK-RKFUI-002 — Flash application facade、plan-only UI 与全局 Job presentation

- Status:blocked（等待 CHG-2026-026 approval + TASK-RKFUI-001/001A done）
- Platform:macos
- Requirements:`REQ-FLASH-003`、`REQ-FLASH-004`、`REQ-FLASH-005`、
  `REQ-FLASH-011`、`REQ-UX-001`、`REQ-UX-005`、`REQ-UX-006`、`REQ-I18N-001`
- Acceptance:`AC-FLASH-003-01`、`AC-FLASH-004-01`、`AC-FLASH-005-01`、
  `AC-FLASH-005-02`、`AC-FLASH-011-01`、`AC-UX-001-01`、`AC-UX-005-01`、
  `AC-UX-006-01`、`AC-I18N-001-01`
- Depends on:TASK-RKFUI-001、TASK-RKFUI-001A
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashApplicationFacadeContractTests.swift`
  - `ArkDeckApp/App/ArkDeckApp.swift`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Flash/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipRockUSBFlashProvider.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - 任何真实 execute/process dispatch 文件
- Risk:medium（host-only archive read/write + plan-only；device mutation/destructive dispatch 0）
- Hardware required:no

### Deliverables

- production/fixture application facade 和不可变 presentation；App ViewModel 不持有 process/
  journal bypass。
- Flash 页面：工具/设备刷新与选择、本地镜像 importer、validation、exact plan、数据影响、
  plan-only Start、normal/切换中/Loader/歧义 mode badge、software-transition capability、物理
  按键 fallback、阶段日志、错误/恢复信息。
- AppShell 仅在 `.flash` 显示 Flash 页面；全局 Job card 跨导航保留状态。
- zh-Hans/en strings、accessibility identifiers、keyboard/screen-reader 可操作的风险信息。

### Verification

- plan-only integration → 真实 Provider validate/makePlan + owned plan Artifact → 全步骤可见、
  mutation/destructive runner 0、finalization success=`planned` / failure=`failed`。
- SwiftUI/XCUITest → Flash 导航、设备/镜像/计划、mode badge、跨页 Job 状态和无颜色危险
  信息可见。
- localization lint/pseudo smoke → 中英文完整且关键控件无字符串拼接。

### Notes / handoff

- 该任务不声称真机一键刷机完成；UI execute control 必须显示 locked/blocked reason。

## TASK-RKFUI-003 — Typed rkdeveloptool execute orchestration 与交互式确认接线

- Status:blocked（等待 CHG-2026-026 approval、TASK-RKFUI-001/001A/002 done、non-elevated USB
  access PASS、软件进态 capability verdict，以及维护者确认 `REQ-FLASH-015` 解释）
- Platform:macos
- Requirements:`REQ-FLASH-002`、`REQ-FLASH-007`、`REQ-FLASH-008`、
  `REQ-FLASH-009`、`REQ-FLASH-010`、`REQ-FLASH-011`、`REQ-FLASH-012`、
  `REQ-FLASH-013`、`REQ-FLASH-015`、`REQ-DEV-001`、`REQ-DEV-002`、
  `REQ-DEV-003`、`REQ-DEV-006`、`REQ-DEV-008`、`POL-WORKFLOW-001`、
  `POL-RECOVERY-001`
- Acceptance:`AC-FLASH-002-01`、`AC-FLASH-007-01`、`AC-FLASH-008-01`、
  `AC-FLASH-009-01`、`AC-FLASH-010-01`、`AC-FLASH-011-01`、
  `AC-FLASH-012-01`、`AC-FLASH-013-01`、`AC-FLASH-015-01`、
  `AC-FLASH-015-02`、`AC-DEV-001-01`、`AC-DEV-002-01`、`AC-DEV-002-02`、
  `AC-DEV-003-01`、`AC-DEV-003-02`、`AC-DEV-006-01`、`AC-DEV-008-01`
- Depends on:TASK-RKFUI-001、TASK-RKFUI-001A、TASK-RKFUI-002
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashApplicationFacade.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashExecutionAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipLoaderTransitionAdapter.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipArchiveStaging.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashApplicationFacadeContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipFlashExecutionAdapterContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/RockchipLoaderTransitionAdapterContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckFakeRockchipFixture/**`
  - `ArkDeckApp/Features/Flash/**`
  - `ArkDeckApp/Resources/Localizable.xcstrings`
  - `ArkDeckAppUITests/Flash/**`
  - `ArkDeck.xcodeproj/project.pbxproj`
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
- Forbidden paths:
  - `openspec/constitution.md`
  - `openspec/specs/**`
  - `openspec/contracts/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RockchipFlashProfile.swift`
  - BlueTool/upgrade_tool 资源或任意 shell/sudo/helper 接线
- Risk:destructive（实现/fixture 测试必须零真实设备 dispatch）
- Hardware required:no（本任务只做 contract/fake；真机归 TASK-RKFUI-004）

### Deliverables

- safe archive staging（防 traversal/link/device/duplicate/trailing payload）与逐成员 hash 复核。
- typed step executor：固定 argv、executable identity receipt、device lane、storage/power、
  durable intent/outcome、critical safe cancellation、raw output Artifact、semantic parser、
  postflight/recovery。
- `enterUpdater` adapter：already Loader skip；supported combination 从 durable HDC binding
  materialize `reboot loader`；等待 disconnect + bounded `ld` polling + Core rebind；unsupported/
  unknown 转 physical fallback；新 binding revision 前 flash dispatch 0。
- UI exact-plan + 双强确认 + dispatch-time recheck；旧确认在任何 pin 漂移后失效。
- fake executable 覆盖九写成功、marker 错误、exit0 但语义失败、取消、crash window、sleep/
  wake、disconnect、postflight mismatch 和 outcomeUnknown。

### Verification

- 关联 AC → contract/fake/fault injection；真实 RockUSB/external tool launch count = 0。
- 无/错 authority、binding、prerequisite、plan、confirmation 任一项 → Job policyBlocked 或
  preflight blocked，mutation/destructive dispatch 0。
- transition cancel/command failure/no disconnect/wrong mode/timeout/multiple candidate/rebind
  ambiguity → `ppt/wlx/rd` dispatch 0；fixed sleep/unique-device auto-bind/default HDC target 0。
- critical write 期间 cancel/quit → 当前 process 不 force kill、下一 step 不启动、durable
  pending-cancel 可 replay。
- intent 无 outcome → outcomeUnknown，restart 自动 replay 0。

### Notes / handoff

- 若实现需要新 schema、helper、entitlement、Core 解释或 Provider command surface，立即
  blocked 并修订 change；不得在代码中暗扩范围。

## TASK-RKFUI-004 — macOS App 产品路径真机验收

- Status:blocked（等待 TASK-RKFUI-003 done + 独立 readiness/具名设备窗口/精确执行授权）
- Platform:macos
- Requirements:`REQ-FLASH-007`、`REQ-FLASH-008`、`REQ-FLASH-009`、
  `REQ-FLASH-010`、`REQ-FLASH-012`、`REQ-FLASH-013`、`REQ-FLASH-014`、
  `REQ-FLASH-015`、`REQ-UX-001`、`REQ-UX-005`
- Acceptance:`AC-FLASH-007-01`、`AC-FLASH-008-01`、`AC-FLASH-009-01`、
  `AC-FLASH-010-01`、`AC-FLASH-012-01`、`AC-FLASH-013-01`、
  `AC-FLASH-014-01`、`AC-FLASH-015-01`、`AC-FLASH-015-02`、
  `AC-UX-001-01`、`AC-UX-005-01`
- Depends on:TASK-RKFUI-003
- Allowed paths:
  - `openspec/changes/chg-2026-026-macos-rockchip-flash-ui/evidence/**`
  - `openspec/verification/hardware-matrix.md`（仅在全部 required hardware AC PASS 后追加
    精确 App build 组合）
- Forbidden paths:
  - `Packages/**`
  - `ArkDeckApp/**`
  - `openspec/specs/**`
  - `openspec/contracts/**`
- Risk:destructive（CORE-2.0.0 下由人类维护者亲自执行；若未来 baseline 改为 standing
  authorization，readiness 仍须逐项 pin 并遵守当时最高权威规则）
- Hardware required:yes（精确 DAYU200/固件/rkdeveloptool/App build/USB 窗口）

### Deliverables

- App UI 端到端 realHardware run：refresh → select → archive validation → exact plan →
  prerequisites/双确认 → software enter Loader（若 capability supported，否则 physical fallback）
  → durable rebind → 九分区 → safe reset → postflight。
- 同窗口负探针：取消确认、篡改一项 pin、postflight mismatch 均零错误推进。
- schema-compliant hardware evidence、脱敏 transcript、App build/tool/archive hashes 和恢复
  路径；只有全部 required AC PASS 才更新 hardware matrix。

### Verification

- 成功面必须由 semantic markers + device reconnect/版本 postflight 共同确认；exit 0 不够。
- 负面必须记录 dispatch count、Job state、certainty、RecoveryGuide；fake/simulation 不计入
  hardware support。

### Notes / handoff

- 发现实现缺陷回 TASK-RKFUI-003 的独立 remediation，不在 evidence PR 混入代码。
