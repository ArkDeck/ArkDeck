---
id: CHG-2026-026
revision: 3 # r3 只起草 TASK-RKFUI-001A exact firmware 7.0.0.33 repin；仅在维护者 review/merge 本 revision PR 后生效
status: approved # r1 已由 PR #298 批准，r2 已由 PR #440 批准；r3 scoped revision 仍须维护者 review/merge 后生效
class: platform
core_change_level: none
owner: "@lvye"
core_baseline: CORE-2.0.0
platforms: [macos]
---

# macOS Rockchip 设备发现与受控一键刷机 UI

## Why

ArkDeck 已有经 DAYU200 真机验证的 `RockchipRockUSBFlashProvider`、严格
`images.tar.gz` Profile、`arkdeck flash` 计划/授权面和恢复指引，但 macOS App 的
Flash 导航目前仍显示通用 HDC diagnostics，没有以下产品接线：

- 从受信任的 `rkdeveloptool ld` 只读输出发现 RockUSB 设备；
- 选择本地镜像并执行流式校验；
- 在 Flash 页面展示目标、工具身份、Provider、镜像 hash、九分区精确计划、数据影响和
  execution mode；
- 从一个用户入口启动完整 Job，并在全局 UI 持续显示阶段、日志、安全边界、取消和恢复
  状态；
- 在满足全部安全门后由交互式人类操作者启动产品执行路径。

维护者提供的 BlueTool 3.3.0 Windows 包证明了“枚举 RK 设备 + 本地/网络镜像 + 单入口
刷机”的可用 UX，但其实现使用 Windows-only `upgrade_tool.exe`、shell 字符串、固定
sleep、弱设备重绑定和非严格镜像集合。ArkDeck 只借鉴交互目标，不复制其二进制、镜像、
协议序列或安全模型。详细逆向分析见 `bluetool-analysis.md`；Loader 进态借鉴与 ArkDeck
逐项对齐见 `loader-entry-alignment.md`。

## What changes

### In scope

- 新增 macOS RockUSB discovery adapter：用户显式选择 `rkdeveloptool`，记录
  path/source/version/hash/platform trust，以 executable URL + argument array 执行只读
  `ld`，严格解析 `DevNo/Vid/Pid/LocationID/Mode`；未知、重复或畸形输出 fail closed。
- r2 将同一官方 upstream commit `304f0737…` 的 clean macOS arm64 build
  `rkdeveloptool ver 1.32` / SHA-256 `bbd7bdc0…9923` 登记为 signed Sandbox discovery
  successor。它只替换 TASK-RKFUI-001 的 E0 `ld` identity；既有 destructive Provider、
  Profile、hardware evidence 与 standing authorization 的 `038a8a0e…3611` pin 保持不变，
  任何 destructive repin 仍需后续独立 change/readiness。
- 先做 signed Sandbox E0 access spike，证明 App 可在**不调用 `sudo`、不安装 helper、
  不修改系统权限**的条件下运行受信任工具并访问 RockUSB。证明失败时 execute 接线保持
  blocked，UI 只能提供 plan-only 和人工恢复/权限指导。
- 新增 normal/HDC → RockUSB Loader 的可选软件进态路线：先以具名 E1 真机任务验证
  DAYU200/HDC/firmware 是否接受 `hdc -t <durable-connect-key> shell reboot loader`；验证通过
  后把现有 Provider 的 typed `enterUpdater(rockusb.enter-loader)` 接到 durable intent、固定
  argv、HDC disconnect、bounded `ld` polling 和 Core cross-mode rebind。能力未知/失败时不
  猜测，转入物理按键向导。
- r2 允许 TASK-RKFUI-001A 在 TASK-RKFUI-001 的 contract implementation 已合入、但 E0
  hardware observation 尚未完成时先行 characterization。原因是维护者选择软件进态作为
  本轮 Loader 来源；继续要求 001 `done` 才能启动 001A 会形成循环依赖。E1 成功后同窗口
  只读 Loader observation 可作为 001A evidence，但 TASK-RKFUI-001 的 signed Sandbox E0
  receipt 仍须由其自身探针独立生成，两个任务不得互相冒充完成。
- r3 只修正上述一次性 characterization 的固件事实：设备窗口 E0 读回确认同一 serial
  摘要目标当前运行 OpenHarmony `7.0.0.33`，而 r2 pin 为 `7.0.0.34`，所以 E1 以 0
  dispatch fail closed。r3 merge 后仅把该字段替换为 `7.0.0.33`；目标、USB transport、
  HDC、clean discovery tool、typed argv、`maxRuns = 1`、截止时间和全部零 destructive
  边界均保持不变。
- 新增 Flash application facade、SwiftUI 页面和中英文 String Catalog：显式刷新/选择
  设备、选择本地 `images.tar.gz`、流式校验、plan-only、精确计划、危险确认、阶段日志、
  normal/切换中/Loader/歧义状态、软件进态、物理按键 fallback、execution-mode badge、
  取消与 RecoveryGuide。
- 复用 `RockchipRockUSBFlashProvider`、`RockchipFlashProfile`、authorization gate、
  WorkflowStep/Journal/Session/Artifact/HostStorage/Power/DeviceBinding 语义；不另建旁路刷机
  引擎。
- 在 E0 access gate 通过后，新增封闭 argv 的 `rkdeveloptool` executor，仅接受 Provider
  生成且授权通过的 `ld`/`ppt`/九个 `wlx`/`rd` 步骤；每个副作用前 durable intent、完成后
  outcome，分区写期间 criticalNonInterruptible，取消只在安全边界生效。
- 用 fake executable/fixtures 覆盖成功、错误、取消、崩溃窗口、断连、畸形输出和
  outcomeUnknown；最后由独立真机任务验证产品 UI 路径。

### Out of scope

- 不复制、链接、分发或执行 BlueTool 的 `BlueTool.exe`、`upgrade_tool.exe`、
  `CmdDloader.exe`、DLL、PAC、`uboot.img` 或任何 bundled image；其许可证和供应链身份
  未知。
- 不实现 BlueTool 的 `UL/DI` 十文件流程、8G uboot 覆盖、紫光展锐 PAC/dayu600 路径、
  PR/issue/任意 URL 下载或自动化测试页。
- 不支持 Maskrom/miniloader `db/gpt/ul`，不猜测相似 Rockchip 型号，不扩展 DAYU200
  支持声明。
- 不对未具名验证的设备/固件启用 `reboot loader`，不以 VID/PID、LocationID、设备型号
  相似或“当前只有一台”完成跨模式自动重绑定；证据不足必须由用户确认 identity diff。
- 不改变 Core Requirement、Acceptance Scenario、journal/manifest schema 或现有
  hardware support matrix；不实现 Windows/Linux 端口。
- “一键”表示在目标与镜像已选择后从一个 `Start Flash Job` 入口启动受控工作流，不表示
  跳过 preflight、精确计划、强确认、权限门或 postflight。

### Observable behavior before/after

- Before：Flash 导航只显示通用 HDC diagnostics；App 无 RockUSB 列表、镜像选择、计划或
  执行入口。
- After：Flash 页面可发现/选择 normal HDC 或符合 Profile 的 Loader 设备，校验本地镜像并
  展示完整计划；对已验证组合可由 typed HDC step 软件进入 Loader，其他情况显示物理按键
  fallback。plan-only 始终可辨识且零 mutation。仅当 signed Sandbox access、工具身份、
  binding/rebind、prerequisites、强确认、storage/power 和 authorization 全部通过时，交互式
  execute 才能进入 typed executor；任一不确定项均明确阻断。

## Scope(涉及的 Requirement/AC)

- Requirements:`REQ-FLASH-001`、`REQ-FLASH-002`、`REQ-FLASH-003`、
  `REQ-FLASH-004`、`REQ-FLASH-005`、`REQ-FLASH-007`、`REQ-FLASH-008`、
  `REQ-FLASH-009`、`REQ-FLASH-010`、`REQ-FLASH-011`、`REQ-FLASH-012`、
  `REQ-FLASH-013`、`REQ-FLASH-015`、`REQ-UX-001`、`REQ-UX-005`、
  `REQ-UX-006`、`REQ-UX-007`、`REQ-I18N-001`、`POL-WORKFLOW-001`、
  `POL-RECOVERY-001`、`POL-MODE-001`、`REQ-DEV-001`、`REQ-DEV-002`、
  `REQ-DEV-003`、`REQ-DEV-006`、`REQ-DEV-008`
- Acceptance:`AC-FLASH-001-01`、`AC-FLASH-002-01`、`AC-FLASH-003-01`、
  `AC-FLASH-004-01`、`AC-FLASH-005-01`、`AC-FLASH-005-02`、
  `AC-FLASH-007-01`、`AC-FLASH-008-01`、`AC-FLASH-009-01`、
  `AC-FLASH-010-01`、`AC-FLASH-011-01`、`AC-FLASH-012-01`、
  `AC-FLASH-013-01`、`AC-FLASH-015-01`、`AC-FLASH-015-02`、
  `AC-UX-001-01`、`AC-UX-005-01`、`AC-UX-006-01`、`AC-UX-007-01`、
  `AC-I18N-001-01`、`AC-DEV-001-01`、`AC-DEV-002-01`、`AC-DEV-002-02`、
  `AC-DEV-003-01`、`AC-DEV-003-02`、`AC-DEV-006-01`、`AC-DEV-008-01`
- Contracts/schemas:复用现行 `WorkflowStep`、journal、manifest、hardware evidence 和
  Rockchip Provider/Profile；新增 parser fixture/registry 和 App presentation 值，不修改
  locked schema。
- 是否需要 Core baseline bump:否；`spec-impact.md` 说明现有 Requirement 已覆盖本次
  macOS 产品接线。

## Safety, privacy, and compatibility

- Discovery 仅是 E0/read-only；多设备允许展示，但 execute 必须显式选择并在 dispatch 前
  读回/核对同一 physical target 与 durable binding。列表位置、PID 或“当前只有一台”均不
  单独构成身份。
- `reboot loader` 是 E1/deviceMutation：只从 durable HDC binding materialize，先记录 intent
  并完成用户影响确认；重枚举后必须先 durable 保存符合 Core threshold 的新 binding
  revision，才允许任何 `ppt/wlx/rd`。不能自动确认时展示 diff 等待用户。
- HDC unavailable/unsupported、命令失败、deadline 超时、出现 `0x5000`/Maskrom/未知 mode
  或多候选时 fail closed，并显示经 CHG-2026-016 真机验证的 DAYU200 物理按键步骤；App
  继续只读观察，不声称代替物理动作。
- 外部进程只接受固定 executable descriptor + argv；不允许 shell、命令字符串拼接、
  PATH 猜测、环境覆盖或 BlueTool 二进制 fallback。
- App 不调用 `sudo`/`osascript`/Authorization Services，不安装 driver/helper，不改
  ACL/group/系统 rule。访问失败区分 permission/driver/offline，并提供最小人工指导。
- 用户选择的工具与镜像使用 security-scoped access；默认日志只记录脱敏路径和 hash，
  raw tool output 作为受控本地 Artifact，不自动上传。
- 分区写 intent 已 durable 而 outcome 缺失时进入 `outcomeUnknown`，禁止自动重放；恢复
  只展示现有 CHG-2026-016 Loader `wlx` 人工路径，不承诺自动救砖。
- macOS：新增实现并需重新跑相关 platform/UI/real-hardware 验收。Windows/Linux 仍为
  deferred/not started，不产生支持声明。
- 回滚：移除 Flash App composition 即可回到当前 CLI/Provider；既有 Profile、CLI、
  evidence 和 hardware matrix 不迁移、不改写。
- `REQ-FLASH-015` 的实现解释必须在批准本 change 时由维护者确认：交互式人类在 App 内
  查看精确计划并完成强确认后启动 typed executor，是否仍属于“人类操作者亲自执行”。若
  维护者判断不兼容，TASK-RKFUI-003/004 保持 blocked，并先起草 Core delta；Agent 不自行
  选择更宽松解释。

## Approval and readiness boundary

- PR #297 只把本 proposal 以 `status: proposed` 登记到 `main`
  (`88dee1dc83d4e9e4675ea36803d5b261f1cdf3da`)，不构成 task execution。
- 本 governance-only readiness PR 同时起草 `proposed→approved` 与
  `TASK-RKFUI-001 blocked→ready`；两项状态只在维护者 review/merge 后生效。批准范围严格等于
  本 proposal、design、verification 和 tasks 已列范围，不修改 Core Requirement/AC/schema。
- 对 `REQ-FLASH-015`，批准解释为：交互式人类必须在 App 内查看 exact plan、完成强确认并
  主动启动 typed executor；后台、自主或跳过确认的启动不属于“人类操作者亲自执行”。该解释
  只解除后续设计歧义，不批准任何真实 Flash dispatch。
- 本次 readiness 只允许 TASK-RKFUI-001 的 contract/fake 工作与具名窗口内 E0/read-only
  `rkdeveloptool ld` access spike。TASK-RKFUI-001A/002/003/004 全部继续 `blocked`；E1
  mode switch 与 E2 flash/erase/format/unlock/update 的 standing authorization 均为 0。

### r2 scoped revision and readiness boundary（2026-07-24；on merge）

- 分类：proposal revision / dependency correction / E1 hardware window = D1 + D2。PR 只修改
  change 治理文档与既有 blocked preflight evidence，不携带 tool registry/code、probe
  implementation 或设备 run；维护者 merge 只批准下列 scope，不构成 E1 已执行或 capability
  `supported`。
- Tool remediation：允许后续独立 TASK-RKFUI-001 implementation remediation 把 discovery
  registry、Swift adapter/tests 与 signed E0 probe 从
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`
  原子 repin 到 clean artifact
  `bbd7bdc0fb121d414fb61085e77211cc1fdd9a3b6c6b285c54380f70e56c9923`。版本仍为
  `rkdeveloptool ver 1.32`，upstream commit 仍为
  `304f073752fd25c854e1bcf05d8e7f925b1f4e14`；host preflight 观察到 ad-hoc
  signature、quarantine absent。registry/code/probe 任一未同步时 fail closed。
- Provider boundary：上述 repin **仅适用于 discovery `ld`**。现有
  `RockchipFlashProfile.pinnedToolchainFingerprint`、Provider、Authorization 和 destructive
  evidence 的 `038a8a0e…3611` 不修改、不借用、不作废；TASK-RKFUI-003/004 因此继续
  `blocked`。
- Dependency correction：TASK-RKFUI-001A 不再等待 TASK-RKFUI-001 `done`；它只依赖已在
  main 的 001 contract implementation/hardening、r2 merge 和本节 D2 pins。001A 的 E1 结果
  只回答 exact combination 的 capability，不能替代 001 的 signed Sandbox E0 receipt。
- E1 window：r2 merge 后只允许对 serial SHA-256
  `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
  对应的 DAYU200、OpenHarmony 7.0.0.34、USB、HDC `Ver: 3.2.0d` /
  SHA-256 `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`
  执行最多一次 typed
  `["-t", "<durable-connect-key>", "shell", "reboot", "loader"]`。connect key 必须从
  dispatch 前已 durable 的 revision 1 binding materialize，不能写入仓库；任一 identity、
  firmware、binding、tool、transport 或现有 HDC server ownership 不匹配即零 E1 dispatch。
- 窗口截止 `2026-07-31T16:00:00Z`；E2/destructive、`sudo`、HDC server lifecycle
  mutation、default target、shell string、`ppt/wlx/rd` dispatch 均为 0。HDC disconnect 后
  只允许 bounded clean-tool `ld` observations；错误 mode、0/多 candidate、timeout 或 rebind
  证据不足均产生 `unsupported|unknown`/人工确认等待，不自动继续。
- 零投机堆叠：本 r2 合入前不得起草 tool repin implementation PR、001A probe/run PR 或发送
  真实 HDC command；r2 合入后仍按 TASK-RKFUI-001 remediation 与 TASK-RKFUI-001A 各自独立
  PR 交付。

### r3 scoped firmware repin and readiness boundary（2026-07-24；on merge）

- 分类：proposal revision / firmware pin correction / E1 hardware window = D1 + D2。PR 只修改
  change 治理文档与 blocked E0 preflight evidence；不携带 probe implementation 或 E1 run。
- Drift evidence：在 `main`
  `fee0f9f507f7a008cc75952bb895056205c6d4f1` 上，固定 read-only
  `hdc -t <durable-connect-key> shell param get const.product.software.version` 返回
  `OpenHarmony 7.0.0.33`。serial SHA-256 精确命中 `958780b2…7a7e`，HDC/server 与 clean
  `rkdeveloptool` pins 均命中；因 r2 firmware 为 `7.0.0.34`，E1/reboot/Loader observation
  dispatch 全为 0。sanitized receipt 见
  `evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.json`。
- Scoped replacement：维护者 merge r3 后，r2 E1 window 中唯一被替换的字段是 firmware
  `OpenHarmony 7.0.0.34` → `OpenHarmony 7.0.0.33`。这是对当前 exact combination 的新
  D2 接受，不把历史 `7.0.0.34` evidence 重新分类，也不扩展到其他 firmware。
- Unchanged pins：DAYU200 serial SHA-256 `958780b2…7a7e`、USB、HDC absolute path /
  `Ver: 3.2.0d` / `48395ba8…d260`、clean `rkdeveloptool 1.32` /
  `bbd7bdc0…9923` / upstream `304f0737…` / no quarantine、revision 1 binding、
  `["-t", "<durable-connect-key>", "shell", "reboot", "loader"]`、截止
  `2026-07-31T16:00:00Z` 与 `maxRuns = 1` 全部不变。blocked preflight 未消费 run budget。
- Safety boundary：E2/destructive、`ppt/wlx/rd`、默认 HDC target、host shell string、
  `sudo`、HDC server lifecycle mutation 与失败重试仍为 0。implementation/run 只能在本 r3
  合入后从新 `main` 开始；任一 pin 再漂移或窗口过期必须重新 readiness。
