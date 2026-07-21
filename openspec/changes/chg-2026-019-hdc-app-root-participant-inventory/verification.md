# CHG-2026-019 Verification Plan

> Status:planned
> Change:CHG-2026-019-hdc-app-root-participant-inventory@r1
> Core baseline:CORE-2.0.0(零 Core 变更)

验证面 = contract 仪表化断言 + signed Sandbox UI 闭环。任何绕过 registry 的注册路径、
任何以常量冒充的计数、任何对 Supervisor 两类 reliability receipt 语义的放宽,出现即整体
fail。fake/loopback/签名本地 build 之外不触达任何真实 hdc/设备/网络。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| PI-HDC-INVENTORY-001 | contract(HDCSupervisorContractTests 专段) | 构造性完备成立:App 可达 API 面无 registry 外注册路径(静态断言);空-完备 inventory 使 participant reliability 为 true 且 endpoint-identity receipt 缺失时 preview 仍 blocked;注入 critical Flash Job 时 preview 含全部 affected/critical、named critical gate 阻断且 lifecycle child dispatch 实测 0;duplicate/跨 endpoint participant 仍 fail-closed | pending |
| PI-HDC-INVENTORY-002 | platform(signed Sandbox XCUITest) | production 启动(非 fixture、`--ui-test-reset-hdc-selection`)下 inventory-unavailable 文案缺席,`hdc.lifecycle.recoveryUnavailable` 理由收敛为 server-identity/endpoint 前置;fixture 场景全部既有断言零回归;签名产物 hash/entitlements 记录在案 | pending |

## Gate

本 change 成为 `verified` 的前提:两个 Evidence ID 均 PASS 且有 run 记录;全量
contract/UI 套件零回归;实现 PR 经维护者 review/merge。本 change 不翻转 TASK-M1-006
状态(其 done/closeout 修订须在本 change 与 CHG-2026-018 均落地后另行起草),不构成
CHG-2026-002 verified、platform conformance、hardware/support 或 release claim。
