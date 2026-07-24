# TASK-HLD-002 run record — 在手册内登记引用约定 — 2026-07-23

- Evidence class: `plan`（document review；零产品执行、零硬件、零 device/network dispatch）
- Core baseline: `CORE-2.1.0`（零 Core/product behavior 变更）
- Scope: change-local `HLD-CONVENTION-001`
- Base: `5f34a2aa376bd3677b69ba14410f265f1a29aaf7`（readiness #443 合入后）
- Input pins: readiness r1 carrier **12/12** 于本 base 实测复核无漂移（全路径比对）
- Producer → consumer: 无产品链。可验证消费面 = 首屏块结构与 shadow-spec 扫描的实测结果
- Evidence currency: `current`

> 本 run 不翻转任务状态。`ready→done` 使用独立 PR。本任务是本 change 最后一个任务。

## Environment

macOS；仓内 Git + Markdown；`scripts/check-sdd.sh` 经 `.venv-sdd`。零外部工具、
零网络、零 secret、零设备。

## Work completed

按 readiness 的**拟增文本:closed**与**范围扩展**（随 #443 合入被接受）执行，共两处
改动，手册 diff 为 **2 个 hunk**。

### 改动 1 — 新增首屏块「引用形式」（原定范围）

插入位置：块 ④ `**archive 只读。**` 之后、正文首段之前，恰一个新块。内容含且仅含
readiness 封闭的三点：

1. 引用**活跃 change** 用耐久形式（change ID + change 目录内路径 + 完整 40-hex blob
   OID），不使用相对路径，并给出理由（该目录归档时会移动，而本手册不会）；
2. 引用**已在 `changes/archive/**` 的目标**可保留相对路径（归档目录不再移动）；
3. **本条只约束本手册自身的后续编辑**，不创造规则，不改变 `AGENTS.md`、
   enforcement、模板或任何其他文档的要求。

### 改动 2 — 修正块 ③ 的陈旧引用形式描述（范围扩展）

| | 文本 |
| --- | --- |
| 改前 | `每条案例只给出仓内`**`相对路径`**`与完整 40-hex Git OID` |
| 改后 | `每条案例只给出`**`可定位的引用（形式见下条）`**`与完整 40-hex Git OID` |

改动**只涉及描述引用形式的部分**。同句其余内容逐字保留，实测确认：
「不复制 raw evidence、hash 表、transcript、secret、真实设备标识、用户绝对路径或
大段日志」全部在场，`POL-PRIVACY-001` 与 `POL-ARTIFACT-001` 两处链接均在场且可解析。

该扩展的授权依据：readiness（#443）以「范围扩展:需维护者接受（merge 本 readiness
即接受）」显式登记，维护者合入 #443 即构成接受。理由亦记于该 readiness：不改则
手册首屏自述与其正文形式相互矛盾，而该矛盾正由本 change 的 TASK-HLD-001 造成。

## Commands and results

| Command | Result |
| --- | --- |
| 开工前 readiness carrier 复核（12 项，全路径） | 12/12 无漂移 **PASS** |
| 首屏块数 | 4 → **5**，新增块恰为 `**引用形式。**` **PASS** |
| 块 ③ 隐私条款逐字保留 | 七类禁复制项全部在场 **PASS** |
| 块 ③ 两处 `POL-*` 引用 | `POL-PRIVACY-001`、`POL-ARTIFACT-001` 均在场且 anchor 解析 **PASS** |
| 不动面：首屏其余 3 块（①②④） | 逐字未改 **PASS** |
| 不动面：`AF-NNN` ID 集合 | `AF-001`…`AF-018` 完整 **PASS** |
| 不动面：八字段契约与顺序 | H2 = 18、H3 = 144，18 组同序 **PASS** |
| 不动面：`Fact`/`Inference`/方法计数 | 36 / 18 / positive 18 / negative 18 **PASS** |
| 不动面：`Currency` 行 | 18 行逐字未改 **PASS** |
| 不动面：正文引用 | 活跃 change 相对链接仍为 **0**；archive 类仍为 **16**；11 个耐久 blob 全部可解析 **PASS** |
| shadow-spec：新增 `SHALL`/`MUST` | **0** **PASS** |
| shadow-spec：对其他文档的强制表述 | **0** **PASS** |
| shadow-spec：自动批准/ready/done 语义 | **0** **PASS** |
| 全部链接与 anchor 解析 | FAIL = 0 **PASS** |
| 手册 diff 规模 | 2 个 hunk（恰对应两处改动）**PASS** |
| 越界复核 | `openspec/templates/**`、`changes/archive/**` diff 均为 **0** **PASS** |
| `./scripts/check-sdd.sh` | `0 error(s), 0 warning(s), 111 acceptance IDs` **PASS** |
| `git diff --check` | 干净 **PASS** |

## AC conclusion

- `HLD-CONVENTION-001`: **passed**（documentReview）。手册首屏新增一条非规范引用
  约定，明确活跃 change 用耐久形式、已归档目标可用相对路径，并明确只约束本手册
  自身后续编辑；新增 normative `SHALL`/`MUST` = 0，对其他文档的强制表述 = 0，
  自动批准/ready/done 语义 = 0；`HLD-DURABLE-001` 所列不动面逐项零变化。

## Deviations and residual risk

- **Deviation:无实质偏离。**两处改动与 readiness 封闭的拟增文本、范围扩展边界
  逐项一致。改动 2 属 readiness 显式登记并经 #443 合入被接受的扩展，非静默扩围。
- **起草期整形（非范围变化）**：改动 2 首版留下两行过短的折行，两次重排为正常
  行宽。仅调整换行位置，字面内容未变（隐私条款与 `POL-*` 引用的逐字保留在每次
  重排后均重新实测）。
- **Residual risk 1 — 约定的非强制性**：本条只约束本手册后续编辑，且无机械门
  校验后续编辑是否遵守。若日后需要机械化（例如 CI 校验手册内不出现活跃 change
  相对路径），须另立 change（本 change proposal 明列 out of scope）。
- **Residual risk 2 — 其他文档不受影响**：仓内其他文件若有同类跨 change 相对引用，
  不在本 change 范围，也不受本约定约束。
- destructive dispatch = **0**；device/network/effect dispatch = **0**；真实硬件 = **无**。
