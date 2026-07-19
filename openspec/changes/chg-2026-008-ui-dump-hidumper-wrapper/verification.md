# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r3
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan。r3 merge 本身不执行任何 task。merge 后，
`TASK-UD-CAP-001` 是唯一 `ready` 的真机任务，只允许人类执行封闭的 stdout-only/readOnly
`INV-1/R1/R3`；`TASK-UD-CAP-MUT-001` 和 `TASK-UD-001` 保持 `blocked`。任何基于未批准
argv/output family、自造 fake/golden 或 blocked task dispatch 的既有 PASS 都无效。

## Readiness environment

- r3 必须先经维护者 review/merge。`TASK-RLC-001 done`、CHG-2026-014 verified 只提供 package
  bytes/interfaces provenance，不提供 M1-006 source AC；TASK-UD-001 的逐 deliverable consumer
  dependency 表还须在未来 readiness revision 复核且没有 `yes` 行。
- 当前 M0B manifest 只含 `hidumper --help` 和 `hidumper -ls`，不是四 Recipe capture。
  `capture-runbook.md` 已在任何新采集前固定唯一 one-element `-a` 候选矩阵和 output-mode/effect
  split。采集完成只证明命令/输出 provenance，不等于 Recipe success；success/failure/unknown
  family 只能由后续 approved decision revision 登记。
- `TASK-UD-CAP-001` 仅能执行 `INV-1/R1/R3`。其 harness implementation PR 必须先合入，且不含
  evidence/status；其后由人类在独立 evidence PR 中执行。R2/R4 不得出现在 harness allowlist、
  真实 dispatch 或该任务 evidence 中。
- `TASK-UD-CAP-MUT-001` 只有在独立 revision 固定 dedicated non-sensitive fixture、fresh
  confirmed binding、durable human deviceMutation confirmation、exact remote sidecar path、
  pre/post inventory、owned cleanup 和 R4 component provenance 后才能 ready；在此之前 R2/R4
  dispatch count 为 `0`。
- TASK-UD-001 的实现/验证环境为锁屏 macOS headless shell、Swift/SwiftPM、
  `xcrun swift-format`、仓库 fixture 与本地临时目录；禁止 installed HDC、真实设备、GUI/系统
  授权、非 loopback 网络与 device dispatch。
- mandatory SDD guard 固定使用
  `/Users/fuhanfeng/Dropbox/Code/Github/ArkDeck/.venv-sdd/bin/python`；Python `3.14.6`、PyYAML
  `6.0.3`、executable SHA-256
  `b502cb4c5b46b8d4192ec6bcb600ce8922f1afc396fcf646e8765c6eba74a0bf`。每次执行前重验；
  任一漂移即 blocked，不得回落默认 `python3` 或联网安装。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / canonical method | Required binary evidence |
| --- | --- | --- | --- |
| r3 stdout capture readiness | `INT-UD-CAPTURE-RO-001` | `TEST-INT-UD-CAPTURE-RO-001` / human target capture | fixed readOnly arrays + faithful external raw hashes + zero mutation |
| r3 mutation capture readiness | `INT-UD-CAPTURE-MUT-001` | `TEST-INT-UD-CAPTURE-MUT-001` / human-authorized deviceMutation capture | fixed mutation arrays + fixture/binding/confirmation/inventory/cleanup |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / derived golden review | capture raw hashes + deterministic redaction receipt + derived hash/privacy/registry consistency |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-CAPTURE-RO-001 | human-operated target capture of approved stdout-only candidates | merged harness exposes only exact `INV-1/R1/R3` arrays with one-element payload; fresh confirmed binding and fixed tool/target tuple; separate raw streams remain outside git and repo records whole-stream hashes/metadata; exit 0 alone is not success; unexpected sidecar/state difference stops as `outcomeUnknown`; R2/R4, deviceMutation and destructive dispatch counts all 0 | pending after r3 merge |
| INT-UD-CAPTURE-MUT-001 | human-authorized target capture of sidecar/UI-state candidates | only after a later readiness revision: exact R2/R4 arrays, dedicated non-sensitive fixture, fresh binding, durable confirmation, exact-path absence/pre/post inventory, separate stdout/sidecar origins, proven ownership and exact owned cleanup; raw remains outside git and destructive count is 0 | blocked |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败；argv/request/recording-dispatch count 均为 0；合法 token positive control 不启动真实 HDC | blocked with TASK-UD-001 |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality；success 只来自登记 output family，不依退出码；错误样 exit-0 显式失败；未登记/marker 缺失为 unknownOutput；chunk/stream precedence 与无 shell composition 全覆盖；零真实 HDC | blocked with TASK-UD-001 |
| INT-UD-GOLDEN-001 | deterministic derived-golden registration review | controlled raw hashes 与 capture manifest 一致且 raw 不入 git；`uidump-derived-redaction-v1` replay 产生登记 derived hash，receipt 固定 algorithm/source/allowlist/raw/derived hash、replacement counts 与 human privacy review；repo 无 sensitive literal；`.gitattributes`、profile/lock、registry 和 Bundle resource 一致；不声称 raw/derived equality 或 compatibility | blocked with TASK-UD-001 |

## Gate

- r3 merge 后只允许执行 `TASK-UD-CAP-001`。它必须按两 PR phase 完成：先合入 closed harness，
  后由人类执行并在独立 evidence/status PR 记录；Agent device dispatch 或 phase 混合使该 AC FAIL。
- stdout-only capture 中出现 unexpected sidecar/path marker 或 state difference 时，立即停止余下
  matrix、记录 `outcomeUnknown` 并进入 Safety review；不得事后将该行降级为 readOnly。
- `TASK-UD-CAP-MUT-001` 的任一 gate 未关闭时，R2/R4、fixture install/start/stop、remote
  inventory/receive/cleanup dispatch count 均为 `0`，不得起草 PASS/done。
- TASK-UD-001 只有在两个 capture task `done`、每个拟支持 Recipe 有真实成功 provenance，且后续
  approved decision/readiness revision 固定 exact argv 与 success/failure/unknown family 后才可
  从 `blocked` 起草为 `ready`。fake 只能验证已批准规则，不能定义规则或证明目标 build。
- capture raw 只存在 repo 外 `0o700` controlled root；仓库只允许 whole-stream hashes/metadata。
  derived golden 必须通过 `capture-runbook.md` 的 deterministic fail-closed chain；任一 unclassified
  token/line 或隐私复核失败都不得提交 fixture。
- mandatory SDD guard 先重验固定 interpreter 的 path/version/hash 与 `import yaml`，再以
  `ARKDECK_PYTHON=<fixed-path> scripts/check-sdd.sh` 执行；不得联网安装或默认回落。
- `TEST-AC-DUMP-003-01` 与两个 wrapper/golden change-local Test ID 必须来自同一 TASK-UD-001
  implementation revision。任一 invalid component case 产生 argv/request/dispatch，或 receipt/
  registry/profile/lock/Bundle resource path/hash 不一致、raw 入仓、privacy self-check 不通过，即
  fail closed。
- M0B/source/public documentation 都只可作为设计输入，不构成 Recipe success、compatibility、
  conformance、hardware/support/release claim；`TASK-M1-006` 保持 blocked/非 done。
