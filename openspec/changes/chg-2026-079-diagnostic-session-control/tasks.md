# Tasks

## TASK-DSC-001 — Runtime session control and macOS Diagnostics

- Goal: start, mark, stop and read a bounded Diagnostic Session through typed Runtime operations.
- Status:in-progress (implementation and local verification complete; CI and maintainer review pending)
- Hardware required: no (implementation and host/fixture verification only)
- Expected paths: `Catalog/`, Rust provider/hoststore/control/daemon, `spec/control/`, ClientKit, App Diagnostics, focused tests and design documentation.
- Acceptance: DSC-AC-1 through DSC-AC-6 in verification.md.
- Device execution: blocked until maintainer review and publication to protected main; no hardware PASS is inferred.
