# DAYU200(RK3568)烧写地址映射事实清单(文档研究;未真机确证)

> 本文件不构成兼容性/支持声明,不解除 `GAP-DAYU200-FLASH-ADDRESSES` 或任何其他
> gap,不改变 DEC-002 状态,不是执行授权。所有 §2 数值行的唯一权威来源是 **合入
> main 的 TASK-PD-002 fresh signed-broker platform mapping evidence**;本文件零自行
> 推导地址、零从镜像成员字节推导地址。任何仅 S3 支撑或属推断的结论标【待真机确证】;
> 任何写设备/模式切换候选标【第二阶段·写设备·RECOVERY 先行】。

## 0. 权威锚点(数值来源与边界)

- **地址数值唯一权威锚点**:TASK-PD-002 同一次 fresh signed-broker platform run 的
  `partition-mapping.json`
  (SHA-256 `965e3bf3bd926c76a646a1bc02ce1f3f4ba855b4e09a7e61b48872195c131347`)与
  `member-reconciliation.json`
  (SHA-256 `55c3515667ff6b1bd8cc922721b0c46a649eee9203a6f8a40c23397765b2d4ad`),
  路径 `openspec/changes/chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-2026-07-20-r5/`。
- 该 evidence 绑定合入 main 的 TASK-PD-001 implementation identity(r4 `110071c1`、
  r5 `33aff46`)。TASK-PD-001 headless contract receipt 不作数值锚点。
- **non-authoritative 边界随锚点继承**:PD-002 mapping 仅对 pinned archive identity
  (SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`、
  732948803 bytes)成立;其解码的 `parameter.txt` 成员 SHA-256
  `35464e3f0b883a8a043dd45ae7ab2342c86b7aa27f24aa1e5a0ccfb6f442d048`。真机上的实际
  分区表可能因 build/GPT 转换而不同,须真机确证。
- PD-002 记录的语法信封:`CMDLINE:mtdparts=<device>:<partition>[,...]`,device
  = `rk29xxnand`,partition = `(<hex-size>|-)@<hex-offset>(<name>[:<attribute>])`,
  `numericUnit = sourceEncodedUnitUnconverted`(即下表 encoded/decimal 为源编码单位,
  未经单位换算)。

## 1. 各 host 工具的寻址语义(S2;工具上下文,非地址权威)

**单位约定(S2):** Rockchip 开源分区体系中,`parameter`/mtdparts 的 `size@offset`
数值单位为 **扇区(sector)**,扇区大小 **512 字节**;GPT 存于 `LBA0~LBA63`
(primary GPT LBA1–63,secondary GPT 于末端)。故任一分区的字节地址 = 扇区值 × 512
(见 §2 派生列)。【S2:Rockchip opensource wiki_Partitions】

| 工具 · 命令 | 寻址方式 | 前提 | 说明(S2 引用) |
| --- | --- | --- | --- |
| `rkdeveloptool wl <BeginSec> <File>` | **按 LBA 扇区偏移**写入,`BeginSec` 为起始扇区 | 设备须已处 Maskrom/Loader 态(经 `db`/`ul`)且 loader 已下载 | usage `WriteLBA: wl <BeginSec> <File>`;`rkdeveloptool ld` 例 `wl 0 <image>` 从扇区 0 起写。【S2:rkdeveloptool main.cpp usage;Radxa docs】 |
| `rkdeveloptool wlx <PartitionName> <File>` | **按分区名**写入,地址由设备侧分区表解析 | **设备侧须已存在分区表**:handler 先查 GPT、再回退 parameter 表;查不到报 `No found %s partition` | usage `WriteLBA: wlx <PartitionName> <File>`;源码 wlx handler 先 GPT 后 parameter 回退。【S2:rkdeveloptool main.cpp:2287-2333】 |
| `rkdeveloptool gpt <gpt partition table>` | 写 **GPT 分区表**(落 LBA0~63 区) | Maskrom/Loader 态 | usage `WriteGPT: gpt <gpt partition table>`;wiki 示例 `db rkxx_loader; gpt parameter_gpt.txt`。【S2:main.cpp;wiki_Partitions】 |
| `rkdeveloptool prm <parameter>` | 写 **parameter(mtdparts)分区表** | Maskrom/Loader 态 | usage `WriteParameter: prm <parameter>`。【S2:main.cpp】 |
| `rkdeveloptool ppt` | 打印设备侧分区表(读) | 设备须已处 Maskrom/Loader 态 | usage `PrintPartition: ppt`。【S2:main.cpp】 |
| `rkdeveloptool db <Loader>` / `ul <Loader>` | 下载/升级 **loader**;非扇区寻址,写入 loader/IDB 区 | Maskrom 态(`db`) | usage `DownloadBoot: db <Loader>` / `UpgradeLoader: ul <Loader>`。loader 落点为 IDB/loader 区,**非 parameter 扇区寻址**(见 §2 未覆盖项)。【S2:main.cpp;Radxa docs】 |
| `rkdeveloptool rl <BeginSec> <SectorLen> <File>` | 按 LBA 扇区读 | Maskrom/Loader 态 | usage `ReadLBA: rl <BeginSec> <SectorLen> <File>`。【S2:main.cpp】 |
| `rkdeveloptool ef` | 擦除 flash | Maskrom/Loader 态 | usage `EraseFlash: ef`。【S2:main.cpp】 |
| `upgrade_tool di -<slot> <File>` / `di -p parameter` | **按 slot/分区标志**下载镜像;`di -p` 写 parameter | 设备须处 maskrom rockusb 态,**loader(`ul`)须先行** | 例 `ul <loader>` → `di -p parameter.txt` → `di -u uboot.img` → `di -k kernel.img` …;地址来自 parameter/loader,命令行不直接给字节地址。【S2:Rockchip wiki_Upgradetool;Firefly wiki】 |
| RKDevTool / AndroidTool(`config.cfg`) | GUI 地址列由 `config.cfg`/parameter 填充;loader 优先、按表顺序写 | Windows;设备处 Maskrom/Loader 态 | DAYU200 官方烧录路径仅此(Windows RockUSB),CHG-011 §3 已记;GUI 地址列填充与写序细节 **无官方逐字文档**。【S2:CHG-011 flash-protocol-facts §3;S3:社区教程】 |

**关键寻址结论(S2):**
- `wl` 直接吃**扇区地址**(§2 表左列即其输入语义域);`wlx`/`upgrade_tool di`/GUI 则
  **不吃字节地址**,而是靠**设备侧已存在的分区表**(GPT 或 parameter)按名解析——故
  这些路径的前提是先 `gpt`/`prm`/`di -p` 把 §2 的地址表写进设备。
- loader(`MiniLoaderAll.bin`)经 `db`/`ul` 写入,**不在 parameter 扇区地址域内**。

## 2. 每分区目标地址映射表(数值行 = PD-002 锚定;字节列 = S2 派生)

下表 **15 行分区**逐行取自 PD-002 `partition-mapping.json` 的 `partitions[]`
(index / name / offset.encoded / offset.value / size.encoded / size.value /
attribute / grammarBranch);**offset(sectors)与 size(sectors)列为 PD-002 源编码
权威值,零改写**。`byte` 列为 **S2 派生**(扇区 × 512,§1 单位约定),**非 PD-002
数值**,仅作语义换算参考。`image?` 列取自 PD-002 `member-reconciliation.json` 的
mapped/orphan 判定(exact case-sensitive stem;alias 推断被禁)。

| idx | 分区名 | offset 扇区(PD-002) | offset byte(S2 派生 ×512) | size 扇区(PD-002) | 分支 | 属性 | 对应镜像成员(PD-002 对账) |
| ---: | --- | --- | ---: | --- | --- | --- | --- |
| 0 | uboot | `0x00002000`=8192 | 4194304 | `0x00002000`=8192 | fixed | — | `uboot.img`(mapped) |
| 1 | misc | `0x00004000`=16384 | 8388608 | `0x00002000`=8192 | fixed | — | 无(orphan partition) |
| 2 | bootctrl | `0x00006000`=24576 | 12582912 | `0x00001000`=4096 | fixed | — | 无(orphan partition) |
| 3 | resource | `0x00007000`=28672 | 14680064 | `0x00003000`=12288 | fixed | — | `resource.img`(mapped) |
| 4 | boot_linux | `0x0000A000`=40960 | 20971520 | `0x00030000`=196608 | fixedBootable | bootable | `boot_linux.img`(mapped) |
| 5 | ramdisk | `0x0003A000`=237568 | 121634816 | `0x00002000`=8192 | fixed | — | `ramdisk.img`(mapped) |
| 6 | system | `0x0003C000`=245760 | 125829120 | `0x00400000`=4194304 | fixed | — | `system.img`(mapped) |
| 7 | vendor | `0x0043C000`=4440064 | 2273312768 | `0x00200000`=2097152 | fixed | — | `vendor.img`(mapped) |
| 8 | sys-prod | `0x0063C000`=6537216 | 3347054592 | `0x00019000`=102400 | fixed | — | 无(orphan partition;见 §3 orphan image `sys_prod.img`) |
| 9 | chip-prod | `0x00655000`=6639616 | 3399483392 | `0x00019000`=102400 | fixed | — | 无(orphan partition;见 §3 orphan image `chip_prod.img`) |
| 10 | updater | `0x0066E000`=6742016 | 3451912192 | `0x00010000`=65536 | fixed | — | `updater.img`(mapped) |
| 11 | eng_system | `0x0067E000`=6807552 | 3485466624 | `0x00008000`=32768 | fixed | — | 无(orphan partition) |
| 12 | eng_chipset | `0x00686000`=6840320 | 3502243840 | `0x00008000`=32768 | fixed | — | 无(orphan partition) |
| 13 | chip_ckm | `0x0069E000`=6938624 | 3552575488 | `0x00020000`=131072 | fixed | — | `chip_ckm.img`(mapped) |
| 14 | userdata | `0x01308000`=19955712 | 10217324544 | `-`(remainder) | remainderGrow | grow | `userdata.img`(mapped) |

**PD-002 未覆盖 / 显式 unknown 的目标地址(不得推导):**
- **loader(`MiniLoaderAll.bin`)目标地址 = unknown**:非 parameter 分区成员
  (PD-002 对账 role=`loaderBinary`、status=`notApplicable`);经 `db`/`ul` 写入
  loader/IDB 区,parameter 扇区地址域**不含**其地址。IDB 具体落点无 PD-002 锚点。
  【待真机确证 / 待 loader 专项文档】
- **orphan 镜像成员的目标分区与地址 = unknown**:`chip_prod.img`、`sys_prod.img` 在
  PD-002 对账中为 orphan(无 exact case-sensitive 分区名匹配;alias 推断被禁)。虽然
  存在 name 形近的分区 `chip-prod`/`sys-prod`(含其扇区地址),但**把带下划线的镜像名
  映射到带连字符的分区名属 alias 推断,PD-002 明文禁止**,故这两个镜像的烧写目标地址
  **不予认定为 unknown**,须真机分区表/官方打包脚本确证。【待真机确证】
- **6 个 orphan 分区**(`misc`/`bootctrl`/`sys-prod`/`chip-prod`/`eng_system`/
  `eng_chipset`):有 parameter 地址(上表)但**本镜像包内无对应 .img 成员**——其地址已
  知(PD-002),但"用什么内容烧、是否需烧"无镜像依据。【事实:无成员;是否运行时生成
  待真机确证】
- **GPT 实际布局 = unknown(与 parameter 语义并存的歧义)**:§1 记 Rockchip 通用 GPT 于
  LBA0~63;而本镜像 parameter 采用 legacy `rk29xxnand` mtdparts 信封,首分区 uboot 起于
  扇区 8192(前 8192 扇区为 loader/IDB/表区)。真机是以 GPT 还是 parameter 表寻址、
  两者是否一致,**PD-002 不覆盖**,须真机 `ppt`/GPT dump 确证。【待真机确证】

## 3. 对账方法设计(against parameter.txt / GPT 语义)

**目标:** 在**不触碰设备、不推导地址**的前提下,给出"镜像成员 ↔ 分区地址"的可复核
对账规则,供第二阶段真机验证复用。

- **权威对账源(PD-002 已实现,只读引用):** `member-reconciliation.json` 的
  `mappingRule` = "case-sensitive filename stem == decoded partition name;no alias,
  punctuation normalization, similarity matching or address inference"。计数:
  imageMemberCount 11 · inventoryMemberCount 17 · mappedImageCount 9 ·
  orphanImageCount 2 · orphanPartitionCount 6。
- **§2 地址表 ↔ parameter.txt 语义对账:** §2 每行 offset/size 直接是 parameter mtdparts
  的 `size@offset`(扇区);相邻分区的连续性不变式 `offset[i] + size[i] == offset[i+1]`
  (fixed 分支)可由 §2 扇区列**纯算术自检**(不引入新地址)。**实际结果(如实):**
  连续性成立于 idx 0→12(`uboot`→`misc`→…→`eng_chipset`,各 `end==next.offset`,
  例 uboot 8192+8192=16384=misc.offset);但存在**两处空洞**——`eng_chipset`
  末(6840320+32768=6873088)到 `chip_ckm` 起(6938624)空 **65536 扇区**,`chip_ckm`
  末(6938624+131072=7069696)到 `userdata` 起(19955712)空 **12886016 扇区**;
  `userdata` 为 remainderGrow(无固定 size,占余量)。这两处空洞是 PD-002 表的**既有
  事实**(reserved/未分配扇区区间),**不得抹平或推测其用途**。此自检**只验证 PD-002 表
  内部一致性与空洞位置**,不产生新地址、不替代真机确证;空洞的实际含义【待真机确证】。
- **§2 地址表 ↔ GPT 语义对账(设计,待真机):** 若真机以 GPT 寻址,则 `wlx <name>` /
  `upgrade_tool di` 的落点应等于 GPT 中该 name 的 first-LBA;真机 `ppt` 或 GPT dump 的
  per-partition first-LBA 应逐行等于 §2 offset 扇区列。**该比对是第二阶段真机步骤**,
  本文档只给出比对方法与预期不变式,不执行。
- **镜像 ↔ 分区对账的三类出口(承 PD-002):** ①mapped(exact stem,9 项)→ 目标地址 =
  §2 同名行;②orphan image(`chip_prod.img`/`sys_prod.img`)→ 目标地址 unknown
  (alias 禁),须真机/打包脚本确证;③orphan partition(6 个)→ 地址已知无镜像。
- **loader 对账:** `MiniLoaderAll.bin` 不入扇区对账,走 `db`/`ul`;其与 parameter 表的
  关系(前 8192 扇区留空区)属 §2 unknown 项,待真机确证。

## 4. 只读观察面草案(设计;非执行授权)

> 本草案的**执行**与任何**采集白名单扩展**均属后续独立 change,本文档不构成执行授权。
> 承 CHG-011 §4 与 route-b-plan 全局 RECOVERY 先行硬序。

### 4.1 第一阶段候选(逐条【只读】+ 前提)

| 候选 | 前提 | 分类 | 观察价值(地址/分区表相关) |
| --- | --- | --- | --- |
| `rkdeveloptool -v` / `--help` | host-only,无设备 | 【只读】 | 版本 ≥1.32 核对;usage 中 `wl/wlx/gpt/prm/ppt` 语义即 §1 锚点(host 侧文本,不触设备) |
| 阅读本镜像内 `parameter.txt`(仓库外 raw / PD-002 已解码) | 无设备(PD-002 已完成) | 【只读】 | §2 地址表来源;不重复解码,只读引用 PD-002 |
| 阅读 `config.cfg`(RKDevTool 配置,镜像成员) | 无设备 | 【只读】 | PD-002 对账中 role=`packageMetadata`;可核对 GUI 地址列来源(待与 §2 比对,属文档研究) |

### 4.2 第二阶段(模式切换 / 写设备 → 全部【第二阶段·写设备·RECOVERY 先行】)

以下候选**均涉及模式切换或写设备**,一律【第二阶段·写设备·RECOVERY 先行】,第一阶段
不执行;仅在 `GAP-DAYU200-RECOVERY-PATH` 关闭后另行独立立项/approve:

- 使设备进入 Maskrom/Loader 态的任何操作(物理按键序列、`hdc` 触发、`upgrade_tool`/
  RKDevTool 进态);
- `rkdeveloptool ld`(**无设备时 host-only 只读**,但**若设备已处 Maskrom/Loader 态则读其模式**——使设备进入该态属第二阶段;故连线态下归第二阶段);
- `rkdeveloptool ppt`/`rl`/`rid`/`rfi`/`rci`/`rcb`(读类,但**前提是设备已处
  Maskrom/Loader 态** → 进态即第二阶段);
- 任何写:`db`/`ul`/`wl`/`wlx`/`gpt`/`prm`/`ef`/`rd`、`upgrade_tool di -*`/`ul`/`ef`、
  RKDevTool 写序——**写设备,RECOVERY 先行,本文档零授权**。

**§2 地址表在第二阶段的唯一合法用途(设计,非授权):** 作为真机 `ppt`/GPT dump 的
**预期比对基线**(§3 GPT 语义对账),用于**验证**读回的分区表是否与镜像 parameter 一致;
**不作为写地址来源**——写地址须来自设备侧已写入的分区表(`wlx`/`di` 按名解析),或经
RECOVERY 先行审定后的显式授权。

## 5. 来源引用(S2/S3 分级)

- **S2(权威/一手):**
  - PD-002 fresh platform mapping/reconciliation evidence(仓库内,§0 hash 锚点)——
    §2 全部地址数值、§3 对账计数与规则的唯一权威来源;
  - rkdeveloptool 上游源码 usage/handler:`main.cpp` usage 文本与 `wlx` handler
    (GPT→parameter 回退、`No found %s partition`),
    <https://github.com/rockchip-linux/rkdeveloptool>(radxa fork 同版本);
  - Rockchip 开源 wiki `wiki_Partitions`(mtdparts 扇区语义、GPT LBA0~63、`db`+`gpt`
    示例),<https://opensource.rock-chips.com/wiki_Partitions>;
  - Rockchip 开源 wiki `wiki_Upgradetool`(`ul`→`di -p`→`di -*` 写序、maskrom rockusb
    前提),<http://opensource.rock-chips.com/wiki_Upgradetool>;
  - Radxa RK3568 `rkdeveloptool` 文档(`db`/`wl 0 <image>`/`ld` 例、Maskrom 前提、
    macOS 构建),<https://docs.radxa.com/en/som/cm/cm3/low-level-dev/rkdeveloptool>;
  - CHG-2026-011 archived `flash-protocol-facts.md`
    (SHA-256 `a012c16a5011918a967e1fa21806afb20613e3dfd54078d5beebc599abb000ba`)——§1
    工具×通道×macOS 可用性与 DAYU200 官方仅 Windows RockUSB 的缺席结论。
- **S3(社区/推断,标【待真机确证】):**
  - Firefly wiki upgrade_tool 烧录序列(与 Rockchip wiki 相容,细节板级差异)——
    <https://wiki.t-firefly.com/en/AIO-3128C/Flash_Image.html>;
  - 字节列(扇区×512)为 S2 单位语义的**算术派生**,非 PD-002 数值,标注在 §2 列头;
  - RKDevTool `config.cfg` GUI 地址列填充与写序的逐字细节无官方文档(S3 社区教程),
    【待真机确证】;
  - 真机是否以 GPT 或 parameter 表寻址、GPT 实际 per-partition first-LBA、orphan 镜像
    (`chip_prod.img`/`sys_prod.img`)的真实目标分区、loader IDB 落点、6 个 orphan 分区
    是否运行时生成——均【待真机确证】。
