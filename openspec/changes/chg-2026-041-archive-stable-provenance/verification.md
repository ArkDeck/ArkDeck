# CHG-2026-041 Verification Plan

> Status:planned
> Change:CHG-2026-041-archive-stable-provenance@r5
> Note(2026-07-28):r5 = trace-probes 的 registry 哈希亦为产品运行时 pin
> (`TraceProbeAdapter.swift`),迁移需 `Sources/**` → ASP-002 的迁移面窄化为
> rockchip 一处,trace 3 处并入 deferred 登记表(共 7 文件 / 15 处)。守卫不变。
> Note(2026-07-28):r4 = ASP-002 readiness 一并更正 `ASP-GUARD-001`——r2 写的
> 「全仓为 0」不可满足（readonly 面 12 处因产品运行时 pin 必须留存），改为
> 「显式 deferred 登记表以外为 0」并要求该表双向校验。
> Note(2026-07-28):r3 三方同步 = `readonly-probes.yaml` 的 SHA-256 被产品源码
> (`HDCReadOnlyProbeRegistry.swift`,由 `HDCProduction.swift` 消费) 钉死,其迁移
> 需 `Sources/**`(本 change 全局 Out of scope)→ ASP-001 窄化到 device-observation
> 一对(零产品消费方,恰是解开 CHG-2026-024 归档所需的全部);readonly/receipts 移出。
> Note(2026-07-28):r2 三方同步 = 迁移面勘察补全（另有 4 处 / 2 文件，其消费方
> 在 `scripts/**`，故移交 ASP-002 并要求「先迁移后设卡」）；`ASP-SHAPE-001` 的
> 零字面量断言限定到 ASP-001 的 9 个具名文件。形态设计零变化。
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部 change-local。任何 registry 语义字段被改动、任何哈希级联不一致、
或迁移后仍存在仓内 change 路径字面量，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| `ASP-SHAPE-001` | ASP-001 | contract | **device-observation 一对**内零 `openspec/changes/` 字面量（r3 窄化；readonly/receipts 因产品 pin 移出本 change，trace/rockchip 按 r2 归 ASP-002）；`HDCDeviceObservationRegistryContractTests` 须新增新形态断言（迁移前该测试完全不解码 provenance）；每条 provenance 具 `sourceChange` + `sourceEvidence` + `sourceSHA256`；active-or-archive 解析对**已归档**来源（chg-2026-015）与**未归档**来源（chg-2026-024）**两分支各**实测恰一处命中，0/2+ 命中为 loud fail |
| `ASP-CASCADE-001` | ASP-001 | contract | 两个 pack `resources.json`、`INTEGRATION-PROFILES.lock.yaml` 与契约测试哈希断言全部一致；Swift 全量于**非 `/private/tmp`** 检出零失败；`check-sdd` 0/0/111；device-observation 的 provenance 本无 `sourceSHA256`，等价判据 = registry 语义字段 diff 为空 + 正副本仍字节一致 + 两个 profile 的哈希引用同步 |
| `ASP-GUARD-001` | ASP-002 | contract | **先迁移**移交的 4 处 / 2 文件及其 `scripts/**` 消费方，**后设卡**；其后 `openspec/changes/` 字面量在**显式 deferred 登记表以外**为 0（表内 = readonly 面 12 处 / 6 文件 + trace-probes 3 处 / 1 文件 = **15 处 / 7 文件**，其哈希均为产品运行时 pin，待 `Sources/**` 授权的后续 change），该表按逐文件期望次数**双向**校验（多于或少于均 fail）；仓内全绿；人造违例（任一 registry 插入一条 `openspec/changes/...`）→ `check-sdd` 报 error 并指名文件与行；撤销该检查后同一违例不再被拦（反证）；acceptance ID 计数保持 111 |

## Gate

`ASP-SHAPE-001` 与 `ASP-CASCADE-001` PASS 后 ASP-001 方可 done；
`ASP-GUARD-001` PASS 后 ASP-002 方可 done。两任务 done 后 change verify 以
独立 PR 收口；CHG-2026-024 的 archive 由其自身独立 PR 走既有流程，不在本
change 载体内。
