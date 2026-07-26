---
id: CHG-2026-037-host-loop-transport-allowlist-shrink
revision: 1
status: approved # 本 approval-only PR 经维护者 review/merge 后生效；r1 proposal 已由 #557 登记（merge 58ab9115）；TASK-TAS-001 仍 blocked 待独立 readiness
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# host-loop transport allowlist 收缩：移除两条零构造点死路由

## Why

`scripts/host_loop/transport.py` 的冻结正向 allowlist（`ALLOWED_ROUTES`）现有
10 条。2026-07-25 TASK-HLR-003 r3 discovery 期实测发现其中两条**任何公开方法都
构造不出来**，2026-07-26 复测成立：

- `("GET", "/repos/{owner}/{repo}/pulls")`——裸列表。唯一的 pulls 列表方法
  `list_open_pulls_for_head` 恒附 `?head&state&per_page&page`，模板化为带查询
  变体；`get_pull` 走 `/{number}`；`POST` 建 PR 是不同的 (method, template) 键。
- `("GET", "/repos/{owner}/{repo}/issues")`——裸列表。`get_issue` 走
  `/{number}`；`create_issue` 是 `POST`；`update_issue`/`close_issue` 是
  `PATCH /{number}`。

零构造点的路由 = 死能力：它不服务任何现有行为，却常驻扩大被授权面。最小能力
原则下，allowlist 里的每一条都应当有活的构造点；留着它们，未来任何一次误接线
（比如一个漏加查询参数的列表调用）会**静默合法化**而不是被 `RouteViolation`
拦下。收缩后，裸列表形态从「允许但无人用」变为「显式拒绝」，fail-closed 面
净增。

发现于治理审计、立项早于 host-loop pilot 的存在（记录时点 2026-07-25，先于
TASK-HLR-005 pre-readiness r0）。**如实登记双重作用**：维护者于 2026-07-26 决定
推进本线时，知晓其实现任务天然满足 TASK-HLR-005 pre-readiness 钉定的 pilot 触发
条件 (a)（天然出现、存在理由独立于 pilot 的 host-only 可派发任务）。本 change 的
立项理由独立成立；pilot 只是按其设计认领天然产生的工作，不构成「为演练制造
任务」。

## What changes

### In scope

- 从 `ALLOWED_ROUTES` 移除上述两条死路由（10 → 8）；`FORBIDDEN_PATH_MARKERS`、
  `FORBIDDEN_METHODS`、全部公开方法签名与行为零变更。
- 同步两处既有测试 pin：`test_backends_cli.NoNewRouteOrEscapeHatch` 的精确内容
  断言（8 条新集合）与 `test_reviewer_contract` 的 `len(ALLOWED_ROUTES)` pin
  （10 → 8）。
- 新增回归测试钉死收缩后语义：裸 `GET /pulls` 与裸 `GET /issues` 模板被
  `assert_route_allowed` 以 `RouteViolation` 拒绝（死能力保持死亡，不可静默
  复活）；每个公开方法在既有 contract 套件下仍构造且仅构造其允许形态（全量
  suite 绿即为零行为变更的机器证明）。
- 本 change 的 evidence 记录。

### Out of scope

- 任何新增路由、任何字段 allowlist 变更、任何公开方法行为变更；
- `sdd-guard.yml`/`agent-pr.yml`/governance text；
- scheduler/launchd/unit/host 状态（两 unit left-running 冻结条款不受本 change
  影响）；
- TASK-HLR-005 pilot 自身的编排（属 chg-2026-030；本 change 不依赖 pilot 也不
  被 pilot 依赖——若 pilot 认领其任务，认领事实记录于 HLR-005 evidence）。

## Tasks

单任务：TASK-TAS-001（见 tasks.md）。propose 合入 ≠ 批准；approval-only PR
merge 后 change 方为 approved；任务经独立 readiness 后方可实现。
