# CHG-2026-044 Spec Impact

> Change:CHG-2026-044-openharmony-profile-version-reconciliation@r1
> Core baseline:CORE-2.1.0

## No-op Core delta

- `openspec/specs/**`:零修改。
- `openspec/contracts/**`:零 schema/required-field/semantic 修改。
- canonical acceptance index/cases:零 ID 增删改；三条 `OPVR-*` 仅为 change-local AC。
- Core baseline:保持 `CORE-2.1.0`。

本 change 不改变任何产品行为、Safety invariant、HDC authority、device binding 或
effect classification，也不认领 canonical Core AC。

## Integration impact

- living `OPENHARMONY-TOOLS` header 对齐到已经由 CHG-2026-024 登记的 `0.5.0`；
- `INTEGRATION-PROFILES-0.6.0`、device/readonly/trace registries/resources 与
  historical adoption boundaries 保持不变；
- SDD Guard 新增 current integration lock entry 与 referenced profile header 的
  generic ID/version consistency check；
- 不创建 `0.6.0/0.7.0`，避免越过 CHG-2026-043 fresh readiness。

## Platform and consumer impact

- macOS runtime/conformance 无变化；Windows/Linux 仍 deferred。
- 既有 consumer pins 不因 living header correction 自动升级。
- CHG-2026-043 `TASK-HSO-001` 只有在本 change verified 后才可重新做 readiness；
  本 change 不替它接受 candidate version、provenance 或实现 scope。
