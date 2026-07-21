# TASK-M1-001 CORE-2.0.0 closure run — 2026-07-16

- Evidence class:`contract`（macOS native Swift Core contract/property tests；非
  realHardware）
- Change approval:PR #14 merge commit
  `df9e0886caece81fd8b5d0f41cd304a8cb953e09`
- CORE-2.0.0 ratification:PR #21 merge commit
  `7e3998cd6977f757b210df95b75ecb5433c7f2cc`
- Ready revision:PR #22 merge commit
  `eb9b9dc64ab422a51a518066f70b728e9ff5ba24`
- Base revision:`eb9b9dc64ab422a51a518066f70b728e9ff5ba24`
- Verification run:`2026-07-16 09:01:32 CST (+0800)`
- Core baseline:`CORE-2.0.0`
- Scope:`REQ-WF-001`、`REQ-WF-002`、`REQ-JOB-001`；
  `AC-WF-001-01`、`AC-WF-002-01`、`AC-JOB-001-01…07`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`，target
  `arm64-apple-macosx26.0`)
- Swift Package deployment target:macOS 14
- Hardware required:no

## Locked inputs and implementation under test

| Input | SHA-256 |
| --- | --- |
| `openspec/specs/workflow-journal-recovery/spec.md` | `0d94128bd06292b1d9ae24a29353a1cbf5591b6c96cd560a139c37d42c357d25` |
| `openspec/contracts/workflow-step.schema.json` | `624d61071070ec1f873a811307fe7eb39f7697c37a68ed3ef8fad774522d1688` |
| `openspec/contracts/workflow-step-registry.yaml` | `2ee47057b157a745f45d85f109735a9e10ea8cab3661cfa192043bbc7ac394f3` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `openspec/verification/acceptance-cases.yaml` | `a8b4e9c0e9fd0bdeb369db18261a8be31324151a68fa710a30e29183b50a476d` |
| `openspec/verification/core-conformance.yaml` | `293cc22936c1079d434c52e23572b6f575c71715d98d32018cde4ecf0deba839` |
| `Packages/ArkDeckKit/Sources/ArkDeckCore/WorkflowStep.swift` | `db4fdbc25b69130bd70d26654d089bec653d30ef6edafb5cb05b972b6afde354` |
| `Packages/ArkDeckKit/Sources/ArkDeckCore/JobStateMachine.swift` | `d904cefde3f99c890719c69e747f4ccf60f734ceca0e7060831923e9263e2cb0` |
| `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/WorkflowStepContractTests.swift` | `c4ce53d9889a55d12cad979794d7b848291e107c93fbea76ed25a78eefec5085` |
| `Packages/ArkDeckKit/Tests/ArkDeckCoreTests/JobStateMachineTests.swift` | `00f408c22bfca8dc25c801029803c0aec05a0744be6f8cc0104a03d9a623b6b1` |

## Closure result

- 封闭的 41-kind `WorkflowStep` registry 与锁定 schema/registry 精确一致；未知
  kind 在 decoder 阶段按 destructive/unsupported 拒绝。Profile 不能暴露 raw
  command surface，也不能降低 effect、cancellation 或 binding minimum；根 Step 与
  compensation descriptor 使用同一 exposure gate。
- execute/plan-only 迁移图的 pair union 与锁定 journal contract 精确相等；五个终态
  无出边、拒绝 external-effect Step，非法边记录 invariant violation。
- 补偿按声明的 terminal trigger 逆序选择；补偿失败单独保留且不覆盖原始失败分类。
- CHG-2026-004 已进入 ratified CORE-2.0.0；Swift state machine、journal pair contract
  与 semantic validator 对 resume marker 的 confirmed/unknown 二值决策一致，旧
  authority-conflict blocker 已解除。

## Binary result — AC-JOB-001-07

| Mode | Vector | Exact result | Ordinary Step dispatch | Intermediate running/planning |
| --- | --- | --- | ---: | ---: |
| execute | confirmed | marker → finalizing → failed | 0 | 0 |
| execute | unknown identity | marker → waitingForRecovery | 0 | 0 |
| execute | unknown outcome | marker → waitingForRecovery | 0 | 0 |
| planOnly | confirmed | marker → finalizing → failed | 0 | 0 |
| planOnly | unknown identity | marker → waitingForRecovery | 0 | 0 |
| planOnly | unknown outcome | marker → waitingForRecovery | 0 | 0 |

`TEST-AC-JOB-001-07` 对每行尝试 host-only、read-only、deviceMutation、destructive
和 unknown-kind 普通 Step。前四类由 marker dispatch guard 拒绝；unknown kind 在
strict decoder 阶段按 destructive/unsupported 拒绝。Evidence/pair mismatch 记录
`resumeMarkerEvidenceMismatch` invariant；所有行均未伪造 `running`/`planning`。

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint <TASK-M1-001 source/test files>` | passed；0 warning |
| `swift test --package-path Packages/ArkDeckKit` | passed；73 tests，0 failure，1 个既有 manual idle-sleep observation harness 按设计 skipped（不属于本任务） |
| `scripts/check-sdd.sh` | passed；0 error，0 warning，111 acceptance IDs |

首次在 filesystem sandbox 内运行 SwiftPM 时，因用户级 clang module cache 不可写而在
manifest 编译前失败；随后按仓库工具环境约定在受控 sandbox 外执行同一命令并通过。
该环境重试未改变代码、测试 oracle 或外部系统状态。

## Acceptance conclusion

| AC | Canonical method | Conclusion | Evidence |
| --- | --- | --- | --- |
| AC-WF-001-01 | `workflowSchemaContract` | passed | 未注册 host command、command-bearing options、非 profile-exposable root/compensation kind 与任意对象层级 duplicate JSON member 均在 dispatch 前拒绝；external process dispatch count 为 0 |
| AC-WF-002-01 | `effectLatticeProperty` | passed | 全部锁定 registry entry 的 effect/cancellation/binding minimum 精确一致；erase 错标 readOnly 后仍为 destructive |
| AC-JOB-001-01 | `stateMachineProperty` | passed | plan-only 完成终态为 planned，hardware success count 不增加 |
| AC-JOB-001-02 | `stateMachineProperty` | passed | 五个终态拒绝回到 running 与新 external-effect Step；非法请求记录 invariant violation |
| AC-JOB-001-03 | `recoveryFaultInjection` | passed | missing destructive outcome 只进入 waitingForRecovery，replay/dispatch count 为 0 |
| AC-JOB-001-04 | `stateMachineProperty` | passed | confirmed preflight failure 精确走 preflight → finalizing → failed |
| AC-JOB-001-05 | `recoveryFaultInjection` | passed | 四项 resume gate 全部成立才到 marker 并回到 mode-correct execution phase；任一缺失回到 waitingForRecovery 且不派发未知 Step |
| AC-JOB-001-06 | `cancellationContract` | passed | matching active Step ID 精确走 cancelRequested → cancellingAtSafeBoundary → cancelled，并产生 request/outcome/safe-boundary 持久化指令 |
| AC-JOB-001-07 | `recoveryDecisionJournalStateMachineContract` | passed | 两个 mode 的 confirmed/unknown identity/unknown outcome 六行全部满足 direct path、journal pair、semantic mismatch rejection、zero dispatch 与 zero fake execution-phase transition |

## Deviations and residual risk

- 本 closure 证明 CORE-2.0.0 范围内的 pure Core contract/property behavior，不声称
  CHG-2026-002 整体 verified、macOS conformance、发布支持或真实硬件支持。
- journal/manifest durable I/O、platform ports、HDC/device binding 与 simulation 等
  M1 integration/platform evidence 仍由后续任务闭环。
- 未执行真实设备、HDC、Provider、网络或 destructive 操作；本 run 的
  device/destructive dispatch count 恒为 0。
- `TASK-M1-001` 的 `done` 状态是待维护者 review/merge 的起草结果；Agent 未自行批准
  task 或 change。
