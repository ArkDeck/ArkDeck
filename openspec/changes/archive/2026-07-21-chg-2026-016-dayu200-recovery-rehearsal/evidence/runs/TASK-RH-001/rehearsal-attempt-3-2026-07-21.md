# TASK-RH-001 恢复演练 attempt #3 — 2026-07-21 — BLOCKED at W2(loader 命令子集)

- Change:CHG-2026-016-dayu200-recovery-rehearsal@r3 / Task:TASK-RH-001
- 执行:2026-07-21 12:57–13:00 CST,维护者 lvye(fuhanfeng)本人;host macOS 26.5.2
  arm64;物理 DAYU200 + USB。Agent 零设备命令(r3 crib 起草 + 事后核验 + 本记录)。
- Evidence class:realHardware **blocked-attempt record**(先例 #104/#173/#213)。
- Final status:**BLOCKED at W2**。零字节写入;§5 两次失败中止规则由 r3 crib **正确
  自动执行**(r2 展示层缺陷的修复就此在真机路径验证)。
- 附:脱敏 transcript `transcript-2026-07-21-attempt3.txt`(SHA-256
  `1177533db0a0c1659d3be6b40707128733dbf47bf371165cfc8ef25ac6d0aa77`;home-mask,
  无序列号)。

## 本 attempt 验证成立的部分(全部一次通过)

- 身份门(工具 `038a8a0e…`/`ver 1.32`、物料 17/17、FA-001 在位)PASS;
- §0 进态序列第三次稳定复现:pre-entry `0x5000 Maskrom` → 序列后
  `0x2207:0x350a Loader`(两次 `ld` 稳定)——进态路径可靠性进一步坐实;
- **r3 W1 条件化按设计首次生效**:`ld`=`0x350a`+`Loader` → `db` 跳过,
  `JUDGE[W1]=SKIPPED-SATISFIED` 落账,无 attempt#2 的两次无效 `db`;
- 写前 `ppt` 第二次读出 GPT 表,**再次 15/15 精确 match FA-001 §2**——设备分区表
  跨窗口稳定,且正是 `parameter.txt` 所编码的同一张表。

## BLOCKED 事实与解读:Loader 态 `gpt` 与 `db` 同族被拒

`gpt parameter.txt` 两次(12:58:50 / 12:58:57)均返回
`The device does not support this operation!`(exit 1),与 attempt#2 的 `db` 拒绝
**同一输出族**。解读:进态所至的板上 U-Boot rockusb gadget 只实现命令子集——
`db`(Maskrom 专用)与 `gpt`(分区表写)均不在其支持面;而读路径(`ld`/`ppt`)
完好。这不是通信故障(#173 类)也不是物料问题(hash 全 MATCH)。

**关键结构事实**:W2 的判定点是「设备侧分区表就位;为 W3 `wlx` 建立解析前提」——
写前 `ppt` 15/15 精确 match 证明该前提**已被设备现存表满足**(W2 要写入的正是这张
表)。与 r3 W1 完全同构的 satisfied-by-existing-state 形态;r3 命令面无「W2 条件
跳过」授权,操作者按 §5 正确中止。

## 四 Test ID disposition(本 attempt)

| Test ID | 结论 |
| --- | --- |
| RH-DAYU200-RECOVERY-001 | blocked-attempt #3:W1 条件跳过生效,W2 `gpt` 按 loader 命令子集被拒(零写入);待 design r4(W2 条件化)后重约窗口,直入 W3 |
| RH-DAYU200-MODE-001 | 复核加固:0x350a Loader 第三窗口稳定;`0x5000 Maskrom` pre-entry 标签形态再次在案 |
| RH-DAYU200-TABLE-001 | 写前读回第二次达成且与 attempt#2 逐字节一致(表稳定);写后读回待写入窗口 |
| RH-DAYU200-SAFETY-001 | PASS(本窗口):全部命令属封闭面、pinned hash 复核、零手算、零写入、§5 自动中止正确执行、序列号零入仓 |

## 遗留与下一步

blocker = r3 命令面缺「W2 条件跳过」。修复走 design r4:写前 `ppt` 与 FA-001 §2
逐行 15/15 精确 match 时,W2 判定点视为已满足、`gpt` 跳过并如实记录;不 match 时
`gpt` 仍必须执行(被拒则 §5 停,另议 Maskrom 裸态路径)。**已知风险如实登记**:
W3 `wlx`/`wl` 可能同样落在 loader 命令子集之外——若下窗口两者均被拒,则本恢复
路线在 Loader 态不可行,须另立 revision 探索真 Maskrom(BootROM)进态。本记录不
翻转任何状态,不构成 conformance/hardware/support/release claim。
