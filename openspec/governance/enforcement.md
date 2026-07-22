# Governance Enforcement

> Version:2.1.0(git-native;2.1.0 = CHG-2026-027 TASK-BAP-001 于"批准语义"节 ADDED 决策分级与批次审批协议两小节,2026-07-22)
> Status:current
> 取代 V1 密码学治理链;背景与事故记录见 `openspec/planning/postmortem-2026-07-governance.md`。

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
- **PR 载体与内容一致(一任务一实现 PR)**:每个任务的实现以该任务命名的独立 PR 交付;readiness、remediation 或状态 PR 不得携带超出其标题/描述所声明范围的实现内容。"合并即批准"的前提是维护者知道自己批准的是什么——载体与内容不符会使批准失真,发现后须在 evidence 或 postmortem 中记录。
- **验证确认与实现分离**:change 的 `verified` 翻转不得只依附实现 PR 的 review;翻转 `verified` 的 PR 应只包含状态与 evidence 引用(run 记录、复验记录),使验证判断可与实现批准分开追溯。
- **作废 PR 立即 close**:被治理裁定作废或被后续 PR 取代的 open PR(如被 supersede 的 remediation 草案、失效的实现尝试),维护者应在裁定生效时立即 close,并在取代 PR 的描述中记录取代关系;"body 里写着 do-not-merge"不构成防线——open 列表中的作废 PR 是误合事故隐患(2026-07-20 #126 误合、#133 revert 教训)。
- **merge 载体可核验**:维护者合并 PR 时应使用 GitHub squash merge(commit subject 携带 `(#N)`),或在本地 merge 后于 commit subject 补记 `(#N)`,使 git 账本单独可核验每次合并的 PR 关联。当 git 历史中出现无 `(#N)` 的合并时,审计者不得仅凭 git 账本断言"绕过信任根",必须先以 `gh pr view <n> --json reviews,mergedBy` 核验 GitHub 侧的 review/merge 元数据再下结论(2026-07-19 #117-#123 窗口曾致三个独立审查者误判)。

### 决策分级(D0/D1/D2)

对每个待维护者合并的决策点分级(CHG-2026-027)。分级只决定该项在批次审批中的
组织方式,**不改变"每个 PR 都需维护者 review/merge"这一事实**;D* 作用于
PR/决策维度,与执行分级 E0/E1/E2(设备维度,CHG-2026-025)正交。分级记录在
批次 digest 与 PR 注记中,不引入仓内状态字段。

- **D0 — 机器可判定状态推进**,同时满足三条件:(a) 结论由 main 已合入状态 +
  确定性检查(guard、测试套件、merged OID 复核、引用扫描、hash/pin 比对)
  完全决定,不依赖新的人类判断;(b) diff 零新 scope、零新风险接受、零新
  授权;(c) 不改变任何权威文件(constitution/specs/contracts/enforcement/
  AGENTS.md)的语义。三条件缺一即非 D0;**拿不准按 D1**。典型:任务 done
  翻转、change verify 翻转、archive、evidence rerun/复验记录、pins 无漂移
  复核。
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

- 执行分级(CHG-2026-025,POL-AGENT-002):**E0** 只读采集与 host 侧分析在 approved change 的 ready 任务范围内可无人值守执行;**E1** 可逆 deviceMutation 另需 per-device typed capability evidence;**E2** destructive 须持维护者经 merged PR 预先批准的 standing authorization(逐项 pin 目标设备身份/binding revision、固件、transport、HDC、Provider、Step 集合、plan hash、恢复路径、有效期与次数),执行门在首个真实设备 Step 前逐项校验并做设备身份读回,任一缺失或不一致即 fail closed(零 dispatch,记 blocked-attempt)。
- 普通 CI(无 standing authorization 载体的自动化,如 GitHub Actions)仍只允许 contract、fake、simulated、plan-only 分支。
- 真实硬件 evidence 必须记录:executor(human 或 agent;agent 另记 authorizationRef)、设备身份(型号/序列号摘要/binding)、固件/工具版本、执行时间、执行的确切命令与结果;destructive 操作另需记录执行前的目标确认(人工物理确认,或与授权逐项比对的机器身份读回)。格式见 `contracts/hardware-evidence.schema.json`。
- simulation/fake/plan-only 证据必须显式分类,永不计入真实硬件验收。Agent 不得自行创建、修改或批准 standing authorization;授权与吊销的载体都是维护者 merge 的 PR,git 历史即授权审计账本。

## Baseline

- 候选 baseline 记录在 `openspec/baselines/`(版本 + 范围说明)。ratification = 维护者批准声明 ratified 的 PR;此后对 specs 的语义修改必须走 change delta 并升版 `CORE-x.y.z`。
- 不再维护逐文件 hash manifest 与 relock 仪式;规格漂移由 PR review + CI 的 ID/结构校验兜底,历史对比用 `git diff <ratification-commit>`。

## V1 遗留清理(人类动作项)

- 删除或轮换 `/Users/Shared/arkdeck-trust/` 下的三把 ed25519 私钥(approval/claim-service/identity-ledger);它们曾与 Agent 同账户可读,视为已泄露。
- 移除 GitHub secrets `ARKDECK_TRUST_BUNDLE`、`ARKDECK_LEDGER_KEY`。
- 为 Agent 配置仅限 `agent/**` 的受限推送凭据。
- `openspec/approvals/`、trust-policy、verifiers、ledger 脚本已从工作树移除;历史字节保留在 git 历史中,勿改写历史。
