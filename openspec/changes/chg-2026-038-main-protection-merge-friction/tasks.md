# CHG-2026-038 Tasks

## TASK-MPF-001 — 施加三项 protection delta 并双向取证

- Status:done（2026-07-26。`MPF-DELTA-001` = **PASS**（attempt#2，见 run.md：
  双面 read-back 全门命中、累计 delta 恰好三项、信任根七项一致、ruleset 未动、
  Agent protection 写入计数 0；R6 未触发，#580 的触发限定条款未被用到）。
  `MPF-FLOW-001` 载体：观测① = evidence PR #581（单命令合入 merge
  `b055fe306d07126c1235788f84a8c035c7209c2e`）；观测②（落后分支免
  `Update branch` 合入）**改于 verify/archive 载体对上执行**——本 PR 原与
  #581 并行 in-flight 的编排被 #580 review-fix 的同段文本冲突打断，重排到
  f28d416b 之后不再落后；重排 force-push 后其 approval 若存续即
  `dismiss_stale_reviews=false` 的直接实证，连同两观测的 audit 四件套由
  change verify PR 以 gh 记录复核落账。flip-base recheck 五项已执行于 #581
  merge `b055fe30…`：(a) 链 ancestry #574/#575/#576/#577/#578/#579/#580/#581
  八 merge 全为 ancestors；(b) run.md attempt#2 已在 flip base 树内；(c)
  Agent 独立双面复验（flip 重排时点再测）全命中（REST `4046aced…`/GraphQL
  `241b9160…`/ruleset `c404036f…`）；(d) 本 flip 单文件；(e) 不声称清单：
  窗口 receipts 存 `~/mpf001-out` 未入仓，哈希清单在 run.md。）
- Historical Status:ready（r2 execution readiness = #579 merge
  `4aab55cc42b04d52d4d55b8aedbfa2b2d49eb998`，after #580 review-fix
  `f28d416b4ef0a8e7d98bed2a1d4d4801482d1c68`（E1 paste-safety/E2 R6 触发
  限定/E3 grade 注记时效）；R0–R6 契约与 pins 见下方 Readiness（r2）段，作
  历史记录保留；其一次性 GraphQL mutation 授权已于 attempt#2 消耗（全门
  PASS，R6 未触发）。）
- Historical Status:blocked（**attempt#1 2026-07-26 blocked**：窗口 S0–S2
  PASS、S3 已执行，但 REST PUT 对 `allow_force_pushes` 无效——REST 布尔是
  「everyone 位 OR `bypassForcePushAllowances` 白名单非空」的拍扁渲染，白名单
  `[lvye]` 仅 GraphQL/UI 可清；S4 FAIL（live projection `0df7bc6a…` ≠ expected
  `4046aced…`；strict/dismiss_stale 两项已 live 达标）；S7 经裁决不执行，
  #578 merge `4a1a118a197a1a0846f04e86acf8232e0784b592` = 追认。全档见
  `evidence/runs/TASK-MPF-001/run.md` attempt#1。）
- Historical Status:ready（r1 execution readiness = #576 merge
  `66a70e2a3dc7338be3cd02f9b5ddb4a1dc1ba236`；其 S0–S7 契约与 pins 见下方
  Readiness（r1）段，作历史记录保留；r1 的一次性 PUT 授权已于 attempt#1 消耗。）
- Readiness（r2；audit base = protected `main`
  `4a1a118a197a1a0846f04e86acf8232e0784b592`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件并新增
    `evidence/runs/TASK-MPF-001/inputs/` 两个工件（`mpf_gql_projection.jq`、
    `mpf_delta.jq`）。只有 `lvye` 对 exact head APPROVED、required checks
    terminal success、`mergedBy=lvye`、`auto_merge=null` 且 squash subject 携
    `(#N)` 的 merge OID 进入 protected main 后，本 readiness 才生效。
  - **Dependency gate:closed。**propose #574
    `aa6b447ceb38585a56b506ee571362f91dccb73a`、approval #575
    `1609b4d5d185410da8d3245efcd5b5a86ccc8d8c`、readiness r1 #576
    `66a70e2a3dc7338be3cd02f9b5ddb4a1dc1ba236`、attempt#1 blocked-attempt
    evidence #578 `4a1a118a197a1a0846f04e86acf8232e0784b592`（= no-S7 裁决
    落账），均 `lvye` APPROVED、audit-base ancestors。
  - **Before-state pins:closed（2026-07-26 r2 起草时 authenticated 复测，与
    attempt#1 驻留态零漂移；执行窗 R1 任一不符 → 零写入、停、重 readiness）：**
    - REST full-GET SHA-256 =
      `d3fa39903526aaa111cda50a2255811045910f4e1b201003995d3bd75346475b`
      （= attempt#1 put.response 逐字节同体）；
    - REST canonical projection（`mpf_projection.jq`）SHA-256 =
      `0df7bc6a1fba967ce7fa270d81182fc8cf0a992909411aeeb7003417f17fbbfe`；
    - GraphQL canonical projection（`mpf_gql_projection.jq`，`jq -S -c`）
      SHA-256 =
      `dea8a6d097a15d22202b23dcf3b92fdb31707d11dc379edf542a8cf3da1035bd`
      逐字 =
      `{"allowsForcePushes":false,"bypass":{"actors":[{"login":"lvye","type":"User"}],"totalCount":1},"lockBranch":false,"pattern":"main"}`；
    - ruleset `19595282` full-GET SHA-256 =
      `c404036f4e78b09960cc7a1705cdf8c5160f08e7baa577cb439350e2fdb31267`；
    - 工具谱系：`jq-1.7.1-apple`（/usr/bin/jq）、`shasum -a 256`、比对一律
      `cmp`（裸 `diff` 本机被遮蔽且崩，attempt#1 已证，禁用）。
  - **Window inputs:committed & pinned。**本 PR 新增（r1 三工件继续在位）：
    - `mpf_gql_projection.jq` SHA-256 =
      `75923b674933d1d36699b151d2bae5d47b17004f3160f0edbe1e1ff619253b9c`
      （GraphQL 投影：pattern 过滤 `main`、actor 只取 `{type, login}` **刻意
      不含 allowance node id**——rollback 重建的 node id 必然是新值，投影须对
      其不敏感）；
    - `mpf_delta.jq` SHA-256 =
      `af7c2df11d77f772448743bf4014e648f8f0b8d7cab349f3901b0e6962913624`
      （attempt#1 修正式：`paths(type != "object" and type != "array")` +
      双侧路径并集，false/null 叶子与 b 侧增删均可见；单项/三项/两项/GraphQL
      增删对四组实测通过）；
    - r1 的 `put-after.json`/`put-rollback.json` 本窗口**零使用**（历史工件
      如实保留，任何 REST PUT 均不在 r2 授权内）。
  - **Expected after:closed（确定性推导 + host 侧实测）。**
    - GraphQL projection SHA-256 =
      `241b916010e3fa431663c36d21af7bd4b361cb4a374a789f0db7d74366efbac6`
      逐字 =
      `{"allowsForcePushes":false,"bypass":{"actors":[],"totalCount":0},"lockBranch":false,"pattern":"main"}`；
    - REST projection SHA-256 = `4046aced77a6ff040ea6789b6edf96a80e288ae6ef144d9d89a85b76a336d2dc`
      （r1 原 expected **复用**；「白名单清空后 REST 布尔渲染 false」是 R3
      待证门而非假设——若 GraphQL 面全达标而 REST 布尔仍 true，即第三个渲染
      语义面，停、如实记、重 readiness）；
    - REST 逐字段 delta 恰一元（R3 输出须逐字节相等，jq `-c` 单行）：

      ```json
      [{"path":"allow_force_pushes","a":true,"b":false}]
      ```

    - 信任根七元组不变：`[1,true,true,["lvye"],true,["guard"],false]`。
  - **Mutation pins。**rule `BPR_kwDOTWtevs4Extgh`（databaseId `80140321`）；
    rollback actor = `lvye` User node id `MDQ6VXNlcjQzNDAxNjE=`（databaseId
    `4340161`，与 REST `restrictions.users[0].id` 一致）；两条 mutation 字符串
    逐字钉定于 R2/R6。GraphQL update 为 patch 语义（未提供字段不动），其兜底 =
    R3 的 REST 全语义投影相等门（覆盖整个 protection 面）。GraphQL mutation
    错误即原子失败 = 零变更（停、贴回转录，不重试不改写）。
  - **Window contract（R0–R6；mutation 仅 R2/R6 且仅 `lvye` 亲手；Agent 已于
    live before + 确定性 after 上 host 侧自测 R1/R3/R4 全部比对逻辑，mutation
    字符串为语法审查 + R3 兜底门）：**

    ```bash
    # R0 身份与工具（输出须为 lvye / jq-1.7.1-apple）
    gh api user --jq .login
    jq --version
    OUT=~/mpf001-out && mkdir -p "$OUT" && cd "$(git rev-parse --show-toplevel)"
    IN=openspec/changes/chg-2026-038-main-protection-merge-friction/evidence/runs/TASK-MPF-001/inputs
    # R1 输入工件 + before 复测（哈希逐一命中 pins；任一不符 → 停，零写入）
    shasum -a 256 "$IN"/mpf_projection.jq "$IN"/mpf_gql_projection.jq "$IN"/mpf_delta.jq
    gh api repos/ArkDeck/ArkDeck/branches/main/protection > "$OUT/r2.before.rest.json"
    shasum -a 256 "$OUT/r2.before.rest.json"
    jq -S -c -f "$IN/mpf_projection.jq" "$OUT/r2.before.rest.json" > "$OUT/r2.before.rest.projection.json"
    shasum -a 256 "$OUT/r2.before.rest.projection.json"
    gh api graphql -f query='{repository(owner:"ArkDeck",name:"ArkDeck"){branchProtectionRules(first:10){nodes{pattern allowsForcePushes lockBranch bypassForcePushAllowances(first:10){totalCount nodes{actor{__typename ... on User{login}}}}}}}}' > "$OUT/r2.before.gql.json"
    jq -S -c -f "$IN/mpf_gql_projection.jq" "$OUT/r2.before.gql.json" > "$OUT/r2.before.gql.projection.json"
    shasum -a 256 "$OUT/r2.before.gql.projection.json"
    gh api repos/ArkDeck/ArkDeck/rulesets/19595282 > "$OUT/r2.ruleset.before.json"
    shasum -a 256 "$OUT/r2.ruleset.before.json"
    # R2 唯一写入（仅 lvye 亲手；GraphQL errors = 原子失败零变更，停并贴回）
    gh api graphql -f query='mutation{updateBranchProtectionRule(input:{branchProtectionRuleId:"BPR_kwDOTWtevs4Extgh",bypassForcePushActorIds:[]}){branchProtectionRule{allowsForcePushes bypassForcePushAllowances(first:10){totalCount}}}}' > "$OUT/r2.mutation.response.json"
    # R3 双面 read-back（GraphQL projection == 241b9160…；REST projection == 4046aced…；delta 恰一元；七元组；REST 全量哈希如实记录不 pin）
    gh api graphql -f query='{repository(owner:"ArkDeck",name:"ArkDeck"){branchProtectionRules(first:10){nodes{pattern allowsForcePushes lockBranch bypassForcePushAllowances(first:10){totalCount nodes{actor{__typename ... on User{login}}}}}}}}' > "$OUT/r2.after.gql.json"
    jq -S -c -f "$IN/mpf_gql_projection.jq" "$OUT/r2.after.gql.json" > "$OUT/r2.after.gql.projection.json"
    shasum -a 256 "$OUT/r2.after.gql.projection.json"
    gh api repos/ArkDeck/ArkDeck/branches/main/protection > "$OUT/r2.after.rest.json"
    shasum -a 256 "$OUT/r2.after.rest.json"
    jq -S -c -f "$IN/mpf_projection.jq" "$OUT/r2.after.rest.json" > "$OUT/r2.after.rest.projection.json"
    shasum -a 256 "$OUT/r2.after.rest.projection.json"
    jq -n -c --slurpfile a "$OUT/r2.before.rest.projection.json" --slurpfile b "$OUT/r2.after.rest.projection.json" -f "$IN/mpf_delta.jq" | tee "$OUT/r2.delta.json"
    jq -c '[.required_pull_request_reviews.required_approving_review_count, .required_pull_request_reviews.require_code_owner_reviews, .enforce_admins.enabled, (.restrictions.users|map(.login)), .required_linear_history.enabled, (.required_status_checks.checks|map(.context)), .allow_deletions.enabled]' "$OUT/r2.after.rest.json"
    # R4 ruleset 前后逐字节一致（cmp 沉默 + UNTOUCHED）
    gh api repos/ArkDeck/ArkDeck/rulesets/19595282 > "$OUT/r2.ruleset.after.json"
    cmp "$OUT/r2.ruleset.before.json" "$OUT/r2.ruleset.after.json" && echo RULESET-UNTOUCHED
    # R5 receipts 汇总（贴回转录）
    shasum -a 256 "$OUT"/r2.*
    # R6 触发限定：仅当 after GraphQL projection ≠ 241b9160…（目标态未达成/错态）
    # 或七元组/ruleset 门变化时 rollback（重加 lvye actor；read-back 双面 ==
    # before 投影 dea8a6d0…/0df7bc6a…；随后记 blocked-attempt）。
    # 若 GraphQL == 目标态而仅 REST 渲染门 FAIL → 零写入、停、如实记
    # （Expected after 条款）、禁止 rollback——回滚会重加白名单、主动退出
    # 已达成的语义目标态
    gh api graphql -f query='mutation{updateBranchProtectionRule(input:{branchProtectionRuleId:"BPR_kwDOTWtevs4Extgh",bypassForcePushActorIds:["MDQ6VXNlcjQzNDAxNjE="]}){branchProtectionRule{bypassForcePushAllowances(first:10){totalCount}}}}' > "$OUT/r2.rollback.response.json"
    gh api graphql -f query='{repository(owner:"ArkDeck",name:"ArkDeck"){branchProtectionRules(first:10){nodes{pattern allowsForcePushes lockBranch bypassForcePushAllowances(first:10){totalCount nodes{actor{__typename ... on User{login}}}}}}}}' | jq -S -c -f "$IN/mpf_gql_projection.jq" | shasum -a 256
    gh api repos/ArkDeck/ArkDeck/branches/main/protection | jq -S -c -f "$IN/mpf_projection.jq" | shasum -a 256
    ```

  - **Flow observation 与 evidence deliverables:与 r1 条款同**——
    `MPF-FLOW-001` 两观测在 `MPF-DELTA-001` PASS 后如实取首两个满足载体
    （预期 = attempt#2 evidence PR 与 done PR，不绑死）；`lvye` 贴回 `$OUT`
    receipts → Agent 起草 run.md **attempt#2 追记**（同文件追加，不改写
    attempt#1）→ 独立 done PR。失败路径：R6 后 run.md 记 blocked-attempt，
    任务退 blocked 重 readiness。
  - **Concurrency/absence:closed at drafting（2026-07-26）。**remote
    `agent/*mpf*` 分支除本 carrier 外 = 0；无其他 in-flight PR 触碰本 change
    目录。
- Historical Status:ready（r1 execution readiness = #576 merge
  `66a70e2a3dc7338be3cd02f9b5ddb4a1dc1ba236`；其 S0–S7 契约与 pins 见下方
  Readiness（r1）段，作历史记录保留；r1 的一次性 PUT 授权已于 attempt#1 消耗。）
- Historical Status:blocked（前置：① 本 change approval-only PR merge；② 独立
  readiness PR 钉定 before 状态的两个 SHA-256、after 期望 projection SHA-256、
  逐步命令与 rollback。**执行者恒为 `lvye`，在 Agent 不可达的会话内亲手执行；
  Agent 零 protection 写入。**① = #575 merge
  `1609b4d5d185410da8d3245efcd5b5a86ccc8d8c`；② = 本 r1。）
- Readiness（r1；audit base = protected `main`
  `1609b4d5d185410da8d3245efcd5b5a86ccc8d8c`）：
  - **Approval boundary:pending human merge。**本 carrier 只修改本文件并新增本
    change `evidence/runs/TASK-MPF-001/inputs/` 三个窗口输入工件。只有 `lvye`
    对 exact head APPROVED、required checks terminal success、`mergedBy=lvye`、
    `auto_merge=null` 且 squash subject 携 `(#N)` 的 merge OID 进入 protected
    main 后，本 readiness 才生效。
  - **Dependency gate:closed。**propose #574 merge
    `aa6b447ceb38585a56b506ee571362f91dccb73a`、approval #575 merge
    `1609b4d5d185410da8d3245efcd5b5a86ccc8d8c`，均 `lvye` APPROVED、
    `auto_merge=null`、audit-base ancestors。
  - **Before-state pins:closed（2026-07-26 authenticated GET 实测，读取身份
    `lvye`，Agent 只读零写入）。**执行窗 S1/S2 任一与下列不符 → 零写入、停、
    重 readiness（proposal Notes 条款）：
    - `main` protection full-GET（2941 bytes）SHA-256 =
      `120faf45d9aaaf8973df91f81ce7703c2476a07554ba1752bcf9e618975d5fd1`；
    - canonical projection（`mpf_projection.jq` 定义，`jq -S -c` 正规化）
      SHA-256 =
      `a8cff4489e2776dfdd552887e290bb8d695fc601ae9e804b6bf496aee60b59d8`；
    - ruleset `19595282` full-GET（744 bytes）SHA-256 =
      `c404036f4e78b09960cc7a1705cdf8c5160f08e7baa577cb439350e2fdb31267`；
    - 工具谱系：`jq-1.7.1-apple`（/usr/bin/jq）、`shasum -a 256`；full-GET pin
      若因 GitHub 响应包络演化失配而 projection 仍配，同样 fail-closed 零写入
      重 readiness，不做现场豁免。
  - **Window inputs:committed & pinned。**本 PR 将三个输入工件入库
    `evidence/runs/TASK-MPF-001/inputs/`，执行窗 S1 先验哈希再使用：
    - `mpf_projection.jq` SHA-256 =
      `c1e3e61dbd6ab43340d649a81d8441606dbf1914fe1987addb777e81a410aed8`
      （canonical projection 定义：剥离全部 `url` 装饰字段、user/team/app 各取
      `{login|slug, id}`、其余语义字段全收录——投影覆盖 full-GET 全部语义面）；
    - `put-after.json` SHA-256 =
      `7dee7f6244ed4057143a26f04e77a6e70036f6f4897320acf2c1428b197cb7b9`
      （after 全量 PUT body：恰好三项翻 false，信任根七项与其余字段按 before
      原值重申；`dismissal_restrictions` 以空集合原样回写以保持 GET 渲染不变，
      平台「空对象=禁用/空集合=启用但空」语义含混为已记录面，S4 投影相等门
      捕获任何渲染变化；`required_signatures` 不在 PUT body 内、由独立子端点
      管理，本窗口不触碰）；
    - `put-rollback.json` SHA-256 =
      `08841850389c66fc525cb8f74f04c0aae2fa022fac80fefe1ae030e657140e04`
      （rollback PUT body = before 三项原值 true，其余与 put-after 同）。
  - **Expected after:closed（确定性推导 + host 侧实测）。**expected after
    projection = before 快照三项语义翻转后过同一投影，SHA-256 =
    `4046aced77a6ff040ea6789b6edf96a80e288ae6ef144d9d89a85b76a336d2dc`；
    S5 delta 证明必须逐字节等于（jq `-c` 单行）：

    ```json
    [{"path":"allow_force_pushes","before":true,"after":false},{"path":"required_pull_request_reviews.dismiss_stale_reviews","before":true,"after":false},{"path":"required_status_checks.strict","before":true,"after":false}]
    ```

    信任根七元组（S5 于 after 全量 GET 上重证，S4 投影相等已蕴含）：
    `[1,true,true,["lvye"],true,["guard"],false]`
    （= review count、CODEOWNER、enforce_admins、push users、linear、required
    checks、allow_deletions）。
  - **Window contract（S0–S7；mutation 仅 S3/S7 且仅 `lvye` 亲手；Agent 已于
    before 快照 + 模拟 after 上 host 侧自测 S1/S2/S4/S5/S6 全部比对逻辑）：**

    ```bash
    # S0 身份与工具（输出必须分别为 lvye / jq-1.7.1-apple）
    gh api user --jq .login
    jq --version
    OUT=~/mpf001-out && mkdir -p "$OUT" && cd <ArkDeck checkout root>
    IN=openspec/changes/chg-2026-038-main-protection-merge-friction/evidence/runs/TASK-MPF-001/inputs
    # S1 输入工件完整性（三行哈希须逐一命中 pins；任一不符 → 停，零写入）
    shasum -a 256 "$IN"/mpf_projection.jq "$IN"/put-after.json "$IN"/put-rollback.json
    # S2 before 双向取证（三个哈希须命中 pins；任一不符 → 停，零写入，重 readiness）
    gh api repos/ArkDeck/ArkDeck/branches/main/protection > "$OUT/before.live.json"
    shasum -a 256 "$OUT/before.live.json"
    jq -S -c -f "$IN/mpf_projection.jq" "$OUT/before.live.json" > "$OUT/before.live.projection.json"
    shasum -a 256 "$OUT/before.live.projection.json"
    gh api repos/ArkDeck/ArkDeck/rulesets/19595282 > "$OUT/ruleset.before.live.json"
    shasum -a 256 "$OUT/ruleset.before.live.json"
    # S3 唯一写入（仅 lvye 亲手；此后任何门失败 → 直接 S7）
    gh api -X PUT repos/ArkDeck/ArkDeck/branches/main/protection --input "$IN/put-after.json" > "$OUT/put.response.json"
    # S4 after read-back（after.live.json 哈希如实记录不 pin；projection 哈希须 == expected 4046aced…）
    gh api repos/ArkDeck/ArkDeck/branches/main/protection > "$OUT/after.live.json"
    shasum -a 256 "$OUT/after.live.json"
    jq -S -c -f "$IN/mpf_projection.jq" "$OUT/after.live.json" > "$OUT/after.live.projection.json"
    shasum -a 256 "$OUT/after.live.projection.json"
    # S5 逐字段 delta 证明（输出须逐字节 == 钉定三元 delta）+ 信任根七元组重证
    jq -n -c --slurpfile a "$OUT/before.live.projection.json" --slurpfile b "$OUT/after.live.projection.json" '[($a[0]|paths(scalars)) as $p | select(($a[0]|getpath($p)) != ($b[0]|getpath($p))) | {path:($p|map(tostring)|join(".")), before:($a[0]|getpath($p)), after:($b[0]|getpath($p))}]' | tee "$OUT/delta.json"
    jq -c '[.required_pull_request_reviews.required_approving_review_count, .required_pull_request_reviews.require_code_owner_reviews, .enforce_admins.enabled, (.restrictions.users|map(.login)), .required_linear_history.enabled, (.required_status_checks.checks|map(.context)), .allow_deletions.enabled]' "$OUT/after.live.json"
    # S6 ruleset 19595282 前后逐字节一致（沉默即相等；随后打印 UNTOUCHED）
    gh api repos/ArkDeck/ArkDeck/rulesets/19595282 > "$OUT/ruleset.after.live.json"
    cmp "$OUT/ruleset.before.live.json" "$OUT/ruleset.after.live.json" && echo RULESET-UNTOUCHED
    # S7 仅失败时 rollback（read-back projection 哈希须 == before a8cff448…；随后记 blocked-attempt）
    gh api -X PUT repos/ArkDeck/ArkDeck/branches/main/protection --input "$IN/put-rollback.json" > "$OUT/rollback.response.json"
    gh api repos/ArkDeck/ArkDeck/branches/main/protection | jq -S -c -f "$IN/mpf_projection.jq" | shasum -a 256
    ```

  - **Flow observation（`MPF-FLOW-001`，窗口成功后，零额外机制）：**①首个自然
    PR 以单命令 `gh pr review <N> --approve && gh pr merge <N> --squash
    --delete-branch` 完成且审计四件套完整（`lvye` APPROVED @ exact head、
    `mergedBy=lvye`、`auto_merge=null`、squash subject 携 `(#N)`）；②main 前进
    后另一 in-flight 已 approve PR **无需** `Update branch` 合入且 approval 未
    作废。预期天然载体 = 本任务 evidence PR 与 done PR（不绑死，如实取首两个
    满足观测的 PR）；补偿控制条款（Agent 请求 merge 前 rebase 到最新
    `origin/main` + 合成树全量套件，今日 25 载体先例）写入 run.md。
  - **Evidence deliverables:**`lvye` 贴回 `$OUT` 全部 receipt → Agent 起草
    `evidence/runs/TASK-MPF-001/run.md`（before/after full-GET 全文、双
    projection、delta.json、七元组、ruleset cmp、put.response、flow 两观测、
    补偿控制条款）→ 独立 done PR。失败路径：S7 后 run.md 记 blocked-attempt
    （#104/#173 先例），任务退 blocked 重 readiness。
  - **Concurrency/absence:closed at drafting（2026-07-26）。**remote
    `agent/*mpf*` 分支 = 0；无其他 in-flight PR 触碰本 change 目录。
- Platform:macos（GitHub 设置面；零产品/设备声明）
- Requirements/AC:change-local `MPF-DELTA-001`、`MPF-FLOW-001`
- Depends on:none
- In scope:`main` branch protection 的恰好三项 delta（`dismiss_stale_reviews`
  →false、`required_status_checks.strict`→false、`allow_force_pushes`→false）；
  执行前后 authenticated 全量 GET 与两类 SHA-256 比对；单命令合并流与 strict
  关闭后补偿控制的 evidence 记录。
- Out of scope:任何信任根开关（review count/CODEOWNER/enforce_admins/push
  restrictions/linear/required `guard`）；ruleset `19595282`；Deploy Key/App/
  凭据/任何其他 repository setting；`allow_deletions`/`block_creations`/
  `required_conversation_resolution`；auto-merge；governance 正文；
  Agent 执行 protection 写入。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`（仅本任务状态/
  evidence 引用）。
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`.github/**`、`scripts/**`、产品 source/tests、
  其他 change。
- Risk:low-medium（见 proposal「Risk」；只放宽两项摩擦开关、只收紧一项漂移，
  信任根零改动）。
- Hardware required:no。
- Decision-Grade:D2。

### Deliverables

- 一次由 `lvye` 亲手执行的 protection 窗口，产出 before/after 双向 authenticated
  取证（full-GET 与 canonical projection 各两个 SHA-256）与逐字段 delta 证明；
- 单命令合并流（`gh pr review --approve && gh pr merge --squash`）在真实 PR 上
  的一次实证；
- strict 关闭后的补偿控制条款如实入档（Agent 请求 merge 前 rebase + 合成树
  全量套件，已实证 25 次）。

### Verification

- `MPF-DELTA-001`：after projection 与 readiness 钉定的期望 projection SHA-256
  逐字节相等；逐字段比对显示**恰好三项**变化，信任根七项（review count 1、
  CODEOWNER true、enforce_admins true、push users `[lvye]`、linear true、
  required check `guard`、allow_deletions false）前后完全一致；ruleset
  `19595282` 未被触碰（独立 GET 比对）。
- `MPF-FLOW-001`：一个真实 PR 以单命令流完成 approve+merge，且其审计记录完整
  （`lvye` APPROVED @ exact head、`mergedBy=lvye`、`auto_merge=null`、squash
  subject 携 `(#N)`）；main 前进后另一个 in-flight PR **无需** `Update branch`
  即可合入，approval 未被作废。

### Notes / handoff

- rollback = 以 before 值反向 PUT 三项并 read-back 复验 before projection
  SHA-256；PEM/App/Deploy Key/ruleset/其他 setting 一律不动。
- **r2 注记（2026-07-26）**：本条 REST 反向 PUT rollback 仅属 r1 窗口历史——
  attempt#1 已证其 read-back 无法证明语义还原（见 run.md）；r2 窗口的 rollback
  = GraphQL 重加 `lvye` actor + 双面投影 read-back（见 Readiness（r2）R6）。
- 本任务的 `Decision-Grade` 行由维护者亲手撰写（r1 时点尚不携带；#577 grade
  播种 commit 已由维护者标注 `D2。`）。**注意等级判定**：
  protection 写入属 D2（凭据/设置面、人类执行），不是 D0——即使标了 grade 也不
  应进入循环派发面，`Hardware required:no` 不代表机器可判定。
- 若执行期发现 before 状态与 readiness 钉定值不符（例如又有第三方改动），
  **零写入并重新 readiness**。
