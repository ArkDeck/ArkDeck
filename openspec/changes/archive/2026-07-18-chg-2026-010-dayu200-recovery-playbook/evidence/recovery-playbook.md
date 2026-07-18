# DAYU200(RK3568)恢复/救砖预案(未演练;文档研究产物)

CHG-2026-010 / TASK-RP-001。**本预案未经真机演练,不关闭
`GAP-DAYU200-RECOVERY-PATH`,不构成任何执行授权**;真机演练是独立的第③步
change,立项前必须原文引用本预案第 6 节检查单作前置 gate。来源分级:S2=厂商/
官方文档与官方开源仓库;S3=社区教程(仅线索);凡依赖 S3 的步骤逐条标注
**【待演练确证】**。物料引用锚定 archived CHG-2026-003 pinned 镜像
(732948803 bytes / SHA-256 `fc7637…5280`)的 member-inventory.json。

## 1. 强制进入方式与模式判别

- Rockchip 芯片有两级恢复态(S2,Firefly Wiki;S3,CSDN 模式区分文):
  - **MaskRom**:芯片固化 ROM 态,bootloader 损坏/为空时的最底层恢复入口,
    经 RockUSB 协议接受主机命令;
  - **Loader**:已有可用 loader 时的升级态,较高层,能做分区级操作。
- DAYU200 进入 MaskRom 的按键序列(S3,CSDN dayu200 烧录教程)
  **【待演练确证:按键点位与时序须在板上核对】**:按住板上白色
  MaskRom/Recovery 键与 RESET 键 → 松开 RESET(保持 MaskRom 键)→ 主机侧
  出现 MASKROM 设备 → 松开按键。
- 模式判别(macOS 侧,零写操作):`rkdeveloptool ld` 列出设备并标注
  `Maskrom` / `Loader` 字样(S2,Radxa rkdeveloptool 文档);USB 枚举 VID 预期
  为 Rockchip 0x2207,具体 PID 与 `system_profiler SPUSBDataType` 呈现形态
  **【待演练确证】**。
- 判别原则:任何"设备未按预期模式出现"的情形都先重插/重走按键序列,不得
  盲目发写命令。

## 2. 恢复工具与 macOS 可用性结论

| 工具 | 平台 | 可用性结论(文档研究) | 分级 |
| --- | --- | --- | --- |
| `rkdeveloptool` | Linux/macOS CLI | macOS 可用:Homebrew 装依赖(libusb 等)后从官方源码构建(Radxa 文档给出完整步骤);Rockchip 官方开源,视为 upgrade_tool 的开源对应物 | S2 |
| `upgrade_tool` | Linux/Windows CLI | Rockchip 闭源工具;macOS 无官方发布,不纳入本预案 | S2 |
| `RKDevTool` | Windows GUI | 官方 OpenHarmony/DAYU200 烧录教程的默认工具,但仅 Windows;macOS 主机不可用,列为备选路径(需另备 Windows 机) | S2 |

- 结论:**macOS 主机的恢复路径以 `rkdeveloptool` 为准**;构建与安装属演练
  change 的前置步骤(本 change 不执行任何安装/构建)。
- 工具二进制/源码获取仅允许官方仓库与发行渠道,下载物须记录 hash。

## 3. 恢复物料(锚定 pinned 镜像成员,hash 前缀引用)

以下成员名/大小/SHA-256 前缀均引自 archived member-inventory.json;演练前须
对本地物料逐一重算全量 hash 比对:

| 成员 | bytes | sha256 前缀 | 恢复用途(文档结论) |
| --- | --- | --- | --- |
| `MiniLoaderAll.bin` | 455104 | `1cdd41803219` | MaskRom 态第一步注入的 loader(`rkdeveloptool db`) |
| `parameter.txt` | 788 | `35464e3f0b88` | 分区表定义;分区偏移的权威语义由 CHG-2026-009(TASK-PD-001)解码 evidence 提供 |
| `uboot.img` | 4194304 | `c1c801e45cbb` | bootloader 分区镜像 |
| `boot_linux.img` | 67108864 | `390c2cf2bf59` | 内核/boot 分区镜像 |
| `resource.img` / `ramdisk.img` | 5652480 / 2385465 | `161cf158f6f2` / `cc6f7c3d9568` | 启动资源/内存盘 |
| `system.img` | 2147483648 | `aef65124a814` | 系统分区 |
| `vendor.img` | 268431360 | `61e0c9adda44` | vendor 分区 |
| `userdata.img` | 1468006400 | `715e7998ebd4` | 用户数据分区(恢复时写入会清数据,须显式确认) |
| `chip_ckm.img` / `chip_prod.img` / `sys_prod.img` | — | `b60b627…`/`6d009c6…`/`8dfb72c…` | 厂商配置分区【待演练确证:是否必写】 |
| `updater.img` / `updater_binary` | — | `5f70d2f…`/`84659f9…` | 恢复/升级子系统【待演练确证:恢复流程是否使用】 |
| `config.cfg` | 10399 | `4d06d303faff` | RKDevTool(Windows)烧录配置;macOS 路径不直接使用,可作分区写序参考【待演练确证】 |

- 非物料成员:`daily_build.log`、`manifest_tag.xml`(构建元数据,不参与恢复)。

## 4. 恢复步骤序列(不可启动 → 可启动;全部【待演练确证】)

> 前提总则:每步执行前确认上一步判别点成立;任何判别点不成立即进入第 5 节
> 中止流程。分区级写入的目标偏移**以 TASK-PD-001 解码 evidence 为准**,本预案
> 不自行推导地址。

1. 状态判定:`rkdeveloptool ld`。设备可见且标 Loader → 走第 4 步;不可见或
   系统完全不启动 → 走第 2 步。判别点:命令输出与预期模式一致。
2. 进入 MaskRom:按第 1 节按键序列操作;判别点:`ld` 显示 Maskrom 设备。
3. 注入 loader:`rkdeveloptool db MiniLoaderAll.bin`(hash 已校验的本地物料);
   判别点:命令报成功且设备转入可写态。失败常见因(S3,论坛/教程):物料
   不完整、USB 线/口不稳——先复核 hash 与线材再重试,最多重试 2 次。
4. 分区写入:按 PD-001 解码的分区映射逐分区
   `rkdeveloptool wl <offset> <image>`(或按名写入,以演练时工具实际支持
   为准【待演练确证】);判别点:每分区写入报成功。写序建议:loader/uboot →
   boot/resource → system/vendor → 其余;`userdata` 仅在接受清数据时写。
5. 复位验证:`rkdeveloptool rd` 或手动 RESET;判别点:设备正常启动进系统,
   `hdc list targets` 重新可见(只读验证,沿 m0b_capture 白名单)。
6. 记录:全程逐命令记录 argv/输出/结果(演练 change 的 evidence 要求)。

## 5. 风险点与中止准则

- 风险:写错偏移/写错分区(最高风险——因此偏移必须来自 PD-001 evidence,
  禁止现场手算);物料 hash 不符仍烧写;MaskRom 下 `db` 反复失败仍强行重试;
  USB 供电/线材不稳导致中途断写。
- 中止准则(任一命中即停手、拍照/记录现场、结束本次窗口):
  1. 同一步骤连续 2 次失败且已排除线材/hash 因素;
  2. 出现预案未覆盖的报错形态;
  3. 设备呈现预案未描述的 USB 枚举状态;
  4. 任何步骤前发现本地物料 hash 与清单不符。
- 升级路径:中止后收集记录→修订本预案(独立 revision PR)→再约窗口;
  MaskRom 是芯片固化态,理论上始终可重入(S2,Firefly)——这也是"演练风险
  可控"的核心依据,但**该论断本身待演练确证**。

## 6. 演练前置检查单(演练 change 立项时须原文引用并逐项打勾)

- [ ] 恢复物料本地就绪,且逐文件全量 SHA-256 与 member-inventory.json 一致;
- [ ] `rkdeveloptool` 已在演练主机构建完成,`ld` 对无设备场景输出正常;
- [ ] TASK-PD-001 分区解码 evidence 已合入 main(分区偏移权威来源);
- [ ] 维护者书面确认:接受演练期间设备变砖乃至不可恢复的残余风险;
- [ ] 维护者时间窗明确,窗口内无其他设备操作并行;
- [ ] 中止预案(第 5 节)已读并同意;演练记录模板就绪(逐命令 argv/输出);
- [ ] 若需 Windows/RKDevTool 备选路径:备选主机与工具就绪(可选项)。

## 7. 来源引用

- S2:Radxa 文档 rkdeveloptool(macOS 构建与 db/wl 用法)
  <https://docs.radxa.com/en/zero/zero3/low-level-dev/rkdeveloptool>;
  Radxa 文档 RKDevTool(Windows 定位)
  <https://docs.radxa.com/en/zero/zero3/low-level-dev/rkdevtool>;
  Firefly Wiki MaskRom 模式(RK3568 族)
  <https://wiki.t-firefly.com/zh_CN/ROC-RK3568-PC/04-maskrom_mode.html>;
  Radxa 论坛 RK3568 烧写 OpenHarmony 实录(rkdeveloptool db/maskrom 行为)
  <https://forum.radxa.com/t/flashing-openharmony-on-rk3568/24068>
- S3(仅线索,对应步骤已标注待演练确证):CSDN dayu200 烧录教程(按键序列)
  <https://blog.csdn.net/weixin_48322642/article/details/135703392>;
  CSDN RK3568 烧写过程总结(MaskRom/Loader 切换)
  <https://blog.csdn.net/Hero_rong/article/details/123704604>;
  CSDN RK 芯片 Loader/MaskRom 模式区分
  <https://blog.csdn.net/meanshe/article/details/142311299>;
  知乎 RK3568 镜像烧录指南
  <https://zhuanlan.zhihu.com/p/29501645819>
