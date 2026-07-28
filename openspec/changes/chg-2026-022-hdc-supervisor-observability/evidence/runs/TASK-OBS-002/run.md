# TASK-OBS-002 run log

## implementation + signed XCUITest（2026-07-28，host-only）

### 授权、基线与范围

- Change = `CHG-2026-022-hdc-supervisor-observability@r3`，本任务只认领
  change-local `OBS-APPFACE-001`，不认领 canonical Core AC。
- Fresh D1 readiness = PR #724 exact head
  `ab58d4b823f59a037dc8fd7f4fb500180c6317da`，由维护者 `lvye`
  APPROVED 后 merge 为
  `d42c002609177e47ef95320cb5bdc0a42f0b510e`。开工前实测该 merge 为
  protected `main` HEAD，且 readiness 后 App/Kit/project/scheme pins 零漂移；
  open PR = 0。
- 实现 commit =
  `963542402c51025c9a2e7855998a60d0af3e7baa`，parent =
  `d42c002609177e47ef95320cb5bdc0a42f0b510e`；只修改 readiness 授权的两个
  现有文件：
  - `ArkDeckApp/Features/HDC/HDCStatusView.swift`：blob
    `476769d4b5b242a91b2bb4d0661cdb0fb7359d44`，SHA-256
    `1d2896c5ee9764e93a53d7bff5ec9f5deaf7cfc3301121a7d419a87dc4750c04`
  - `ArkDeckAppUITests/HDC/HDCStatusUITests.swift`：blob
    `6224637fcc083807684a2473785f559b181f0925`，SHA-256
    `23d99d56cf27491a3b3aad6f1f0d3d3275bead9689b5515ef3f1da11faaaf563`
- 环境：macOS 26.5.2 (`25F84`) arm64、Xcode 26.6 (`17F113`)、
  Apple Swift 6.3.3；Developer Mode enabled。

### 实现落点

| Readiness pin | 实现 |
| --- | --- |
| Automatic counters | `hdc.counters.autoLifecycle` 与 `hdc.counters.autoSubserver` 直接读取 immutable presentation `Int` 并输出十进制字符串 |
| Endpoint source | `hdc.endpoint.source` 输出 `endpointSource.rawValue`，nil 输出 `unknown` |
| Ownership basis | `hdc.ownership.basis` 按四个钉定 key 的固定顺序输出 `name=true|false`，以 `; ` 分隔；nil 输出 `unavailable` |
| Device events | `hdc.devices.events` 按 presentation 原顺序输出 `timestamp kind [identifier]`，以 ` | ` 分隔；empty 输出 `none` |
| Accessibility | 五项均复用既有 `field` helper，保持 static-text 与 exact identifier |
| Boundary | App 仍只 import `ArkDeckWorkflows`；零 OpenHarmony/raw source/snapshot/composition/HMAC/runner/argv/process capability，零 fixture literal |

`HDCStatusUITests.swift` 只新增 readiness 钉定的四个方法：

- AP1 `testOBSAPP1_ObservationSummaryFieldsAreAccessibleStaticText`
- AP2 `testOBSAPP2_DeviceEventsPreserveOrderShapeAndRedaction`
- AP3 `testOBSAPP3_ProductionLaunchContainsNoFixtureObservationValues`
- AP4 `testOBSAPP4_AppSourceKeepsPresentationOnlyPackageBoundary`

明确零修改：`ArkDeckApp/App/ArkDeckApp.swift`、project/scheme、Package/Sources/
contracts、proposal/design/verification/acceptance YAML；零新增 refresh/timer/poll/
retry，零 HDC lifecycle/subserver/device mutation/destructive capability。

### 命令与结果

| 命令 | 结果 |
| --- | --- |
| `xcrun swift-format format --in-place <two authorized files>` | PASS；`git diff --check` PASS |
| `CI=true swift build --package-path Packages/ArkDeckKit --product ArkDeckFakeHDCFixture` | PASS |
| temporary repo-root hardlink + `cmp`/inode | 与 `.build/.../ArkDeckFakeHDCFixture` 字节相同，inode 均为 `99945963` |
| default-signing `xcodebuild ... test`，fresh DerivedData/result bundle | PASS；13 tests，0 failures；既有 9 + AP1–AP4 |
| `xcresulttool get test-results summary` | `Passed`；total/passed/failed/skipped = `13/13/0/0`，arm64 macOS 26.5.2 |
| App/runner `codesign --verify --deep --strict` | 两者 PASS；identifier = `com.arkdeck.desktop` / `com.arkdeck.desktop.hdcuitests.xctrunner`；`Signature=adhoc`，`TeamIdentifier=not set` |
| App/runner executable SHA-256 | `f6f9656bf0a5eb605c149d8d80d35c58a9b06f5de0c9e5e0f58c8eb48bb500cc` / `10eadaa806586ea51ddede5090b9d3bafe9ee2ee4c0b4bdfcd0c796208e0c892` |
| post-quarantine `swift test --filter HDCSupervisorContractTests` | 55 tests，0 failures |
| final `swift test --package-path Packages/ArkDeckKit` | exit 0；466 listed tests，1 skipped，0 failures |
| second final `swift test --skip-build` | exit 0；全量再次 PASS |
| `scripts/check-sdd.sh` | 0 errors，0 warnings，111 acceptance IDs |
| `python3 -m unittest test_check_pr_paths.py`（`scripts/`） | 50 tests，OK |

偏差说明：signed picker 测试把临时可见 hardlink 选入 Sandbox 后，macOS 给其
共享 inode（ignored `.build` fake fixture）重新附加 `com.apple.quarantine`。
紧随其后的第一次 Swift 全量因此发生 fake child 零调用/非零退出，判为无效
环境 run 并中止；它不是产品或 contract 失败。仅清除该生成物 xattr 并删除
临时 hardlink 后，HDC supervisor 55/55 与两次全量均 PASS；清理产生零 tracked
diff。DerivedData、xcresult 与 hardlink 均已删除。

### AP1–AP4 二值结论

| AP | 结果 |
| --- | --- |
| AP1 | PASS：五个 ID 均为可访问 static text；fixture 值精确为 `0`、`0`、`unknown`、`unavailable` 与两条 ordered event 单值 |
| AP2 | PASS：appeared 严格早于 disappeared；两项均为 UTC fractional RFC 3339 + `redacted-device-[0-9a-f]{24}`；零 `Optional(...)`/internal reason/raw connect key |
| AP3 | PASS：无 fixture flag 的 `/usr/bin/true` fail-closed production launch 中事件字段存在，但两个固定 timestamp/identifier 均不存在，lifecycle dispatch button 不存在 |
| AP4 | PASS：App 产品 import 仅 Workflows；五 ID 各恰一处并消费钉定 presentation 字段；零 raw/process capability 与 fixture literal |

结论：`OBS-APPFACE-001` host-only signed UI evidence = PASS。该结果不构成真实
设备/M0B-002 evidence，不自行把 TASK-OBS-002 标为 `done`，也不把 change 标为
`verified`；implementation/evidence PR merge 后仍须独立 `ready→done` 状态 PR。
