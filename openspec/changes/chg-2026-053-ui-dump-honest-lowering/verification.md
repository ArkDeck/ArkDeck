# Verification — CHG-2026-053

> Change:CHG-2026-053-ui-dump-honest-lowering@r1
> Status:planned(实现 PR 内更新各 AC 结论;真机项如实保持 pending 直到
> 下一次已接管设备 E0 运行)

## UDR-AC-1 windowInventory 真实 argv

- 方法:contract 测试断言 `capture-ui-dump` 步骤经 provider lowering 产出的
  **完整 argv** 为 `["-t", <connectKey>, "shell", "hidumper", "-s",
  "WindowManagerService", "-a", "-a"]`(与 CHG-2026-008 真机验证的 INV-1
  形态逐 token 相等),缺 connectKey 时 fail closed。
- Evidence:实现 PR 内测试 + 全量套件结果。

## UDR-AC-2 componentTree fail closed

- 方法:负例测试断言 `captureAction` 对 `componentTree` actionRef 与
  `.captureUIDump(.componentTree)` lowering 均抛出机器可读拒绝(原因含
  windowId 契约缺失),零 dispatch;正例断言该路径不再从任何 catalog 步骤
  可达。
- Evidence:实现 PR 内测试。

## UDR-AC-3 契约/catalog/journal 三方一致

- 方法:`diagnostics-stdout.yaml`、重生成的
  `RuntimeOperationCatalogGenerated.swift`(digest 更新)、WorkflowStep
  validator 与 journalStep 参数表四处均注册 `windowInventory` 且零 drift;
  `scripts/check-sdd.sh` 与既有 catalog/WorkflowStep contract 套件全绿。
- Evidence:实现 PR 内测试 + check-sdd 输出。

## UDR-AC-4 真机复验(pending-hardware)

- 方法:下一次已接管 DAYU200 的 E0 `capture.diagnostics@1` 运行产出非空
  `ui-dump.json`,内容为真实窗口清单输出(非错误文本);结论补记入本文件与
  GJ-1 状态。
- Evidence:runtime job artifact(真实字节)+ run 记录。当前状态:pending
  (无设备窗口不阻塞 TASK-UDR-001 done;禁止以 fake/simulation 顶替)。
