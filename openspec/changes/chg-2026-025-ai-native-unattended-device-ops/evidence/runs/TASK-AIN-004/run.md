# TASK-AIN-004 run — E0 身份读回(r2 finalize 依据)

- Date:2026-07-22
- Executor:human operator `lvye`(设备窗口,E0 只读;crib = `scripts/e0_readback/capture.py`)
- Device:DAYU200(RK3568),normal hdc 模式;host macOS 26.5.2 arm64。
- Toolchain:hdc `48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260`
  (钉住值命中)。

## 命令与结果

```
python3 scripts/e0_readback/capture.py \
  --hdc /Applications/DevEco-Studio.app/.../hdc \
  --out-dir ~/e0-readback/run-1
→ E0 readback complete. serial digest match vs pinned target: True (1 token)
→ exit 0
```

四条只读 hdc 命令(`-v`/`checkserver`/`list targets`/`list targets -v`)全 exit 0、
无 timeout。仓库安全摘要见同目录 `e0-readback-redacted-summary.json`(只含 SHA-256
摘要与 match 布尔;原始含序列号 stdout 留 `~/e0-readback/run-1/`,仓库外)。

## 判定

- **身份确认:PASS**——`serialVerdict.matched = true`,observed digest
  `958780b2…7a7e` == pinned digest(AUTH-2026-025-DAYU200-001)。接入设备即被授权的
  那台物理 DAYU200。
- `sensitiveSelfCheckPassed = true`(discovery 输出无用户路径)。

## 偏差(如实记录)

- `usbIdentities = []`:`system_profiler SPUSBDataType -json` 本次未枚举到 0x2207
  设备(normal hdc 模式下设备被 hdc 守护占用是常见现象)。**身份确认完全依据 hdc
  serial 摘要命中**(设备唯一标识,足够强);USB 模式那一路为补充信息、本次为空,
  不构成阻断。E2 执行在 Loader 态(0x2207:0x350a),届时由 rkdeveloptool 直接枚举
  USB,与本 crib 的 system_profiler 路径无关。

## bindingRevision 决定(r2 pin = 1)

`target.bindingRevision` 无 host 读取路径,本读回未读也未创建任何 durable 绑定
(仅只读 hdc discovery)。按 Core `DeviceBindingHistory` 不变量,首次 durable 绑定
= **revision 1**;仓内无该 DAYU200 的持久绑定 journal(M0B/RF 未持久化跨 change 的
绑定)。故 r2 pin `bindingRevision = 1`。

**执行期一致性要求**:AIN-004 E2 执行时,harness durably 绑定设备得到 revision R,
须在 `--unattended-context` 提供 R;门 `RockchipStandingAuthorizationValidator` 要求
R == 载体 pin(1),不符即 fail closed。因此执行须在设备首次绑定(R=1)、且任何
rebind 递增之前进行。

## r2 载体最终化

`AUTH-2026-025-DAYU200-001.json`:`bindingRevision` -1 → 1;`carrier` PENDING → r2
PR 引用。`carrier` 字段格式偏差(如实记录):r1 README 曾写 `@<blob-oid>`,但载体
无法自引用自身 blob-oid(逻辑不可能),故 provenance 以"r2 merge commit(git 历史)"
承载,carrier 字段记 PR 号 + 说明。其余 host pin 于合入版 f15c3a8 复核无漂移。
