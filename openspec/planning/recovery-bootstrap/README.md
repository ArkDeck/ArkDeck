# Governance recovery bootstrap candidate

> Status: draft / non-authorizing
>
> Source decision: `APPROVE-RECOVERY-BOOTSTRAP`, 2026-07-14
>
> Current execution gate: closed / quarantined

本目录把治理事故恢复拆成可审查的 SDD candidate。用户决定只授权
draft、静态分析和无副作用验证；它不授权 containment、密钥操作、外部
配置、签名、approval、claim、发布或打开 execution gate。

## 为什么位于 planning

当前 guard 只认识 `arkdeck-behavior` 与 `arkdeck-platform`。现有 Task
contract 又强制产品 Requirement/AC、Core、Platform、Integration 和
Conformance pins，无法合法表达修复治理 authority 本身的操作。

因此，本 candidate：

- 只位于 `openspec/planning/recovery-bootstrap/`；
- 不创建 `.openspec.yaml`、Change lock、Task packet 或 approval；
- 不使用正式 CHG/TASK/APR identity；
- 不修改 accepted protected bytes；
- 不追求完整 guard 绿色，guard 应继续对现有污染状态 fail closed；
- 等待仓库外 human recovery authority 后，才允许在隔离 staging 中生成
  exact protected candidate。

## 文件

- `incident-observations.json`：对已签 snapshots 1..10 的可复算只读观察，
  包含已知最少 31 组 identity collision 和 snapshot 内全部 legacy identity；
  不是正式 incident attestation。
- `bootstrap-scope.yaml`：当前授权边界、产品不变式和允许的恢复输出类别。
- `arkdeck-governance-schema.yaml`：V1 封闭式 recovery schema 设计；不是
  已注册 OpenSpec schema。
- `artifact-contracts.yaml`：所有 source/lock/result/publication artifact 的
  exact field、序列化、hash 与 stage 约束；正式 candidate 仍须生成完整 JSON Schema。
- `ledger-v2-contract.yaml`：新 trust epoch、持久 ledger、quarantine 和
  external verifier 的 contract candidate。
- `recovery-authority-contract.yaml`：五个人工 gate 的外部 subject、字段与
  不可继承授权规则。
- `candidate-patch-manifest.template.yaml`：B..R 逐文件 exact patch manifest
  模板；空模板永远不能授权执行。
- `publication-transition-manifest.template.yaml`：R→S、S→T、T→P 在 parent/child
  均已存在后使用的 external exact-diff 模板；R 只锁 path/role plan，不锁未来 bytes。
- `bootstrap-protocol.md`：五个人工 gate 与 B/R/S/T/P publication 流程。
- `acceptance-cases.yaml`：RB-001..RB-022 的二值验收定义。
- `verification.md`：测试、证据与责任映射。
- `human-runbook.md`：人工 containment、轮换、ratification 和 reopen handoff。

## 固定结论

1. 旧 snapshots、approval、packet、lock 和 Git history 全部保留；不得选择
   一个“正确 hash”后删除其余历史。
2. 已暴露 trust epoch 按 presumed-compromised 处理；没有证据证明私钥已被
   实际窃取，但旧 epoch 不再具有执行授权能力。
3. 已知最少 31 个直接 collision identity 永久 tombstone；Gate 2 发现更多时
   必须更新 manifest 并重新批准。所有 legacy identity 即使没有碰撞也永久保留，
   不得复用；引用旧 epoch authority 的衍生对象不得获得 eligibility。
4. 三类 key 分离并全部轮换：human approval、claim service、identity ledger。
5. Agent/PR workflow 永远不持长期 signing secret；权威 ledger 由持久、
   序列化、Agent 不可访问的外部服务签发。
6. `CORE-1.0.0` 保留为 quarantined history。Candidate 精确提出尚未分配的
   `CORE-2.0.0`；正式 recovery authority 必须先证明该 ID 全局未使用再分配/接受。
   若证明失败，整个 candidate 失效并重审，Agent 不得静默改成其他名称。
7. 产品 `openspec/specs/**`、所有 Requirement/Scenario、POL-* normative block、
   Core acceptance registry 和产品 contract 在恢复中必须 byte-identical。
8. 恢复完成不会自动批准 CHG-003；它仍需 fresh pins、独立 Change/Task
   approval 和正常 claim。
9. Gate 1 前必须建立独立 recovery authority root。它只签 recovery lineage，
   不能签普通 Change/Task/claim/ledger；target operational root 由它批准创建，
   并且只有 Gate 5 才能激活。
10. Bootstrap 只能消费一次固定 repository/schema/epoch slot，slot 有独立 rollback
    witness；B/R/S/T/P 必须是 exact 单父链，R 不得锁定任何未来 stage bytes/hash/OID。
11. Gate 4 只产生 non-authorizing candidate component bundles；Gate 5 authorization
    也不直接激活任何对象。只有单一 rollback-resistant CAS 发布且独立读取到的 latest
    signed activation head `state=current` 才产生 current authority，claim 每次分配与
    commit 都必须重新验证并固定该 head。Head payload、signature 与 pointer 原子可见；
    rollback-witness pin 在 slot reservation/ceremony 固定，Gate 3 只能原样采用。

## 下一个人工 gate

本 candidate 完成审查后，下一步不是执行，而是二选一：

- `RECOVERY-CONTAINMENT`：由仓库外保护操作员冻结 gate、停止旧 key 使用并
  保存 WORM 取证材料；
- `RECOVERY-DRAFT-REVISE`：仅返回修改意见，继续保持所有外部状态不变。

聊天确认不替代正式 authorization。正式记录必须绑定 exact committed
candidate、canonical full Git OID、incident manifest hash、operator、nonce、
有效期、单调 recovery sequence 和 operation allowlist。
