---
id: CHG-2026-020-dayu200-real-flash
revision: 1
status: proposed
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# DAYU200 正向烧写:Rockchip RockUSB Flash Provider 与 `arkdeck flash`

## Why

用户目标是 `arkdeck flash images.tar.gz` 真机烧写 DAYU200。前置已就位:

- **命令面已真机实证**:恢复演练(CHG-2026-016,verified)于 attempt #5(#220)证明
  DAYU200 macOS 写设备通道 = **rkdeveloptool RockUSB Loader 态 `wlx`**(over 既有分区
  表),九分区全写入成功、`rd` 复位后设备重启进系统、postcheck `Connected`;并真机
  纠正了 #173 的 hdc/flashd 推测(#223)。
- **分区/地址事实已建立**:PD-002(`partition-mapping.json`)、FA-001(`flash-address-facts.md`)
  给出 15 分区语义与地址,恢复演练 `ppt` GPT dump 五窗口 15/15 逐行确证。
- **Core 契约已就绪**:`REQ-FLASH-001…015`(CORE-2.0.0)定义 typed Provider、destructive
  确认、critical write、postflight、recovery、hardware evidence 与 Agent/CI 边界;M1-008
  已交付 `SimulatedFlashProvider`(AC-FLASH-006-01)。
- **DEC-002**(first flashing protocol)保持 open,其 `GAP-DAYU200-RECOVERY-PATH` 已关闭、
  其余三 gap 经真机确证推进;正向全量烧写的 Provider 选择待本 change 立项。

本 change 是 DEC-002 resolution vehicle 指定的 **DAYU200 real-flash 实现载体**:把恢复
实证的命令面产品化为一个 typed Rockchip Flash Provider,并接入 `arkdeck flash` CLI。

## What changes

### DEC-002 正向决策建议(经维护者 review 确立)

DAYU200 正向烧写 Provider = **Rockchip RockUSB Provider**(rkdeveloptool ≥1.32,Loader
态 `wlx` over 既有分区表),**非** hdc/flashd。依据 = 恢复演练 attempt #5 真机 evidence
(#220)。`db`/`gpt` 属 MaskRom/miniloader 阶段命令、板上 U-Boot 升级态不实现,故正向
烧写沿用"进态→(现存表)→逐分区 `wlx`→`rd`→postflight"路径。

### In scope(分期;本 change 首 PR 只 proposal + design,实现各自独立 Task PR)

- **阶段 A — 人工真机特征化(device-gated,REQ-FLASH-014/015)**:
  - `images.tar.gz` 输入契约:成员清单、逐成员 SHA-256、分区映射(锚定 PD-002/FA-001)、
    大小范围、允许分区集与写序;
  - `RockchipFlashProfile`(REQ-FLASH-003):允许分区/必需文件/大小/hash/顺序的声明面;
  - 由**人类维护者**按 design 封闭命令面在 DAYU200 真机正向烧写一个已知 `images.tar.gz`
    (恢复演练 crib 的正向产品化),产出 `hardware-evidence.json` + 脱敏 transcript +
    postflight `ppt`/`list targets` 对照;
  - `hardware-matrix.md` 新增 DAYU200/Rockchip/rkdeveloptool 1.32 的 supported 行
    (REQ-FLASH-014:≥1 设备完整 realHardware 验收)。
- **阶段 B — 产品 Swift Flash Provider(REQ-FLASH-001/002/007/008/012/013/015)**:
  - `RockchipRockUSBFlashProvider`:`probe`/`validate`/`makePlan`/`recover` + typed
    `FlashStep`;prerequisites 声明(`updater`/`loader`/`unlocked`/`recoveryPath`);
  - `execute`/`planOnly`/`simulated` 模式可辨识(REQ-FLASH-004,复用 M1-008 seam);
  - destructive 确认(REQ-FLASH-007:显示设备/镜像/Provider/分区/数据影响;`userdata`
    erase 更强确认)、critical write 安全边界(REQ-FLASH-008)、postflight 语义校验
    (REQ-FLASH-012)、bounded recovery + RecoveryGuide(REQ-FLASH-013,接入恢复演练
    验证的 Loader `wlx` 恢复路径);
  - **REQ-FLASH-015 Agent/CI 边界**:真实设备 flash/erase 由**人类操作者亲自执行**,
    Agent/CI 凭据只允许 contract/fake/simulated/plan-only;execute plan + 真实 binding
    并存时 fail closed 生成人工 handoff;执行前须与待执行计划精确一致的人工确认;
  - `arkdeck flash images.tar.gz` CLI 接入(App 只经 Core/Workflows use-case,产出
    exact plan → 人工确认 → 人类执行,不由 Agent 直接 dispatch)。

### Out of scope / Non-goals

- 不修改任何 Core `REQ-FLASH-*`/AC/contract/schema(认领其既有 realHardware/contract 面);
- 不支持 DAYU200 以外设备、不新增厂商协议(各须独立 change,REQ-FLASH-014);
- 不改恢复演练(CHG-016)结论;不做正向烧写之外的 dump/trace/debug 功能;
- 首 PR 不实现 Swift、不执行真机烧写、不产生 evidence(proposal + design 层)。

## 安全设计原则(对齐 Core flashing 不变量)

- **Agent 零 destructive dispatch**:与恢复演练同构——真机写设备由人类维护者亲手执行,
  Agent 只做 Profile/契约/crib 起草、事后核验与 evidence 起草;
- **hash 先行**:`images.tar.gz` 成员逐一 SHA-256 校验 vs Profile,不符即阻断(REQ-FLASH-003);
- **exact plan + destructive 确认**:执行前展示完整计划(设备/Provider/分区/数据擦除),
  `userdata` 清数据须显式强确认(恢复演练 `ERASE-USERDATA` 先例);
- **恢复接入**:失败 RecoveryGuide 直接复用恢复演练验证的 Loader `wlx` 恢复路径
  (REQ-FLASH-013,honest:明确可能丢数据/无法启动);
- **simulation 永不冒充真机**(REQ-FLASH-006/014):simulated evidence 不进 hardware matrix。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR。其后阶段 A/B 各任务
在 approve + 独立 readiness 后方可执行;阶段 A 真机执行须人类维护者 + 具名设备窗口 + 书面
风险确认(REQ-FLASH-015/RISK 先例);阶段 B Swift 实现经维护者 review。本 change 不构成
hardware support、兼容性或 release 声明,直到阶段 A realHardware 验收合入 hardware matrix。
