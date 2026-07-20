# Governance Enforcement

> Version:2.0.0(git-native)
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

- Agent(以及任何自动化)不得对真实设备执行 destructive 操作;只能产出 plan 与人工执行步骤。
- 真实硬件 evidence 必须记录:操作者(人类)、设备身份(型号/序列号/binding)、固件/工具版本、执行时间、执行的确切命令与结果;destructive 操作另需记录执行前的人工目标确认。格式见 `contracts/hardware-evidence.schema.json`。
- simulation/fake/plan-only 证据必须显式分类,永不计入真实硬件验收。

## Baseline

- 候选 baseline 记录在 `openspec/baselines/`(版本 + 范围说明)。ratification = 维护者批准声明 ratified 的 PR;此后对 specs 的语义修改必须走 change delta 并升版 `CORE-x.y.z`。
- 不再维护逐文件 hash manifest 与 relock 仪式;规格漂移由 PR review + CI 的 ID/结构校验兜底,历史对比用 `git diff <ratification-commit>`。

## V1 遗留清理(人类动作项)

- 删除或轮换 `/Users/Shared/arkdeck-trust/` 下的三把 ed25519 私钥(approval/claim-service/identity-ledger);它们曾与 Agent 同账户可读,视为已泄露。
- 移除 GitHub secrets `ARKDECK_TRUST_BUNDLE`、`ARKDECK_LEDGER_KEY`。
- 为 Agent 配置仅限 `agent/**` 的受限推送凭据。
- `openspec/approvals/`、trust-policy、verifiers、ledger 脚本已从工作树移除;历史字节保留在 git 历史中,勿改写历史。
