---
id: CHG-2026-042-tasks-field-colon-parity
revision: 1
status: approved
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# `tasks.md` 字段冒号文法对齐：关闭 C-M7 静默楔死

## Why

CHG-2026-040 的冻结体检台账将 **C-M7** 记录为尚未立项的残余缺陷：两个生产
消费者对同一份 `tasks.md` 使用不同的字段文法。

- `scripts/check_pr_paths.py` 的 `Allowed paths` 读取器接受 ASCII `:` 与全角
  `：`；
- `scripts/host_loop/__main__.py` 的 `Status`、`Hardware required` 与
  `Decision-Grade` 同样接受两种冒号，但 `Depends on` 与 `Allowed paths`
  只接受 ASCII `:`；
- 结果是 PR 路径守卫可以接受一项任务，host-loop discovery 却会静默省略它。
  CI 绿不能揭示这项差异，任务因此可能永久不进入循环观察面。

在 protected `main`
`e114d9d3ae668bff68d2cfb69c59fa6f4dff00ec` 上复核：

- 活跃 `tasks.md` 有 6 个 `Depends on：`，全部位于 CHG-2026-036；
- 原 discovery 为 26 个候选；
- 仅把 `Depends on` / `Allowed paths` 的冒号类改为 `[:：]` 后为 32 个候选，
  新增恰为 `TASK-BRC-001` 至 `TASK-BRC-006`，零候选丢失；
- 这 6 项当前均为 `done` 或 `blocked`，所以该语法修正不会在当前基线上新增
  可 dispatch 的 ready task；它只恢复循环对真实治理状态的可见性。

## What changes

### In scope

- 把 host-loop discovery 的 `Depends on` 与 `Allowed paths` 字段分隔符收敛为
  与现有兄弟字段及 PR 路径守卫相同的封闭集合：ASCII `:` 或全角 `：`。
- ASCII 与全角写法必须产生完全相同的 dependency IDs、allowed paths 与候选
  字段；inline 值、合法缩进列表续行、空值与散文排除语义保持不变。
- 新增跨解析器契约测试：同一 `Allowed paths` fixture 由 host-loop discovery
  与 `check_pr_paths` 读取时，两个冒号变体均被接受且路径集合相同。
- 对全部活跃 `tasks.md` 做实现前后差分清点：零候选丢失；新增候选必须逐项归因
  于已登记的全角冒号语料，不能夹带其他解析放宽。
- 将 `TASK-CM7-001` 纳入 host-loop `never-claim` 根并以精确内容测试锁定。
  该任务会修改 discovery 自身，必须由会话实现，不能让循环认领。

### Out of scope

- 不改写 CHG-2026-036 或任何其他 change 的既有 `tasks.md` 标点；
- 不改变 task ID、Status、Hardware required、Decision-Grade、依赖完成判定、
  Allowed paths glob、change-relative 路径或 PR 身份/祖先校验语义；
- 不做任意 Unicode 规范化或接受 `:` / `：` 以外的分隔符；
- 不抽取第三套通用 Markdown parser，不重构 discovery / PR guard 的其他读取路径；
- 不修改 workflow、scheduler/launchd、GitHub 配置、Core/spec/contracts、产品代码；
- 不改写已归档的 CHG-2026-040 台账。

## Scope（涉及的 Requirement/AC）

- Requirements：无 canonical Core Requirement 认领（implementation-only）。
- Acceptance：change-local `CM7-PARITY-001`、`CM7-CORPUS-001`、
  `CM7-SELF-001`。
- Contracts/schemas：无持久化、wire、Core schema 变化；仅仓内治理文档读取契约。
- Core baseline bump：不需要。

## Safety, privacy, and compatibility

- **Failure modes**：主要风险是 parser 放宽意外扩大候选面。修复只允许两种已在
  仓内合法使用的冒号，并要求 before/after 差分、非法分隔符负例及逐项变异反证。
  discovery 仍在字段缺失、空值、未知硬件值或无 allowed path 时省略任务。
- **Authority boundary**：候选可见不等于可认领；approved、ready、hardware、
  dependency、allowed paths、base pin、Decision-Grade 与 never-claim 门保持不变。
  `TASK-CM7-001` 在实现合入前不写 `Decision-Grade`，并在同一实现中加入
  never-claim 根。
- **Data/schema compatibility**：ASCII 写法输出逐字段不变；全角写法从静默省略
  变为按同一封闭文法读取。无 migration，也不重写现存文档。
- **平台影响**：macOS host automation only；Windows/Linux 尚未启动，无影响、
  不产生支持声明或 revalidation。
- **隐私与设备**：只读仓内 Markdown 与 host-side contract tests；零网络、
  零凭据、零设备访问、零 E1/E2/destructive dispatch。
- **Rollback**：revert 单个实现 PR；无外部或持久化状态残留。

## Tasks

- **TASK-CM7-001** — 对齐字段冒号文法、补跨解析器/活体语料回归，并将本任务
  加入 never-claim 根。任务在 change approval 与独立 D1 readiness 合入前保持
  `blocked`；proposal 合入不构成 approval 或 readiness。
