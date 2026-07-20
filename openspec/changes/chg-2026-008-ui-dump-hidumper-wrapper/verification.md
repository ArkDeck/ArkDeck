# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r3
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan。r3 merge 本身不执行任何 task，且 merge 后
没有 real-device task 为 `ready`。`TASK-UD-PREFLIGHT-001`、`TASK-UD-HWE-SEM-001`、
`TASK-UD-REDACTOR-001`、`TASK-UD-PRIVACY-REVIEW-001`、`TASK-UD-CAP-MUT-001`、
`TASK-UD-CAP-R4-001` 与 `TASK-UD-001`
均保持 `blocked`；任何
installed-HDC/device/binding/server-lifecycle 执行或基于未批准 argv/output family、自造
fake/golden 的既有 PASS 都无效。

## Readiness environment

- r3 必须先经维护者 review/merge。`TASK-RLC-001 done`、CHG-2026-014 verified 只提供 package
  bytes/interfaces provenance，不提供 M1-006 source AC；TASK-UD-001 的逐 deliverable consumer
  dependency 表还须在未来 readiness revision 复核且没有 `yes` 行。
- 当前 M0B manifest 只含 `hidumper --help` 和 `hidumper -ls`，不是四 Recipe capture。其旧
  connect key、server state/generation 和 direct-HDC procedure 都不能复用为当前 binding/preflight。
- `capture-runbook.md` 只固定 one-element `-a` candidate boundary。official source 没有
  DAYU200 target-build source/binary mapping，不能证明 output mode；R1-R4 首次 target capture
  全部保守归入 `captureRemoteFile/deviceMutation`，不存在 readOnly Recipe case。
- `TASK-UD-PREFLIGHT-001` 只有在下列 production chain 完成后才可起草 ready：M1-006 source
  AC/done；M1-007 durable binding implementation/done + real-device composition；CHG-2026-015
  TASK-I15-001 done/verified；registered/adopted commandless
  `serverIdentityGeneration`；registered no-server-start initial discovery；registered/adopted
  `selectedDeviceAuthorizationBinding`；literal profile/entry/resource/adapter/receipt pins。
- existing server 必须在任何 HDC command 前由 host-wide supervisor 的 commandless platform
  observation 证明。absent、ownership/generation/endpoint/version unknown 或 drift 时 dispatch `0`；
  本 change 不启动、停止、重启、接管或配置 server。
- initial binding 由人类 physical selection 触发，production workflow 先 durable append
  `bindingCandidate`/`bindingConfirmed`；harness 只以 receipt ID + fixed positive revision 通过
  production loader/replay 取得 connect key。operator/default/stale/other-source path 均不可达。
- journaled confirmation/append-chain/dispatch authority 属于 external Core MAJOR，不是本 change 的
  contract/integration detail。必须由独立 `class:core` / `core_change_level:major` change 的具名
  `TASK-JAUTH-CORE-001` 同时交付 Requirement/AC delta、Core schemas/validator、macOS production
  store/trusted-entrypoint/dispatch gate、existing journal/checkpoint migration、crash/restart/recovery/
  rollback fault tests、language-neutral conformance vectors与三平台 disposition；该 task done、change
  verified/archived、`CORE-3.0.0` ratified且 CHG-008 retarget 前，offline verifier/preflight 都不得 ready。
- `TASK-UD-HWE-SEM-001` 必须在真机 task ready 前完成。未来 revision 先固定 binding receipt、
  server receipt、device-intent manifest、physical-target confirmation receipt 与 task-applicable confirmation
  manifest、confirmation-event receipt、journal-authorization receipt schemas，再实现
  `scripts/ui_dump_capture/verify_hardware_evidence.py` 与对应 test path，并钉死 source commit OID、
  file hashes、fixed Python 与 exact CLI；generic JSON schema 通过不能替代 cross-document semantic
  equality。当前 journal contract 没有与 Manifest confirmation/execution authority 关联的 task-applicable
  event 或 append-chain 字段，必须由上述 Core MAJOR/TASK-JAUTH-CORE-001 先补齐并形成 production
  evidence；trusted host entry point 的 confirmation event 必须 durable
  append 到同一 Session/Job 且 sequence/append chain 严格早于全部 related intents，时间戳/事后 evidence
  不能补权。verifier 必须重算 model/serial/identity/scope/intent/journal linkage，但只能检查 claimed
  operator/attestation 字段一致性；现实人类身份由维护者 PR review/merge 保证。
- `TASK-UD-CAP-MUT-001` 另需 dedicated non-sensitive fixture、registered typed window inventory、
  registered exact-path sidecar inventory operation、ownership、confirmation、receive/cleanup 与 fixed
  executable entrypoint。当前 remote-operation catalog 无该 operation；generic `verifyRemoteState`
  不足。任一缺失时 R1-R3/INV-1 dispatch `0`。
- R4 已拆为 `TASK-UD-CAP-R4-001`。它还依赖 Phase A R2 capture、approved R2 output family 和
  versioned typed component-tree extractor/receipt；十进制校验、first/lowest/manual selection 均不
  构成 provenance。任一缺失时 R4 request/process dispatch `0`。
- `TASK-UD-REDACTOR-001` 必须在 TASK-UD-001 ready 前完成并固定
  `scripts/ui_dump_redaction/{redact.py,record_privacy_review.py,import_reviewed_fixture.py,algorithm-v1.json,safe-literals-v1.txt,redaction-receipt.schema.json,privacy-review-receipt.schema.json}`、
  tests/README、commit OID/逐文件 hash、fixed Python、fixed `/usr/bin/git` version/hash/closed argv 与
  transform/finalizer/importer exact CLIs。transform receipt 不含 reviewer/decision且不可变；其 CLIs 必须证明 controlled
  root 位于全部 worktree 外，三个 data path/owner-only parents 均位于该 root 下且 pairwise distinct，
  raw read-only/link-count-one/pre-post identity 不变，output/receipt no-follow exclusive-create 且无
  symlink/hardlink/parent-race/worktree
  breakout；PATH poisoning、Git missing/hash/version/output drift 必须在读取 input 前失败。
- `TASK-UD-PRIVACY-REVIEW-001` 必须由人类在 transform 后检查 exact derived bytes，再用 pinned
  finalizer exclusive-create separate review receipt。finalizer 禁止 destination/Recipe/output-family
  override，只从 approved full commit OID 的 exact decision manifest blob/entry/canonical entry hash 读取 mapping；它自己记录
  `recordedAt`，强制 `completedAt < reviewedAt <= recordedAt` 与最多 300 秒 recording delay。只有 receipt
  引用 immutable transform receipt hash、same derived hash、decision commit/blob/entry/canonical entry hash、Recipe/output-
  family/raw-origin/three destinations 且 `decision=approvedForRepository` 才能交给 TASK-UD-001。
  TASK-UD-001 不读取 raw、运行 transform/finalizer或补写 receipts；它只执行 pinned importer，后者对
  external derived/receipts 各 no-follow 打开一次、保留 descriptors、单遍 hash+copy，并对 decision-derived
  三个 repo targets 通过 retained parents no-follow/exclusive-create，禁止 path reopen/manual copy/overwrite。
- 后续 output-family decision 只允许有 repo-safe synthetic/derived positive fixture 的文本 marker 或
  结构 parser family。raw byte-fingerprint/digest family 在本 change 中 unsupported/out of scope；若未来
  需要，须先由独立 approved change 固定复用 production stream→digest 路径的 privacy-safe conformance seam。
- mandatory SDD guard 固定使用
  `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`；Python `3.14.6`、PyYAML
  `6.0.3`、executable SHA-256
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。每次执行前重验；
  任一漂移即 blocked，不得回落默认 `python3` 或联网安装。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / method | Required binary evidence |
| --- | --- | --- | --- |
| capture-specific supervised preflight | `INT-UD-PREFLIGHT-001` | `TEST-INT-UD-PREFLIGHT-001` / human supervised preflight | already-PASS production HDC/device interfaces + stable existing-server snapshot + durable binding receipt/reopen + hardware evidence |
| UI Dump hardware evidence semantic linkage | `INT-UD-HWE-SEM-001` | `TEST-INT-UD-HWE-SEM-001` / offline cross-document fault injection | pinned source/test/OID/hashes/CLI + durable confirmation-event/journal ordering + schema-valid semantic mismatch rejection |
| UI Dump derived-golden privacy transform/import | `INT-UD-REDACTOR-001` | `TEST-INT-UD-REDACTOR-001` / offline adversarial/property contract | pinned transform/finalizer/importer + two receipt schemas/three CLIs + fixed Python/Git + source-descriptor/single-pass/exclusive-create contract |
| UI Dump human privacy review finalization | `INT-UD-PRIVACY-REVIEW-001` | `TEST-INT-UD-PRIVACY-REVIEW-001` / human exact-derived review + receipt-chain verification | approved decision commit/blob/entry hash + immutable transform receipt + separate approved review receipt + self-recorded time/three destinations |
| r3 conservative Phase A capture | `INT-UD-CAPTURE-MUT-001` | `TEST-INT-UD-CAPTURE-MUT-001` / human-authorized deviceMutation capture | R1-R3 exact arrays + binding/server/confirmation/registered inventory/cleanup + hardware evidence |
| r3 conservative Phase B R4 capture | `INT-UD-CAPTURE-R4-001` | `TEST-INT-UD-CAPTURE-R4-001` / extractor-bound human deviceMutation capture | R2 family/extractor receipt + R4 exact array + binding/server/inventory/cleanup + hardware evidence |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / derived golden review | decision-bound descriptor import + immutable receipts + derived hash/privacy/registry consistency |

The local prerequisite/capture cases do not close canonical Core evidence. Their applicable canonical
inputs and ownership are explicit:

| Task | Canonical Requirement → AC → Test inputs | Closure disposition |
| --- | --- | --- |
| `TASK-UD-PREFLIGHT-001` | `REQ-HDC-001` → `AC-HDC-001-01/02` → `TEST-AC-HDC-001-01/02`; `REQ-HDC-002` → `AC-HDC-002-01` → `TEST-AC-HDC-002-01`; `REQ-HDC-003` → `AC-HDC-003-01/02` → `TEST-AC-HDC-003-01/02`; `REQ-HDC-004` → `AC-HDC-004-01` → `TEST-AC-HDC-004-01`; `REQ-HDC-005` → `AC-HDC-005-01` → `TEST-AC-HDC-005-01`; `REQ-DEV-001` → `AC-DEV-001-01` → `TEST-AC-DEV-001-01`; `REQ-DEV-002` → `AC-DEV-002-01/02` → `TEST-AC-DEV-002-01/02`; `REQ-DEV-006` → `AC-DEV-006-01` → `TEST-AC-DEV-006-01` | read-only Safety/source dependencies; must already PASS under canonical evidence class/source owner; local realHardware receipt cannot substitute |
| `TASK-UD-CAP-MUT-001` | `REQ-DUMP-002/005/006/007/008` → `AC-DUMP-002-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs; capture enforces them but does not close parserGolden/contract/platform cases |
| `TASK-UD-CAP-R4-001` | `REQ-DUMP-003/005/006/007/008` → `AC-DUMP-003-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs; `AC-DUMP-003-01` closes only in `TASK-UD-001`; the capture task claims no canonical PASS |
| `TASK-UD-REDACTOR-001` | `REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01` | read-only privacy Safety input; synthetic redactor contract does not execute diagnostic export or close canonical platform evidence |
| `TASK-UD-PRIVACY-REVIEW-001` | `REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01` | read-only privacy Safety input; human derived review is change-local evidence and does not close canonical diagnostic-export platform evidence |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-PREFLIGHT-001 | human supervised existing-server + durable binding preflight | commandless registered supervisor observation proves existing endpoint/process-start identity/executable/version/ownership/generation and durable Job snapshot; human selection produces reopenable bindingCandidate/bindingConfirmed positive revision plus physical-target receipt; canonical model/serial/identity hash and validity match hardware/binding/intents; task-applicable confirmation event/append chain precedes every device intent; registered selected-device observation matches; harness has receipt-ID/fixed-revision loader only; mismatch paths dispatch 0 | blocked |
| INT-UD-HWE-SEM-001 | offline cross-document semantic fault injection | fixed source/test paths and hashes plus exact CLI validate physical model/serial/identity and unexpired confirmation scope across hardware/binding/intents/receipts, positive binding revision, stable server tuple, claimed-operator/attestation field equality, exact task/AC/step kinds, artifact hashes and raw-outside-git; confirmation event/session/job/payload/sequence/append-chain exactly match the durable journal receipt and precede every related intent; it makes no human-authenticity claim; backdated/late/broken-chain and other schema-valid semantic mismatches exit nonzero; no HDC/device/network | blocked |
| INT-UD-REDACTOR-001 | offline deterministic privacy-toolchain adversarial/property contract | fixed transform/finalizer/importer sources、algorithm/allowlist、two schemas/three CLIs、Python/Git identities；finalizer reads exact approved commit blob/entry hash and self-records time；importer uses retained no-follow source/parent/output descriptors, single-pass hash+copy and no-replace targets；PATH/Git/decision/time/content/path/symlink/race/mutation/partial-write cases fail closed without overwrite；no real raw/human review/HDC/device/network | blocked |
| INT-UD-PRIVACY-REVIEW-001 | human exact-derived privacy review and immutable receipt finalization | pinned transform produces immutable transform receipt; human review occurs afterward; finalizer derives Recipe/output-family/raw-origin/three destinations from approved decision commit/blob/entry hash, self-records `recordedAt`, and creates separate receipt with approved decision and bounded time ordering; future/stale/rejected/missing/mutated/mismatched chains block import; Agent raw/review/finalizer count 0 | blocked |
| INT-UD-CAPTURE-MUT-001 | human-authorized Phase A first target-build deviceMutation capture | no readOnly Recipe branch; R1-R3 exact one-element payloads materialize only from durable binding; physical model/serial/identity receipt and unexpired recomputed confirmation scope match all intents; confirmation event/append chain precedes every intent; same server generation verified before/after; dedicated fixture, typed window inventory, registered exact-path operation, separate raw origins, ownership evidence and exact cleanup; schema + pinned semantic verifier match receipts/intents/artifact hashes; destructive/Agent dispatch 0 | blocked |
| INT-UD-CAPTURE-R4-001 | extractor-bound human-authorized Phase B deviceMutation capture | approved R2 family/parser produces exactly one fixture-selected component through pinned extractor receipt; manual/regex-only/zero/multiple/stale/foreign source paths dispatch 0; R4 exact one-element payload and the same physical identity/unexpired confirmation whose journal event precedes its intent, binding/server/inventory/ownership/privacy/semantic gates pass; destructive/Agent dispatch 0 | blocked |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败；argv/request/recording-dispatch count 均为 0；合法 token positive control 不启动真实 HDC | blocked with TASK-UD-001 |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality；success 只来自登记且有 repo-safe positive fixture 的文本 marker/结构 parser family，不依退出码；raw byte-fingerprint/digest registration 被拒绝；错误样 exit-0 显式失败；未登记/marker 缺失为 unknownOutput；chunk/stream precedence 与无 shell composition 全覆盖；零真实 HDC | blocked with TASK-UD-001 |
| INT-UD-GOLDEN-001 | deterministic derived-golden registration review | prerequisites done；approved decision full commit/blob/entry/canonical entry hash binds Recipe/output family/raw origin/three destinations；review receipt binds immutable transform/derived hashes and bounded self-recorded time；pinned importer opens sources once/no-follow, single-pass hashes+copies, and exclusive-creates targets through retained parents；symlink/path swap/race/mutation/existing-target/partial-write negatives do not overwrite；TASK-UD-001 raw/transform/finalizer/manual-copy count 0；repo/profile/lock/Bundle hashes一致 | blocked with TASK-UD-001 |

## Real-hardware evidence gate

`TASK-UD-PREFLIGHT-001`、`TASK-UD-CAP-MUT-001` 和 `TASK-UD-CAP-R4-001` 各自必须提交其
evidence directory 下的
`hardware-evidence.json`，并只读消费
`openspec/contracts/hardware-evidence.schema.json`。每份记录必须包含 claimed operator、physical
target/serial、firmware、toolchain、transport、executedAt、该 task exact acceptance ID、actual
step kinds 与所有 repo artifact path/hash；claimed operator 的真实性由维护者 review attestation，
不是 verifier 的自动结论。

Generic schema 中 optional 的 `device.bindingRevision` 对本 change 是 mandatory semantic field：
必须为正数，并与 durable binding receipt、每个 device intent、capture manifest 相等。
`physicalTargetConfirmation` 与 `device.model`/`serial` 必须等于 physical-target receipt 的 canonical
identity，receipt identitySnapshotHash 必须等于 binding receipt 与每个 device intent。所有相关 intent
必须落在 physical receipt 与 accepted task-applicable confirmation 的有效时间窗内；capture intents
必须由 `kind=deviceMutation` entry 覆盖，且 recomputed scopeHash/related intent set 精确相等。
该 manifest entry 还必须对应同一 Session/Job production journal 中由 trusted host entry point durable
append 的 typed confirmation event；confirmation-event/journal-authorization receipts 必须闭合 event ID、
payload hash、strict sequence、previous/append hashes 与 journal head，且 confirmation sequence 严格小于
每个 related intent。`decidedAt` 较早但 event 较晚/缺失不能通过。
`toolchain.other` 必须记录 server endpoint/ownership/generation 与全部 receipt hashes。

固定 validator：`/opt/homebrew/anaconda3/bin/jsonschema` version `4.17.3`，executable SHA-256
`672885a523b0d538e4d734a9009d1678827facd27f2e634093e3bfc838392de7`。每个 evidence PR 运行：

```text
/opt/homebrew/anaconda3/bin/jsonschema -i <task-evidence>/hardware-evidence.json openspec/contracts/hardware-evidence.schema.json
```

随后按 `TASK-UD-HWE-SEM-001` 固定的 exact CLI 运行
`scripts/ui_dump_capture/verify_hardware_evidence.py`。该 task 必须已通过独立 contract evidence，且
readiness revision 必须钉死 source/test commit OID 与 SHA-256、input schema versions、fixed Python；
verifier 证明 claimed operator/attestation 字段跨文件一致、confirmation `actor=user`/accepted/time
window、physical model/serial/identity hash、positive binding revision、scopeHash/related intents、journal/
Session/Job/event/payload hash equality、gap-free append chain 与 pre-intent sequence、
acceptance IDs、artifact hashes 与 server tuple 一致，且 sensitive raw 不入 git。它不证明 claimed
operator 是真人；真实性只由维护者 PR review/merge attestation 保证。schema 或 semantic 任一失败
均不能形成 realHardware evidence/PASS。validator/verifier/schema/CLI 漂移即 blocked，不得联网安装。

## Gate

- r3 merge 后仍不得执行任何 capture/preflight。依赖 completion/readiness revision 合入之前，
  installed HDC、device、binding creation、server/device/network dispatch 均为 `0`。
- 任何 HDC command 之前先有 commandless `SP-0` existing-server receipt；不得用 `-v`、
  `checkserver` 或 discovery 试探 server 是否存在。absent/unknown 时停止，不隐式启动 server。
- 每条 HDC intent 绑定 exact durable CurrentDeviceBinding revision 和 Job toolchain server generation；
  dispatch 前 revision/generation drift 为 `0`，dispatch 后 drift 为 `outcomeUnknown` 且停止余下步骤。
- R1/R3 不能因 source routing 推断为 readOnly。首次 R1-R4 都按 deviceMutation scope、exact path
  inventory 与 owned cleanup 执行；若 later target evidence 支持 output-mode 决策，只能由独立
  approved revision 登记；R4 只能在 Phase A 与 R2 parser/extractor decision 后单独执行。
- 当前 catalog 没有 exact-path inventory operation，hardware semantic verifier 也不存在；二者完成
  registration/implementation/pinning 之前所有 Recipe dispatch `0`，不得用 raw command 或人工复核
  代替。
- typed confirmation journal event/append-chain contract 未合入，或 confirmation event 不严格早于全部
  related intents 时，所有相关 dispatch `0`；该 contract 只能来自 verified/archived Core MAJOR 与
  `TASK-JAUTH-CORE-001` production evidence，manifest、wall-clock 或事后 evidence 不得补发 authority。
- `TASK-UD-REDACTOR-001` 未 `done` 或任一 source/manifest/allowlist/schema/test/replay pin 漂移时，
  fixed Git identity/argv 漂移，或 raw/output/receipt file-identity/no-follow/exclusive-create/worktree-
  containment gate 未闭合时，
  privacy-review task 不得读取 raw，TASK-UD-001 不得 ready；golden task 不得修改该 toolchain。
- `TASK-UD-PRIVACY-REVIEW-001` 未由人类完成，或 separate review receipt missing/rejected/mutated/
  mismatched，decision commit/blob/entry/canonical entry hash/destination 不一致，或 review time future/stale/unbounded 时，
  TASK-UD-001 不得 ready；transform receipt 不得事后写入 reviewer/decision。
- pinned importer source/test/CLI/Git identity 任一未固定，或它不能从 retained source descriptors 单遍
  hash+copy、不能通过 retained destination parents no-follow/exclusive-create，TASK-UD-001 不得 ready；
  manual/path-reopen copy、existing-target overwrite 和调用者 destination override 永远禁止。
- TASK-UD-001 只有在 external Core MAJOR、preflight/verifier/redactor/privacy-review/两阶段 capture task
  `done`、每个拟支持 Recipe 有真实成功 provenance，
  且后续 approved decision/readiness revision 固定 exact argv 与 success/failure/unknown family 后
  才可从 `blocked` 起草为 `ready`。fake 只能验证已批准规则，不能定义规则或证明目标 build。
- raw byte-fingerprint/digest output family 不得在本 change 登记；干净 checkout 的 contract tests 必须
  对每个获批文本 marker/结构 parser family 使用 repo-safe synthetic/derived fixture 经 exact production
  semantic-evaluator path 正向覆盖。
- capture raw 只存在 repo 外 `0o700` controlled root；derived golden 必须通过
  `capture-runbook.md` 的 deterministic fail-closed chain；任一 unclassified token/line 或隐私复核
  失败都不得提交 fixture。
- mandatory SDD guard 先重验固定 interpreter path/version/hash 与 `import yaml`，再以
  `ARKDECK_PYTHON=<fixed-path> scripts/check-sdd.sh` 执行；不得联网安装或默认回落。
- M0B/source/public documentation 都只可作为设计输入，不构成 current binding、server
  generation、Recipe output mode/success、compatibility、conformance 或 hardware/support/release
  claim；`TASK-M1-006` 保持 blocked/非 done。
