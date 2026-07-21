---
id: CHG-2026-020-dayu200-real-flash
revision: 1
status: archived # 2026-07-21 archive PR(先例 #178/#235;目录外零精确路径引用,DEC-002/hardware-matrix 均名称引用不断链);verified 于 #239。原注: 2026-07-21 本 verification-closure PR(先例 #175/#176/#201/#208/#224);批准链 #225/#226;须在 RF-001 done #234、RF-002 done #238 之后合入;archive 另行
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

## Approval

- r1 proposal 经 PR #225 合入 main(squash `596a1c3`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171/#195/#200)将本 change
  置为 `approved`;批准由维护者 review/merge 本 PR 构成。merge 即批准:
  - **DEC-002 正向决策建议** = Rockchip RockUSB Provider(Loader 态 `wlx`,非 hdc/flashd;
    恢复 attempt #5 #220 背书)——本批准确立该建议为本 change 的实现方向;DEC-002 整体
    resolve 仍由维护者在阶段 A realHardware 验收后判定;
  - **两阶段 scope 与安全设计**:TASK-RF-001(阶段 A 契约/Profile + 人工真机正向烧写)与
    TASK-RF-002(阶段 B Swift Provider + `arkdeck flash` + REQ-FLASH-015 Agent 边界)的
    objective/scope/allowed-paths 边界,以及 design §0 封闭命令面、`images.tar.gz` 契约、
    RockchipFlashProfile、REQ-FLASH-* 认领面与两个 change-local 验收(`RF-CONTRACT-001`/
    `RF-REALFLASH-001`)。
- 本批准不产生任务执行:`TASK-RF-001`/`TASK-RF-002` 保持 `blocked`,各须独立 readiness PR
  转 `ready`;阶段 A 真机执行另须具名设备窗口 + 书面风险确认;阶段 B 实现经维护者 review。
  本批准不构成 hardware support、兼容性、DAYU200 以外设备或 release 声明;simulated 永不
  进 hardware matrix。

## Verification closure(2026-07-21)

依 verification.md Gate 逐项复核(V2:整体结论由维护者 review/merge 本 PR 确认;须在
RF-001 done PR #234 与 RF-002 done PR #238 之后合入):

- **任务面**:两 task 均 done,各有 merged 实现 + 独立 done PR + evidence——
  TASK-RF-001(契约/Profile #230 `3ba7c2f` + 真机正向烧写 #233 `410598e`,done #234
  `7d2e2ba`);TASK-RF-002(Swift 实现 #236 `32908a9` + 真机验收 #237 `657f405`,
  done #238 `9a98941`)。
- **change-local 验收**(三项均可复查):
  - `RF-CONTRACT-001`(documentReview)**PASS**(#230 `images-tar-contract.md` §5:
    允许分区 = PD-002 mapped 9 项、orphan/无成员/空洞禁写、17 成员逐一 SHA-256、写序
    低偏移在前锚定 FA-001 §2、prerequisites、命令面 = design §0 封闭面);
  - `RF-REALFLASH-001`(realHardware)**PASS**(#233 `forward-flash-2026-07-21.md`:
    人工 crib 九分区 Loader `wlx` 全写入、`rd`、重启进系统、postcheck 58B
    `USB Connected localhost`);
  - `RF-ACCEPT`(realHardware,RF-002 真机验收)**PASS**(#237
    `acceptance-2026-07-21.md`:`arkdeck flash` 产品路径端到端 validate → exact plan →
    人工确认 gate → 人工 handoff `wlx`×9 → `rd` → postflight `succeeded/confirmed`)。
- **认领 Core AC**(11 行,canonical method 均满足;逐项 ownership 见 verification.md):
  - contract 面:`AC-FLASH-001/002/004/007/008/012/013-01` 与 `AC-FLASH-015-01/02` 由
    #236 的 15 个 contract 测试全绿承载(`TEST-AC-FLASH-*` PASS 行在案;全量
    `swift test` 302/0);`AC-FLASH-003-01` 由 #230 契约 + #236 Swift validation 面
    (mismatch → execute 与 planned-success 双阻断)承载;
  - realHardware 面:`AC-FLASH-014-01` 由 #233(matrix observed 行
    `EVD-RF001-DAYU200-20260721-001`)+ #237(**首条 verified 行**
    `EVD-RF002-DAYU200-20260721-001`,完整 Provider AC 组合)承载;#237 另实测
    非 TTY execute → `policyBlocked`(AC-FLASH-015-01 产品面)、mode-gate 先行
    (AC-FLASH-001)、postflight fail-closed 双向(AC-FLASH-012:observation 缺语义
    marker 时拒判 succeeded,marker 齐备才 succeeded)。
- **安全不变量**:Agent/CI destructive dispatch 全程恒 0(结构性:代码库无 dispatch
  路径;仪表化:`RockchipFlashDispatchMonitor` 快照断言;真机窗口实测:P1
  policyBlocked);真机 flash 均由人类维护者亲手执行;命令面全程未超出 design §0 封闭
  面;`userdata` 均经显式 `ERASE-USERDATA` 强确认;设备序列号零入仓。
- **偏差在案**:RF-002 验收 postflight #1 因 crib observation 聚合缺陷判
  waitingForRecovery,同批真实产物重聚合后 #2 succeeded——设备/产品无缺陷,产品语义门
  fail-closed 行为正确,两次判定与根因见 #237 transcript(§3 偏差记录)。
- **边界**:不构成 DAYU200 以外设备、其他固件/工具版本的支持声明;simulated/fake 未
  进入 hardware matrix;DEC-002 整体 resolve 与 archive 均属后续独立 governance PR,
  由维护者判定。
