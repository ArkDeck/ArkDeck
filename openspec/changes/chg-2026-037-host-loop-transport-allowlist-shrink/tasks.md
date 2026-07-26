# CHG-2026-037 Tasks

## TASK-TAS-001 — 移除两条零构造点死路由并钉死收缩后语义

- Status:ready（r1 implementation readiness；仅在维护者对本独立 readiness PR exact
  head review/merge 后生效。只授权一个实现交付：按下方契约收缩 allowlist 并同步
  pins/回归测试，载体 = 维护者按 CHG-2026-030 TASK-HLR-005 编排选定（预期 =
  host-loop pilot 的 `agent/host-loop/tasks/TASK-TAS-001` envelope PR；维护者亦可
  另行显式指定常规 agent PR）。不授权：任何其他 `scripts/host_loop/` 文件变更、
  任何新增路由/字段 allowlist/`FORBIDDEN_*` 变更、governance text 变更、
  scheduler/launchd/host 变更、以及**代任务撰写 `Decision-Grade`**（该行由维护者
  亲手补写，时机受 HLR-005 编排约束）。）
- Historical Status:blocked（前置：① 本 change approval-only PR merge；② 独立
  readiness PR 钉定实现 base 的 exact blob pins 与实现契约。① = #558 merge
  `bdead7e47d824e213942d273e671a5d9ab9f7cd8`；② = 本 r1。）
- Readiness（r1；audit base = protected `main`
  `bdead7e47d824e213942d273e671a5d9ab9f7cd8`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件。只有
    `lvye` 对 exact head APPROVED、required checks terminal success、
    `mergedBy=lvye`、`auto_merge=null` 且 squash subject 携 `(#N)` 的 merge OID
    进入 protected main 后，本 readiness 才生效。
  - **Dependency gate:closed。**propose #557 merge `58ab9115e51d6b53a8a34632a067147a1a7fc00e`、
    approval #558 merge `bdead7e47d824e213942d273e671a5d9ab9f7cd8`，均
    `lvye` APPROVED、`auto_merge=null`、audit-base ancestors。
  - **Source pins:closed。**实现 base 与本 readiness merge tree 中下列 blob 须逐
    项相等，任一 drift 即停并重钉：
    `transport.py` `55e17e3caf139522c189dc6284db6ae90272fad2`、
    `test_backends_cli.py` `c8dc6afb7a161541bd6ffdbe93d7c4d662c967f5`、
    `test_reviewer_contract.py` `50aa14925d3c2ff70bbeb404a18f0e69a357577a`。
  - **Implementation contract:binary（2026-07-26 干跑实测钉定）。**
    ① `ALLOWED_ROUTES` 恰移除两行：`("GET", "/repos/{owner}/{repo}/pulls")` 与
    `("GET", "/repos/{owner}/{repo}/issues")`；transport.py 其余零字节变更。
    ② **已实测的反应面 = 恰好 3 条断言**：`test_backends_cli.
    NoNewRouteOrEscapeHatch.test_allowlist_contents_are_pinned_exactly`、同类
    `test_allowlist_is_unchanged_in_size`、`test_reviewer_contract.LoopReadOnly.
    test_module_adds_no_transport_route`——干跑删除后全量 480 中**只有**这 3 条
    失败、零行为测试失败（= 零构造点的机器证明，已于 audit base 复现）。实现须
    同步这 3 处到 8 条集合，且**不得出现第 4 处失败**；出现即说明有未知依赖，
    停并重 readiness。
    ③ 新增两条回归测试：`assert_route_allowed("GET", <裸 pulls 路径>)` 与
    `("GET", <裸 issues 路径>)` 抛 `RouteViolation`。
    ④ 全量 suite 于实现后 = 482 （480 − 0 + 2）OK + 1 expectedFailure；
    `check-sdd` 0/0；diff 恰在 Allowed paths 内。
  - **Concurrency/absence:closed at drafting（2026-07-26）。**remote
    `agent/task-tas*` 分支 = 0；envelope 载体 `agent/host-loop/tasks/TASK-TAS-001`
    与 lease `agent/host-loop/leases/TASK-TAS-001` 远端 absent（`agent/host-loop/**`
    全页 = 0，HLR-005 pre-readiness 复测过）。
  - **Pilot 联动（事实注记）**：本任务 ready 且依赖零缺后，距 claimable 只差
    `Decision-Grade` 行；两 unit left-running、900s 一轮。维护者补写该行的时机 =
    HLR-005 readiness r1 合入后按其编排——提前补写即提前认领，届时 reviewer/batch
    编排未就位，pilot evidence 将不完整。
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
- Decision-Grade:D0。

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
