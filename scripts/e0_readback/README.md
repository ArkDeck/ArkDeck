# E0 readback crib (CHG-2026-025 / TASK-AIN-004)

只读身份/模式读回,用于 finalize standing authorization
`AUTH-2026-025-DAYU200-001`(见 change 的 `evidence/authorizations/`)。它确认接在
host 上的物理设备**就是**被授权的 DAYU200(serial 摘要 == 载体 pin),并记录 USB
模式。它是 AIN-004 readiness r1 里描述的"一次 E0 只读读回"的具体工具。

**这不是 flash,也不改任何设备状态。** 唯一的 device-state 变化(E2 刷机)不在本
脚本内。属执行分级 E0(本 change 生效后 agent 可无人值守;亦可维护者一行执行)。

## 命令面(封闭只读 allowlist)

`hdc -v` / `hdc checkserver` / `hdc list targets` / `hdc list targets -v`,外加一次
只读 host USB 枚举(`system_profiler SPUSBDataType -json`)。argv 全为定长数组,无
shell 拼接,无 operator 组合命令(m0b_capture 同型安全属性)。

## 用法

```bash
# 交付前 host 自测(无设备,验证纯逻辑/argv/摘要比对/退出码/脱敏门):
python3 scripts/e0_readback/capture.py --selftest-host

# 设备窗口(DAYU200 接入,normal hdc 模式 0x2207:0x0018):
python3 scripts/e0_readback/capture.py \
  --hdc ~/dayu200-rehearsal/... /hdc \
  --out-dir ~/e0-readback/run-1        # 必须在任何 git 仓库之外
```

- **退出码**:`0` = 读回成功且 serial 摘要命中被授权目标;`1` = 读回成功但设备不是
  被授权目标(serial 摘要不符/无 hdc serial)或敏感内容自检失败(fail closed);
  `2` = 用法/harness 错误(out-dir 在仓内、hdc 不可执行、输出文件已存在、脱敏门失败)。
- 原始含序列号字节只落 `--out-dir`(仓库外,脚本会拒绝仓内路径);仓库安全的
  `redacted-summary.json` 只含 SHA-256 摘要、match 布尔与 USB 模式,并经输出侧脱敏门
  复扫后才写出。

## Binding revision(为何本脚本不读它)

standing authorization 的 `target.bindingRevision` **没有 host 读取路径**——
`arkdeck` CLI 与 hdc 都不暴露它;它是 ArkDeck durable 设备绑定 journal 的状态
(`CurrentDeviceBinding.revision`,Core `DeviceBindingHistory`)。本读回**只**确认
身份(serial 摘要 + USB 模式),不读也不臆造 revision。

r2 finalize 时按此确定 `bindingRevision`:

- 该 DAYU200 无持久化 durable 绑定时,首次 durable 绑定 = **revision 1**(Core 不变量
  `initialBinding.revision == 1`);若 ArkDeck 已持有该设备的持久绑定,则取其 current
  revision;
- 执行期在 `--unattended-context` 里提供**同一个**值;两者一旦不一致,执行门 fail
  closed(`RockchipStandingAuthorizationValidator`)。

## r2 finalize 流程(读回成功后)

1. 本脚本 exit 0(serial 摘要命中)→ 确认是被授权设备;
2. 按上节确定 `bindingRevision`;
3. readiness r2:把载体 `AUTH-2026-025-DAYU200-001.json` 的 `bindingRevision` 从 `-1`
   改为该值、`carrier` 从 PENDING 改为 r2 PR 引用、AIN-004 翻 `ready`;
4. 维护者 merge r2 = 批准精确目标。此后 AIN-004 无人值守 E0 采集 + E2 刷机方可对该
   载体生效。

读回后执行门运行时仍会用 `RockchipDeviceIdentityReadback` 再次校验 serial 摘要与 USB
身份;序列号原始字节永不入仓。

## 测试

```bash
python3 -m unittest scripts/e0_readback/test_capture.py -v   # 26 tests,无需设备
```
