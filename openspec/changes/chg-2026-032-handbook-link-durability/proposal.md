---
id: CHG-2026-032-handbook-link-durability
revision: 1
status: proposed
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
