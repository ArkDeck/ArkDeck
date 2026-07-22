# Standing authorizations (CHG-2026-025)

维护者经 merged PR 批准的 E2(destructive)执行授权载体。每个 `AUTH-*.json` 是
`RockchipStandingAuthorization`(schema 1.0.0,`StandingAuthorization.swift` 解析)的
持久形态;执行门在首个真实设备 Step 前对其逐项校验并 fail closed(REQ-FLASH-015,
AC-FLASH-015-01/02/03)。

**批准语义**:授权由维护者 merge 承载它的 PR 构成;Agent 可起草,不得自批
(POL-AGENT-001)。任何 pinned 字段漂移即整体失效,须新 readiness PR 重新授权。
吊销 = 维护者 merge 删除/作废该文件的 PR;git 历史即授权审计账本。

## AUTH-2026-025-DAYU200-001(TASK-AIN-004,首次无人值守真机验收)

host 侧字段已于 base `0a5c9fd9…2215f` 实测锁定(见 tasks.md AIN-004 Readiness
pins):

| 字段 | 值 | 来源 |
| --- | --- | --- |
| `target.model` | DAYU200 (RK3568) | `RockchipFlashProfile.targetDeviceModel` |
| `target.serialSHA256` | `958780b2…7a7e` | SHA-256 of DAYU200 serial recorded in-repo by EVD-M0B-DAYU200-20260718-001(同一物理设备;原始字节不复制入本文件) |
| `firmwareArchiveSHA256` | `fc7637f3…5280` | pinned 参考镜像 7.0.0.33(CHG-2026-003) |
| `toolchainFingerprint` | rkdeveloptool-1.32@`038a8a0e…3611` | RF-002 pinned toolchain |
| `providerIdentity` | arkdeck.rockchip-rockusb-flash-provider | Provider 常量 |
| `planDigestSHA256` | `c85be3b3…6cff` | 合入版 `makePlan(mode:.execute,.valid)` 实测(与 RF-002 transcript 逐字一致) |
| `stepSetDigestSHA256` | `075b52c4…8fdb` | 同上 |
| `transport` | usb | — |
| `maxRuns` | 1 | 单次授权刷机 |
| `validUntil` | 2026-08-31T00:00:00Z | 授权有效期上限 |

**`target.bindingRevision` = `-1`(fail-closed 占位)**:这是唯一需要一次设备读回
才能确定的 pin。`-1` 使 `RockchipStandingAuthorization.parse` 直接以
`negativeValue(field: "target.bindingRevision")` 拒绝——因此本 r1 载体**在解析层即
不可授权任何 dispatch**,是有意的 fail-closed 状态。

### 完成路径(r2,一次设备读回)

在具名设备窗口对目标 DAYU200 执行**一次 E0 只读身份/binding 读回**(本 change 生效后
E0 属 agent 可无人值守执行;亦可由维护者一行执行),取:

- 当前 durable binding revision;
- 设备 serial(复核其 SHA-256 == `958780b2…7a7e`,确认仍是同一物理设备);
- USB vid:pid(应为 `0x2207:0x350a` Loader 态)。

然后 readiness r2:把 `bindingRevision` 从 `-1` 改为读回值、把 `carrier` 从 PENDING
改为该 r2 PR 的 `PR #<n> <path>@<blob-oid>`,并将 tasks.md AIN-004 翻 `ready`。
维护者 merge r2 = 批准精确目标。此后 AIN-004 无人值守执行方可对该载体生效。

读回后执行门仍会用运行时 `RockchipDeviceIdentityReadback` 再次校验 serial 摘要与
USB 身份;序列号原始字节永不入本文件(只入 SHA-256 摘要)。
