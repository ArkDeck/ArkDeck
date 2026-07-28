---
id: CHG-2026-042-tasks-field-colon-parity
revision: 2
status: verified # 2026-07-28 本 verification-closure PR；closure 段见文末
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

## Revision r2：候选总数是快照，不是语义不变量

TASK-CM7-001 fresh readiness 在 protected `main`
`20aeee5653d7eece08911c0a84afc92c1fa09702` 复算时，r1 写下的固定总数
26→32 已自然变为 **27→33**：proposal 合入后，本 change 自己新增的
`TASK-CM7-001` 同时出现在 before 与 after，故两侧各加 1。语义差分完全不变：
`lost=[]`，`gained` 仍恰为 `TASK-BRC-001`…`TASK-BRC-006`，六项仍全部
`done` / `blocked`。

同轮并发检查发现唯一 open PR #704 会新增一个使用 ASCII 冒号的
`TASK-OBS-001R`。在其 exact head
`7a5da66fdf4e1cf09018a538312523899dacdeba` 上执行同一差分为 **28→34**，
`lost` 与 `gained` 集合仍与上段逐项相同。由此证明固定总数会被无关、合法的
ASCII task 增减扰动，不能充当 C-M7 的 pass/fail 边界。

r2 只更正验证算术，不改变 scope、实现文件、解析行为或 AC ID：

- **语义不变量**：`lost=[]`；`gained` 恰为已登记的六个 BRC task；六项均不得
  变为 ready / 可 dispatch，且其 status、grade、hardware、dependency 与
  allowed paths 必须逐项入 evidence；
- **诊断快照**：26→32、27→33、28→34 三组计数全部保留并绑定各自 exact tree，
  只用于复查语料演进，不要求后续总数恒定；
- 新增/删除无关 ASCII task 只要 before/after 两侧对称、语义不变量仍成立即可；
  任何 lost、未登记 gained、或六项中出现 ready / 可 dispatch 仍须停下并走
  proposal revision。

本 r2 是 D1 proposal revision；维护者 merge 只批准上述计数门更正。
`TASK-CM7-001` 继续 `blocked`，不构成 readiness 或实现授权。

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
  加入 never-claim 根。r1 change approval 已由 PR #702 合入；任务在独立 D1
  readiness 合入前保持 `blocked`，r2 合入也不构成 readiness。

## Verification closure（2026-07-28）

唯一任务 TASK-CM7-001 已在 protected main 记为 done；三条 change-local AC
均有可复查 evidence。本 PR 只翻 change / verification 状态并引用已合入记录，
零实现、零 scope、零 acceptance 定义变化。

- **治理与交付链**：proposal #701 merge
  `f20077a0630147be879acb5a8db5ae780ae79b2a`；approval #702
  `3703a96ea334dc2ec2598008bd9c070190832127`；proposal r2 #705
  `7c75dec6bb2f8f8a468a0c05001e35c43d998e22`；readiness r1 #707
  `c3ad721f1119d7cbf73022a89dd1b502bb92289a`、r2 #712
  `0c35f35e1afdb3ffe1e3602d7d1b87b2ed4e37f8`、scope remediation r3
  #714 `eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`、final corpus r5 #718
  `0185bf52b8e908560867bccaeb5f6a96d2cedf02`、r6 #720
  `cd3f3e0a7b4c2055746a617110e94b2e1dc791c7`；implementation #721
  `54c3a3cfbc455b5eb0ab6710955ad994d5b57eac`；done #723
  `de324711463030a4ae3ff3daae9ffaeeb1f5cd70`。#721 reviewed head
  `4a8d552a03bcc0fb12cbb4306b63e1a719602800` 与 merge tree 的 7 个
  授权文件逐字一致；#723 reviewed head
  `e4439178c7a2699092aa111eea171b65b5d088fc` 与 merge-tree `tasks.md`
  逐字一致。
- **`CM7-PARITY-001` = PASS**：host-loop 的 `Depends on` /
  `Allowed paths` 与 PR guard 对 `:` / `：` 的 inline、合法缩进续行输出
  等价；空值、散文、`;` / `；` 继续 fail closed。分别撤销两条 parser
  全角分支时对应专属测试均以 `0 != 1` 变红。
- **`CM7-CORPUS-001` = PASS**：run 记录逐项登记六个 gained candidate 的
  status、grade、hardware、dependencies 与 allowed paths；原始实现 base、
  r6 submission base 以及 verification base protected main
  `7b05ccdaea47acc647ba235c630c3899a952c9c3` 均为 `30→36`、
  `lost=[]`、gained 恰为 `TASK-BRC-001`…`TASK-BRC-006`。BRC-001/002
  done，BRC-003…006 blocked，六项均非 ready / 不可 dispatch。开放
  PR #724 exact head `3523087c21850e7885222ccf4d158ce6d6b9abd2`
  与 verification base 的无冲突 prospective tree 也得到同一结果。
- **`CM7-SELF-001` = PASS**：TASK-CM7-001 exact root 与合法 `A` / `R`
  suffix 永不 claim，相邻 `TASK-CM7-002` / `TASK-CM7-0011` 不受影响；
  移除 root 时 exact / `A` / `R` 三项专属断言全红。done 树中本任务同时被
  never-claim、status done 与 unknown-grade 拒绝，`claimable=none`。
- **closure 复验（`7b05ccda…`）**：13 项 colon/census/never-claim =
  13/13；PR guard = 50/50；host-loop 全量 = 644 tests / 1 expected failure /
  0 unexpected failures；`check-sdd` = 0 error / 0 warning /
  111 acceptance IDs；`git diff --check` PASS。既有 localhost 测试的
  `ResourceWarning` 与 line-369 `SyntaxWarning` 仍为非失败输出，不影响 AC。
- **边界结论**：Core/spec/contracts/baseline、产品代码、设备/HDC、credential、
  E1/E2/destructive dispatch 均无变化；无真实硬件或外部副作用声明。
  Evidence 真值源为已合入
  `evidence/runs/TASK-CM7-001/run.md`，本 closure 不把实现 PR 的 review
  单独当作 verification 批准；只有维护者 merge 本独立 PR 后 `verified`
  才生效。
