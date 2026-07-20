# Product Decisions and Open Questions

Open question 不得以聊天记忆留存。每项记录默认决策、阻塞范围和受影响 specs。

## DEC-001 First supported hardware

- Status：decided（2026-07-18;决策由 owner review/merge 本 decision PR 构成,
  V2 治理,决策路径见 #52 登记）
- Owner：product/hardware owner
- Question（历史）：首批必须支持哪些设备/开发板、芯片、OpenHarmony build/API？
- Decision：首个目标设备/开发板选定为 **DAYU200（RK3568 SoC）**;其固定镜像输入
  锚定为 CHG-2026-003 pinned vendor archive（`732948803` bytes,SHA-256
  `fc7637f3…ec75280`,归档 evidence 见下）。OpenHarmony build/API 的正式支持范围
  不在本决策预先声明,由 M0B bring-up 与后续 DAYU200 Integration change 依真实
  设备 evidence 确定。
- Boundary：本决策是**目标选定,不是支持声明**——hardware matrix 仍无任何
  supported 行;任何硬件支持、兼容性或 flash 能力声明仍须 M0B 真实设备 evidence
  与 hardware verification;simulated/特征化 evidence 永不进入硬件支持矩阵。
- Evidence input（2026-07-18,CHG-2026-003 archived）：
  - 位置:`openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-characterization/evidence/`
    （四份 schema 校验 JSON + summary.md + run.md,#44/#47/#48/#49 全链 merge）;
  - 结论:pinned vendor archive（`732948803` bytes,SHA-256 `fc7637f3…ec75280`）
    分类为 `imagePackageFamily: rockchipRawImageSet`,六条件全真;17 个成员全部
    root-level regular file,物理序清单含逐成员 SHA-256（3 anchors + 11 `.img` +
    4 allowlist 文件,最大 `system.img` 2 GiB）;
  - 边界:fixedArchiveOnly、非权威;`deviceFlashProvider`/`targetCompatibility`
    均 `unknown`,`imageProfileReadiness: candidateNonExecutable`;该证据支持
    "候选镜像包结构完好、可作为 M0B bring-up 目标"的判断,不构成硬件支持、
    兼容性或 M0B 结论。
- Unblocked by this decision：M0B（DAYU200 bring-up）与 DAYU200 Integration
  change 的立项/规划;各自执行仍受独立 change proposal、readiness 与 evidence
  门禁,DEC-002 未决前不实现任何 Flash Provider。
- Reopen rule：更换或新增首批设备、变更 pinned 镜像输入、或将目标选定提升为
  支持声明,均须经 governance PR 重开/修订本条（后者另需 M0B evidence）。
- Affected：REQ-FLASH-001/002/014、hardware matrix

## DEC-002 First flashing protocol

- Status：open（CHG-2026-003 已把决策所缺证据显式化为四个 gap,登记为本决策的
  required evidence input,见下）
- Owner：hardware owner
- Question：首批设备使用 HDC flashd、fastboot、upgrade_tool 还是厂商协议？镜像/分区清单是什么？
- Default：仅设计 HDC/flashd Provider，不宣称已支持
- Required evidence（2026-07-18,来自 archived CHG-2026-003
  `package-classification.json.gaps[]`,全部 `unknown`）：
  - `GAP-DAYU200-PARTITION-SEMANTICS`:`parameter.txt` 分区表语义未解读（特征化
    刻意不解码成员字节）;
  - `GAP-DAYU200-FLASH-ADDRESSES`:未从任何成员推导烧写 offset/地址映射;
  - `GAP-DAYU200-FLASH-PROTOCOL`:flashd/rockusb/USB/UART/TCP 协议事实未建立;
  - `GAP-DAYU200-RECOVERY-PATH`:烧写中断后的恢复/救砖路径未建立。
- Resolution vehicle：四个 gap 须由后续独立 change 解决（DAYU200 Integration
  change / Route-B CLI plan-only 特征化;按 backlog 规则不得并入既有 Task,
  CHG-2026-003 evidence 明确不能满足本决策）;在此之前本决策保持 Default。
- Blocks：M4 Provider implementation/verification
- Affected：flashing spec、Provider contract

## DEC-003 Meaning of Debug

- Status：decided
- Decision：MVP 是设备调试工作台，不自研 ArkTS/C++ 源码级调试器
- Reopen rule：需要 Core/product MINOR or MAJOR change
- Affected：debug-workbench spec

## DEC-004 Distribution and update channel

- Status：partially open
- Default：Developer ID signed/notarized direct distribution；M0A 决定 Sandbox feasibility；自动更新非 MVP
- Question：内部工具、公开分发或 Mac App Store？
- Blocks：最终 distribution profile、M5 release
- Affected：macOS profile、diagnostics/privacy

## DEC-005 Embedded Trace viewer

- Status：decided
- Decision：MVP 只采集/导出，不内嵌完整 SmartPerf/Trace Streamer viewer
- Reopen rule：new capability change

## DEC-006 Retention and output policy

- Status：open
- Default：local-only、user-selected root、bounded quota/retention、pinned session protected
- Question：默认输出位置、总配额、保留期和组织级脱敏要求？
- Blocks：产品默认值，不阻塞 Storage contract
- Affected：REQ-ART-006、platform profiles

## DEC-007 Bundled HDC fallback

- Status：deferred
- Default：MVP 不捆绑，external-first
- Required before enabling：API/device support matrix、更新策略、license notices、SBOM、签名、公证、依赖审计
- Affected：REQ-HDC-001、platform distribution

## DEC-008 Remote crash/telemetry

- Status：deferred
- Default：无自动上传，仅本地、用户触发的脱敏诊断包
- Required before enabling：explicit opt-in、service/backend、privacy/retention、security review
- Affected：REQ-DIAG-001/002、POL-PRIVACY-001

## DEC-009 Dump product boundary

- Status：decided / Core baseline
- Decision：MVP 只包含 ArkUI UI Dump；Fault/Crash Artifact 和 System Diagnostic Snapshot 是 v1.x candidates
- Reopen rule：Core/product change with privacy/permission/version/symbolication design
- Affected：REQ-DUMP-001、project scope

## DEC-010 Linux support matrix and distribution

- Status：open / future
- Default：Linux 是 declared future target，但当前无支持声明
- Question：首批 distro/desktop/architecture 是什么；选择 deb/rpm/AppImage/Flatpak/Snap 中哪条 release path？
- Required evidence：udev/USB/UART、D-Bus/FileManager1、logind clocks/inhibitor、external HDC provenance、sandbox child-process/device/file matrix
- Discovery rule：L0 不被本 decision 阻断；L0 Task 必须预先固定有限的 distro/desktop/architecture/package 候选，只能产出 feasibility evidence 与 decision proposal，不得声称支持
- Blocks：L1 implementation、任何 Linux release claim，以及把候选矩阵提升为 supported matrix
- Affected：PLATFORM-LINUX@0.1.0、Platform verification/hardware matrix

## RISK-001 DAYU200 恢复演练残余风险接受(检查单第 4 项)

- Revision：r2 evidence-owner correction candidate；仅维护者 review/merge 本 PR 后生效
- Status：accepted（r1 于 2026-07-18 经 PR #97、merge
  `c3134f05d97591c6cd875dfe12ee2854b5151a0d` 形成 archived CHG-2026-010
  预案 §6 检查单第 4 项所要求的"维护者书面确认"；r2 不改变该风险接受，
  只在维护者合入后修正检查单第 3 项的 current evidence owner）
- Owner / 确认人：维护者 `lvye`（fuhanfeng）
- Statement（确认内容）：本人已阅读 archived CHG-2026-010
  `recovery-playbook.md` 的 §4 恢复步骤序列、§5 风险点与中止准则、§6 前置
  检查单,以及 archived CHG-2026-013 `prep-record.md` 的准备结论与 F1-F3
  发现。本人确认:**接受 DAYU200 恢复演练期间设备变砖乃至不可恢复的残余
  风险**;知悉"MaskRom 为芯片固化态、理论上始终可重入"这一风险兜底论断
  本身尚待演练确证,不将其视为承诺;知悉演练是全链条第一个写设备操作。
- Scope（适用范围）：仅覆盖按下列全部条件执行的恢复演练——
  1. 演练 change 独立立项/approve,立项时自归档路径原文引用 §6 检查单、同时引用
     本 RISK-001@r2 supersession，且七项全部打勾;
  2. 步骤遵循 archived 预案 §4、记录使用 archived CHG-2026-013 模板
     (含 P1-P6 前置检查)。归档预案/模板中的 `TASK-PD-001 解码 evidence` 字样保持
     immutable historical text，不再构成 current evidence-owner authority；对应检查项只有在
     TASK-PD-002 `done` 状态、同一次 fresh signed-broker platform mapping/reconciliation
     evidence 与其绑定的 TASK-PD-001 implementation identity 全部合入 `main` 后才满足，
     分区偏移只能取自该 TASK-PD-002 mapping evidence;
  3. §5 四项中止准则任一命中即停手。
- Invalidation（失效条件）：archived 预案或演练步骤发生 revision 后,本
  确认自动失效,须以新的 RISK 记录重新确认;本确认不可被引用于演练以外的
  任何写设备操作。r2 只修正 upstream task decomposition 后的 evidence owner，未修改
  archived bytes、步骤序列、风险点或中止准则；未来再次改变 evidence owner 仍须新的
  maintainer-reviewed RISK revision。
- Boundary：本确认**不构成演练执行授权**,不勾检查单其余项——第 3 项
  (TASK-PD-002 `done` + fresh platform mapping evidence)与第 5 项(明确时间窗、窗口内无
  其他设备操作并行)
  仍须在演练 change 立项时分别满足;`GAP-DAYU200-RECOVERY-PATH` 保持
  unknown,DEC-002 保持 open。
- Consumer：未来演练 change 立项时,检查单第 4 项引用本记录打勾。
- Clarification（2026-07-20,随账本对齐 PR 合入）：archived CHG-2026-013 proposal 中
  "第 4 项尚未满足"为其立项时点快照(immutable historical text),该项已由本记录
  r1(`c3134f0`)满足；当前未满足项仅剩第 3 项与第 5 项(见 Boundary)。本条为澄清
  注记,不改变 r1/r2 的接受范围、owner、Scope 或失效条件。
- Revision r2 provenance：CHG-2026-009@r4 经 PR #116 合入 `main`
  `7585603d459ae26ad566b9aaeecc953f9c26bd98`，将 headless codec remediation 与
  fresh platform mapping/reconciliation 分配给 TASK-PD-001/TASK-PD-002；CHG-2026-012@r2
  经 PR #120 合入 `main` `3a9d91f347cb1ebb4c8626017f8004cc6a036a09`，已把下游
  TASK-FA-001 的数值锚点同步到 TASK-PD-002。本 revision 不运行 collector、不读取 archive、
  不访问设备、不生成/rejudge evidence，也不改变 gap/DEC-002、兼容性、支持、硬件或 release
  状态。
