# TASK-BER-001 设备窗口 attempt#2(2026-07-29)— BER-HW-001 / BER-HW-002 PASS

- Operator:维护者(lvye)亲手执行;Agent 零设备命令、零 destructive dispatch
- Evidence class:**realHardware**
- Baseline:main `909db12`(#783 修复合入后)
- Binaries(该 main 构建):`arkdeck-agentd` `13d63844…`、`arkdeck` `ef6f9f79…`

## 环境事实

| 项 | 值 |
| --- | --- |
| Device | DAYU200 (RK3568),USB,`Connected` |
| Connect key | `1501…4900`(脱敏;完整字节不入仓) |
| Durable target | `TGT-958780b2ffb7`(稳定物理身份 SHA-256 前 12 位) |
| HDC | `Ver: 3.2.0f`,SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`(与仓内 pin 零漂移) |
| HDC 路径 | `<DEVECO_SDK>/default/openharmony/toolchains/hdc` |
| State dir | `<HOME>/adw`(沿用 attempt#1 目录,故含其遗留 unknown job——见下方对照证据) |

## 逐步结果

**S1 daemon 启动**:`recovered 1 persisted job(s); unknown outcomes parked`
+ `listening on <HOME>/adw/agentd.sock`。恢复逻辑在真机状态目录上生效。

**S2 doctor**:`providers: ["hdc"]`、`bootstrap: ready`、`targetStore: ready`、
`adoptedTargetCount: 1`、`catalogDigest: 9af00b6f…`(与仓内生成矩阵一致)。

**S3 adopt**:`outcome: adopted`、`targetId: TGT-958780b2ffb7`、
`bindingRevision: 1`。**幂等成立**:返回 attempt#1 建立的同一 target,
未新建。

**S4 `observe.device@1`(BER-HW-001)**:`state: succeeded`、
`outcomeUnknown: false`、`waitingForHuman: false`。完整 timeline:

```
jobCreated
queued->preflight
preflight->running
intent probe-host-tool
verified probe-host-tool ["toolVersion"]
intent probe-hdc-server
verified probe-hdc-server ["clientVersion", "serverVersion"]   ← #783 修复点
intent probe-device
verified probe-device ["connectKeys", "targetCount"]
host-step finalize-session
running->finalizing
finalizing->succeeded
```

每个设备步骤都是 **intent 先于 dispatch、verify 后于 receipt** 的完整
三段式;`probe-hdc-server` 现由专用 checkserver 语义解析器判定并同时
读出 client/server 两侧版本。除首次设备侧信任(attempt#1 已完成)外
**零人工命令**。

**S5 daemon 重启恢复(BER-HW-002 上半)**:重启后 `job list` 返回两条,
状态与重启前逐字一致:

- 本次 job:`succeeded`,新增 `recovered: journal clean`;
- attempt#1 遗留 job:仍 `waitingForRecovery` / `outcomeUnknown: true`,
  timeline 累积**第三条** `recovered: outstanding intents or unknown
  outcomes; no redispatch`。

> **对照证据(意外之喜)**:这条 unknown job 已跨 **3 次 daemon 重启**
> 从未被重发,也从未被自动改判为成功——"outcomeUnknown 不自动重试"
> 在真机状态上得到了跨重启的持续验证,比一次性断言更强。

**S6 拔插重绑(BER-HW-002 下半)**:物理拔出 → 重插 → `device adopt`
返回**同一** `TGT-958780b2ffb7`;`device list` 仍只有一条,
`adoptedAtUtc` 保持 `2026-07-29T07:01:51Z`(attempt#1 的原始时间)。
**跨物理断连、跨进程重启、跨窗口的身份幂等成立**,未凭"新出现的第一个
USB 设备"误绑。

**收尾**:两次 `pkill`(SIGTERM)shell 均报 `done`,不再出现 attempt#1
的 `trace trap`;#783 的干净退出修复在真机路径上确认。

## AC 判定

| AC | 判定 | 依据 |
| --- | --- | --- |
| `BER-HW-001` | **PASS** | S3+S4:一次 adopt + 一次 observe 端到端 succeeded,完整 job timeline,除设备侧首次信任外零人工命令 |
| `BER-HW-002` | **PASS** | S5:重启后历史与状态逐字保持、unknown job 零重发;S6:拔插后同一 targetId、零重复 target |

## 与 attempt#1 的关系

attempt#1(`window-attempt-1.md`)如实记为 blocked-attempt,其暴露的两个
缺陷由 #783 修复(checkserver 语义解析器、daemon 干净退出),判据一字
未改。本次在修复后的 main 上复跑同一套步骤全部通过。

## 安全核对

- Agent 零设备命令:全部步骤由维护者亲手执行并贴回 transcript;
- 零 destructive dispatch:本 change 全部动作 effect ≤ readOnly;
- 序列号/connect key 完整字节不入仓;raw 产物留 daemon 私有状态目录;
- runtime 请求零 `changeId`/`taskId`(CLI 构造面不存在该字段)。
