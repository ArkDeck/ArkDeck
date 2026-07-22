---
id: CHG-2026-029-agent-failure-prevention
revision: 1
status: approved # r1 proposal 经 PR #345 合入 main `7083148b4ed6916f17ec87e05cc5970378839ba7`;正式批准仅由维护者 review/merge 本 approval-only PR 构成
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# Agent 高频失败模式手册与任务期预防接线

## Why

ArkDeck 的可审计历史已经积累了足够多的 Agent 失败案例，但可复用教训分散在
change `tasks.md`、长篇 run/addendum、review remediation 与 postmortem 中。
这些记录适合作为审计正本，却不适合在新任务开工前快速检索；结果是同类问题
经常直到实现后或深度 review 才再次暴露：

1. readiness/allowed-paths 未覆盖真实依赖或生产消费者，任务需从 `ready`
   回退 `blocked`，或另开 remediation 扩充精确路径；
2. 类型和 contract 测试可构造正例，但 App/CLI production root 没有可信数据源、
   authority 或真实 effect path；
3. authorization、device facts、usage count 或 evidence provenance 由调用方文本/
   文件自报，shape 校验被误当作信任证明；
4. producer/consumer 首次端到端运行过晚，跨语言布尔、序列化、toolchain、签名/
   Sandbox 与本机路径差异直到平台 run 才暴露；
5. 旧 revision 的 PASS、candidate hash 和历史 run 没有在事实原位清楚标记
   `SUPERSEDED`，容易被后续任务误读；
6. 安全反例在多轮 review 后逐项补齐，说明通用 adversarial matrix 与任务拆分
   信号没有在 design/readiness 阶段被复用；
7. V1 治理事故证明，把经验直接堆成新的重型数据库、签名链或复杂 guard 可能
   再次让机制本身成为最大变更面。

CHG-2026-028 已把 Swift CI、三方 revision、结构化完整 pins 与 PR allowed-paths
四个可机器判定面纳入机械化。本 change 不复制这些 guard，也不把知识文档变成
新的规则源；它补齐尚需人类/Agent 语义判断的部分：建立一份短小、非权威、
证据链接驱动的失败模式手册，并把相关选择、生产可达性、可信事实来源与 evidence
freshness 提示接入 change 模板。历史 archive 保持冻结。

## What changes

### TASK-AFP-001 — 非权威失败模式手册

新增 `openspec/planning/agent-failure-patterns.md`，以稳定 `AF-NNN` ID 登记首批
九类模式：

- `AF-001` readiness/allowed-paths 假阳性；
- `AF-002` production root/authority/effect path 不可达；
- `AF-003` caller-controlled trust/provenance/facts；
- `AF-004` producer→consumer 端到端与跨语言类型缝隙；
- `AF-005` evidence freshness、class 与 supersession；
- `AF-006` PR/status/revision/pin 漂移；
- `AF-007` 非 hermetic 环境与本机隐式依赖；
- `AF-008` adversarial matrix 缺口与任务跨信任边界过大；
- `AF-009` 治理机制与实际信任边界错位。

每项固定包含：触发信号、已观察案例链接、根因、开工前检查、必需正反验证、
canonical rule 引用、已有自动化防线/诚实缺口、最近复核基线。手册头部必须声明
其为 non-normative index；与 Constitution/spec/contracts/enforcement/AGENTS 冲突时
后者优先。案例只链接历史正本，不复制 raw evidence、敏感数据或大段日志。

### TASK-AFP-002 — change 模板接线

最小修改三个模板：

- `templates/change/tasks.md`：加入 `Applicable failure patterns`，要求任务作者选择
  相关 `AF-*`，或写 `none` 及可审查理由；
- `templates/change/design.md`：加入 production root→authority→effect 可达性与
  trusted fact source/anti-forgery 分析；
- `templates/change/evidence-run.md`：加入完整 base OID、输入 pins、evidence class、
  producer/consumer 路径、current/superseded 判定与失效条件。

模板只提示思考和记录，不新增批准语义，不自动把 task 置 `ready/done`，也不覆盖
既有 Requirement/AC、Definition of Ready/Done 或 evidence schema。

### TASK-AFP-003 — 历史案例检出演练

不修改历史文件，使用新手册和模板字段对至少六个固定历史案例做 document-review
演练，覆盖：readiness/路径漏项、production source 缺失、caller-controlled trust、
跨语言端到端缝隙、evidence supersession/adversarial filesystem、V1 治理错位。
每个案例必须展示“哪个字段会在实现前触发什么动作”，并包含至少一个不会被手册
误判为产品缺陷的环境失败反例。演练只证明检索/提示有效，不重写历史结论。

### Out of scope / non-goals

- 不修改 `AGENTS.md`、Constitution、enforcement、current specs、contracts、schema、
  baseline、integration/platform profile 或任何产品代码；
- 不新增 wiki、数据库、向量库、Agent memory 服务、签名链或新 CI/guard；
- 不追溯修改 `changes/archive/**`、既有 evidence、task/change 状态或 PR 元数据；
- 不重复 CHG-2026-028 的 Swift/revision/pin/allowed-paths 机械化；
- 不把 hidden Codex/聊天记录当作事实源；案例范围只覆盖仓库与完整 Git 审计账本；
- 不修复被案例引用的产品/流程缺陷；任何现实缺陷仍由其所属 approved change 处理。

## Scope（涉及的 Requirement/AC）

- Canonical Requirements：无；
- Canonical Acceptance：无；
- Change-local acceptance：`AFP-HANDBOOK-001`、`AFP-TEMPLATE-001`、
  `AFP-DRILL-001`；
- Contracts/schemas：无；
- Core baseline bump：不需要。

## Safety, privacy, and compatibility

- **Shadow-spec 风险**：手册可能被误当成规则源。通过 non-normative 头部、只链接
  canonical rule、禁止新增 SHALL/批准语义、冲突时权威文件优先来约束。
- **陈旧风险**：案例与自动化状态可能漂移。每项记录最近复核的完整 main OID，
  事实发生变化时保留原案例链接并更新当前处置，不改写历史 evidence。
- **过度治理风险**：本 change 只增加一份 Markdown 索引与三个模板的小字段，
  不引入 parser、数据库或 gate；AFP-003 演练证明价值后才可讨论进一步机械化。
- **隐私**：只引用仓内已脱敏记录与 Git OID/PR 编号；不复制设备标识、用户路径、
  secret、raw dump/trace 或仓库外日志。
- **平台影响**：零产品行为、零平台实现和零 conformance 变化；Windows/Linux 未来
  任务可复用相同手册，但本 change 不声明其平台支持状态。
- **Rollback**：独立 revert 手册与模板接线即可；无数据迁移、运行时状态或 archive
  改写。

## Approval and flow

本 PR 只登记 r1 proposal/design/tasks/verification/acceptance-cases，状态保持
`proposed`，三项任务全部保持 `blocked`。正式批准须独立 approval-only PR；之后
每项任务各自经过 readiness、implementation/evidence、done PR。TASK-AFP-003 在
AFP-001/002 done 后执行；change verified 需三条 change-local acceptance 全部有
可复查 evidence，且独立 verified PR 由维护者确认。

## Approval

- r1 proposal 经 PR #345 由维护者 @lvye APPROVED 并合入 protected `main`，
  merge OID 为 `7083148b4ed6916f17ec87e05cc5970378839ba7`（2026-07-23，
  Asia/Shanghai）。该 merge 只登记 `status: proposed` 的 proposal/design/tasks/
  verification/acceptance-cases，不构成 change approval 或任务执行。
- 正式批准：仅在维护者 review/merge 本 approval-only PR 后，本 change 的
  `status: approved` 才生效。该 merge 表示维护者接受以下封闭范围：
  - **TASK-AFP-001**：交付一份 non-normative、证据链接驱动的
    `agent-failure-patterns.md`，首批仅含 design 定义的 `AF-001`…`AF-009`，
    手册不得覆盖 canonical authority、复制 raw/sensitive evidence 或创造批准语义；
  - **TASK-AFP-002**：只修改 tasks/design/evidence-run 三个 change 模板，增加
    Applicable AF、production root→authority→effect、trusted fact sources 与
    evidence currency/supersession 提示；不删除或放宽既有 gate，不新增 parser/CI；
  - **TASK-AFP-003**：只在本 change evidence 内执行六类历史案例 + 至少一个环境
    反例的 document-review drill，不修改 archive/历史结论、不重新验证产品或硬件；
  - **共同验收**：`AFP-HANDBOOK-001`、`AFP-TEMPLATE-001`、`AFP-DRILL-001`
    按 verification r1 二值执行；shadow-spec、secret/privacy、archive-zero-diff、
    allowed/forbidden paths、SDD 与 diff checks 全部保持；
  - **不动面**：`AGENTS.md`、Constitution、enforcement、spec/contracts/schema/
    baseline、integration/platform profile、产品 source/tests、scripts/workflows、
    CHG-2026-028 机械化归属与所有 platform/conformance/support 状态均不改变。
- 本批准不产生任何任务执行或 readiness：TASK-AFP-001/002/003 继续保持
  `blocked`，各自必须在其依赖满足后通过独立 readiness PR；不授权追溯修改
  `changes/archive/**`，也不授权修复案例指向的现实产品/流程缺陷。
