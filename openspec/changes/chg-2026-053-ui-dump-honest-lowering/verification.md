# Verification — CHG-2026-053

> Change:CHG-2026-053-ui-dump-honest-lowering@r2
> Status:partial # r1:UDR-AC-1..3 passed;r2:UDR-AC-5..8 pending(本 PR 是
> 拆分/批准载体,结论由实现 PR 写入)。原 r1 状态行如下:
> 2026-07-30 UDR-AC-1..3 随实现 PR 通过;UDR-AC-4 如实保持
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

## UDR-AC-5 dumpLayout 真实 argv(r2)

- 方法:contract 测试断言 `capture-ui-tree` 步骤经 provider lowering 产出的
  **完整 argv** 为 `["-t", <connectKey>, "shell", "uitest", "dumpLayout", "-p",
  <provider-owned remote path>]` —— 逐 token,**不含 `-w`、不含 `-d`**
  (2026-07-31 真机实测形态);远端路径必须是 provider 自铸的 owned path,
  调用方无法提供;缺 connectKey 时 fail closed。
- Evidence:实现 PR 内测试 + 全量套件结果。
- 结论:pending。

## UDR-AC-6 effect 随输入升级,且未请求时逐字节不变(r2)

- 方法:(a) 不带 `uiComponentTree` 的请求,其 materialized plan effect、
  授权路径与选中步骤集与 r2 之前**完全相同**(断言计划 digest 不因本次 catalog
  变更而改变语义:E0 + `defaultReadOnly`,三个新步骤不被选中);
  (b) 带 `uiComponentTree: true` 时 effect 升为 `deviceMutation`,走既有
  capability 路径;缺授权时**零 dispatch**。
- Evidence:实现 PR 内测试。
- 结论:pending。

## UDR-AC-7 组件树产物走脱敏发布,且收不到即记 missing(r2)

- 方法:(a) `ui-tree.json` 由**接收到的字节**经会脱敏的 `publish` 路径发布,
  断言 `RuntimeArtifactStore.publishFile` 对 `application/json` 仍然拒绝
  (即不得复用 D4 的 file-backed 路径);(b) 接收腿没有落地文件时,
  `ui-tree.json` 记 `missing` 且带原因,绝不发布 `DumpLayout saved to:` 这类
  状态行冒充产物;(c) 超预算按既有 D4 语义 fail closed。
- Evidence:实现 PR 内测试。
- 结论:pending。

## UDR-AC-8 真机端到端(r2,pending-hardware)

- 方法:已接管设备上一次 `capture.diagnostics@1` 带 `uiComponentTree: true`
  的 Agent 执行:`ui-tree.json` 发布且可解析为 `{attributes, children}` 树、
  节点数 > 1、远端临时文件被清理、人工 HDC 命令为 0;窗口记录写入
  `evidence/runs/TASK-UDR-002/`。
- 说明:命令面已于 2026-07-31 实测为 `[R]`(见 proposal r2),**但 ArkDeck 的
  lowering 与端到端未验证**;按 UDR-AC-4 先例,该 AC 保持 pending-hardware 且
  不阻塞任务 done,不得以命令面的 `[R]` 冒充实现已验证。
- 结论:pending。
