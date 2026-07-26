# CHG-2026-037 Design — transport allowlist 收缩

> Status:draft
> Change:CHG-2026-037-host-loop-transport-allowlist-shrink@r1
> 冲突时以 Constitution、AGENTS.md、enforcement.md 为准。

## 1. 被移除的两条路由与零构造点证明

```text
("GET", "/repos/{owner}/{repo}/pulls")     # 裸 PR 列表
("GET", "/repos/{owner}/{repo}/issues")    # 裸 Issue 列表
```

证明方法（实现 PR 须在 evidence 里复现三层）：

1. **源扫描**：`transport.py` 全部 `self._call("GET", …)` 构造点枚举——
   `list_open_pulls_for_head`（恒带 `?head=…&state=open&per_page=100&page=N`，
   `_templatize` 归一为 `?head&state&per_page`）、`get_pull`（`/{number}`）、
   `get_issue`（`/{number}`）、`list_check_runs`（`/{oid}/check-runs?…`）。
   裸列表路径的字面构造点 = 0。
2. **结构证明**：allowlist 键是 `(method, template)` 二元组；`POST /pulls`、
   `POST /issues` 与被移除的 `GET` 条目同 template 不同 method，互不影响——
   移除后 create_pull/create_issue 的既有 contract 测试必须继续全绿。
3. **收缩后回归**：`assert_route_allowed("GET", "/repos/o/r/pulls")` 与
   `assert_route_allowed("GET", "/repos/o/r/issues")` 抛 `RouteViolation`。
   若未来任何方法误构造裸列表，它在第一次调用即被拒，而非静默合法。

## 2. 改动面（封闭列举）

| 文件 | 变更 |
| --- | --- |
| `scripts/host_loop/transport.py` | `ALLOWED_ROUTES` 移除两条（10→8）；其余零字节变更 |
| `scripts/host_loop/test_backends_cli.py` | `NoNewRouteOrEscapeHatch` 精确内容断言更新为 8 条集合 |
| `scripts/host_loop/test_reviewer_contract.py` | `len(ALLOWED_ROUTES)` pin 10→8 |
| （新增于既有测试文件内）| 两条裸列表拒绝回归测试 |

禁止顺带：任何新路由、任何 `ALLOWED_*_PATCH_FIELDS` 变更、任何
`FORBIDDEN_*` 变更、任何公开方法体变更。

## 3. 风险

- **误删活路由**：以全量 suite（480+ 基线）为门——任何公开方法若依赖被删条目，
  其 contract 测试即红。实测零依赖。
- **未来需要裸列表**：重新加入 = 治理变更（allowlist 注释原文），走新 change；
  本收缩不预支任何未来判断。
- **与 HLR-004 测试 pin 的联动**：`len==10` pin 由本 change 一并更新，属
  声明范围内同步，非 scope 蔓延。

## 4. D0 形状说明（供维护者 grade 判断参考，非代写）

结论由 main 已合入状态 + 确定性检查完全决定（零构造点是源码事实、由测试与
suite 机械判定）；diff 零新 scope/零新风险接受/零新授权（只收不放）；零权威
文件语义变更。grade 行本身依惯例由维护者亲手撰写。
