# Governance Enforcement

> Version:2.2.0(git-native;2.2.0 = CHG-2026-046 ADDED"控制平面分离"节、MODIFIED"批准语义"的 PR 载体规则为垂直交付单元形态,2026-07-29;2.1.0 = CHG-2026-027 TASK-BAP-001 于"批准语义"节 ADDED 决策分级与批次审批协议两小节,2026-07-22)
> Status:current
> 取代 V1 密码学治理链;背景与事故记录见 `openspec/planning/postmortem-2026-07-governance.md`。
>
> **适用范围收窄(2026-07-30,产品闭环优先阶段)**:本文件的信任模型与「合并进
> main = 人类批准」语义全局有效;其余流程条款(决策分级、批次审批协议、change 级
> `verified`/archive 独立载体、验证确认与实现分离)仅适用于安全内核治理——恰四类
> Repo 审批(新 operation/破坏性修改、新 provider、新 profile、E2 安全策略)与
> `PRODUCT-LOOP.md` §3 安全条件触发的治理工作。日常产品交付按仓库根
> `PRODUCT-LOOP.md` 执行:一个问题一个垂直产品 PR,不再产生 readiness/status/
> verified/archive-only 载体;与本文件冲突时以 `PRODUCT-LOOP.md` 为准
> (`AGENTS.md` 权威顺序)。

## 信任模型

威胁模型保持不变:自主 AI Agent 可能伪造证据、静默扩权、绕过验收。V2 的防线是:

1. **受保护 `main` 分支**:禁止 force-push 与删除;合并需要人类 CODEOWNER(@lvye)的 approving review;必需状态检查 `sdd-guard` 通过。
2. **PR 作者与批准者分离**:Agent 推送 `agent/**` 分支,`agent-pr` workflow 以 `github-actions[bot]` 身份开 PR,维护者 review。
3. **凭据分离(人类运维要求)**:Agent 使用仅能推送 `agent/**` 分支的受限凭据(fine-grained PAT 或 deploy key);维护者的账号凭据与批准动作不出现在 Agent 可达的进程/密钥环里。在凭据分离落实前,"Agent 无法自批"只是软约束——这是 V1 失效的直接教训。
4. **完整 git 历史即审计账本**:批准、内容与时序都由 main 的提交历史承载;CI 以 `fetch-depth: 0` 全历史检出。不引入仓库外 ledger、签名快照或本地私钥。

## 批准语义

- **合并进 main = 人类批准**。change 的 approved、任务的 ready、baseline 的 ratified 都通过维护者批准对应 PR 生效。
- 状态写在文档 front matter/正文中(如 proposal.md 的 `status:`),经 PR 修改;Agent 在自己的分支上可以起草状态变化,但只有维护者合并后才生效。
- Git revision 引用一律使用完整 commit OID;branch、tag 名、缩写不构成固定引用。
- **PR 载体与内容一致(一个垂直交付单元一个 PR;2.2.0 = CHG-2026-046 MODIFIED)**:每个垂直交付单元(一个任务的实现 + 测试 + 文档 + evidence + 该任务的状态翻转)以声明该任务的独立 PR 交付;PR 不得携带超出其标题/描述所声明范围的内容。**readiness-only、status-only、done-only、verified-only 独立 PR 形态废止**:readiness 结论(pins、风险确认、边界)并入 proposal 或交付 PR 正文;任务 done 状态随实现 PR 翻转。例外保持独立载体的恰两类——change 级 `verified`/archive(独立决策,见下一条),与 D2 窗口/授权载体(其本身是 D2 决策)。proposal 可携带 `status: approved` 落地:维护者 review + merge 该 proposal PR 即构成批准,无需再开 approval-only PR。"合并即批准"的前提是维护者知道自己批准的是什么——载体与内容不符会使批准失真,发现后须在 evidence 或 postmortem 中记录。
- **验证确认与实现分离**:change 的 `verified` 翻转不得只依附实现 PR 的 review;翻转 `verified` 的 PR 应只包含状态与 evidence 引用(run 记录、复验记录),使验证判断可与实现批准分开追溯。
- **作废 PR 立即 close**:被治理裁定作废或被后续 PR 取代的 open PR(如被 supersede 的 remediation 草案、失效的实现尝试),维护者应在裁定生效时立即 close,并在取代 PR 的描述中记录取代关系;"body 里写着 do-not-merge"不构成防线——open 列表中的作废 PR 是误合事故隐患(2026-07-20 #126 误合、#133 revert 教训)。
- **merge 载体可核验**:维护者合并 PR 时应使用 GitHub squash merge(commit subject 携带 `(#N)`),或在本地 merge 后于 commit subject 补记 `(#N)`,使 git 账本单独可核验每次合并的 PR 关联。当 git 历史中出现无 `(#N)` 的合并时,审计者不得仅凭 git 账本断言"绕过信任根",必须先以 `gh pr view <n> --json reviews,mergedBy` 核验 GitHub 侧的 review/merge 元数据再下结论(2026-07-19 #117-#123 窗口曾致三个独立审查者误判)。

## 控制平面分离(Repo/Runtime;2.2.0 = CHG-2026-046 ADDED)

- **Repo Agent Plane**:代码、契约、`Catalog/`、provider、profile 与安全策略
  的一切变更,载体是 OpenSpec change + PR,信任根与批准语义不变。**恰四类
  变化需要 OpenSpec/PR 审批**:新 operation 或对已发布 operation 的破坏性
  修改;新 provider;新 integration/device profile;E2 安全策略变化。
- **Device Agent Runtime Plane**:执行已合入 main 的 catalog 所定义的 typed
  operation。**已发布 operation 的每次执行只生成 runtime job 记录(job/
  session/artifact),不生成 Git task、不开 PR**;runtime 请求不携带也不
  要求 `changeId`/`taskId`/PR OID/主干 commit OID,仓库溯源只作为已发布
  operation bundle 的可选构建来源信息存在。
- 运行时授权凭据是 **Runtime Capability**(CHG-2026-046 T03):E0 由默认
  只读策略允许(仍受 target/timeout/bytes/privacy 约束);E1 需 scope/
  期限/次数受限的 standing capability;E2 需绑定精确 plan digest 与
  artifact hash 的一次性 capability。**E2 capability 与既有 standing
  authorization 的信任根相同**:创建/修改/吊销的唯一载体仍是维护者 merge
  的 PR,本节不弱化"真实硬件与 destructive 操作"节的任何规则。
- 两平面的分界由 catalog 承载:operation 的 effect/授权/步骤/预算只在
  catalog 中定义一份,发布(merge)后 Runtime Plane 照 catalog 执行;
  catalog 之外不存在可执行的 operation。

### 决策分级(D0/D1/D2)

对每个待维护者合并的决策点分级(CHG-2026-027)。分级只决定该项在批次审批中的
组织方式,**不改变"每个 PR 都需维护者 review/merge"这一事实**;D* 作用于
PR/决策维度,与执行分级 E0/E1/E2(设备维度,CHG-2026-025)正交。分级记录在
批次 digest 与 PR 注记中,不引入仓内状态字段。

- **D0 — 机器可判定状态推进**,同时满足三条件:(a) 结论由 main 已合入状态 +
  确定性检查(guard、测试套件、merged OID 复核、引用扫描、hash/pin 比对)
  完全决定,不依赖新的人类判断;(b) diff 零新 scope、零新风险接受、零新
  授权;(c) 不改变任何权威文件(constitution/specs/contracts/enforcement/
  AGENTS.md)的语义。三条件缺一即非 D0;**拿不准按 D1**。典型:change
  verify 翻转、archive、evidence rerun/复验记录、pins 无漂移复核(任务
  done 翻转自 2.2.0 起随垂直交付 PR 同车,不再单独成 PR/决策点)。
- **D1 — 人类判断**(封闭列举,扩列须经治理 PR):change approval、readiness
  (首次风险接受 + pins 锁定 + 窗口/边界确认)、DEC-* 产品决策、ADR、Core
  delta 与 baseline ratification、proposal revision(r2+)、机制冻结例外、
  postmortem 定性。
- **D2 — 物理与授权**:设备窗口执行安排、standing authorization 的创建/修改/
  吊销、E1 per-device capability evidence 的接受、凭据与权限配置变更。D2 项
  通常伴随维护者仓外动作,digest 须写明该动作。

### 批次审批协议

- **队列载体 = GitHub issue**(命名 `batch-YYYYMMDD-N`)。审计正本永远是批次
  合并产生的逐 PR merge 记录(`(#N)` subject 惯例);issue 只是导航,close
  即归档,不承载任何批准语义。
- **入队门(三条全过才入队)**:CI 绿;独立 AI 合前 review APPROVE(实现与
  review 必须是不同会话,无 APPROVE 不入队);digest 字段完整(模板
  `openspec/templates/batch-digest.md`,TASK-BAP-002 交付;交付前以
  CHG-2026-027 design §2 字段面为准)。
- **合并语义**:维护者按 digest 声明顺序逐 PR review/merge。**每次合并仍是
  逐项批准;digest 无批准语义;任何等级(含 D0)不存在 auto-merge;
  "CI 绿 ≠ 批准"不变**。
- **遇拒停链**:批次内某 PR 被拒绝或要求修改,即停止其依赖链的合并(digest
  声明依赖它的后续项本轮不合),被拒项回炉走正常修复流程;无依赖关系的其余
  项可继续。
- **宽度并行,零投机堆叠**:批次吞吐来自多 lane 并行;D1/D2 判断门之后的
  成 PR 工作在该门合入前不得开工(门后唯一允许的预跑 = 不产生 PR 的采集/
  勘察);D0 机械序列可同 lane 连续排入。
- **fail closed**:守望会话对合并状态以 merge OID 确认(不以分支消失或时间
  推断);无法确认即保持暂停,不猜测续跑。

## CI 校验(sdd-guard)

`scripts/check-sdd.sh` 在每次 push/PR 运行,只做只读一致性校验:

- 所有 YAML/JSON 可解析,拒绝 duplicate key;
- Requirement/AC ID 全局唯一;每个 Requirement 至少一个 Given/When/Then Scenario;
- `verification/acceptance-cases.yaml` 与 `verification/acceptance-index.txt` 与 specs 中的 AC 集合三方精确一致;
- `contracts/capability-registry.yaml`:每个 capability 对应存在的 spec 目录,release class 合法,`requires` 闭包无未知项、无环;
- 每个 change 目录含必需 artifact(proposal/tasks/verification),front matter status 合法;
- delta spec 的 ADDED/MODIFIED 标题格式与 ID 规则。

CI 红 = 不能合并;CI 绿 ≠ 批准。授权判断永远来自维护者 review。

## 真实硬件与 destructive 操作

- 执行分级(CHG-2026-025,POL-AGENT-002):**E0** 已发布 read-only operation 由默认只读策略在正常 target/tool/timeout/bytes/privacy 准入后可无人值守执行，不需要 Git Task/PR；**E1** deviceMutation 须有匹配的 per-device `RuntimeCapability`；**E2** destructive 须有精确 maintainer-merged `standingAuthorization` 或同一受监督交互会话的精确 `evolutionCampaignConfirmation`。两种 E2 authority 都须逐项匹配计划和目标；campaign 还固定 base/scope/toolchain/预算，最多 16 个串行 attempt、四小时、并发一。
- 每个 E2 attempt 在首个真实设备 Step 前都 SHALL re-materialize typed plan、校验 authority/candidate pins、做 fresh target/binding readback 并 reserve ordinal。只有前一 attempt durable terminal 且完整 outcome/readback 分类为 `safeToReflash` 时，才可自动继续；未知、unsafe、drifted、过期、超限或无 reservation 永久零新 dispatch。普通 CI、scheduler/daemon 与无上述 authority 的 Agent 仍只允许 contract、fake、simulated、plan-only 分支。
- 真实硬件 evidence 必须记录 executor(human 或 agent)、实际 effect/typed Step kinds 和按实际 effect 匹配的 authority reference（Agent E0=`defaultReadOnlyPolicy`、E1=`runtimeCapability`、E2=`standingAuthorization|evolutionCampaignConfirmation`）、设备身份摘要/binding、固件/工具版本、fresh target confirmation、attempt ordinal、执行时间和 Artifact reference/hash。campaign 不得记作 standing authorization；schema-valid evidence 只记录 provenance，不签发 capability 或授权 dispatch。
- simulation/fake/plan-only 证据必须显式分类，永不计入真实硬件验收。Agent 不得自行创建、修改或批准 standing authorization；其授权与吊销的载体仍是维护者 merge 的 PR，git 历史是授权审计账本。

## Baseline

- 候选 baseline 记录在 `openspec/baselines/`(版本 + 范围说明)。ratification = 维护者批准声明 ratified 的 PR;此后对 specs 的语义修改必须走 change delta 并升版 `CORE-x.y.z`。
- 不再维护逐文件 hash manifest 与 relock 仪式;规格漂移由 PR review + CI 的 ID/结构校验兜底,历史对比用 `git diff <ratification-commit>`。

## V1 遗留清理(人类动作项)

- 删除或轮换 `/Users/Shared/arkdeck-trust/` 下的三把 ed25519 私钥(approval/claim-service/identity-ledger);它们曾与 Agent 同账户可读,视为已泄露。
- 移除 GitHub secrets `ARKDECK_TRUST_BUNDLE`、`ARKDECK_LEDGER_KEY`。
- 为 Agent 配置仅限 `agent/**` 的受限推送凭据。
- `openspec/approvals/`、trust-policy、verifiers、ledger 脚本已从工作树移除;历史字节保留在 git 历史中,勿改写历史。
