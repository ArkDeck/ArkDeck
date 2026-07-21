# CHG-2026-020 Design:DAYU200 Rockchip RockUSB Flash Provider

> Status:candidate(随 proposal r1;approve 前不构成实现授权)
> Core baseline:CORE-2.0.0(零 Core 变更;认领 flashing REQ-FLASH-* 的 DAYU200 面)

## 0. 命令面(封闭;正向烧写唯一授权面,恢复演练 crib 的正向产品化)

正向全量烧写路径,与恢复实证(CHG-016 attempt #5)同构:

| 序 | 动作 | 判定点 |
| ---: | --- | --- |
| 进态 | §0 精确按键序列 → `ld` 必须 `0x2207:0x350a` + `Loader` | 非该形态即 STOP(mode-gate) |
| 前置 | `ppt` 读现行分区表 vs Profile 声明的分区集逐行比对 | 表匹配 = `wlx` 解析前提就位(satisfied-by-existing-state);不匹配则 `gpt parameter.txt` 写表(如板上升级态拒则须 MaskRom,另立 revision) |
| 写 | 逐分区 `wlx <PartitionName> <image>`(按 Profile 写序;`wl <BeginSec>` 回退取 FA-001 §2 扇区值,零手算) | 每分区 `Write LBA from file (100%)`/exit 0 |
| 复位 | `rd`(或手动 RESET) | `Reset Device OK.` |
| postflight | `list targets -v` 重现 `Connected` + 语义校验(REQ-FLASH-012) | 未回连 = 非 succeeded,进 RecoveryGuide(REQ-FLASH-013) |

`db`/`gpt`/`ul` 等 MaskRom/miniloader 阶段命令不在正向主路径(板上 U-Boot 升级态不实现;
#220/#218 实证)。全部 rkdeveloptool 设备命令 `sudo`(macOS USB claim)。

## 1. `images.tar.gz` 输入契约

- 顶层 = 一个 gzip tar,成员 = 分区镜像(`.img`)+ 分区表(`parameter.txt`)+ 可选
  loader(`MiniLoaderAll.bin`,仅 MaskRom 分支用)+ 构建元数据;
- 契约声明(随 Profile):成员清单、逐成员 SHA-256、`分区名 ↔ 镜像` 映射(锚定 PD-002
  `member-reconciliation.json`)、大小范围、写序、允许分区集、orphan/无成员分区显式不写;
- validate(REQ-FLASH-003):解包后逐成员 SHA-256 vs 契约,任一不符 → 阻断 execute 与
  planned-success;镜像来源 hash 未在 Profile 声明 → unknown → 阻断。
- 阶段 A 首验用一个**已知 pinned** `images.tar.gz`(CHG-003 archived 的 17 成员即天然
  fixture:`fc7637f3…5280`);产品面接受用户任意 tar.gz 须先经 Profile 声明其 hash 集。

## 2. `RockchipFlashProfile`(REQ-FLASH-001/002/003)

- 允许分区集 = PD-002 mapped 9 项(uboot/resource/boot_linux/ramdisk/system/vendor/
  updater/chip_ckm/userdata);orphan(chip_prod/sys_prod)与 6 无成员分区、扇区空洞
  **禁止写**(FA-001 §2);
- prerequisites(REQ-FLASH-002):`loader`(0x350a Loader,required)、`recoveryPath`
  (required,= CHG-016 验证的恢复路径)、`unlocked`(userdata erase 时 required)、
  `stablePower`(optional);unsatisfied/unknown 在 destructive confirmation 前阻断;
- 写序 = 低偏移在前(design §0 表);每分区 hash/大小/目标名声明。

## 3. Provider 类型(REQ-FLASH-001,阶段 B)

`RockchipRockUSBFlashProvider`:
- `probe` → 设备模式(`ld`)+ Provider 适用性(RockUSB 0x350a);不适用则 preflight 阻断
  (不尝试"相似命令",AC-FLASH-001-01);
- `validate` → `images.tar.gz` 契约 + Profile hash/分区/顺序校验;
- `makePlan` → typed `FlashStep` 序列(进态→ppt 前置→逐分区 wlx→rd→postflight),
  `execute`/`planOnly`/`simulated` 模式标识(REQ-FLASH-004);分区写 Step 标
  `criticalNonInterruptible`(REQ-FLASH-008);
- `recover` → RecoveryGuide = 恢复演练 Loader wlx 路径(REQ-FLASH-013,honest 状态)。

## 4. REQ-FLASH-015 Agent/CI 边界(与恢复演练同构,核心安全设计)

- Agent/CI 执行凭据只允许 contract/fake/simulated/plan-only 分支;真实 binding + 含
  `flashPartition` 的 execute plan 并存 → destructive dispatch 数 0、Job `policyBlocked`、
  生成受控人工 handoff(AC-FLASH-015-01);
- 真实设备 flash/erase 由**人类操作者亲自执行**;执行器在首个真实 Step 前校验人工确认
  与待执行计划精确一致(target binding/固件/transport/HDC/Provider/Step 集合),任一
  不符或缺失 → 真实 dispatch 0、run 不产生 verified realHardware evidence(AC-FLASH-015-02);
- evidence 记录 operator、物理目标确认、执行时间、恢复路径;事后 run/hardware evidence/
  聊天确认不能追认授权。
- **落地形态**:阶段 A 完全走人工(维护者亲手 crib,Agent 零设备命令),与 CHG-016 相同;
  阶段 B 的 Swift 执行器实现上述 gate,产品 `arkdeck flash` = 生成 exact plan → 人工确认
  → 人类执行,App/Agent 不直接 dispatch destructive Step。

## 5. 分期与 Task 边界

- **TASK-RF-001(阶段 A,device-gated)**:契约 + Profile 定义 + 人工真机正向烧写 evidence
  + hardware matrix supported 行。前置:approve + readiness + 具名设备窗口 + 书面风险确认。
- **TASK-RF-002(阶段 B,Swift)**:`RockchipRockUSBFlashProvider` + typed FlashStep +
  确认/critical/postflight/recovery/Agent-gate + `arkdeck flash` CLI 接入。前置:approve
  + readiness + TASK-RF-001 的 Profile/契约/命令面 evidence。
- 两 task 各自独立 readiness/实现/done PR;proposal + design(本 PR)不实现、不执行真机。

## 6. 波及与边界

- Core:零变更(认领 REQ-FLASH-* 的 DAYU200 realHardware/contract 面);
- DEC-002:本 change 建议正向决策 = Rockchip RockUSB Provider;DEC-002 整体 resolve 由
  维护者在阶段 A realHardware 验收后判定;
- hardware matrix:阶段 A 验收前无任何 supported 行;simulated 永不冒充(REQ-FLASH-014);
- 恢复接入:直接复用 CHG-016 验证的 Loader wlx 恢复路径,不重造。
