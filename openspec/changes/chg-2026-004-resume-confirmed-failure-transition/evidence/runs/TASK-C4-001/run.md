# TASK-C4-001 run record — 2026-07-16

- Evidence class:`contract`（Swift unit/property + synthetic journal fixtures；非 realHardware）
- Change approval:PR #16 merge commit `d09c722ad54bfc73070de0b9dfe3758a34e48ec4`
- Base revision:`2c16a44c92a4de30c3108fe0cc8a666bcd26ffd3`
- Pinned baseline:`CORE-1.0.0`
- Candidate baseline:`CORE-2.0.0`（未 ratify）
- Scope:`REQ-JOB-001`、`POL-SAFETY-001`、`POL-RECOVERY-001`、
  `POL-WORKFLOW-001`；`AC-JOB-001-01…07`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)
- AJV CLI Draft 2020-12 mode，临时通过 `npx --yes ajv-cli` 执行

## Locked and produced inputs

| Input | SHA-256 |
| --- | --- |
| approved delta `specs/workflow-journal-recovery/spec.md` | `5c2aa384c794ac7236cc2722ef25bbb17c5768ea46e1cf0a59f01e5ac71065fd` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `JobStateMachine.swift` | `d904cefde3f99c890719c69e747f4ccf60f734ceca0e7060831923e9263e2cb0` |
| `JobStateMachineTests.swift` | `00f408c22bfca8dc25c801029803c0aec05a0744be6f8cc0104a03d9a623b6b1` |
| `fixtures/marker-to-finalizing.json` | `6f900e088d58fe07c5aecb75b260392133107779ea1af412174d45d9645e5ad0` |
| `fixtures/marker-to-waiting-for-recovery.json` | `6349c16a45bf1aaf964943827feaa8ed96f0fb0c7723fb9ed703420ff83f7d66` |

## Work completed

- Journal `stateTransitionPair` 同时加入
  `resumeAtConfirmedSafeBoundary → finalizing` 与
  `resumeAtConfirmedSafeBoundary → waitingForRecovery`，未新增 required field 或修改
  journal schema version。
- 新增 `ResumeMarkerSemanticValidator`：unknown identity 或任一 unknown outcome 优先
  选择 `waitingForRecovery`；仅 identity、outcomes 全 confirmed 且存在 failure 时选择
  `finalizing`；无 failure 的全 confirmed vector 才选择 mode-correct
  `running`/`planning`。
- marker evaluation 将 evidence 与 requested pair 一并校验；mismatch 记录
  `resumeMarkerEvidenceMismatch` invariant。旧的无 evidence generic failure/unknown
  event 在 marker 状态被拒绝，不能绕过 semantic guard。
- execute 与 plan-only destination set 都保留正常恢复出口并新增两个安全出口；marker
  仍不在普通 Workflow Step dispatch allowlist。
- 新增 journal 完整 event round-trip、old-graph reader rejection、destination exact set、
  semantic mismatch、normal resume mode 与二值 AC matrix 测试。

## Binary result — AC-JOB-001-07

| Mode | Vector | Exact result | Ordinary Step dispatch | Intermediate running/planning |
| --- | --- | --- | ---: | ---: |
| execute | C | marker → finalizing → failed | 0 | 0 |
| execute | U-I | marker → waitingForRecovery | 0 | 0 |
| execute | U-O | marker → waitingForRecovery | 0 | 0 |
| planOnly | C | marker → finalizing → failed | 0 | 0 |
| planOnly | U-I | marker → waitingForRecovery | 0 | 0 |
| planOnly | U-O | marker → waitingForRecovery | 0 | 0 |

每行分别尝试 host-only、read-only、deviceMutation、destructive 和 unknown-kind 普通
Step。前四类均由 marker dispatch guard 拒绝；unknown kind 在严格 decoder 阶段按
destructive/unsupported 拒绝，因此 external/device dispatch count 均为 0。

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint Sources/ArkDeckCore/JobStateMachine.swift Tests/ArkDeckCoreTests/JobStateMachineTests.swift` | passed；0 warning |
| `python3 -m json.tool openspec/contracts/journal-event.schema.json` | passed；JSON syntax valid |
| `npx --yes ajv-cli validate --spec=draft2020 --strict=false -s openspec/contracts/journal-event.schema.json -r openspec/contracts/workflow-step.schema.json -d '<TASK-C4-001 fixtures glob>'` | passed；两个完整 stateTransition fixtures 均 valid |
| `swift test --package-path Packages/ArkDeckKit` | passed；73 tests，0 failure，1 个既有 manual idle-sleep harness skipped |
| `scripts/check-sdd.sh` | passed；0 error，0 warning，110 acceptance IDs |

## Acceptance conclusion

| AC | Conclusion | Evidence |
| --- | --- | --- |
| AC-JOB-001-07 | passed | C/U-I/U-O 在两个 mode 的 direct path、journal pair、semantic mismatch、zero dispatch 和 zero fake execution-phase transition 全部二值通过 |
| AC-JOB-001-03/05 | passed | destructive outcome unknown 与 incomplete recovery gate 保持 waitingForRecovery，replay/dispatch count 0 |
| AC-JOB-001-01/02/04/06 | passed | planned/terminal/preflight failure/cancellation canonical regression tests 全部通过 |

## Compatibility, deviations, and residual risk

- 新 reader 对两个新 pair 的完整 fixtures 可解码并通过 Draft 2020-12 graph validation；
  synthetic old-graph reader set 对两个 pair 均按预期拒绝。未执行 journal rewrite 或
  downgrade。
- AJV 未加载可选 `ajv-formats` plugin，因此明确报告 `date-time` format assertion
  ignored；两个 fixtures 的 timestamp 均使用 ISO 8601 UTC，且本任务变更和 oracle 只
  涉及 `stateTransitionPair`。结构、pair membership 与 external schema reference 均已
  验证。
- npm 报告 `ajv-cli` 的传递依赖含 deprecated package；工具仅在用户明确批准后临时
  运行，未加入项目 dependency 或产物。
- 未执行真实设备、HDC、provider、网络或 destructive 操作；未修改 current spec、
  global acceptance registry、baseline 或 platform conformance。macOS 保持
  `notStarted`，Windows/Linux 保持 deferred/not started。
- TASK-C4-001 implementation evidence 已完成，但 change 不标记 verified，
  `CORE-2.0.0` 不在本 run ratify；两者仍等待 maintainer review 与 archive flow。
