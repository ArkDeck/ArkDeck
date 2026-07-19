# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r3
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan。r3 merge 本身不执行任何 task，且 merge 后
没有 real-device task 为 `ready`。`TASK-UD-PREFLIGHT-001`、`TASK-UD-HWE-SEM-001`、
`TASK-UD-CAP-MUT-001`、`TASK-UD-CAP-R4-001` 与 `TASK-UD-001` 均保持 `blocked`；任何
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
- `TASK-UD-HWE-SEM-001` 必须在真机 task ready 前完成。未来 revision 先固定 binding receipt、
  server receipt、device-intent manifest schemas，再实现
  `scripts/ui_dump_capture/verify_hardware_evidence.py` 与对应 test path，并钉死 source commit OID、
  file hashes、fixed Python 与 exact CLI；generic JSON schema 通过不能替代 cross-document semantic
  equality。
- `TASK-UD-CAP-MUT-001` 另需 dedicated non-sensitive fixture、registered typed window inventory、
  registered exact-path sidecar inventory operation、ownership、confirmation、receive/cleanup 与 fixed
  executable entrypoint。当前 remote-operation catalog 无该 operation；generic `verifyRemoteState`
  不足。任一缺失时 R1-R3/INV-1 dispatch `0`。
- R4 已拆为 `TASK-UD-CAP-R4-001`。它还依赖 Phase A R2 capture、approved R2 output family 和
  versioned typed component-tree extractor/receipt；十进制校验、first/lowest/manual selection 均不
  构成 provenance。任一缺失时 R4 request/process dispatch `0`。
- mandatory SDD guard 固定使用
  `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`；Python `3.14.6`、PyYAML
  `6.0.3`、executable SHA-256
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。每次执行前重验；
  任一漂移即 blocked，不得回落默认 `python3` 或联网安装。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / method | Required binary evidence |
| --- | --- | --- | --- |
| capture-specific supervised preflight | `INT-UD-PREFLIGHT-001` | `TEST-INT-UD-PREFLIGHT-001` / human supervised preflight | already-PASS production HDC/device interfaces + stable existing-server snapshot + durable binding receipt/reopen + hardware evidence |
| UI Dump hardware evidence semantic linkage | `INT-UD-HWE-SEM-001` | `TEST-INT-UD-HWE-SEM-001` / offline cross-document fault injection | pinned source/test/OID/hashes/CLI + schema-valid semantic mismatch rejection |
| r3 conservative Phase A capture | `INT-UD-CAPTURE-MUT-001` | `TEST-INT-UD-CAPTURE-MUT-001` / human-authorized deviceMutation capture | R1-R3 exact arrays + binding/server/confirmation/registered inventory/cleanup + hardware evidence |
| r3 conservative Phase B R4 capture | `INT-UD-CAPTURE-R4-001` | `TEST-INT-UD-CAPTURE-R4-001` / extractor-bound human deviceMutation capture | R2 family/extractor receipt + R4 exact array + binding/server/inventory/cleanup + hardware evidence |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / derived golden review | capture raw hashes + deterministic redaction receipt + derived hash/privacy/registry consistency |

The local preflight/capture cases do not close canonical Core evidence. Their applicable canonical
inputs and ownership are explicit:

| Task | Canonical Requirement → AC → Test inputs | Closure disposition |
| --- | --- | --- |
| `TASK-UD-PREFLIGHT-001` | `REQ-HDC-001` → `AC-HDC-001-01/02` → `TEST-AC-HDC-001-01/02`; `REQ-HDC-002` → `AC-HDC-002-01` → `TEST-AC-HDC-002-01`; `REQ-HDC-003` → `AC-HDC-003-01/02` → `TEST-AC-HDC-003-01/02`; `REQ-HDC-004` → `AC-HDC-004-01` → `TEST-AC-HDC-004-01`; `REQ-HDC-005` → `AC-HDC-005-01` → `TEST-AC-HDC-005-01`; `REQ-DEV-001` → `AC-DEV-001-01` → `TEST-AC-DEV-001-01`; `REQ-DEV-002` → `AC-DEV-002-01/02` → `TEST-AC-DEV-002-01/02`; `REQ-DEV-006` → `AC-DEV-006-01` → `TEST-AC-DEV-006-01` | read-only Safety/source dependencies; must already PASS under canonical evidence class/source owner; local realHardware receipt cannot substitute |
| `TASK-UD-CAP-MUT-001` | `REQ-DUMP-002/005/006/007/008` → `AC-DUMP-002-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs; capture enforces them but does not close parserGolden/contract/platform cases |
| `TASK-UD-CAP-R4-001` | `REQ-DUMP-003/005/006/007/008` → `AC-DUMP-003-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs; `AC-DUMP-003-01` closes only in `TASK-UD-001`; the capture task claims no canonical PASS |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-PREFLIGHT-001 | human supervised existing-server + durable binding preflight | commandless registered supervisor observation proves existing endpoint/process-start identity/executable/version/ownership/generation and durable Job snapshot; human selection produces reopenable bindingCandidate/bindingConfirmed positive revision; registered selected-device observation matches; harness has receipt-ID/fixed-revision loader only; mismatch paths dispatch 0; schema-valid hardware evidence records same binding revision and server tuple | blocked |
| INT-UD-HWE-SEM-001 | offline cross-document semantic fault injection | fixed source/test paths and hashes plus exact CLI validate positive binding revision equality across hardware/binding/intents, stable server tuple, human operator, exact task/AC/step kinds, artifact hashes and raw-outside-git; schema-valid semantic mismatches exit nonzero; no HDC/device/network | blocked |
| INT-UD-CAPTURE-MUT-001 | human-authorized Phase A first target-build deviceMutation capture | no readOnly Recipe branch; R1-R3 exact one-element payloads materialize only from durable binding; same server generation verified before/after; dedicated fixture, typed window inventory, registered exact-path operation, separate raw origins, ownership evidence and exact cleanup; schema + pinned semantic verifier match binding/server/intents/artifact hashes; destructive/Agent dispatch 0 | blocked |
| INT-UD-CAPTURE-R4-001 | extractor-bound human-authorized Phase B deviceMutation capture | approved R2 family/parser produces exactly one fixture-selected component through pinned extractor receipt; manual/regex-only/zero/multiple/stale/foreign source paths dispatch 0; R4 exact one-element payload and the same binding/server/inventory/ownership/privacy/semantic gates pass; destructive/Agent dispatch 0 | blocked |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败；argv/request/recording-dispatch count 均为 0；合法 token positive control 不启动真实 HDC | blocked with TASK-UD-001 |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality；success 只来自登记 output family，不依退出码；错误样 exit-0 显式失败；未登记/marker 缺失为 unknownOutput；chunk/stream precedence 与无 shell composition 全覆盖；零真实 HDC | blocked with TASK-UD-001 |
| INT-UD-GOLDEN-001 | deterministic derived-golden registration review | controlled raw hashes 与 capture manifest 一致且 raw 不入 git；`uidump-derived-redaction-v1` replay 产生登记 derived hash，receipt 固定 algorithm/source/allowlist/raw/derived hash、replacement counts 与 human privacy review；repo 无 sensitive literal；`.gitattributes`、profile/lock、registry 和 Bundle resource 一致；不声称 raw/derived equality 或 compatibility | blocked with TASK-UD-001 |

## Real-hardware evidence gate

`TASK-UD-PREFLIGHT-001`、`TASK-UD-CAP-MUT-001` 和 `TASK-UD-CAP-R4-001` 各自必须提交其
evidence directory 下的
`hardware-evidence.json`，并只读消费
`openspec/contracts/hardware-evidence.schema.json`。每份记录必须包含 human operator、physical
target/serial、firmware、toolchain、transport、executedAt、该 task exact acceptance ID、actual
step kinds 与所有 repo artifact path/hash。

Generic schema 中 optional 的 `device.bindingRevision` 对本 change 是 mandatory semantic field：
必须为正数，并与 durable binding receipt、每个 device intent、capture manifest 相等。
`toolchain.other` 必须记录 server endpoint/ownership/generation 与 binding/server receipt hashes。

固定 validator：`/opt/homebrew/anaconda3/bin/jsonschema` version `4.17.3`，executable SHA-256
`672885a523b0d538e4d734a9009d1678827facd27f2e634093e3bfc838392de7`。每个 evidence PR 运行：

```text
/opt/homebrew/anaconda3/bin/jsonschema -i <task-evidence>/hardware-evidence.json openspec/contracts/hardware-evidence.schema.json
```

随后按 `TASK-UD-HWE-SEM-001` 固定的 exact CLI 运行
`scripts/ui_dump_capture/verify_hardware_evidence.py`。该 task 必须已通过独立 contract evidence，且
readiness revision 必须钉死 source/test commit OID 与 SHA-256、input schema versions、fixed Python；
verifier 证明 operator 不是 Agent、positive binding revision equality、acceptance IDs exact、artifact
hashes resolve、server tuple matches 且 sensitive raw 不入 git。schema 或 semantic 任一失败均不能
形成 realHardware evidence/PASS。validator/verifier/schema/CLI 漂移即 blocked，不得联网安装。

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
- TASK-UD-001 只有在 preflight/verifier/两阶段 capture task `done`、每个拟支持 Recipe 有真实成功 provenance，
  且后续 approved decision/readiness revision 固定 exact argv 与 success/failure/unknown family 后
  才可从 `blocked` 起草为 `ready`。fake 只能验证已批准规则，不能定义规则或证明目标 build。
- capture raw 只存在 repo 外 `0o700` controlled root；derived golden 必须通过
  `capture-runbook.md` 的 deterministic fail-closed chain；任一 unclassified token/line 或隐私复核
  失败都不得提交 fixture。
- mandatory SDD guard 先重验固定 interpreter path/version/hash 与 `import yaml`，再以
  `ARKDECK_PYTHON=<fixed-path> scripts/check-sdd.sh` 执行；不得联网安装或默认回落。
- M0B/source/public documentation 都只可作为设计输入，不构成 current binding、server
  generation、Recipe output mode/success、compatibility、conformance 或 hardware/support/release
  claim；`TASK-M1-006` 保持 blocked/非 done。
