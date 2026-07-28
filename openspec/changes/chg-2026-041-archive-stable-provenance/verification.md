# CHG-2026-041 Verification Plan

> Status:planned
> Change:CHG-2026-041-archive-stable-provenance@r1
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部 change-local。任何 registry 语义字段被改动、任何哈希级联不一致、
或迁移后仍存在仓内 change 路径字面量，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| `ASP-SHAPE-001` | ASP-001 | contract | 全部 registry/resource/receipt 零 `openspec/changes/` 字面量；每条 provenance 具 `sourceChange` + `sourceEvidence` + `sourceSHA256`；active-or-archive 解析对**已归档**来源（chg-2026-015）与**未归档**来源（chg-2026-024）**两分支各**实测恰一处命中，0/2+ 命中为 loud fail |
| `ASP-CASCADE-001` | ASP-001 | contract | 两个 pack `resources.json`、`INTEGRATION-PROFILES.lock.yaml` 与契约测试哈希断言全部一致；Swift 全量于**非 `/private/tmp`** 检出零失败；`check-sdd` 0/0/111；每条 `sourceSHA256` 与迁移前逐项相等（只改引用未改内容的机器证明）；registry 语义字段 diff 为空 |
| `ASP-GUARD-001` | ASP-002 | contract | 迁移后仓内全绿；人造违例（任一 registry 插入一条 `openspec/changes/...`）→ `check-sdd` 报 error 并指名文件与行；撤销该检查后同一违例不再被拦（反证）；acceptance ID 计数保持 111 |

## Gate

`ASP-SHAPE-001` 与 `ASP-CASCADE-001` PASS 后 ASP-001 方可 done；
`ASP-GUARD-001` PASS 后 ASP-002 方可 done。两任务 done 后 change verify 以
独立 PR 收口；CHG-2026-024 的 archive 由其自身独立 PR 走既有流程，不在本
change 载体内。
