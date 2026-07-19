# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

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
  `hardware-evidence.json`。durable Session/journal 留在 repo 外；binding/server receipt 只记录
  session/job ID、positive binding revision、binding event/hash、identity hash、endpoint/ownership/
  generation 与 toolchain snapshot hash，不含 connect key/serial。physical-target receipt 与 hardware
  evidence 按其 approved schema 记录 model/serial，并由 identity hash、confirmedAt/validUntil、claimed
  operator/attestation 字段关联；repo-safe exposure 边界由前置 contract revision 固定。
- Verification（未来）：capture harness 只能接收 receipt ID + fixed revision，经 production loader
  replay exact Session/journal，revision/hash/current identity 任一不符时 intent/request/process `0`；
  每次 HDC intent 前后 revalidate same server generation；hardware evidence 必须按下述固定 validator
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
  physical-target confirmation receipt 与 task-applicable confirmation manifest 的字段、时间和 hash
  一致性；
  它不声称证明操作者的现实身份。
- Change-local closure:`INT-UD-HWE-SEM-001` / `TEST-INT-UD-HWE-SEM-001`；不认领任何
  canonical Core AC PASS。
- Blocking dependencies/gates:
  - 独立 approved contract/integration revision 先固定 repo-safe binding receipt、server receipt、
    device intent manifest、physical-target confirmation receipt 与 task-applicable confirmation manifest 的
    schema path/version，以及 canonical serialization/hash linkage；当前 generic
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
  - 后续 readiness revision 固定 source commit OID、下列两个文件各自 SHA-256、fixed Python
    executable path/version/hash 与 exact CLI；hash 未产生前本 task 不能 ready；
  - exact CLI shape 必须为
    `<FIXED_PYTHON> scripts/ui_dump_capture/verify_hardware_evidence.py --evidence <hardware-evidence.json> --binding-receipt <binding-receipt.json> --intent-manifest <intent-manifest.json> --server-receipt <server-receipt.json> --physical-target-receipt <physical-target-confirmation-receipt.json> --confirmation-manifest <confirmation-manifest.json> --repository-root <ARKDECK_ROOT> --expected-task-id <TASK_ID> --expected-acceptance-id <AC_ID>`；
    所有输入均为 path token，不得接受 raw JSON、connect key、serial override 或网络来源；
  - verifier 必须检查 claimed operator 字符串/attestation 字段跨文件精确相等、confirmation
    `actor=user`/accepted/time window、physical model/serial/identity hash/scope hash linkage、
    `bindingRevision > 0` 且等于 binding receipt 和全部 device intents、server endpoint/ownership/
    generation 与 Job snapshot/全部 pre/post receipt 相等、task/AC/step kinds 精确、repo artifact
    path/hash 可解析、敏感 raw 不在 git；unknown/missing/extra/mismatch/expired 一律 nonzero；
    **这只证明记录一致性，不证明 claimed operator 是真人**。操作者真实性仍按
    `hardware-evidence.schema.json` description 与治理规则由维护者 review/merge attestation 保证；
  - offline negative tests 至少覆盖 missing/zero binding revision、receipt/intent revision mismatch、
    physical model/serial/identity mismatch、stale/expired/substituted physical confirmation、scope hash/
    related intent/arguments mismatch、server generation/endpoint/ownership drift、wrong task/AC、
    claimed-operator/attestation mismatch、confirmation actor/decision mismatch、artifact hash/path
    mismatch、raw 路径落入 git、schema-valid 但语义不一致；不得把 `operator="human-name"` positive
    fixture 描述为真人身份证明，也不得只测试 schema-invalid JSON。
- Future allowed paths（仅在上述 input contracts 合入后的独立 readiness revision 生效）：
  - `scripts/ui_dump_capture/verify_hardware_evidence.py`
  - `scripts/ui_dump_capture/test_verify_hardware_evidence.py`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-HWE-SEM-001/**`
  - 本 `tasks.md`（仅该 task 的独立 status/evidence 更新）
- Read-only inputs:未来固定的 binding/server/intent/physical-target/confirmation schemas；
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
  `confirmation-manifest.json`。hardware record 的 model/serial/physical confirmation、
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
  `hardware-evidence.json`；raw 继续留在 repo 外。
- Verification（未来）：R4 exact one-element payload 中 component token 与 extractor receipt 相等；
  altered/stale/foreign R2 hash、parser drift、zero/multiple selection、manual token、binding/server/path
  drift 的 R4 request/process dispatch 均为 `0`；schema + pinned semantic verifier 均 PASS；
  destructive/Agent dispatch `0`。
- Forbidden now:component parser/extractor 发明或实现、R4 capture/evidence、manual component ID、
  installed HDC/device/server/network dispatch。

## TASK-UD-REDACTOR-001 — deterministic derived-golden redactor/allowlist 前置

- Status:blocked（`uidump-derived-redaction-v1` 当前只有名称与高层步骤，没有获批 source、
  safe-literal allowlist、receipt schema、replay CLI 或 adversarial tests；不得接触真实 raw）
- Objective:在 `TASK-UD-001` ready 前，以独立 host-only task 实现、审查并固定 fail-closed
  `uidump-derived-redaction-v1`，使后续执行者只能重放已批准算法与 safe-literal allowlist，不能在
  golden 实现 PR 中决定保留哪些 UI 文本。
- Change-local closure:`INT-UD-REDACTOR-001` / `TEST-INT-UD-REDACTOR-001`。
- Canonical Safety input:`REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01`；本 task
  不执行 diagnostic export、不认领 canonical platform PASS，只对 derived-golden 输入加严隐私边界。
- Blocking dependencies/gates:
  - 独立 approved readiness/implementation revision 仅在下列 exact paths 内定义 algorithm manifest、
    source、safe-literal allowlist、receipt schema 与 tests；完成时固定 source commit OID、每个文件
    SHA-256、fixed Python path/version/hash 与 exact replay CLI，任一 hash 未知时不得 `done`；
  - exact CLI shape 必须为
    `<FIXED_PYTHON> scripts/ui_dump_redaction/redact.py --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt --input <CONTROLLED_RAW_PATH> --expected-input-sha256 <RAW_SHA256> --output <REPO_EXTERNAL_DERIVED_PATH> --receipt <REPO_EXTERNAL_RECEIPT_PATH>`；
    output/receipt 初始位置必须在 repo 外，tool 不得直接写 git worktree；
  - algorithm manifest 必须逐字固定 strict UTF-8、line-ending normalization、token/line grammar、typed
    ordinal placeholder format、ordering、escaping、duplicate handling、resource limits、error codes 与
    whole-stream hashing。未知/invalid UTF-8/control/bidi/confusable/unclassified token 或 line 必须
    fail closed，不得透传；
  - `safe-literals-v1.txt` 的每个保留字必须在该 task 的维护者 review 中逐项批准，只允许结构语法；
    package/ability/page/window/component/path、用户/设备标识与任意页面文本不得通过 pattern、prefix、
    fallback 或“看似无害”启发式进入 allowlist。后续 TASK-UD-001 只读消费，不得修改；
  - receipt schema 必须绑定 algorithm/source/manifest/allowlist OID 与 hashes、raw/derived whole-stream
    hashes、byte counts、replacement counts by typed category、error/disposition 与 replay command hash；
  - offline adversarial/property tests 只用 synthetic bytes，至少覆盖 invalid UTF-8、CRLF/CR、NUL/
    control/bidi/confusable、Unicode normalization、package/ability/path/serial/window/component/长数字、
    页面文本、未知 token/line、overlong input、ordering/duplicate、allowlist/source/manifest/hash drift、
    deterministic repeat 与零敏感 literal byte search；任何 unclassified input 必须 nonzero 且不产出
    可提交 derived fixture。
- Future allowed paths（仅在独立 readiness revision 合入后生效）：
  - `scripts/ui_dump_redaction/README.md`
  - `scripts/ui_dump_redaction/redact.py`
  - `scripts/ui_dump_redaction/test_redact.py`
  - `scripts/ui_dump_redaction/algorithm-v1.json`
  - `scripts/ui_dump_redaction/safe-literals-v1.txt`
  - `scripts/ui_dump_redaction/redaction-receipt.schema.json`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/**`
  - 本 `tasks.md`（仅该 task 的独立 status/evidence 更新）
- Read-only inputs:`openspec/specs/ui-dump/spec.md`、`openspec/contracts/hardware-evidence.schema.json`、
  本 change 的 privacy boundary；不读取真实 capture raw。
- Hardware required:no；installed HDC、device/server/network dispatch 与真实 UI raw input 均为 `0`。
- Required evidence（未来）：`run.md` 记录 source/manifest/allowlist/schema/test hashes、exact CLI、
  synthetic fixture hashes、binary negative outcomes、deterministic replay hash 与 repo sensitive-literal
  audit；不得声称 synthetic tests 是 raw capture 或 canonical `AC-DUMP-008-01` PASS。
- Forbidden now:创建/修改上述实现文件、选择 safe literals、读取/复制真实 raw、生成 derived golden、
  起草 PASS/done 或把人工隐私 review 替换成自动化真实性声明。

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
    fallback argv、marker、fingerprint 或结构锚点，再用自造 fake/golden 自证通过。
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
| derived golden fixture 与 SwiftPM resource contract | `Bundle.module` resource seam；不消费 M1-006 source behavior/evidence | no | remains blocked：capture + 独立 `TASK-UD-REDACTOR-001` pinned source/manifest/allowlist/replay receipt 尚未闭环 |
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
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden registration | controlled raw hash → deterministic derived receipt；privacy、profile/lock/resource 一致 |

- Objective:仅在 approved target-build Recipe capture 与后续 decision/readiness revision 固定
  精确 argv/output family 后，实现四个 canonical ArkUI Recipe wrapper、Core component ID
  preflight、golden 登记与 fake/adversarial contract tests。
- Requirements/AC:`REQ-DUMP-003` / `AC-DUMP-003-01`，以及 change-local
  `INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`。
- Unblock prerequisites（全部满足后另起 governance revision，不能由实现 PR 顺带改写）：
  - `TASK-UD-PREFLIGHT-001 done`：human evidence 证明 existing server 的 exact endpoint/
    ownership/generation 和 durable CurrentDeviceBinding positive revision；capture harness 只经
    production loader/replay materialize `-t`，没有 operator/default/stale connect-key path；
  - `TASK-UD-HWE-SEM-001 done`：offline verifier 的 input schemas、source/test path、commit OID、
    SHA-256 与 exact CLI 均已固定，schema-valid 但 physical model/serial/identity、binding/server/
    intent/confirmation scope/artifact 语义不一致或过期的 negative fixtures 全部 fail closed；operator
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
    argv 以及 success/failure/unknown family（文本 marker、结构锚点或 byte fingerprint 采用哪种
    必须显式声明），并说明 precedence/chunk boundary；
  - `TASK-RLC-001 done` + CHG-2026-014 verified 继续只作为 package bytes/interfaces provenance；
    不提供 M1-006 source AC，且上表经后续 revision 复核仍无 `yes`；
  - `TASK-UD-REDACTOR-001 done`：`uidump-derived-redaction-v1` 的 source/algorithm manifest/
    safe-literal allowlist/receipt schema/tests、commit OID 与逐文件 SHA-256 已合入，fixed replay CLI
    和 synthetic adversarial/property evidence PASS；TASK-UD-001 只读重放这些 pins，禁止修改算法或
    allowlist。缺任一 pin 时不得起草 ready；
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
  - preflight/capture manifests 记录、且由后续 readiness revision 固定的 exact repo-external raw
    paths（只允许读取/重算 hash/执行 approved deterministic transform；不得原地修改）
  - `scripts/ui_dump_redaction/README.md`、`redact.py`、`algorithm-v1.json`、
    `safe-literals-v1.txt`、`redaction-receipt.schema.json` 及 `TASK-UD-REDACTOR-001` 已合入 evidence
    （只读重放；不得由本 task 修改）
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    `openspec/baselines/**`、`openspec/platforms/**`、hardware matrix
  - TASK-M1-006 源码/任务/evidence 与其他 change/task evidence
  - `scripts/ui_dump_redaction/**` 的任何修改（该目录只由 `TASK-UD-REDACTOR-001` owning task 管理）
  - 上述 Allowed paths 以外的 App/Package source、tests、fixtures 或 integration inputs
  - 已安装真实 `hdc`、真实设备、capture/collector、非 loopback 网络、GUI/系统授权、
    device mutation/destructive dispatch
- Risk:medium（把人类受控 raw 经 deterministic redaction 登记为 derived fixture，并固定新的
  argv/output-family 语义；必须闭环 raw/derived receipt 与隐私审查，并以 fake 对抗测试覆盖
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
    fail closed；实现者不得新增自己的 success marker；
  - byte-exact **derived** HiDumper golden pack、registry/hash/provenance、`.gitattributes` 与
    Bundle.module resource contract；raw 永不入仓，只能按 `TASK-UD-REDACTOR-001` 固定 CLI 只读
    重放 pinned `uidump-derived-redaction-v1`，receipt 绑定 raw、algorithm/source/manifest/allowlist、
    derived 与 replay-command hashes、replacement counts 及 human privacy review；不得修改算法/
    allowlist、把 derived 标为 raw 或由未登记 transform 生成 fixture；
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
    success/failure/unknown family、exit-0 trap、marker absence、chunk boundary、stdout/stderr
    precedence 与无 shell composition 的 fake/adversarial branches 全覆盖；
  - `TEST-INT-UD-GOLDEN-001`：受控 raw hash 与 capture manifest 一致；controlled replay 的
    pinned exact CLI/algorithm/source/manifest/allowlist hashes 与 `TASK-UD-REDACTOR-001` evidence
    一致并产生已登记 derived hash；任一 pin 漂移、unknown token/line 或 receipt mismatch fail closed；
    repo 不含 raw/sensitive literals；receipt、registry/profile/lock/Bundle.module resource path/hash
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
