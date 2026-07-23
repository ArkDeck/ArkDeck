# TASK-AFP-005 run record — 手册 archive 断链收口 — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-LINK-001`
- Base: `857ce32ce33931a0328cda099e203df6b005818d`（readiness #392 合入后）
- Input pins: readiness r1 carrier **12/12** 于本 base 实测复核无漂移
- Producer → consumer: 无产品链。可验证的消费面 = `git grep` 对
  `openspec/planning/**` 的实测结果与手册自身的链接解析
- Evidence currency: `current`

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR。

## Environment

macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。零外部工具、
零网络、零 secret、零设备。

## Work completed

按 readiness 的**待改行:closed**与**改法:closed**执行，改动**恰一行**。

**改前**（手册第 23–24 行）：

```text
检索。taxonomy 与其封闭范围登记在
[CHG-2026-029 design §3](../changes/chg-2026-029-agent-failure-prevention/design.md)：
```

**改后**：

```text
检索。taxonomy 与其封闭范围登记在 **CHG-2026-029 的 `design.md` §3**（revision r4，
protected `main` `d53da289b7da80a4ee2282f5dea3122ebf97325a`；该 change 归档后目录
位置会变，故此处以 change ID 与完整 OID 定位，不使用相对路径）：
```

readiness 要求保留的三项事实全部在场：① change ID `CHG-2026-029`；② 章节
`design.md §3`；③ 不随目录移动失效的定位锚 = 完整 40-hex OID
`d53da289b7da80a4ee2282f5dea3122ebf97325a`（r4 merge；该 commit 上 `design.md` §3
即 taxonomy 现行版本）。

readiness 列举的三种**禁止改法**均未采用：未改指向 `changes/archive/<date>-<id>/`、
未删除事实指向、未把 §3 内容复制进手册。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 readiness carrier 复核（12 项） | 12/12 无漂移 **PASS** |
| `git grep -c 'chg-2026-029-agent-failure-prevention' -- openspec/planning/` | 改前 1 → 改后 **0** **PASS** |
| 手册 change 链接分布 | 改前 35（10 archive + 25 active）→ 改后 **34（10 archive + 24 active）**；减少的恰为本 change 那 1 条 **PASS** |
| 三项事实指向在场 | change ID / `design.md` §3 / 完整 OID 三项均在 **PASS** |
| 不动面：`AF-NNN` ID 集合 | `AF-001`…`AF-018` 完整，不增不删不复用 **PASS** |
| 不动面：八字段契约与顺序 | H3 = 144，18 组同序 **PASS** |
| 不动面：`Automation status` 取值域 | 18 项全合法 **PASS** |
| 不动面：`Fact`/`Inference` 与方法计数 | `Fact` = 36、`Inference` = 18、positive 18、negative 18，与 AFP-004 后基线一致 **PASS** |
| 不动面：其余 34 条链接 | 逐字未改（diff 仅第 23–25 行）**PASS** |
| 手册全部链接解析 | 98 条中相对链接全解析，56 个 anchor 命中 **PASS** |
| 越界复核 | `openspec/templates/**`、`changes/archive/**`、`chg-2026-027-…/**` diff 均为 **0** **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

### 归档模拟复核

按 readiness 的"断链复核"要求：本 change 目录未来 `git mv` 到
`openspec/changes/archive/<date>-chg-2026-029-agent-failure-prevention/` 后，手册
对该目录的引用数为 **0**（改后实测），故**不存在可断项**。改前该数为 1，即改前
归档必断。

## AC conclusion

- `AFP-LINK-001`: **passed**（documentReview）。手册对本 change 目录的相对路径引用
  归零，taxonomy 的事实指向以不依赖目录位置的形式保留；ID 集合、taxonomy 归属与
  两轴划分、八字段契约与顺序、`Automation status` 取值域、首屏声明、
  `Fact`/`Inference` 标注与 positive/negative 计数全部零变化；其余指向活跃 change
  的 24 条链接逐字不动并登记为已知限制；模板、archive 与 chg-2026-027 目录
  diff 为零。

## 已知限制（登记备查，不在本任务修复）

手册仍有 **24 条**指向 8 个活跃 change（chg-006/008/021/022/025/026/028）的相对
链接与 **10 条**指向 `changes/archive/**` 的链接。后者路径稳定；**前者在各自 change
归档时会断链**。根因是"长期存活的索引用相对路径引用会移动的目录"，与本任务修复的
是同一类问题，但跨 change，须另立 change 统一处置（例如统一改为 change ID + 完整
OID 形式）。本任务按 readiness 的不动面条款逐字保留，不顺手扩围（`AF-001` 的
"不顺手修"条款）。

## Deviations and residual risk

- **Deviation:无。**改动与 readiness 封闭的待改行、改法、不动面逐项一致。
- **Dated 注记（2026-07-23）——跨 lane 现状再更新，不改写 readiness 原文。**
  本 run 起草期复核 `origin/main` `857ce32c…` 发现 CHG-2026-027 lane 已推进两步，
  与本 change 的既有登记有出入，如实记录：
  1. **BAP-002 readiness r4**（#391 合入 `9859384…`）声明其 r2 的 15 项
     authority/input pins **随实现合入完成使命退役**，并明确记载"drill 阶段不再以
     兄弟 lane 高频文件为 authority pin"，理由是该类 pin 结构性易碎（其 r3 重钉的
     `dc812977…` 已被本 change r4 再次打漂为 `6211712d…`）。
  2. **候选 2′（`CHG-2026-029` verify）已被该 lane 宣告失效**——成因是本 change r4
     新增 `TASK-AFP-005`（blocked）并升 `verification @r4`，使"四任务全 done 即
     verify"前提不再成立。候选 2 改为**规则钉定**：候选 1 之后最先天然产生且入队
     三门齐备的 D0 状态推进 PR；该 lane 明确把 **`TASK-AFP-005 ready→done`** 列为
     在途可能来源之一（仅导航，不构成限定）。
  **对本 change 的影响**：① 本任务的 `ready→done` PR 可能成为该 lane 的候选 2″，
  故起草时须留在 open 队列、不催合，并在记录中注明可能的候选身份；② 本 change 的
  archive 阻断理由需重新评估——r4 登记的阻断依据是"BAP-002 pin 指向本 change 路径，
  archive 会使其不可解析"，而该 lane r4 已声明该类 pin 退役；但其 `yaml pins`
  carrier 中的条目文本仍在（`chg-2026-027…/tasks.md:157-158`，值仍为
  `bbbda9b9…`）。**该评估不在本任务授权面内**，留给 change 级 verify 或 archive
  起草时按当时事实判断，本 run 只记录指针。
- **Residual risk 1 — OID 锚点的语义**：改后文本以 r4 merge OID 定位。该 OID 固定
  且可解析，但读者需自行用 `git` 定位文件；相较相对链接牺牲了点击可达性，换取
  归档后不失效。这是 readiness 封闭改法的既定取舍。
- **Residual risk 2 — 24 条活跃链接**：见上节已知限制，另立 change。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；真实硬件 = **无**。
