---
id: CHG-2026-029-agent-failure-prevention
revision: 5
status: archived # 2026-07-23 本 archive PR；verified #416 merge `bfc11e306890012dc98270178764f356a9e40912`；implementation-only、零 spec/registry delta；目录外旧 active-root 精确路径仅 CHG-2026-027 已退役历史 pin 2 处；仅在维护者 review/merge 本 PR 后生效
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

## r4 追加动因（2026-07-23，archive 就绪扫描）

四任务全部 `done` 后、起草 change 级 verify 前，按 `AF-006` 的"archive 前必做目录外
精确路径引用扫描"执行扫描（`git grep` 全仓，排除本 change 目录），得到两项发现。
本 r4 只登记事实与新增一个 `blocked` 任务，不修复、不改变任何已 `done` 结论。

### 发现 1 — 本 change 的手册在 archive 后会断链（**本 change 自身问题**）

`openspec/planning/agent-failure-patterns.md` 第 24 行以相对路径链接
`../changes/chg-2026-029-agent-failure-prevention/design.md`。手册位于
`openspec/planning/`，**不随 change 归档移动**；archive 一旦 `git mv` 到
`changes/archive/<date>-<id>/`，该链接即断。

这是本 change 唯一的 archive 断链点，须在 archive 前收口 → 新增 **TASK-AFP-005**。

### 发现 2 — 另一 change 的活跃 readiness 钉着本 change 的文件（**跨 lane，不在本

change 授权面内，只登记指针**）

`openspec/changes/chg-2026-027-decision-grading-batch-approval/tasks.md` 的
**TASK-BAP-002（状态 `ready`）** `yaml pins` carrier 含：

```text
- path: openspec/changes/chg-2026-029-agent-failure-prevention/tasks.md
  blob: bbbda9b9f2ebefbe9b360fe2cade4e70712ed724
```

该 blob 对应本 change `tasks.md` 在 `#381` 合入
`cfab930722afe60ed5e8759ea0c91d7a178971cc` 时的状态。此后本 change 的 `#383`
（drill evidence 引用）与 `#384`（AFP-003 `ready→done`，合入
`5a51ec4…`）各改动一次，当前 blob 为
`dc8129773d18349b7e7d5123ce2fa8beefb80b7d`。

**因此该 pin 已经漂移，与 archive 无关**：按 BAP-002 readiness 自身的漂移条款，
其 r2 现已失效，需由 CHG-2026-027 lane 重钉。此外 archive 会使该 path 消失，构成
第二个断点，但其根因是同一条 pin。

**处置（fail closed）**：`openspec/changes/chg-2026-027-**` 在本 change 全部任务的
forbidden paths 内，本 change **不修复、不改写**该 pin，只在此登记 dated 指针与
完整 OID，交回 CHG-2026-027 lane 判断与重钉。**本 change 的 archive PR 在该 pin
被重钉或解除前不得起草**——这是 `AF-006` 的"断链即暂缓"，与 CHG-2026-015 同型
（该先例最终由 provenance re-pin 收口，PR `#351` merge
`583b1c1d4de1a77fc0554908f9b45e28fe604a56`）。

### 已知限制（不在本 r4 修复，登记备查）

手册共有 35 条指向 change 目录的相对链接：10 条指向已在 `archive/` 的目标（路径
稳定），**25 条指向 8 个仍活跃的 change**（chg-006/008/021/022/025/026/028/029）。
这些活跃目标各自 archive 时都会使手册断一批链。TASK-AFP-005 **只收口本 change
自己的 1 条**（archive 阻断项）；其余 24 条属跨 change 的结构性问题，其根因是
"长期存活的索引用相对路径引用会移动的目录"，应另立 change 统一处置（例如改为只
记 change ID + 完整 OID 而不用相对路径），不塞进本 change 的 archive PR。

### TASK-AFP-005 — 手册 archive 断链收口（r4 新增）

新增一个 `blocked` 任务：把手册第 24 行对本 change `design.md` 的相对路径引用改为
**不依赖 change 目录位置**的表述（保留"taxonomy 登记在 CHG-2026-029 design §3"这一
事实指向，去掉会断的相对链接，或改为随归档仍可解析的形式），并复核手册对本 change
目录的其余引用为零。

任务边界：只改 `openspec/planning/agent-failure-patterns.md` 与本 change 的
`evidence/**`、`tasks.md`；不改 `AF-NNN` ID 集合、taxonomy 归属、八字段契约、
`Automation status` 取值域与首屏声明；不动模板、不改 archive、不修复发现 2、
不处理其余 24 条活跃链接。新增 change-local acceptance `AFP-LINK-001`。

### r4 对 verify 顺序的影响

本 r4 使 change-local acceptance 由四条增至五条。**change 级 verify 须在
`AFP-LINK-001` 有可复查 evidence 之后起草**，即顺序为：r4 批准 → AFP-005
readiness/实现/done → verify → （待发现 2 解除后）archive。此调整避免"先 verify、
再对已 verified 的 change 追加修订"这一形态。

## r5 追加动因（2026-07-23，change-level verification remediation）

在 protected `main` `95e56eae0102c37a885c0277089089a02b7bc4fb` 上执行首次
change-level verification 时，五条 change-local acceptance 中三条通过，但
`AFP-HANDBOOK-001` 与 `AFP-CORRECT-001` 被同一个一手事实冲突阻断：

1. r3 已在 design §3.2 明确更正：第四条 gap 是 reliable progress total 可不经
   capability 校验产生；正确的一手形态是
   `chg-2026-021/tasks.md` 的 reliable-total receipt 只可由当前 adapter
   `capability=true` factory 产生，以及 `TASK-TR-002R/run.md` 的
   “Reliable progress totals have no public initializer”；
2. 现行手册 `AF-014` 的 Signal、Fact、Preflight 与 Negative verification 仍保留
   “公开枚举 case 可绕过能力门”这一 r2 已否定的表述；
3. TASK-AFP-004 run 却把 `AFP-CORRECT-001` 记为 passed，且其 readiness source
   inventory 未包含 `TASK-TR-002R/run.md`，因此该结论对 AF-014 不可复查；
4. `verification.md` 已在矩阵中登记 r3/r4 新增的两条 AC，但首段与 Result gate
   仍写“三条”及 `AFP-001/002/003`，与 r4 proposal 的五条验收顺序不一致。

一手 bytes（本 r5 起草基线）：

- `openspec/changes/chg-2026-021-trace-adapter-capture/tasks.md` blob
  `14703a488170143e02b15d3ae496d23cf390864e`；
- `openspec/changes/chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-002R/run.md`
  blob `23434076488e8ef6a10d9d93121cefc4e1c6fd80`；
- 现行手册 blob `6fbb1a706bcf488aa39db672b51f0327a92cdf9b`；
- TASK-AFP-004 run blob `4eed9d2f5ab8d79ef681a6d1473ed31b71d5242b`。

根因仍是本 change 已登记的 `AF-016`（会话记忆替代一手核查），而首次全量复核又
漏过同一已知表述，触发 `AF-015`。旧 run 不追溯改写；按 `AF-005` 新增 addendum，
在当前事实原位建立 supersession/currency 指针。

### TASK-AFP-006 — AF-014 一手事实修正与 evidence addendum

新增一个 `blocked` remediation 任务，封闭完成以下工作：

- 按 design §3.2/r5 §3.3 与上述两份一手 bytes 修正手册 `AF-014` 的四处错误表述；
- 对手册当前全部 `Fact` 行重新执行逐行一手复核，addendum 必须逐行列出 AF ID、
  相对路径、完整 blob OID、可检索位置、判定与处置，不能只给汇总计数；
- 新增 `evidence/runs/TASK-AFP-004/addendum-r5.md`，明确 TASK-AFP-004 run 对
  AF-014 的旧 PASS 结论已被本 addendum 取代；旧 run bytes 保持不动；
- 新增 `evidence/runs/TASK-AFP-006/run.md`，记录实现基线、输入 pins、before/after、
  全链接/OID/不变量/隐私/allowed-paths 检查与两条 AC 的唯一结论；
- 手册 `Currency` 更新为 AFP-006 的实际 implementation audit base。

任务边界只含手册、本 change `evidence/**` 与 `tasks.md` 的本任务状态/evidence 引用；
不改 taxonomy、ID 集合、八字段契约、其他 AF 项的语义、模板、archive、CHG-2026-021
历史 bytes、spec/contracts/governance 或产品代码。任务复用
`AFP-HANDBOOK-001` 与 `AFP-CORRECT-001`，不新增 acceptance ID。

### r5 flow 与批准边界

本 r5 revision PR 只登记 remediation scope、design/verification 与 revision 同步，
并新增保持 `blocked` 的 TASK-AFP-006；**不含手册修复、addendum 或 readiness**。
顺序固定为：r5 维护者 review/merge → AFP-006 独立 readiness → implementation/
evidence → done → 重跑五条 change-local acceptance → 独立 change verified PR。
按 D1 判断门后零投机堆叠，r5 合入前不得起草后续成 PR 工作。

## Verification closure（2026-07-23）

依 `verification.md` Result gate 在 protected `main`
`33050b0ceed5a4cfa400f3eb6829a724200a71de` 上独立重跑（TASK-AFP-006 done #414
`2462f72d71dffe26e3a69a8932fe469e667f2a38` 为其祖先）。
V2 下本节只记录候选结论；五条 AC 的整体确认与 front matter `status: verified`
只在维护者 review/merge 本 verification-closure PR 后生效。

- **r5 固定顺序与人类门**：revision #408
  `3304797578b75d072b3b4dc235dccec35fc7d060` → readiness #410
  `31865366f7bdb8e5ca33f0c8d41c15f6daba7933` → implementation/evidence
  #413 `99dbacd2923ed40b86dbff9f69ef259e16c9fd94` → done #414
  `2462f72d71dffe26e3a69a8932fe469e667f2a38`。四个 PR 均已由 @lvye
  `APPROVED` 并依次合入；零门后投机 PR。
- **任务面**：AFP-001…AFP-006 在该 base 全部为 `done`；每项 implementation/
  evidence 与独立 done merge 均在 ancestry：
  AFP-001 #360 `95dc61cf6ed9223f5b5c1728aaf0d9a1ba6c9d5c` / #362
  `4c8506a30afc5505230134903ccf03729a640c07`；
  AFP-002 #366 `3ed97323225b4614aa537bc707e1c79bb5fb9b36` / #368
  `89f6c916e2724941b3cb9d949c3d925a92ade3db`；
  AFP-003 #383 `493153f65025f177550071b5c7ac5ea7cb0b90d0` / #384
  `5a51ec460409085067bc0e0dacba958d580b79c6`；
  AFP-004 #374 `21d339b97d083f1e79c1851854737d5cf0a68d8e` / #379
  `605bff09fdc992478203109b1e5414b207d553b3`；
  AFP-005 #394 `21445775cef0837fe98381a1750464bcc2a829f8` / #396
  `1b9079268db8e85bee9383f7b705d957f2a9cda3`；
  AFP-006 #413 `99dbacd2923ed40b86dbff9f69ef259e16c9fd94` / #414
  `2462f72d71dffe26e3a69a8932fe469e667f2a38`。
- **`AFP-HANDBOOK-001` — PASS**：手册首屏 non-normative/authority/conflict/
  privacy/archive 边界齐全；H2 = 18（`AF-001`…`AF-018` 唯一同序），H3 = 144
  （18 组八字段同序）；Fact = 36（含 AF-018 dated Fact）、Inference = 18、
  positive = 18、negative = 18；18 项 Currency 全部绑定 AFP-006 implementation
  base `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`。AF-014 同时回源
  CHG-2026-021 tasks 与 TASK-TR-002R run，`PublishedArtifact`、exact
  `revision + 1`、current-adapter `capability=true` factory 与无 public
  initializer 的一手语义在场，错误 public-enum bypass 表述为 0。
- **`AFP-TEMPLATE-001` — PASS**：相对 AFP-002 readiness base
  `9397e23d62434cc9b7cb747d721044442322763f`，tasks/design/evidence-run
  三模板分别只增 13/11/10 行，旧行逐行同序保留；3 + 1 + 4 个封闭字段全在场，
  `none`/`not applicable` 需理由且不自动通过，未创造批准、状态或
  simulation→realHardware 语义。
- **`AFP-DRILL-001` — PASS**：TASK-AFP-003 run 的六个固定案例均有阶段、AF ID、
  模板字段、`Inference` 动作、历史 evidence 与 Fact/Inference 标注；quarantine
  反例保持 `BLOCKED`、`NOT DISPATCHED`、device mutation/destructive = 0/0，
  未升级为产品失败或 realHardware。#383 的合入 diff 仅为本 change run 与
  `tasks.md` 两个路径，archive/history bytes 零改动。
- **`AFP-CORRECT-001` — PASS**：r5 addendum 明确旧 AFP-004 run 的 AF-014
  结论已 superseded；F01…F36 唯一无缺号，47 个 source path/blob pair 全部与
  implementation base bytes 精确相等；36/36 为 `supported`，35 retained +
  F27 rewritten；旧 run blob 保持
  `4eed9d2f5ab8d79ef681a6d1473ed31b71d5242b`。手册 22 枚完整 commit OID
  全部存在且在本 verification base ancestry；Fact 命名 symbol 16/16 可在手册与
  本 change 外解析。
- **`AFP-LINK-001` — PASS（r5 增量口径）**：`openspec/planning/**` 对本 change
  目录名的引用为 0，taxonomy 的 change ID / `design.md` §3 / r4 完整 OID 指向
  在场。AFP-005 implementation merge #394 上的标准 Markdown link 实际为 **97**
  （change links 34 = 10 archive + 24 active）；其 run 表中的“全部链接 98”是
  off-by-one，本闭包不沿用该总数。r5 #413 按 AFP-HANDBOOK/CORRECT 的一手来源门
  只新增一条 TASK-TR-002R run 链接、删除原 24 条中的 0 条；当前为 98 条标准链接
  （56 anchors，全部解析），change links 35 = 10 archive + 25 active。因此
  AFP-LINK 所指的 r4 原有 24 条活跃链接确实逐字未动；新增第 25 条是 r5 明确授权
  的 AF-014 first-source delta，不被误记为 AFP-005 当时已存在。
- **共同边界与仓库门**：六个 implementation merge 的 diff 均只落手册、三个模板或
  本 change 路径；archive/spec/contracts/governance/product diff 为 0。相对链接、
  56 个 anchors、完整 OID 与 source blob 复核均通过；交付面用户绝对路径、
  裸 64-hex、private-key marker 为 0；无 raw evidence、设备标识或 secret 复制。
  `scripts/check-sdd.sh` = 0 error / 0 warning / 111 acceptance IDs；
  `git diff --check` 干净；验证期间 GitHub open PR = 0。全程 host-only
  `documentReview`，device/HDC/network/process/effect/destructive dispatch = 0，
  真实硬件 = 无。首次推送后并发 #415 使 main 从 #414 前进到本 verification base；
  该 merge 只改 CHG-2026-030 的 proposal/design/tasks/verification，与本 change、
  手册、模板及 evidence 零路径交集；更新 base 后上述门全部重跑。

剩余风险保持已登记边界：手册是语义 review 导航而非机械 gate；当前另有 25 条活跃
change 相对链接会随各自未来归档而断，须由独立 change 统一收口；本 verified 状态
不把手册提升为权威规则，不改变产品/platform/conformance/support 状态，也不授权
未来 CI/guard 或 archive 工作。

## Archive closure（2026-07-23）

- Verification closure PR #416 已由 @lvye `APPROVED` 并合入 protected `main`
  `bfc11e306890012dc98270178764f356a9e40912`，本 change 的 `verified` 状态已生效。
- Archive audit base 为 protected `main`
  `e69a0c23b327571327bfce4a87d5e50f406db256`；其最新并发 #417 只修改
  CHG-2026-030 `tasks.md`，与本 change、手册、模板和 evidence 零路径交集。
- 本 change 为 `implementation-only`，无 spec delta、canonical acceptance
  registry、Core baseline、integration/platform profile 或产品实现需要合入；archive
  的有效变更只有 proposal `verified→archived` 与整棵 change 目录迁移到
  `openspec/changes/archive/2026-07-23-chg-2026-029-agent-failure-prevention/`。
- 归档前目录外精确 active-root 扫描仅命中 CHG-2026-027 `tasks.md` 两处：一处
  readiness r3 的 dated 漂移叙述，一处 readiness r2 的旧 `yaml pins` carrier。
  CHG-2026-027 readiness r4 #391
  `98593848defa91f73e6537bd7d151d58fcc42428` 已合入并明确这些实现期
  authority/input pins “随实现合入完成使命退役”，其任务随后由 #398
  `ab5bccef0ae544789c8345276df983ff551cfbee` 置 done、change 由 #399
  `09d4afd77b213efd07a5f8b0d07f1be23d71d095` 置 verified；两处现为冻结的
  historical process record，不是 living authority，不在本 archive PR 改写。
- `openspec/planning/**` 对旧 active-root 的引用为 0；手册使用 change ID、
  `design.md` §3 与完整 OID 定位，归档不造成该指向断链。其他目录外
  `CHG-2026-029` 命中均为 change ID/历史名称引用，不含旧目录路径。
- CHG-2026-021 r3 登记的 archive 顺序门因此满足其“CHG-2026-029 已归档”分支；
  本 PR 不替该 change 执行后续 archive，也不改写其 scope、evidence 或 living
  consumers。

本 archive 只改变治理位置与状态，不重新验证历史 AC，不改变手册权威边界、产品/
platform/conformance/support 结论，也不产生任何 device/HDC/network/process/effect/
destructive dispatch。
