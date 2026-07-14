# Governance recovery bootstrap protocol

> Status: draft / non-authorizing

本协议把恢复分成五个必须独立确认的人工 gate。任何较早 gate 都不蕴含较晚
gate，聊天中的 `APPROVE-RECOVERY-BOOTSTRAP` 只覆盖 Gate 0 的 draft 工作。

## Roles

| Role | Responsibility | Forbidden |
| --- | --- | --- |
| Drafting Agent | 起草 candidate、计算公开 hash、运行无副作用测试 | 私钥、签名、外部配置、claim、发布 |
| Human security owner | 接受 incident、批准 containment/key transition | 把聊天确认当 detached approval |
| Independent recovery authority | 在 Gate 1 前通过仓库外 fingerprint ceremony 建立，只签 recovery lineage | 普通 Change/Task/claim/ledger subject |
| Protected recovery operator | 在 exact authorization 下操作外部服务和隔离 staging | 扩大 allowlist、修改产品规则 |
| Independent verifier | 从 WORM 历史和外部服务验证结果 | 信任 candidate guard 的自报结论 |
| Protected publisher | 只发布 exact 已批准 result | 重建、修补或替换 result bytes |

同一自然人承担多个角色时，operator credential、approval credential 和 service
credential 仍须分离；每一步保留独立审计事件。自动化 Agent 永远不能承担后四个
角色。

`independentRecoveryAuthorityRoot` 必须在 Gate 1 前由人类通过 out-of-band
fingerprint ceremony 确认，ceremony 固定 fingerprint 算法、verifier build、human-
presence 方法、control boundary 与 revocation rule，且不受旧 operational keys、target
root、仓库或 Agent 控制。它批准 Gate 1..5 和 target operational root 的创建/激活；
target root 不能批准自身。每个 recovery subject 必须绑定上一 subject 的 exact ID/hash，
外部服务对 `(repository, recovery slot, lineage, sequence)` 做唯一 CAS。

## Gate 0 — Draft candidate

当前状态：已由 `APPROVE-RECOVERY-BOOTSTRAP` 授权。

允许：

- 在 `openspec/planning/recovery-bootstrap/` 起草非规范 candidate；
- 读取公开 repository bytes、public keys 和已签 ledger records；
- 计算 snapshot、identity collision 和 candidate file hashes；
- 运行 JSON/YAML、静态 guard 和 fake/adversarial tests。

禁止：

- 修改 accepted protected paths；
- 读取、生成、移动、销毁或调用任何 private key；
- 修改 GitHub secret、branch protection、environment 或外部 service；
- 生成正式 recovery identity、approval、claim、run、lock 或 snapshot；
- 把现有 9 个 fail-closed guard errors 隐藏成绿色。

退出条件：candidate files 可审查，protected-file diff 为零，JSON/YAML 结构
通过，guard error fingerprint 没有新增错误。

## Gate 1 — RECOVERY-CONTAINMENT

需要 independent recovery authority 签发的新仓库外人工 authorization。服务在
任何外部动作前原子消费固定 slot
`(repositoryId, arkdeck-governance, recoveryEpoch=1)`；lineage/authority epoch 是服务
写入的 value，不是客户端可换的 key。并发、换 lineage/epoch 或重放只能一个成功。
同一原子 reservation 还固定 rollback-witness service ID/build/fingerprint、activation
sequence，并生成 initial slot/activation heads。紧随其后的首个 formal
`recoveryAuthorityCeremony` subject 必须由已 out-of-band 确认的 recovery root 精确确认
该 pin 与两个 head；Gate 3 只能采用，不能替换。
授权 subject 至少绑定 exact committed
candidate、canonical base OID、operator、nonce、有效期、单调 recovery sequence、
operation allowlist 和 expected evidence。

允许的最小外部动作：

1. 原子采集足以固定暴露窗口的最小状态：Git refs、current key fingerprints、
   current ledger head 和 cloud/workflow audit cursor。
2. 立即从 claim/signing service 层关闭执行资格；只改 Markdown 不构成 containment。
3. 禁止 `agent/**`、PR 和普通 CI 获得任何长期 signing capability。
4. 停止三把旧 key 的授权用途；不得用旧 key 给自己的撤销签名。
5. 在移动或销毁旧 key 前，完成 WORM 保存 snapshots/signatures/chain、approvals、
   locks、packets、Git objects/refs、workflow bytes、run metadata 和外部 registry。
6. 生成不含 private bytes 的 hash manifest 和审计 receipt。

退出条件：旧 epoch 的 signing/claim path 无法再产生当前授权，且取证材料可由
独立 verifier 重新读取。Gate 1 不批准 incident 结论或新 key。

## Gate 2 — RECOVERY-INCIDENT-ACCEPTANCE

人类审批 exact incident inventory 与 quarantine closure：

- 已观察 snapshots 1..10 的 raw SHA-256 和 previous-hash chain，以及外部 registry、
  Git history、CI metadata/WORM store 中发现的任何追加 legacy record；
- 已知最少 31 个 direct collision keys 与全部 observed hashes；正式数量由
  completeness verifier 决定，发现第 32 个必须更新并重新批准 manifest；
- 完整 `legacyIdentitySet`；所有旧 identity 无论是否碰撞都永久禁止复用；
- 三个旧 public-key fingerprints；
- old trust epoch presumed-compromised/non-authorizing disposition；
- direct permanent tombstones 与 transitive ineligibility rule；
- WORM history commitment 和 completeness verifier result。

不得选择一个 observed hash 作为“正确版本”，不得删除其余历史，也不得使用
普通 change supersession 解释污染 authority。

退出条件：外部 incident approval 固定 exact manifest bytes 和 quarantine set。

## Gate 3 — RECOVERY-KEY-ROTATION

Independent recovery authority 审批 exact target operational trust root、三个用途
分离的 public keys、service identity、部署位置、OIDC policy、operator 和 activation
sequence。Target root 不能自签或批准自身创建，并且在 Gate 5 前不具有正常 authority。
Activation sequence 在固定 slot 的原子 reservation 时由服务分配并写入 initial signed
candidate activation head；Gate 3 只能采用该 exact value，不能另选或重置。

约束：

- private keys 只存在于 Agent 不可访问的专用 service/HSM 边界；
- GitHub repository/environment secret 不保存长期 private key；
- diagnostic workflow 无 signing token；
- protected workflow 仅凭短期 OIDC 请求 exact-commit snapshot；
- service 同时验证 issuer/audience、repository、immutable job workflow ref/commit、
  protected ref、protected environment、exact target commit、event、run ID/attempt 和
  operation scope；请求前不得执行 untrusted checkout 或 branch code；
- new verifier 由新 root 固定，旧 verifier 只能用于取证；
- transition record 绑定 incident/quarantine/history hashes、old/new fingerprints、
  subject-type scope 和单调 activation sequence。
- 每个 detached envelope 的 payload ID/hash 与 signer ID/fingerprint 必须 exact equal
  对应 service-role pin；rollback witness pin 在 slot reservation/ceremony 先固定，Gate 3
  只能 exact-adopt，其余 operational service pin 由 Gate 3 固定。攻击者自签但密码学
  有效的 envelope 仍无效。

退出条件：RB-001、RB-004、RB-009、RB-012、RB-020、RB-021 的受控外部测试
通过。Gate 3 不允许发布 repository protected changes。

## Gate 4 — RECOVERY-GOVERNANCE-RATIFICATION

在 Gate 1..3 完成后，Drafting Agent 或无签名能力的隔离 builder 可以先构造
non-authoritative candidate `R`；它不能发布、签名或改变任何 external state。
正式 recovery authorization 随后绑定 exact candidate bytes，受保护 operator
只能重新验证并 stage/publish 同一个 `R`，不能重建或修补它。Authorization 必须绑定：

- incident、quarantine、history commitment 和 recovery lock hashes；
- canonical full base commit `B`；
- 每个 protected output 的 exact path、operation、base hash 和 result hash；
- candidate result revision `R`、operator、nonce、有效期和 recovery sequence；
- 新 root/verifier/public keys 和 ledger checkpoint identity；
- 明确的 product behavior delta `none`；
- 禁止 claim、硬件、产品实现和 scope 外写入。

候选必须增加封闭的 `arkdeck-governance@1`、ledger V2/quarantine contracts、
external authorization/result contracts、secret-free diagnostic CI、protected
publication workflow、guard/selftests，以及一致的 governance current-state。

Fresh baseline/axis bytes 不属于 B..R patch。R 中的 `publication-plan.yaml` 只固定
每个后续 stage 的 exact path/role/mode/type 与可变 JSON pointers，不包含未来 bytes、
hash 或 commit OID。每个隔离 parent/child 都存在后，independent recovery authority
才生成并签发该 transition 的 exact OID/diff authorization。R 还固定每个 stage/role
的正整数 exact cardinality；transition manifest 的 role counts、
全局表 JCS hash 与按当前 transition 过滤后的 stage rows 必须全等，不能把单 stage diff
与全局三阶段 rows 混比，也不能只验证“role 被允许”。本 candidate 固定提出
尚未分配的 `CORE-2.0.0`；若外部服务不能证明该 ID 从未使用，candidate 必须重审，
Agent 不能静默改名。旧 `CORE-1.0.0` bytes 和污染 subjects 保留，不原地重写。

## B/R/S/T/P publication

| Revision | Exact meaning | Allowed diff |
| --- | --- | --- |
| B | recovery authorization 固定的污染源 base | none |
| R | protected operator 生成的 exact repaired candidate | 仅 manifest 中逐文件 add/replace |
| S | metadata child | external R→S authorization 固定的 B/R recovery result mirror |
| T | isolated publication staging | external S→T authorization 固定的 proof、fresh baseline/axis/config；不移动历史 |
| P | publication child | external T→P authorization 固定的 exact approval mirrors 与 publication metadata；authorization 本身不镜像进 P |

任何阶段夹带额外文件都失败。R/S/T/P 先存在于隔离 recovery ref，在 Gate 5 前不可
进入权威分支。Candidate guard 通过只是证据之一；外部 verifier 必须独立验证 B..R，
并为 R..S、S..T、T..P 各验证 parent/child full OID 与 exact diff authorization。
Git 历史必须是单父链 `parents(R)=[B]`、`parents(S)=[R]`、`parents(T)=[S]`、
`parents(P)=[T]`；merge、graft/replace-parent 或任何额外 parent 都失败。
P 存在后再签发 `governanceRecoveryPublicationResult`，它才能绑定完整 B/R/S/T/P、
各 stage authorization、fresh approvals、pre-Gate5 ledger/slot candidate component
bundles 和全部 RB results；S 中的
result 不得未来引用 T/P，任何 stage authorization 不得镜像进自己的 target commit。

Gate 4 的退出条件：除独立 reopen 决策外的 RB evidence 全部通过；fresh Core、
Conformance、Platform、Integration 与 publication subjects 分别取得外部 approval；
持久 ledger 与 slot-witness service 为 exact P 生成 closed candidate component bundle。
每个 bundle 的 pre-activation attestation 只验证 component bytes/signature、连续性、
quarantine 与 independently fetched current head，不验证尚不存在的 Gate 5 activation，
且 authority effect 恒为 none。这样 Gate 4 不依赖 Gate 5，不形成验证环。

这些 target-root approval/snapshot 在 Gate 5 前都带 `recoveryCandidate` 状态；每个
approval 通过 closed candidate envelope 固定 identity/hash、target epoch、lineage 和
Gate 3 activation sequence。Activation manifest 具有自身 ID/revision，并要求 envelope
与 fresh Core/axis subject 一一对应；P、root/epoch、sequence、bundle 与 subject pins 在
Gate 3、publication result、manifest 和 Gate 5 之间 exact equal。任何缺失、额外、重复
或不相等都失败。

## Gate 5 — RECOVERY-GATE-OPEN

这是独立于 Gate 4 的最后人工决定。输入必须是 exact P、
`governanceRecoveryPublicationResult` approval、fresh baseline/axis approvals、ledger
V2/slot-witness candidate component bundles 和完整 RB-001..RB-022 报告。

Gate 5 authorization 本身不执行以下动作；它只在被签发、witness 后把恢复状态推进到
`activationPending`，使一个 exact activation transaction 有资格被构造：

- 将新 trust epoch 标为 current；
- 将新 baseline/locks 标为 current accepted authority；
- 打开 spec execution gate；只有 fresh claim service 的隔离、序列化、capability
  separation receipts 同时通过，claim execution gate 才能另行打开。

它不能：

- 复活任一 quarantined identity；
- 自动批准重新创建的 M0A Change/Task；
- 自动批准 CHG-003；
- 授予真实设备或 destructive hardware 权限。

Transaction 的 hash DAG 固定为 `activation manifest → Gate 5 authorization →
post-authorization slot-witness bundle → pre-commit verifier result →
recoveryGateOpenResultBundle → activation-head receipt`。Result bundle 不包含自己的 hash
或未来 head。所有 participant 只能 prepare non-authorizing candidate；最后由与 slot
witness 同一独立 rollback-resistant 边界对 expected candidate head 做一次 CAS。只有
独立查询到的 latest、签名有效且 `state=current` 的 activation-head receipt 才同时让
manifest 中精确列出的 root/baseline/axis 和两个 gate decision 生效。不存在可独立漂移
的 service-local “open” boolean。

Head payload 与 detached signature 必须先 durable prepare；CAS 把 exact payload、signature
envelope 和 latest pointer 作为一个不可分可见单元发布。Pointer 不能先于签名可见；crash
后只能完成同一 expected-head/payload/signature tuple。

CAS 前后崩溃或响应不确定时，只能用同一 transaction/hash 查询并 reconcile；CAS 失败
没有 authority。服务不可达、snapshot/head stale、history/quarantine 不完整或任一声明
冲突时全部保持关闭。

`claimExecutionGateDecision=true` 必须同时满足 `specExecutionGateDecision=true`；整体
decision 为 rejected 时两个 gate decision 必须都是 false。任一 gate 保持关闭时必须
记录 non-empty reason，不能用空 evidence 推导“默认打开”。

Claim service 在分配 claim identity 前和 atomic commit 内都必须独立取得 latest
activation head，验证 `state=current`、result bundle、`spec=true && claim=true` 及自身
build/key/suite evidence，并把 head raw hash/generation 与 bundle hash 写入 claim/receipt。
head stale、变化、aborted、不可达或由客户端提供时零分配并 fail closed。

若恢复无法安全继续，只有 independent recovery authority root 可沿同一 hash-linked
lineage 签发 `recoveryPermanentAbortAuthorization`。它必须绑定当前 state、原因和 evidence，
expected activation head/hash/generation，并将两个 gate 固定为 false。Authorization 自身
无 effect；witness service 必须在一个 serializable transaction 中记录它并把同一 expected
head CAS 为 `aborted`。Current CAS 与 abort CAS 最多一个成功。只有 independently fetched
latest aborted head 才永久消费 slot；旧但签名有效的 bundle/head 一律拒绝。Abort 不能由
Agent、operator 或服务超时隐式触发。

## Post-recovery reauthorization

1. 用全新 Change/Task/approval identities 重建 M0A；旧文件只作历史证据。
2. CHG-003 保留已确认的 classifier 结构，但重新固定 fresh Core、macOS Platform、
   OpenHarmony Integration、Conformance 和 canonical base OID。
3. CHG-003 分别取得 Change approval 与 Task approval，随后才可原子 claim。
4. 恢复 approval 与 CHG-003/M0A approval 永不合并或相互蕴含。
