# Tasks — CHG-2026-059

单任务垂直交付。`status: approved` 与本 Task 的 `ready` 只有在 proposal PR 经维护者
review/merge 进入 protected `main` 后生效；合入前不得开始实现 PR。

> **NRU-004 超越声明（2026-08-19）**：下文所有 fixed-tool/`--rkdeveloptool`/
> `wlx`/`231a05ef…` 表述为历史实施记录；执行面现为 `arkforged` 原生 RockUSB
> （CHG-2026-063）。真机通过记录见 `evidence/task-afa-001/`
> （AFA-AC-6/7/8 done；AC-9/AC-10 真机半仍缺）。

## TASK-AFA-001 — ArkDeck 做 authority，ArkForge 做 Rockchip 执行

- Status:in-progress（proposal PR #1317 已 merge。已完成：第 2 步 permit 签发
  （对着 ArkForge 三组交叉验证向量逐字节通过）、IPC 客户端（新 target `ArkForgeIPC`，
  golden frame 取自真实 daemon）、工具切到 `231a05ef…`（design 第 10 节）。
  以及第 1 步删 lowering（`wlx`/`rl`/`ppt` 及其判定逻辑全部移除，legacy journal
  译为具名不可重放拒绝，读域教训索引到 `docs/design/rockchip-read-domain.md`）。
  第 1、2 步与 IPC 客户端已由 #1328 merge。
  本 PR 再加：第 3 步签发侧对抗矩阵（`ArkForgeExecutionAuthority`，七条具名拒绝
  + 零派发断言 + AFA-AC-4 字节重放）、第 4 步 `ArkForgeManagedControlPort`
  （四个语义动作、`EnterUpdater` 三次观测缺一不可、回执禁止事实在**构建处**拦下、
  同一扫描覆盖 journal/UI）、第 5 步 `ArkForgeFlashSession`（watchJob 循环、
  admission/control 应答、AFA-AC-10 取消三态；真实 client 已声明满足同一 protocol）。
  未完成：把 session 接进 `RuntimeJobEngine` 自己的 dispatch 分支、第 6 步真机。
  在那之前 `flash.dayu200` 仍在授权前被拒，5 条端到端 recovery 测试保持 skip。
  仅在本实现 PR 经维护者 review/merge 后生效）
- Golden Journey:GJ-4
- Platform:macos
- Requirements:`AFA-REQ-001`…`AFA-REQ-005`（单任务覆盖全部五条）
- Acceptance:`AFA-AC-1..10`
- Depends on:本 proposal r1 merge
- Allowed paths:
  - `Packages/ArkDeckKit/Package.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCore/**`
  - `Packages/ArkDeckKit/Sources/ArkForgeIPC/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Bootstrap/DeviceBootstrap.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Rockchip*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/ArkForge*.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobEngine.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeRecoveryService.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckStorage/JournalEventValidation.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckProcess/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckAgentDaemonMain/**`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckCLIMain.swift`
  - `Packages/ArkDeckKit/Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift`
  - `Packages/ArkDeckKit/LaunchAgents/LaunchAgentService.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/**`
  - `docs/design/rockchip-read-domain.md`
  - `openspec/changes/chg-2026-059-arkdeck-arkforge-authority/**`
- Applicable failure patterns:
  - `AF-004`（producer 到真实 dispatcher/postflight 全链）——permit 必须真的到达
    `arkforged` 并真的驱动一次写入，不能以 mock 通过；
  - `AF-008`（trust boundary 对抗矩阵）——permit 的完整性标签、pairing epoch、
    单次使用、重传语义各要有否定用例；
  - `AF-011`（不得以 exit 0 或文件名替代 postflight 证明）——本 change 的
    postflight 期望值必须来自**写入的那份 system.img**，不是归档名、不是 build log。
    这条有实测：2026-07-28 的 daily 名字写 7.0.0.35、log 写 7.0.0.35，
    而它产出的设备答 7.0.0.36。
- Production reachability:
  `Agent → owner-only UDS → RuntimeJobEngine → flash.dayu200 → ExecutionAuthority
   → StepPermit → arkforged → Rockchip fixed-tool Provider → rkdeveloptool wlx
   → read-domain-aware verification → rd → ManagedDeviceControlPort(ReadBuildFacts)
   → RuntimeJobEngine postflight`
- Trusted fact sources:
  - archive 字节/大小/hash 与 17 成员：ArkForge CAS + manifest（本仓钉值可交叉核对）；
  - 设备自身分区表：`rkdeveloptool ppt`，由 ArkForge 解析并与 Profile 做三方一致；
  - 读域：运行时实测（`rl` 近端/远端探测），不是 Profile 常量；
  - build postflight 期望值：从写入的 `system.img` 内提取的 `const.ohos.fullname`；
  - 设备身份与 connectKey：ArkDeck 独有，ArkForge 不接收。
  调用方不能同时构造任一事实及其证明。

### 子项

1. **删除两个 case 及其实现**
   - `RockchipProviderAction.flashPartitions` / `.verifyFlashReadback`
   - `RockchipRuntimeActionHost` 中对应的 `wlx`/`rl` argv 构造、
     `RockchipPinnedPartitionTable` 扇区跨度守卫、`RockchipWriteProgressParser`、
     `characterizeMediumReadDomain`
   - 断言：产品代码 grep 不到 `"wlx"`、`"rl"`、`"ppt"` 作为 argv 元素

2. **StepPermit 签发（Swift）**
   - canonical CBOR（RFC 8949 §4.2.1 确定性编码）+ HMAC-SHA256
   - 与 ArkForge `arkforge-authority-api::StepPermit::signing_body` 逐字节一致
   - 交叉验证向量：ArkForge 仓提供 N 组 (permit, secret, tag)，Swift 侧全部复现
   - 重传重放已存字节；`PairingEpoch` 随任一进程重启轮换

3. **ManagedDeviceControlPort（Swift）**
   - 四个语义动作，映射见 proposal §3
   - `EnterUpdater` 必须包含断开与重绑观测
   - 回执 secret-scan：`connectKey`/路径/argv/shell/lifecycle 一律不出现

4. **RuntimeJobEngine 接线**
   - `flash.dayu200` 的 dispatch 改走 permit 路径
   - 现有 authorization/confirmation 判定不变
   - `ActionReceiptSummary` → journal → UI 事件形状不变

5. **真实 DAYU200 全量刷写**
   - 九分区 + userdata
   - 读域感知验证：readback 与 typed-skip 各自出现且分类正确
   - build postflight：设备答 `OpenHarmony-7.0.0.36`
   - crash/cancel：至少一次在写入中途杀掉 `arkforged`，验证重启后
     该 permit 被拒绝为 outcomeUnknown 且**不重放**

6. **maturity 发布**
   - 只发布 (ArkDeck authority, 本机平台, 该 toolchain digest, 该 evidence set)
     这一个组合为 ProductionVerified


### Not allowed without a new change

- 新增 published operation
- 改 `flash.dayu200` 的 step 集合或 UI 事件形状
- 保留任何形式的 Rockchip lowering 作为 fallback
