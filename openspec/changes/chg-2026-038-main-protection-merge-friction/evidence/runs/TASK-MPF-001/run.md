# TASK-MPF-001 run log

## attempt#1（2026-07-26）— blocked：REST PUT 无法清除 force-push 白名单

### 结论

三项 delta 只落地两项。`required_status_checks.strict` 与
`dismiss_stale_reviews` 已 live 置 false；`allow_force_pushes` 的 REST 布尔
**无法经由 REST PUT 达成 false**——它是「everyone 位 OR per-actor 白名单非空」
的拍扁渲染，PUT `false` 只写 everyone 位，清不掉白名单。S4 投影门正确 FAIL；
S7 rollback 经裁决**不执行**（理由见下）；此后零写入，任务退 blocked 待 r2。

### 窗口时间线与 receipts（存 `~/mpf001-out/`）

| 步骤 | 结果 | 取证 |
| --- | --- | --- |
| readiness r1 | #576 merge `66a70e2a3dc7338be3cd02f9b5ddb4a1dc1ba236`（lvye APPROVED） | 生效 |
| S0–S2 preflight | PASS | `before.live.json` == pin `120faf45d9aaaf8973df91f81ce7703c2476a07554ba1752bcf9e618975d5fd1`；`before.live.projection.json` == pin `a8cff4489e2776dfdd552887e290bb8d695fc601ae9e804b6bf496aee60b59d8`；`ruleset.before.live.json` == pin `c404036f4e78b09960cc7a1705cdf8c5160f08e7baa577cb439350e2fdb31267`；三 inputs 哈希于 main 树复核命中 |
| S3 PUT | 已执行（lvye 亲手） | `put.response.json` sha256 `d3fa39903526aaa111cda50a2255811045910f4e1b201003995d3bd75346475b`；**响应体即显示 `strict=false`、`dismiss_stale_reviews=false`、`allow_force_pushes.enabled=true`** |
| S4–S6（用户侧） | 未执行 | Agent 交付的第三命令块尾部混入 `</parameter>` 杂质 → zsh 整行 parse error、零执行（Agent 输出事故，如实记） |
| S4 等价补测（Agent 只读） | **FAIL** | live full-GET sha256 `d3fa3990…`（**与 put.response.json 逐字节相同** = PUT 后状态稳定、期间无其他写）；projection sha256 `0df7bc6a1fba967ce7fa270d81182fc8cf0a992909411aeeb7003417f17fbbfe` ≠ expected `4046aced77a6ff040ea6789b6edf96a80e288ae6ef144d9d89a85b76a336d2dc`；三元组 `[false,false,true]` |
| S6 等价补测 | PASS | ruleset `19595282` 复测 sha256 == `c404036f…`（未动） |

修正后的逐字段 delta（修正式见「工具缺陷」；before → live）：

```json
[{"path":"required_pull_request_reviews.dismiss_stale_reviews","a":true,"b":false},{"path":"required_status_checks.strict","a":true,"b":false}]
```

信任根七元组 live 复测 = `[1,true,true,["lvye"],true,["guard"],false]`（未动）。

### 根因（双 API 面同时刻取证）

GraphQL（与 REST live 读同窗口）：

```json
{"pattern":"main","allowsForcePushes":false,"lockBranch":false,"bypassForcePushAllowances":{"totalCount":1,"nodes":[{"id":"MDIwOkJyYW5jaEFjdG9yQWxsb3dhbmNlMTMzMjI0NjE5","actor":{"__typename":"User","login":"lvye"}}]}}
```

（rule `BPR_kwDOTWtevs4Extgh` / databaseId `80140321`）

- GraphQL everyone 位 `allowsForcePushes=false` 而 REST 同刻 `enabled=true`
  → REST 布尔 = 「everyone 位 OR 白名单非空」的拍扁渲染；
- 白名单（"Specify who can force push" = `[lvye]`）仅 GraphQL/UI 面可管理，
  classic REST protection API 无字段表达、无能力清除；
- before 的 `enabled=true` 因此**不能反推**当时 everyone 位的值（不可追溯，
  如实记）；
- 语义现状：main 的 force push = 仅 `lvye` 可为。与 CHG-2026-033
  TASK-RPT-001 evidence 锚（`force-push false and deletion false`）仍不符——
  原 drift 的真实形态比 REST 面显示的深一层。

### S7 裁决（未执行；本 PR merge = 维护者追认）

不执行 `put-rollback.json` 的理由：

1. rollback 的 read-back 门（REST projection == `a8cff448…`）对白名单不敏感，
   只能证明 REST 渲染还原、**无法证明语义还原**——r1 投影模型已被本 attempt
   证伪为不完备；
2. `put-rollback.json` 携 `allow_force_pushes: true`，会把 everyone 位写成
   true：GraphQL 实测 everyone 位现为 false，rollback 将把「仅 lvye 白名单」
   扩成「所有 write 权限者可 force push」，主动劣化、与 CHG-2026-033 锚背道
   而驰；
3. 投影模型被证伪时，停止一切写入是 fail-closed 的第一义（宁驻留、不盲写）。

驻留态（本 attempt 终态，r2 的 before）已钉定：

- REST full-GET sha256 `d3fa39903526aaa111cda50a2255811045910f4e1b201003995d3bd75346475b`
  / projection sha256 `0df7bc6a1fba967ce7fa270d81182fc8cf0a992909411aeeb7003417f17fbbfe`
  / 三元组 `[false,false,true]`；
- GraphQL：`allowsForcePushes=false`、白名单 `[lvye]`（totalCount=1，node
  `MDIwOkJyYW5jaEFjdG9yQWxsb3dhbmNlMTMzMjI0NjE5`）；
- ruleset `19595282` == `c404036f…`。

驻留态在每一轴上不劣于 before：strict/dismiss_stale 已达目标值；force-push
白名单为原 drift 残留、未被本窗口引入或扩大。

### 工具缺陷（r2 必修，均已实测复现）

1. **jq `paths(scalars)` 假阴性**：`scalars` 是 select 型 node_filter，
   `paths(f)` 以「节点值过 f 后的 truthiness」选路径 → 值为 `false`/`null`
   的叶子路径被吞。r1 S5 delta 式对「false→true 变化」与「b 侧新增」单向
   失明（r1 方向 before 三项皆 true 故侥幸可用；S4 哈希门为真门，本次即由
   哈希门阻断）。**修正式（已于 单项/三项/两项 三对照实测）**：

   ```jq
   ([($a[0] | paths(type != "object" and type != "array")),
     ($b[0] | paths(type != "object" and type != "array"))] | unique) as $ps
   | [ $ps[] | . as $p
       | select(($a[0] | getpath($p)) != ($b[0] | getpath($p)))
       | {path: ($p|map(tostring)|join(".")),
          a: ($a[0]|getpath($p)), b: ($b[0]|getpath($p))} ]
   ```

2. 本机 PATH 上裸 `diff` 被 DevEco toolchain 同名二进制遮蔽且 dyld 崩溃
   （exit 134）——窗口命令用 `cmp` 不受影响；后续 runbook 禁用裸 `diff`。

### MPF-FLOW-001 资格注记

strict/dismiss_stale 现已 live 关闭，后续 merge 将事实上走单命令流；但按 r1
失败路径，本 attempt **不采认** flow 观测。留待 r2 的 `MPF-DELTA-001` PASS
后如实取首两个满足观测的 PR。

### r2 需要什么

- 以驻留态为新 before（上表三组 pin 直接复用）；
- 授权**恰好一次 GraphQL mutation**：`updateBranchProtectionRule`
  （rule `BPR_kwDOTWtevs4Extgh`，`bypassForcePushActorIds: []`），**零 REST
  PUT**（everyone 位已为 false，strict/dismiss_stale 已达标）；
- 双面 read-back：GraphQL（`allowsForcePushes=false` 且
  `bypassForcePushAllowances.totalCount=0`）+ REST projection ==
  `4046aced…`（r1 原 expected **不变，直接复用**——白名单清空后 REST 布尔
  应渲染 false，此推断本身列为 r2 的待证门而非假设）；
- 修正版 delta 式 + `cmp`-only 比对纪律；
- 执行者恒 `lvye` 于 Agent 不可达会话；Agent 零 protection 写入。
