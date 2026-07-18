# DAYU200(RK3568)烧写协议事实清单(文档研究;未真机确证)

CHG-2026-011 / TASK-FP-001。**本清单是文档级结论,不构成兼容性/支持声明,不
解除 `GAP-DAYU200-FLASH-PROTOCOL`,不构成任何执行授权;DEC-002 保持 open**。
来源分级:S2=厂商/官方文档与官方开源仓库(含源码);S3=社区教程/第三方
(仅线索);凡关键结论仅有 S3 支撑、或由 S2 源码/文档**推断**而无直接文字
陈述者,逐条标注**【待真机确证】**。仓库内已合入的 M0B 实测事实以
「内部 evidence」引用(CHG-2026-006 TASK-M0B-001 run.md /
hardware-evidence.json),区别于外部文档。传输层研究范围仅 USB;
**TCP/UART 明确 out of scope**(route-b/M0B 已推迟,本 change 不研究)。

## 1. 通道枚举(文档级定义与适用态)

| 通道 | 文档级定义 | 适用态 | 分级 |
| --- | --- | --- | --- |
| A. RockUSB(MaskRom 态) | Rockchip 私有 USB class,BootROM 固化实现,用于固件下载;存储上无可启动固件时自动进入,亦可强制进入 | 芯片级最底层态,DRAM 未初始化、下载大小受限;须先 `db` 注入 loader 转入 usbplug 态 | S2(Rockchip 官方 wiki_Rockusb) |
| A'. RockUSB(Loader/usbplug 态) | `db` 注入 loader 后的 RockUSB 态(DRAM 已初始化,可做分区级读写);另有 legacy Miniloader Rockusb 态(`reboot loader`/recovery 键)与 U-Boot Rockusb 态(`rockusb 0 mmc 0`) | 分区级烧写主力态;OpenHarmony 官方 DAYU200 烧录教程中 RKDevTool 的 LOADER 设备即此类态 | S2(wiki_Rockusb;OH quickstart;HiHope 烧录指导) |
| B. OpenHarmony flashd(HDC 传输) | 升级子系统 updater 的刷机模式:「提供格式化用户分区、擦除分区、刷写镜像、zip 整包升级」;client/server 结构,host 与设备间以 HDC 为数据传输通道;设备侧是基于 hdc daemon 框架的 flashd daemon(`services/flashd/daemon/flashd_main.cpp`,`REGISTER_MODE(Flashd, "updater.flashd.configfs")`) | 仅 root 设备且处于升级(updater)模式时存在;官方定位为「不支持 fastboot 刷机的设备」的替代路径 | S2(update_updater flashd Readme/源码;OH hdc 指导「升级模式」节) |
| C. fastboot | hdc 保留 `target boot -bootloader` 进入方式;flashd 文档以「不支持 fastboot 的设备」为其定位 | DAYU200/RK3568 无任何官方 fastboot 烧写文档;不作为候选主路径 | S2(hdc 指导)+ 缺席结论 |
| D. sideload(OTA 整包) | hdc host usage 源码列 `sideload [PATH]`(完整 OTA 包旁加载);docs 命令表未收录 | 升级路径而非裸镜像烧写;仅源码可见,文档级状态不明【待真机确证】 | S2(developtools_hdc translate.cpp,source-only) |

- 通道 A/A' 的 host 工具(RKDevTool/upgrade_tool/rkdeveloptool)是**同一 RockUSB
  通道的不同客户端**,不构成独立通道(§3)。
- **DAYU200 官方烧写路径事实**:OpenHarmony RK3568 quickstart 烧录文档与
  HiHope 板卡烧录指导均只写 Windows(DriverAssitant + RKDevTool/DevEco Device
  Tool,Loader/MaskRom 态);**通篇未提 flashd/hdc 烧写,亦无 macOS 路径**
  (S2,缺席结论)。flashd 在 RK3568 板卡 updater init cfg 中确有接线
  (`updater.flashd.configfs` job,S2 device_board_hihope 源码),即代码路径
  存在但**端到端流程对 DAYU200 无官方文档**【待真机确证】。

## 2. 进入方式与传输层

### 2.1 进入条件(按通道)

| 通道/态 | 进入方式(文档级) | 分级 |
| --- | --- | --- |
| MaskRom | 自动:存储上无可启动固件;强制:断开/短接存储(eMMC clock 等)或板上按键 | S2(wiki_Rockusb;Radxa);DAYU200 具体按键序列仅 S3(CSDN)**【待真机确证】**(与 CHG-2026-010 预案 §1 同源) |
| Loader | 系统内 `reboot loader`(begetctl/init 文档:「重新启动并进入烧写模式」);OH quickstart(DevEco 路径):按住 VOL+/Recovery 键 + RESET,约 3 秒进 Loader | S2(subsys-boot-init-plugin;OH quickstart-ide-3568-burn) |
| flashd | 文档正路:`hdc shell write_updater boot_flash` + `hdc shell reboot updater`(hdc 指导);等价:`reboot flashd`(init 的 `DoRebootFlashed` 写 misc「boot_flash」后重启,begetctl 文档表格收录);`hdc target boot flashd` 为两份官方文档的**链式推断**(`target boot [MODE]`=begetctl reboot 参数直通),无逐字文档**【待真机确证】**;前提:root 设备;flashd Readme(2021 era)另记 `hdc_std shell reboot updater` 旧说法 | S2(hdc 指导;startup_init reboot.c;begetctl 文档;update_updater 源码) |
| U-Boot Rockusb | U-Boot 命令行 `rockusb 0 mmc 0` | S2(wiki_Rockusb);DAYU200 的 uboot 是否保留该命令**【待真机确证】** |

### 2.2 传输层与 USB 识别形态(VID/PID 文档值)

- 传输层:两通道均 USB。flashd daemon 源码含 `-t`(TCP)选项且默认 USB
  (S2 flashd_main.cpp);**TCP/UART 均 out of scope,本 change 不研究**。
- Rockchip USB VID = `0x2207`(S2 wiki_Rockusb)。
- **RockUSB 态 PID**:官方 wiki 的 per-SoC PID 表止步 RK3399(0x330c),
  **未收录 RK356x**;RK3568 在 MaskRom/Loader 态枚举为 `2207:350a` 出自
  Radxa RK3568 板文档(`rkdeveloptool ld` 实录 `Vid=0x2207,Pid=0x350a`),
  非 DAYU200 板**【待真机确证】**(S2 Radxa,适用板不同)。
- **MaskRom/Loader 同 VID:PID,不以 PID 区分**:rkdeveloptool 源码以 USB 设备
  描述符 `bcdUSB` 最低位判别(0=MASKROM,1=LOADER;RKScan.cpp),`ld` 输出
  逐设备打印 `Maskrom`/`Loader`/`Unknown` 字样(S2 源码)。
- **hdc/flashd 态识别**:host hdc 不按 VID/PID 识别设备,而按接口描述符
  `bInterfaceClass=0xff, bInterfaceSubClass=0x50, bInterfaceProtocol=0x01`
  (S2 host_usb.cpp/usb_ffs.h);文档级识别指引仅「设备管理器见 HDC
  Device/HDC Interface」。DAYU200 板卡 init cfg(S2 device_board_hihope):
  正常系统 `2207:0018`(product 字符串「HDC Device」,`ffs.hdc`);updater 态
  hdc 分支改写 `idProduct 0x5000`(即 `2207:5000`);**flashd 分支沿用
  `2207:0018`**——此为 init cfg 源码推断,无文字文档**【待真机确证】**。
- 内部 evidence:M0B 实测 DAYU200 正常系统经 USB 被 hdc 识别(transport
  USB;serial 见 hardware-evidence.json),与上述 `2207:0018`/HDC Device
  形态相容,但 M0B 未记录 VID/PID 数值。

## 3. 工具映射(host 工具 × 通道 × macOS 可用性 × 版本约束)

| 工具 | 通道 | 平台 | macOS 可用性(文档级) | 版本约束(文档级) | 分级 |
| --- | --- | --- | --- | --- | --- |
| `rkdeveloptool` | RockUSB | Linux/macOS CLI | **可用**:Radxa 文档给出 macOS(Intel/Apple Silicon)Homebrew 依赖(automake/autoconf/libusb/pkg-config)+ 官方源码构建全步骤;已知坑=缺 pkg-config 的 PKG_CHECK_MODULES 报错 | Radxa 对 RK3568 代要求 **≥ v1.32**(`rkdeveloptool -v` 验证);上游 repo 无 release,v1.32 为 configure.ac 版本(上游与 radxa fork 一致);仅烧 raw 镜像,**不支持 update.img 整包格式**(S3);依赖 libusb-1.0 | S2(Radxa docs/wiki;rockchip-linux 源码);update.img 限制 S3(cnx-software,与 Firefly 工具描述相容) |
| `upgrade_tool` | RockUSB | Linux CLI(闭源) | 无官方 macOS 发布,不可用 | 支持 update.img 与 raw 镜像(Firefly 文档) | S2(Firefly) |
| `RKDevTool` | RockUSB | Windows GUI | 不可用(仅 Windows;v2.86 发行包) | OpenHarmony/HiHope 官方 DAYU200 烧录教程默认工具(配 DriverAssitant v5.1.1) | S2(Radxa;OH quickstart;HiHope) |
| `hdc` | flashd(HDC 传输) | Windows/Linux/macOS CLI | **官方支持 macOS**:hdc 指导明示三平台;SDK toolchains 内置(macOS 位于 DevEco-Studio Contents/sdk);官方另发 Mac/Mac-M1 SDK 包 | 版本串 `Ver: X.X.Xx`(`-v`/`checkserver`);官方版本配套表:3.1.0a→API 12、3.1.0e→API 15+、3.2.0b→API 20;兼容性为**软约束**(「设备刷最新镜像须用最新 hdc」,不匹配报 `[Fail]Failed to communicate with daemon`),无硬性最低版本握手文档 | S2(OH hdc 指导 zh;release notes) |

- 内部 evidence(M0B 实测,已合入 main):macOS host `hdc Ver: 3.2.0d`
  (client=server,`checkserver` 实测;binary 出自 DevEco-Studio SDK
  toolchains,SHA-256 已钉),设备 OpenHarmony `7.0.0.34` / API `26.0.0`,
  组合可用——这是 hdc「macOS 可用」的仓库内实测锚点,但**不构成 flashd 刷机
  模式可用性的证据**(M0B 全程只读白名单,未进 flashd)。
- 结论(文档级,非支持声明):macOS host 上 RockUSB 通道唯一候选客户端为
  `rkdeveloptool`(与 CHG-2026-010 恢复预案 §2 结论一致);flashd 通道候选
  客户端为 SDK 自带 `hdc`,但 flashd 端到端对 DAYU200 无官方文档背书
  (§1 缺席结论)**【待真机确证】**。

## 4. 只读观察面草案(设计;非执行授权)

> 本节是**未来**第一阶段受控采集的候选清单草案。**其执行属后续独立
> change(须独立立项/approve),本文档不构成任何执行授权**。分类规则:
> 【只读】=不改变设备任何持久/运行状态;凡涉及模式切换、重启、写分区者
> 一律【第二阶段·写设备·RECOVERY 先行】,不纳入第一阶段执行面。M0B 教训
> 沿用:工具退出码不可信(hidumper --help exit 0 先例),成败判定须基于
> 输出标记并保留原始字节。

### 4.1 第一阶段候选(逐条只读性标注)

| 候选命令 | 前提 | 只读性 | 备注 |
| --- | --- | --- | --- |
| `rkdeveloptool --help` / `-v` | host-only,无设备 | 【只读】(不触碰设备) | 采集 usage 文本与版本串,核对 ≥1.32 |
| `rkdeveloptool ld` | host-only;设备可缺席 | 【只读】(USB 枚举级列举) | 无设备场景输出形态即有观察价值(CHG-2026-010 检查单第 2 项同源);**若设备已处 Maskrom/Loader 态**则显示模式字样——但使设备进入该态的操作本身属第二阶段 |
| `hdc -v` / `hdc version` / `hdc checkserver` | host-only | 【只读】 | M0B 已有 3.2.0d 实测锚点,复采仅为版本漂移检测 |
| `hdc list targets [-v]` / `hdc checkdevice <serial>` | 设备正常系统在线 | 【只读】 | 沿 m0b_capture 白名单先例 |
| `hdc shell getparam const.*` 类参数读取 | 设备正常系统在线 | 【只读】(shell 内仅读参数) | 逐条命令须在执行 change 中白名单化;shell 本身可执行任意命令,故白名单为硬边界 |
| `td`/`rid`/`rfi`/`rci`/`rcb`/`ppt`/`rl`(rkdeveloptool 读类命令) | **设备须已处 Maskrom/Loader 态** | 命令本身【只读】(读 ID/flash 信息/分区表/LBA) | **进入该态=模式切换=【第二阶段·写设备·RECOVERY 先行】**;第一阶段不执行 |

### 4.2 模式切换/写设备候选(全部排除出第一阶段)

以下每条均标注**【第二阶段·写设备·RECOVERY 先行】**(route-b-plan 硬顺序
规则:`GAP-DAYU200-RECOVERY-PATH` 关闭前不得执行;演练 change 须引用
CHG-2026-010 §6 检查单作前置 gate):

- `hdc target boot`(任意变体:`-bootloader`/`-recovery`/`flashd`/`loader`/
  `updater` MODE 直通)——重启并切换设备模式;
- `hdc shell write_updater boot_flash`、`hdc shell reboot ...`(含
  `updater`/`flashd`/`loader`)——写 misc 分区并重启;
- `hdc update` / `hdc flash` / `hdc erase` / `hdc format` / `sideload`
  ——flashd 刷机面本体(擦关键分区即变砖,flashd Readme 明示);
- `hdc target mount`、`hdc smode`、`hdc tmode ...`——挂载可写/守护进程
  重启/通道状态变更;
- `rkdeveloptool db`/`ul`/`wl`/`wlx`/`gpt`/`prm`/`ef`/`rd`/`cs`——注入
  loader/写 LBA/写分区表/擦除/复位/切存储(`db` 虽不落盘但注入并运行代码、
  改变设备运行态,归入写类);
- 任何使设备进入 MaskRom/Loader 的物理操作(按键/短接)——改变设备运行态。

## 5. 来源引用(S2/S3 分级)

- S2(厂商/官方文档与官方开源仓库):
  - Rockchip 官方 wiki:Rockusb 协议/模式/工具与 per-SoC PID 表
    <http://opensource.rock-chips.com/wiki_Rockusb>
  - rkdeveloptool 源码(上游):usage 命令全集 main.cpp、模式判别 RKScan.cpp、
    版本 configure.ac
    <https://github.com/rockchip-linux/rkdeveloptool>(radxa fork 同版本
    <https://github.com/radxa/rkdeveloptool>)
  - Radxa 文档/维基:RK3568 maskrom/loader 实操(`2207:350a`、`ld` 输出)、
    macOS 构建步骤、≥1.32 要求
    <https://wiki.radxa.com/Rock3/install/rockchip-flash-tools>
    <https://wiki.radxa.com/Rock3/install/usb-install>
    <https://docs.radxa.com/en/som/cm/cm3/low-level-dev/rkdeveloptool>
    <https://docs.radxa.com/en/rock3/rock3b/low-level-dev/maskrom/mac-os>
  - Firefly 文档:upgrade_tool(Linux/闭源/update.img)、MiniLoaderAll.bin
    先写惯例
    <https://wiki.t-firefly.com/en/Firefly-RK3399/03-upgrade_firmware.html>
    <https://wiki.t-firefly.com/en/ROC-RK3566-PC/03-upgrade_firmware_with_flash.html>
  - OpenHarmony hdc 使用指导(zh master;含「升级模式」flashd 节、命令表、
    版本配套表、三平台支持)
    <https://gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/subsystems/subsys-toolchain-hdc-guide.md>
  - OpenHarmony init 插件文档(begetctl `reboot flashd`/`reboot loader` 表)
    <https://gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/subsystems/subsys-boot-init-plugin.md>
  - update_updater 仓库:flashd Readme、flashd 源码(flashd_main.cpp、
    commanders、flashd.h)、write_updater.cpp、services/main.cpp
    <https://gitee.com/openharmony/update_updater>
  - startup_init 源码:reboot.c(`DoRebootFlashed`)、init_cmd_reboot.c
    <https://gitee.com/openharmony/startup_init>
  - developtools_hdc 源码:translate.cpp(flash commands usage)、define.h
    (CMDSTR_FLASHD_*)、host_usb.cpp/usb_ffs.h(接口识别)
    <https://gitee.com/openharmony/developtools_hdc>
  - device_board_hihope RK3568 源码:正常/updater/flashd USB init cfg
    (`2207:0018`/`0x5000`、`updater.flashd.configfs`)
    <https://gitee.com/openharmony/device_board_hihope>
  - OpenHarmony RK3568 quickstart 烧录文档(Windows/RKDevTool/DriverAssitant
    默认路径;VOL+ 进 Loader)
    <https://gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/quick-start/quickstart-ide-3568-burn.md>
    <https://gitee.com/openharmony/docs/blob/master/zh-cn/device-dev/quick-start/quickstart-pkg-3568-burn.md>
  - HiHope DAYU200 烧录指导(RKDevTool/Windows;Linux udev 路径;无 macOS)
    <https://gitee.com/hihope_iot/docs/blob/master/HiHope_DAYU200/docs/%E7%83%A7%E5%BD%95%E6%8C%87%E5%AF%BC%E6%96%87%E6%A1%A3.md>
  - OpenHarmony v5.0.0 release notes(Mac/Mac-M1 SDK 包)
    <https://gitee.com/openharmony/docs/blob/master/zh-cn/release-notes/OpenHarmony-v5.0.0-release.md>
- S3(社区/第三方,仅线索;对应结论已标待真机确证):
  - CSDN dayu200 烧录教程(按键序列;rkdeveloptool db/wl 序列)
    <https://blog.csdn.net/weixin_48322642/article/details/135703392>
    <https://blog.csdn.net/m0_64420071/article/details/137241029>
  - cnx-software rkdeveloptool 介绍(不支持 update.img)
    <https://www.cnx-software.com/2018/07/10/rkdeveloptool-flash-linux-firmware-rockhip/>
  - USB ID 数据库(0x2207 注册归属)
    <https://the-sz.com/products/usbid/index.php?v=0x2207>
  - Homebrew 第三方 tap(rkdeveloptool v1.32 for macOS,打包存在性线索)
    <https://github.com/IgorKha/homebrew-rkdeveloptool>
- 内部 evidence(仓库内已合入实测,非本 change 执行):
  - CHG-2026-006 TASK-M0B-001 run.md / hardware-evidence.json(hdc 3.2.0d、
    OH 7.0.0.34/API 26.0.0、transport USB、SDK toolchains 路径与 hash)
  - CHG-2026-010 recovery-playbook.md(工具可用性结论与按键序列 S3 标注同源)
