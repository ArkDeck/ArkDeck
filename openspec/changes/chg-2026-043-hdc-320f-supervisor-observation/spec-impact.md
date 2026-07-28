# CHG-2026-043 Spec Impact

> Change:CHG-2026-043-hdc-320f-supervisor-observation@r1
> Core baseline:CORE-2.1.0

## No-op Core delta

- `openspec/specs/**`:零修改。
- `openspec/contracts/**`:零 schema/required-field/semantic 修改。
- canonical acceptance index:零 ID 增删改；四条 `HSO-*` 仅为 change-local AC。
- Core baseline:保持 `CORE-2.1.0`。

本 change 以更窄的 exact integration authority 实现既有 `REQ-HDC-002`
host-wide supervisor、`REQ-HDC-003` ownership-protected lifecycle、`REQ-HDC-004`
endpoint isolation 与 `REQ-UX-002` diagnostics。它不改变 external ownership 的
four-evidence 定义，不让 health/version unknown 变成 known，也不扩大 lifecycle 或
device mutation authority。

## Integration and platform impact

- 新增独立 exact 3.2.0f commandless supervisor-observation registry/resource，并 bump
  OpenHarmony profile 与 Integration lock。
- macOS profile 只增加该 family 的 mapping/version adoption；不产生 platform
  conformance transition。
- 现有 3.2.0d readonly registry、3.2.0f device-observation registry、hardware matrix
  与所有既有 conformance pins 保持不变。
- Windows/Linux 仍 deferred；不得从 macOS process/socket implementation推断支持。

## Consumer and hardware impact

- TASK-HSO-002 是单独 consumer adoption，必须在 registry task done 后独立 readiness。
- 本 change 的 host-only contract/evidence 不满足 CHG-2026-006 `TASK-M0B-002` 的任何
  realHardware AC，也不改变其 blocked 状态。
- 本 change verified 后，M0B-002 仍须另起 fresh readiness，重新 pin 同一候选、
  hardware matrix、工具/设备可用性和完整验证方法。
