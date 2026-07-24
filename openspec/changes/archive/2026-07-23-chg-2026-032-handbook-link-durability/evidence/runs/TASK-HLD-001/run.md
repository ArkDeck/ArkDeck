# TASK-HLD-001 run record — 活跃 change 引用改为耐久形式 — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `HLD-DURABLE-001`
- Base: `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06`（readiness #439 合入后）
- Input pins: readiness r1 carrier **23/23** 于本 base 实测复核无漂移；六个目标
  change 于开工时逐个确认**仍活跃**（均未归档）
- Producer → consumer: 无产品链。可验证消费面 = `git grep`/链接解析对手册的实测结果
- Evidence currency: `current`

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR。

## Environment

macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。零外部工具、
零网络、零 secret、零设备。

## Work completed

按 readiness 的**待改清单:closed**（19 条）与**改法:closed**执行。逐条对照表见
[`link-inventory.md`](link-inventory.md)（脚本生成，含每条的 AF 项、目标 change、
change 目录内路径、完整 40-hex 定位 blob 与所采用的括号形式）。

### 改法与其两种落地形态

统一形态：去掉 `](../changes/...)` 相对链接，保留 change ID + change 目录内路径 +
完整 blob OID。实际落地时按原链接文字是否已含信息分两种：

| 形态 | 条数 | 样例 |
| --- | --- | --- |
| **ID + 路径 + blob**（原文字未含 change ID） | 8 | ``TASK-RKFUI-001 `run.md`（CHG-2026-026 `evidence/runs/TASK-RKFUI-001/run.md`，blob `0f24bb…`）`` |
| **仅 blob**（原文字已含 change ID 与文件名） | 11 | ``CHG-2026-006 `tasks.md`（blob `779ff6…`）`` |

第二种是起草期发现的**冗余修正**：首版改写机械地在括号内重复 change ID 与文件名，
产生 “CHG-2026-006 `tasks.md`（CHG-2026-006 `tasks.md`，blob …）” 这类读两遍的文本，
11 条命中。改为在原文字已含 ID + 文件名时括号内只留 blob。三项事实指向在两种形态
下都完整（第二种由原文字承担 ID 与路径两项）。

readiness 列举的**四种禁止改法**均未采用：未改指向预期 `changes/archive/<date>-<id>/`
路径、未删除任何事实指向、未把被引用内容复制进手册、未改动任何案例的事实文字。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 readiness carrier 复核（23 项） | 23/23 无漂移 **PASS** |
| 开工前六个目标 change 活跃性 | 6/6 仍在 `openspec/changes/`，均未归档 **PASS** |
| 活跃 change 相对链接计数 | 19 → **0** **PASS** |
| `changes/archive/**` 类链接计数 | 16 → **16**，内容逐字未改 **PASS** |
| 新增 blob OID | 11 个唯一值，`git cat-file -e` 逐个可解析，**0 不可解析** **PASS** |
| 逐条对照表 | 19 行齐备，每行含 AF 项/目标/路径/完整 40-hex blob/形态 **PASS** |
| 不动面：`AF-NNN` ID 集合 | `AF-001`…`AF-018` 完整 **PASS** |
| 不动面：八字段契约与顺序 | H3 = 144，18 组同序 **PASS** |
| 不动面：`Automation status` 取值域 | 18 项全合法 **PASS** |
| 不动面：`Fact`/`Inference`/方法计数 | `Fact` 36 / `Inference` 18 / positive 18 / negative 18 **PASS** |
| 不动面：`Currency` 行 | 18 行逐字未改 **PASS** |
| 剩余链接解析 | 全解析，56 个 anchor 命中，FAIL = 0 **PASS** |
| **归档模拟（6 个活跃 change 逐个）** | chg-006/008/022/025/026/028 各 **0 条可断项** **PASS** |
| 越界复核 | `openspec/templates/**`、`changes/archive/**` diff 均为 **0** **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

### OID 取值纪律

11 个 blob 全部由 `git rev-parse HEAD:<path>` 在 implementation base 实测取得，
取值命令记于 `link-inventory.md`。**无一由短 hash 补全为 40 位**——该形态是
`AF-016` 的已知复发实例（CHG-2026-029 期间发生过），readiness 已将其列为二值门。

## AC conclusion

- `HLD-DURABLE-001`: **passed**（documentReview）。手册中指向活跃 change 的相对链接
  计数为 0；19 条逐条处置且对照表记录原目标、路径、定位 OID 与取值命令；每条改后
  文本保留可唯一定位的事实指向且含可解析的完整 40-hex OID；archive 类 16 条计数与
  内容零变化；不动面逐项零变化；六个被引用活跃 change 的归档模拟下均无可断项；
  模板与 archive diff 为零。

## Deviations and residual risk

- **Deviation（起草期自纠，如实记录）**：首版改写在括号内机械重复 change ID 与
  文件名，11 条产生重复文本。已改为按原文字内容分两种形态，三项事实指向在两种
  形态下均完整。该修正不改变 readiness 封闭的改法实质（仍是"去相对链接、保留 ID +
  路径 + OID"），只消除冗余表述。
- **Residual risk 1 — 点击可达性**：耐久形式牺牲相对链接的点击跳转，读者需用
  `git cat-file -p <blob>` 或按 change ID 检索定位。这是 CHG-2026-029 TASK-AFP-005
  已确立、本 change design §3 沿用的既定取舍。
- **Residual risk 2 — blob 指向历史版本**：blob OID 固定指向**本 base 时的内容**；
  被引用文件后续修订不会反映到手册。这正是"耐久"的代价与目的——引用的是当时被
  引用的事实，而非随后演化的文件。若某案例结论被后续记录 supersede，仍按
  `AF-005` 在事实原位更新，属未来任务而非本任务。
- **Residual risk 3 — 仓内其他文件**：本 change 只覆盖该手册；仓内其他文件若有
  同类跨 change 相对引用，不在本 change 范围（proposal 明列 out of scope）。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；真实硬件 = **无**。
