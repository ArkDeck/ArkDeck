# TASK-RH-001 恢复演练 attempt #4 — 2026-07-21 14:17 — BLOCKED at W2(crib bug + gpt 子集拒绝)

- Change:CHG-2026-016-dayu200-recovery-rehearsal@r4 / Task:TASK-RH-001
- 执行:2026-07-21 14:17–14:19 CST,维护者 lvye(fuhanfeng)本人;host macOS 26.5.2
  arm64;物理 DAYU200 + USB。Agent 零设备命令。
- Evidence class:realHardware **blocked-attempt record**(先例 #104/#173/#213/#215)。
- Final status:**BLOCKED at W2**。零字节写入;§5 两次失败中止正确执行。**本 attempt
  的 blocker 一半是 crib 脚本缺陷(非设备),W3 wlx 决定性测试因此仍未跑到**。
- 附:脱敏 transcript `transcript-2026-07-21-attempt4.txt`(SHA-256
  `66568fedf30c627faf85f016d2172319366922b7e200884d7fa1f9e993ad9478`)。

## crib 脚本缺陷(如实披露,已修复,非设备行为)

r4 crib 首版(`rehearse-r4.sh`)的 W2 条件比对写成
`printf '%s\n' "$LAST_OUT" | python3 - <<'PYEOF'`——`python3 -` 的 stdin 被 heredoc
(python 脚本源)抢占,管道里的 `ppt` 数据被丢弃,`for ln in sys.stdin` 读到空,
`rows=0`。故 15/15 比对**永远 mismatch**,W2 条件跳过被误判为失败、误入「必须执行
gpt」分支。**人工核对 transcript 里的写前 `ppt` 表,实为与 FA-001 §2 逐行 15/15 精确
match**(与 attempt#2/#3 逐字节相同,连续第四次一致)——W2 判定点本应满足、gpt 本应
跳过、流程本应直入 W3。

修复:比对改走 argv 文件路径(`python3 - "$RUN_DIR/ppt-before.txt"` + `open(sys.argv[1])`,
与身份门物料校验同法),用真实 attempt#4 ppt 输出端到端自测得 `PPT-MATCH 15/15`/exit 0。
修复版脚本 SHA-256 前缀 `a1a7a55c…`。缺陷纯属 crib 实现层,design r4 逻辑正确不受影响,
命令面零变动。

## 设备侧事实(有效)

- 身份门(工具 `038a8a0e…`/`ver 1.32`、物料 17/17、FA-001)PASS;
- 进态序列**第四次稳定**:pre-entry `0x5000 Maskrom` → 序列后 `0x350a Loader`(两次
  `ld` 稳定);
- **r4 W1 条件跳过生效**(`JUDGE[W1]=SKIPPED-SATISFIED`);
- 写前 `ppt` **第四次**读出同一张 GPT 表(与 attempt#2/#3 逐字节一致);
- W2 `gpt` **第二次**两次均被 `The device does not support this operation!` 拒绝——
  与 attempt#2 `db`、attempt#3 `gpt` **同一输出族**。累计:写类 `db`×2、`gpt`×4 全部
  被板上 U-Boot rockusb gadget 拒绝;读类 `ld`/`ppt` 始终完好。

## 四 Test ID disposition(本 attempt)

| Test ID | 结论 |
| --- | --- |
| RH-DAYU200-RECOVERY-001 | blocked-attempt #4:因 crib W2 比对 bug 误入 gpt(第二次被子集拒绝),**W3 wlx 仍未测到**;crib 已修,下窗口重跑 r4(修正版)直入 W3 |
| RH-DAYU200-MODE-001 | 进态第四次稳定(0x350a Loader);无新信息 |
| RH-DAYU200-TABLE-001 | 写前读回第四次达成且逐字节一致(表跨四窗口稳定);写后读回待写入窗口 |
| RH-DAYU200-SAFETY-001 | PASS(本窗口):全部命令属封闭面、pinned hash 复核、零手算、零写入、§5 正确中止、序列号零入仓 |

## 下一步(不改 design;只修 crib)

design r4 逻辑正确(W2 条件化),本 blocker 主因是 crib 实现缺陷,已修复自测通过——
**无需新 revision**。下窗口跑修正版 `rehearse-r4.sh`:W1/W2 条件跳过(ppt 15/15 将正确
命中)→ 直入 **W3 `wlx uboot` 命令子集探针**。该探针仍是唯一决定性未知:`wlx uboot`
成功 → 真实恢复达成、RECOVERY gap 关闭;`wlx`+`wl` 均被同族拒绝 → Loader 态恢复路线
不可行、须另立 revision 探 BootROM 真 Maskrom 进态。本记录不翻转任何状态,不构成
conformance/hardware/support/release claim。
