# Design — CHG-2026-059 规格实施文档

> 读者：在 ArkDeck 仓实现 Swift 侧的人。
> 本文只讲**怎么做**与**为什么必须这么做**；要不要做见 `proposal.md`。
>
> ArkForge 侧的对应产物都在 ArkForge 仓，路径在文中逐处给出，都能直接跑。
> **2026-08-15 更新：controller execution/admission surface 与 dispatch 均已实现**，
> 第 8 节列了逐项状态。还没有的是**在真机上跑一次**——现有端到端测试用的是
> 脚本化 tool port，不是设备（AF-V2.4）。

> **NRU-004 超越声明（2026-08-19，ArkForge main `c049a11`）**：本稿描述的
> vendor fixed-tool 执行面已被 CHG-2026-063 整体退役，正文保持原样仅作实施
> 记录。照抄以下契约今天会失败：
>
> - **§8.2/§8.6 的启动契约已删除。** `--rkdeveloptool <路径>` 与
>   `--rkdeveloptool-sha256` 不再是合法旗标（`unknown argument`，daemon 拒绝
>   启动）；原生 RockUSB port 内建，不存在「不给工具就没有 dispatcher」的
>   形态；§8.6 的 `-v` 自检与 quarantine 关卡随外部工具一起消失。§9 表格里
>   钉 `231a05ef…` 的行同此。
> - **§8.5 的 `HelloAck` 示例值已变**：`toolchain_id = "arkforged-native-rockusb"`，
>   `toolchain_sha256` = daemon 启动时自量的自身构建摘要。比对义务不变。
> - **§0/§8 的 `wlx`/`ppt`/`rl`/`rd` 词汇仅存于历史**：封闭面现为七个语义动作，
>   `Write LBA (100%)` stdout 标记由 `writePayloadSha256` 写线摘要比对承接。
> - **顶注「还没有真机跑一次」已过时**：2026-08-18 首过
>   （`EVD-AFA-DAYU200-20260818-001`，本 change `evidence/task-afa-001/`），
>   2026-08-19 vendor 移除后原生面复验全绿
>   （`EVD-NRU-DAYU200-20260819-001`，chg-2026-063 evidence）。
>
> authority 分界本身（permit 签发、managed control、connectKey 永不过界）
> 不受 NRU-004 影响，仍是现行事实。ArkForge 仓的草稿正本已带同等声明。

---

## 0. 一句话架构

~~~text
ArkDeck                                   arkforged
───────                                   ─────────
拥有 HDC、connectKey、target binding
拥有 authority：签发 StepPermit
                    ──── materializePlan ──▶   物化公私计划（已实现，只读）
                    ◀─── watchJob 事件流 ────   状态、admission 请求、回执
                    ──── submitStepPermit ─▶   验证 permit、落 intent、派发
                    ◀─── managedControl 请求──   「请你帮我进 Loader」
                    ──── submitReceipt ────▶   authority 观测到什么
                                              拥有 rkdeveloptool、封闭命令面
                                              拥有读域三态判定、durable journal
~~~

**ArkDeck 不再拥有的**：`wlx`/`rl` 的 argv、扇区地址、读窗语义、写进度解析。
**ArkForge 永远不会拥有的**：connectKey、hdc 路径、endpoint、shell、server 生命周期。

---

## 1. 要删的东西（先删，再接）

建议实现顺序把删除放在最前，因为它决定了后面每一步的形状。

### 1.1 `RockchipProviderAction` 的两个 case

`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DeviceProviders/DeviceProviderContract.swift`

~~~swift
case flashPartitions(RockchipRuntimeFlashBundle)     // 删
case verifyFlashReadback(RockchipRuntimeFlashBundle) // 删
~~~

### 1.2 `RockchipRuntimeActionHost` 中随之而去的实现

- `case .flashPartitions` / `case .verifyFlashReadback` 两个分支；
- `arguments: ["wlx", mapping.partitionName, image.stableDescriptorPath]` 的构造；
- `readSectors(executable:offsetSectors:count:...)` 与 `characterizeMediumReadDomain`；
- `RockchipWriteProgressParser`；
- `RockchipPinnedPartitionTable.span(for:)` 的扇区跨度守卫；
- `RockchipRockUSBFlashProvider.closedCommandSurface` 里的 `wlx`/`wl`/`rl`
  （`ld`/`ppt`/`rd` 也一并移交——ArkForge 侧同名封闭命令面在
  `crates/arkforge-provider/src/rockchip_execute.rs`）。

### 1.3 保留的十一个 case

其余全部是 HDC 侧的，只有 ArkDeck 能做。完整归属表在 ArkForge 仓
`adapters/arkforge-arkdeck-adapter/src/control.rs`，
每个 baseline case 都被标为 `keptByAuthority` / `keptInternal` /
`delegatedToArkForge`，并有测试断言三类之和穷尽 baseline。

### 1.4 一条不能省的收尾

`characterizeMediumReadDomain` 删掉，但它承载的教训不能跟着删。
实现 PR 需要在 `docs/` 留一条索引，指向 ArkForge 的 AD-006 与 AD-019：
2026-08-04 那九次「写入未落盘」全是冤案，来自 `rl` 在读窗外返回的 uniform filler。
2026-08-15 ArkForge 用一条独立代码路径复现了同一读窗（AD-019）。

> 这不是形式主义。删掉一段代码等于删掉写它的人当时知道的东西，
> 除非那件事被写在别处。

---

## 2. StepPermit：字节必须一致

### 2.1 权威定义

ArkForge `crates/arkforge-authority-api/src/lib.rs`，`StepPermit` 与 `permit_body()`。

签名体 = `permit_body(permit)` 的**确定性 CBOR 编码**，
tag = `HMAC-SHA256(pairingSecret, signingBody)`。

签名体**不含** `integrity_tag`——tag 覆盖 body，body 不覆盖 tag。

### 2.2 编码规则（RFC 8949 §4.2.1）

Swift 侧必须做到，一条都不能少：

| 规则 | 说明 |
|---|---|
| map key 按**编码后字节**排序 | 不是按字符串字典序。`"a"` 与 `"aa"` 的编码长度不同，排序结果可能与直觉相反 |
| 整数用最短形式 | `23` 编码为 `0x17`，不是 `0x1817` |
| 无浮点 | ArkForge `architecture.md` 15.4 在摘要模型里禁止浮点 |
| 无 tag、无不定长 | 编码器不得产生 major type 6 或不定长容器 |
| 文本按 UTF-8 原样 | 不做 NFC/NFD 归一 |

### 2.3 交叉验证向量

`permit-vectors.md`（本目录）给了三组 (permit, secret) → (signingBody 摘要, tag)。
Swift 侧的契约测试必须逐组复现。这是 `AFA-AC-2`。

对不上时的排查顺序（按经验命中率）：

1. map key 排序用了字符串序而不是编码后字节序；
2. 整数没用最短编码；
3. `singleUse` 这类 bool 被编成了 0/1 整数而不是 major type 7 的 20/21；
4. 32 字节摘要被编成了 hex 文本而不是 byte string。

ArkForge 那个测试可以打印完整 signingBody 供逐字节比对。

### 2.4 重传：重放字节，不要重新推导

~~~text
授权决定作出 → 完整 permit（含 tag）先落盘 → 才返回
重传同一个 permitID → 读出已存字节原样发出
~~~

**禁止**在重传时重新构造 permit 再签一次。两份字节不同的「同一张」permit
正是完整性标签要消除的歧义（ArkForge `architecture.md` 8.6）。
ArkForge 侧对同一个 permitID 的第二次 admission 会直接拒绝为
`IntentAlreadyRecorded`，不会创建第二个 intent。

### 2.5 PairingEpoch

任一进程重启就轮换。旧 epoch 签发的、**尚未消费**的 permit 永远不能被首次消费——
它作废，admission 重来。ArkForge 侧在 `verify_permit` 里判 `StalePairingEpoch`。

pairing secret 只在内存里，不落盘明文（ArkForge `architecture.md` 15.2）。

---

## 3. 线上契约

正本：ArkForge `proto/arkforge.proto`。以下是实现要点，不是重复定义。

### 3.1 方向：daemon 从不主动呼出

daemon 在 `watchJob` 流上**请求**，authority 回头**调用**。
每一条消息都是 client 发起的，authority 因此可以答、可以拒、可以干脆不答，
三者对 daemon 是不同的事件。

### 3.2 API 编号

| # | API | 会话 | 说明 |
|---:|---|---|---|
| 6 | `startExecution` | controller | 已实现；未配对 authority 时返回 `UNAVAILABLE` |
| 7 | `watchJob` | 任意 | 已实现。轮询而非推送——daemon 所有连接共用一把锁，一个停在那里等下一条事件的 handler 会挡住产生它的那次调用 |
| 12 | `submitStepPermit` | **controller only** | 已实现。答复一次 admission |
| 13 | `submitManagedControlReceipt` | **controller only** | 已实现。报告 authority 自己观测到什么 |

12/13 必须是 controller-only：能提交 permit 的 public 调用方，
就是一个没人配对过的 authority。ArkForge 侧
`SessionKind::may_call` 已按此实现并有测试。

### 3.3 admission 往返

~~~text
JobEvent{kind=STEP_ADMISSION_REQUESTED, admission=StepAdmissionSnapshot{request_id, …}}
        ▼
ArkDeck：拿自己的 binding 重新验证 snapshot 的每一项
        ▼
submitStepPermit{request_id, permit_cbor, integrity_tag, pairing_epoch}
   或    submitStepPermit{request_id, refusal:"…"}
~~~

**snapshot 要重新验证，不能回显。** 被原样送回的 snapshot 什么也没证明。
至少要核对：`plan_sha256` 是不是自己批准的那个计划、
`admitted_device_facts_sha256` 是不是自己当前 binding 的设备、
`observed_at_epoch_ms + snapshot_lifetime_ms` 有没有过期。

拒绝要用 `refusal` 字段明说。沉默与拒绝在 daemon 侧是两件事：
拒绝走 `CancelledSafe`，沉默走超时后的 snapshot 作废重来。

### 3.4 managed control 往返

~~~text
JobEvent{kind=MANAGED_CONTROL_REQUESTED, control_request=ManagedControlRequest{action, …}}
        ▼
ArkDeck：执行映射表里那一串 provider action
        ▼
submitManagedControlReceipt{request_id, accepted, facts, evidence_sha256}
~~~

`accepted=false` **不等于**「什么都没发生」。模式切换可能已经生效而没被观测到，
daemon 会把它记成 outcome unknown 而不是失败。要表达「确实没发生」，
用 `failure_reason` 说清楚依据。

---

## 4. ManagedDeviceControlPort 的 Swift 侧

映射表正本：ArkForge `adapters/arkforge-arkdeck-adapter/src/control.rs`。

| 语义动作 | provider action 序列 | 语义成功 |
|---|---|---|
| `ENTER_UPDATER` | `observeHDCNormalUSB` → `enterLoader` → `waitForHDCDisconnect` → `waitForLoader` → `rebindLoader` | 命令被接受 **且** 绑定身份断开 **且** 恰好一台设备以 Loader 重新绑定 |
| `REBOOT_TO_NORMAL` | `waitForBoundHDCReconnect` | 原绑定目标以相同 stable identity 回到 normal |
| `READ_PRODUCT_FACTS` | `verifyBoundBuild` | 绑定目标答出 `const.product.model` |
| `READ_BUILD_FACTS` | `verifyBoundBuild` | 绑定目标答出 `const.ohos.fullname` |

### 4.1 `ENTER_UPDATER` 是四次观测，不是一条命令

只映射 `enterLoader` 会让「命令被接受」被记成「设备已进入 Loader」。
ArkForge `architecture.md` 16.2 要求的是
「HDC accepted + expected disconnect + unique Loader rebind」三者齐备。

### 4.2 超时按实测取，不要按估计

ArkForge 2026-08-15 在真机上连续采样两次切换（AD-020）：

| 方向 | 认不出任何设备的时长 |
|---|---:|
| normal → loader | 3,725 ms |
| loader → normal | **15,579 ms** |

回 normal 的空窗 **15.6 秒**。任何短于此的 deadline 都会把健康的板子判成没回来。
现有 `reconnectDeadlineMilliseconds: 120_000` 余量充足，保持即可——
但这个数从今天起有实测依据，不再是估的。

同一次实测还确认：**serial digest 与 topology digest 两者都变**。
把 USB serial 当作跨模式稳定标识的实现会在这里认不出同一块板子。
唯一可用的跨模式锚点是 ArkDeck 自己的 stable identity。

### 4.3 回执里绝对不能出现的东西

~~~text
connectKey  hdcExecutablePath  hdcEndpoint  argv  shell  serverLifecycleAction
~~~

ArkForge 侧有断言（`control.rs` 的 `FORBIDDEN_RECEIPT_FACTS`），
daemon 收到含这些 key 的回执会拒绝。ArkDeck 侧需要对应的 secret-scan 测试，
覆盖 receipt、journal 与 UI 事件三处。

---

## 5. RuntimeJobEngine 接线

### 5.1 不变的部分

`flash.dayu200` 的 operation 契约、step 集合、UI 事件形状、
现有的 authorization/confirmation 判定——**一律不动**。
已有 journal 不需要迁移。

### 5.2 变的部分

原来：`RuntimeJobEngine` → `RockchipRuntimeActionHost` → 子进程。

现在：`RuntimeJobEngine` → `arkforged`：

1. `materializePlan`（已有的只读 API）拿到 ArkForge plan 与 plan digest；
2. `startExecution{plan_id, plan_sha256}` 开一个**尚不能产生外部效果**的 daemon job；
3. 把 `(ArkDeck job, daemon job, plan/digest, artifact, target binding, purpose,
   toolchain)` correlation 原子写入 job-owned
   `arkforge-runtime-state.json` sidecar；
4. 写入 ArkDeck 对应 step intent；只有第 3、4 步都 durable 后才进入 `watchJob`；
5. 对每个 `STEP_ADMISSION_REQUESTED`：跑现有的授权判定 → 签 permit → `submitStepPermit`；
6. 对每个 `MANAGED_CONTROL_REQUESTED`：跑映射表里的 provider action → `submitReceipt`；
7. 对每个 `ACTION_RECEIPT`：先把 canonical terminal receipt 写入同一个
   job-owned ArkForge sidecar，再写 correlated step outcome、驱动 UI。

arkforged 在发布第 7 步事件之前，已经把 canonical receipt body、semantic digest
和该事件的 cursor 一起写入 `SemanticReceiptRecorded`。因此 ArkDeck 与 arkforged
都重启时，新 daemon 能以同一个 cursor 重放同一张 receipt；ArkDeck 仍须按 durable
correlation 重验 job/plan/step/postflight，不能只信 terminal 字符串。

这里的顺序是 crash contract，不是缓存优化。`ArkForgeLaneHost` 的 actor cache
不构成 durable authority；进程重启后只能用记录里的 daemon job id 调
`watchJob`，不得为同一次 ArkDeck attempt 再调 `startExecution`。如果进程恰好死在
第 2、3 步之间，daemon 最多留下一个没有 permit、不能触碰设备的 orphan job。
如果死在 terminal receipt 与 step outcome 之间，reconcile 用已落盘 receipt 关闭原
intent，不重签 permit，也不创建新 intent。

### 5.3 postflight 期望值的来源（这条最容易做错）

期望的 build 版本**必须来自被写入的那份 `system.img`**，
不是归档文件名，不是 build log。

实测依据：2026-07-28 的 daily 归档名字写 `7.0.0.35`，它的 build log 也写 `7.0.0.35`，
而它产出的设备答 **`OpenHarmony-7.0.0.36`**（本仓 `RockchipFlashProfile.dayu200`
的注释已经记了这条，2026-08-04 在刷好的板子上确认）。

ArkForge 从镜像里提取这个值并放进计划的 postflight 期望
（`crates/arkforge-artifact/src/dayu200.rs`，AD-016）。
ArkDeck 侧读到 `ACTION_RECEIPT` 时按它比对即可，不要另起一份推导。

> 顺带：这个值在 2 GiB `system.img` 的第 320,762,067 字节。
> ArkForge 早先按「属性在文件头部」的假设设了 64 MiB 扫描上界，
> 结果在所有真实归档上都提取不到——这条假设从来没被量过。

---

## 6. 失败与恢复

### 6.1 daemon 崩溃

ArkForge 的 journal 落盘规则：与派发决定相关的记录在 `append` 返回前 `fsync`。
重启后按 `architecture.md` 13.3 的表推导处置，且**任何一行都不允许重放派发**。

ArkDeck 侧要处理的形态：

| daemon 重启后 | ArkDeck 该做什么 |
|---|---|
| 该 permit 已消费并有回执 | 只接受 canonical body、关联 ID 与 digest 全部复验通过的原回执；不要重签 |
| 该 permit 消费中断、无回执 | outcome unknown。**不要**签第二张 permit |
| 该 permit 已签发但 daemon 没落 intent | 可以重传**同一个** permitID；不能签新的 |

第二行是最容易做错的：一个「重试一下」的按钮会在这里造成第二次写入。

ArkDeck 自身崩溃遵循同一规则：恢复先读 durable correlation，再被动观察那个精确
daemon job。只有 exact `succeeded` 且 canonical terminal receipt 通过 job/plan/
postflight digest 校验，才可补写原 intent 的成功 outcome；`cancelledSafe` 可补写
confirmed-not-executed；缺失、未来 terminal 值、`confirmedFailed` 或
`outcomeUnknown` 都不能据此重放，必要时转入独立的只读设备 reconcile。
被动观察必须消费完整的有限 poll：同一条 durable 历史里，先前的
`outcomeUnknown` 可以被随后 read-only reconcile 产生的 `succeeded` 或
`confirmedFailed` 覆盖；在第一个 unknown 处提前返回会漏掉真正终态和重放 receipt。

### 6.2 掉电

ArkForge 的 fsync 只证明到**进程死亡**为止。macOS `fsync(2)` 不冲刷盘内缓存，
`F_FULLFSYNC` 需要 libc 而 ArkForge 的零依赖决定（AFD-0001）不允许。
记为已知边界（AD-017），不记为已通过的门。ArkDeck 侧不要据此声称掉电安全。

### 6.3 取消

- 只读步骤：尽快取消；
- permit 之前：`CancelledSafe`；
- 模式切换派发之后：等 rebind/reconcile；
- 写入中：排队到下一个安全边界。`wlx` 进行中**不可**中断——
  杀进程不等于安全取消，只会把结果变成 unknown。

#### 6.3.1 与 `RuntimeDispatchCancellationResolution` 的对应（2026-08-16 补）

`#1309`–`#1311` 之后 `RuntimeJobEngine` 有了自己的取消安全边界模型：
`.drained` 是 process-group 拆除的**正面证明**，可以把 intent 关成 cancelled；
`.unconfirmed` 留在 outcomeUnknown。本 change 把 `flash.dayu200` 的 dispatch
移出 ArkDeck 进程之后，**那个进程组不再属于 ArkDeck**，这条 lane 上不存在
可取得的 drain proof。

对应关系必须写死，否则会得到「杀不掉所以判 unknown」这种既不安全也不真实的结论：

| ArkForge `cancelJob` 的答复 | ArkDeck 侧应记 | 依据 |
|---|---|---|
| `CancelledSafe`（permit 尚未消费，工具从未 spawn） | 等价于 `.drained`，关成 cancelled | 比 drain proof 更强：不是「进程已清理」，是「进程从未存在」 |
| `CANCEL_NOT_SAFE`（permit 已消费，`wlx` 进行中） | **两者都不是**——取消请求被**拒绝**，job 继续跑到该 step 的回执 | `wlx` 不可中断；记成 unconfirmed 会把一次**正在正常完成**的写入记成未知结果 |
| daemon 失联 / 无回执 | 等价于 `.unconfirmed`，outcomeUnknown，且**不得**重签 permit | 与 6.1 同一张表 |

所以 `flash.dayu200` 的 `cancellingAtSafeBoundary` 语义是「等这一步的回执」，
不是「拆进程组并证明拆干净了」。ArkDeck 侧不要为这条 lane 去找一个它已经不拥有的证明。

`AFA-AC-3` 之外另加一条否定用例：写入中途请求取消，断言得到的是
`CANCEL_NOT_SAFE` 的拒绝，而不是一个 unconfirmed 的取消回执。

---

## 7. 实现顺序建议

| 步 | 内容 | 可独立验证 |
|---:|---|---|
| 1 | 删两个 case 及其实现 | 编译 + grep 断言 |
| 2 | CBOR 确定性编码器 + permit 签发 | 三组交叉验证向量 |
| 3 | permit 对抗矩阵 | 七项否定用例，零派发 |
| 4 | `ManagedDeviceControlPort` | 四个动作 + secret-scan |
| 5 | `RuntimeJobEngine` 接线 | 与 ArkForge 联调（需 ArkForge 侧 AF-V2.4 接线同期完成） |
| 6 | 真机全量刷写 | `AFA-AC-6..10` |

第 2、3 步不依赖 ArkForge 侧的任何新代码，可以立刻开始并独立验收。

---

## 8. ArkForge 侧的状态（2026-08-15 更新）

controller execution/admission surface **已实现并固定**：

| 项 | 状态 |
|---|---|
| `startExecution`（API 6） | ✅ 建 job、开 per-job journal、发布第一条 admission |
| `watchJob`（API 7） | ✅ 事件流，`from_sequence` 支持断线续传 |
| `cancelJob`（API 8） | ✅ permit 之前 `CancelledSafe`；之后拒绝为 `CANCEL_NOT_SAFE` |
| `submitStepPermit`（API 12） | ✅ 逐项验证并落 durable intent |
| `submitManagedControlReceipt`（API 13） | ✅ 校验 request/action、拒绝禁止事实、落回执与 checkpoint |
| 新增消息的 Rust 编解码 | ✅ 全部 round-trip 测试 |
| permit 的 CBOR 解码 | ✅ `StepPermit::from_canonical_bytes` |

九条端到端测试在 `crates/arkforged/tests/admission_surface.rs`，
用真实归档物化的真实计划驱动整套握手。

### 8.1 ArkDeck 侧现在可以对着什么写

- **permit 编码**：`StepPermit::from_canonical_bytes` 做**往返校验**——
  解出来再编回去必须与输入逐字节相同，否则拒绝为 `NotCanonical`。
  这意味着 Swift 侧只要有一个字节的编码差异就会被当场拒绝，而不是默默通过。
  先用 `permit-vectors.md` 的三组向量对齐，再接线。
- **snapshot 新鲜度**：`SNAPSHOT_LIFETIME_MS = 60_000`。晚到的 permit 被拒为
  `SNAPSHOT_EXPIRED`，daemon 同时发布一条**新的** admission——不需要重启 job，
  重新签一张即可。
- **禁止事实**：回执里出现 `connectKey`/`hdcExecutablePath`/`hdcEndpoint`/
  `argv`/`shell`/`serverLifecycleAction` 任一，整条回执被拒为
  `RECEIPT_CARRIES_FORBIDDEN_FACTS`。不是丢字段继续。
- **`accepted: false` 的含义**：job 进入 `outcomeUnknown`，不是失败。
  要表达「确实没发生」，在 `failure_reason` 里说清依据。
- **配对**：daemon 用 `--pair-from-stdin <epoch>` 启动，authority 把 secret 写进
  它的 stdin 再关闭。没配对时 `startExecution` 与 API 12/13 一律返回
  `EXECUTION_DISABLED`，且这个判断在解析 payload **之前**——
  它是 daemon 的常驻事实，不是某一次请求的事实。

### 8.2 dispatch（2026-08-15 已实现）

写入执行也接上了：`crates/arkforged/src/dispatch.rs`。

- **在服务锁之外跑。** job registry 交出一份 `PendingDispatch`，dispatcher
  **取走**它（取走即标记 in-flight，第二个 dispatcher 拿不到同一份），
  释放锁，跑完，再回来记录。锁只在两头各持有一次短写。
  这条不是洁癖：daemon 所有连接共用一把 mutex，2 GiB 的 `wlx` 要几分钟，
  在锁里跑会冻住本该报告它的那条事件流。
- **一个 step 的全部私有动作按序跑**：只读子动作在前，唯一的 primary 在后
  （architecture.md 6.3），回执报告 primary 的结果。
  最初我只跑了第一个动作，结果 `characterize-read-domain` 跑了、
  `readback-partition` 没跑——九个目标一个判定都没有。
- **镜像在第一次写入时才 staging**，一次，之后复用。没走到写入的 job 不必先付
  4 GB 的解压代价。
- **失败分两类，这是本模块唯一的判断**：tool 被 spawn **之前**的拒绝
  → `ConfirmedNoEffect`（设备可证明未被触碰）；spawn **之后**的失败
  → `OutcomeUnknown`。搞反任一方向，要么把真实效果记成「无效果」，
  要么让每一次被拒的前置检查都变成待 reconcile 的 job。

daemon 用 `--rkdeveloptool <绝对路径>` 启动 dispatcher；不给就没有 dispatcher，
job 会停在第一个需要派发的步骤上等着（这是诚实的停，不是崩）。

### 8.3 端到端测试

`crates/arkforged/tests/admission_surface.rs` 十一条，其中
`a_job_dispatches_every_step_and_reaches_a_verdict_on_each` 用一个脚本化的
tool port 把整个计划跑完：九条 `wlx` 按 Profile 声明顺序发出、`ppt` 先于它们、
`rd` 在最后、九个 readback 全部给出 `typedSkip` 且不带任何 strength。
脚本里的 `ppt` 输出与读面行为都取自 2026-08-15 的真机实测（AD-018、AD-019）。

**仍然没有的**：真机上跑一次。测试用的是脚本 port，不是设备。

### 8.4 Readiness：机器可读，且不是「配对了就行」

daemon 的执行就绪是**两个常驻事实**，都在启动时确定，任何请求都改不了：

| 事实 | 缺了会怎样 |
|---|---|
| authority 已配对 | permit 验不了，回执没地方去 |
| fixed tool 已绑定 | 需要本 daemon 派发的步骤跑不了 |

**只配对不算就绪。** 早先的版本只看配对，结果 job 会一路走到第一个 dispatch、
花掉一张 permit、然后停在那里——那是要 reconcile 的状态，而不是「没启动」。
现在 `startExecution` 在**解析 payload 之前**就按常驻事实拒绝，
并且**一次报全部缺失项**，免得修完一个才发现还有第二个。

### 8.5 ArkDeck 侧怎么读

握手就能读到，不必先物化一个跑不了的计划：

~~~text
HelloAck {
  execution_ready:      bool
  execution_blockers:   ["NO_PAIRED_AUTHORITY", "NO_DISPATCHER"]   // 稳定码
  toolchain_id:         "rkdeveloptool"
  toolchain_sha256:     "231a05ef…"   // 本仓 rockchip-component-build@1.0.0 的产物
}
~~~

`execution_blockers` 为空 ⟺ `execution_ready` 为真。

> 这里的示例摘要在 2026-08-16 之前写的是 `bbd7bdc0…`。那是
> `pinnedReadOnlyDiscovery`，也就是 homebrew 的那份——AD-011 里挂死在 dyld 的那一份。
> 一个会被复制进真实命令行的示例不该指向它，已改为下一节说的那一份。

**把 `toolchain_sha256` 和你计划里的 toolchain 摘要比一下。** 不一致时
`startExecution` 会拒为 `TOOLCHAIN_DIGEST_MISMATCH`——toolchain 摘要是 maturity
组合键的一部分（architecture.md 12.3），换一份工具就是在跑一个没人发布过的组合。
daemon 会拒，但你不必等它拒才知道。

### 8.6 工具摘要强制比对，并且必须证明它能跑

~~~bash
arkforged --runtime-dir <dir> --profile profiles/dayu200.yaml \\
  --pair-from-stdin <epoch> \\
  --rkdeveloptool /absolute/path \\
  --rkdeveloptool-sha256 <64 hex>
~~~

绑定一个工具要过两关，缺一不可：

1. **字节是不是钉的那些**——`--rkdeveloptool-sha256` 必填，不符拒绝启动。
2. **这些字节能不能跑**——以 device-free 的 `-v` 探测，5 秒超时。

第二关不是多余的。AD-015 说的就是**字节相等不等于能用**：同一份
`bbd7bdc0…` 带 `com.apple.quarantine` 时挂死在 dyld，摘要检查一切正常。
2026-08-15 完整复现并诊断：

~~~text
带 quarantine   → 探测 5,009 ms 未返回 → 杀掉 → 拒绝启动，错误里直接给出
                  `xattr -d com.apple.quarantine <path>`
清除 quarantine → 摘要一字不差 → 自检 207 ms 通过 → execution: ready
~~~

同一次实测还发现 quarantine 的**第二种形态**：并不总是挂死，也可能立即退出、
不产生任何输出。两种形态都被拒，且都会附上 quarantine 证据——
用 `/usr/bin/xattr` 尽力查一次，查不到就明说查不到，绝不含糊成「未知原因」。

> 超时 5 秒不是对「工具可能有多慢」的估计。实测答案是 25–207 ms;
> 5 秒远在任何合理答案之外，因为这一关要抓的失败不是慢，是**永远不返回**。

工具跑不了时 daemon **拒绝启动**，并提示去掉 `--rkdeveloptool` 就能起一个只读 daemon。
这条规则简单：给了 `--rkdeveloptool`，它就必须被钉住、匹配、并且能跑。

除此之外，ArkForge 侧的执行机制——封闭命令面、读域三态、staging 与写前
revalidate、durable journal、permit 单次使用——**都已完成并在真机上验证到写入前的
最后一步**，见 ArkForge 仓 `docs/evidence/runs/2026-08-15-dayu200-flash-rehearsal.md`。

---

## 9. 基线复核（2026-08-16）

ArkForge `architecture.md` 2.1 要求：**实施前必须以当时最新 main 再做一次差异复核**。
本节是那次复核。

- ArkForge 侧的审计基线：`2849c5c1`（`refactor(TASK-AIN-021): adopt app concurrency defaults (#1302)`，2026-08-13）
- 复核时 ArkDeck main：`b5f5a52b`（2026-08-15），其间 **10 个 commit**

### 9.1 本 change 要拆掉的东西：没动过

六个目标文件自基线以来 **0 个 commit**——
`RockchipRuntimeActionHost`、`RockchipProviderAction`、`RockchipRuntimeComposition`、
`RockchipFlashExecutionHost`、`RockchipPinnedPartitionTable`、`RockchipWriteProgressParser`。
第 1 步（删两个 case 及其实现）可以按原样进行。

### 9.2 两处 `flash.dayu200` 分支被删掉了，但语义没变

`RuntimeJobEngine` 里两处对 `flash.dayu200` 的特判在 `#1309`–`#1311` 期间消失，
都是**泛化而非删除**：

1. artifact store 必需性判断收进 `RuntimeArtifactService.requiresArtifactStore(reference:)`，
   原清单（含 `flash.dayu200`）逐项保留；
2. 「mapped step 没有 artifact store」从只对 `flash.dayu200` 抛错，改为对每个 mapped step
   抛错——严格更 fail-closed。

两处对本 change 都是中性或有利的。

### 9.3 `RuntimeJobEngine` 长了 544 行，其中一处与本 change 相关

新增的取消安全边界模型（`.drained` / `.unconfirmed` / process-group drain proof）
写在本 change 提案之后。对应关系已补进 **6.3.1**。这是本次复核唯一需要改设计的发现。

### 9.4 工具选型（ArkForge AD-023）

ArkForge 2026-08-16 实测：本机三份 `rkdeveloptool` 里只有**一份**可出厂。

| 摘要 | 来源 | 动态库闭包 | 能否出厂 |
|---|---|---|---|
| `bbd7bdc0…` | homebrew（= `pinnedReadOnlyDiscovery`） | — | ❌ 且带 quarantine 会挂死（AD-011/AD-015） |
| `038a8a0e…` | 本机构建（= `pinnedProduction`，2026-08-15 彩排跑的那份） | 含 `/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib` | ❌ 依赖只有那台机器才有的路径 |
| `231a05ef…` | 本仓 `rockchip-component-build@1.0.0`（ArkDeck.app 内捆绑的那份） | 七个系统库，libusb 静态链入 | ✅ 且 Developer ID + Hardened Runtime + 空 entitlement 字典俱全 |

`verification.md` 的 Environment 早已写明要用 `rockchip-component-build@1.0.0` 的产物，
方向一致；本节补的是**为什么**，以及一条治理事实：

**`RockchipFlashExecutionHost` 今天仍然钉 `038a8a0e…`**
（`RockchipDeviceDiscovery.swift:21-28`，消费者在 `:872/1154/1179/1356`）。
这与 ADR-0003 自己写明的迁移缺口一致——「pinned discovery registry 继续描述当前
user-selected E0 路径，直到另一个 change 引入 bundled component registry 并显式迁移
其消费者」——所以不是缺陷，但它对本 change 有一个具体后果：

> toolchain 摘要是 maturity 组合键的一部分。用哪一份工具跑 `AFA-AC-6` 的真机全量刷写，
> 决定了**发布的是哪个组合**。用 `038a8a0e…` 通过，等于把组合钉在一份出不了厂的工具上，
> 将来换成 `231a05ef…` 出厂时那是另一个组合，需要另一次真机通过。

**建议：在第一次真机写入之前就把 `flash.dayu200` 这条 lane 切到 `231a05ef…`。**
现在换的代价是零（还没有任何写入证据），真机通过之后再换是一次完整重跑。
这属于 ADR-0003 的 bundled component registry 迁移，需维护者决定是并入本 change
还是单开一个。

### 9.5 结论

复核通过，改动三处：新增 6.3.1（取消语义对应）、新增 9.4（工具选型），
并把 8.5 的示例摘要从 `bbd7bdc0…` 改为 `231a05ef…`。

`revision` 保持 **r1**：r1 从未提交过 review——本 change 在 2026-08-16 之前
一直是工作区里的未跟踪目录。改动发生在提交之前，不构成一次修订轮次。

---

## 10. 工具已切到 `231a05ef…`（2026-08-16 定）

9.4 提出的选择已经拍板：**`flash.dayu200` 这条 lane 在第一次真机写入之前就切到
本仓 `rockchip-component-build@1.0.0` 的产物**。

### 10.1 为什么现在切

toolchain 摘要是 maturity 组合键的一部分。现在换的代价是零——还没有任何写入证据；
真机通过之后再换是一次完整重跑。而彩排用的 `038a8a0e…` 已被实测证明不可出厂
（链接 Homebrew 的 libusb），所以「先用它跑通、以后再说」等于先发布一个必然要作废的组合。

### 10.2 钉的是**已签名**的那份

`openspec/integrations/rockchip/bundled-component/1.0.0/package.json` 记的是
`be753c69…`，且 `"unsigned": true`——那是 Code Sign On Copy **之前**被摄入的字节。
`arkforged` 哈希的是它将要执行的那个文件，也就是签名后的那份：

| 用途 | 摘要 |
|---|---|
| `--rkdeveloptool-sha256`、计划里的 toolchain digest | `231a05ef…`（已签名，App 包内） |
| 组件包记录、依赖白名单来源 | `be753c69…`（未签名摄入） |

钉错一个，daemon 会以 `... hashes to X, and --rkdeveloptool-sha256 pins Y` 拒绝启动。
两个摘要并排放在 `ArkForgeToolchainPin` 里，就是为了让这个差别是**可见的**而不是被发现的。

### 10.3 实测

2026-08-16 用捆绑组件启动真实 `arkforged`：

~~~text
dispatch: /Applications/ArkDeck.app/Contents/MacOS/rkdeveloptool (231a05ef…)
  signing: arm64 com.arkdeck.desktop.rkdeveloptool (runtime, team 8AQTYW5FKR, no entitlements)
  self-test: rkdeveloptool ver 1.32 in 18 ms
execution: not ready (NO_PAIRED_AUTHORITY)
~~~

它同时通过了 ArkForge 的 release 签名条款（`--require-release-signing`，AFD-0003）
——彩排那份过不了。握手回报的 `toolchain_sha256` 就是 `231a05ef…`，
本 change 的契约测试用这段真实字节断言它与 `ArkForgeToolchainPin` 一致。

### 10.4 没有动的东西

`RockchipDiscoveryIntegrationProfile.pinnedProduction` **保持 `038a8a0e…` 不变**。
它描述的是 ADR-0003 说的那条 user-selected E0 遗留路径，会随第 1 步一起消失；
在它还活着的时候改它的钉值，等于在一个即将删除的路径上引入一次未经验证的行为变化。
新的钉值是新加的 `ArkForgeToolchainPin`，只服务于 ArkForge 这条 lane。

---

## 11. IPC 客户端（2026-08-16 已实现）

第 3、5 步都要它，而它此前在 Swift 侧不存在。新增 target `ArkForgeIPC`
（依赖 `ArkDeckCore`，已在架构矩阵里加一行）：

- **proto3 wire 子集**，手写，与 ArkForge `crates/arkforge-ipc/src/wire.rs` 逐条对应。
  三条规则承载兼容性契约：零值不写、嵌套消息即使为空也写、未知字段跳过而
  **未知枚举值硬失败**（architecture.md 15.2）；
- **消息集**：Hello/HelloAck、Request/Response/Error，以及执行面 API 6/7/8/12/13
  用到的全部 payload；
- **UDS 传输**：4 字节大端长度前缀，长度在分配**之前**检查上限；
- **`ArkForgeDaemonClient`**：controller 会话、握手、请求/响应、`watchJob` 事件流。
  它只搬字节：能编码 authority 签好的 permit、能编码 authority 选择的 refusal，
  但没有任何办法自己构造其中任何一个。

### 11.1 测试用的是真实 daemon 的字节

契约测试里的 golden frame 是 2026-08-16 从真实运行的 `arkforged` 上抓的，
不是照着 `.proto` 手工拼的。这个区别是有意的：只对着自己编码器测的 codec
只会与自己一致，而本仓要避免的失败恰恰是「authority 说了一种 daemon 听不懂的方言」。

抓到的三条：带工具绑定但未配对的 `HelloAck`、一条 OK 的 `Response`、
一条 `startExecution` 的 `NO_PAIRED_AUTHORITY` 拒绝。
