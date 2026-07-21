# TASK-RF-001 — `images.tar.gz` 契约与 `RockchipFlashProfile` 定义

- Change:CHG-2026-020-dayu200-real-flash / Task:TASK-RF-001(阶段 A,契约/Profile
  documentReview 部分;真机正向烧写 evidence 另见 `run.md` 设备窗口执行后)
- Class:documentReview(host-only,零设备命令);真机执行由人类维护者(REQ-FLASH-015)。
- Base:readiness PR #227 合入后 main。本文件是正向烧写 exact plan 的唯一 Profile 依据
  (REQ-FLASH-001/002/003),锚定 CHG-2026-003 `member-inventory.json`、CHG-2026-009
  PD-002 `partition-mapping.json`(`965e3bf3…`)与 CHG-2026-012 FA-001 §2 地址表,均只读
  引用、零改写。

## 1. `images.tar.gz` 输入契约(REQ-FLASH-003)

- 顶层 = 单个 gzip tar;首验 pinned 包 = CHG-2026-003 archived identity(size
  `732948803`、SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`);
- validate:解包后逐成员 SHA-256 vs 下表,任一不符 → 阻断 execute 与 planned-success
  (AC-FLASH-003-01);产品面接受用户任意 `images.tar.gz` 须先经 Profile 声明其成员 hash 集,
  未声明 → unknown → 阻断。

### A. `images.tar.gz` 成员清单(17,逐成员 SHA-256;锚定 CHG-2026-003 `member-inventory.json`,pinned archive `fc7637f3…5280`)

| idx | 成员 | size(bytes) | SHA-256 | 分类 |
| ---: | --- | ---: | --- | --- |
| 0 | `boot_linux.img` | 67108864 | `390c2cf2bf59f8bedc99a9622a1263410c6132341aece6a1b9c30ed5567a9523` | **mapped 分区镜像** |
| 1 | `chip_ckm.img` | 33554432 | `b60b62747679659c337eef737ea5064bbcea68b9fc219f62a076c06d05a6c81a` | **mapped 分区镜像** |
| 2 | `chip_prod.img` | 52428800 | `6d009c6b685f65f91bd77ceb201916f07dde8668fde4432ee534bb04e0b6cbad` | orphan 镜像(禁写) |
| 3 | `config.cfg` | 10399 | `4d06d303faff1d3e530a9d2c9bb22073427b0b498bb4bb438b5177897d86f33c` | 非分区元数据 |
| 4 | `daily_build.log` | 24496219 | `5823dd263cab3168dbd3ee098c5b5045b82b8393548b9da9f095de2883a2a0e9` | 非分区元数据 |
| 5 | `manifest_tag.xml` | 114913 | `fd458507b4bb63f372049a0bb9a2cd779af426e2d27de43134ace05e5884ff74` | 非分区元数据 |
| 6 | `MiniLoaderAll.bin` | 455104 | `1cdd418032195210f191445ed96e2da5ea83d2cfe880c912ebec635839d76542` | loader(正向不用;MaskRom 分支经 db) |
| 7 | `parameter.txt` | 788 | `35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048` | 分区表(正向 wlx over 既有表跳过 gpt) |
| 8 | `ramdisk.img` | 2385465 | `cc6f7c3d9568cbb3f810edd67ebe0015a04734605ca4f21c065ce94f88ec3b07` | **mapped 分区镜像** |
| 9 | `resource.img` | 5652480 | `161cf158f6f256e7794568b1307581e4656da1a8d8d3d2612da73195d3eda06e` | **mapped 分区镜像** |
| 10 | `sys_prod.img` | 52428800 | `8dfb72cfa61dc748f62f3d766214ab579c857f3b8a62e6890a8abc7ae0ac1062` | orphan 镜像(禁写) |
| 11 | `system.img` | 2147483648 | `aef65124a814fcce8345dbfbdf049aaa862bd76786d099095c6951b4561ba1bb` | **mapped 分区镜像** |
| 12 | `uboot.img` | 4194304 | `c1c801e45cbb92ee63e14df3dda5d819792e02295525bd53dbf750efb645916d` | **mapped 分区镜像** |
| 13 | `updater_binary` | 3248612 | `84659f9fd5a13b8293904f9ad7531ee9637523efffb90e74a49443f9f8ef5cd5` | 非分区元数据 |
| 14 | `updater.img` | 20692486 | `5f70d2f79cbcda267a20aff98c187ffdaac2ce1f693ae6f7dbdc2bec7b1c5494` | **mapped 分区镜像** |
| 15 | `userdata.img` | 1468006400 | `715e7998ebd47653a0ec2e062964224684762ab8686330c6b69b8d5f1f55886c` | **mapped 分区镜像** |
| 16 | `vendor.img` | 268431360 | `61e0c9adda4420417d88bcc1f4d725558b75e41046f528100a584c8dc466cd41` | **mapped 分区镜像** |

### B. `RockchipFlashProfile` — 允许分区/写序/地址(9 mapped;写序=低偏移在前,恢复演练 attempt#5 实证)

| 写序 | 分区名 | ← 镜像成员 | offset(sectors,FA-001 §2/PD-002) | offset(hex) | wl 回退 BeginSec |
| ---: | --- | --- | ---: | --- | ---: |
| 1 | `uboot` | `uboot.img` | 8192 | `0x00002000` | 8192 |
| 2 | `resource` | `resource.img` | 28672 | `0x00007000` | 28672 |
| 3 | `boot_linux` | `boot_linux.img` | 40960 | `0x0000A000` | 40960 |
| 4 | `ramdisk` | `ramdisk.img` | 237568 | `0x0003A000` | 237568 |
| 5 | `system` | `system.img` | 245760 | `0x0003C000` | 245760 |
| 6 | `vendor` | `vendor.img` | 4440064 | `0x0043C000` | 4440064 |
| 7 | `updater` | `updater.img` | 6742016 | `0x0066E000` | 6742016 |
| 8 | `chip_ckm` | `chip_ckm.img` | 6938624 | `0x0069E000` | 6938624 |
| 9 | `userdata` | `userdata.img` | 19955712 | `0x01308000` | 19955712 |
## 2. 禁写面(FA-001 §2;正向烧写零触碰)

- **orphan 镜像**:`chip_prod.img`/`sys_prod.img` — PD-002 对账 orphan,目标分区 unknown,
  alias 推断被禁,**不写**;
- **6 无成员分区**:`misc`/`bootctrl`/`sys-prod`/`chip-prod`/`eng_system`/`eng_chipset`
  — 无镜像依据,**不写**;两处扇区空洞(FA-001 §3)不写不探;
- **非分区成员**:`config.cfg`/`daily_build.log`/`manifest_tag.xml`/`updater_binary` —
  非分区物料,不入写序;`parameter.txt` = 分区表(正向路径 `wlx` over 既有表跳过 `gpt`,
  恢复演练实证板上 U-Boot 升级态拒 `gpt`);`MiniLoaderAll.bin` = loader(正向不用;仅
  Maskrom 分支经 `db`,当前设备直接进 Loader 态)。

## 3. Prerequisites(REQ-FLASH-002;destructive confirmation 前校验)

| prerequisite | required/optional | satisfied 判据 |
| --- | --- | --- |
| `loader` | required | `ld` = `0x2207:0x350a` + `Loader`(mode-gate;非该形态阻断) |
| `recoveryPath` | required | CHG-2026-016 验证的 Loader 态 `wlx` 恢复路线可用(RecoveryGuide 依据) |
| `unlocked` | required(仅 `userdata` erase) | 执行时显式强确认(`ERASE-USERDATA` 先例) |
| `stablePower` | optional | 操作者现场确认 |

任一 required 为 unsatisfied/unknown → destructive confirmation 前阻断(AC-FLASH-002-01)。

## 4. 命令面(design §0;正向烧写唯一授权面)

进态(§0 按键序列)→ mode-gate(`ld` 须 `0x350a`+`Loader`)→ `ppt` 前置(现行表 vs §1
分区集比对,满足即 `wlx` 解析前提就位)→ 逐分区 `sudo rkdeveloptool wlx <name> <image>`
(§1.B 写序;`wl <BeginSec>` 回退取上表扇区值,零手算)→ `rd` 复位 → postflight
`list targets -v` 重现 `Connected` + 语义校验(REQ-FLASH-012)。全部设备命令 `sudo`;
真机由人类维护者亲手执行,Agent 零设备命令。

## 5. RF-CONTRACT-001 documentReview 结论

| 检查项 | 结论 |
| --- | --- |
| 允许分区集 = PD-002 mapped 9 项 | PASS(§1.B 表;uboot…userdata) |
| orphan/无成员分区/扇区空洞禁写 | PASS(§2;chip_prod/sys_prod + 6 无成员 + 空洞) |
| 逐成员 SHA-256 锚定 member-inventory | PASS(§1.A 17 成员表,pinned `fc7637f3…5280`) |
| 写序低偏移在前 + 地址锚定 FA-001 §2/PD-002 | PASS(§1.B;offset 逐行取自 FA-001 §2 扇区列) |
| prerequisites 声明(loader/recoveryPath/unlocked) | PASS(§3) |
| 命令面 = design §0 封闭面,与恢复演练同构 | PASS(§4) |
| 与 design §1/§2 逐项一致、零 Core/spec 改写 | PASS |

**RF-CONTRACT-001 = PASS**(documentReview)。本 Profile 供阶段 A 真机正向烧写生成 exact
plan;真机 evidence(RF-REALFLASH-001)于设备窗口执行后补入 `run.md`。不构成 hardware
support、兼容性或 release 声明,直到真机验收合入 hardware matrix。
