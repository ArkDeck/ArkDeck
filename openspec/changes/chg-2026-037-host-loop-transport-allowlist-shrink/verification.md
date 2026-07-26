# CHG-2026-037 Verification Plan

> Status:planned
> Change:CHG-2026-037-host-loop-transport-allowlist-shrink@r1
> Core baseline:CORE-2.1.0（零 Core 变更；canonical Core AC 零认领）

验收面全部为 change-local。任何新增路由、任何字段 allowlist 放宽、任何公开
方法行为变更、任何 `FORBIDDEN_*` 触碰，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| TAS-ROUTE-001 | TAS-001 | contract | `ALLOWED_ROUTES` 恰为 8 条且精确内容被 `NoNewRouteOrEscapeHatch` 断言；裸 `GET /repos/{owner}/{repo}/pulls` 与裸 `GET /repos/{owner}/{repo}/issues` 被 `assert_route_allowed` 以 `RouteViolation` 拒绝（新增回归测试）；`route_inventory`/`forbidden_capability_count` 负证 = 0 |
| TAS-BEHAVIOR-001 | TAS-001 | contract | 全部公开方法既有契约测试零修改仍绿（同 template 异 method 的 `POST /pulls`、`POST /issues` 不受影响）；全量 offline suite 绿；`check-sdd` 0 error/0 warning；PR diff 恰在任务 Allowed paths 内 |

## Gate

两条全 PASS 且 evidence run 在案，任务方可 done；change verify 于任务 done 后
以独立 PR 收口。
