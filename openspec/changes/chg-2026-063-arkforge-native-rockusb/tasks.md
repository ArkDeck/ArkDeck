# Tasks — CHG-2026-063

分阶段垂直交付，每个 Task 独立可验。`ready` 只有在本 proposal PR 经维护者
review/merge 进入 protected `main` 后生效；合入前不得开始实现 PR。

ArkForge（Rust 仓库）无路径门，直接提交 main，但仍按本文件声明的路径自律；
ArkDeck 侧实现 PR 必须匹配 Allowed paths（`scripts/check_pr_paths.py`
--preflight 本地先验，注意管道会吞退出码，勿 `| tail` 后判断）。

## TASK-NRU-001 — 原生只读路径：USB 底座 + 协议引擎 + 端口双轨

- Status:done（2026-08-18;ArkForge main `a935798` 实现 + `26aa527` 真机 Loader
  读 parity——证据在 ArkForge 仓 `crates/arkforged/tests/evidence/
  2026-08-18-task-nru-001-read-parity.txt`）
- Golden Journey:GJ-4
- Platform:macos
- Requirements:NRU-REQ-001（bulk 传输底座，FFI 收容于单 crate）、
  NRU-REQ-002（typed 端口面，`ld`/`ppt`/`rl` 语义原生化）
- Acceptance:NRU-AC-1..3（见 verification.md）
- Depends on:本 proposal merge（即 AFD-0001 修订获批）
- 交付内容:
  1. 新 crate `arkforge-usb`：IOKit FFI（IOUSBHost/IOUSBLib）枚举 vendor
     0x2207、独占 claim、bulk in/out、超时；unsafe 只许出现在此 crate。
  2. `arkforge-provider`：RockUSB 封帧 + TEST_UNIT_READY / READ_LBA /
     READ_CAPACITY / 枚举读描述符；opcode 以 pinned vendor 源码为规范参考
     （design.md"规范来源"节）。
  3. `arkforged`：`trait RockUsbPort`（typed），`VendorToolPort`（现
     FixedToolPort 适配）与 `NativeRockUsbPort` 双实现；`--rockusb-port
     native|vendor` 运行时选择，默认 vendor（本 Task 不切默认）。
  4. A/B 读一致性 harness：同一在板设备上，原生 `rl`（首扇区、GPT 主备表、
     随机 LBA 窗口）与 vendor `rl` 逐字节相同；`ppt`/枚举语义等价。
  5. 台架实证记录进 `evidence/`（读比对哈希清单）。
- Allowed paths（ArkForge 仓库，自律声明）:
  - `crates/arkforge-usb/**`
  - `crates/arkforge-provider/src/**`
  - `crates/arkforged/src/**`
  - `crates/arkforged/tests/**`
  - `Cargo.toml`、`Cargo.lock`

## TASK-NRU-002 — 原生写路径 + 复位 + campaign AFA-AC-7 双轨互证

- Status:done（2026-08-18;ArkForge main `3567484`——原生 WRITE_LBA/RESET、
  toolchain 身份换源;当晚两次全量 `succeeded` 落在双轨/默认切换窗口内）
- Golden Journey:GJ-4
- Platform:macos
- Requirements:NRU-REQ-003（WRITE_LBA 按 observed_table 寻址）、
  NRU-REQ-004（DEVICE_RESET）、NRU-REQ-005（新 toolchain 身份与成熟度）
- Acceptance:NRU-AC-4..6
- Depends on:TASK-NRU-001
- 交付内容:
  1. 原生 WRITE_LBA（分块、typed 进度、无 stdout marker 判定）；寻址复用
     `session.observed_table()` 已核对的 entry.offset_sectors，越界拒绝
     逻辑不动。
  2. 原生 DEVICE_RESET；`rd` 退出 vendor 路径。
  3. `ToolchainKind` 新增原生种类；identity digest 取 arkforged 构建摘要；
     `publish_dayu200_maturity` 发布新组合；campaign `AFA-AC-7` 建档
     （transcript 进 `transcripts/`）。
  4. 双轨互证（campaign 内容）：原生写→vendor 读回验摘要；vendor 写→
     原生读回验摘要；两向全部九分区。
  5. `--hardware-campaign AFA-AC-7` 下以 `--rockusb-port native` 跑
     `flash.dayu200` 全绿 `succeeded`（无 vendor 进程 spawn，`pgrep`
     取证进 evidence/）。
- Allowed paths:同 TASK-NRU-001，另加 `transcripts/**`、`profiles/**`

## TASK-NRU-003 — ArkDeck 观察半边换源（vendor `ld` 回执退场）

- Status:done（2026-08-19;ArkDeck #1395（本 task tag）完成观察半边换源与
  advice 面重命名;vendor 可执行零引用由 `AuthorizationSurfaceGuardContractTests`
  的全源码 tripwire 守卫）
- Golden Journey:GJ-4
- Platform:macos
- Requirements:NRU-REQ-006（Loader 观察第二源改为 arkforged
  `discoverDevices` 回执；双源规则不变）
- Acceptance:NRU-AC-7..8
- Depends on:TASK-NRU-002
- 交付内容:
  1. `RockchipRuntimeActionHost` 的 `waitForLoader`/`rebindLoader`/
     `enterLoader` already-loader 捷径：`observeLoader(executable:)`
     （vendor `ld`）替换为经 lane 客户端取 `discoverDevices` 观察回执；
     IOKit 探测半边保持不变，缺一仍拒。
  2. `flash.bind-current-loader` 重绑流程同源替换。
  3. `.rebootToNormal` ArkDeck 动作（刷机路径已不可达）连同其 catalog
     descriptor 清理（先 grep bind/恢复流引用，确认零引用再删）。
  4. 契约测试：performer 全动作过真实校验宿主（既有
     `ArkForgeControlPerformerContractTests` 模式），观察换源后 1815+ 全绿。
- Allowed paths:
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Rockchip*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForge*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Sources/ArkForgeIPC/**`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`

## TASK-NRU-004 — 默认切原生 + vendor 全面退役

- Status:done（2026-08-19;ArkForge main `8129a7a` 默认原生 + `c049a11`
  移除 vendor 运行时;终局回归 NRU-AC-10 = `EVD-NRU-DAYU200-20260819-001`
  （本 change `evidence/runs/TASK-NRU-004/`,亦入 hardware-matrix）。
  **交付内容第 4 条的「rkdeveloptool 保留为 Maskrom 救援工具」半句被
  CHG-2026-065 提案取代**——维护者已决定救援件整体退役,见该 change）
- Golden Journey:GJ-4
- Platform:macos
- Requirements:NRU-REQ-007（信任面收敛为 arkforged 自身签名与摘要）
- Acceptance:NRU-AC-9..10
- Depends on:TASK-NRU-003
- 交付内容:
  1. `--rockusb-port` 默认 native；vendor 分支保留一个发布周期后删除。
  2. `packaging/macos/package-arkforged.sh` 不再携带/重签 rkdeveloptool；
     `ARKFORGE_RKDEVELOPTOOL*` 打包环境变量退场。
  3. ArkDeck：lane 组合四要素改三要素（`ARKDECK_RKDEVELOPTOOL_PATH` 退场，
     all-or-nothing 语义保持）；`agentd install/update` 的
     `--rkdeveloptool` flag、`ArkForgeToolchainPin`、AD-015 vendor 自检、
     `flash install-tool`/`trust-tool` 子命令按引用清理；plist 迁移逻辑
     兼容旧安装（缺省该键不视为 partial）。
  4. 端到端回归：新默认下 `flash.dayu200` 全绿 `succeeded`；
     `/Applications/ArkDeck.app` 内的 rkdeveloptool 保留为 Maskrom 救援
     工具（文档注明），产品运行路径零引用。
- Allowed paths:
  - TASK-NRU-003 全部路径，另加：
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemon/**`
  - `Packages/ArkDeckKit/LaunchAgents/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/**`
