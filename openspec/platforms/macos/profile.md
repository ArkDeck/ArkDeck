# macOS Platform Profile

> ID：PLATFORM-MACOS  
> Version：0.2.0
> Status：review（M0A 后决定 Sandbox/distribution）  (distribution 面已于 2026-07-21 经 DEC-004 #261/ADR-0002 决定,见下各节 dated 注记)
> Core baseline：CORE-2.0.0  
> Core strategy：native-conforming-shared-contract-vector-suite  
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Minimum target：macOS 14

本文件只定义 macOS 实现；它不得覆盖 Core Requirement 或 AC。

## Technology profile

- Swift 6 structured concurrency；
- SwiftUI 原生桌面 UI，主窗口可使用 `NavigationSplitView`；
- 领域层、Process、Runtime、OpenHarmony Adapter、Workflow 和 Storage 分为独立 Swift Package targets；
- 不把 SwiftUI/AppKit 类型泄漏进 Core contracts；
- 优先使用系统框架，第三方依赖需有许可证、供应链和更新评审。

## 建议工程边界

```text
ArkDeckApp/
  App/
  Features/Devices Flash Debug Dump Trace History
  Resources/Localizable.xcstrings
Packages/ArkDeckKit/
  ArkDeckCore
  ArkDeckProcess
  ArkDeckRuntime
  ArkDeckOpenHarmony
  ArkDeckWorkflows
  ArkDeckStorage
```

## Port mapping

| Core Port | macOS 实现候选 |
| --- | --- |
| ProcessExecutor | Foundation `Process`/底层 spawn wrapper；绝对 URL + `[String]`；不调用 `/bin/sh -c` |
| SingleInstanceGuard | 固定 Application Support lock file + 非阻塞 `flock`，进程生命周期持有 fd |
| AppActivationService | AppKit/系统激活主实例机制；进程列表只用于 UX |
| PowerActivityController | `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`；如 Spike 需要更强诊断则封装 IOPM assertion，不重复持有两套 |
| VolumeIdentityResolver | URL volume resource values / filesystem identity；不能以目录字符串归组 |
| HostStorageProbe | URL volume capacity resource values / filesystem attributes；按真实卷身份查询容量，处理卷拔出、只读重挂与 ENOSPC |
| PersistentFileAccess | 标准文件选择器 + security-scoped bookmark（Sandbox prototype） |
| ToolTrustInspector | path/hash/version/codesign assessment/quarantine status；不删除 xattr、不重签 |
| DeviceAccessAdvisor | entitlement、Sandbox denial、USB/UART 可见性与权限诊断；不静默安装 helper、提权或修改系统策略 |
| SystemLogger | Unified Logging/`Logger` + 有界结构化诊断 |
| ElapsedDeadlineClock | `ContinuousClock` 或经 contract test 证明睡眠期间继续推进的等价时钟；`Date` 仅审计/跨进程 fail-safe reconcile |
| ActiveWorkClock | `SuspendingClock` 或经 contract test 证明睡眠期间暂停的等价时钟；wake 后重置 throughput/ETA segment |
| SleepWakeObserver | `NSWorkspace` sleep/wake notification 或经 contract test 验证的等价系统通知；wake 后触发 journal reconcile、重连评估和 ETA segment reset |
| PlatformFileRevealer | Finder reveal |

## M1 HDC read-only probe mapping

M1-006 consumes the exact `OPENHARMONY-TOOLS@0.3.0` registry at
`openspec/integrations/openharmony/readonly-probes.yaml` (SHA-256
`b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6`). macOS maps
the four registered families as follows:

| Probe family | macOS access / diagnostic mapping |
| --- | --- |
| `serverIdentityGeneration` | Supported through commandless platform process observation: exact executable identity, exact loopback listener endpoint, PID start identity, and bracketed pre/post observation. A child command cannot establish ownership. |
| `selectedDeviceAuthorizationBinding` | Supported only for the registered `list targets -v` argv and only after a stable existing-server identity receipt. Strict parsing must match the selected device's durable connect-key and serial binding, and the complete stdout bytes must equal the registry's captured `rawSHA256` family. The current family therefore establishes `.ready` only for that registered capture; a different device row remains unavailable even when it matches a durable binding. Supporting arbitrary devices requires a separately approved integration change that registers a parameterized raw family. |
| `keyAccessDiagnostics` | Unsupported. The registered profile grants no key path or file-read dispatch authority; UI reports the capability unavailable without guessing a path or touching key material. |
| `subserverCapability` | Unsupported. The registered profile grants no child command; UI reports unavailable and spawn-sub, killall-sub, and device-migration call counts remain zero. |

The production classifier is bound to the registry plus its hash-pinned resource manifest and
control vectors. Missing, mismatched, or unregistered evidence fails closed. The signed Sandbox
test path uses a user-selected executable with a security-scoped bookmark and repository
`ArkDeckFakeHDCFixture`; it never executes an installed HDC, accesses a real device, or mutates a
server.

## Session location

默认可使用：

```text
~/Library/Application Support/ArkDeck/Sessions/<year>/<month>/<sessionUUID>/
```

用户选择其他输出根目录时遵守 PersistentFileAccess 和 Core volume identity 规则。

## Sandbox / external tool boundary

M0A 必须同时验证：

1. Sandboxed prototype；
2. 非 Sandbox、Developer ID + Hardened Runtime prototype。

候选 entitlement 仅是待验证输入：

| 场景 | 候选 entitlement / 条件 |
| --- | --- |
| App Sandbox | `com.apple.security.app-sandbox` |
| USB | `com.apple.security.device.usb` |
| UART | `com.apple.security.device.serial` |
| HDC server/TCP/update client | `com.apple.security.network.client` |
| ArkDeck-managed server listener | `com.apple.security.network.server` |
| 用户文件 | `com.apple.security.files.user-selected.read-write` 与 app-scoped bookmark |
| Bundled helper | 仅 `com.apple.security.app-sandbox` + `com.apple.security.inherit` |

工具/镜像 bookmark 使用只读 scope，只有输出目录需要 read-write。用户选择文件权限不等于允许执行任意外部程序；把 POSIX path 交给 child 也不能假定转移了运行时 PowerBox 动态扩展。外部 HDC 读取镜像、key 和输出目录必须端到端验证。

### Rockchip Loader-mode execution（NRU-004）

macOS 上受支持的 Rockchip 产品路径是 protected Runtime 经已测量的 `arkforged`
daemon 使用 native RockUSB backend；toolchain identity 为
`arkforged-native-rockusb`。ArkDeck 的 typed workflow 不选择或启动外部 Rockchip
executable，不接受 executable bookmark、caller argv、PATH/shell、动态下载、helper
或 copy-to-container fallback。

`flash.dayu200` 的 HDC `enterUpdater` 步骤仍使用已绑定 target 的 external-first HDC；
Loader 枚举、分区表读取、写入、逐分区读回、reset、rebind 与 postflight proof 全部走
native ArkForge。破坏性执行仍由 protected Runtime 在 exact plan、artifact lease、fresh
target/binding/tool facts 与 durable reservation 闭合后生成并消费 `RuntimeCapability`；
本 profile 不新增 fallback 或调用方授权面。

DEC-011 / ADR-0003 选择的 App-owned bundled child 已被 NRU-004 在 Loader-mode 产品
路径上取代。该 child 只作为单独的、operator-invoked Maskrom rescue utility 随 App
分发；它不是 Runtime Provider、Loader-mode backend、discovery fallback 或 ArkForge
依赖。其 source/license/SBOM/notarization 与发布义务继续由
`openspec/integrations/rockchip/bundled-component/1.0.0/` 和对应 release 文档承载。

## Gatekeeper and quarantine

- ArkDeck 自身签名公证不等于外部 HDC 可信；
- 测试 DevEco HDC、浏览器下载且带 quarantine 的 HDC、同一工具无 quarantine 对照、可信/未知签名工具；
- 使用干净 VM snapshot，包含 Safari 下载 + Archive Utility 解包传播链；
- ArkDeck 不自动清除 quarantine、不修改 raw xattr payload、不重签工具、不要求关闭系统安全；
- 被阻止时展示 path、signing identity、hash、quarantine/assessment 和风险；只有系统提供入口且用户确认来源时引导 Open Anyway。

## Hardened Runtime and distribution

Release 默认不申请：

```text
com.apple.security.cs.allow-jit
com.apple.security.cs.allow-unsigned-executable-memory
com.apple.security.cs.disable-library-validation
com.apple.security.cs.allow-dyld-environment-variables
com.apple.security.cs.disable-executable-page-protection
com.apple.security.get-task-allow
```

启动独立 HDC 不是关闭 Library Validation 的理由。M0A 必须交付实际签名 entitlement dump、Sandbox/Gatekeeper 日志、场景结果和 distribution decision record。

首版候选分发为 Developer ID 签名、Hardened Runtime、公证的 DMG/ZIP。若 Sandbox 阻断 HDC/USB/Provider，选择非 Sandbox 站外分发而不是放宽 Core。

**已决定(2026-07-21,DEC-004 #261 / ADR-0002,supersede ADR-0001)**:v1 分发 =
**Sandboxed** + Developer ID + Hardened Runtime + 公证**单一 DMG**、公开直接分发;
ZIP/MAS/双构建排除。"若 Sandbox 阻断"分支未发生——M0B 真机 USB 采集与
M1-006/CHG-2026-019 signed Sandbox XCUITest 证明现行六 entitlement 形态可用,
entitlement 集以 ADR-0002 声明为准。release gates(DevID identity、Sandboxed 形态
clean-VM/clean-host 矩阵、自动更新 change verified)见 ADR-0002,未满足前 release
保持 blocked。

## Auto-update(2026-07-21 起纳入 v1)

**2026-07-21 经 DEC-004 #261/ADR-0002 纳入 v1 更新渠道**,载体 = CHG-2026-023
(选型/XPC/签名链/隐私由其两任务评估落地;verified 前手动公证 DMG 过渡)。下段
安全基线保持为该 change 的输入。原注: 自动更新不是 MVP。若未来采用 Sparkle：HTTPS、Developer ID/公证、archive EdDSA 签名和私钥隔离是基础；Sparkle 2.9+ signed feed 需同时启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，属于附加保护。

## macOS UI mapping

- 导航：Overview、Flash、Debug、UI Dump、Trace、History；
- 底部或全局 Job Drawer 展示所有任务；
- Settings 管理 HDC/Provider path、输出根目录、Profile、隐私和清理；
- String Catalog 提供 `zh-Hans`/`en`；
- UI Dump 必须使用完整名称；plan-only/simulated 使用持续 badge。

## Device-observation family mapping（CHG-2026-024 / TASK-I24-001，2026-07-27）

macOS adopts `OPENHARMONY-HDC-DEVICE-OBSERVATION-PROBES@1.0.0`
(`OPENHARMONY-TOOLS@0.5.0`, lock `INTEGRATION-PROFILES-0.6.0`, registry SHA-256
`79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49`), observed on hdc `3.2.0f` — a different tool from the `3.2.0d`
read-only and trace registries mapped above.

| Probe family | macOS access / diagnostic mapping |
| --- | --- |
| `deviceObservationSnapshot` | Supported for the exact `list targets -v` argv against a pre-existing server on the exact `127.0.0.1:8710` endpoint, with bracketed pre/post server identity. Presence is read from the state column only: `observedEmpty` means zero `Connected` rows, satisfied either by the CRLF-terminated `[Empty]` marker a server emits before it has ever seen a device, or by rows that are all `Offline`. This tool never deletes a row, so the UI must not treat a vanished row as a departure nor a surviving row as presence. Unknown literal, column-count mismatch, duplicate key, residual `CR`, zero-byte stdout, stderr, nonzero exit or truncation make the whole snapshot unknown; timeout, cancellation, server absence and endpoint drift make it unavailable. No partial set is ever emitted. |

This mapping publishes integration inputs only. It changes no Core Requirement/AC semantics and
does not wire the CHG-2026-022 consumer, whose cadence, fan-out and presentation remain behind
that change's own readiness.

## Commandless supervisor-observation mapping（CHG-2026-043 / TASK-HSO-001，2026-07-28）

macOS adopts `OPENHARMONY-HDC-SUPERVISOR-OBSERVATION-PROBES@1.0.0`
(`OPENHARMONY-TOOLS@0.6.0`, lock `INTEGRATION-PROFILES-0.7.0`, registry SHA-256
`f1691f748da10f1bb7753167d71ff3b764a347676f97d5ec70a1e97ac35c9763`,
resource manifest SHA-256
`6bf09cabfc762b1e632d6dba2528b04b33173f6e53f2f1669d26ef8d72a4ab3d`)
for the exact hdc `3.2.0f` executable SHA-256
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
and endpoint `127.0.0.1:8710`.

| Probe family | macOS access / diagnostic mapping |
| --- | --- |
| `serverIdentityGeneration` | `platformProcessObservation` only, with empty argv and invocation disallowed. The selected executable bytes are verified before/after bounded OS process/socket scans; exactly one existing process-owned normalized listener and equality of PID/start/path/hash/endpoint/listener are required before a current receipt may mint generation. Missing, ambiguous, mismatched, drifted, timed-out, cancelled or scan-error state fails closed without HDC child or lifecycle/mutation effect. |

This mapping registers no `checkserver`, health or client/server/daemon version source and grants
no ownership by itself. It is separate from the 3.2.0d readonly and 3.2.0f device-observation
families, forbids fallback/cross-version facts, and does not wire a production consumer.
Platform conformance and support/release status remain unchanged.
