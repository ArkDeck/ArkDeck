# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r3
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan(经 2026-07-20 维护者裁剪决定收敛,
初稿见 PR 提交历史 `a613b76`)。r3 merge 本身不执行任何 task,merge 后没有 real-device
task 为 `ready`。`TASK-UD-CAP-MUT-001`、`TASK-UD-CAP-R4-001`、`TASK-UD-REDACTOR-001` 与
`TASK-UD-001` 均保持 `blocked`;任何 installed-HDC/device 执行或基于未批准 argv/output
family、自造 fake/golden 的既有 PASS 都无效。

## Readiness environment

- r3 必须先经维护者 review/merge。`TASK-RLC-001 done`、CHG-2026-014 verified 只提供
  package bytes/interfaces provenance,不提供 M1-006 source AC;TASK-UD-001 的逐
  deliverable consumer dependency 表还须在未来 readiness revision 复核且没有 `yes` 行。
- 当前 M0B manifest 只含 `hidumper --help` 和 `hidumper -ls`,不是四 Recipe capture。其
  旧 connect key 不得假设仍有效,必须在采集会话内经 `hdc list targets` 重新观察。
- `capture-runbook.md` 固定 one-element `-a` candidate boundary、人工 preflight
  (`HP-0..HP-2`)、exact-path 清单与结果判定规则。official source 没有 DAYU200
  target-build source/binary mapping,不能证明 output mode;R1-R4 首次 target capture
  全部保守归入 `captureRemoteFile/deviceMutation`,不存在 readOnly Recipe case。
- 采集授权模型 = M0B 先例:runbook + 人类维护者亲手执行 + 维护者对 evidence PR 的
  review/merge attestation。production supervisor/binding 栈、journal 授权链与 offline
  receipt verifier 均不是本 change 前置(JAUTH 候选项见 backlog)。
- `TASK-UD-CAP-MUT-001` 的 readiness PR 必须固定 dedicated non-sensitive fixture HAP
  tuple、字面 `INV-1` inventory 命令、唯一 exact remote sidecar path 与设备/时间窗;任一
  缺失时 R1-R3/`INV-1` dispatch `0`。
- R4 已拆为 `TASK-UD-CAP-R4-001`,另需 approved R2 output-family decision revision 记录
  选定 component token 及其依据;十进制校验、first/lowest/manual selection 均不构成
  provenance;任一缺失时 R4 dispatch `0`。
- `TASK-UD-REDACTOR-001` 必须在 TASK-UD-001 ready 前完成:固定
  `scripts/ui_dump_redaction/{redact.py,test_redact.py,algorithm-v1.json,safe-literals-v1.txt,redaction-receipt.schema.json,README.md}`,
  transform 确定性、unknown token fail closed、输出侧敏感终检、safe literals 逐项
  维护者批准;source hash 在 evidence 执行时记录。
- derived golden 的隐私复核载体 = TASK-UD-001 golden PR 的维护者逐字审读(merge =
  attestation);`TEST-INT-UD-GOLDEN-001` 负责 hash 链与敏感字面量扫描的机器侧闭环。
- 后续 output-family decision 只允许有 repo-safe synthetic/derived positive fixture 的
  文本 marker 或结构 parser family。raw byte-fingerprint/digest family 在本 change 中
  unsupported/out of scope;若未来需要,须先由独立 approved change 固定复用 production
  stream→digest 路径的 privacy-safe conformance seam。
- mandatory SDD guard 使用 `<ARKDECK_ROOT>/.venv-sdd/bin/python`(Python 3.14.6、PyYAML
  6.0.3);每次执行前 preflight `import yaml` 并在 run.md 记录实际 path/version/hash,
  不得回落默认 `python3` 或联网安装。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / method | Required binary evidence |
| --- | --- | --- | --- |
| r3 conservative Phase A capture | `INT-UD-CAPTURE-MUT-001` | `TEST-INT-UD-CAPTURE-MUT-001` / human runbook deviceMutation capture | R1-R3 exact arrays + HP preflight 记录 + exact-path 清单 + 分立 raw origin + hardware evidence |
| r3 conservative Phase B R4 capture | `INT-UD-CAPTURE-R4-001` | `TEST-INT-UD-CAPTURE-R4-001` / decision-bound human deviceMutation capture | R2 decision/token 记录 + R4 exact array + HP preflight + 清单/cleanup + hardware evidence |
| UI Dump derived-golden privacy transform | `INT-UD-REDACTOR-001` | `TEST-INT-UD-REDACTOR-001` / offline adversarial/property contract | deterministic transform + receipt hash 链 + 输出侧敏感终检 + synthetic 负例矩阵 |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / derived golden review | capture-manifest→receipt→bytes hash 链 + registry/profile/lock/Bundle 一致 + 敏感扫描零命中 |

local capture/redactor case 不关闭 canonical Core evidence,其 canonical 输入与 ownership:

| Task | Canonical Requirement → AC → Test inputs | Closure disposition |
| --- | --- | --- |
| `TASK-UD-CAP-MUT-001` | `REQ-DUMP-002/005/006/007/008` → `AC-DUMP-002-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;capture 遵守但不关闭 parserGolden/contract/platform cases |
| `TASK-UD-CAP-R4-001` | `REQ-DUMP-003/005/006/007/008` → `AC-DUMP-003-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;`AC-DUMP-003-01` 只在 `TASK-UD-001` 关闭;capture task 不认领 canonical PASS |
| `TASK-UD-REDACTOR-001` | `REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01` | read-only privacy Safety input;synthetic redactor contract 不执行 diagnostic export、不关闭 canonical platform evidence |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-CAPTURE-MUT-001 | human runbook Phase A first target-build deviceMutation capture | no readOnly Recipe branch;HP-0..HP-2 preflight 记录且恰一目标;每条命令显式 `-t`,connect key 只来自同会话 inventory;R1-R3 exact one-element payloads;exact-path pre/post 清单与 owned-only cleanup;stdout/stderr/sidecar 分立 raw origin 逐流 SHA-256;raw 全部留仓库外;hardware-evidence 过 schema 且 claimed operator 由维护者 review attest;destructive/Agent dispatch 0 | blocked |
| INT-UD-CAPTURE-R4-001 | decision-bound human Phase B deviceMutation capture | approved R2 decision 记录 exact component token/依据/R2 raw hash;manual/zero/ambiguous token 路径 dispatch 0;R4 exact one-element payload 与 Phase A 相同的 preflight/清单/cleanup/privacy gates;hardware-evidence 过 schema;destructive/Agent dispatch 0 | blocked |
| INT-UD-REDACTOR-001 | offline deterministic privacy-transform adversarial/property contract | 固定 transform source/algorithm manifest/safe-literal allowlist/receipt schema;expected-input-hash 不符拒绝;unknown/unclassified token fail closed;输出侧敏感终检命中即硬失败;receipt 记录完整 hash 链与 replay 命令;重复运行 byte-deterministic;synthetic 负例矩阵全过且不覆盖 raw、不产出可提交 derived;零真实 raw/HDC/device/network | blocked |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败;argv/request/recording-dispatch count 均为 0;合法 token positive control 不启动真实 HDC | blocked with TASK-UD-001 |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality;success 只来自登记且有 repo-safe positive fixture 的文本 marker/结构 parser family,不依退出码;raw byte-fingerprint/digest registration 被拒绝;错误样 exit-0 显式失败;未登记/marker 缺失为 unknownOutput;chunk/stream precedence 与无 shell composition 全覆盖;零真实 HDC | blocked with TASK-UD-001 |
| INT-UD-GOLDEN-001 | deterministic derived-golden registration review | 每个入仓 golden bytes SHA-256 = receipt derived hash;receipt raw hash = capture manifest whole-stream hash;algorithm/manifest/allowlist hash 与 REDACTOR evidence 一致;`.gitattributes` 先行;registry、profile/lock 与 Bundle.module path/hash 一致;敏感字面量扫描零命中;receipt 缺失/hash 断链/未审读 derived 一律 fail;TASK-UD-001 raw 访问 count 0 | blocked with TASK-UD-001 |

## Real-hardware evidence gate

`TASK-UD-CAP-MUT-001` 与 `TASK-UD-CAP-R4-001` 各自必须提交其 evidence directory 下的
`hardware-evidence.json`,并只读消费 `openspec/contracts/hardware-evidence.schema.json`
(version 2.0.0,provider none)。每份记录必须包含 claimed operator、physical
target/serial、firmware、toolchain、transport、executedAt、该 task exact acceptance ID、
actual step kinds 与所有 artifact path/hash。

evidence PR 必须运行 JSON-schema 校验并在 `run.md` 记录校验工具的 path/version(执行时
记录,不预钉 hash)。schema 校验只证明结构;claimed operator 与 run 叙述的真实性由
维护者对 evidence PR 的 review/merge attestation 保证——与本仓库其他 merge 相同的
信任根(先例 EVD-M0B-DAYU200-20260718-001)。schema 校验失败或 artifact hash 断链时
不构成 realHardware evidence/PASS。

## Gate

- r3 merge 后仍不得执行任何 capture。readiness PR 合入之前,installed HDC、device、
  server/device/network dispatch 均为 `0`。
- 任何设备命令前必须完成 `HP-0..HP-2` 并记录;恰一目标、显式 `-t`、无默认目标;批次前
  复查漂移即停。
- R1-R4 首次执行都按 deviceMutation scope、exact-path 清单与 owned cleanup 执行;若
  later target evidence 支持 output-mode 决策,只能由独立 approved revision 登记;R4 只
  能在 Phase A 与 R2 decision 后单独执行。
- `TASK-UD-REDACTOR-001` 未 `done`,或其 algorithm/manifest/allowlist/receipt schema 任一
  未固定时,不得生成 derived golden,TASK-UD-001 不得 ready;golden task 不得修改该
  toolchain。
- TASK-UD-001 只有在两个 capture task `done`、每个拟支持 Recipe 有真实输出记录、
  approved decision revision 固定 exact argv 与 success/failure/unknown family、REDACTOR
  done 后才可从 `blocked` 起草 `ready`。fake 只能验证已批准规则,不能定义规则或证明
  目标 build。
- raw byte-fingerprint/digest output family 不得在本 change 登记;干净 checkout 的
  contract tests 必须对每个获批文本 marker/结构 parser family 使用 repo-safe
  synthetic/derived fixture 经 exact production semantic-evaluator path 正向覆盖。
- capture raw 只存在仓库外 `0o700` controlled root;derived golden 必须通过
  `capture-runbook.md` 的 deterministic fail-closed chain;任一 unclassified token/line
  或隐私复核失败都不得提交 fixture。
- mandatory SDD guard 先 preflight 固定 interpreter,再以
  `ARKDECK_PYTHON=<fixed-path> scripts/check-sdd.sh` 执行;不得联网安装或默认回落。
- M0B/source/public documentation 都只可作为设计输入,不构成 current Recipe output
  mode/success、compatibility、conformance 或 hardware/support/release claim;
  `TASK-M1-006` 保持 blocked/非 done,本 change 不重判其任何 evidence。
