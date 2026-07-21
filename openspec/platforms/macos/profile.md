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
`9014c480c3df61b5a6db7e54e52f29e89d7c93431e91d0856cf5710c22466b9d`). macOS maps
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
