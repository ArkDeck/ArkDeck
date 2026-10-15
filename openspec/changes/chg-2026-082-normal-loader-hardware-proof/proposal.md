---
id: CHG-2026-082-normal-loader-hardware-proof
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos, windows]
---

# Prove common hardware identity before entering Loader

A Normal USB identity may be an eMMC CID while Loader exposes the SoC serial.
Sending `reboot loader` before recording a common identity can lose the only live
Normal route and leave an unknown intent without provable same-target recovery.

Runtime must collect and durably read back the exact Normal target's hardware
serial before admitting this transition. The fixed kernel source must match the
already bound Loader identity. Missing, ambiguous, malformed, mismatched or
unpersisted evidence blocks admission and sends no mode-changing command.
The action repeats the read, persistence and attachment/tool checks immediately
before dispatch; Loader readback must retain the same physical connector.

This tightens the existing destructive admission policy and travels with its
implementation for maintainer review. It adds no operation, provider, profile,
caller-supplied proof, capability administrator or arbitrary shell route. The
existing protected-main Runtime owns the fixed read and record. The source is
supported only when its actual bytes match the admitted Loader identity; a
vendor serial or unsupported kernel does not receive an exception.

Earlier unknown Jobs, capabilities, effect sets and budgets remain immutable.
No current observation is imported as historical evidence. A Normal-only binding
cannot silently become a Loader binding. Complete-overwrite recovery still needs
every proof in POL-RECOVERY-001. User confirmation is not a substitute.

Compatibility: current Core and recovery predicates remain unchanged. The scoped
admission tightening is reviewed in this implementation PR; tests use synthetic
ports and do not claim hardware acceptance or change approval.
