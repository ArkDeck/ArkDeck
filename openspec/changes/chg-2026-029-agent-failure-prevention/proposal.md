---
id: CHG-2026-029-agent-failure-prevention
revision: 3
status: approved # r1 经 PR #345/#347 批准,r2 经 #355 合入;本 r3 事实更正修订仅在维护者 review/merge 当前 revision PR 后生效
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

**r2 追加动因（2026-07-23，维护者要求对全部会话/任务历史重扫）**：r1 的九类
全部落在 change/PR/evidence 这条**治理与交付**轴上。对 `main`
`03f5ebae80ed6f3b24c1cff14fa91c8e9400b45c` 上 352 个 commit、17 个 archived change
与 12 个 active change 的复扫显示，实际烧掉最多轮次与最多设备窗口的另一族失败
落在**执行与验证**轴上，且完全不被 r1 九类覆盖：测试自证（套套逻辑，仓内至少
三处已清理记录）、把退出码当语义成功、交付给操作者的一次性脚本在设备窗口才
暴露 bug（CHG-2026-016 连烧三窗口）、照搬既有 harness 形态而漏读目标 REQ、
门只校验凭据存在而不校验语义绑定、单点修复不扫同模式、凭记忆写 pin、
收尾轮次仍在加架构、多会话共享工作副本。这九类每一类都已经在仓内至少复发一次
并留下 remediation 载体，因此以 `AF-010`…`AF-018` 补齐；同时把复扫中发现属于
r1 既有根因的新子面并入原 ID，避免 ID 膨胀。

**r3 追加动因（2026-07-23，本 change 自身的事实性缺陷）**：TASK-AFP-003 readiness
（`#369`）在对 pinned bytes 逐项复核时发现，r2 写入 design §3.2 的 `AF-014` 第四条
gap 表述为“`TraceProgressTotal.reliable` 作为 public case 绕过 capability 门”，并把
该表述整体归属于 `chg-2026-021/tasks.md`。全仓复核结论：

1. `TraceProgressTotal` **在仓内不存在**，仅出现于 r2 的 design.md 自身；
2. 该 gap 的一手表述是 `chg-2026-021/tasks.md` 二值门 ④ 与
   `evidence/runs/TASK-TR-002R/run.md`（“reliable-total receipt 只能由当前 adapter
   capability=true factory 产生”“no public initializer … minted only by a factory”），
   相关字段名为 `TraceCatalogContracts.swift` 的 `reliableByteTotalAvailable`；
3. 同段的 `expectedTargetID` 与 `publication receipt` 是**真实符号**，但位于 Swift
   源码/测试与 run evidence，不在被归属的 `tasks.md` 内；
4. 已合入手册 `AF-014` 未使用该不存在的符号名（其 `Fact` 只引文件名），但
   “公开枚举 case”这一机制描述同样未经一手核对。

根因 = `AF-016`（以会话记忆代替一手核查），发生在本 change 自身的 r2 起草中——
起草者把跨会话记忆里的符号名直接写入 design，未对仓内 bytes 复核。**这是手册所
登记模式在其自身产出上的一次真实复发**，按 `AF-005` 的 currency 规则在事实原位
更正，不改写 r2 的 Git 历史。

r3 起草期已做**符号级同模式扫描**（`AF-015` 要求）：手册 18 项的 `Fact` 行只引用
文件名、零代码符号，未被污染；design §3.1/§3.2 的 11 个符号名中，除本条外仅
`partiallyMechanized`/`semanticReview` 未在仓内其他位置出现，而这两个是本 change
自定义的 `Automation status` 取值域，非外部符号。故符号级污染边界闭合于本条一处；
散文级表述的复核构成 TASK-AFP-004。

CHG-2026-028 已把 Swift CI、三方 revision、结构化完整 pins 与 PR allowed-paths
四个可机器判定面纳入机械化。本 change 不复制这些 guard，也不把知识文档变成
新的规则源；它补齐尚需人类/Agent 语义判断的部分：建立一份短小、非权威、
证据链接驱动的失败模式手册，并把相关选择、生产可达性、可信事实来源与 evidence
freshness 提示接入 change 模板。历史 archive 保持冻结。

## What changes

### TASK-AFP-001 — 非权威失败模式手册

新增 `openspec/planning/agent-failure-patterns.md`，以稳定 `AF-NNN` ID 登记首批
十八类模式。r1 登记的**治理/交付面**九类：

- `AF-001` readiness/allowed-paths 假阳性；
- `AF-002` production root/authority/effect path 不可达；
- `AF-003` caller-controlled trust/provenance/facts；
- `AF-004` producer→consumer 端到端与跨语言类型缝隙；
- `AF-005` evidence freshness、class 与 supersession；
- `AF-006` PR/status/revision/pin 漂移；
- `AF-007` 非 hermetic 环境与本机隐式依赖；
- `AF-008` adversarial matrix 缺口与任务跨信任边界过大；
- `AF-009` 治理机制与实际信任边界错位。

r2 追加的**执行/验证面**九类（详见 design §3.2；每项均有仓内已发生案例）：

- `AF-010` 自证式验证：套套逻辑断言与未经变异证伪的测试；
- `AF-011` 成功判据取错信号：exit code、marker 与管道截断；
- `AF-012` 交付给人类执行的一次性产物未在 host 侧自测（烧设备窗口）；
- `AF-013` 形态照搬：复用既有 harness/设计而未回读目标 capability 的全部 REQ；
- `AF-014` 门只校验凭据存在/形状，不校验语义绑定（fail-closed 弱化）；
- `AF-015` 缺陷类只在发现点修复，未全仓扫描同模式；
- `AF-016` 以会话记忆/摘要代替一手核查；
- `AF-017` 收敛失败：修复轮次引入新架构与过度设计；
- `AF-018` 多会话共享状态与轻信他方声明。

r2 同时对 `AF-001`…`AF-009` 追加已观察子面与修正（design §3.1），不改写任何
r1 已登记的 ID 归属，也不新增任务、acceptance ID 或 gate。

### TASK-AFP-004 — 手册 `Fact` 断言的一手核对与更正（r3 新增）

r3 修正 design §3.2 `AF-014` 的一处未经一手核实的表述（详见下节 Why），并新增
一个 `blocked` 的独立 remediation 任务：对已合入手册 `AF-001`…`AF-018` 的全部
`Fact` 行做一手复核，凡不能由其 pinned 一手出处支持的具体表述，改写为可支持的
表述或降级为 `Inference`；`Inference` 行只检查是否被误写成 `Fact`。

任务边界：只改 `openspec/planning/agent-failure-patterns.md` 与本 change 的
`evidence/**`、`tasks.md`（仅本任务状态/evidence 引用）；不新增/删除 `AF-NNN` ID、
不改 taxonomy 归属、不改八字段契约、不动模板、不改写 archive 或任何历史结论。
新增 change-local acceptance `AFP-CORRECT-001`。

**为什么是全量复核而不是只改这一处**：只在发现点修复正是手册自己登记的
`AF-015`（缺陷类只在发现点修复，未全仓扫描同模式）。r3 起草期已用符号级扫描
排除了一类同型污染（见下节），但**散文级**表述只能靠逐条一手复核，构成本任务
的实质工作量。

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
- **r3 修订（本 PR）**：(a) 在事实原位更正 design §3.2 `AF-014` 的第四条 gap 表述，
  逐条钉到一手出处，并保留 r2 勘误记录；(b) 新增 `blocked` 的 **TASK-AFP-004**
  与 change-local acceptance `AFP-CORRECT-001`，对手册全部 `Fact` 行做一手复核与
  更正。r3 在维护者 review/merge 本 revision PR 后生效。
  r3 **不**改写 r2 的 Git 历史、不改 taxonomy 的 ID 集合与归属、不改八字段契约、
  不动模板、不改 AFP-001/002 的 `done` 结论、不改 archive。
  **连带后果（如实登记）**：r3 改动 `design.md`，而 TASK-AFP-003 readiness r1
  （`#369` 合入 `16325dbe40bad0fd445587e34ef4e99f93a76b9b`）的 pins carrier 钉定了
  该文件的 r2 blob，合并 r3 即使该 pin 漂移。按其自身条款，AFP-003 在实现开工前
  须以 readiness r2 重钉；本 r3 不翻转其状态，也不代其重钉。
- **r2 修订**：仅扩充 TASK-AFP-001 的登记面（`AF-001`…`AF-009` →
  `AF-001`…`AF-018`）并对 r1 九项追加已观察子面。r2 在维护者 review/merge 本
  revision PR 后生效。r2 **不**新增任务、不新增 acceptance ID、不新增 gate/CI/
  parser、不改变任何任务状态（三项仍 `blocked`）、不改变 out-of-scope 与不动面
  清单，也不改变 `AFP-TEMPLATE-001`/`AFP-DRILL-001` 的验收内容；
  `AFP-HANDBOOK-001` 的验收对象由九项 ID 扩为十八项，字段契约与边界条款逐字不变。
