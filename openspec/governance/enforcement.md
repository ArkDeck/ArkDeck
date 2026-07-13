# Governance Enforcement

> Version：1.0.0  
> Status：review  
> Execution gate：closed until ratification

## Valid human approval

Proposal 的 `status: proposed` 和 verification plan 的 `Status: planned` 在 change approval 后保持不可变。`approved` 由 exact change lock 推导，`implementing` 由有效 claim 推导，`verified` 由精确绑定 change lock、verification plan、所有 active done run、AC 和 result commit 的 `verification-result.json` 及其外部批准推导。编辑 Markdown/YAML 状态不构成转换。有效 approval 必须符合 `contracts/approval.schema.json`，并引用以下至少一种外部不可由执行 Agent 单独伪造的机制：

1. 受保护 Git branch/PR 上由配置的人类 CODEOWNER 给出的 approving review；
2. 由受信任人类 key 生成、可验证的 detached signature；
3. 组织批准系统返回的 immutable approval ID，并由 CI connector 验证。

Approval 必须绑定 subject ID、revision、content hash、base commit 和 approver identity。Task approval 的 `subjectSha256` SHALL 是已冻结单个 Task packet JSON 文件原始 UTF-8 bytes 的 SHA-256；claim 和 run sidecar 不在该 hash 内，也不得改写 packet。Change/baseline/archive approval 分别绑定该版本由 guard 生成的 immutable subject manifest hash。CI/guard 验证失败时，change/task/baseline 仍是未批准。

任何名为 base/result/source/implementation/repository revision 的 Git pin 都必须是 `rev-parse <value>^{commit}` 返回值本身，并符合仓库对象格式的 canonical full OID（SHA-1 为 40、SHA-256 为 64 个小写十六进制字符）。`HEAD`、branch、tag、缩写或其他 revspec 即使当下可解析也一律无效，不能通过移动 ref 改写已批准 subject。

Change lock 固定 proposal、scope、delta/spec-impact、design、immutable verification plan、review 和 canonical acceptance registry，但不固定派生的 `tasks.md` 索引或独立批准的 Task packet。Task packet union 必须始终精确等于锁定 scope；新增 replacement 不能扩张 scope，并须通过自己的 Ready/Task approval 与原 run 的 `taskSupersession` approval。该分离使 replacement 可追加，同时保持旧 change lock、claim 和审批时序有效。

V1 的 Change ID/revision 与 Task ID/revision 都是单写：revision 固定为 1。批准后的 change scope/source 变化必须创建带 `supersedes_change_id` 的新 Change ID；Task 分解变化使用新 Task ID。Guard 在 live 与全部 archive 组成的全局命名空间中检查 Task、claim、Task+attempt、run 和 attestation identity 唯一，并要求同一 approved subject identity 只能映射一个 immutable hash；旧 ID、lock、packet、claim 和 run 不能被重用、r2 覆盖或删除。

`supersedes_change_id` 只允许指向一个已外部批准的 predecessor，且 proposal 必须预分配唯一 `supersession_barrier_attestation_id`；lineage root 的该字段必须为 null。全部 proposal link 必须无环，同一 predecessor 最多只能有一个获得外部批准的 successor。Successor 的 exact change-lock approval 是 fail-closed 的 change-level `superseded` 终态边界，不是注释：批准前，受保护治理 coordinator/claim service 必须以同一串行化 transaction 签发符合 `change-supersession-barrier.schema.json` 的 `supersession-barrier-attestation.json`。该 proof 绑定 exact predecessor/successor locks 与预分配 approval ID、服务 ledger revision、全局单调 lineage sequence、`closedAt`，并完整列出每个 claim 及其 exact claim/run/owner bytes；外部 verifier 必须对不可删除 ledger 验证 inventory 完整性和所有 lease 已由原 owner 终态化。Successor approval 必须严格晚于 `closedAt`。仅比较仓库当前文件或 wall-clock、删除 sidecar、事后回填文件/时间戳均不能形成边界。边界生效后 predecessor packet 仅保留作历史，claim eligibility 被撤销；不得新建 claim、继续 change verification 或在边界后批准 archive。被替代 Change 留在 live history，或在边界生效前已按 verified archive gate 归档。

Barrier 的 lock identity 由 Change ID/revision、content hash 与 approval ID 组成，不包含可变仓库路径；因此唯一的 live→archive 目录移动不会要求改写已签发 proof，任何同 hash 的多位置副本仍由全局 identity/approval guard 拒绝。

Guard 还会反向扫描所有 `taskPacket` approved attestations：每个批准必须在 live 或 archive 中解析到唯一、byte hash 完全相同的 packet。删除或用同一 Task ID 改写已批准 packet 会留下 orphan approval 并失败；受保护 Git/外部 approval registry 负责保证 approval 本身不可被执行 Agent 删除。

仅扫描当前 Git tree 不能证明“历史 ID 永不复用”。execution gate 打开后，受保护 CI 还必须通过 `ARKDECK_IDENTITY_LEDGER_SNAPSHOT` 注入仓库外、只读、独立 verifier 验真的 append-only snapshot。Snapshot 绑定 repository revision，并逐项固定所有 immutable Task packet、claim、run、attestation、approval、approved subject、change/archive lock、evidence/release subject 与 accepted baseline 的 identity/revision/hash；guard 要求该完整 inventory 与当前 tree 精确相等。Ledger service 负责 previous snapshot hash 与 revision 单调性，删除旧 archive/approval/sidecar、改写历史或复用 ID 都不能从 ledger 中移除旧条目。缺 snapshot 时 execution gate fail closed。

Core MINOR/MAJOR change proposal 与新 Core baseline 在进入批准前都必须携带 declared target platforms 的精确 `platform_revalidation` matrix。Guard 独立校验 change 和 baseline，不以 Task 已进入 `ready` 为前提；当前交付平台不得使用 `deferred`，future/non-shipping 平台的 `deferred` 仍会阻止其支持声明与发布。

Platform lock 为每个平台保存 `notStarted | verified | needsReverification | nonConformant`、最后 verified Core baseline/conformance hash 和外部批准 evidence。新 Core baseline 与旧 verified pin 不一致时，guard 拒绝继续显示 `verified`，必须先改为 `needsReverification`；不得靠改写 profile 文本延续旧结论。

本地解析 attestation 字段不能验证人类身份，仓库内 policy 也不能指定批准自己的 trust root。Guard 只有在受保护 CI/宿主通过 `ARKDECK_TRUST_ROOT_BUNDLE` 注入仓库外 bootstrap root、该 root 固定当前 policy hash 和 verifier 集合，且对应 verifier 对 attestation 与 exact subject 返回成功时，才接受 approval。单纯在本机设置同名环境变量或运行本地 guard 不构成批准；权威结论来自受保护执行环境。当前 external root 与 trust policy 均未配置，因此所有执行/ratification gate 必须保持 closed。

仓库中的 `trust-root-bundle.example.yaml` 只定义格式，永远不是 trust root。真实 bundle 必须由受保护 CI secret、只读 mount 或等价宿主控制提供，包含 root ID、当前 policy hash，以及 verifier 的机制/subject-type scope、绝对路径和 executable hash。

## Current bootstrap state

Git 仓库已在 2026-07-13 的 one-time governance bootstrap 中初始化，`.github/CODEOWNERS` 仅是待人类填写真实身份的占位；受保护 review/CI、外部 trust-root bundle 和受信任 signing key 均未配置。因此：

- `CORE-1.0.0` 当前是 review candidate，execution gate closed；
- `chg-2026-001-macos-m0a` 保持 proposed，Task 保持 draft；
- Agent 可以继续审查/修正规格，但不能宣称 approved/ready 或开始产品实现。

## Candidate relock and guard self-test

候选期（baseline 未 accepted、execution gate closed）内，protected 文件的任何编辑都必须随后运行 `python3.14 scripts/relock_baseline.py` 重生成 file manifest 并重钉 lock 内的 manifest hash，保证 `scripts/check-sdd.sh` 在每个 commit 上保持绿色；带着 hash mismatch 的树不得作为任何后续工作的基础。规则：

- protected 集合的唯一定义是 `scripts/sdd_protected_set.py`，guard 与 relock 工具共同消费；两处各自维护清单是被禁止的。SDD 工具链固定使用 `.python-version` 声明的 CPython 精确版本与 `scripts/requirements-sdd.txt` 固定的依赖版本，版本不匹配时 fail closed；这两个文件是 pin 的唯一来源，工具代码不得另行硬编码版本。本机/CI 建议 `python3.14 -m venv .venv-sdd && .venv-sdd/bin/pip install -r scripts/requirements-sdd.txt`；`scripts/check-sdd.sh` 的解释器解析顺序为 `ARKDECK_PYTHON` 显式覆盖 → 仓库内 `.venv-sdd` → PATH 上的 `python3.14`，无论选中哪个都仍由 runtime gate 二次校验。
- relock 工具只对候选 baseline 生效：lock `status: accepted`、`accepted_at` 非空、`approval_ref` 已设置或 execution gate 已 open 时必须拒绝运行。ratification 之后的任何变化都走 approved Core change 和新的 `CORE-x.y.z`，永不原地重写。
- relock 输出 added/removed/changed 漂移报告；提交前人工审查该报告，确认漂移只包含本次有意的编辑。
- `scripts/guard_selftest.py` 是 guard 的对抗性自测：在隔离副本上逐项注入违规（protected 内容篡改、未登记 protected 文件、manifest 篡改/乱序、acceptance index 缺失/未知 ID、重复 AC、无 Scenario 的 Requirement、Task packet 状态自提升、platform profile 篡改），断言 guard 逐项报错，并验证 relock 的修复与拒绝行为。CI 必须同时要求 `scripts/check-sdd.sh` 与 `python3.14 scripts/guard_selftest.py` 通过；guard 语义的任何修改都必须先补充能证明新检查会失败的自测用例。

## One-time governance bootstrap

为避免“必须先有 guard 才能创建 guard”的死锁，只有在用户明确要求执行 governance bootstrap 时，单个 Agent MAY 在无并发执行者的前提下：

- 初始化版本控制；
- 安装 baseline/spec guard；
- 配置人类 owner/CODEOWNERS 或受信 approval key；
- 在 Agent 不可控制的 CI secret/read-only mount 中安装 bootstrap trust-root bundle；
- 配置仓库外 append-only identity ledger service、独立 verifier 与受保护 snapshot 注入；
- 配置受保护 review/CI；
- 提交 candidate baseline 供人类 ratification。

该 bootstrap SHALL NOT 修改产品 Requirement、AC、contracts 或平台实现，也 SHALL NOT 自动批准自己的结果。完成后仍需人类通过新机制批准。

## Protected set

以下文件必须进入 governance lock 和受保护 review：

- `AGENTS.md`；
- `openspec/constitution.md`、`project.md`、`config.yaml`；
- `openspec/governance/**`；
- `openspec/architecture/**`；
- `openspec/integrations/**` 和工具 catalogs/fixtures（由独立 `INTEGRATION-PROFILES` lock 保护，避免无语义 parser 更新强迫 Core 升版）；
- `openspec/platforms/**`（由 `PLATFORM-PROFILES.lock.yaml` 与 Task 的独立 profile hash 保护，不得绕过 Core）；
- `openspec/schemas/**` 和 `openspec/templates/change/**`；
- `openspec/changes/README.md`；
- current specs、Core contracts、verification policy/index/cases、baseline locks；
- Integration、Platform Profile 与 Core conformance 各自的 lock/manifest 和独立 approval；
- approval/claim/run-record schemas。
- `scripts/check_sdd.py`、`scripts/sdd_guard_core.py`、`scripts/sdd_guard_lifecycle.py`、`scripts/sdd_guard_release.py`、`scripts/sdd_guard_support.py`、`scripts/check-sdd.sh`、`scripts/check-json.py`、`scripts/sdd_protected_set.py`、`scripts/relock_baseline.py`、`scripts/guard_selftest.py`、`.python-version` 与 `scripts/requirements-sdd.txt`。

## Task claim

经批准且所属 Change 仍是当前 approved lineage head 的 immutable Task packet 先进入 `ready/unclaimed`。执行者随后通过受保护 claim 服务创建符合 `task-claim.schema.json` 的 immutable claim，并在成功后进入 `in_progress`；不得把 claim/owner/attempt 写回 Task packet。服务必须在与 Change supersession approval 相同的串行化 eligibility transaction 中拒绝非 lineage head 的 packet，再原子签发符合 `claim-owner-attestation.schema.json` 的仓库外可验证证明，绑定 claim 原始 bytes/hash、Task、attempt、owner 和 lease。Replacement Task 的 claim 还必须在 exact `taskSupersession` approval 之后创建，并通过 `supersededRunId` 与 `taskSupersessionApprovalId` 绑定该 approval；普通 claim 两字段必须为 null，禁止事后补批。单一 Git compare-and-swap 只有同时能取得该外部 owner proof 时才足够。

含 `hdc-server`、`device-binding` 或 `host-volume` 的 claim 还必须携带 `resource-identity-attestation.schema.json`。该证明由同一受保护 claim service 在原子冲突检查前解析真实 endpoint/generation、稳定设备 binding 或主机卷标识，绑定 claim 原始 bytes，并输出规范 URN。Guard 会从证明中的规范字段重新计算 URN；仓库内自报名称、路径、IP 别名或 plan 字段本身均不能证明两个资源不同。

`controlledHardwareLab` claim 的 `claimantKind` 必须是 `humanOperator`；普通 agent/automation service 即使能创建文件也不能领取。真实设备 dispatch 还必须有符合 `lab-execution-authorization.schema.json`、由仓库外人类批准的 pre-dispatch authorization，精确绑定 operator、claim bytes/owner proof、Task、符合 `lab-execution-plan.schema.json` 的 immutable plan bytes/hash、Step kinds/effects、runtime capabilities、目标 binding、固件、transport、HDC client/server/daemon/endpoint/generation、Provider、有效期和物理目标确认。执行器在首个真实设备 Step 前重新验证并记录 first/last dispatch 时间；approval 与物理确认都必须早于 first dispatch，last dispatch 必须早于过期。Claim 字段、事后 run 或 hardware evidence 均不能补发授权。

无原子 claim 机制时，同一个 Task 不能并行执行；claim 过期只能经 stale-claim reconcile 产生新 attempt，不能覆写旧 run record。

V1 不定义可变 lease/续租 sidecar：单个 lease 最长 24 小时，run 必须在 immutable lease 内结束。后一 attempt 只有在前一 claim 已有 `done | blocked | interrupted | superseded` 终态 run 且时间不晚于新 claim 时才合法；Task ID 本身是隐式 exclusive resource。Run 声明的 `modifiedFiles` 必须与真实 `baseRevision..resultRevision` Git diff 完全相等。Change verification 还必须从 exact change-approval base 证明最终 result tree 等于 active done run 的无冲突 Git tree 并集，加上逐文件、按引用闭包验证的 lifecycle metadata；ancestor 关系本身不足以证明 Task scope。

Claim owner 可以记录 `blocked/interrupted`，但每个终态 run 必须有受保护 claim 服务签发的 `run-owner-attestation`，把 run bytes/hash、claim、attempt 和 `executedBy` 绑定到原 claim owner；其他仓库写入者不能结束该 lease。Agent 不能自行宣告 `done`。Done run 的 finalized bytes/hash、run ID、attempt 和 base revision还必须由 subject type `taskRun` 的仓库外人类 approval 验证；owner proof 与结果批准是两个独立 gate。

## Guard responsibilities

Ratification 前必须实现并在 CI 强制：

- 所有 YAML/YAML front matter 在任何语义解析前递归拒绝 duplicate mapping key、anchor、alias 与 merge key，确保 reviewer、verifier 和各语言 parser 对 exact approved bytes 只有一个解释；
- JSON evidence/Task/claim/run 按实例 `schemaVersion` 路由到保留的 versioned `$id`；live Task 使用 current contract，archive 使用其历史版本。发布 MAJOR schema 时必须新增 schema 文件/路由并永久保留旧 schema，禁止用当前 schema 重新解释不可变 archive；

- baseline hashes、governance protected-set hashes；
- Core change/baseline 的三平台 revalidation matrix，且 current delivery platform 不得 deferred；
- 每个 Platform Profile 对全部 Core Port 的精确映射；
- Task platform 与所 pin Platform Profile 的显式 platform binding；Platform conformance 状态不得跨 Core baseline 漂移；
- Platform conformance evidence 必须结构化固定 profile/verification/Core/Integration/Conformance 全部 hash；accepted lock revision 用 `previous_lock` 形成可审计状态链，既有 verified/needsReverification 不得重置为 notStarted；
- 每个 verified Platform 必须固定外部批准的 `platformReleaseSubject`（source revision、每个 OS/arch/package cell 与 release artifact hash）；PCE 必须逐 cell 精确覆盖该 subject。所有 Core/Platform/Port result 都绑定 canonical definition hash；每个 controlled-external evidence artifact 绑定 exact Core/Conformance/implementation 与显式 case/Port/support-cell hash 集并独立外验。真实硬件引用还必须绑定当前平台 case manifest，以及包含 Core/behavior canonical Scenario SHA 或 platform exact expected result 的 case definition hash。发布对象或规范期望变化但没有新 PCE/evidence 时必须 needsReverification，禁止让历史结论泛化到当前包或改写后的 case；
- change 的 approved/implementing/verified/rejected 生命周期在没有 ready Task 时同样验证；archive 必须分离 Task result `verification_revision`、只新增 finalized verification record 的 live `source_tree_revision` 与不可发布 staging `result_revision`，绑定 staging 中除 lock 外的完整目录、exact Git result、accepted result baseline、移动前完整 live 语义 guard 的受保护 `archiveSourceVerification` 与外部 archive approval；已归档真机证据只能从该证明覆盖且由 archive tree 逐字节保留的完整 provenance bundle 重建，不能降级成同名 run 查找；
- change supersession graph 必须引用已批准 predecessor、保持单 successor/无环；successor approval 前必须有 externally verified、ledger-complete、sequence-monotonic 的 barrier proof，边界后 predecessor 不得出现新 claim、change verification 或 archive approval；
- replacement claim 必须绑定且严格晚于其 exact `taskSupersession` approval；Task/claim/run/attestation identity 与 approved subject identity→hash 映射跨 live/archive 全局唯一；
- valid approval reference and approved content hash；
- Core/current-spec diff 只能来自批准 delta；
- duplicate/missing Requirement/AC 和 Scenario coverage；
- JSON/YAML/schema validity；
- approval/claim/task-packet/run instance 的 JSON Schema 与跨文件引用一致性；
- task claim owner/run owner proof、lab pre-dispatch authorization、base revision、allowed/forbidden path；
- canonical exclusive-resource URN 与 capability 所需的 HDC server/device binding/host volume 互斥；
- conformance manifest/fixture/catalog hashes；
- acceptance index 与 current specs 中全部 AC 的精确一致性；
- 只有受保护 archive workflow 可在 verified + 已批准 pre-archive proof 后构造不可发布的 sync/archive staging subject；`archive-lock.yaml` 不得位于它所绑定的 `result_revision` 内。`source_tree_revision..result_revision` 必须通过 exact name-status/hash allowlist，只含逐字节 live→archive move、pre-archive proof 与 approved behavior sync/new-baseline/必要 revalidation metadata；不得夹带实现变化、删除旧 archive 或修改其他历史。Guard 还从 Git 历史推导首次新增 archive lock 的唯一 publication commit，并要求 result→publication 只新增 lock 与 exact approval mirrors。任何权威分支 merge、current-spec/baseline 生效或 archive 发布必须在 exact staging subject 取得 baseline + human archive approval 后原子完成。
