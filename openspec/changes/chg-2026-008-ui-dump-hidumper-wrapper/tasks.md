# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## External Core MAJOR prerequisite — journaled execution authority

CHG-008 保持 `class:platform` / `core_change_level:none`，不得在本 change 内新增 journal event、
append-chain contract 或改变 dispatch authority。该行为会收紧 accepted schema 与 pre-dispatch Safety
结果，按 Constitution 属于 Core MAJOR。以下全部是外部 blocker，不是本 change 的 approved delta：

- 另起独立 Core change，声明 `class:core`、`core_change_level:major`、
  `platforms:[macos, windows, linux]` 与 candidate `CORE-3.0.0`，并由维护者单独批准；
- owning Core change 必须声明稳定 production implementation task ID `TASK-JAUTH-CORE-001`。该 task
  同时修改 approved Requirement/AC delta、`journal-event.schema.json`、Manifest/semantic validator、
  language-neutral conformance vectors，以及 macOS production locked journal/store、trusted host entry
  point 与 dispatch gate；offline receipt/verifier task 不能替代它；
- `TASK-JAUTH-CORE-001` 必须覆盖旧/new journal reader/writer compatibility、existing Session/checkpoint
  migration、torn-tail/crash-window recovery、restart/reconcile、rollback/downgrade refusal、sequence/hash-
  chain corruption 与 after-the-fact authority fault tests；任一 unknown/missing authority 的真实 dispatch
  count 为 `0`；
- owning Core proposal 必须逐平台给出 disposition。当前 macOS/Windows/Linux 都是 `notStarted`，因此
  macOS production port 必须跑新 Core contract/property/recovery suite，Windows/Linux 记录
  `deferred/notStarted` 并消费同一 language-neutral vectors；三者均不得产生支持/release claim；
- 只有 `TASK-JAUTH-CORE-001 done`、owning Core change `verified` 且 archive/ratification PR 已把 delta
  合入 current specs/contracts、把新 AC 加入 global registry/conformance、ratify `CORE-3.0.0` 后，
  CHG-008 才能另起 revision 把 `core_baseline` 从 `CORE-2.0.0` 重定向到 `CORE-3.0.0`。在此之前
  `TASK-UD-HWE-SEM-001` 也不得 ready/done；schema-only/offline evidence 不能铸造 production authority。

## TASK-UD-PREFLIGHT-001 — supervised server + durable binding 人工前置

- Status:blocked（r3 不存在可执行的 real-device task；所有 installed-HDC/device dispatch 为 `0`）
- Objective:仅在缺失的 production dependencies 合入后，由人类通过 host-wide supervisor 与
  Core device-targeting workflow 证明 existing-server endpoint/ownership/generation，创建并 reopen
  一个 durable `CurrentDeviceBinding` revision，供后续 capture harness 按 revision 读取；操作者
  永远不提供 connect key。
- Change-local closure:`INT-UD-PREFLIGHT-001` / `TEST-INT-UD-PREFLIGHT-001`。
- Canonical Safety/source inputs:`REQ-HDC-001/002/003/004/005` 与
  `REQ-DEV-001/002/006`；本 task 不认领其 canonical AC/Test PASS，逐项 ownership 见下表。
- Blocking dependencies/gates:
  - 上述 external Core MAJOR 已完整关闭：`TASK-JAUTH-CORE-001 done`、owning change verified/archived、
    `CORE-3.0.0` ratified，且本 change 已由后续 revision 明确 retarget；当前未满足；
  - `TASK-UD-HWE-SEM-001 done`，且其 receipt/intent input schemas、source/test OID/hash、fixed
    interpreter 与 exact CLI 已由后续 readiness revision 重验；schema-only 路径不可执行；
  - `TASK-M1-006 done`，其 production `HDCServerSupervisor` source AC/evidence 可消费；本
    preflight 明确依赖真实 endpoint/ownership/generation behavior，不能以 CHG-2026-014 的
    consolidated bytes/interface provenance 替代（当前未满足）；
  - `TASK-M1-007` implementation 与独立 `done` status 均已合入；其 production durable
    `CurrentDeviceBinding` loader、locked journal adapter 与 real-device composition 另有获批
    adoption/readiness task（当前均未满足）；
  - CHG-2026-015 的 `TASK-I15-001 done`、change `verified`，且 `serverIdentityGeneration` 与
    `selectedDeviceAuthorizationBinding` 已被 production supervisor 采用；另有获批的
    no-server-start initial device-discovery family，可产生 candidate 但不能绕过人工选择（当前
    未满足）；
  - 后续 revision 钉死 registry/profile version、entry/resource hash、platform receipt schema、
    adapter OID、Session store/loader interface 和 exact endpoint；不得由本 task 选择；
  - `capture-runbook.md` 的 `SP-0…SP-3` 逐项可二值执行：server absent、ownership/generation/
    endpoint/version unknown、generation drift 或 receipt 不可信时所有 HDC dispatch `0`；本 change
    不启动、停止、重启、接管或配置 server；
  - initial binding 只能由人类 physical selection 触发，先 durable append `bindingCandidate` /
    `bindingConfirmed`，revision 从 `1` 开始；随后 registered selected-device probe 必须与 durable
    identity/revision 相等。旧 M0B connect key、UI current selection、默认目标、CLI/env/file
    connect-key input 全部禁止。
- Future allowed paths:必须由 dependencies 完成后的独立 readiness revision 固定；在此之前无
  implementation/evidence allowed path 可执行。未来 evidence 位置只可为
  `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-PREFLIGHT-001/**`
  与本 `tasks.md` 的独立 status/evidence 更新。
- Read-only inputs:`capture-runbook.md`；accepted device-targeting/server specs；locked journal/
  manifest/workflow-step/hardware-evidence contracts；M1-007、CHG-015 及其 adoption 的 merged
  evidence/profile/lock。
- Hardware required:yes, human only；当前未 ready。
- Required evidence（未来）:`run.md`、repo-safe `binding-server-receipt.json`、
  `physical-target-confirmation-receipt.json`、`confirmation-manifest.json`、
  `confirmation-event-receipt.json`、`journal-authorization-receipt.json`、
  `hardware-evidence.json`。durable Session/journal 留在 repo 外；binding/server receipt 只记录
  session/job ID、positive binding revision、binding event/hash、identity hash、endpoint/ownership/
  generation 与 toolchain snapshot hash，不含 connect key/serial。physical-target receipt 与 hardware
  evidence 按其 approved schema 记录 model/serial，并由 identity hash、confirmedAt/validUntil、claimed
  operator/attestation 字段关联；repo-safe exposure 边界由前置 contract revision 固定。
- Verification（未来）：capture harness 只能接收 receipt ID + fixed revision，经 production loader
  replay exact Session/journal，revision/hash/current identity 任一不符时 intent/request/process `0`；
  task-applicable confirmation 必须由 trusted host entry point 先 durable append 为同一 Session/Job 的
  typed journal event，且其 sequence/append-chain receipt 严格早于每个 covered intent；`decidedAt` 或事后
  evidence 不能单独授权。每次 HDC intent 前后 revalidate same server generation；hardware evidence 必须按下述固定 validator
  过 schema；pinned verifier 必须证明 device model/serial/physical confirmation、identitySnapshotHash、
  `device.bindingRevision`、server tuple 与 durable receipt/全部 device intents/confirmation scope 的
  字段与 hash 一致。claimed operator 的现实真实性只由维护者 PR review attestation 判定。
- Forbidden now:implementation、task evidence 起草、installed HDC、device/server/network dispatch、
  binding creation、GUI/系统授权、server lifecycle/subserver、connect key 读取/记录。

### TASK-UD-PREFLIGHT-001 canonical dependency boundary

| Canonical Requirement | Canonical AC / Test | 本 task disposition |
| --- | --- | --- |
| `REQ-HDC-001` | `AC-HDC-001-01` / `TEST-AC-HDC-001-01`；`AC-HDC-001-02` / `TEST-AC-HDC-001-02` | read-only Safety/source dependency；由 source implementation task 按 contract/platform evidence 关闭，本 task 只验证已关闭 interface 的 capture-specific composition |
| `REQ-HDC-002` | `AC-HDC-002-01` / `TEST-AC-HDC-002-01` | read-only Safety/source dependency；不得用本 task 的 realHardware receipt 替代 `supervisorContract` |
| `REQ-HDC-003` | `AC-HDC-003-01` / `TEST-AC-HDC-003-01`；`AC-HDC-003-02` / `TEST-AC-HDC-003-02` | read-only Safety/source dependency；lifecycle call counter/ownership contract 仍由 source task 关闭 |
| `REQ-HDC-004` | `AC-HDC-004-01` / `TEST-AC-HDC-004-01` | read-only Safety/source dependency；本 task 不关闭 platform endpoint-isolation evidence |
| `REQ-HDC-005` | `AC-HDC-005-01` / `TEST-AC-HDC-005-01` | read-only Safety/source dependency；本 task 不定义 adapter output family |
| `REQ-DEV-001` | `AC-DEV-001-01` / `TEST-AC-DEV-001-01` | read-only Safety/source dependency；必须在 M1-007/source task 已 PASS 后消费 durable binding interface |
| `REQ-DEV-002` | `AC-DEV-002-01` / `TEST-AC-DEV-002-01`；`AC-DEV-002-02` / `TEST-AC-DEV-002-02` | read-only Safety/source dependency；本 task 的 receipt equality 不能替代 binding dispatch contract/property |
| `REQ-DEV-006` | `AC-DEV-006-01` / `TEST-AC-DEV-006-01` | read-only Safety/source dependency；本 task 只加严 identity gate，不关闭 canonical effect-gate property |

只有上述 canonical evidence 由其 source owner 合入 PASS，且 local
`TEST-INT-UD-PREFLIGHT-001` 单独通过时，preflight 才可能起草完成；两类 evidence 不互相替代。

## TASK-UD-HWE-SEM-001 — UI Dump hardware evidence 离线语义 verifier

- Status:blocked（当前 schema-only 验证不足；不存在获批 executable verifier，任何 realHardware
  PASS 均不得只凭 generic JSON schema 起草）
- Objective:在真机 task ready 前，实现并审查一个纯 host/offline、fail-closed semantic verifier，
  交叉验证 hardware evidence、durable binding receipt、device intent manifest、server receipt、
  physical-target confirmation receipt、task-applicable confirmation manifest、confirmation-event receipt
  与 durable journal authorization receipt 的字段、顺序和 hash 一致性；
  它不声称证明操作者的现实身份。
- Change-local closure:`INT-UD-HWE-SEM-001` / `TEST-INT-UD-HWE-SEM-001`；不认领任何
  canonical Core AC PASS。
- Blocking dependencies/gates:
  - 上述 external Core MAJOR prerequisite 必须先完整关闭；`TASK-JAUTH-CORE-001` 的 production
    implementation/conformance evidence、owning change verified/archive evidence 与 ratified
    `CORE-3.0.0` baseline 缺一不可。当前 `journal-event.schema.json` 没有与 manifest confirmation/
    execution authority 关联的 task-applicable event kind 或 append-chain 字段，故本 offline task 当前
    不得 ready，也不得自行定义 Core fields/dispatch rule；
  - Core MAJOR 关闭后，另一个独立 approved integration/receipt revision 才可固定 repo-safe binding
    receipt、server receipt、device intent manifest、physical-target confirmation receipt、task-applicable
    confirmation manifest，以及 Core 已定义的 confirmation-event/journal-authorization receipt projection
    的 schema path/version 与 canonical serialization/hash linkage；generic
    `hardware-evidence.schema.json` 的 `operator` 是字符串，`physicalTargetConfirmation` 也没有 receipt/
    identity/scope linkage，不足以定义 cross-document equality 或操作者真实性；
  - physical-target receipt schema 必须固定 canonical model+serial serialization、claimed operator、
    `confirmedAt`、`validUntil`、binding revision、identitySnapshotHash 与 receipt hash；hardware evidence
    的 `physicalTargetConfirmation.confirmedDeviceIdentity`、`device.model`/`serial` 必须与之精确相等，
    且其 identitySnapshotHash 必须等于 binding receipt 与全部 device intents 的 target identity hash；
  - confirmation manifest schema 必须固定 `confirmationId`、task-applicable `kind`、
    `decision=accepted`、`actor=user`、
    claimed operator、`decidedAt`、`validUntil`、`scopeHash`、related step/intent IDs 与 canonical scope
    serialization。scope 至少包含 task/Recipe、physical model/serial、identitySnapshotHash、binding
    revision、server tuple、fixture hash、exact argv/arguments hashes、remote path、inventory/receive/
    cleanup；capture task 的相关 deviceMutation intent 必须全部且只能被同一未过期
    `kind=deviceMutation` confirmation 覆盖；preflight 则只允许 schema 登记的 physical/binding
    confirmation kind 与 exact related events，不得伪造 mutation entry；
  - owning Core MAJOR 必须定义由 trusted host entry point 写入 production locked Session journal 的
    typed accepted-confirmation/authorization event；repo-safe `confirmation-event-receipt` 至少绑定 journal/
    Session/Job ID、confirmation ID、event ID、strictly monotonic sequence、canonical event-payload hash、
    previous append hash 与 append hash。`journal-authorization-receipt` 必须绑定同一 journal identity/head、
    从该 confirmation event 到全部 related intent 的无缺口 ordered slice，并为每个 intent 固定 event ID、
    sequence、payload/arguments hash、previous/append hash；不得包含 connect key 或 raw UI bytes；
  - production harness 必须从 durable store 读取该 event/chain，而不是从 CLI/imported manifest mint
    authority；对每个 planned intent，harness 必须在同一 serialized journal lane 下确认 confirmation event
    已 durable append/current，随后 append+fsync 该 intent 并证明其 sequence 更大，之后才 dispatch；最终
    journal-authorization receipt 再投影 confirmation→全部 related intents 的完整 slice。wall-clock
    `decidedAt`/`confirmedAt` 只作有效期检查，不能证明先后；
    missing event、chain gap、hash/head/session/job mismatch、sequence reuse/non-monotonic、confirmation event
    不早于任一 intent 时，intent/request/process dispatch 均为 `0`，事后 receipt/evidence 不得补权；
  - 后续 readiness revision 固定 source commit OID、下列两个文件各自 SHA-256、fixed Python
    executable path/version/hash 与 exact CLI；hash 未产生前本 task 不能 ready；
  - exact CLI shape 必须为
    `<FIXED_PYTHON> scripts/ui_dump_capture/verify_hardware_evidence.py --evidence <hardware-evidence.json> --binding-receipt <binding-receipt.json> --intent-manifest <intent-manifest.json> --server-receipt <server-receipt.json> --physical-target-receipt <physical-target-confirmation-receipt.json> --confirmation-manifest <confirmation-manifest.json> --confirmation-event-receipt <confirmation-event-receipt.json> --journal-authorization-receipt <journal-authorization-receipt.json> --repository-root <ARKDECK_ROOT> --expected-task-id <TASK_ID> --expected-acceptance-id <AC_ID>`；
    所有输入均为 path token，不得接受 raw JSON、connect key、serial override 或网络来源；
  - verifier 必须检查 claimed operator 字符串/attestation 字段跨文件精确相等、confirmation
    `actor=user`/accepted/time window、physical model/serial/identity hash/scope hash linkage、
    confirmation ID/event payload hash 与 durable journal receipt 精确相等、append chain 无缺口且
    confirmation event sequence 严格小于每个 related intent sequence、
    `bindingRevision > 0` 且等于 binding receipt 和全部 device intents、server endpoint/ownership/
    generation 与 Job snapshot/全部 pre/post receipt 相等、task/AC/step kinds 精确、repo artifact
    path/hash 可解析、敏感 raw 不在 git；unknown/missing/extra/mismatch/expired 一律 nonzero；
    **这只证明记录一致性，不证明 claimed operator 是真人**。操作者真实性仍按
    `hardware-evidence.schema.json` description 与治理规则由维护者 review/merge attestation 保证；
  - offline negative tests 至少覆盖 missing/zero binding revision、receipt/intent revision mismatch、
    physical model/serial/identity mismatch、stale/expired/substituted physical confirmation、scope hash/
    related intent/arguments mismatch、server generation/endpoint/ownership drift、wrong task/AC、
    claimed-operator/attestation mismatch、confirmation actor/decision mismatch、伪造更早 `decidedAt` 但
    confirmation event sequence 晚于 intent、missing/duplicate event、sequence reuse/non-monotonic、journal/
    Session/Job/head mismatch、append-chain gap/hash mismatch、intent payload/arguments hash mismatch、artifact
    hash/path mismatch、raw 路径落入 git、schema-valid 但语义不一致；不得把 `operator="human-name"` positive
    fixture 描述为真人身份证明，也不得只测试 schema-invalid JSON。
- Future allowed paths（仅在上述 input contracts 合入后的独立 readiness revision 生效）：
  - `scripts/ui_dump_capture/verify_hardware_evidence.py`
  - `scripts/ui_dump_capture/test_verify_hardware_evidence.py`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-HWE-SEM-001/**`
  - 本 `tasks.md`（仅该 task 的独立 status/evidence 更新）
- Read-only inputs:未来固定的 binding/server/intent/physical-target/confirmation/confirmation-event/
  journal-authorization schemas；
  `openspec/contracts/hardware-evidence.schema.json`；`openspec/verification/acceptance-cases.yaml`；
  git index/repository root。
- Hardware required:no；tests 必须只用 synthetic offline fixtures/temp directories，installed HDC、
  device/server/network dispatch 均为 `0`。
- Forbidden now:创建 verifier/evidence、选择 receipt schema、填入占位 hash、联网安装 dependency，
  或用 schema-valid JSON 声称 semantic PASS。

## TASK-UD-CAP-MUT-001 — R1-R3 首次 target-build 人工 deviceMutation 采集

- Status:blocked（`R1`、`R2`、`R3` 和 ad-hoc `INV-1` dispatch count 必须为 `0`；本 task
  不含 `R4`）
- Change-local closure:`INT-UD-CAPTURE-MUT-001` / `TEST-INT-UD-CAPTURE-MUT-001`。
- Canonical Safety inputs:`REQ-DUMP-002/005/006/007/008`；本 task 不认领其 canonical
  AC/Test PASS，逐项 ownership 见下表。
- Depends on:`TASK-UD-PREFLIGHT-001 done`、`TASK-UD-HWE-SEM-001 done`；后续独立
  readiness revision 关闭下列全部 gate。
- Blocking gates:
  - R1/R3 的 official source 只作静态 routing hint，不是 DAYU200 firmware output-mode evidence；
    R1-R3 首次 target execution 全部提高为 `captureRemoteFile/deviceMutation`，不得存在
    stdout-only/readOnly 分支；
  - 固定 dedicated disposable non-sensitive fixture HAP tuple：artifact hash、bundle、ability、
    静态页面内容、window rule，以及 install/start/stop/cleanup 的 typed effect/argv；另行批准
    typed window-inventory operation；未登记的 `INV-1` 不可执行；
  - 从 `TASK-UD-PREFLIGHT-001` receipt 固定 session/job、positive binding revision 与
    server endpoint/ownership/generation；harness 只能经 production loader materialize `-t`，并在
    每个 intent 前后重放/revalidate binding 与 server；
  - physical-target confirmation receipt 的 canonical model/serial 与 hardware evidence 的
    `physicalTargetConfirmation`、`device.model`/`serial` 精确相等；receipt identitySnapshotHash 与
    durable binding receipt/全部 device intents 精确相等，且 capture intent 时间必须位于 receipt
    `confirmedAt...validUntil` 内。不同设备、identity mismatch 或过期 receipt 时 intent/request/
    process dispatch `0`；
  - `deviceMutation` confirmation manifest 的 accepted `actor=user` receipt 必须在 dispatch 前 durable
    存在且未过期；scope hash 由固定 canonical serialization 重算，覆盖 Recipe、physical model/serial、
    binding revision/identitySnapshotHash、server tuple、fixture、exact argv/arguments hashes、remote
    path、pre/post inventory、receive 与 cleanup；related step/intent ID 集合必须 exact，任一缺失、
    extra、stale 或 substituted confirmation 时对应 dispatch `0`；
  - 同一 confirmation 必须先由 trusted host entry point durable append 为 production Session/Job typed
    journal event；harness 只从 locked journal replay 授权。其 confirmation-event receipt 与 journal-
    authorization receipt 必须证明 event ID/payload hash/append hash 相等、chain 无缺口且 confirmation
    sequence 严格小于全部 related intent sequence；时间字段、manifest 或事后 evidence 单独出现时
    dispatch `0`；
  - 另一个 approved contract/integration change 必须先在 `remote-operations.yaml`、
    `workflow-step-registry.yaml`/schema 与 platform adapter/profile/lock 中登记 exact-path sidecar
    pre/post inventory typed operation；当前 catalog **不存在**该 operation，generic
    `verifyRemoteState(probeId, expectedState)` 也没有 exact path/argv/output family/adapter binding，
    因而不可使用；
  - 该 registration 必须固定 operation ID、typed arguments、minimum effect、exact argv array、
    output family/parser、adapter OID/hash、literal remote path、existence/type/size/mtime/ownership
    receipt、timeout/cancellation，并禁止 shell/raw command；readiness revision 只引用 merged entry
    OID/hash，不得由 harness/operator 临时选择命令；
  - 固定一个 exact remote sidecar path，且由上述 registered operation 的 pre-receipt 证明不存在；
    禁止全局 `/data` search、wildcard、symlink follow、递归删除或覆盖既有文件；R1/R3 也执行同一
    保守 inventory，不得先运行再观察；
  - post-inventory 证明 exact new path 属于本 task，stdout/sidecar 分立 raw origin/hash，cleanup
    仅允许 `cleanupOwnedRemotePath(remotePath, ownershipEvidenceId)` 消费同一 path 的 registered
    pre/post receipts 所产生的 ownership evidence ID；ownership/identity 不明则保留，cleanup
    failure 记录 `needsAttention`；
  - inventory/ownership negative tests 至少覆盖 pre-existing path、missing post path、非 regular
    file/symlink、unchanged/stale identity、mtime/size/identity ambiguity、unexpected extra output、
    parser unknown、binding/server drift，以及无 ownership evidence 的 receive/cleanup；对应
    Recipe/receive/cleanup dispatch 必须按 gate 为 `0`。
- Future allowed paths（仅在 readiness revision 合入后生效并由其重新固定 executable entrypoint）：
  - closed durable-binding/server-aware harness source与 offline fault tests（具体路径当前未批准）
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-MUT-001/**`
  - 本 `tasks.md`（仅独立 status/evidence PR）
- Forbidden now:任何 implementation、installed HDC、device dispatch、fixture install/start、
  remote inventory/receive/cleanup 或 evidence 起草；不得复用 M0B connect key/server state。
- Hardware required:yes, human only；当前未 ready。
- Required evidence（未来）：`run.md`、`redacted-manifest.json`、`capture-hashes.md`、
  `hardware-evidence.json`、repo-safe `physical-target-confirmation-receipt.json` 与
  `confirmation-manifest.json`、`confirmation-event-receipt.json`、
  `journal-authorization-receipt.json`。hardware record 的 model/serial/physical confirmation、
  `device.bindingRevision`、identitySnapshotHash linkage 必须与 preflight receipt/全部 intent 相等；
  `toolchain.other` 记录 endpoint/ownership/generation 与 receipt hashes；raw 保持 repo 外。
- Schema/semantic validation（三个 realHardware task 均强制）：
  `/opt/homebrew/anaconda3/bin/jsonschema` version `4.17.3`，SHA-256
  `672885a523b0d538e4d734a9009d1678827facd27f2e634093e3bfc838392de7`；执行
  `/opt/homebrew/anaconda3/bin/jsonschema -i <task-evidence>/hardware-evidence.json openspec/contracts/hardware-evidence.schema.json`，
  再运行已完成 `TASK-UD-HWE-SEM-001` 的 pinned offline verifier；其 source/test OID/hash、exact CLI
  或 input schema 任一漂移即 blocked。validator 漂移或联网安装需求也 blocked。
- Deliverables/verification:见 `capture-runbook.md`；未来必须对 R1-R3 证明 exact one-element
  payload、durable binding materialization、physical model/serial/identity receipt linkage、
  same-generation server pre/post、unexpired exact-scope confirmation、exact-path inventory、separate
  raw origins、owned cleanup、hardware schema/semantic validation 与 raw/derived privacy chain，且
  destructive/Agent dispatch count `0`。未关闭前不得起草 PASS/done。

### Capture task canonical Safety boundary

| Canonical Requirement | Canonical AC / Test | Capture task disposition |
| --- | --- | --- |
| `REQ-DUMP-002` | `AC-DUMP-002-01` / `TEST-AC-DUMP-002-01` | read-only Safety input；window ID 必须来自另行登记的 typed inventory，但本真机 task 不关闭 `adapterGolden` |
| `REQ-DUMP-005` | `AC-DUMP-005-01` / `TEST-AC-DUMP-005-01` | 强制执行 stdout/sidecar 分离；仅贡献事实 evidence，不替代 canonical `artifactContract` |
| `REQ-DUMP-006` | `AC-DUMP-006-01` / `TEST-AC-DUMP-006-01` | 强制 owned-only cleanup；不替代 canonical `ownershipCleanupContract` |
| `REQ-DUMP-007` | `AC-DUMP-007-01` / `TEST-AC-DUMP-007-01` | 强制 stale/unknown fail closed；不替代 canonical `sidecarFaultInjection` |
| `REQ-DUMP-008` | `AC-DUMP-008-01` / `TEST-AC-DUMP-008-01` | 仅作 raw/derived/privacy Safety 输入；本 task 不执行 diagnostic export，也不关闭 platform evidence |

## TASK-UD-CAP-R4-001 — R4 componentDetail 后置人工 deviceMutation 采集

- Status:blocked（`R4` dispatch count 必须为 `0`；十进制格式校验不构成 component provenance）
- Change-local closure:`INT-UD-CAPTURE-R4-001` / `TEST-INT-UD-CAPTURE-R4-001`。
- Canonical Safety inputs:`REQ-DUMP-003` → `AC-DUMP-003-01` →
  `TEST-AC-DUMP-003-01`；`REQ-DUMP-005` → `AC-DUMP-005-01` →
  `TEST-AC-DUMP-005-01`；`REQ-DUMP-006` → `AC-DUMP-006-01` →
  `TEST-AC-DUMP-006-01`；`REQ-DUMP-007` → `AC-DUMP-007-01` →
  `TEST-AC-DUMP-007-01`；`REQ-DUMP-008` → `AC-DUMP-008-01` →
  `TEST-AC-DUMP-008-01`。`AC-DUMP-003-01` 仍由 `TASK-UD-001` 的 canonical contract test
  关闭，其余 disposition 与上表相同；本 task 不认领任何 canonical PASS。
- Depends on:`TASK-UD-CAP-MUT-001 done`；后续 approved R2 output-family/extractor decision；
  `TASK-UD-HWE-SEM-001 done`。
- Blocking gates:
  - R2 target capture 完成后，独立 approved decision revision 先登记 R2 success/failure/unknown
    output family 与 parser；unknown/truncated/failure R2 不可进入 extraction；
  - 同一 decision/contract chain 必须登记 versioned typed component-tree extractor：source/resource
    path、input family/version、parser/adapter OID 与 SHA-256、typed component-ID output schema、
    deterministic fixture selector 和 exact zero/one/many rule。不得以 regex/十进制校验、第一项、
    最小值、操作者选择或自由文本替代；zero 或 multiple match 均阻断 R4 request/process dispatch；
  - extractor receipt 必须绑定同一 R2 raw-origin hash、fixture hash/window token、parser OID/hash、
    selected component token 与 selection proof；R4 harness 只接受该 receipt ID，不接受
    `COMPONENT_ID` CLI/env/file/manual input；
  - 继承 R1-R3 的 durable binding/server、dedicated fixture、registered exact-path inventory、
    ownership/receive/cleanup、raw/privacy 与 semantic verifier gates，并取得覆盖 R4 exact scope 的
    独立 human `deviceMutation` confirmation。
- Future allowed paths:必须由 extractor/operation/verifier dependencies 完成后的独立 readiness
  revision 固定；在此之前只保留未来 evidence path
  `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-R4-001/**`
  与本 `tasks.md` 的独立 status/evidence 更新。
- Hardware required:yes, human only；当前未 ready。
- Required evidence（未来）：R2 extractor receipt、`run.md`、`redacted-manifest.json`、
  `capture-hashes.md`、`physical-target-confirmation-receipt.json`、`confirmation-manifest.json`、
  `confirmation-event-receipt.json`、`journal-authorization-receipt.json`、
  `hardware-evidence.json`；raw 继续留在 repo 外。
- Verification（未来）：R4 exact one-element payload 中 component token 与 extractor receipt 相等；
  altered/stale/foreign R2 hash、parser drift、zero/multiple selection、manual token、binding/server/path
  drift 的 R4 request/process dispatch 均为 `0`；schema + pinned semantic verifier 均 PASS；
  destructive/Agent dispatch `0`。
- Forbidden now:component parser/extractor 发明或实现、R4 capture/evidence、manual component ID、
  installed HDC/device/server/network dispatch。

## TASK-UD-REDACTOR-001 — deterministic derived-golden redactor/allowlist 前置

- Status:blocked（`uidump-derived-redaction-v1` 当前只有名称与高层步骤，没有获批 source、
  safe-literal allowlist、两阶段 receipt schemas/CLIs、pinned Git inventory executable 或 adversarial
  tests；不得接触真实 raw）
- Objective:在 `TASK-UD-001` ready 前，以独立 host-only task 实现、审查并固定 fail-closed
  `uidump-derived-redaction-v1` transform 与独立 privacy-review finalizer，使后续人类任务只能重放
  已批准算法/allowlist 并在不可变 transform receipt 之后生成另一份 review receipt；golden 实现 PR
  不能决定保留哪些 UI 文本或补写任一 receipt。
- Change-local closure:`INT-UD-REDACTOR-001` / `TEST-INT-UD-REDACTOR-001`。
- Canonical Safety input:`REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01`；本 task
  不执行 diagnostic export、不认领 canonical platform PASS，只对 derived-golden 输入加严隐私边界。
- Blocking dependencies/gates:
  - 独立 approved readiness/implementation revision 仅在下列 exact paths 内定义 algorithm manifest、
    transform/finalizer source、safe-literal allowlist、transform/privacy-review receipt schemas 与 tests；
    完成时固定 source commit OID、每个文件 SHA-256、fixed Python/Git path/version/hash 与两个 exact
    CLIs，任一 hash 未知时不得 `done`；
  - exact CLI shape 必须为
    `<FIXED_PYTHON> scripts/ui_dump_redaction/redact.py --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt --controlled-root <CONTROLLED_ROOT> --input <CONTROLLED_RAW_PATH> --expected-input-sha256 <RAW_SHA256> --output <REPO_EXTERNAL_DERIVED_PATH> --receipt <REPO_EXTERNAL_RECEIPT_PATH> --repository-root <ARKDECK_ROOT>`；
    三个 data path 只能是 token，不得接受 stdin/raw bytes/network；
  - transform CLI **只能**生成不可变 derived bytes 与 `redaction-receipt`；该 schema 不得包含
    reviewer/decision，也不得在 human review 后修改。receipt 固定 `completedAt`、algorithm/source/
    manifest/allowlist OID+hash、raw/derived hashes+sizes、replacement counts、path/file identities、Git
    inventory 与 replay-command hash；
  - privacy-review finalization exact CLI 必须为
    `<FIXED_PYTHON> scripts/ui_dump_redaction/record_privacy_review.py --transform-receipt <IMMUTABLE_TRANSFORM_RECEIPT> --expected-transform-receipt-sha256 <TRANSFORM_RECEIPT_SHA256> --derived <DERIVED_PATH> --expected-derived-sha256 <DERIVED_SHA256> --reviewer <CLAIMED_HUMAN_REVIEWER> --decision <approvedForRepository|rejected> --reviewed-at <RFC3339> --repository-destination <GOLDEN_REPO_RELATIVE_PATH> --output <PRIVACY_REVIEW_RECEIPT_PATH> --repository-root <ARKDECK_ROOT>`；
    finalizer 必须只读打开 transform receipt/derived，重算 hashes，绝不读取 raw 或修改 transform
    receipt；review output 初始不存在并 no-follow/exclusive-create。`privacy-review-receipt` schema 固定
    reviewer claim、decision、reviewedAt、transform receipt ID/hash、derived hash/size、algorithm/
    allowlist hashes、destination 与 checklist version；`reviewedAt` 必须晚于 transform `completedAt`。
    automation 只证明字段/顺序一致，现实人工复核由具名 human task 与维护者 PR review attestation；
  - worktree inventory executable 固定为绝对路径 `/usr/bin/git`，version
    `git version 2.50.1 (Apple Git-155)`，SHA-256
    `179301dcb41ea78accc3fa0048a7e6f6710d891945a751a34addd622020c1818`；不得使用 `PATH`、
    `/opt/homebrew/bin/git`、alias、env/config/CLI override 或 shell。两个 CLIs 必须在读取任何 data input/
    创建任何 output 前验证 executable regular-file identity/hash 与 exact version，并仅以 argument array
    `[/usr/bin/git, "-C", <ARKDECK_ROOT>, "worktree", "list", "--porcelain", "-z"]` 枚举全部
    registered worktree，记录 raw stdout hash/parsed inventory hash；
  - tool 还须沿 retained descriptor ancestor walk 拒绝任何 repository 的 `.git` worktree
    marker。`CONTROLLED_ROOT` 必须是 owner-only `0o700` real directory，位于全部 detected/registered git
    worktree 外且没有 symlink path component。三个 data path 都必须位于该 root 下，其 path components/
    parent directories 由 retained directory descriptors 固定且 owner-only。input 必须为 owner-only
    `0o600` regular file、`st_nlink == 1`，只能以 read-only/no-follow descriptor 读取；创建前的
    `(parent device+inode, basename)` 与创建后的 file descriptor device+inode 对 input/output/receipt
    必须分别 pairwise distinct；
  - output/receipt 必须事先不存在，并通过逐 component no-follow directory descriptors 加
    `O_CREAT|O_EXCL|O_NOFOLLOW`（或语义等价的 platform primitive）以 `0o600` 创建；禁止 truncate、replace、
    symlink/hardlink 与 path re-resolution 后穿透 worktree。tool 必须在读前、写后从 retained descriptors
    复验 controlled-root/parent/file device+inode、mode、link count 与全部 worktree containment，并证明 raw
    identity/size/mtime/hash 未变化；任一 alias、existing target、parent swap、inventory drift 或 identity
    drift 都 nonzero，不能覆盖 raw，也不能产出可提交 fixture；
  - algorithm manifest 必须逐字固定 strict UTF-8、line-ending normalization、token/line grammar、typed
    ordinal placeholder format、ordering、escaping、duplicate handling、resource limits、error codes 与
    whole-stream hashing。未知/invalid UTF-8/control/bidi/confusable/unclassified token 或 line 必须
    fail closed，不得透传；
  - `safe-literals-v1.txt` 的每个保留字必须在该 task 的维护者 review 中逐项批准，只允许结构语法；
    package/ability/page/window/component/path、用户/设备标识与任意页面文本不得通过 pattern、prefix、
    fallback 或“看似无害”启发式进入 allowlist。后续 TASK-UD-001 只读消费，不得修改；
  - transform receipt 还必须记录 pinned Git path/version/hash、worktree raw-output/inventory hashes、
    controlled-root 与 input pre/post descriptor identity、output/receipt identity、open/create policy、mode/
    link count 与 containment result；两份 receipts 都不能通过 symlink/hardlink/alias 指回 raw、derived、
    对方或任一 worktree；
  - offline adversarial/property tests 只用 synthetic bytes，至少覆盖 invalid UTF-8、CRLF/CR、NUL/
    control/bidi/confusable、Unicode normalization、package/ability/path/serial/window/component/长数字、
    页面文本、未知 token/line、overlong input、ordering/duplicate、allowlist/source/manifest/hash drift、
    output=input、receipt=input、output=receipt、lexical/canonical alias、`..`、symlink leaf/parent、raw
    hardlink/link-count > 1、existing target、worktree-target symlink、parent-swap race、raw identity/mtime/size
    mutation、worktree inventory drift、wrong mode、PATH poisoning、Git missing/not-regular/hash/version
    mismatch、malformed/truncated/duplicate/incomplete `--porcelain -z` inventory、Git nonzero/timeout、
    transform receipt mutation、derived mismatch、missing/duplicate review receipt、empty reviewer、invalid/
    rejected decision、review-before-transform、destination traversal/absolute path，以及 deterministic repeat
    与零敏感 literal byte search；
    任何 unclassified/unsafe-path input 必须 nonzero 且不覆盖 raw、不产出
    可提交 derived fixture。
- Future allowed paths（仅在独立 readiness revision 合入后生效）：
  - `scripts/ui_dump_redaction/README.md`
  - `scripts/ui_dump_redaction/redact.py`
  - `scripts/ui_dump_redaction/test_redact.py`
  - `scripts/ui_dump_redaction/record_privacy_review.py`
  - `scripts/ui_dump_redaction/test_record_privacy_review.py`
  - `scripts/ui_dump_redaction/algorithm-v1.json`
  - `scripts/ui_dump_redaction/safe-literals-v1.txt`
  - `scripts/ui_dump_redaction/redaction-receipt.schema.json`
  - `scripts/ui_dump_redaction/privacy-review-receipt.schema.json`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/**`
  - 本 `tasks.md`（仅该 task 的独立 status/evidence 更新）
- Read-only inputs:`openspec/specs/ui-dump/spec.md`、`openspec/contracts/hardware-evidence.schema.json`、
  本 change 的 privacy boundary；不读取真实 capture raw。
- Hardware required:no；installed HDC、device/server/network dispatch 与真实 UI raw input 均为 `0`。
- Required environment（未来 implementation）：固定 Python 与 SDD task 相同；固定 inventory executable
  仅为上述 `/usr/bin/git` path/version/hash。任一 identity/version/hash 漂移即 blocked，不能从 PATH
  fallback、联网安装或由执行者换 Git。
- Required evidence（未来）：`run.md` 记录 source/manifest/allowlist/schema/test hashes、exact CLI、
  fixed Python/Git identities、synthetic transform/review receipt chain hashes、binary negative outcomes、
  deterministic replay hash 与 repo sensitive-literal audit；不得声称 synthetic tests 是 raw capture、
  现实人工 privacy review 或 canonical `AC-DUMP-008-01` PASS。
- Forbidden now:创建/修改上述实现文件、选择 safe literals、读取/复制真实 raw、生成 derived golden、
  起草 PASS/done、从 PATH 选择 Git、把 reviewer/decision 写回 transform receipt，或把人工 privacy
  review 替换成自动化真实性声明。

## TASK-UD-PRIVACY-REVIEW-001 — human derived-golden privacy review/finalization

- Status:blocked（真实 raw/derived 的 transform 与人工 privacy review 尚无获批 executable two-stage
  chain；Agent raw access 与 finalization count 必须为 `0`）
- Objective:在 golden implementation 前，由人类维护者对 decision revision 选定的每个 repo-external
  raw origin 重放 pinned transform，检查 exact derived bytes，再用 pinned finalizer 生成独立不可变
  `privacy-review-receipt`；transform receipt 永不补写 reviewer/decision。
- Change-local closure:`INT-UD-PRIVACY-REVIEW-001` / `TEST-INT-UD-PRIVACY-REVIEW-001`。
- Canonical Safety input:`REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01`；本 task
  不执行 diagnostic export、不认领 canonical platform PASS，只提供 change-local human review evidence。
- Depends on:
  - `TASK-UD-REDACTOR-001 done`，其 transform/finalizer source、两个 receipt schemas、tests、commit
    OID/逐文件 hashes、fixed Python/Git identities 与 exact CLIs 已合入且无 drift；
  - `TASK-UD-CAP-MUT-001 done`、`TASK-UD-CAP-R4-001 done`，以及后续 approved decision revision
    已逐 golden 固定 source raw-origin/hash、Recipe/output family 与 repository destination；
  - future readiness revision 固定 human-only execution entrypoint、repo-external controlled-root locator
    IDs 与 evidence allowed paths；任一缺失时不得读取 raw 或创建 derived/review receipt。
- Fixed two-stage procedure（未来）：
  1. 人类操作者按 `TASK-UD-REDACTOR-001` exact transform CLI 生成新的 derived + immutable transform
     receipt；raw identity/size/mtime/hash 前后不变，Git/path containment 全部 PASS；
  2. 人类对 exact derived hash 对应的完整 bytes 做 privacy review；package/ability/page/window/component/
     path/user/device identifiers、页面文本或未知 literal 任一残留都选择 `rejected`，不得进入 golden；
  3. review 后才调用 exact `record_privacy_review.py` CLI，显式提供 claimed reviewer、decision、reviewedAt
     与 fixed repository destination；finalizer 只读验证 immutable transform receipt/derived hash，并
     exclusive-create separate review receipt；
  4. 只有 `decision=approvedForRepository`、reviewedAt > transform completedAt、receipt chain/destination/
     hashes 全部一致的 derived 才能交给 TASK-UD-001。rejected/missing/multiple/mutated/mismatched review
     receipt 一律阻断；不得重跑 finalizer 覆盖既有 decision。
- Future allowed paths:必须由 dependencies 完成后的独立 readiness revision 固定；当前只保留
  `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-PRIVACY-REVIEW-001/**`
  与本 `tasks.md` 独立 status/evidence path。`scripts/ui_dump_redaction/**` 全部只读。
- Read-only inputs（未来）：pinned redactor/finalizer toolchain；capture/decision repo-safe manifests；
  decision 固定的 repo-external raw origins。receipt 不得包含 raw/derived bytes、absolute user path、serial、
  package/ability/page/window/component literal；只记录 logical locator ID、hash/size 与 review metadata。
- Hardware required:no；human only for sensitive raw/review。installed HDC、device/server/network dispatch
  均为 `0`；Agent 不读取 raw/derived，不填写 reviewer/decision。
- Verification（未来）：每个拟提交 golden 恰有一条 immutable transform receipt → exact derived hash →
  approved separate privacy-review receipt → exact repository destination 链；reviewer/decision/time 字段只
  自动检查一致性，现实人工复核由维护者对该 evidence PR 的 attestation 保证。负例至少覆盖 receipt
  mutation/replacement、derived drift、review before transform、rejected/unknown decision、empty reviewer、
  duplicate/missing review、destination traversal/mismatch、Git/toolchain/path identity drift 与 raw mutation。
- Required evidence（未来）：`run.md`、repo-safe transform/privacy-review receipts、两者 SHA-256、derived
  hash/size 清单、claimed human reviewer/decision/time、fixed destination 与 privacy checklist disposition；
  raw/derived bytes 保持 repo 外，直到 TASK-UD-001 只复制已批准 derived fixture。
- Forbidden now:读取真实 raw/derived、运行 transform/finalizer、起草 reviewer/decision、生成 receipt/
  golden、使用 GUI/网络/设备/HDC，或把本 task 标为 ready/done。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:blocked（r3 review-remediation candidate；仅在本治理 PR 由维护者 review/merge 后
  生效。本 PR 不执行 TASK-UD-001，不产生 implementation/acceptance evidence，也不使
  CHG-008 verified）
- Blocking review（2026-07-19；只读审计，零真实 HDC/device dispatch）：
  - Capture/decision blocker：
    `EVD-M0B-DAYU200-20260718-001` 的 redacted manifest 只含 `hidumper --help` 与
    `hidumper -ls`。所谓四个文件是两条命令的 stdout/stderr，不是四个 Recipe；现有 evidence
    没有 Recipe success output family。r3 `capture-runbook.md` 只固定 one-element `-a` candidate
    boundary；official source 不能证明 target output mode，因此 R1-R4 首次 capture 全部保守提高为
    `deviceMutation`。`TASK-UD-PREFLIGHT-001` 因 production server identity/generation、durable
    binding 与 registered discovery/adoption 缺失而 blocked，mutation task 也 blocked；后续
    decision revision 尚未登记任何 target-build success/failure/unknown family。执行者不得选择
    fallback argv、marker 或结构锚点，再用自造 fake/golden 自证通过。
  - Consumer-dependency blocker：r2 未按 CHG-2026-014 提供逐 deliverable dependency 表。
    本 r3 在下表完成审查，但由于 capture/decision 尚未满足，每一项结论仍是
    `remains blocked`；后续 readiness revision 必须重新确认表内结论。
  - Core-trace blocker：`REQ-DUMP-003` / `AC-DUMP-003-01` / `TEST-AC-DUMP-003-01` 必须由
    TASK-UD-001 自身闭环。缺失、空值、非法格式及参数/shell injection 形状的 component ID
    必须在 argv/`ProcessRequest` materialization 前失败，request 与 dispatch counter 均为 `0`。
  - SDD-environment gate:satisfied for the declared host。固定 interpreter、Python/PyYAML
    version 与 executable hash 见本 task `Required environment`；未来执行前任一漂移仍 fail
    closed，不得回落到缺 `yaml` 的默认 `python3` 或联网安装。
  - Draft disposition：PR #126 的 argv/marker/fixture 与 PASS evidence 建立在未批准的假设上，
    不属于本 task acceptance evidence，只作为不可合并 draft 审计记录保留。

### CHG-2026-014 consumer dependency review

| Consumer deliverable | 使用的 consolidated interface | 是否需要 source AC | 结论 |
| --- | --- | --- | --- |
| typed Recipe、window/component token validator 与 argv materializer | 纯 ArkDeckOpenHarmony typed value；不调用 M1-006 probe/lifecycle/authorization | no | remains blocked：candidate matrix 已固定，但 target capture/decision 尚未完成 |
| success/failure/unknown semantic evaluator | `ArkDeckProcess.ProcessOutputChunk`、`ProcessExecutionResult`、`ProcessSemanticEvaluating`、`ProcessSemanticResult` | no | remains blocked：四 Recipe output family/marker 未登记 |
| Process/HDC preflight-to-request seam 与零 launch 证明 | `ArkDeckProcess.ProcessRequest` recording factory/dispatch counter；明确不使用 `HDCProduction`、`HDCProcessCommandRunner` 或真实 child | no | remains blocked：Core negative matrix 尚未在获批实现 revision 二值执行 |
| derived golden fixture 与 SwiftPM resource contract | `Bundle.module` resource seam；不消费 M1-006 source behavior/evidence | no | remains blocked：capture + `TASK-UD-REDACTOR-001` immutable transform contract + `TASK-UD-PRIVACY-REVIEW-001` separate approved review receipt 尚未闭环 |
| OpenHarmony profile / Integration lock 登记 | integration registry/schema；不消费 M1-006 source AC | no | remains blocked：argv 与 output family decision 尚不存在 |

所有 `no` 仅表示该 deliverable 不需要 M1-006 source AC，不等于当前可执行。TASK-UD-001
不绑定生产 HDC dispatch，不触发 device mutation，不产生 compatibility/conformance/hardware/
support/release claim；其 own verification 在 authoritative Recipe inputs/decision 缺失时不能二值
执行，所以依 CHG-2026-014 保持 `blocked`。SDD interpreter 已固定不解除 capture/decision
blocker；`TASK-M1-006` 也保持 `blocked`/非 `done`。

上表仅审查 TASK-UD-001 的实现 deliverables。`TASK-UD-PREFLIGHT-001` 不在该 independence
结论内：它明确消费 production `HDCServerSupervisor` 的 endpoint/ownership/generation behavior，
因此需要 TASK-M1-006 source AC/done 以及后续 registered-probe adoption；当前不得用 consolidated
interface 自行替代。

### Requirement → AC → Test trace

| Requirement/source | Acceptance | Canonical Test ID / method | TASK-UD-001 closure |
| --- | --- | --- | --- |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | 缺失、空、非法、注入型 component ID；零 argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | 获批 argv exact equality；仅登记 family 可成功；exit-0/unknown fail closed |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden registration | capture raw hash → immutable transform receipt → approved privacy-review receipt → derived fixture；profile/lock/resource 一致 |

- Objective:仅在 approved target-build Recipe capture 与后续 decision/readiness revision 固定
  精确 argv/output family 后，实现四个 canonical ArkUI Recipe wrapper、Core component ID
  preflight、golden 登记与 fake/adversarial contract tests。
- Requirements/AC:`REQ-DUMP-003` / `AC-DUMP-003-01`，以及 change-local
  `INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`。
- Unblock prerequisites（全部满足后另起 governance revision，不能由实现 PR 顺带改写）：
  - external Core MAJOR prerequisite 完整关闭：`TASK-JAUTH-CORE-001 done`、owning change
    verified/archived、`CORE-3.0.0` ratified，且本 change 已 retarget 新 baseline；
  - `TASK-UD-PREFLIGHT-001 done`：human evidence 证明 existing server 的 exact endpoint/
    ownership/generation 和 durable CurrentDeviceBinding positive revision；capture harness 只经
    production loader/replay materialize `-t`，没有 operator/default/stale connect-key path；
  - `TASK-UD-HWE-SEM-001 done`：offline verifier 的 input schemas、source/test path、commit OID、
    SHA-256 与 exact CLI 均已固定，schema-valid 但 physical model/serial/identity、binding/server/
    intent/confirmation scope/journal ordering/artifact 语义不一致或过期的 negative fixtures 全部 fail closed；
    confirmation event 的 durable append sequence/chain 必须严格早于全部 related intents，时间字段或事后
    evidence 不得补权；operator
    自动校验只认领 claimed-field/attestation 一致性，现实人类身份仍由维护者 PR review 保证；
  - `TASK-UD-CAP-MUT-001 done`：人类维护者只按 `capture-runbook.md` 的封闭 Phase A 矩阵执行
    R1-R3 `deviceMutation` Recipe，逐条记录 one-element `-a` payload、same binding/server generation、
    separate raw origins、exit/timeout/hash、registered inventory/ownership/cleanup；raw UI bytes留在
    受控位置，不进入仓库；
  - `TASK-UD-CAP-R4-001 done`：只在 R2 output family 与 versioned typed extractor 获批后执行 R4；
    component token 由同一 R2 raw hash 的 extractor receipt 唯一产生，manual/ambiguous/stale path
    均不可达；三个 realHardware task 均有 schema-valid 且 semantic-valid
    `hardware-evidence.json`，其中 physical model/serial/identity、`device.bindingRevision` 与 durable
    receipt/intents/unexpired confirmation scope 精确相等；
  - 每个拟支持 Recipe 至少有一份真实成功输出；若目标 build 无法成功，平台结论必须如实为
    blocked/nonConformant，不得由 fake 补齐。后续 approved decision revision 逐 Recipe 固定精确
    argv 以及 success/failure/unknown family；本 change 只允许可由 repo-safe synthetic/derived fixture
    正向覆盖的文本 marker 或结构 parser family，并说明 precedence/chunk boundary。raw byte-fingerprint/
    digest family 明确 unsupported/out of scope，不得由 decision revision 登记；若未来需要，必须另起
    approved change 先固定 privacy-safe、复用 production stream→digest 实现路径的 conformance seam；
  - `TASK-RLC-001 done` + CHG-2026-014 verified 继续只作为 package bytes/interfaces provenance；
    不提供 M1-006 source AC，且上表经后续 revision 复核仍无 `yes`；
  - `TASK-UD-REDACTOR-001 done`：`uidump-derived-redaction-v1` 的 source/algorithm manifest/
    safe-literal allowlist、transform/finalizer sources、两个 receipt schemas/tests、commit OID 与逐文件
    SHA-256 已合入，fixed Python/Git identities、两个 exact CLIs 和 synthetic adversarial/property evidence
    PASS；其 controlled-root/worktree inventory、no-follow、exclusive-create、pairwise file identity/raw
    immutability gates 及负例全部 PASS。TASK-UD-001 只读验证这些 pins，禁止运行/修改 toolchain；
  - `TASK-UD-PRIVACY-REVIEW-001 done`：每个 selected raw origin 已由人类完成 exact transform + derived
    privacy review；不可变 transform receipt 与 separate `decision=approvedForRepository` review receipt
    绑定同一 derived hash/destination，reviewedAt 晚于 transform completedAt。TASK-UD-001 不读取 raw、
    不填 reviewer/decision、不生成或修改两份 receipts；缺任一 approved chain 时不得 ready；
  - 固定 SDD Python executable 的 path/version/hash 重新 preflight 通过；r3 与后续 readiness
    revision 均经维护者 review/merge。
  - Agent 不得执行上述真实 `hdc`/device capture，也不得以公开文档、simulation 或 fake
    代替 human target-build evidence。
- Allowed paths:
  - `.gitattributes`（仅新增 HiDumper golden binary/byte-exact pattern；fixture 提交前固定）
  - `Packages/ArkDeckKit/Package.swift`（仅为 ArkDeckContractTests 登记 HiDumper Golden
    `.copy` resource tree，不改变 product/dependency）
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HiDumperWrapper.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperWrapperContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperGoldenResourceContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/1.0.0/**`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-001/**`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md`（仅 TASK-UD-001 状态与
    completion evidence）
- Read-only inputs:
  - `openspec/specs/ui-dump/spec.md`
  - `openspec/contracts/catalogs/dump-recipes.yaml`
  - 本 change `capture-runbook.md` 与 preflight/capture task 的已合入 repo-safe evidence
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/**`
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/**`
  - preflight/capture manifests 与 `TASK-UD-PRIVACY-REVIEW-001` 固定的 repo-external **derived** paths、
    immutable transform receipts、approved privacy-review receipts（只允许按 hash 读取/复制 approved
    derived；raw path/bytes 对本 task 不可达）
  - `scripts/ui_dump_redaction/README.md`、`redact.py`、`record_privacy_review.py`、`algorithm-v1.json`、
    `safe-literals-v1.txt`、`redaction-receipt.schema.json`、`privacy-review-receipt.schema.json` 与两个
    prerequisite tasks 的已合入 evidence（只读验证 pins；本 task 不执行或修改）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    `openspec/baselines/**`、`openspec/platforms/**`、hardware matrix
  - TASK-M1-006 源码/任务/evidence 与其他 change/task evidence
  - `scripts/ui_dump_redaction/**` 的任何修改（该目录只由 `TASK-UD-REDACTOR-001` owning task 管理）
  - 任何真实 raw path/bytes、transform/finalizer execution、reviewer/decision input 或 receipt rewrite
  - 上述 Allowed paths 以外的 App/Package source、tests、fixtures 或 integration inputs
  - 已安装真实 `hdc`、真实设备、capture/collector、非 loopback 网络、GUI/系统授权、
    device mutation/destructive dispatch
- Risk:medium（只复制已经 human-reviewed 的 derived fixture，并固定新的 argv/output-family 语义；
  必须闭环 immutable transform + separate privacy-review receipts，并以 fake 对抗测试覆盖
  exit-0 陷阱）
- Hardware required:no for TASK-UD-001；真机输入只来自三个具名前置 realHardware tasks 的已合入
  evidence。本实现/contract verification 必须 headless、无设备。
- Required environment:锁屏 macOS headless shell；Swift 6.3.3、`xcrun swift-format` 6.3.0、
  SwiftPM；固定 Python executable
  `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`，Python `3.14.6`、PyYAML
  `6.0.3`、SHA-256 `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。
  执行前先验证 version/hash 与 `import yaml`，再以该 path 设置 `ARKDECK_PYTHON` 调用 guard。
  任一 preflight 失败即 blocked；不得联网下载、启动 GUI/真实 HDC/真实设备或取得新系统授权。
- Deliverables:
  - 四个 Recipe 的 approved fixed typed argv composition；window/component ID 只作为已验证
    token 插入，不接受 shell/free-form text；componentDetail 的缺失/空/非法/注入输入在产生
    argv/`ProcessRequest` 前失败，recording request/dispatch count 均为 `0`；
  - 只依 approved decision revision 登记的 output family 做 success/failure/unknownOutput
    classification；exit code 0 不能单独成功，`option ... missed` 明确失败，未登记/marker 缺失
    fail closed；实现者不得新增自己的 success marker；仅支持 repo-safe fixture 可正向复验的文本
    marker/结构 parser family，raw byte-fingerprint/digest family 必须拒绝登记；
  - byte-exact **derived** HiDumper golden pack、registry/hash/provenance、`.gitattributes` 与
    Bundle.module resource contract；raw 永不入仓且本 task 不读取 raw/运行 transform。每个 fixture
    只从 `TASK-UD-PRIVACY-REVIEW-001` approved chain 复制：immutable transform receipt 绑定 raw hash、
    algorithm/source/manifest/allowlist、derived/replay-command hashes 与 replacement counts；separate
    privacy-review receipt 绑定该 transform receipt hash、same derived hash、claimed reviewer、
    `approvedForRepository` decision、reviewedAt 与 exact destination。不得补写/合并 receipt、修改
    algorithm/allowlist、把 derived 标为 raw 或由未登记 transform 生成 fixture；
  - OpenHarmony profile 与 Integration lock 版本化、一致登记；未登记 family 保持
    unknown/unsupported；
  - fake/adversarial tests 与 `evidence/runs/TASK-UD-001/run.md`，记录 base revision、
    输入/输出 hash、命令、二值 AC、偏差/风险及真实 HDC/device dispatch count `0`。
- Verification:
  - `TEST-AC-DUMP-003-01`：componentDetail 的 missing、empty、非法字符/格式、leading option、
    whitespace/newline、shell metacharacter 与 argument-injection cases 全部 preflight failure；
    argv/request materialization count `0`，recording dispatch count `0`；合法 token positive control
    只证明能 materialize，不启动真实 HDC；
  - `TEST-INT-UD-WRAPPER-001`：四 Recipe 对 approved decision 的 argv exact equality；每个已登记
    文本 marker/结构 parser success/failure/unknown family 均由 repo-safe synthetic/derived fixture
    通过 exact production semantic-evaluator path 正向覆盖；raw byte-fingerprint/digest registration 被
    拒绝；exit-0 trap、marker absence、chunk
    boundary、stdout/stderr precedence 与无 shell composition 的 fake/adversarial branches 全覆盖；
  - `TEST-INT-UD-GOLDEN-001`：transform receipt 的 raw hash 与 capture manifest 一致，source/algorithm/
    manifest/allowlist/Git/replay pins 与 `TASK-UD-REDACTOR-001` evidence 一致；separate privacy-review
    receipt hash 引用该 immutable transform receipt，same derived hash、`approvedForRepository`、review
    time/destination 与 `TASK-UD-PRIVACY-REVIEW-001` evidence 一致。任一 pin/receipt/decision/time/hash/
    destination 漂移或 missing/duplicate/rejected review fail closed；本 task raw-access/transform/finalizer
    count 为 `0`；repo 不含 raw/sensitive literals，receipts、registry/profile/lock/Bundle.module path/hash
    一致；
  - Commands:`xcrun swift-format lint` 变更 Swift 文件；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests`；
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests`；
    `swift test --package-path Packages/ArkDeckKit`；固定 interpreter 的 hash/version/PyYAML
    preflight；以固定 path 设置 `ARKDECK_PYTHON` 运行 `scripts/check-sdd.sh`；
    `git diff --check`；fixture SHA-256 与禁止 dispatch 静态审计；
  - Core Test ID 与两个 change-local Test ID 均有同一 implementation revision 的可复查
    PASS evidence
    才能起草 `done`；不构成 M1-006、HDC compatibility、platform conformance、hardware、
    support 或 release claim。
