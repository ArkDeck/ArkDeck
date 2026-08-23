# Verification — CHG-2026-059

> Change:CHG-2026-059-arkdeck-arkforge-authority@r6
> Status:planned；proposal merge 只批准 scope，不代表实现或真机通过

> **NRU-004 超越声明（2026-08-19，ArkForge main `c049a11`）**：本矩阵的
> AFA-AC-6/7/8 已于 2026-08-18 以**当时的 fixed-tool 执行面**真机通过
> （`EVD-AFA-DAYU200-20260818-001`，`evidence/task-afa-001/`；AC-6 的
> 「九条 `wlx` 全部 `Write LBA from file (100%)`」正是那个执行面的观测点）。
> 其后 CHG-2026-063 退役了该执行面：Environment 中「pinned rkdeveloptool
> （homebrew 那份不算，quarantine 会挂死在 dyld）」一条作废，`arkforged`
> 原生执行、不再绑定任何外部工具；AC-6 的观测点在原生面由 `write-partition`
> 语义回执承担（`writePayloadSha256` 与 staged digest 逐一比对），
> 2026-08-19 原生面全量复验全绿（`EVD-NRU-DAYU200-20260819-001`）。
> AC-9/AC-10 的真机半仍未做，`evidence/README.md` 如实登记。

## Environment

- macOS 14+ 登录用户 LaunchAgent；Swift 6 / ArkDeckKit；当前 protected-main Catalog digest。
- 一台已接管、信任完成的 DAYU200（RK3568）。**本 change 的验收会覆盖它的 userdata。**
- ArkForge `arkforged`，pinned rkdeveloptool（本仓 `rockchip-component-build@1.0.0` 产物；
  homebrew 的那份不算——它虽然字节相同，但带 quarantine 时会挂死在 dyld，
  见 ArkForge AD-015）。
- 一份真实 DAYU200 daily 归档。基线用例：
  `version-Daily_Version-OpenHarmony_7.0.0.35-20260728_180253-dayu200_img.tar.gz`，
  SHA-256 `6a023c73…f064e`，730,769,584 字节——与本仓
  `RockchipFlashProfile.dayu200.archiveSHA256` 相同。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| AFA-AC-1 lowering 已移除 | 产品代码扫描 + 编译 | `RockchipProviderAction` 无 `flashPartitions`/`verifyFlashReadback`；产品代码中 `wlx`/`rl`/`ppt` 不作为 argv 元素出现 | grep + 契约测试 |
| AFA-AC-2 permit 字节一致 | ArkForge 提供的交叉验证向量 | Swift 侧对每组 (permit, secret) 产出与 Rust 侧逐字节相同的 canonical CBOR 与 HMAC tag | 契约测试，向量入 evidence |
| AFA-AC-3 permit 对抗矩阵 | 篡改 tag / 过期 epoch / 过期时间 / action 不符 / plan 不符 / 非 single-use / 重复消费 | 七项全部拒绝，且**零派发**；重复消费返回原回执而不是二次执行 | 契约测试 |
| AFA-AC-4 重传语义 | 同一 permitID 重传 | 重放已存字节；不得确定性重新推导；不得产生第二个 StepIntent | 契约测试 + journal 断言 |
| AFA-AC-5 控制端口边界 | 四个语义动作正例 + 回执 secret-scan | 回执不含 connectKey/路径/argv/shell/lifecycle；`EnterUpdater` 未观测到断开或未唯一重绑时不报成功 | 契约测试 + 真机 |
| AFA-AC-6 真机全量刷写 | 九分区 + userdata | 九条 `wlx` 全部 `Write LBA from file (100%)`；`rd` 后设备回到 normal 并以原 stable identity 重绑 | 真机 run 记录 |
| AFA-AC-7 读域感知验证 | 写入后 readback | 读窗内的目标给出 Verified 或 Failed；窗外目标给出 TypedSkip 并在回执记 `skipped-lba-read-window` 与 `readDomainDetail`；**TypedSkip 不计入任何 verified 强度** | 真机 run 记录 |
| AFA-AC-8 build postflight | 刷后读设备 | 设备答 `const.ohos.fullname = OpenHarmony-7.0.0.36`——注意归档名写的是 7.0.0.35；期望值必须来自写入的 `system.img`，不是归档名也不是 build log | 真机 run 记录 |
| AFA-AC-9 crash 不重放 | 写入中途 SIGKILL `arkforged`，重启 | 该 permit 被判为 outcomeUnknown 并拒绝再次派发；journal 可复原；不产生第二个 StepIntent | 真机 run 记录 + journal |
| AFA-AC-10 取消不伪造 drain proof | `wlx` 进行中请求取消 | 得到 `CANCEL_NOT_SAFE` 的**拒绝**，job 继续跑到该 step 的回执；**不得**产生 `.unconfirmed` 的取消回执，也不得声称 `.drained`——那个进程组已不属于 ArkDeck（design 6.3.1） | 契约测试 + 真机 run 记录 |

### Controller restart durability addendum（2026-08-23）

| 场景 | 必须结果 | 自动化证据 |
|---|---|---|
| `startExecution` 已返回、permit-capable call 尚未进入 | job-owned ArkForge sidecar 中的 correlation 与 ArkDeck step intent 均已 durable；否则调用不可进入 | `testRestartReconcilesTheExactDaemonTerminalWithoutStartingOrUsingActorCache` 在 `performPrepared` 入口读取 sidecar + journal |
| ArkDeck 进程丢失 daemon terminal | 新进程观察 correlation 中的 exact daemon job；`prepareExecution/startExecution` 次数为 0 | 同上，fresh lane host + `prepareCount == 0` |
| terminal receipt 已有、lane actor cache 丢失 | receipt 先持久化，再补原 intent 的 typed outcome；后续 catalog projection 只读 durable receipt | 同上，最终 complete-overwrite typed outcomes 全部成立 |
| 恢复观察 | 不 start、不签 permit、不提交 control receipt、不 cancel | `testPassiveTerminalObservationCannotAnswerOrMutateTheJob` |
| ArkDeck 与 arkforged 都重启 | daemon 从 `SemanticReceiptRecorded` 重放原 canonical receipt/cursor 后报告 immutable terminal；controller 消费完整 poll，后来的 `succeeded`/`confirmedFailed` 覆盖较早 `outcomeUnknown`，且不产生任何 mutation call | ArkForge `a_job_dispatches_every_step_and_reaches_a_verdict_on_each`（reopen receipt/digest/facts）；ArkDeck `testPassiveObservationConsumesReconciledTerminalAndRestartedReceipt` |

## 不在本次验收内

- 多设备并发（本环境单板）
- eligible complete-overwrite recovery（另需 recovery contract，本 change 不含）
- 掉电耐久性：`arkforged` 的 fsync 只证明到进程死亡为止；macOS `fsync(2)` 不冲刷
  盘内缓存，而 `F_FULLFSYNC` 需要 libc，ArkForge AFD-0001 不允许。记为已知边界
  （ArkForge AD-017），不记为已通过的门。

## 已知会被此次验收破坏的东西

DAYU200 的 userdata 会被覆盖。这是 `flash.dayu200` 的既有语义
（ArkForge `profiles/dayu200.yaml` 的 `dataImpact.userdata: overwritten`），
不是本 change 引入的。执行前需操作者明确确认。
