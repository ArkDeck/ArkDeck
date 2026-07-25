# Spec Impact — CHG-2026-035

## Classification

本 change 是 macOS platform architecture decision。它为 CHG-2026-026
`TASK-RKFUI-001G` 的 merged blocked 事实建立独立判断门，不修改现行 Core 行为、
acceptance pass/fail、contract/schema 或 hardware support claim。

## No-op delta conclusion

- `openspec/specs/**`：零修改；
- `openspec/contracts/**`：零修改；
- canonical acceptance registry/index：零 ID 变化；
- Core baseline：保持 `CORE-2.1.0`；
- HDC external-first/DEC-007：零修改；
- CHG-2026-026 scope/task/evidence/status：零修改。

四条 `RKTA-*` 是 change-local document-review acceptance，只验证候选比较、架构结论、
authority/effect 边界与后续 handoff 的完整性，不升级为 Core AC。

## Decision impact boundary

本 proposal 的登记或批准都不批准五类候选中的任何一个。`TASK-RKTA-001` 的后续
decision carrier 可以选择架构，但不能直接实现。若所选架构需要下列任一变化，ADR
必须把它列为独立、先决且仍未批准的 change/decision：

- 修改 Sandboxed 单一 DMG、精确 entitlement 集或 DEC-004/ADR-0002；
- 改变 Flash execute/plan-only 用户可观察语义或任何 Core Requirement/AC；
- 新增 IPC/helper/bundled-tool schema、供应链 registry 或 locked contract；
- 改变 HDC bundling/external-first；
- 修改 CHG-2026-026 的 scope、task state、allowed paths 或 verification。

因此本 change verified 时仍不产生产品实现或平台 conformance claim；只有后续 change
按所选架构完成 implementation/evidence/verification 后，才可能改变产品能力。
