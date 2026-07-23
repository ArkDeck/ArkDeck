# TASK-AFP-004 run record — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `AFP-CORRECT-001`
- Base: `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`（readiness #372 合入后）
- Input pins: readiness r1 carrier **39/39** 于本 base 实测复核无漂移（含手册 blob
  `5b8c3b6b26b76893744aa11bdd7618318eab4674` 与 26 个一手出处文件）
- Producer → consumer: 本任务的"consumer"是复核脚本对手册 `Observed cases` 的
  逐行解析，"producer"是 26 个 pinned 一手出处的 bytes；两端在同一 base 上直接比对，
  无中间转述层——**本 change 自身的 `design.md`/`proposal.md` 未被用作出处**（该来源
  正是 r3 所修缺陷的成因）。
- Evidence currency: `current`（精确绑定本 PR 提交的手册 bytes）

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR；本记录不构成 change `verified`。

## Environment

- macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。
- 零外部工具、零网络、零 secret、零设备。复核脚本在仓库外 scratchpad 执行。

## Work completed

对手册 `AF-001`…`AF-018` 的全部 **37 条 `Fact`** 逐条一手复核（清单计数与 readiness
登记值一致：37 行，其中 5 行无内联链接）。判定结果：

| 判定 | 行数 |
| --- | --- |
| `supported`（保留原文） | **33** |
| `partially-supported`（改写为出处能支持的表述） | **3**（F09、F14 与 F07 之一并入下表） |
| `unsupported`（删除，无任何一手出处） | **1** |

处置后 `Fact` 由 37 行变为 **36 行**；`Inference` 保持 **18 行**，无一行被误标为
`Fact`（逐项检查）。

### 需要处置的 4 行（其余 33 行 `supported`，原文保留）

| 行 | 项 | 原表述（摘） | 一手复核 | 判定 | 处置 |
| --- | --- | --- | --- | --- | --- |
| F07 | `AF-004` | RKFUI-001 `run.md` "记录同一失败态被两侧实现分类不一致、单一输出上限字段被两种解释消费、修复时显式指定权威侧" | 该 run.md 中**无**任何一侧分类不一致或输出上限双解释的记载（`permissionDenied`/`maximumOutputBytes` 零出现）；该表述来自会话期 review，非 pinned bytes | `unsupported`（作为该出处的断言） | **改写**为出处实证：同一 E0 面存在 Swift 与 Python 两侧契约套件并各自跑通，且 receipt schema 与 `probe.py` 直接输出对齐 |
| F09 | `AF-005` | 同 run.md "记录 review 的检查路径：receipt key 集对照生成代码输出形状、枚举字段值对照代码枚举 `rawValue`" | run.md 记载的是 receipt **由人手从原始信封转录**、schema 与本 commit `probe.py` 输出对齐、下次 E0 直接由 `probe.py` 生成；**无** key 集/`rawValue` 对照法（`rawValue` 零出现） | `partially-supported` | **改写**为上述三条实证表述 |
| F14 | `AF-008` | 四份 remediation "**依次**暴露路径替换、typed write boundary、rename 与 unknown outcome、FIFO 与 writer-lock/identity" | 面的集合成立，但"依次（每轮各一）"不成立：FIFO/non-regular 在 **round 3**；writer-lock/identity 与路径替换在**初轮与 round 4**；`unknown` 相关表述在初轮至 round 3；round 4 无 `unknown` | `partially-supported` | **改写**为"跨轮反复出现而非每轮各一"，并逐面标出实际所在轮次 |
| F36 | `AF-018` | 同 run.md "记录分支被其他会话工作树占用时的处置" | 该 run.md **零命中**；全仓搜索显示该表述的唯一出现处就是手册自身，无任何一手出处 | `unsupported` | **删除**该行（`AF-018` 的 `Fact` 由 3 行减为 2 行，F35 文件级分工与 F37 dated observation 均 `supported`） |

四行的共同来源均为跨会话记忆而非 pinned bytes——与 r3 所修的 `AF-014` 缺陷同源
（`AF-016`）。

### Currency

18 项 `Currency` 统一更新为本次复核基线 `e48673fbe8c8440d7e12dbfe6aea5e94f996a4e2`
与 `2026-07-23`；首批基线 `de6b79aafa95700297a94dc311e94b1283f8abdd` 的记录按
`AF-005` **保留不追溯改写**。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 readiness carrier 复核（39 项） | 39/39 无漂移 **PASS** |
| `Fact` 计数复现 | 37 行 / 其中 5 行无内联链接，与 readiness 登记值一致 **PASS** |
| 逐行一手核对（37 行 × 五列） | 33 `supported` / 3 `partially-supported` / 1 `unsupported`，无遗漏行 **PASS** |
| `Inference` 误标检查 | 18 行，误标为 `Fact` = 0 **PASS** |
| Invariants：`AF-NNN` ID 集合 | H2 = 18，恰 `AF-001`…`AF-018`，不增不删不复用 **PASS** |
| Invariants：八字段契约与顺序 | H3 = 144，18 组同序 **PASS** |
| Invariants：`Automation status` 取值域 | 18 项全部合法 **PASS** |
| Invariants：positive/negative 方法 | 18 + 18 = 36 **PASS** |
| 符号级复扫 | 手册内 3 个符号，不可解析 = `semanticReview`/`partiallyMechanized`（本 change 自定义取值域，r3 已确认边界）**PASS** |
| 相对链接与 anchor | 98 条全解析（含 56 anchor；较前少 1 条 = F36 删除）**PASS** |
| 完整 40-hex OID | 21 枚全部在 ancestry **PASS** |
| `changes/archive/**` 与 `openspec/templates/**` diff | 0 / 0 **PASS** |
| allowed/forbidden path audit | diff 仅手册 + 本 change `evidence/**` + `tasks.md` **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

### 复核方法的证伪能力

needle 命中法本身会产生假阴性，本 run 未把"未命中"直接判为 `unsupported`：
5 行未命中中，**F12 经回源确认 `supported`**——源以英文 `one-byte tamper of bundled
registry.yaml → FAILS as intended` 表述，而 needle 用了中文"一字节"。其余 4 行才在
回源阅读后判定需处置。该反例证明本次判定不是"扫描说红就改"。

## AC conclusion

- `AFP-CORRECT-001`: **passed**（documentReview）。37 条 `Fact` 全部匹配到一手出处
  并给出 supported/unsupported 判定；不被支持的具体表述已改写为出处能支持的表述
  或整行删除，每处均记判定依据；`Inference` 未被误标；ID 集合、taxonomy 归属、
  八字段契约、`Automation status` 取值域与两轴划分零变化；符号级复扫通过；
  `Currency` 已更新；archive 与模板 diff 为零。

本 run 不主张 `AFP-HANDBOOK-001`/`AFP-TEMPLATE-001`（已分别于 AFP-001/002 达成）或
`AFP-DRILL-001`（AFP-003 仍待 readiness r2）的任何结论。

## Deviations and residual risk

- **Deviation（范围内的行数变化）**：`AF-018` 的 `Fact` 由 3 行减为 2 行（F36 删除）。
  readiness 的 invariants 未要求 `Fact` 行数不变，只要求 ID 集合/字段契约/取值域/
  两轴划分零变化，四者均已实测零变化；删除属方法 ④ 的合法处置且记有依据。
- **Residual risk 1 — 复核粒度**：本次判定基于"出处 bytes 是否支持该表述"，不判断
  被引用 change 的结论本身是否正确；若某出处自身有缺陷，本任务只记指针不修复
  （本次未触发该情形）。
- **Residual risk 2 — 散文级残留**：needle + 回源阅读能覆盖可检索的具体断言，但
  无法机械穷尽所有措辞强度问题（如"记录"与"证明"的区别）。该限制如实记录，
  未引入 parser/CI（属 proposal 明列 out of scope）。
- **Residual risk 3 — 未来漂移**：一手出处后续被修订时，本次 `supported` 判定不
  自动继续成立；`Currency` 记录了判定基线以便复查。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；真实硬件 = **无**。
