# TASK-M1-001 run record — 2026-07-15

- Evidence class: `platform`（macOS native Core contract/property tests；非 realHardware）
- Core baseline: `CORE-1.0.0`
- Base revision: `df9e0886caece81fd8b5d0f41cd304a8cb953e09`
- Scope: `REQ-WF-001`、`REQ-WF-002`、`REQ-JOB-001`、`REQ-JOB-003`、`REQ-JOB-004`；`AC-WF-001-01`、`AC-WF-002-01`、`AC-JOB-001-01`…`06`、`AC-JOB-003-01`、`AC-JOB-004-01`

## Environment

- macOS 26.5.2 (25F84), arm64
- Xcode 26.6 (17F113)
- Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, target `arm64-apple-macosx26.0`)
- Swift Package deployment target: macOS 14

## Locked inputs

| Input | SHA-256 |
| --- | --- |
| `openspec/specs/workflow-journal-recovery/spec.md` | `1dce0b474aedec0f4fba22bac7b15c0d65b45957a4bbf255cc5b9e2a4a7480b3` |
| `openspec/contracts/workflow-step.schema.json` | `624d61071070ec1f873a811307fe7eb39f7697c37a68ed3ef8fad774522d1688` |
| `openspec/contracts/workflow-step-registry.yaml` | `2ee47057b157a745f45d85f109735a9e10ea8cab3661cfa192043bbc7ac394f3` |
| `openspec/contracts/journal-event.schema.json` | `caefd7909d7f270251cefa76c9fcc49416e66ade8d8a66c2b20598043ff6e962` |
| `openspec/verification/acceptance-cases.yaml` | `df55c639b7ecd89ce86a38650dac4644d2d27da23633b3a874369fef2ce37f9e` |
| `openspec/verification/core-conformance.yaml` | `be5f9d2d13764904b3e6bda8c0f9f32a3ae519410a0a6908b2fb3aef693904eb` |

## Work completed

- 实现封闭的 41-kind `WorkflowStep` registry 与严格 decoder：未知 kind 以 destructive/unsupported 拒绝；拒绝未知字段、shell/argv/command surface、非法 typed arguments 与未知 catalog/action 配对。Profile 与 trusted Core/Provider 使用两个无默认来源的显式 decode 入口；Profile exposure 校验覆盖根 Step 和全部 compensation descriptor，trusted 路径仍可使用批准的内部 compensation。
- 在 `JSONDecoder` 前执行不构造对象的严格 JSON 扫描，对解码后的 member name 按对象作用域检测重复；覆盖顶层、arguments/parameters、数组内对象和 compensation descriptor。Unicode escape 等价名称按重复拒绝，大小写不同名称保持 JSON 语义上的不同，后续保留字检查仍大小写不敏感。
- Core minimum effect/cancellation/binding 只能保持或提高；`binding_exact` 与 `profile_exposable` 直接对照锁定 registry fail closed。
- 实现 execute/plan-only Job 状态机、五个不同终态、invariant violation 记录、受控 reconcile、outcomeUnknown 保留、普通/critical 取消指令与终态 dispatch 门禁。普通 Step 派发只允许在明确执行阶段；`waitingForRecovery`、`reconciling`、`resumeAtConfirmedSafeBoundary` 均拒绝派发。
- 状态机保存已授权 Step ID 及经 Core 提升后的 cancellation policy；取消事件只携 Step ID，缺失或不匹配均拒绝，调用方不能把 `criticalNonInterruptible` 降级为 `immediate`。
- 所有终态转换在状态机底层强制 `activeStep == nil`；cancellation safe boundary 是唯一会在终态转换中显式结束 active Step 的路径。`finalizationCompleted` 遇到 active `finalizeSession` 或其他 Step 时拒绝，必须先用 matching ID 完成；不会静默清除不匹配 Step。
- 实现按 terminal trigger 选择的 compensation unwind plan，以及原始失败与补偿失败分离的 finalization report；补偿失败独立触发 `needsAttention`。
- 测试直接读取锁定的 workflow-step schema/registry、journal state enum 与 `stateTransitionPair`；execute/planOnly 允许边的 union 与 contract 精确比较，不再维护完整的测试内 transition 字典。mode-exclusive、终态无出边和非法边 invariant 另行验证；recovery 测试实际调用 `authorizeDispatch`。
- 发现 `REQ-JOB-001` 与 journal contract 对 `resumeAtConfirmedSafeBoundary` confirmed-failure 边冲突后，停止该边的实现选择，创建 proposed Core change `CHG-2026-004-resume-confirmed-failure-transition`，并将本任务标为 blocked。

## Commands and results

| Command | Result |
| --- | --- |
| `swift format lint <TASK-M1-001 source/test files>` | passed；0 warning |
| `swift test --package-path Packages/ArkDeckKit` | passed；68 tests，0 failure，1 个既有 manual idle-sleep harness 按设计 skipped（不属于本任务） |
| `scripts/check-sdd.sh` | passed；0 error，0 warning，110 acceptance IDs |

## AC conclusion

| AC | Canonical method | Conclusion | Evidence |
| --- | --- | --- | --- |
| AC-WF-001-01 | `workflowSchemaContract` | passed | 未注册 host command、command-bearing options、根/嵌套非 profile-exposable kind 和任意层级 duplicate JSON member 均在 dispatch 前拒绝；escaped duplicate name 同样拒绝，测试 dispatch count 为 0 |
| AC-WF-002-01 | `effectLatticeProperty` | passed | 全部锁定 registry entry 的 minimum effect/cancellation/binding 与 YAML 精确一致；erase 错标 readOnly 后仍为 destructive；trusted 内部 compensation 保留 Core minimum classification |
| AC-JOB-001-01 | `stateMachineProperty` | passed | plan-only 完成终态为 planned，且不增加 hardware success count |
| AC-JOB-001-02 | `stateMachineProperty` | passed | Swift execute/planOnly 边集 union 直接与锁定 journal contract pair 精确比较；mode-exclusive state 不交叉接受，非法边记录 invariant violation；所有终态 `activeStep == nil` 且拒绝新 Step dispatch |
| AC-JOB-001-03 | `recoveryFaultInjection` | passed | missing destructive outcome 初始化只进入 waitingForRecovery；测试实际调用 `authorizeDispatch(flashPartition)` 并得到 `dispatchNotAllowedInState`，flash dispatch count 为 0 |
| AC-JOB-001-04 | `stateMachineProperty` | passed | confirmed preflight failure 精确走 `preflight → finalizing → failed` |
| AC-JOB-001-05 | `recoveryFaultInjection` | passed | restart-safe、安全边界、确定 outcome、confirmed binding 四项逐一缺失均回到 waitingForRecovery 且实际拒绝 destructive dispatch；waitingForRecovery/reconciling/resume marker 都拒绝普通 Workflow Step；四项齐备才恢复 running |
| AC-JOB-001-06 | `cancellationContract` | passed | execute/running Job 实际 authorize 一个 Core policy 为 immediate 的 Step；缺失/错误 ID 均不能取消，matching ID 精确走 cancelRequested/cancellingAtSafeBoundary/cancelled，产出 request 与 outcome/safe-boundary 持久化指令，终态 `activeStep == nil` |
| AC-JOB-003-01 | `criticalCancellationContract` | passed | flash 声明的低 cancellation 被 Core 提升并存入 active Step；按相同 Step ID 取消产出 wait-for-safe-boundary 与 must-not-force-terminate 指令，缺失/错误 ID 均拒绝；forced termination count 为 0 |
| AC-JOB-004-01 | `compensationFaultInjection` | passed | capture 原始失败与 restore 补偿失败同时保留，原始分类不被覆盖，`needsAttention == true` |

## Deviations and residual risk

- 本 evidence 证明已运行的 Core contract/property 测试，不声称 change verified、发布支持或真实硬件支持。journal/manifest 的实际 durable I/O 与 schema publication 仍由后续任务集成验证。
- `workflow-journal-recovery/spec.md` 与 `journal-event.schema.json` 对 `resumeAtConfirmedSafeBoundary --confirmed failure--> finalizing` 的允许性仍属权威冲突。`CHG-2026-004-resume-confirmed-failure-transition` 已由 PR #16 合入批准，但 `TASK-C4-001` 尚未执行；该 Core change 完成前，本 run 不声称“精确 Core 迁移图”，`TASK-M1-001` 保持 blocked。
- 未执行真实设备、HDC、网络或 destructive 操作；本任务 device/destructive dispatch count 恒为 0。

## TASK-M1-001R remediation addendum — 2026-07-15

- 授权：PR #15 merge commit `4aa3053a8437127a7c6e2390e8072eedc457425a`。
- 复审基线：`d19680a831fdc19d45b85947c1a73e7b5f757848`，Core baseline 仍为
  `CORE-1.0.0`。
- 非冲突修复复核：Profile 根 Step 与全部 compensation descriptor exposure 门禁、
  任意对象层级 duplicate JSON member 拒绝、Swift mode union 与锁定 journal pair union
  精确相等均通过。
- 复跑结果：四文件 `swift format lint` 通过；`swift test --package-path
  Packages/ArkDeckKit` 通过（68 tests，0 failure，1 skipped）；`scripts/check-sdd.sh`
  通过（0 error，0 warning，110 acceptance IDs）。
- 本补充不解除 `TASK-M1-001` blocker，不处理 Review 4，也不把 task/change 标为
  done/verified。
