# TASK-M1-001R run record — 2026-07-15

- Evidence class:`platform`（macOS native parser/contract tests；非 realHardware）
- Core baseline:`CORE-1.0.0`
- Authorization:PR #15 merge commit `4aa3053a8437127a7c6e2390e8072eedc457425a`
- Base revision:`d19680a831fdc19d45b85947c1a73e7b5f757848`
- Verification run:`2026-07-15 23:20 CST`
- Scope:`REQ-WF-001`、`REQ-WF-002`、`REQ-JOB-001`；`AC-WF-001-01`、`AC-WF-002-01`、`AC-JOB-001-02`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)

## Work completed

- Profile decoder 对根 Step 与所有 compensation descriptor 执行同一 `profile_exposable` 门禁；`stopRemoteCapture`、`restoreParameter`、`cleanupOwnedRemotePath` 嵌套声明均拒绝，trusted Core/Provider 路径仍接受并保留 Core minimum classification。
- 严格 JSON 前置扫描器在任何对象层级检测重复 member name；JSON string escape 解码后比较，不使用会先折叠字段的 `JSONSerialization`。
- Job transition 测试从锁定 `journal-event.schema.json` 解析全部 `stateTransitionPair`，与两个 mode 的 Swift 允许边 union 精确比较；另行验证 mode-exclusive state、终态无出边和非法边 invariant。

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint Sources/ArkDeckCore/JobStateMachine.swift Sources/ArkDeckCore/WorkflowStep.swift Tests/ArkDeckCoreTests/JobStateMachineTests.swift Tests/ArkDeckCoreTests/WorkflowStepContractTests.swift` | passed；0 warning |
| `swift test --package-path Packages/ArkDeckKit` | passed；68 tests，0 failure，1 个既有 manual idle-sleep harness skipped |
| `scripts/check-sdd.sh` | passed；0 error，0 warning，110 acceptance IDs |

首次在 filesystem sandbox 内执行 `swift test` 时，SwiftPM/Clang 因无权写入
`~/.cache/clang/ModuleCache` 而在 manifest 编译前退出；按 `AGENTS.md` 在 sandbox 外以
同一命令重跑后得到上表通过结果。该诊断尝试未进入测试执行，不计为 AC 失败。

## AC conclusion

| AC | Conclusion | Evidence |
| --- | --- | --- |
| AC-WF-001-01 | passed | 根/compensation exposure 和 duplicate JSON fixtures 均在 decoder 阶段拒绝；external/device dispatch count 为 0 |
| AC-WF-002-01 | passed | trusted compensation 的 effect/cancellation/binding 均不低于锁定 registry minimum |
| AC-JOB-001-02 | passed | contract pair union 精确相等；mode-exclusive、terminal 和 illegal-edge negative tests 通过 |

## Deviations and residual risk

- 未修改 accepted Core Requirement、AC、contract、baseline 或 `CHG-2026-004`；该 change 已由 PR #16 合入批准，但 `TASK-C4-001` 尚未执行，Review 4 冲突仍由原 `TASK-M1-001` blocker 单独跟踪。
- 未执行真实设备、HDC、网络或 destructive 操作；dispatch count 为 0。
- 本 run 不把 `TASK-M1-001R` 或 `TASK-M1-001` 标为 done/verified，不声称 change verified。
