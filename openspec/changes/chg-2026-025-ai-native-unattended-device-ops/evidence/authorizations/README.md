# Standing authorizations (CHG-2026-025)

维护者经 merged PR 批准的 E2(destructive)执行授权载体。每个 `AUTH-*.json` 是
`RockchipStandingAuthorization`(schema 1.0.0,`StandingAuthorization.swift` 解析)的
持久形态;执行门在首个真实设备 Step 前对其逐项校验并 fail closed(REQ-FLASH-015,
AC-FLASH-015-01/02/03)。

**批准语义**:授权由维护者 merge 承载它的 PR 构成;Agent 可起草,不得自批
(POL-AGENT-001)。任何 pinned 字段漂移即整体失效,须新 readiness PR 重新授权。
吊销 = 维护者 merge 删除/作废该文件的 PR;git 历史即授权审计账本。

> **载体路径是契约,不是约定**:`MaintainerMergedAuthorizationResolver` 只从
> `registryPath = openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/authorizations/<authorizationId>.json`
> 读取,故**文件名必须与 `authorizationId` 逐字一致**。批准由 GitHub provenance 建立
> (作者 `github-actions[bot]`、`lvye` 对 exact head approve、`lvye` merge、三方 actor
> 分离、`.github/CODEOWNERS` blob OID 命中),`approvedBy`/`carrier` 只是显示与交叉核对
> 字段,**单凭它们不构成批准**。

## AUTH-2026-025-DAYU200-002(TASK-AIN-004 r3,当前载体,fail-closed)

2026-07-27 由 readiness r3 引入,**取代 `-001`**(后者随 r2 security-remediation 作废,
按 POL-AGENT-001 原样保留为历史,不修改、不复用)。host 侧字段已于 base
`6e45a224cc7d5a758fe2f5661effe3c2ae726baf` 全部重新实测(非沿用 r1 值),实测结果与 r1
逐字相同:

| 字段 | 值 | 本次取证 |
| --- | --- | --- |
| `target.model` | DAYU200 (RK3568) | `RockchipFlashProfile.targetDeviceModel` 实测 |
| `target.serialSHA256` | `958780b2…7a7e` | 同一物理设备(EVD-M0B-DAYU200-20260718-001);原始字节不入仓 |
| `firmwareArchiveSHA256` | `fc7637f3…5280` | 本机 pinned 归档实测命中 |
| `toolchainFingerprint` | rkdeveloptool-1.32@`038a8a0e…3611` | `~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool` 实测命中 |
| `providerIdentity` | arkdeck.rockchip-rockusb-flash-provider | Provider 常量实测 |
| `planDigestSHA256` | `c85be3b3…6cff` | base 树 `makePlan(mode:.execute,.valid)` 实测 |
| `stepSetDigestSHA256` | `075b52c4…8fdb` | 同上 |
| `transport` / `maxRuns` / `validUntil` | usb / 1 / 2026-08-31T00:00:00Z | — |

**`target.bindingRevision` = `-1`,`carrier` = PENDING:本载体现在授权为零。**
`RockchipStandingAuthorization.parse` 对负值以
`negativeValue(field: "target.bindingRevision")` 直接拒绝,故它在解析层即不可授权任何
dispatch——这是有意的 fail-closed 状态,与 r1 同型。

### 完成路径(r4)

与 r1→r2 不同,`bindingRevision` **不再**由 caller 在 `--unattended-context` 里提供:
AIN-005/006/007 之后,执行门要求 durable binding snapshot
(`~/Library/Application Support/ArkDeck/rockchip-binding.json`)的 `revision`
与本载体 `target.bindingRevision` 逐字相等。因此 r4 的前置是**先建立 durable 绑定**,
再据其 revision 定本 pin,而不是靠一次 E0 读回臆造。

r4 另需三项(见 tasks.md「Readiness pins(r3)」D-1/D-2/D-3):产品执行宿主四项前置
可证、ADR-0003 范围裁决、hdc 身份重钉。三项任一未闭合即不得 r4。

## AUTH-2026-025-DAYU200-001(TASK-AIN-004,首次无人值守真机验收;**superseded**)

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
