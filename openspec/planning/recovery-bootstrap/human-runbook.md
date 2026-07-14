# Human recovery handoff

> Status: draft checklist; no operation is authorized

本 runbook 只说明后续人工批准需要看什么。它故意不包含私钥命令、secret 值或
可以从普通 Agent 环境直接执行的签名步骤。

## Before any containment action

- [ ] 通过仓库外 channel 确认 independent recovery authority root ceremony；记录
      fingerprint 算法/值、verifier build、human-presence 方法、control boundary 与
      revocation rule。它不由旧 key、target root、仓库或 Agent 控制，只允许 recovery subjects。
- [ ] 确认 exact candidate 已提交，并记录 canonical full Git OID；未提交 working
      tree 不能成为 authorization subject。
- [ ] 原子记录 current Git refs、ledger head、old public-key fingerprints 和 cloud/
      workflow audit cursor；该最小 capture 完成后立即执行 kill switch，不等待完整取证。
- [ ] 核对 `incident-observations.json` 的 10 snapshots 和 31 collision groups；
      正式 manifest 必须由外部 verifier 重新生成/验证，不能直接信任 Agent 文件。
- [ ] 指定 human security owner、protected operator、independent verifier 和
      protected publisher identities。

## Authorization template requirements

每个正式 recovery authorization 必须至少包含：

- subject type 与全新 subject ID；
- exact repository ID 与 canonical full base/result OID；
- exact incident、quarantine、history commitment、patch manifest hashes；
- human approver 与 protected operator；
- operation allowlist 和逐文件 expected output；
- nonce、有效期、单调 recovery sequence 和 trust epoch；
- new public-key fingerprints、service identity 和 verifier hash；
- product behavior delta `none`；
- 明确禁止普通 Task claim、产品实现、HDC、设备与 destructive hardware；
- external verification receipt 和 append-only audit reference。

聊天 token、repo-local JSON、Markdown checkbox 或本地 guard 绿色均不能替代该
authorization。

## RECOVERY-CONTAINMENT review

- [ ] 固定 `(repositoryId, arkdeck-governance, recoveryEpoch=1)` slot 已被外部服务
      原子消费一次；lineage/authority epoch 由服务分配，换值或并发第二次请求均失败。
- [ ] Slot 的独立 rollback witness 已记录 consume/state/sequence；整体回滚 slot
      database/head/signer/backup 仍不能重新消费或降低 state。
- [ ] 外部 execution/claim/signing gate 已 fail closed。
- [ ] `agent/**`、PR 和普通 CI 无长期 signing secret/token。
- [ ] 旧 approval、claim-service、ledger key 已停止授权用途。
- [ ] 旧 key 处理前的 WORM evidence 已完成并由独立 verifier 读取。
- [ ] WORM evidence 覆盖 Git refs/objects、approval registry、locks/packets、workflow
      bytes/run metadata、snapshots/signatures/chain，且不含 private key/secret。
- [ ] 没有删除/改写旧 snapshot、approval、packet、lock 或 Git history。
- [ ] 没有用旧 key 签署其自身撤销或新 trust epoch。

## RECOVERY-INCIDENT-ACCEPTANCE review

- [ ] Snapshot 1..10 raw hashes、signatures、previous-hash chain 完整。
- [ ] Snapshot 1/2 empty entries 与 ledger ID schema mismatch 已保留为 findings。
- [ ] 已知最少 31 个 direct collision identities 及全部 observed hashes 完整、排序、
      唯一；外部 completeness scan 发现更多时已更新并重新批准 manifest。
- [ ] 完整 legacy identity set 已从 snapshots、Git history、external registry、CI
      metadata 和 WORM evidence 合并；所有旧 ID 均永久禁止复用。
- [ ] 旧 trust epoch 全部 authority 被标记 non-authorizing。
- [ ] Direct tombstone 与 transitive reference rejection 都进入 quarantine contract。
- [ ] 没有从冲突 hashes 中选“正确值”。

## RECOVERY-KEY-ROTATION review

- [ ] Target operational root 由 independent recovery authority 批准，未自签、未由
      old key 签发，并且 Gate 5 前保持 non-authorizing。
- [ ] 新 root 无法由旧 key 签发或回退。
- [ ] Human approval、claim service、identity ledger 三类 key 分离。
- [ ] Private keys 不在 repository、Agent filesystem、GitHub secret、workflow env、
      artifact、evidence 或日志中。
- [ ] OIDC policy 固定 repository、trusted workflow identity、trusted ref/environment、
      issuer/audience、immutable workflow ref/commit、protected ref/environment、exact
      target commit、event、run ID/attempt 和 operation scope；请求前未执行 untrusted code。
- [ ] `agent/**`、PR checkout、untrusted workflow ref 的 signer 请求被拒绝并审计。
- [ ] Old bundle/verifier/key epoch 的 replay 被拒绝。
- [ ] Recovery root、human approval、claim、ledger、publication OIDC 的 subject-type
      capability matrix 逐个 cross-use 测试均拒绝错误组合。
- [ ] Verifier、ledger、slot witness、activation-head detached envelopes 的 payload
      ID/hash 与 signer ID/fingerprint exact equal 对应 service-role pin；witness pin 由
      reservation/ceremony 先固定且 Gate 3 exact-adopt，攻击者自报 fingerprint 或替换成
      另一个有效 signer 均失败。

## RECOVERY-GOVERNANCE-RATIFICATION review

- [ ] `arkdeck-governance@1` 只接受一次 `recovery-bootstrap`，不能用于通用治理。
- [ ] No ordinary Task packet、standardAgent claim 或 controlledHardwareLab workaround。
- [ ] Candidate protected diff 与逐文件 manifest 精确一致，无 glob/symlink/delete。
- [ ] Product specs、Requirement/Scenario、POL-* blocks、Core acceptance、capability 和
      workflow-step registries byte-identical。
- [ ] 新 governance/ledger/quarantine contracts 和 adversarial tests 完整。
- [ ] Diagnostic CI 零 secret；publication 只消费外部服务 exact-commit snapshot。
- [ ] Source CORE-1.0.0 和污染 subjects 原 bytes 保留并 quarantine。
- [ ] Fresh baseline/Conformance/Platform/Integration/approval IDs 从完整 legacy identity
      set、quarantine 和 new ledger 查询确认从未出现。
- [ ] 每个 fresh approval 都是 `recoveryCandidate` envelope，固定 target epoch、lineage
      与 Gate 3 activation sequence；envelope ID/hash 与 fresh subject ID/hash 一一对应，
      Gate 5 manifest 只列出 exact candidate hashes。
- [ ] R 的 plan 只预分配后续 path/role/mode/type/pointers，不含 S/T/P bytes/hash/OID；
      R→S、S→T、T→P 各自在隔离 parent/child 已存在后取得 exact external authorization。
- [ ] R 固定 stage/role/count table；每个 transition manifest 的 cardinality hash、entry
      role counts 与该全局表按 `stage == transition` 的 projection exact equal，没有把
      单 stage diff 与全表混比，也没有只凭“permitted role”放行的路径。
- [ ] B/R/S/T/P diff 与各阶段 external authorization 全部通过；S result 只绑定
      B/R，stage authorization 不镜像进自己的 target，P 后 publication result 才绑定完整链。
- [ ] Git commit parents 精确为 `R←B←`、`S←R`、`T←S`、`P←T` 的单父关系；
      merge、graft/replace-parent 或额外 parent 已拒绝。

## RECOVERY-GATE-OPEN review

- [ ] RB-001..RB-022 均有 exact evidence 和 independent publication-result approval。
- [ ] 新 ledger 在两个 clean runner 与 service restart 之间保持连续。
- [ ] 并发 writer、identity remap、reset、replay、signer substitution 全部失败。
- [ ] 独立 rollback witness 能发现 service DB/head/signer/backup 整体回滚；每个事务
      crash point 都没有产生可授权 orphan/fork；snapshot/witness record 无自引用，
      candidate component bundle 含 exact published-head receipt 和不依赖 Gate 5 的
      pre-activation verifier attestation。
- [ ] Constitution、project、enforcement、trust policy、config、baseline/manifest 和
      locks 对 current gate/baseline 给出一致结论。
- [ ] External service 为 exact publication commit 提供 read-only verified snapshot。
- [ ] Gate 4/5 绑定的是完整 ledger 与 slot-witness candidate component bundle ID/hash，
      不是可替换的单个 snapshot/record hash；P、root/epoch、sequence、envelope、fresh
      subject 和 bundle 在 publication result、manifest 与 Gate 5 exact equal。
- [ ] Gate-open approval 独立于 ratification approval，且仍不批准 M0A/CHG-003。
- [ ] Gate-open subject 仅进入 `activationPending`；manifest→authorization→witness→
      verifier→result bundle→activation head 是单向无环 DAG。只有 rollback-resistant
      CAS 产生、独立查询到的 latest signed `state=current` head 才生效。
- [ ] Activation payload/signature 已 durable prepare；CAS 把 exact payload、detached
      signature 与 latest-head pointer 作为一个不可分可见单元发布，缺任一项时 pointer
      不得表现为 current/aborted。
- [ ] Spec execution gate 与 claim execution gate 分开；claim service 的持久化、
      序列化、key isolation 和 capability receipts 未通过时后者保持关闭；Gate-open
      subject 固定 exact claim service ID/build/key fingerprint、suite hash 与 receipt hashes。
- [ ] Claim allocation 与 commit 都重新读取 latest activation head，并把 head hash/
      generation/result-bundle hash 固定进 claim；stale/aborted/unavailable 时零分配。
- [ ] Current 与 permanent-abort 对同一 expected activation head 并发 CAS，只能一个
      成功；旧但签名有效的 pre-abort head/bundle 不被接受。

## If any check fails

保持 execution/claim/signing gate closed；保存新 evidence；不得本地 fallback、降低
AC、重用 identity、重签旧 bytes 或把 staging 发布到权威分支。返回 candidate
draft/review，而不是尝试“让 guard 先绿起来”。若必须永久终止，只接受 independent
recovery authority root 沿当前 predecessor chain 签发的 exact permanent-abort subject；
该 subject 必须把 spec/claim gate 固定为 false，并由独立 witness 在一个 serializable
transaction 中记录后把 expected activation head CAS 为 `aborted`；subject 自身无 effect。
