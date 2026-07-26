# CHG-2026-037 Tasks

## TASK-TAS-001 — 移除两条零构造点死路由并钉死收缩后语义

- Status:blocked（前置：① 本 change approval-only PR merge；② 独立 readiness PR
  钉定实现 base 的 exact blob pins 与实现契约。）
- Platform:macos（host-only；零产品/设备声明）
- Requirements/AC:change-local `TAS-ROUTE-001`、`TAS-BEHAVIOR-001`
- Depends on:none
- In scope:`ALLOWED_ROUTES` 移除 `("GET","/repos/{owner}/{repo}/pulls")` 与
  `("GET","/repos/{owner}/{repo}/issues")`（10→8）；同步
  `test_backends_cli.NoNewRouteOrEscapeHatch` 精确内容断言与
  `test_reviewer_contract` 的 `len(ALLOWED_ROUTES)` pin；新增两条裸列表
  `RouteViolation` 拒绝回归测试；evidence 记录。
- Out of scope:任何新增路由/字段 allowlist 变更/公开方法行为变更；
  `FORBIDDEN_PATH_MARKERS`/`FORBIDDEN_METHODS` 变更；governance text；
  scheduler/launchd/host 状态。
- Allowed paths:`scripts/host_loop/transport.py`、
  `scripts/host_loop/test_backends_cli.py`、
  `scripts/host_loop/test_reviewer_contract.py`、本 change `evidence/**`、本
  change `tasks.md`（仅本任务状态/evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、`scripts/host_loop/` 其余文件、
  产品 source/tests、其他 change。
- Risk:low（只收不放；全量 suite 为零行为变更之门；误删活路由会立即红）。
- Hardware required:no。

### Deliverables

- 收缩后的 `ALLOWED_ROUTES`（8 条精确集合）与三层零构造点证明（源扫描枚举、
  (method, template) 结构说明、收缩后拒绝回归）；
- 两处既有 pin 的同步与两条新增拒绝测试；
- evidence run 记录全量 suite 前后计数与 `check-sdd` 0/0 基线。

### Verification

- `TAS-ROUTE-001`：`ALLOWED_ROUTES` 恰为 8 条且内容被精确断言；裸
  `GET /pulls`、裸 `GET /issues` 模板被 `assert_route_allowed` 拒绝；
  `route_inventory`/`forbidden_capability_count` 负证维持 0。
- `TAS-BEHAVIOR-001`：全部公开方法契约测试零修改仍绿（`POST /pulls`、
  `POST /issues` 等同 template 异 method 条目不受影响）；全量 offline suite
  绿；`check-sdd` 与 diff check 绿。

### Notes / handoff

- 本任务不携带 `Decision-Grade` 行：依惯例该行由维护者亲手撰写；时机受
  CHG-2026-030 TASK-HLR-005 pre-readiness r0 的编排约束（readiness r1 合入后
  按序补写——活循环每 900s 扫描，提前补写即提前认领）。
- 若 host-loop pilot（TASK-HLR-005）认领本任务，实现载体 = loop 开启的
  `agent/host-loop/tasks/TASK-TAS-001` envelope PR，认领与 review/merge 事实
  记录于 HLR-005 evidence；本任务自身的 done 翻转仍走本 change 的独立状态 PR。
- implementation/evidence 与 `ready→done` 状态 PR 分离。
