# Change Package Workflow

Current specs 不能直接修改。任何行为、contract、平台设计或实现工作都从 change package 开始。

## Naming and state

```text
folder: chg-yyyy-nnn-short-name
display ID: CHG-YYYY-NNN
proposed source → approved lock → claimed/implementing → verified result → archived
                      └→ rejected
```

Proposal front matter 的 `status: proposed` 是不可变 source 声明，不承担运行态。`approved` 由 exact `change-lock.yaml` + 外部批准推导，`implementing` 由有效 claim 推导，`verified` 由 `verification-result.json` + exact done runs + 外部批准推导，`archived` 由 archive lock 推导。Agent 不能自行完成这些治理动作；编辑 front matter 或 verification plan 状态不构成转换。有效批准规则见 `openspec/governance/enforcement.md`。

`scope.yaml` 是批准时冻结的 Requirement/AC 精确集合。它必须包含全部 change-local AC；Task packet 的 Requirement/AC union 必须与它完全相等，既不能漏掉困难场景，也不能静默扩张。Change ID 的 revision 在 V1 固定为 1；批准后的范围变化创建新的 Change ID，并在 proposal 写 `supersedes_change_id` 指回一个已批准旧 ID，同时预分配唯一 `supersession_barrier_attestation_id`。旧 change/Task/claim/run 永久保留，不存在原地 r2；其 identity 也不得在 archive 后复用。

Change replacement 是执行授权转换，而不是普通引用。Proposal link 必须无环；一个 predecessor 最多只能有一个 approved successor。受保护 coordinator/claim service 先签发固定文件名 `supersession-barrier-attestation.json`：它符合 `change-supersession-barrier.schema.json`，绑定 exact predecessor/successor locks、完整 claim/run/owner inventory、ledger revision、全局单调 lineage sequence 与 `closedAt`，且其 ID 必须等于 proposal 预分配值。外部 verifier 必须对不可删除 service ledger 证明 inventory 完整；successor approval 必须严格晚于 barrier。该 approval 生效后旧 Change 推导为 `superseded`，其 packet 即使仍写 `ready` 也只保留作历史。若需要停止在途工作，先以 `blocked` 或 `interrupted` 形成真实 terminal run；删除 sidecar、比较当前树时间戳或事后回填均不能越过边界。

`tasks.md` 与 `task-packets/` 不进入 change-lock：前者只是可追加的派生索引，后者各自由独立 `taskPacket` approval 固定。这样失败后的 replacement Task 可以在不改写既有 change lock/旧 claim 的前提下加入；它仍受 immutable `scope.yaml` exact union、Ready Gate 和 `taskSupersession` approval 约束。Proposal、scope、delta/spec-impact、design、verification plan、review 与 canonical acceptance registry 仍由 change-lock 固定。

## Required artifacts

```text
openspec/changes/<change-id>/
├── proposal.md
├── scope.yaml                            # immutable exact Requirement/AC scope
├── specs/<affected-capability>/spec.md   # behavior change 的 ADDED/MODIFIED/REMOVED delta
├── spec-impact.md                        # platform/implementation-only 使用，替代 no-op delta
├── design.md
├── tasks.md
├── task-packets/TASK-*.json              # immutable；符合 task-packet.schema.json
├── verification.md
├── verification-result.json             # 仅 verified 后存在；immutable + externally approved
├── acceptance-cases.yaml                 # change-local/platform AC canonical method/evidence
├── review.md                             # pre-task review
├── ready-review.md                       # pre-approval structural/pinning review; approval is derived later
├── change-lock.yaml                      # approved change inputs 的 immutable hash manifest
├── supersession-barrier-attestation.json # successor only；claim ledger service proof，不进入 change-lock
└── evidence/
    ├── summary.md
    └── runs/<task-id>/attempt-NNN/
        ├── claim.json
        ├── claim-owner-attestation.json
        ├── lab-execution-plan.json            # controlledHardwareLab only; immutable typed plan bytes
        ├── lab-execution-authorization.json   # controlledHardwareLab only
        ├── run.json
        └── run-owner-attestation.json
```

模板位于 `openspec/templates/change/`。

Folder name 必须是 lowercase kebab-case，供 OpenSpec CLI 使用；大写审计 ID 保留在 proposal front matter。

## Change classes

- `core`：改变跨平台行为、Safety、AC 或 schema；需要 baseline version change 和全平台影响审查。
- `capability`：在既有 Core 下新增/修改用户可观察能力。
- `integration`：OpenHarmony/HDC/工具版本适配；不得降低 Core。
- `platform`：macOS/Windows/Linux 工程、权限、UI、打包或 Port；不得改变 Core AC。
- `implementation-only`：不改变可观察行为和 pass/fail 的重构、测试或基础设施。

## Delta format

规格 delta 使用：

```text
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

V1 只接受 ADDED 与 MODIFIED，且 behavior change 一律声明 Core MINOR/MAJOR并提供三平台 revalidation matrix；在没有规范语义等价证明前不得把 behavior delta 标作 PATCH。ADDED 只能追加到已有 capability spec 文件；创建新 spec 文件要等待 canonical preamble/file contract。MODIFIED 必须包含完整的新 Requirement 和完整 Scenario 集，且保留该 Requirement 的全部 baseline AC ID；新增 AC 可以加入。省略旧 AC、REMOVED 与 RENAMED 在尚无版本化 tombstone/migration contract 时一律 fail closed，不能靠隐式删除或复用 ID 通过。

每个 behavior change 还必须锁定自己的 `acceptance-cases.yaml`：case 集合精确等于该 delta 触及的 AC，每项固定 delta Scenario 的 repo-relative path、`#AC-ID` anchor 和 canonical block SHA-256。它可以在本 change 内覆盖 baseline 中同 ID 的 method/Test/evidence，但解析必须以 Task/run/result 的 `changeId` 为边界；其他 change 与 Platform/Core conformance 永远只能看到自己的 registry 或 baseline case，不能被该覆盖污染。

## Apply and archive

1. 验证所有 Task 和 AC evidence。
2. 所有 active Task result 从 exact change-approval base 汇合到 canonical full Git OID `verification_revision`。受保护 workflow 必须证明最终 Git tree 是各获批 run diff 的无冲突精确并集；并集外只能出现从该 Change 已验证 lifecycle 引用闭包逐文件枚举的 metadata，不能仅凭 ancestor 关系带入未归属提交。随后生成的 `verification-result.json` 其 `resultRevision` 精确等于该较早的 commit；外部 change-verification approval 绑定 record bytes，并以 `verification_revision` 为 `baseRevision`。workflow 再创建一个只新增 finalized record 与其 exact approval mirror 的 metadata child commit `source_tree_revision`，由此推导 change 为 verified。这样 record 不需要引用包含自身的 commit。
3. 受保护 CI 针对 `source_tree_revision` 的完整 live tree 运行语义 guard，生成并外部批准 `pre-archive-verification.json`。该证明逐文件固定 source change，并证明 ready/pins、claim owner/lease、规范资源身份、controlled-lab 事前授权、typed plan→实际执行、硬件来源、审批时序、Git diff 和 AC/change verification 均已通过；归档后的弱化重放或事后补授权不能替代它。若存在真机证据，后续 guard 必须从该证明固定的 Task→claim/owner→lab plan/authorization→run/owner/result→execution records→local case registry 文件重建同一 provenance bundle，归档不得让 immutable EVD/PCE 断链。
4. 只有受保护 archive workflow 可以从 `source_tree_revision` 创建一个隔离、不可发布的 staging commit。Behavior/Core change 按 exact approved delta 更新 `openspec/specs/` 与 Core acceptance registry，生成待批准的新 Core baseline，并同步 Conformance 与 Platform revalidation metadata；platform/implementation-only change 不生成假 Core baseline，复用 byte-identical accepted Core/Conformance subjects，Platform lock 若已由获批 Task result 更新则沿用该固定 bytes。两类 change 都将目录移到 `changes/archive/YYYY-MM-DD-<id>/`。该 commit 是 `result_revision`，此时不得包含 `archive-lock.yaml`，也不得合并到权威分支、发布或改变支持声明。Guard 对两 revision 运行 `--no-renames` 的 exact name-status/hash transition：除逐字节 live→archive move、pre-archive proof 和 behavior sync 所需的 spec/acceptance/config/conformance/new-baseline/Platform revalidation metadata 外，任何实现源码变化、旧 archive 删除或额外文件都 fail closed。
5. 在 `result_revision` 已存在后，workflow 才生成 `archive-lock.yaml`。它固定除自身外的完整归档目录、pre-archive 证明、source change lock、base/verification/source-tree/result revisions 和 accepted result Core baseline。若 baseline/Platform/Conformance subject 在 staging 中新增或改变，其 approval `baseRevision` 必须精确等于 `result_revision`；若 platform-only archive 复用 byte-identical subject，则保留原 approval，并要求其 canonical base 是 `result_revision` 的祖先。复用 baseline 的 ratification-time Platform context 必须从 `result_revision` 固定的 current+history lock chain 按 ID/revision/hash 解析，不能强迫它等于较新的 current Platform lock。Archive approval 始终绑定 exact lock bytes，且 `baseRevision` 精确等于 `result_revision`。
6. `archive-lock.yaml`、有效外部 approval 与其验证结果只能写入 `result_revision` 的后继元数据提交。Guard 从 Git 历史推导首次新增该 lock 的唯一 publication commit，并要求 `result_revision..publication` 的 exact diff 只包含 `archive-lock.yaml` 与当次尚未存在的 exact archive/baseline/Platform/Conformance approval mirrors；任何源码、旧历史或额外文件变化都失败。所有 gate 通过后，受保护 workflow 才可发布该 commit（或包含它的后继）到权威分支；发布前 staging 不构成 current spec、accepted baseline、已归档 change 或平台支持事实。

这个分阶段模型有意避免两类自引用：`verification-result.json` 位于它所引用的 `verification_revision` 之后；`archive-lock.yaml` 绑定先前的 `result_revision`，但不属于该 commit。Guard 必须证明 verification→source-tree 只新增 finalized verification record，且 staging tree 中归档目录除 lock 外的文件集合/bytes 与最终目录完全相同。历史重放只使用该 archive 固定的 revisions、lock bytes 和当时 axis approval refs，不读取当前可演进的 Platform/Conformance lock 来重新解释旧 publication。只移动目录、编辑 status、构造 staging commit 或运行 CLI 均不能完成归档。

Archive 保留 proposal/design/tasks/evidence，作为“为什么改变”的历史；current specs 只保留“现在系统应如何行为”。

## Task packet 与运行态

Task packet 在 `ready` 前由 Ready Gate 和人类 approval 固定；approval 的 subject hash 是单个 packet 文件的原始 bytes。V1 packet `revision` 恒为 1。Ready packet 是 `ready/unclaimed`，执行 Agent 原子创建独立 claim 后才进入 `in_progress`。owner、attempt、lease、命令、结果和 evidence 从不写回 packet。范围变化让旧 claim 产生 owner-attested `superseded` terminal run，明确 replacement Task 与理由并取得 exact `taskSupersession` 人类批准；replacement claim 的 `supersededRunId`/`taskSupersessionApprovalId` 必须精确绑定并严格晚于该批准，普通 claim 两字段为 null。replacement 必须是同 change/base/platform、保持旧 Requirement/AC/allowed path/deliverable 覆盖的全新 Ready Task。验证通过前旧 Task 不会从 active scope 移除，不能用 r2 覆盖历史。

## Effective spec during implementation

实现 approved change 时，Task 的有效规格是：

```text
pinned current baseline
+ approved scoped delta overlay
```

Delta 只替换其中列明的 Requirement/AC，其他规则仍来自 baseline。scope/Task/run/`verification-result.json` 必须使用该 change 的同一个 overlay 和 change-local case registry；不得借用另一个 change 的新增 ID 或覆盖 case。Core/Safety delta 必须具有有效 approval，并在 archive 后生成新 baseline；否则执行 Agent 必须 blocked。

Behavior change 的 sync/archive gate 还必须从 Git `base_revision` 重建 predecessor specs，应用 exact approved ADDED/MODIFIED blocks，并证明：untouched spec file 的 full-byte hash 不变，touched file 的非 Requirement 内容不变，Requirement blocks 与 delta 精确相等。Platform change 不得改变任何 current spec file。新 baseline/manifest 自洽不能替代这项等式证明。

Integration change 同样必须版本化 `integrations/**/profile.md`、catalog/fixture，重跑相关 parser golden/contract tests，生成新的 `INTEGRATION-PROFILES` lock revision，并让后续 Conformance/Task 固定新 version/hash。不得把 integration 文件当作可在实现期间随意修改的研究笔记，也不得仅因 parser family 变化重发 Core baseline。

## OpenSpec CLI boundary

- Behavior/Core changes use schema `arkdeck-behavior` and create delta specs.
- Platform/implementation-only changes use schema `arkdeck-platform` and create `spec-impact.md` instead of a fake/no-op delta.
- 普通 Agent、CLI 和非受保护 workflow 在 archive approval 前不得执行 `/opsx:sync`、`openspec archive` 或任何等价 current-spec merge。受保护 archive workflow 仅可在 change verified 且 pre-archive proof 已批准后构造上述隔离 staging subject；它在 archive approval 前仍不得发布、合并或让 staging 成为任何事实源。
- CLI artifact generation does not itself approve a change, claim a Task, verify evidence, or ratify a baseline。
