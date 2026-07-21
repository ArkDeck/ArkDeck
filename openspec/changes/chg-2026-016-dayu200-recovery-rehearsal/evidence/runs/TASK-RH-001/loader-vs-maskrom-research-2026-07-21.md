# RH-001 支持研究 — Loader 态 vs MaskRom 态与 W3 wlx 判决预案 — 2026-07-21

- Change:CHG-2026-016 / Task:TASK-RH-001(下窗口执行支持研究)
- Class:**documentReview**(权威 RK3568/rkdeveloptool 文档推导;**非真机**,零设备
  命令)。DAYU200 板上具体 rockusb 命令子集仍待下窗口 `wlx` 真机确证。
- 目的:解释 attempt #2–#4 的设备行为(`db`×2、`gpt`×4 被同族拒、读类始终完好),并
  为下窗口 W3 `wlx` 判决的**两个分支**预备接地素材。不改 design、不改命令面、不预判
  真机结果。

## 权威区分:Loader 态 ≠ MaskRom 态

Rockchip/Firefly 文档明确两种 USB 下载态:

- **Loader mode**:板上 bootloader **完好**,启动时检测到 `RECOVERY` 键 + USB 连接 →
  bootloader 自身进入升级等待态,由**它的** rockusb gadget 处理 host 命令。
- **MaskRom mode**:仅当 bootloader **损坏/读不出 IDB** 时,BootROM(片上固化)接管、
  等待 host 经 USB 传入 loader 代码。

## 本设备状态判定:处于 Loader 态,非 MaskRom

四窗口 `ld` 稳定显示 `Vid=0x2207,Pid=0x350a,LocationID=2 **Loader**`——按上文即
**Loader mode**(bootloader 完好 + RECOVERY 键进入),**不是** MaskRom。`0x350a` 是
RK3568 的 RockUSB PID,Loader/MaskRom 共用该 PID,靠 `ld` 第三列标签区分。我们的按键
序列进入的正是文档描述的"RECOVERY 键 → Loader 升级态",与设备 bootloader 完好一致。

## `db`/`gpt` 被拒的机制(与证据吻合)

- `db`(DownloadBoot)是把 loader 代码传给 **MaskRom 态的 BootROM**;设备已在 Loader
  态(bootloader 在跑、BootROM 已交权),故 `db` 被拒——attempt#2 实证。
- `gpt`(写分区表)在 Rockchip 正常流程属 MaskRom+注入 miniloader 阶段的操作;板上
  U-Boot 的升级态 rockusb 子集未实现,故被同族拒——attempt#3/#4 实证。
- 读类 `ld`/`ppt` 属查询命令,U-Boot 升级态实现,始终完好;`ppt` 四窗口读出同一 GPT
  表(15/15 match FA-001 §2)= 分区表已在设备侧且正确。

## W3 `wlx` 判决:为何**有合理成功可能**(核心)

`wl`(WriteLBA)/`wlx`(按分区名写)是往**已存在分区表**的已知 LBA/分区写数据——这
正是 **Loader 升级态的核心用途**(不需要 `db`,因为 loader 已在跑)。而本设备:分区表
已在(`ppt` 15/15)、Loader 完好在跑。因此 U-Boot 升级态**很可能**实现了 `wl`/`wlx`
写数据命令,即使它拒绝 `db`/`gpt`(改分区表类)。**结论:`wlx` 成功可能性合理,不是
悲观预期**;但 DAYU200 板上 U-Boot 的确切命令子集仍须下窗口真机确证。

## 两分支接地预案

- **分支 A:`wlx uboot` 成功** → 印证"U-Boot Loader 升级态支持按现有分区表写数据"。
  crib 自动写完九分区 → 真实恢复达成 → RECOVERY gap 关闭 → DEC-002 → real-flash 立项。
  real-flash change 的命令面即以 Loader 态 `wlx`(分区表已在)为主路径。
- **分支 B:`wlx`+`wl` 均被同族拒** → Loader 态 U-Boot rockusb 不实现任何写类 →
  必须进**真 MaskRom**。文档接地的进态方法:重启时按 RECOVERY,设备尝试从 eMMC 引导
  pre-loader,**若 BootROM 读不到可引导 IDB 则进 MaskRom**;bootloader 完好的设备正常
  按键进不了 MaskRom,须**硬件强制**(短接 eMMC clk/cmd 使 BootROM 读不到 IDB)——
  Firefly/Kobol 明确标注该操作有硬件风险,是"防砖最后防线",仅在 Loader 路线确证不可行
  后才做。此分支须另立 design revision(硬件强制进态步骤 + 风险再确认),不在本 change
  当前授权面。

## 边界

本研究为通用 RK3568/rkdeveloptool 文档推导,减小了理论不确定性但**不替代**下窗口
`wlx` 真机判决;DAYU200 特定命令子集以真机为准。不改 design r4、不改命令面、不翻转
任何状态,不构成 conformance/hardware/support/release claim。

## 来源

- Firefly Wiki — MaskRom mode / boot mode:
  https://wiki.t-firefly.com/en/ROC-RK3568-PC/04-maskrom_mode.html 、
  https://wiki.t-firefly.com/en/ROC-RK3568-PC/01-bootmode.html
- Rockchip Wiki — how to enter rockusb maskrom mode:
  http://rockchip.wikidot.com/how-to-enter-rockusb-maskrom-mode
- Rockchip open source — Partitions / Rkdeveloptool:
  https://opensource.rock-chips.com/wiki_Partitions 、
  https://opensource.rock-chips.com/wiki_Rkdeveloptool
- rkdeveloptool issues(报错族先例):
  https://github.com/rockchip-linux/rkdeveloptool/issues/13 、
  https://github.com/rockchip-linux/rkdeveloptool/issues/43
- Kobol Wiki — Maskrom Mode(硬件强制风险):
  https://wiki.kobol.io/helios64/maskrom/
