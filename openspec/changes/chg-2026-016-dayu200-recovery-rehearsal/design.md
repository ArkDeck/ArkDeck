# Design — CHG-2026-016 DAYU200 恢复演练(封闭写命令面 = 唯一授权面)

> Status:candidate(随 change 生命周期)。本文件是演练执行的硬门:超出本文命令面的
> 任何设备命令一律禁止;写序、判定点与中止准则对操作者有约束力。全部步骤由人类
> 维护者亲手执行;Agent 零设备命令,只做脚本起草、事后核验与 evidence 起草
> (M0B/PD-002 先例)。
>
> **r2 修正(2026-07-20,基于 RH-001 真机 blocked-attempt #173 + Oniro/HiHope 官方
> 文档)**:r1 假定按键即进 RockUSB Maskrom,真机实测得 `2207:5000`(updater-hdc),
> rkdeveloptool RockUSB 不通。r2 修正=① §0 精确进态序列(权威原文)+ mode-gate;
> ② 全部 rkdeveloptool 设备命令加 `sudo`(macOS USB 接口 claim 需特权,Radxa/社区
> 一致,r1 脚本漏);③ 写前硬门:`ld` 必须显 `0x350a`(RockUSB),显 `0x5000`
> (updater-hdc)即 STOP 重进。恢复路线仍为 rkdeveloptool RockUSB,未转 hdc/flashd。
>
> **r3 修正(2026-07-21,基于 RH-001 blocked-attempt #2/#213 真机事实)**:r2 进态
> 序列已实证有效——首次达成 `0x350a`,但设备**直接落在 Loader 态**(板上 miniloader
> 已运行,`ld` 标签 `Loader`,三次读取稳定),而非 r2 假设的裸 Maskrom;该态下 W1
> `db` 按协议被拒(`The device does not support this operation!`,两次,零写入)。
> r3 修正仅两点:① **W1 条件化**——写序开始前 `ld` 显 `0x350a`+`Loader` 时,W1 的
> 判定点「设备转入可写态(ld 显示 Loader)」视为已满足,`db` 跳过并如实记录;显
> `0x350a`+`Maskrom` 时 W1 `db` 仍必须执行,判定点不变。② **W2 主路径确认**——
> attempt #2 抢救读回 `ppt` 表头 `Partition Info(GPT)` 且 15/15 精确 match FA-001 §2,
> GPT 分支实锤,W2 以 `gpt parameter.txt` 为确认主路径(`prm` 替代分支保留不删)。
> 其余命令面、写序、判定点、§5 中止准则零变更。

## 0. 进态序列与 mode-gate(r2 新增;权威原文,硬门)

**精确进态序列**(Oniro/HiHope HH-SCDAYU200 官方文档,逐字):
"Press and hold `VOL/RECOVERY` then `RESET` buttons. Release `RESET` button."
即:① 按住 `VOL/RECOVERY` 不放 → ② 保持按住,按一下 `RESET` → ③ 松开 `RESET`,
`VOL/RECOVERY` 继续按住约 2-3 秒再松开。

**mode-gate(写设备前的绝对前提)**:进态后 `sudo rkdeveloptool ld` 必须输出
`Vid=0x2207,Pid=0x350a`(RockUSB download gadget,权威文档确认 = 可烧写态)。
- 显 `0x350a` → 允许进入 §2 写序;
- 显 `0x5000`(updater-hdc,= 进了 OH recovery/updater 而非 RockUSB)或无设备 →
  **STOP,断电重进 §0 序列**,不得对 `0x5000` 设备尝试任何写命令(rkdeveloptool
  RockUSB 无法驱动,r1 已实证);
- 连续 2 次进不到 `0x350a` → 按 §5 中止,记录并结束窗口。

## 1. 物料与工具身份(执行前逐项复核,漂移即停)

| 项 | Pinned 身份 | 来源 |
| --- | --- | --- |
| pinned 归档 | size `732948803`、SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280` | CHG-2026-003 archived identity |
| 归档成员(解包后) | 17/17 逐文件全量 SHA-256 vs archived `member-inventory.json`(TASK-RR-001 已验一轮,执行前对解包物料复核) | CHG-2026-003 inventory;TASK-RR-001 |
| `rkdeveloptool` | SHA-256 `038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611`,`-v` = `ver 1.32`,upstream commit `304f0737…` 构建 | TASK-RR-001 evidence |
| 分区地址基线 | FA-001 §2 表(15 行,逐行锚定 TASK-PD-002 `partition-mapping.json` `965e3bf3…`) | CHG-2026-012 evidence |
| 解包目录 | 仓库外受控目录(`0700`,先例 `~/dayu200-rehearsal/`),解包仅限本演练物料 | RR-001 先例 |

## 2. 封闭命令面(白名单;argv 逐字面)

> **r2:全部 `rkdeveloptool` 设备命令以 `sudo` 前缀执行**(macOS USB 接口 claim 需
> root;`ld` 枚举可无 sudo 但为一致性统一加)。argv 主体不变。

**读类(只读,可多次):**

| 命令 | 用途 | 前提 |
| --- | --- | --- |
| `rkdeveloptool -v` | 版本复核(须 `ver 1.32`) | host-only |
| `rkdeveloptool ld` | 设备模式判别(Maskrom/Loader/无设备) | host-only;设备任意态 |
| `rkdeveloptool ppt` | 设备侧分区表读回(观察搭载 §4) | 设备已处 Loader 态 |
| `system_profiler SPUSBDataType`(或等价只读 USB 枚举) | USB PID 观察(观察搭载 §4) | host-only |
| `scripts/m0b_capture/capture.py --commands hdc-list-targets,hdc-list-targets-verbose` | 复位后正常启动 postcheck(只读,既有白名单) | 设备回正常系统态 |

**写类(每条一次为限,重试规则见 §5;全部【写设备】):**

| 序 | 命令 | 判定点 |
| ---: | --- | --- |
| W1 | `rkdeveloptool db MiniLoaderAll.bin` | 报成功且设备转入可写态(`ld` 显示 Loader)。**r3 条件化:写序开始前 `ld` 已显 `0x350a`+`Loader` 时判定点视为已满足,`db` 跳过并如实记录;`0x350a`+`Maskrom` 时必须执行** |
| W2 | `rkdeveloptool gpt parameter.txt` | 报成功(设备侧分区表就位;为 W3 `wlx` 建立解析前提)。若工具/设备形态要求 `prm`,以 `rkdeveloptool prm parameter.txt` 替代并如实记录——两者仅取其一 |
| W3 | 逐分区 `rkdeveloptool wlx <PartitionName> <image>`(优先路径) | 每分区报成功;分区名↔镜像对取 §3 写序表 |
| W3' | 回退路径(仅当 `wlx` 对某分区报 `No found partition` 或等价失败):`rkdeveloptool wl <BeginSec> <image>`,`<BeginSec>` **逐值取自 FA-001 §2 的 PD-002 扇区列,零现场手算**;使用回退即如实记录原因 | 报成功 |
| W4 | `rkdeveloptool rd`(或手动 RESET) | 设备正常启动进系统;postcheck `list targets -v` 显示 `Connected` |

## 3. 写序(预案 §4 + PD-002 对账约束)

仅写 PD-002 对账 **mapped** 的分区(exact stem,9 项),按低偏移在前:

1. `uboot` ← `uboot.img`
2. `resource` ← `resource.img`
3. `boot_linux` ← `boot_linux.img`
4. `ramdisk` ← `ramdisk.img`
5. `system` ← `system.img`
6. `vendor` ← `vendor.img`
7. `updater` ← `updater.img`
8. `chip_ckm` ← `chip_ckm.img`
9. `userdata` ← `userdata.img`——**仅在现场显式确认接受清数据后写**;跳过则如实记录

**明确不写:** `chip_prod.img`/`sys_prod.img`(PD-002 orphan,目标分区 unknown,
alias 推断被禁——FA-001 §2);6 个无成员分区(`misc`/`bootctrl`/`sys-prod`/
`chip-prod`/`eng_system`/`eng_chipset`,无镜像依据);`MiniLoaderAll.bin` 不入分区
写序(经 W1 `db` 注入);`updater_binary`/`config.cfg`/构建元数据(非分区物料)。
两处扇区空洞(FA-001 §3)不写不探,保持原状。

## 4. 观察搭载(同窗口免费只读;DEC-002 第二阶段输入)

- **模式判别观察**:进 Maskrom 前后与 `db` 后各执行 `ld` + USB 枚举一次,记录输出
  形态与 USB VID:PID(CHG-2026-011 待确证项:RK3568 PID 是否 `0x350a`、Maskrom/
  Loader 判别字样)——只记录,不据此改流程。
- **分区表读回比对**:Loader 态下 `ppt` 输出逐行与 FA-001 §2 基线(PD-002 锚定)
  比对,逐行记 match/mismatch/absent/extra;W2 之前若可读则先读一次(设备原表),
  W2 之后再读一次(新表)。比对只入 evidence,不改写基线;差异不现场解释,标
  【待后续分析】。

## 5. 中止与重试(预案 §5 原文要点,对操作者有约束力)

- 同一步骤连续 **2 次**失败且已排除线材/hash 因素 → 中止;
- 出现预案未覆盖的报错形态 / 未描述的 USB 枚举状态 → 中止;
- 任何步骤前发现本地物料 hash 与清单不符 → 中止;
- 中止即停手、记录现场、结束窗口;修订走独立 revision PR 再约窗口;
- `db` 失败常见因(S3):物料不完整、USB 线/口不稳——复核 hash 与线材后重试,
  **最多重试 2 次**。

## 6. 记录与隐私

- 逐命令记录 argv/完整输出/结果(TASK-RR-001 模板);操作脚本由 Agent 事前起草
  (pinned-hash 门内建、transcript 自动落盘、流内容按需回显——rkdeveloptool 输出
  不含序列号之外的敏感面,序列号出现处按 M0B 脱敏惯例处理);
- 序列号字节仅入 `hardware-evidence.json` device identity 字段;repo-facing
  transcript/run.md 用占位符;raw 全量留仓库外受控目录;
- 版本后果如实记录:演练完成后设备运行 pinned 7.0.0.33 build(参考态)。
