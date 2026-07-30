# Verification — CHG-2026-053

> Change:CHG-2026-053-ui-dump-honest-lowering@r1
> Status:passed # 2026-07-30 UDR-AC-1..3 随实现 PR 通过;UDR-AC-4 如实保持
> pending-hardware(定义为不阻塞任务 done,见其节),待下一次已接管设备 E0
> 运行补记;维护者 review/merge 实现 PR 即确认

## UDR-AC-1 windowInventory 真实 argv

- 方法:contract 测试断言 `capture-ui-dump` 步骤经 provider lowering 产出的
  **完整 argv** 为 `["-t", <connectKey>, "shell", "hidumper", "-s",
  "WindowManagerService", "-a", "-a"]`(与 CHG-2026-008 真机验证的 INV-1
  形态逐 token 相等),缺 connectKey 时 fail closed。
- Evidence:实现 PR 内测试 + 全量套件结果。
- **结论(2026-07-30):PASS** —
  `DeviceProviderArgvContractTests.testWindowInventoryLowersToTheDeviceValidatedInventoryForm`
  逐 token 断言(含 timeout 30);缺 connectKey 负例由既有
  `DeviceProviderContractTests.testEveryDeviceScopedHDCPlanUsesDescriptorBoundTarget`
  全 action 覆盖。全量 702 tests / 1 skipped / 0 failures。

## UDR-AC-2 componentTree fail closed

- 方法:负例测试断言 `captureAction` 对 `componentTree` actionRef 与
  `.captureUIDump(.componentTree)` lowering 均抛出机器可读拒绝(原因含
  windowId 契约缺失),零 dispatch;正例断言该路径不再从任何 catalog 步骤
  可达。
- Evidence:实现 PR 内测试。
- **结论(2026-07-30):PASS** —
  `testComponentTreeActionRefIsRejectedBeforeAnyIntentExists` 与
  `testComponentTreeScopeHasNoHonestLoweringAndFailsClosed` 两负例断言拒绝
  原因含 windowId;`RuntimeOperationCatalogContractTests` 的 actionRef 全量
  枚举断言 componentTree 不再被任何步骤引用。

## UDR-AC-3 契约/catalog/journal 三方一致

- 方法:`diagnostics-stdout.yaml`、重生成的
  `RuntimeOperationCatalogGenerated.swift`(digest 更新)、WorkflowStep
  validator 与 journalStep 参数表四处均注册 `windowInventory` 且零 drift;
  `scripts/check-sdd.sh` 与既有 catalog/WorkflowStep contract 套件全绿。
- Evidence:实现 PR 内测试 + check-sdd 输出。
- **结论(2026-07-30):PASS** — `catalog_gen generate.py --check` exit 0
  (零 drift);catalog digest `3455e050…` → `1ee1c1a6…`;workflow-step
  JSON schema 与 Swift validator 同步新增 windowInventory 分支并有 parity
  断言;check-sdd 0 error / 0 warning / 114 acceptance IDs。

## UDR-AC-4 真机复验(pending-hardware)

- 方法:下一次已接管 DAYU200 的 E0 `capture.diagnostics@1` 运行产出非空
  `ui-dump.json`,内容为真实窗口清单输出(非错误文本);结论补记入本文件与
  GJ-1 状态。
- Evidence:runtime job artifact(真实字节)+ run 记录。当前状态:pending
  (无设备窗口不阻塞 TASK-UDR-001 done;禁止以 fake/simulation 顶替)。
- **结论(2026-07-30):PENDING-HARDWARE** — 实现当日 E0 只读发现见一台
  DAYU200 候选经 USB 可见但 `Offline`(设备侧信任握手未完成,属 §14 首次
  接入人工预算);未执行任何设备命令,零 dispatch。
