# DAYU200 演练准备记录(TASK-RR-001;host-only,设备不在场)

CHG-2026-013 / TASK-RR-001。执行日期:2026-07-18;执行主机=演练主机
(维护者 macOS `26.5.2 (25F84)`,arm64,Apple clang 21.0.0)。**全程 DAYU200
不连接主机**:操作者(维护者 fuhanfeng)于执行前在会话中书面确认已断开;
`ld` 采集输出零设备枚举行佐证。本记录为 archived CHG-2026-010 预案 §6 检查单
第 1/2 项与第 6 项模板部分提供打勾 evidence;**打勾动作发生在未来演练 change
立项时,本记录不构成演练授权**。host 侧产物路径以 `~` 掩蔽 home;物料/构建
产物字节不入仓。

## 1. 工具构建(检查单第 2 项)

- 依赖:automake 1.18.1_1 / autoconf 2.73 / libusb 1.0.30 / pkgconf 2.5.1
  均已在位(Homebrew),`brew install` 跳过(白名单"已装则跳过"分支)。
- 源码:`git clone https://github.com/rockchip-linux/rkdeveloptool.git`
  → `~/dayu200-rehearsal/rkdeveloptool`,HEAD commit
  `304f073752fd25c854e1bcf05d8e7f925b1f4e14`(2025-03-07,上游 master)。
  另克隆 radxa fork(`https://github.com/radxa/rkdeveloptool.git`,HEAD
  `ac50fcb73a63af566ea728464e376131b9384948`)仅用于交叉诊断,未用于最终构建。
- 构建序列(净化 PATH=`/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`,
  见 §3 发现 F1):`autoreconf -i`(exit 0)→ `./configure`(exit 0)→
  `make CXXFLAGS="-g -O2 -Wno-vla-cxx-extension"`(exit 0,`error:` 计数 0;
  旗标追加原因见 §3 发现 F2,**零源码修改**)。
- 产物:`~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool`,205760 bytes,
  SHA-256 `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`。

## 2. 无设备冒烟(检查单第 2 项;byte-exact 分流采集)

| 命令 | exit | stdout(bytes / SHA-256) | stderr | 判定(按输出标记) |
| --- | --- | --- | --- | --- |
| `rkdeveloptool -v` | 0 | 24 / `8edc164e8e73ec8e3bd3cb242ccaa73dec5492bf070e958e827073b4d98a0468` | 空 | `rkdeveloptool ver 1.32` —— 满足 ≥1.32(CHG-2026-011 §3 版本约束) |
| `rkdeveloptool --help` | 0 | 752 / `f0b94492dab347f5cc966c2a248851a69c270aa8809e000fb9ba1441d0b158ad` | 空 | usage 命令全集与 CHG-2026-011 事实清单 §4 分类一致(ld/td/rid/rfi/rci/rcb/ppt/rl 读类;db/ul/wl/wlx/gpt/prm/ef/rd/cs 写类) |
| `rkdeveloptool ld` | **1** | 24 / `1d216c21d0c8cb11b7433f84579aa04c6fd84bec4a19e3541fbe0f844b66d939` | 空 | `not found any devices!` —— 无设备形态正常,**零设备枚举行**(设备不在场佐证) |

- `-v` 原始 stdout:`rkdeveloptool ver 1.32`(+LF)。
- `ld` 原始 stdout:`not found any devices!`(+LF)。
- **注意:`ld` 无设备场景 exit=1**——退出码不可信教训(M0A `[success]`、M0B
  `hidumper --help` exit 0 同族)再添一例;一切判定必须按输出标记。
- 采集文件:`~/dayu200-rehearsal/captures/{v,help,ld}.{out,err}`(三个 .err
  均 0 字节,SHA-256 = 空串 hash `e3b0c442…`)。

## 3. 构建期发现(对演练环境有效)

- **F1(环境陷阱,高价值)**:本机 PATH 中 OpenHarmony SDK toolchains 目录
  (DevEco-Studio 内,为 hdc 加入)排在 `/usr/bin` 之前,其内含同名 `diff`
  (Mach-O arm64,非 POSIX 语义):对不识别选项报错、**对不存在文件对仍
  exit 0**。后果:autoconf `config.status` 用 PATH 上的 `diff` 判断 header
  是否变化,误判"unchanged"而**静默跳过 `cfg/config.h` 生成**,make 报
  `config.h file not found`(上游与 radxa fork 双双复现,证明与仓库无关)。
  修复:构建全程净化 PATH。**对演练的含义:演练主机上任何构建/脚本执行前
  必须净化 PATH 或用绝对路径**——已写入演练记录模板前置检查第 P4 项。
- **F2**:上游 `-Wall -Werror` 遇 Apple clang 21 的 `-Wvla-cxx-extension`
  告警升级为 error(main.cpp VLA 用法,Linux/gcc 下无此告警);以
  `make CXXFLAGS="-g -O2 -Wno-vla-cxx-extension"` 追加旗标构建,零源码修改。
- F3:构建依赖四件套本机已全数在位,无新增安装。

## 4. 恢复物料复核(检查单第 1 项)

- pinned 归档:`~/Downloads/version-Daily_Version-OpenHarmony_7.0.0.33-20260713_000751-dayu200_img.tar.gz`
  全量重算:**732948803 bytes / SHA-256
  `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`**——与
  archived CHG-2026-003 archive-identity.json 逐字节一致。
- 解包至 `~/dayu200-rehearsal/materials/`(tar exit 0),对 archived
  member-inventory.json 全部 17 成员逐文件**全量** SHA-256 重算比对:
  **17/17 MATCH,0 FAIL**(size 与 sha256 双比对):

| 成员 | bytes | SHA-256(重算,与 inventory 一致) | 结果 |
| --- | --- | --- | --- |
| `MiniLoaderAll.bin` | 455104 | `1cdd418032195210f191445ed96e2da5ea83d2cfe880c912ebec635839d76542` | MATCH |
| `boot_linux.img` | 67108864 | `390c2cf2bf59f8bedc99a9622a1263410c6132341aece6a1b9c30ed5567a9523` | MATCH |
| `chip_ckm.img` | 33554432 | `b60b62747679659c337eef737ea5064bbcea68b9fc219f62a076c06d05a6c81a` | MATCH |
| `chip_prod.img` | 52428800 | `6d009c6b685f65f91bd77ceb201916f07dde8668fde4432ee534bb04e0b6cbad` | MATCH |
| `config.cfg` | 10399 | `4d06d303faff1d3e530a9d2c9bb22073427b0b498bb4bb438b5177897d86f33c` | MATCH |
| `daily_build.log` | 24496219 | `5823dd263cab3168dbd3ee098c5b5045b82b8393548b9da9f095de2883a2a0e9` | MATCH |
| `manifest_tag.xml` | 114913 | `fd458507b4bb63f372049a0bb9a2cd779af426e2d27de43134ace05e5884ff74` | MATCH |
| `parameter.txt` | 788 | `35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048` | MATCH |
| `ramdisk.img` | 2385465 | `cc6f7c3d9568cbb3f810edd67ebe0015a04734605ca4f21c065ce94f88ec3b07` | MATCH |
| `resource.img` | 5652480 | `161cf158f6f256e7794568b1307581e4656da1a8d8d3d2612da73195d3eda06e` | MATCH |
| `sys_prod.img` | 52428800 | `8dfb72cfa61dc748f62f3d766214ab579c857f3b8a62e6890a8abc7ae0ac1062` | MATCH |
| `system.img` | 2147483648 | `aef65124a814fcce8345dbfbdf049aaa862bd76786d099095c6951b4561ba1bb` | MATCH |
| `uboot.img` | 4194304 | `c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d` | MATCH |
| `updater.img` | 20692486 | `5f70d2f79cbcda267a20aff98c187ffdaac2ce1f693ae6f7dbdc2bec7b1c5494` | MATCH |
| `updater_binary` | 3248612 | `84659f9fd5a13b8293904f9ad7531ee9637523efffb90e74a49443f9f8ef5cd5` | MATCH |
| `userdata.img` | 1468006400 | `715e7998ebd47653a0ec2e062964224684762ab8686330c6b69b8d5f1f55886c` | MATCH |
| `vendor.img` | 268431360 | `61e0c9adda4420417d88bcc1f4d725558b75e41046f528100a584c8dc466cd41` | MATCH |

- 非物料成员(`daily_build.log`/`manifest_tag.xml`,构建元数据)同样重算并
  MATCH,维持 inventory 完整对账;演练不使用它们(预案 §3 口径)。

## 5. host 侧持久物清单(演练时复用;字节不入仓)

- 工具:`~/dayu200-rehearsal/rkdeveloptool/rkdeveloptool`(hash 见 §1;演练前
  须重算比对);
- 物料:`~/dayu200-rehearsal/materials/`(17 成员;演练前须按检查单第 1 项
  重新逐文件全量比对);
- 采集与构建日志:`~/dayu200-rehearsal/captures/`、
  `~/dayu200-rehearsal/captures-build-*.log`。

## Boundary

host-only;设备不在场;不勾检查单第 3/4/5 项、不立项演练、不构成演练执行
授权;不解除任何 gap;DEC-002 不变。
