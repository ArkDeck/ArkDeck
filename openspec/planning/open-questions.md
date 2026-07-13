# Product Decisions and Open Questions

Open question 不得以聊天记忆留存。每项记录默认决策、阻塞范围和受影响 specs。

## DEC-001 First supported hardware

- Status：open
- Owner：product/hardware owner
- Question：首批必须支持哪些设备/开发板、芯片、OpenHarmony build/API？
- Default：无支持声明
- Blocks：M0B、真实 Flash、hardware verification
- Affected：REQ-FLASH-001/002/014、hardware matrix
- Work allowed：M0A、通用 M1、simulation、parser fixtures

## DEC-002 First flashing protocol

- Status：open
- Owner：hardware owner
- Question：首批设备使用 HDC flashd、fastboot、upgrade_tool 还是厂商协议？镜像/分区清单是什么？
- Default：仅设计 HDC/flashd Provider，不宣称已支持
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
