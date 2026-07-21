# TASK-RH-001 恢复演练 attempt #2 — 2026-07-21 — BLOCKED(W1 mode-appropriate)

- Change:CHG-2026-016-dayu200-recovery-rehearsal@r2 / Task:TASK-RH-001
- 执行:2026-07-21 11:09–11:20 CST,维护者 lvye(fuhanfeng)本人;host macOS 26.5.2
  arm64;物理 DAYU200 + USB。Agent 零设备命令(r2 crib 脚本起草 + 事后核验 + 本记录
  起草,M0B/PD-002/#173 先例)。
- Evidence class:realHardware **blocked-attempt record**(先例 #104/#173;非三项
  realHardware AC 的 passing evidence,但含两项决定性只读产出,见下)。
- Final status:**BLOCKED at W1**,且为 **mode-appropriate rejection**:设备零字节写入,
  全程停留在功能完好的 Loader 态;§5 两次失败中止规则正确执行。
- 附:脱敏 transcript `transcript-2026-07-21.txt`(SHA-256
  `fd128ce72011e8cef56c5106d0edbc3a6ae8f60ee7953c268fa63ac64ffde76f`;用户路径
  home-mask,无设备序列号,唯一 64-hex 为工具 pinned hash)。

## Preflight(全部通过)

- 工具:`rkdeveloptool` SHA-256 `038a8a0e…3611`(pinned 一致)、`-v` = `ver 1.32`;
- 物料:17/17 成员 SHA-256 vs archived member-inventory.json = 17 MATCH / 0 FAIL;
- FA-001 §2 基线在位。

## 核心产出 ①:r2 进态序列真机验证成功(#173 根因关闭)

pre-entry `ld` = `Vid=0x2207,Pid=0x5000 … Maskrom`(工具对 0x5000 的标签;#173 已证
该态 rkdeveloptool 无法建 comm)。执行 r2 §0 精确按键序列(hold VOL/RECOVERY →
press/release RESET → 继续按住 2-3s)后:

```
DevNo=1  Vid=0x2207,Pid=0x350a,LocationID=2  Loader
```

**首次达成 0x350a(RockUSB)**,mode-gate PASS;且状态标签为 **Loader**(非裸
Maskrom)——设备经该序列直接进入板上 miniloader 运行态。该观察在窗口内三次 `ld`
(mode-gate/OB/抢救)间稳定不变。MODE-001 的 r1 缺口(0x350a 是否可达)就此补全。

## BLOCKED 事实:W1 `db` 两次被拒 = Loader 态的 mode-appropriate 行为

`db MiniLoaderAll.bin` 两次(11:10:57 / 11:11:45)均返回
`The device does not support this operation!`(exit 1)。与 #173 的
`Creating Comm Object failed!` 是不同失败:本次通信正常、命令被设备侧拒绝。
解读:`db` 的用途是向 **Maskrom 裸态**注入 loader;设备已在 Loader 态(miniloader
已运行)时该操作按协议被拒。**W1 的判定点「设备转入可写态(ld 显示 Loader)」在
进态完成时即已满足**——r2 design 假设 Maskrom→db→Loader 路径,真机走的是直接进
Loader 路径。r2 命令面无「W1 条件跳过」授权,操作者按 §5 两次失败规则中止,正确。

crib 脚本缺陷如实记录:中止文案处 macOS bash 3.2 多字节变量名解析缺陷导致
`unbound variable` 退出;中止语义已达成,缺陷仅展示层,已于窗口后修复(`${var}` +
ASCII 括号),命令面零变动。

## 核心产出 ②:窗口内只读抢救——TABLE-001 写前基线 15/15 精确 match

操作者以 design §2 读类白名单命令手动执行 `ld`(稳定同上)与 `ppt`,读出设备现行
分区表(表头 `Partition Info(GPT)` = **GPT 分支实锤**,FA-001 §1 的 GPT vs parameter
待确证项落定)。逐行 vs FA-001 §2(PD-002 锚定)比对:

| NO | ppt Name | ppt LBA | FA-001 offset(PD-002) | 判定 |
| ---: | --- | --- | --- | --- |
| 00 | uboot | 00002000 | 0x00002000 | match |
| 01 | misc | 00004000 | 0x00004000 | match |
| 02 | bootctrl | 00006000 | 0x00006000 | match |
| 03 | resource | 00007000 | 0x00007000 | match |
| 04 | boot_linux | 0000A000 | 0x0000A000 | match |
| 05 | ramdisk | 0003A000 | 0x0003A000 | match |
| 06 | system | 0003C000 | 0x0003C000 | match |
| 07 | vendor | 0043C000 | 0x0043C000 | match |
| 08 | sys-prod | 0063C000 | 0x0063C000 | match |
| 09 | chip-prod | 00655000 | 0x00655000 | match |
| 10 | updater | 0066E000 | 0x0066E000 | match |
| 11 | eng_system | 0067E000 | 0x0067E000 | match |
| 12 | eng_chipset | 00686000 | 0x00686000 | match |
| 13 | chip_ckm | 0069E000 | 0x0069E000 | match |
| 14 | userdata | 01308000 | 0x01308000 | match |

**15 match / 0 mismatch / 0 absent / 0 extra**;index、name(含 `sys-prod`/
`chip-prod` 连字符形态)、offset 逐项一致。设备现行 GPT 与 PD-002 解码基线完全吻合,
Loader 读路径功能完好。原始值零改写;本比对只入 evidence,不改基线。

## 四 Test ID disposition(本 attempt)

| Test ID | 结论 |
| --- | --- |
| RH-DAYU200-RECOVERY-001 | blocked-attempt #2:进态成功,W1 被拒(mode-appropriate),W2-W4 未执行;待 design r3(W1 条件化)后重约窗口 |
| RH-DAYU200-MODE-001 | **实质补全**:0x350a RockUSB 达成且稳定,进态序列→Loader 态路径实证;0x5000 pre-entry 形态再次在案 |
| RH-DAYU200-TABLE-001 | **写前读回达成**:15/15 精确 match vs FA-001 §2(写后读回待下窗口) |
| RH-DAYU200-SAFETY-001 | PASS(本窗口):封闭面全遵守(db/ld/ppt 均在 §2 白名单)、pinned hash 复核、零手算地址、零字节写入、§5 正确中止、序列号零入仓 |

## 遗留与下一步

唯一 blocker = r2 命令面缺「设备直接进 Loader 态时 W1 跳过」的授权。修复走 design r3
revision PR(W1 条件化:写前 `ld` = `Loader` 即判定点满足、跳过并记录;`Maskrom` 才
必须 `db`),merge 后同步 crib 脚本并重约窗口——届时从 W2 `gpt`(GPT 分支已实锤)
直接开始。本记录不翻转任何状态,不构成 conformance/hardware/support/release claim。
