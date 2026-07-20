# Delivery Roadmap

> Overall estimate：TBD / pending real hardware confirmation  
> Core baseline：CORE-2.0.0

## Current repository state

> 2026-07-20 对齐；此前条目为 2026-07-14 时点快照，见 git 历史。

- SDD baseline：CORE-2.0.0 已于 2026-07-16 ratify（CHG-2026-004）；V2 git-native 治理自 2026-07-14 生效(见 planning/postmortem-2026-07-governance.md)；
- GitHub 仓库、受保护 main、CODEOWNERS 与 agent-pr/sdd-guard workflow 已配置；Agent 受限凭据分离仍是待办人类动作；
- macOS 产品代码已存在：ArkDeck.xcodeproj/ArkDeckApp shell 与 Packages/ArkDeckKit（M0A verified；M1 即 chg-2026-002 的 001-005/009/010 done、006 blocked 遗留、007/008 状态见其 tasks.md）；Windows/Linux 仍未开始；
- 工具链：Swift 6.3.3 / SwiftPM / swift-format 6.3.0（M1 readiness 记录）；
- 硬件：DEC-001 已选定 DAYU200/RK3568；hardware-matrix 有首条 observed 行（EVD-M0B-DAYU200-20260718-001，OH 7.0.0.34/API 26），supported 行仍为零；Route-B 恢复预案/演练准备已归档，恢复演练 device-gated。

## Milestones

| Milestone | Planning band | Exit condition |
| --- | ---: | --- |
| M0A macOS platform Spike | 3–6 days | Xcode/runner shell, external HDC discovery, supervisor prototype, single instance/journal/power, clean-VM Gatekeeper/Sandbox matrix and distribution decision |
| M0B real hardware bring-up | TBD | first devices, HDC/auth/channel evidence, capabilities, target flash protocol/updater entry, transport rebind boundaries and vendor recovery path |
| M1 shared infrastructure | 7–12 days | Process/Runtime ports, HDC supervisor/auth, DeviceCoordinator/binding revision, journal/reconcile, HostStorageCoordinator, clock/progress, simulation and diagnostics skeleton |
| M2 UI Dump/Trace MVP | 7–12 days per verified output family | four UI Dump recipes, bounded hitrace/bytrace adapters, parameter policy, raw/derived artifacts, history and failure fixtures |
| M3 Debug workbench | 4–7 days | hilog rotation/quota, Apps, forwarding, one-shot commands and explicit device-buffer management |
| M4 Flash MVP | re-estimate after M0B | one real Provider, plan/effect gates, prerequisites/images, storage/power/binding/recovery state machine and hardware evidence |
| M5 stability/release | 5–9 days | fault injection, diagnostics, zh-Hans/en, accessibility, privacy, signed/notarized package and clean-host smoke |
| W0 Windows platform Spike | future | Port selection, process/lock/power/volume/trust proof and Core conformance feasibility |
| W1 Windows application | future, after W0 | Windows UI and platform ports, shared capabilities, platform tests and signed package without Core changes |
| L0 Linux platform Spike | future | distro/desktop matrix, process/flock/D-Bus/logind clocks, honest tool provenance, udev/USB/UART and package/sandbox feasibility |
| L1 Linux application | future, after L0 | Linux UI and platform ports, shared capabilities, platform tests and selected signed/repository package without Core changes |

Bands are software planning ranges, not commitments. M2 only covers declared parser/help families; each new firmware family and vendor protocol is separate scope.

## Implementation dependency order

```text
M0A platform feasibility
→ Process / Runtime / Storage / Journal
→ HDC Supervisor / Authorization
→ Device Binding
→ Workflow / Recovery
→ UI Dump + Trace
→ Debug
→ M0B-confirmed Flash
→ Release hardening
```

Windows/Linux follow the same dependency graph after W0/L0 and reuse language-neutral Core contracts, adapters where portable, schemas, fixtures and conformance vectors. Neither future platform is a current support claim.

## Entry rule

Milestone text is not an executable Task. Work begins only from an approved change with `ready` Task packets.
