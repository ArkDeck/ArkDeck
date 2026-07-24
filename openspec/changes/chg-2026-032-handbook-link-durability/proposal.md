---
id: CHG-2026-032-handbook-link-durability
revision: 1
status: verified # 2026-07-23 本 verification-closure PR;approval #438 merge `4675971ee132d0b94a7f0780e9987518489974bf`;两 task done 已合入(OID 见 Verification closure);archive 另行。原注:r1 proposal 经 #437 合入 `02b27b01246eaed4b230f3a2cfec6a72545c63ff`
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# 失败模式手册的跨 change 引用耐久化

## Why

`openspec/planning/agent-failure-patterns.md`（CHG-2026-029 交付，现已 archived）
是一份**长期存活**的非权威索引：它不属于任何 change，不随任何 change 归档移动。
但它引用历史案例时使用**相对路径**指向 `openspec/changes/<id>/...`，而 change 目录
在归档时会 `git mv` 到 `openspec/changes/archive/<date>-<id>/`。

结果是一个结构性不对称：**被引用方会移动，引用方不会**。每当一个被引用的 change
归档，手册就断一批链，且断链**静默发生**——没有任何机械门会报（guard 不校验
markdown 链接可达性）。

这不是假设。CHG-2026-029 自身的 TASK-AFP-005 已经处理过同一问题的一个实例：手册
指向该 change 自己 `design.md` 的那一条，在它归档前必须先去掉相对路径，否则归档
即断。当时按 readiness 的不动面条款只收口了那一条，其余逐字保留并如实登记为已知
限制，交由本 change 统一处置。

**实测现状（base `5737c1b7127f2cbe98cfb953434b4a0dfe11498d`）**：手册共 35 条指向 change 目录的相对链接：

| 类别 | 条数 | 目标数 | 风险 |
| --- | --- | --- | --- |
| 指向 `changes/archive/**` | 16 | 7 | 路径已稳定，归档目录不再移动 |
| **指向活跃 change** | **19** | **6** | **各自归档时断链** |

活跃目标分布：`chg-2026-006`(1)、`chg-2026-008`(2)、`chg-2026-022`(5)、
`chg-2026-025`(1)、`chg-2026-026`(6)、`chg-2026-028`(4)。

其中 `chg-2026-028` 与 `chg-2026-027` 已 `verified`，归档是自然后继动作——
即断链在近期就会发生。

> 计数说明：CHG-2026-029 的 TASK-AFP-005 run 曾记录"其余 24 条"。该数字对当时 base
> 成立；此后 `chg-2026-021` 归档（其 6 条转入 archive 类）与 AFP-005 自身的收口
> 使活跃条数降至 19。本 change 以上表实测值为准，不沿用历史计数。

## What changes

### TASK-HLD-001 — 活跃 change 引用改为耐久形式

把手册中 **19 条**指向活跃 change 的相对链接，改为与 TASK-AFP-005 同构的耐久形式：
保留可检索的事实指向（change ID + 文件名 + 必要的章节/任务标识 + 完整 40-hex
OID），去掉会随归档失效的相对路径。

指向 `changes/archive/**` 的 16 条**逐字不动**：归档目录不再移动，其相对路径是
稳定的，改写它们只会降低可点击性而无收益。

### TASK-HLD-002 — 在手册内登记引用约定

在手册首屏的既有边界声明中增加一条**非规范**约定：引用 change 目录时，若目标为
活跃 change 则使用耐久形式（change ID + 完整 OID），若目标已在 `archive/` 则可用
相对路径。该条只约束本手册自身的后续编辑，**不创造任何 normative 规则**，也不改变
`AGENTS.md`、enforcement 或模板对其他文档的要求。

### Out of scope / non-goals

- 不改 `AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、
  `Automation status` 取值域、`Fact`/`Inference` 标注与 positive/negative 计数；
- 不改任何案例的**事实内容**——只改引用形式；
- 不动 `openspec/templates/**`、`AGENTS.md`、Constitution、enforcement、
  current specs/contracts；
- 不改写 `changes/archive/**`（含已归档的 CHG-2026-029 自身）；
- 不新增 parser/CI/guard 校验链接可达性（若日后证明值得机械化，另立 change）；
- 不处理仓内其他文件的同类引用（本 change 只覆盖该手册）。

## Scope（涉及的 Requirement/AC）

- Canonical Requirements：无；Canonical Acceptance：无；
- Change-local acceptance：`HLD-DURABLE-001`、`HLD-CONVENTION-001`；
- Contracts/schemas：无；Core baseline bump：不需要。

## Safety, privacy, and compatibility

- **可点击性下降**：耐久形式牺牲相对链接的点击可达，换取归档后不失效。这是
  TASK-AFP-005 已确立的既定取舍，本 change 沿用同一形态以保持手册内一致。
- **事实完整性**：改写只动引用形式；每条改动后须仍能由 change ID + OID 唯一定位到
  原记录，验证以逐条对照为二值门。
- **隐私**：只引用仓内已脱敏记录与 Git OID；零 secret、零设备标识、零用户路径。
- **平台影响**：零产品行为、零平台实现、零 conformance 变化。
- **Rollback**：单文件 revert 即可；无数据迁移、无运行时状态。

## Approval and flow

V2 治理：本 propose PR 合入仅登记提案，状态保持 `proposed`，两任务保持
`blocked`；批准须独立 approval-only PR；两任务各自经 readiness、
implementation/evidence、done PR；change verified 需两条 change-local acceptance
均有可复查 evidence 并由维护者在独立 verify PR 中确认。

## Approval

- r1 proposal 经 PR #437 合入 protected `main`，merge OID
  `02b27b01246eaed4b230f3a2cfec6a72545c63ff`。该 merge 只登记 `status: proposed` 的
  proposal/design/tasks/verification/acceptance-cases/spec-impact，**不构成 change
  approval 或任务执行**。
- 正式批准：仅在维护者 review/merge 本 approval-only PR 后，本 change 的
  `status: approved` 才生效。该 merge 表示维护者接受以下封闭范围：
  - **TASK-HLD-001**：只把手册中指向**活跃 change** 的相对链接改为耐久形式
    （change ID + 文件名 + 必要章节/任务标识 + 完整 40-hex OID）；指向
    `changes/archive/**` 的链接逐字不动；不改任何案例的事实内容。
  - **TASK-HLD-002**：只在手册首屏既有边界声明中增加一条**非规范**引用约定，
    且该约定只约束本手册自身的后续编辑，不创造 normative 规则、不改变
    `AGENTS.md`/enforcement/模板对其他文档的要求。
  - **共同验收**：`HLD-DURABLE-001`、`HLD-CONVENTION-001` 按 verification r1
    二值执行；计数门、逐条对照、OID 可解析、归档模拟、不动面零变化与
    shadow-spec 扫描全部保持。
  - **不动面**：`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、
    `Automation status` 取值域、`Fact`/`Inference` 标注与 positive/negative 计数、
    案例事实内容、`openspec/templates/**`、`AGENTS.md`、Constitution、
    enforcement、current specs/contracts、`changes/archive/**` 与所有
    platform/conformance/support 状态**均不改变**。
- 本批准**不产生任何任务执行或 readiness**：TASK-HLD-001/002 继续保持 `blocked`，
  各自必须在依赖满足后通过独立 readiness PR 才能开工；本批准也不授权新增
  parser/CI、不授权处理仓内其他文件的同类引用。

## Verification closure（2026-07-23）

本节随 change `approved → verified` 写入。两条 change-local acceptance 均有可复查
evidence，且本 closure 的每项结论在 verify base `fee0f9f507f7a008cc75952bb895056205c6d4f1`
上**独立实测复核**，非引用 run 的自述。

### 任务与承载

| Task | implementation/evidence | done 状态 PR |
| --- | --- | --- |
| TASK-HLD-001 | #441 merge `b8f41066e0aa3a8d1343f805524f9c9439ff9c5c` | #442 merge `73b46b684b27eda23cfbaad06c5b707bff39e2cc` |
| TASK-HLD-002 | #444 merge `03d5cb3653b9fa4b87b139321ac25844e3ff7350` | #448 merge `fee0f9f507f7a008cc75952bb895056205c6d4f1` |

approval-only #438 merge `4675971ee132d0b94a7f0780e9987518489974bf`；
readiness：HLD-001 #439 merge `a7ee3f88634972cea4f3bb6622d2f6dab6ea6e06`、
HLD-002 #443 merge `5f34a2aa376bd3677b69ba14410f265f1a29aaf7`。

### `HLD-DURABLE-001` — **passed**（documentReview）

evidence：`evidence/runs/TASK-HLD-001/run.md` 与逐条对照表
`evidence/runs/TASK-HLD-001/link-inventory.md`。verify base 独立实测：

- 手册中指向**活跃 change** 的相对链接 = **0**（原 19 条全数处置）；
- 指向 `changes/archive/**` 的链接 = **16**，计数与内容零变化；
- 耐久引用 blob = **11** 个唯一值，`git cat-file -e` 逐个可解析，**0 不可解析**；
- **归档模拟**：chg-2026-006/008/022/025/026/028 六个被引用活跃 change 逐个验证，
  各 **0 条可断项**。

### `HLD-CONVENTION-001` — **passed**（documentReview）

evidence：`evidence/runs/TASK-HLD-002/run.md`。verify base 独立实测：

- 首屏块数 = **5**，末块恰为 `**引用形式。**`，三点（活跃 change 用耐久形式并说明
  理由、已归档目标可保留相对路径、只约束本手册自身后续编辑）齐备；
- 块 ③ 的隐私条款与 `POL-PRIVACY-001`/`POL-ARTIFACT-001` 两处引用逐字保留；
- shadow-spec：新增 normative `SHALL`/`MUST` = **0**。

### 共同不动面（两 AC 同项，verify base 实测零变化）

`AF-001`…`AF-018` ID 集合完整；H2 = 18、H3 = 144 且八字段同序；
`Fact` 36 / `Inference` 18；positive 18 / negative 18；`Currency` 18 行；
`Automation status` 取值域合法。

### Repository checks

`scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs；
`git diff --check` 干净；`changes/archive/**` 与 `openspec/templates/**` diff = **0**。

### 归档就绪（前瞻，不构成 archive 授权）

`git grep` 全仓扫描：本 change 目录的**目录外引用 = 0**。TASK-HLD-001 已把手册对
change 目录的引用全部转为耐久形式，故本 change 的归档不产生新的引用耦合，也不需要
先修改任何其他文件。archive 仍须独立 PR。

### verified 的边界

verified **不**把手册提升为权威规则（它仍是 non-normative 索引）、**不**改变任何
产品/platform/conformance/support/release 状态、**不**构成未来 guard/CI 扩展授权。
手册中仍有 **16 条**指向 `changes/archive/**` 的相对链接，属**有意保留**
（归档目录不再移动，见 design §3），非遗留缺陷。

### Provenance 复核边界（如实记录）

TASK-BAP-003 凭据分离生效后 Agent 无维护者 `gh` 凭据，无法读取上述各 PR 的
reviews/mergedBy。本 closure 以 `git` 验证：所列 merge OID 全部在 protected `main`
的 ancestry 中，且各交付物 blob 与其实现分支 head 逐字一致。**“由维护者 APPROVED”
未经 Agent 独立验证**，由维护者 review 本 verify PR 时确认。
