# TASK-AFP-001 run — 非权威 Agent 失败模式手册 — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-HANDBOOK-001`
- Date: 2026-07-23（Asia/Shanghai）；executor: `agent`（host-only）
- Base: protected `main` `b2571fa6e30cf00594869c365c10d48946a8c9f6`（#359 合入后）。
  起草起点为 `2f0c53e2924382bdf051c4975d1ed35b4ffd042d`（readiness r2 #357 合入后）；
  起草期间 `main` 前进一次，本 run 已在新 base 上重跑全部门（见 Deviations）
- Readiness: r2，audit base `de6b79aafa95700297a94dc311e94b1283f8abdd`
- 交付物 blob: `openspec/planning/agent-failure-patterns.md`
  `5b8c3b6b26b76893744aa11bdd7618318eab4674`

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR；本记录不构成 change `verified`，
> 也不构成任何批准、授权或平台/硬件支持声明。

## Environment

- macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`（PyYAML 可用）。
- 零外部工具、零网络依赖、零 secret、零设备。审读脚本在仓库外 scratchpad 执行，
  不产生仓内写入，不作为交付物。

## Readiness 前置复核（开工前）

| 项 | 结果 |
| --- | --- |
| pins carrier 35 项逐项复核（31 blob 解析到精确值 + 4 commit 在 ancestry） | 35/35 OK，0 drift |
| 目标路径 `openspec/planning/agent-failure-patterns.md` 在 base 不存在（零路径碰撞） | 确认不存在 |
| Environment/concurrency gate：审读时 GitHub open PR = 0 | 0 |
| Approval gate：change `approved` + `revision: 2` 已在 protected `main` 生效 | 满足 |

## Work completed

交付 `openspec/planning/agent-failure-patterns.md`，逐项对照 readiness 的
Handbook shape 与 Canonical-reference routing：

- 首屏依次声明 non-normative、权威顺序与冲突处置（冲突时忽略手册、无法裁决即
  `blocked`）、只链接不复制 evidence、隐私与 archive 只读边界；无批准/授权/支持语义。
- 恰 18 个二级标题 `AF-001`…`AF-018`，标题名逐字采用 proposal r2 taxonomy；
  两轴划分与"不维护发生次数真相数据库"写入前言。
- 每项恰 8 个三级标题，顺序为 `Signal`、`Observed cases`、`Root cause`、
  `Preflight`、`Verification`、`Canonical references`、`Automation status`、
  `Currency`。
- `AF-001`…`AF-009` 的 `Observed cases` 纳入 design §3.1 登记的子面；
  `AF-010`…`AF-018` 与 design §3.2 的根因/案例锚点一致。
- CHG-2026-028 的已覆盖面与未覆盖语义面如实标注，含 readiness 点名的两处边界：
  `AF-010` 的"canary 红反证只覆盖新 check"、`AF-016` 的"pins 校验只覆盖形状不覆盖
  来源"；另在 `AF-001`/`AF-018` 写明 allowed-paths diff 是 guard-rail 而非安全边界。

## Commands and results

| Command | Result |
| --- | --- |
| 结构审读（H2/H3 计数与字段顺序） | H2 = 18；H3 = 144；18 组字段与 design §2 八字段逐字同序 **PASS** |
| ID 唯一性与序列 | `AF-001`…`AF-018` 唯一、无缺号、无复用 **PASS** |
| positive/negative 方法计数 | positive 18 + negative 18 = **36** **PASS** |
| `Fact`/`Inference` 分离 | 38 处 `Fact` 标记、18 处 `Inference` 标记，每项至少各一 **PASS** |
| `Automation status` 取值域 | 18 项全部落在 `mechanized`/`partiallyMechanized`/`semanticReview` **PASS** |
| `Currency` 一致性 | 18 项全部记 `de6b79aafa95700297a94dc311e94b1283f8abdd` + `2026-07-23` **PASS** |
| 相对链接与 anchor 解析 | 99 条链接全部解析；其中 56 个 section anchor 按 GitHub slug 规则逐一命中目标文件真实标题 **PASS** |
| 完整 40-hex OID 审计 | 20 枚唯一 OID，全部在 `HEAD` ancestry 中 **PASS** |
| shadow-spec 扫描 | 新增 normative `SHALL`/`MUST` = 0；自动 approval/ready/done 表述 = 0；platform support 声明 = 0；hardware PASS 声明 = 0 **PASS** |
| secret/隐私扫描 | 用户绝对路径 = 0；裸 64-hex 摘要 = 0；设备序列号形态 = 0；私钥/token 形态 = 0；raw dump/trace 复制 = 0 **PASS** |
| `changes/archive/**` diff | 0 **PASS** |
| allowed/forbidden path audit | diff 仅 `openspec/planning/agent-failure-patterns.md`、本 change `evidence/**`、本 change `tasks.md`（仅 evidence 引用）；forbidden 面零触碰 **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

### 反向验证（审读脚本本身不是套套逻辑）

按 `AF-010` 的自有要求，审读脚本以变异实验证伪而非只取绿：

| 变异 | 期望 | 实测 |
| --- | --- | --- |
| 首版手册中 `AF-006` 引用 archived CHG-2026-015 目录 | 链接检查报 `MISSING FILE` | **实际报红**：日期前缀写成 `2026-07-21-…`，真实归档目录为 `2026-07-22-…`（该错误由脚本发现并已修正，非事后补记） |

该次真实红结果证明链接/anchor 检查具备证伪能力；修正后复跑 0 FAIL。

## AC conclusion

- `AFP-HANDBOOK-001`: **passed**（documentReview）。十八个 ID 唯一且八字段齐全、
  `Fact`/`Inference` 分离、每项含 positive 与 negative 方法、链接与 anchor 全解析、
  OID 与 currency 复核通过、automation status 诚实、shadow-spec 与隐私扫描为 0、
  archive 零 diff。

本 run 不主张 `AFP-TEMPLATE-001`（TASK-AFP-002）或 `AFP-DRILL-001`（TASK-AFP-003）
的任何结论，两任务保持 `blocked`。

## Deviations and residual risk

- **Deviation 1（起草期自纠，如实记录）**：首版 `AF-006` 的归档目录路径由推测写成，
  被链接检查证伪后按仓内实际路径修正。此为 `AF-016`（以记忆/推断代替一手核查）
  的实例，记录于此不改写手册中的既有条目。
- **Deviation 2（base 前移，如实记录）**：起草期间 protected `main` 由
  `2f0c53e2924382bdf051c4975d1ed35b4ffd042d` 前进到
  `b2571fa6e30cf00594869c365c10d48946a8c9f6`（#359，与本任务授权面零文件交集）。
  首次推送时 PR allowed-paths 检查因两点 diff 计入新合入文件而报红——这是 stale
  base 产物而非授权面越界。处置：rebase 到新 base 后**重跑全部二值门**（readiness
  pins 35/35 无漂移；结构、链接/anchor、OID、shadow-spec、隐私、guard 全部复现
  上表结果），而非沿用旧 base 的结论。此为 `AF-018`（多会话共享状态）的实例。
- **Residual risk 1 — 陈旧**：手册的案例结论与 automation status 会随后续 change
  漂移。缓解形态已写入 design §2：更新时保留原案例链接并更新当前处置与
  `Currency`，不改写历史 evidence。本 run 不建立自动 currency 检查。
- **Residual risk 2 — shadow spec**：手册可能被误读为规则源。缓解 = 首屏权威/冲突
  声明 + 只链接 canonical rule + 本次扫描确认零 normative 新增；该风险由后续 review
  持续承担，无机械门。
- **Residual risk 3 — anchor 脆弱性**：56 个 section anchor 依赖目标文件标题文本；
  标题改写会静默断锚。本 run 未引入 anchor 检查的 CI 门（新增 parser/CI 属
  out of scope，见 proposal）；该限制如实记录，不声称已解决。
- destructive dispatch 计数 = **0**；device/network/effect dispatch = **0**；
  真实硬件涉及 = **无**。
