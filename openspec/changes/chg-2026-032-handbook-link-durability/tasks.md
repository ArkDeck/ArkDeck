# CHG-2026-032 Tasks

> Change approval 状态以 `proposal.md` 为唯一事实源。本文件只登记任务，不执行任务、
> 不产生 completion evidence，也不把任何 task 置 ready；change approval 本身不解除
> 各任务的独立 readiness 前置。

## TASK-HLD-001 — 活跃 change 引用改为耐久形式

- Status:blocked（双前置：① CHG-2026-032 经 approval-only PR 批准；② 独立 readiness
  PR 钉定手册 blob 与逐条待改清单）
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `HLD-DURABLE-001`
- Depends on:change approval、independent readiness
- Applicable failure patterns:`AF-006`（archive 前引用扫描与断链即暂缓——本 change
  正是该模式的一次前置修复）、`AF-015`（同模式须全量处置而非只改发现点）、
  `AF-016`（逐条改写须以实测取值为准，不得凭记忆补全 OID）
- Production reachability:not applicable；纯文档索引，零产品 effect、零 dispatch
- Trusted fact sources:`git grep` 与链接解析对 protected `main` 的实测结果、被引用
  文件的仓内 bytes 与 `git rev-parse` 取得的完整 OID；**不以本 change 的 proposal
  转述、既往 run 的历史计数或会话记忆替代实测**
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-032-handbook-link-durability/evidence/**`、
  `openspec/changes/chg-2026-032-handbook-link-durability/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、`openspec/governance/**`、
  `openspec/specs/**`、`openspec/contracts/**`、`openspec/changes/archive/**`、
  `openspec/templates/**`、其他 change 目录、产品 source/tests/scripts/workflows
- Risk:low（风险是改写时丢失事实指向、误改 archive 类链接、或 OID 凭记忆生成）
- Hardware required:no

### Deliverables

- 手册中指向**活跃 change** 的相对链接归零（readiness 钉定的逐条清单全数处置）；
- 每条改后仍含可唯一定位的事实指向：change ID + 文件名 + 必要的章节/任务标识 +
  完整 40-hex OID；
- 指向 `changes/archive/**` 的链接**逐字不动**；
- run 记录逐条列出：原链接 → 改后文本 → 用于定位的 OID → 该 OID 的实测来源命令。

### Verification

- `HLD-DURABLE-001` document review；
- 二值门：活跃 change 相对链接计数 → 0；archive 类链接计数与内容零变化；
  每条改后文本含完整 40-hex OID 且该 OID 在 protected `main` ancestry 中可解析；
- 不动面：`AF-NNN` ID 集合、taxonomy 归属与两轴划分、八字段契约与顺序、
  `Automation status` 取值域、`Fact`/`Inference` 标注、positive/negative 计数
  全部零变化；
- 归档模拟：对每个被引用的活跃 change，其目录若移入 `changes/archive/<date>-<id>/`，
  手册中不存在可断项；
- `scripts/check-sdd.sh` 与 `git diff --check`；archive 与 templates diff 为零。

### Notes / handoff

- 逐条 OID 一律以 `git rev-parse` / `git log` 实测取得并在 run 中记录取值命令；
  **禁止由短 hash 补全为 40 位**（`AF-016` 的已知复发形态，CHG-2026-029 期间发生过）；
- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR。

## TASK-HLD-002 — 在手册内登记引用约定

- Status:blocked（三前置：① change approval；② TASK-HLD-001 done；③ 独立 readiness
  PR 钉定手册 blob 与拟增文本的精确位置）
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `HLD-CONVENTION-001`
- Depends on:change approval、TASK-HLD-001 done、independent readiness
- Applicable failure patterns:`AF-009`（避免把一条编辑约定写成新的 normative 规则）
- Production reachability:not applicable；纯文档，零产品 effect
- Trusted fact sources:TASK-HLD-001 已合入的手册 bytes；约定文本只描述本手册自身的
  编辑惯例，不引用外部授权
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-032-handbook-link-durability/evidence/**`、
  `openspec/changes/chg-2026-032-handbook-link-durability/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:同 TASK-HLD-001
- Risk:low（风险是措辞被误读为对其他文档的强制要求）
- Hardware required:no

### Deliverables

- 手册首屏既有边界声明中增加一条**非规范**引用约定：活跃 change 用耐久形式
  （change ID + 完整 OID），已在 `archive/` 的目标可用相对路径；
- 措辞须明确该约定**只约束本手册自身的后续编辑**，不创造 normative 规则、
  不改变 `AGENTS.md`/enforcement/模板对其他文档的要求。

### Verification

- `HLD-CONVENTION-001` document review；
- shadow-spec 扫描：新增 normative `SHALL`/`MUST` = 0；对其他文档的强制表述 = 0；
  自动批准/ready/done 语义 = 0；
- 不动面同 TASK-HLD-001（ID 集合、八字段契约、取值域、标注与计数零变化）；
- `scripts/check-sdd.sh` 与 `git diff --check`。

### Notes / handoff

- 本任务只加约定文本，不再改任何既有链接；
- 实现/evidence 与状态 PR 分离。
