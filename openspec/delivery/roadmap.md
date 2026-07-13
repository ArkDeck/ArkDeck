# Delivery Roadmap

> Overall estimate：TBD / pending real hardware confirmation  
> Core baseline：CORE-1.0.0

## Current repository state

- SDD baseline exists；
- Git repository initialized via the one-time governance bootstrap (2026-07-13)；protected review/CI and external trust root remain unconfigured, so all execution gates stay closed；
- no Xcode/Windows/Linux solution or product code；
- local Swift 6.3.2 is visible, but `xcode-select` currently points to Command Line Tools；
- no real device/support matrix has been supplied。

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
