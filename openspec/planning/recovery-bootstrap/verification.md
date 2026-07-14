---
status: plannedNonAuthorizing
acceptance_namespace: RB
acceptance_count: 22
---

# Governance recovery verification candidate

> Status: planned / non-authorizing

所有 RB ID 仅属于本 planning candidate，不是 accepted Core/platform AC。Contract
测试可以由 Agent 起草和运行；`controlledExternalTestReceipt` evidence 必须由仓库外
保护环境生成并由独立 verifier 验证。

## Current draft gate

当前阶段只要求：

1. `openspec/planning/**` 之外没有由本 bootstrap 产生的 unstaged/staged change；
2. JSON/YAML/Markdown 结构与 duplicate-key 检查通过；
3. 完整 guard 保持现有 fail-closed，错误 fingerprint 不新增 bootstrap 引入项；
4. 不访问 private key、外部 secret、GitHub setting、network service 或设备。

完整 RB-001..RB-022 只能在后续 protected recovery 环境验证。

## RB-001

从 standard Agent、同 UID sandbox、`agent/**` 和 PR workflow 请求 private-key read
或 signer token。所有请求必须拒绝并产生外部审计 receipt；测试不能把真实 key
暴露给测试进程。

## RB-002

Independent verifier 从 WORM source 重算 snapshots 1..10、signatures、chain、
approvals、locks、packets 和 Git subjects。结果固定 exact incident manifest hash，
并扫描 secret/private material 为零。

## RB-003

把外部重建 collision set、完整 legacy identity set 与 quarantine manifest 做排序后的
exact equality。31 只作为 draft 已知最小 collision 数；所有 legacy identity（包括未
碰撞者）永久保留且禁止复用，整个 exposed trust epoch 为 non-authorizing。若完整性
扫描发现任何新增 identity 或 collision，旧 manifest/approval 必须失效并重新生成。

## RB-004

分别从 preserved evidence 选取由旧 approval、claim-service、ledger 三个 fingerprint
签发的历史签名，仅用 public key 验证其密码学有效性，再把各 subject 提交 current
epoch eligibility。历史验证可成功，current authority 必须因 epoch/quarantine 拒绝；
测试不得读取或重新调用任一旧 private key。若某 key class 没有可验证的历史样本，则
改用 external key-registry revocation 查询和 verifier-substitution vector 证明其 current
authority 为零，禁止为了补样本制造新的旧-key 签名。

## RB-005

为 baseline、Change、Task、approval、claim、verification、archive 和 release 分别
构造 direct/transitive quarantined reference。所有路径在任何 side effect 前失败。

## RB-006

Clean runner A 请求 snapshot，重启 ledger service，再由 clean runner B 请求下一
snapshot。验证 ledger revision、global sequence、previous hash、history commitment
和独立 witness checkpoint 连续；本地空目录不能触发新权威 genesis，service restart
后读取到的 witness minimum sequence 不得降低。

## RB-007

在 serializable transaction 中提交同 identity/same hash 两次，再提交同
identity/different hash。前者幂等，后者回滚；比较 transaction 前后完整 state hash。

## RB-008

两个 writer 固定相同 expected predecessor 并发提交不同合法 inventory。仅一个
CAS 成功；另一个得到 conflict，服务中不存在同 revision fork。

## RB-009

分别 replay old snapshot/bundle/verifier、降低 trust epoch/global sequence，并把
database、head pointer、signer state 与所有 service backup 一起回滚。Verifier 必须从
独立 control boundary 取得更高 witness minimum 并拒绝每个 vector，保留外部审计事件。

## RB-010

Golden vectors 至少覆盖：invalid ledgerId、missing/extra field、empty entries、duplicate
identity、unsorted entries、bad previous hash、revision skip、incomplete inventory、
quarantine omission 和 valid signature over invalid semantics。

## RB-011

对同一 snapshot 依次提供 exact protected commit、其他 ancestor、descendant、branch
name、short OID 和 dirty working tree identity。只有 exact canonical full OID 通过。

## RB-012

OIDC matrix 覆盖 trusted publication workflow、`agent/**` push、PR、fork、unpinned
workflow path/ref、错误 issuer/audience/repository/event/operation/run identity。只有同时
满足 immutable workflow ref/commit、protected ref、protected environment、exact target
commit、run ID/attempt 和 operation scope，且请求前没有执行 untrusted checkout/code 的
完整 tuple 通过；snapshot/audit receipt 必须绑定该 tuple。

## RB-013

对 ledger、approval、claim、verifier 分别注入 timeout、connection reset、partial
response、stale snapshot 和 ambiguous status。Spec execution gate 与 claim execution
gate 独立保持关闭，Ready/claim/dispatch 恒为零，本地 generator/signing fallback 恒为零。

## RB-014

机器抽取 Constitution、project、enforcement、trust policy、config、baseline lock/
manifest、Integration/Platform/Conformance locks 的 current state，要求单一 baseline、
trust epoch 和 gate 结论；再取得 external signed review。

## RB-015

从 B 的完整 protected set 与 CORE manifest 展开 default-frozen regular files，再计算
`bootstrap-scope.yaml` 的 fully frozen files、mixed-file named projections、preserved
history 和 exact governance output allowlist。对 B/R 比较 path/mode/type/raw blob hash；
产品 specs/architecture/integration/platform/conformance/contracts 和全部 Requirement/
Scenario/POL/Safety/Agent/hardware/fail-closed projection 必须 exact equal，不接受语义近似。

## RB-016

External ledger 在 Gate 2 完整 legacy identity set、collision tombstones、preserved V1
history 和 new epoch 全局查询每个 proposed root、ledger、baseline、Change、Task 与
approval identity。任何已出现 key（即使从未碰撞）失败；fresh IDs 原子保留后才可
进入 candidate result，Git clone/reset/history rewrite 不改变查询结论。

## RB-017

这是 Gate 5 前的 policy/preflight 测试，不执行真实 gate mutation。先证明 candidate
guard/recovery tests 绿色但缺 gate-open approval 时 gate 必须关闭；再用隔离 verifier
验证 positive/negative authorization vectors 是否精确绑定 P、publication result、
activation manifest、candidate component bundles、baseline/axis approvals 以及 spec/claim
两个独立 decision。Envelope 与 fresh subject 必须双射；Gate 3、publication result、
manifest、Gate 5 的 P/root/epoch/sequence/bundle/subject 重复 pin 必须 exact equal。

逐点在 Gate 5 authorization sign、slot witness append、pre-commit verify、result bundle
生成及 activation-head CAS 前后注入 crash/timeout/ambiguous response。Authorization、
post-authorization witness、verifier result 或 result bundle 任一单独存在时 authority 恒为
零；只有 independently fetched latest signed head `state=current` 才生效。Negative vectors
至少包含 `spec=false, claim=true`、overall `rejected` 但任一 gate=true、envelope/subject
非双射、任一重复 pin 不同或 stale expected head；还必须证明 `Gate5=rejected`、slot
record 非 accepted `publicationVerified→activationPending` advance 或 pre-commit verifier
`decision=failed` 时不能生成 Ready result bundle、不能 CAS current。任一 ledger/slot
pre-activation attestation 为 `failed`、签名无效、commitment/head 不匹配时，其 bundle
必须派生为 ineligible，PublicationResult 不能 passed。全部必须 reject。
Current CAS 后，claim
allocation 与 commit 都必须重读相同 latest head，验证 `spec=true && claim=true` 并固定
head hash/generation/result-bundle hash；任何变化或不可达均零分配。

## RB-018

在 fresh recovery state 中仅保留 CHG-003 structural decision，依次缺失 fresh Core/
Platform/Integration/Conformance/base pins、Change approval、Task approval；每种情况都
拒绝 Ready/claim。全部具备后也只进入正常 eligible，不自动 claim。

## RB-019

静态扫描 recovery schema、authorization、operation plan、runtime capability 和实际
B..P diff；HDC/device/USB/UART/TCP/Flash/destructive dispatch authority 必须为空。

## RB-020

对 independent recovery root、normal human approval、claim service、identity ledger
service 和 publication OIDC 运行完整 credential × subject-type matrix。只有各 credential
的唯一允许用途成功；human approval 必须证明 human presence。每个错误组合、自签、旧
key、target root 提前使用和 repo-local key 均拒绝并生成外部审计 receipt。另运行
publication OIDC scope × lifecycle matrix：Gate 5 前只允许 create/read recoveryCandidate
component，latest activation head 为 current 后才允许 create/read current bundle；token、
provider context、workflow policy、requested scope 或 epoch/anchor 任一不等都拒绝。对
verifier、ledger、slot witness 与 activation head envelope 逐一替换 payload ID/hash、
signer ID/fingerprint 或使用攻击者自签的“有效”key；operational signer 必须等于 Gate 3
role pin，witness signer 必须等于 reservation+ceremony pin 且被 Gate 3 exact-adopt，任一
不等都拒绝。

## RB-021

在第一个 containment 外部动作前，让两个并发请求消费相同固定 slot
`(repositoryId, arkdeck-governance, recoveryEpoch=1)`；只能一个成功，lineage/authority
epoch 与 activation sequence 由服务写入 value 而不是客户端 key。随后以新 lineage、
伪造 authority epoch/activation sequence、不同
nonce、Git clone、reset、history rewrite 和 service restart 重试，均必须命中不可删除的
`recoveryEpochConsumed` 记录并拒绝。失败请求不能产生部分 containment、签名、sequence
或 gate side effect；同 lineage 恢复只能沿更高、hash-linked sequence 继续。把 slot
service database、head、signer 与 backup 一起回滚后，独立 slot witness 仍须暴露已消费
slot 和不降低的 state/sequence，不能重新进入 available/reserved。再对一个 rejected
subject 和一个人工批准的 permanent-abort subject 分别在 witness 后整体回滚；前者的
sequence/predecessor 仍不可复用。让 current result-bundle CAS 与 approved permanent-abort
CAS 竞争同一 expected activation head，只能一个成功；在 abort sign/witness/CAS 前后注入
crash 与 ambiguous response，只能按同 subject/hash reconcile。Abort 成功后提交旧但签名
有效的 slot bundle、candidate activation head 或 current result bundle，latest external
head 仍须为 aborted，旧对象全部拒绝，slot 永久 consumed 且 spec/claim gate=false。
另把 Gate 3 rollbackWitness service entry/field 改成不等于 reservation+ceremony pin，必须
拒绝 key transition；在 reserved、contained、incidentAccepted 各用替换 witness 签 early
abort，aborted head 必须无效且不得伪造 slot state transition。

## RB-022

在 ledger transaction 的 predecessor verify、DB pending commit、sign、independent
witness append、authoritative mark、snapshot publish 和 head pointer update 前后逐点注入
crash。重启 reconciliation 必须得到唯一 witnessed linear head，或保持 fail closed；
signed-but-unwitnessed、witnessed-but-unpublished 与 published-but-head-stale 状态均不能被
客户端当作授权 snapshot，也不能形成 orphan、fork 或重复 sequence。Snapshot 仅包含
witness reservation/previous hash，witness record 也不包含自身 hash；只有 snapshot、
detached signature、external witness record 和 exact `publishedHeadReceipt` 的一致 bundle
在 Gate 5 前也只能成为 authority-effect-none 的 candidate component。验证
`component payload → pre-activation attestation → outer component bundle → activation
manifest → Gate 5 authorization → post-authorization witness → pre-commit verifier result →
result bundle → activation-head receipt` 是单向 hash DAG；任何 self/future/outer reverse
reference 都失败。再在 candidate/current/aborted activation-head receipt 发布前后注入
crash，验证 previous-head chain、generation、detached signature、same-payload idempotency 和
different-payload conflict。特别在 payload/signature durable prepare 与 latest-head CAS
可见性边界注入 crash：`current/aborted` pointer 不得在 exact payload/signature 缺失时可见，
restart 只能完成同 expected-head/payload/signature tuple。没有 exact latest head receipt 时
任何 bundle 都不产生 authority。
Snapshot/witness/verifier/activation-head 的 detached envelope 还必须同时绑定 exact payload
ID/raw hash 与对应 pin；witness/activation-head 使用 reservation+ceremony pin 并由 Gate 3
exact-adopt，其余使用 Gate 3 service role pin。替换为另一个密码学有效 signer 也必须失败。

## Required adversarial suite

- second recovery epoch or second `arkdeck-governance@1` proposal;
- governance package containing `specs/**`, product REQ/AC or modified POL block;
- ordinary Task packet, standardAgent claim or controlledHardwareLab workaround;
- path glob, traversal, symlink, delete, wrong base/result hash or scope-extra write;
- incident omission/duplicate/unsorted item or modified historical snapshot;
- immutable ID remap, deletion, chain reset, stale snapshot and concurrent fork;
- repo-local verifier/trust root, signer substitution and Agent-readable key;
- missing/expired recovery authority, wrong operator/nonce/sequence/B/R;
- B/R/S/T/P stage with any extra file;
- stage manifest raw hash, explicit field mapping, required-role cardinality or single-parent mismatch;
- old baseline identity reuse or missing declared-platform revalidation;
- generator signing after guard returns non-zero;
- wrong credential/subject cross-use or missing human presence;
- second recovery lineage after clone/reset/history rewrite;
- second recovery request using a different lineage or authority epoch;
- crash before and after each ledger transaction/witness publication step.
- pre-Gate5 verifier incorrectly requiring activation or claiming current authority;
- non-bijective candidate envelope/fresh-subject set or cross-Gate pin mismatch;
- Gate 5 authorization/result bundle without latest current activation-head CAS;
- concurrent current/abort CAS, stale signed head and claim-time head change;
- pre-Gate5 current-snapshot OIDC scope or post-abort current-bundle read.

## Evidence bundle

Recovery result evidence must index immutable records for all 22 tests, exact commands or
service requests, exit/decision, source/result hashes, verifier identity, deviations and
remaining risks. Aggregation may summarize but cannot replace raw controlled-external
records or their independent approvals.
