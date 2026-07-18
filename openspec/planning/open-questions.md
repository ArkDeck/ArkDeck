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
