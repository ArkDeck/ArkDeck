# Postmortem:V1 密码学治理体系(2026-07-12 ~ 2026-07-14)

> Status:final
> 本文取代 `governance-recovery.md` 与 `recovery-bootstrap/`(13 文件、约 5,500 行恢复协议);它们的完整内容保留在 git 历史中。

## 发生了什么

V1 治理体系试图用密码学手段防御"自主 AI Agent 伪造证据/静默扩权":三把 ed25519 私钥(approval/claim-service/identity-ledger)、detached SSH signature 审批、仓库外 append-only identity ledger、claim service 与 supersession barrier、逐文件 hash 的 baseline lock 与 relock 仪式、约 12,900 行 guard 脚本。

2026-07-13 ratify CORE-1.0.0 并打开 execution gate;2026-07-14 发现 ledger snapshot 4–10 中 31 组 `(kind,id,revision)` identity 映射到多个 SHA-256(含 `acceptedBaseline/CORE-1.0.0@1` 三个 hash、`TASK-M0A-001@1` 换绑),被当作 P0 事故,催生了 13 文件的恢复协议草案。

## 根因(2026-07-14 全面评审结论)

1. **identity 碰撞不是攻击,是自伤**:31 组碰撞与维护者自己的 relock/re-pin 提交一一对应——ratify 当天为修 CI 就两次原地重写了 accepted baseline(d02b202、28e20c5),每次重写都要重钉 ready packet,每次重钉都产生新的 identity→hash 映射。机制把自己的正常运维记成了"历史改写"。
2. **密码学层对自身威胁模型零防护**:三把私钥与运行 Agent 同机同 UID 可读,`ratify.py` 内置自动签名路径;评审期间实测 Agent 可一条命令伪造能通过 CI 验签的"人类批准"。
3. **ledger 的 append-only 属性为空**:CI 在临时 runner 上每次从空目录重建 snapshot(revision 恒为 1、previous 恒为 null),签名 key 以 secret 注入 agent 分支可触发的 workflow;"跨 run 防历史改写"从未存在。
4. **流程在纸面上就无法走通**:规则强制的"受保护 claim 服务/verification workflow/archive workflow"不存在;union-of-diffs 汇合模型与 dependsOn 任务链结构性冲突(重叠路径必 fail closed);被 hash 冻结的治理文本自相矛盾(gate closed 散文 vs gate open lock)。
5. **恢复方向错误**:恢复协议准备把失败的机制重建成更重的版本(外部串行签名服务、WORM、HSM 边界),而不是回答"这些机制换来了什么"。

## 决策

**采用 V2 git-native 治理**(见 `governance/enforcement.md`):受保护 main + CODEOWNER PR review 是唯一信任根;完整 git 历史是审计账本;CI 只做只读一致性校验;真实防线补在真正缺失的地方——**凭据分离**(Agent 用仅限 `agent/**` 的受限凭据)。

废止并从工作树移除:trust-policy、verifiers、approvals/、ledger/relock/ratify/guard 脚本族、claim/attestation/barrier/lab-authorization contract schema、baseline hash manifest、恢复协议草案。字节级历史全部保留在 git 中,不改写。

CORE-1.0.0 回到 **candidate** 状态,待内容矛盾修复后经一次 PR review 重新 ratify。V1 的"approved/ready"记录(chg-2026-001 及其 task)按人类真实意图保留为 approved,不再依赖签名文件证明。

## 教训

- 治理机制的强度必须与部署现实匹配:密钥与被防对象同账户时,签名只是仪式。
- 单人 + AI 项目的稀缺资源是维护者注意力;每个把关点都要回答"它拦住了什么 PR review 拦不住的东西"。
- guard 越复杂,它本身越成为最大的变更面与事故源(本次事故完全由治理机制自身产生,0 行产品代码受影响)。
- 先让流程能走通一个真实任务,再谈加固。

## 遗留人类动作项

见 `governance/enforcement.md` 的"V1 遗留清理":删除/轮换 `/Users/Shared/arkdeck-trust/` 私钥、移除两个 GitHub secrets、为 Agent 配置受限推送凭据。
