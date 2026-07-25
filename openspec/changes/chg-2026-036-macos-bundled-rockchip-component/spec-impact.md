# Spec Impact — CHG-2026-036

## Classification

本 change 是 ADR-0003 选定架构的 macOS platform implementation prerequisite。它闭合
bundled Rockchip component 的供应链、构建、打包签名、product composition、signed
Sandbox E0 与 clean distribution evidence，不修改 shared Core 行为。

## No-op Core delta conclusion

- `openspec/specs/**`：零修改；
- `openspec/contracts/**`：零 locked contract/schema 修改；
- canonical acceptance registry/index：零 ID 变化；
- Core baseline：保持 `CORE-2.1.0`；
- HDC external-first/DEC-007：零修改；
- CHG-2026-026 scope/task/evidence/status：零修改；
- hardware support matrix：零修改。

七条 `BRC-*` 是 change-local acceptance。它们验证 component 的 source/distribution、
reproducibility、nested package、composition、E0 与 clean-host delivery，不升级为
Core AC，也不形成真实 Flash 或 macOS platform conformance claim。

## Integration artifact boundary

后续任务可以新增
`openspec/integrations/rockchip/bundled-component/<version>/`，记录 source、build、
dependency、SBOM、artifact 与 bundle identity。该 registry 是 product-owned
integration input，不是 caller-provided authority，也不替代 runtime signature/hash/
version verification。

若实现发现必须修改 typed Provider/Profile、workflow step registry、Job/Artifact
schema、App entitlement、distribution architecture、HDC bundling 或任何 Core
Requirement/AC，本 change 的对应任务保持 blocked，并先走 proposal revision/new
change；不能把差异藏在实现或 verification 中。

## Downstream boundary

本 change verified 后只证明 bundled component prerequisite。它不会自动：

- 修改或解封 CHG-2026-026；
- 创建 Flash UI/按钮或 enablement；
- 接受 destructive standing authorization；
- 执行 Loader transition、partition write、reset 或真实 update；
- 更新 hardware matrix 或声明 macOS Flash support。

这些用户可观察能力必须由 CHG-2026-026 的后续独立 revision、readiness、implementation
与 realHardware acceptance 闭合。
