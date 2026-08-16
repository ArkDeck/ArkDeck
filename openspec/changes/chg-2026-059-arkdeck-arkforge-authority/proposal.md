---
id: CHG-2026-059-arkdeck-arkforge-authority
revision: 5
status: approved # r1 由 PR #1317 merge；r2 由 PR #1325 merge。TASK-AFA-001 可开工
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# ArkDeck 保留 authority，把 Rockchip lowering 交给 ArkForge

> 恰四类声明：本 change 不新增 published operation——`flash.dayu200` 保持原样。
> 它改变的是该 operation 的**实现归属**：ArkDeck 继续做 authority 与 HDC owner，
> 停止在自己进程里降解 Rockchip 命令与扇区地址，改为向 `arkforged` 签发 StepPermit。
> 因为触及设备执行栈与 provider action 集合，按 `AGENTS.md` 控制平面条款走
> OpenSpec + 维护者 PR review/merge。

## §19 治理循环四问

1. **对应的真实安全风险**：destructive 的 Rockchip 写入路径目前有**一份**实现，
   在 ArkDeck 进程内；它同时持有 authority、HDC 所有权和 `wlx`/`rl` 的 argv 与扇区
   地址。这让「谁批准了这次写入」和「谁执行了这次写入」落在同一个信任域里，
   审计时无法把两者分开。`RockchipRuntimeActionHost` 里 `flashPartitions` 与
   `verifyFlashReadback` 两个 case 是这份耦合的落点。
2. **为什么不能直接通过 Runtime 缺陷修复**：这不是缺陷，是边界。把执行侧移出去需要
   一个 provider action 集合的收缩和一条新的 permit 信道，两者都是 Repo-plane 变化。
3. **推进哪个 Golden Journey**：GJ-4。今天 DAYU200 刷写只能由 ArkDeck 自己降解；
   本 change 之后同一条 Journey 由 ArkDeck 批准、由 ArkForge 执行，
   而 ArkDeck 的生产 lowering 里不再出现任何 Rockchip 命令或地址。
4. **为什么不会产生后续治理连锁**：本 proposal 合入即批准；只创建一个垂直实现任务。
   ArkForge 侧的对应实现已经完成并在真机上验证到写入前的最后一步
   （见下「ArkForge 侧现状」），本 change 不为它再开治理项。

## Audit baseline（2026-08-15）

| 项 | 值 |
|---|---|
| 本仓基线 | `e3b9aff3 feat(TASK-DHA-001): integrate pinned ArkTrace summary analyzer` |
| ArkForge 基线 | `26b0d86 docs(AF-V2.5)`；395 tests 全绿 |
| 读的 ArkDeck 源 | `DeviceProviderContract.swift` `RockchipProviderAction`；`RockchipRuntimeActionHost.swift`；`RockchipFlashProfile.swift`；`RockchipRockUSBFlashProvider.swift` |
| 真机 | DAYU200 / RK3568，序列 `150100424a…4900`，当前 `OpenHarmony-7.0.0.37` |

> class 定为 `integration`：本 change 不新增 published operation，也不改变
> `flash.dayu200` 的可观察语义，改的是 rkdeveloptool 这条工具链的归属——
> 它从 ArkDeck 进程内移到 ArkForge。若维护者认为「destructive 执行路径跨进程」
> 应按 `capability` 或 `core` 处理，请在 review 时重分类；本文不替维护者定这一条。

## Why（根因）

`RockchipRuntimeActionHost` 今天做四件事：拥有 HDC、决定 authority、
降解 `rkdeveloptool` 命令、解释设备读回。前两件只有 ArkDeck 能做；后两件是设备机制，
与 ArkDeck 的产品语义无关，而且已经被证明**难以在产品代码里做对**：

- 2026-08-04 的九次「写入未落盘」判定全部是冤案。它们来自 `rl` 在读窗之外返回的
  uniform filler，而写入实际已落盘并可启动（ArkForge AD-006）。修复链 PR #1066–#1070
  是在产品代码里补 read-domain 语义——这类知识每一条都要在 ArkDeck 里重学一遍。
- 同一份知识在 ArkForge 里已经是可测试的机制：读域三态判定
  （Verified / TypedSkip / Failed）、erased-medium filler 的独立分类、
  「TypedSkip 不计入任何 verified 强度」的类型级保证。

`architecture.md`（ArkForge）9.1 已经写明这条分工：ArkDeck 拥有 HDC endpoint、
server ownership、connectKey、target binding；ArkForge 只能通过 typed
`ManagedDeviceControlPort` 请求语义动作。本 change 把这条分工落到代码上。

## ArkForge 侧现状（本 change 的前置事实，非本 change 的工作）

ArkForge 已经完成并在真实 DAYU200 上验证到写入前的最后一步：

| 能力 | 状态 |
|---|---|
| 真实归档导入 + 17 成员逐值 parity | ✅ 与本仓 `RockchipFlashProfile.dayu200` 钉值逐项一致，机器检查 |
| 构建事实提取 | ✅ 从真实 `system.img` 提取 `OpenHarmony-7.0.0.36`——与本仓 2026-08-04 在刷好的板子上实测到的答案一致 |
| durable engine | ✅ journal 落盘 + fsync policy 随 record kind 固定；撕裂尾部穷举复原；13.3 崩溃处置表由 journal 推导 |
| StepPermit 单次使用 | ✅ 跨进程重启由 durable ledger 保证；顺序由类型强制，逐个 by value 消费 |
| Rockchip fixed-tool Provider | ✅ 封闭命令面 `ld`/`ppt`/`wlx`/`rl`/`rd`；argv 只在 Provider 内降解 |
| 读域三态判定 | ✅ 真机实测：1 Verified / 2 Failed / 6 TypedSkip，读窗边界与 AD-006 相容 |
| 九个镜像落盘 + 写入前 revalidate | ✅ 4,017,485,774 字节，九个 SHA-256 全部与本仓钉值一致 |
| 九条 `wlx` 真实 argv 降解与前置校验 | ✅ 全部通过，**全部未派发**——设备写入次数 0 |

缺的只有一样：一张 permit。ArkForge 刻意签发不了——它的架构守卫禁止
`crates/arkforged` 引用签发函数。这正是本 change 要补上的那一半。

## What changes

### 1. `RockchipProviderAction` 收缩两个 case

删除（不是绕过）：

- `case flashPartitions(RockchipRuntimeFlashBundle)`
- `case verifyFlashReadback(RockchipRuntimeFlashBundle)`

以及它们在 `RockchipRuntimeActionHost` 里的实现、`rkdeveloptool` 的
`wlx`/`rl` argv 构造、`RockchipPinnedPartitionTable` 的扇区跨度守卫、
`RockchipWriteProgressParser`、`characterizeMediumReadDomain`。

> 留一份「以防万一」的 lowering 等于对同一条 destructive 路径保留两份实现，
> 这正是 ArkForge `architecture.md` 21.3 明令禁止的。

保留的十一个 case 全部是 HDC 侧的，只有 ArkDeck 能做。完整归属表见
`adapters/arkforge-arkdeck-adapter/src/control.rs`（ArkForge 仓），
其中每一个 baseline case 都被分类为 keptByAuthority / keptInternal /
delegatedToArkForge，并有测试断言三类之和穷尽 baseline。

### 2. ArkDeck 实现 `ExecutionAuthority`

`flash.dayu200` 的 Runtime dispatch 改为：

~~~text
RuntimeJobEngine
  → arkforged materializePlan（已有的只读 API）
  → 对每个 public step：现有的 authorization/confirmation 判定不变
  → 签发 StepPermit（HMAC over canonical CBOR body，keyed by pairing secret）
  → arkforged 执行该 step，返回 ActionReceiptSummary
  → RuntimeJobEngine 记 journal、驱动 UI
~~~

permit 的字段与签名体由 ArkForge `arkforge-authority-api` 定义；
本 change 在 Swift 侧实现同一套 canonical CBOR 编码与 HMAC-SHA256。
**重传必须重放已存字节**，不得确定性重新推导——两份字节不同的「同一张」permit
正是完整性标签要消除的歧义。

### 3. ArkDeck 实现 `ManagedDeviceControlPort`

四个语义动作，映射到保留下来的 provider action：

| 语义动作 | ArkDeck action 序列 | 语义成功 |
|---|---|---|
| `EnterUpdater` | `observeHDCNormalUSB` → `enterLoader` → `waitForHDCDisconnect` → `waitForLoader` → `rebindLoader` | 命令被接受 **且** 绑定身份断开 **且** 恰好一台设备以 Loader 重新绑定 |
| `RebootToNormal` | `waitForBoundHDCReconnect` | 原绑定目标以相同 stable identity 回到 normal |
| `ReadProductFacts` | `verifyBoundBuild` | 绑定目标答出 `const.product.model` |
| `ReadBuildFacts` | `verifyBoundBuild` | 绑定目标答出 `const.ohos.fullname` |

`EnterUpdater` 是四次观测而不是一条命令。只映射 `enterLoader` 会让
「命令被接受」被记成「设备已进入 Loader」。

回执里**不得**出现：`connectKey`、hdc 可执行路径、hdc endpoint、argv、shell、
server lifecycle 动作。ArkForge 侧有断言，ArkDeck 侧需对应的 secret-scan 测试。

### 4. `rd` 的归属

`rebootToNormal` 是唯一一个设备半边是 Rockchip 命令的控制动作——
Loader 模式下设备没有 HDC 可说话。`rd` 由 ArkForge 通过它自己的 fixed-tool port 发出；
ArkDeck 出的是只有它能出的那一半：盯住那台**确切绑定**的设备回来。

### 5. maturity 与证据

ArkForge 的 `RK-M02` 目前是 `hardwareGated`——「AF-V2 要求先有一次真机全量刷写通过」。
本 change 的实现 PR 完成那一次刷写后，**只发布这一个组合**
（ArkDeck authority + 本机平台 + 该 toolchain digest + 该 evidence set）为
ProductionVerified。maturity 是组合键，一次通过不解锁别的组合。

## Requirements

### AFA-REQ-001 — Rockchip lowering 归属

ArkDeck SHALL NOT 在产品代码中构造 `rkdeveloptool` 的 argv、扇区地址或读窗语义。
`flashPartitions` 与 `verifyFlashReadback` 两个 provider action SHALL 被删除而非绕过；
保留任一形式的 fallback lowering 等于对同一条 destructive 路径保留两份实现。

### AFA-REQ-002 — Permit 签发

ArkDeck SHALL 以与 ArkForge 逐字节一致的确定性 CBOR 编码构造 StepPermit signing body，
并以 HMAC-SHA256 签发。完整 permit（含 tag）SHALL 在返回前落盘；重传 SHALL 重放已存字节，
SHALL NOT 确定性重新推导。`PairingEpoch` SHALL 随任一进程重启轮换，旧 epoch 的未消费
permit SHALL 作废。

### AFA-REQ-003 — Managed device control port

ArkDeck SHALL 实现四个语义控制动作，并按发布的映射表执行对应的 provider action 序列。
`EnterUpdater` 的语义成功 SHALL 要求命令被接受、绑定身份断开、且恰好一台设备以 Loader
重新绑定。回执 SHALL NOT 携带 connectKey、可执行路径、endpoint、argv、shell 或
server lifecycle 动作。

### AFA-REQ-004 — 可观察契约不变

`flash.dayu200` 的 operation 契约、step 集合、UI 事件形状与现有 authorization/confirmation
判定 SHALL 保持不变。已有 journal SHALL NOT 需要迁移。

### AFA-REQ-005 — Postflight 期望值来源

刷后 build 校验的期望值 SHALL 来自被写入的 system image 内提取的
`const.ohos.fullname`，SHALL NOT 来自归档文件名或 build log。

## Acceptance

- **AFA-AC-1**：`RockchipProviderAction` 不再含 `flashPartitions`/`verifyFlashReadback`；
  产品代码中 `wlx`/`rl`/`ppt` 不作为 argv 元素出现。
- **AFA-AC-2**：对 `permit-vectors.md` 的三组向量，Swift 侧产出与 Rust 侧逐字节相同的
  canonical CBOR 与 HMAC tag。
- **AFA-AC-3**：篡改 tag、过期 epoch、过期时间、action 不符、plan 不符、非 single-use、
  重复消费——七项全部拒绝且零派发；重复消费返回原回执而非二次执行。
- **AFA-AC-4**：同一 permitID 重传重放已存字节，不产生第二个 StepIntent。
- **AFA-AC-5**：四个语义动作正例通过；回执 secret-scan 在 receipt/journal/UI 三处均无泄漏；
  未观测到断开或未唯一重绑时 `EnterUpdater` 不报成功。
- **AFA-AC-6**：真实 DAYU200 九分区 + userdata 刷写通过；九条 `wlx` 全部
  `Write LBA from file (100%)`；`rd` 后设备以原 stable identity 回到 normal。
- **AFA-AC-7**：读窗内目标给出 Verified 或 Failed；窗外目标给出 TypedSkip 并记录
  `skipped-lba-read-window` 与 `readDomainDetail`；TypedSkip 不计入任何 verified 强度。
- **AFA-AC-8**：刷后设备答 `const.ohos.fullname = OpenHarmony-7.0.0.36`。
- **AFA-AC-9**：写入中途 SIGKILL `arkforged` 后重启，该 permit 判为 outcomeUnknown 并
  拒绝再次派发；journal 可复原；不产生第二个 StepIntent。

## Out of scope

- `compatibility alias`（`flash.dayu200` → generic adapter）与 legacy decoder：
  本 change 之后 `flash.dayu200` 的实现已经换掉，别名与 legacy 解码另开 change。
- generic UI：本 change 不改 UI，Runtime 事件形状保持不变。
- `arkforged` 的签名/entitlement/打包契约：对齐 #1299 体系，另开 change（ArkForge AD-007）。
- DAYU600 / Unisoc：ArkForge `architecture.md` 17.5 十八条证据门 0 条 PASS，
  本 change 不涉及。

## Safety, privacy, compatibility and rollback

- **安全**：destructive 路径从「一个进程既批准又执行」变成「ArkDeck 批准、
  ArkForge 执行、permit 单次使用且跨崩溃有效」。写入前的三方一致
  （Profile allowlist、设备自身分区表、artifact manifest）由 ArkForge 强制，
  任一不符在 spawn 之前拒绝。
- **隐私**：permit 与回执都不携带 HDC 路径、connectKey 或 argv。
- **兼容**：`flash.dayu200` 的 operation 契约、step 集合、UI 事件形状不变；
  变的是谁执行。已有 journal 不需要迁移。
- **回滚**：本 change 是删除 + 委派。回滚 = revert 实现 PR，
  `RockchipRuntimeActionHost` 的两个 case 与其实现随之回来。
  没有需要清理的持久状态；ArkForge 的 journal 是它自己的目录。
- **不回滚的部分**：即便回滚，2026-08-04 的读域教训仍然成立——
  ArkDeck 的 `characterizeMediumReadDomain` 不能因为本 change 被删掉而被忘记。
  实现 PR 需在 `docs/` 留一条指回 ArkForge AD-006/AD-019 的索引。

## 强制重复与新任务自检（PRODUCT-LOOP §5/§17）

本 change 不新增治理框架、不创建 readiness-only PR，
只创建一个垂直实现任务 `TASK-AFA-001`，其实现 PR 同车交付：
Swift 侧 permit 签发与控制端口、两个 case 的删除、契约测试、
真实 DAYU200 全量刷写与 build postflight、Task done、verification 结论。
