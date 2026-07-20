# TASK-RH-001 恢复演练 attempt — 2026-07-20 — BLOCKED

- Change:CHG-2026-016-dayu200-recovery-rehearsal@r1 / Task:TASK-RH-001
- 执行:2026-07-20 19:52–19:56 CST,维护者 lvye(fuhanfeng)本人;host macOS
  26.5.2(25F84)/arm64;物理 DAYU200 + USB。Agent 零设备命令(脚本起草+事后核验+
  本记录起草,M0B/PD-002 先例)。
- Evidence class:realHardware **blocked-attempt record**(非三项 realHardware AC
  的 passing evidence;先例 PD-002 platform-attempt #104)。
- Final status:**BLOCKED**。恢复主路径(rkdeveloptool RockUSB db→prm→wlx)在
  loader 注入首步即失败;设备未被写入任何字节,经重启完整恢复到正常态。维护者按
  design §5 正确中止。
- 附:脱敏 transcript `transcript-2026-07-20.txt`(SHA-256
  `0845ab8852fef495f46614b7a5539e2d4fbf7c1bdabc71e7dcdb8919e51d3d72`;用户路径已
  home-mask 为 `<HOME>`/`<ARKDECK_ROOT>`,无设备序列号,唯一 64-hex 为工具 pinned
  hash)。

## Preflight(全部通过)

- 工具:`rkdeveloptool` SHA-256
  `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`(pinned 一致)、
  `-v` = `rkdeveloptool ver 1.32`;
- 物料:17/17 成员逐文件全量 SHA-256 vs archived member-inventory.json =
  **17 MATCH / 0 FAIL / 0 MISSING**;
- Developer Mode enabled。

## 关键发现(本次窗口的核心产出)

**设备的 Maskrom-按键路径产出 `Vid=0x2207,Pid=0x5000`,不是 rkdeveloptool 可驱动的
RockUSB 端点。**

- `rkdeveloptool ld`(含 sudo 复测)稳定输出
  `DevNo=1  Vid=0x2207,Pid=0x5000,LocationID=2  Maskrom`——能枚举;
- 但 `rkdeveloptool db MiniLoaderAll.bin`(无 sudo 与 sudo 各一次)均输出
  `Creating Comm Object failed!`——**建立 RockUSB 通信对象即失败,发生在任何数据
  传输之前**;后续 `prm`/`ppt`/`wlx uboot` 连锁失败
  (`Creating Comm Object failed!` / `Not found any partition table!`)。
- **判读**:`0x5000` 对照 CHG-2026-011 记录的 DAYU200 init cfg 事实 = **updater-hdc
  模式**(`2207:0018`=正常 HDC、`2207:5000`=updater-hdc、`2207:350a`=RockUSB 为
  Radxa 板值 DAYU200 待确证)。rkdeveloptool 的 `ld` 按 USB 描述符启发式误标
  "Maskrom",但 `Creating Comm Object failed!` 证明它不是 RockUSB 端点——rkdeveloptool
  讲 RockUSB 协议,无法驱动 hdc-transport 的 updater 设备。
- **意义**:一手印证 CHG-2026-011 缺席结论(DAYU200 官方仅 Windows RockUSB,
  flashd/hdc 才是设备侧实际通道);是 DEC-002 flash-route 决策的关键真机输入。
- sudo 非解:`db` 在 sudo 下同样 `Creating Comm Object failed!`——排除特权因素,
  确认为模式/协议不匹配。

## 四个 Test ID 判定(如实)

| Test ID | 结论 |
| --- | --- |
| `TEST-RH-DAYU200-RECOVERY-001` | **BLOCKED / NOT EXECUTED**:rkdeveloptool RockUSB 全流程未达成,loader 注入(`db`)首步即 `Creating Comm Object failed!`;无分区被写入 |
| `TEST-RH-DAYU200-MODE-001` | **PARTIAL PASS(observed 事实)**:进态后 `ld` 输出形态与 USB 记录为 `2207:5000`(updater-hdc);落实 CHG-011 待确证的 DAYU200 进态 PID(非 RockUSB `350a`);观察未改变流程 |
| `TEST-RH-DAYU200-TABLE-001` | **BLOCKED / NOT EXECUTED**:`ppt` 输出 `Not found any partition table!`(comm 未建立),无法读回分区表比对 FA-001 §2 基线 |
| `TEST-RH-DAYU200-SAFETY-001` | **PASS(封闭面与隐私合规)**:全部设备命令属 design §2 封闭面(计数:读 `ld`×3/`ppt`×1、写尝试 `db`×2/`prm`×1/`wlx`×1,+recovery postcheck m0b 白名单);首写前工具/物料 hash 全部复核;**零字节写入**(comm 从未建立);零现场手算(未达 wl 回退);orphan 镜像与无成员分区零命令;§5 中止准则触发即遵守(维护者在 W3 uboot 失败处 Ctrl-C);序列号未入本记录/transcript(仅 recovery-check raw 在仓库外) |

## 设备恢复确认(附带 recovery 事实)

- 设备处 updater-hdc 软模式,经**物理断电重启**恢复到正常系统;
- recovery postcheck(m0b_capture 既有白名单只读):`hdc list targets` plain 33B
  SHA-256 `2035c0783fe1b2fbc3bba6badfb76003c1a5d46bbe16d1479de439e9fd874fc2`、
  verbose 58B `d8816e413776d80e6e577b78f6abbf8c114bfd570b3627f7a007c97681af9c48`
  ——**与 merged M0B/PD-002 device 采集逐字节相同**,即设备回到与演练前一致的正常
  `Connected` 态(同 identity)。raw 留仓库外 `~/dayu200-rehearsal/recovery-check/`。
- **有限 recovery 结论**:从 updater 模式经重启可完整恢复;但这**不等于** RECOVERY-001
  要求的 rkdeveloptool RockUSB 全流程恢复——后者未达成。

## 偏差 / 遗留

- **执行脚本初版缺 sudo**(Agent 起草疏漏):首轮 `db` 无 sudo 失败;sudo 复测证明
  非特权问题,如实记录。
- **RECOVERY 主路径假设被真机推翻**:design r1 假定 Maskrom-按键 → RockUSB →
  rkdeveloptool 全流程;真机上该按键路径产出 updater-hdc(0x5000),rkdeveloptool
  RockUSB 不通。need design revision:或研究 hdc/flashd 恢复路线、或研究真 RockUSB
  Maskrom(`0x350a`)的正确物理进态(通常需接地 eMMC 时钟强制 BootROM Maskrom),
  再约窗口。
- `GAP-DAYU200-RECOVERY-PATH` **保持 open**(本次未关闭);DEC-002 保持 open,本
  attempt 的 0x5000 发现作为其新增真机输入(登记走后续 governance PR)。
- 维护者在 W1/W2 confirm 处曾答 `y`,但命令输出为失败——**本记录以命令输出为准,
  不以点击为准**;transcript 保留原始输出。

## Boundary

blocked-attempt 零 governed PASS;不构成产品 flash 能力/兼容性/support/release
声明;不关闭任何 gap;hardware matrix 不新增 supported 行。`ready→done` 不适用
(RECOVERY/TABLE 未达成);后续=design revision + 重约窗口,或 DEC-002 route 决策。
