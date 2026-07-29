# TASK-BER-001 设备窗口计划(BER-HW-001 / BER-HW-002)

> **本文件不是授权载体。** 窗口安排属 D2 决策,由维护者裁定;本文件只
> 提供窗口内要执行的确切步骤与判据,便于一次窗口拿全两条 AC 的证据。
> Agent 零设备命令:以下命令**全部由维护者亲手执行**并把输出贴回
> transcript,Agent 负责核验与起草 evidence PR。

## 前置(窗口前确认,任一不满足即不开窗)

1. main 已含 TASK-BER-001 实现 PR 的合并 commit(记 OID)。
2. 本机已构建:`swift build --product arkdeck-agentd --product arkdeck`
   (在 `Packages/ArkDeckKit`),记两个二进制的 SHA-256。
3. 已知 HDC 绝对路径与其 SHA-256(维护者 2026-07-28 实测值
   `05b2bf7a…f83`,版本 `Ver: 3.2.0f`;若漂移则先记录新值,勿硬套)。
4. DAYU200 已连接、已在设备端完成一次调试信任(或准备在窗口内完成)。
5. 状态目录使用**窗口专用且短**的路径(勿污染日常):
   `~/adw-$(date +%m%d)`。**必须短**:Unix socket 路径上限 104 字节,
   socket = `<state-dir>/agentd.sock`;超限时 daemon 会明确报出实际
   字节数与上限并拒绝启动(自测已实证)。

## Host 侧自测已覆盖(窗口内不必再验)

2026-07-29 在无设备条件下实测:daemon 启动/存活/`doctor`/`device list`
均正常;未配置 `ARKDECK_HDC_PATH` 时 `device adopt` 明确拒绝且消息可
操作;socket 超长路径拒绝并给出字节数与修法。两处缺陷(async top level
下 `dispatchMain()` 杀死 daemon、socket 超长仅报 "too long")已在实现
PR 内修复并各配回归测试(含正负对照变异)。**窗口只需验证真设备面。**

## 步骤

所有命令在仓库根执行;`$BIN` = `Packages/ArkDeckKit/.build/debug`。

```bash
export ARKDECK_WINDOW_STATE="$HOME/adw-$(date +%m%d)"
export ARKDECK_HDC_PATH="<HDC 绝对路径>"
mkdir -p "$ARKDECK_WINDOW_STATE"
shasum -a 256 "$ARKDECK_HDC_PATH"
"$ARKDECK_HDC_PATH" -v
```

**S1 启动 daemon**(独占一个终端窗口,保持前台):

```bash
ARKDECK_HDC_PATH="$ARKDECK_HDC_PATH" "$BIN/arkdeck-agentd" --state-dir "$ARKDECK_WINDOW_STATE"
```

预期:打印 `arkdeck-agentd listening on <state>/agentd.sock` 并**保持
运行**(host 自测已实证该形态:打印后即退出属已修缺陷,若再次出现请如实
记录)。`ARKDECK_HDC_PATH` 未设时 daemon 仍会启动,但 adopt 会明确拒绝
(fail-closed),不会静默降级。

**S2 doctor**(第二个终端):

```bash
"$BIN/arkdeck" doctor --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
```

预期:`providers` 含 `hdc`;`targetStore`/`bootstrap` 为 `ready`;
`catalogDigest` 与仓内 `Catalog/generated/effect-authorization-matrix.md`
首行 digest 一致。

**S3 adopt**:

```bash
"$BIN/arkdeck" device adopt --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
```

预期分支(如实记录实际走到哪一支):
- `outcome=adopted` + `targetId`:直接进 S4;
- `outcome=waitingForHuman`:按提示在**设备屏幕**上确认调试信任,再重跑
  同一条命令(应转为 adopted);
- `outcome=needsSelection`:记录候选列表,追加
  `--candidate <connect-key>` 重跑。

```bash
"$BIN/arkdeck" device list --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
```

**S4 observe.device@1 端到端**:

```bash
"$BIN/arkdeck" job submit --socket "$ARKDECK_WINDOW_STATE/agentd.sock" \
  --target "<S3 的 targetId>" --operation "observe.device@1" --wait --json
```

预期:`state=succeeded`、`outcomeUnknown=false`,timeline 含
`intent probe-host-tool` / `verified probe-device` / `finalizing->succeeded`。
**这就是 BER-HW-001。**

**S5 重启恢复(BER-HW-002 上半)**:S1 终端 `Ctrl-C` 停 daemon,重启同
命令,然后:

```bash
"$BIN/arkdeck" job status --socket "$ARKDECK_WINDOW_STATE/agentd.sock" \
  --job "<S4 的 jobId>" --json
"$BIN/arkdeck" job list --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
```

预期:历史 job 仍可查、状态不变。

**S6 拔插重绑(BER-HW-002 下半)**:物理拔下 USB → 重插 → 重跑 S3 的
adopt:

```bash
"$BIN/arkdeck" device adopt --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
"$BIN/arkdeck" device list --socket "$ARKDECK_WINDOW_STATE/agentd.sock" --json
```

预期:**同一 targetId**(幂等,凭稳定身份识别),不新建 target;若返回
新 targetId 或 needsSelection,如实记录——那是要修的缺陷,不是可接受
偏差。

## 贴回时的脱敏纪律

- `connectKey`/序列号:贴回时替换为 `<32-hex-key>` 占位或前 4 后 4;
- 家目录路径:替换为 `<HOME>`;HDC 路径替换为 `<TOOL>`;
- 只贴命令与 JSON 输出,不贴设备原始日志。

## 判据(Agent 核验用)

| AC | 通过条件 | 失败即 |
| --- | --- | --- |
| BER-HW-001 | S4 一次提交得到 succeeded + 完整 timeline;S3 除设备侧信任外零人工命令 | 记 blocked-attempt,分析后修实现,不改判据 |
| BER-HW-002 | S5 历史可查且状态不变;S6 返回同一 targetId | 同上 |

任一步骤报错:**停下**,原样贴回错误文本;不重试、不换参数绕过。
