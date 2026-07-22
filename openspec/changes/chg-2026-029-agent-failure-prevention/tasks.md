# CHG-2026-029 Tasks

> Change approval 状态以 `proposal.md` 为唯一事实源。本文件只登记任务，不执行任务、
> 不产生 completion evidence，也不把任何 task 置 ready；change approval 本身不解除
> 各任务的独立 readiness 前置，三任务在对应 readiness 合入前均保持 blocked。

## TASK-AFP-001 — 建立非权威 Agent 失败模式手册

- Status:blocked（双前置：① CHG-2026-029 经 approval-only PR 批准；② 独立 readiness
  PR 钉定历史审计 base、九项 case link 与文档结构）
- Platform:macos（过程文档跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-HANDBOOK-001`
- Depends on:change approval、independent readiness
- Applicable failure patterns:`AF-009`（避免把手册本身做成新的重型治理机制）
- Production reachability:not applicable；纯文档索引，零产品 effect
- Trusted fact sources:protected-main Git 历史、仓内 review/postmortem/evidence；聊天记忆与
  仓库外 scratchpad 不作为事实源
- Allowed paths:`openspec/planning/agent-failure-patterns.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、产品 source/tests/scripts/workflows
- Risk:low（主要风险是 shadow spec、陈旧链接与复制敏感 evidence）
- Hardware required:no

### Deliverables

- `openspec/planning/agent-failure-patterns.md`，包含 design §2 固定字段与首批
  `AF-001`…`AF-009`；
- 每项至少一个可复查仓内案例与 canonical rule 引用，事实/推断分离；
- CHG-2026-028 已覆盖面与未覆盖语义面诚实标注；
- non-normative/authority/conflict/privacy/archive 边界在首屏明确。

### Verification

- `AFP-HANDBOOK-001` document review；
- 九个 ID 唯一且字段齐全；link/OID/currency 审计；shadow-spec、secret/privacy、
  archive-zero-diff 检查；
- `scripts/check-sdd.sh` 与 `git diff --check`。

### Notes / handoff

- 实现/evidence PR 不翻 task 状态；`ready→done` 使用独立 PR；
- 若某案例需要修改历史结论或 canonical rule，停止并把该问题交回所属 change，不在本
  手册任务中修复。

## TASK-AFP-002 — 将失败模式选择、生产可达性与 evidence freshness 接入模板

- Status:blocked（三前置：① change approval；② TASK-AFP-001 done；③ 独立 readiness
  PR 钉定三个模板 blob 与精确新增字段）
- Platform:macos（模板跨平台可复用，零平台产品行为）
- Requirements/AC:change-local `AFP-TEMPLATE-001`
- Depends on:change approval、TASK-AFP-001 done、independent readiness
- Applicable failure patterns:`AF-001`、`AF-002`、`AF-003`、`AF-005`、`AF-008`
- Production reachability:not applicable；本任务只修改模板，模板内容要求未来任务显式
  记录 production root→authority→effect 或 `not applicable` 理由
- Trusted fact sources:TASK-AFP-001 已合入手册、当前三个模板完整 Git blob；模板不把
  调用者自报字段升级为可信事实
- Allowed paths:`openspec/templates/change/tasks.md`、
  `openspec/templates/change/design.md`、`openspec/templates/change/evidence-run.md`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、产品 source/tests/scripts/workflows
- Risk:low-medium（模板措辞可能被误解为新批准语义或强制性产品规则）
- Hardware required:no

### Deliverables

- tasks template：Applicable AF、production reachability、trusted fact sources 三个短字段；
- design template：authority/production reachability 分析段；
- evidence-run template：完整 base OID/input pins、producer→consumer、currency/
  superseded/invalidated 字段；
- 所有新增字段都允许诚实 `not applicable` + 理由，不改变既有状态、scope、AC、风险、
  hardware 与 evidence 分类规则。

### Verification

- `AFP-TEMPLATE-001` document review；
- before/after 字段矩阵证明既有模板条目零删除、零放宽；
- 搜索不存在自动批准、自动 ready/done、fake→hardware 或手册覆盖 canonical rule 的措辞；
- `scripts/check-sdd.sh` 与 `git diff --check`，archive diff 为零。

### Notes / handoff

- 不在本任务引入 parser/CI；进一步机械化必须另立 change；
- 实现/evidence 与状态 PR 分离。

## TASK-AFP-003 — 历史案例检出演练与误报边界复核

- Status:blocked（四前置：① change approval；② TASK-AFP-001 done；③ TASK-AFP-002 done；
  ④ 独立 readiness PR 钉定六个案例和一个环境反例的完整 base/link）
- Platform:macos（document review；零真实设备/产品执行）
- Requirements/AC:change-local `AFP-DRILL-001`
- Depends on:change approval、TASK-AFP-001 done、TASK-AFP-002 done、independent readiness
- Applicable failure patterns:`AF-001`…`AF-009`
- Production reachability:not applicable；只对历史记录做检出演练，不执行或重新验证产品路径
- Trusted fact sources:readiness 钉定的 protected-main OID、仓内历史 bytes 与 merge/review
  记录；不得用聊天摘要补足历史事实
- Allowed paths:`openspec/changes/chg-2026-029-agent-failure-prevention/evidence/**`、
  `openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:`AGENTS.md`、`openspec/constitution.md`、
  `openspec/governance/**`、`openspec/specs/**`、`openspec/contracts/**`、
  `openspec/changes/archive/**`、`openspec/planning/agent-failure-patterns.md`、
  `openspec/templates/**`、产品 source/tests/scripts/workflows
- Risk:low（风险是 hindsight bias、把环境失败误报为产品缺陷、或把演练当作重新验证）
- Hardware required:no

### Deliverables

- 一份 historical detection drill run，覆盖 design §5 六类固定案例与至少一个环境失败反例；
- 每例记录最早触发阶段、AF ID、模板字段、应采取动作、历史最终发现证据；
- false-positive 边界：环境失败保持环境失败，fake/simulation 不升级为真实支持，演练不改变
  任何历史 task/change/AC 结论。

### Verification

- `AFP-DRILL-001` document review；
- 六类案例全部有 evidence link 且能映射到具体 preflight/verification 动作；
- 至少一个环境反例被正确分类为 blocked/deviation 而非产品 failure；
- archive、历史 evidence、产品代码 diff 均为零；`scripts/check-sdd.sh` 与
  `git diff --check`。

### Notes / handoff

- 演练结果若发现当前 active task 的现实缺陷，只记录指针并 fail closed；不得在 AFP-003
  allowed paths 外顺手修复。
