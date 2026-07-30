# TASK-UDR-001 run r1(2026-07-30,host 实现与 contract 验证)

分类:real host execution(全部命令在本机真实运行);零设备命令、零 dispatch。

## 做了什么

- `diagnostics-stdout.yaml` + `workflow-step.schema.json` 同步新增
  `windowInventory`(参数面 = byteBudget,与 componentTree 相同);
- `Catalog/operations/capture.diagnostics.v1.json` 的 `capture-ui-dump`
  actionRef `componentTree` → `windowInventory`;
  `catalog_gen generate.py --write` 重生成(digest
  `3455e050…` → `1ee1c1a68486f45f8406fd362770655eb9d5dc983e1da27a87235d95eeb01a94`);
- `WorkflowStep` validator、`RuntimeJobEngine.journalStep` 注册
  windowInventory;provider `captureAction` 映射 windowInventory →
  `.captureUIDump(.windowList)`;
- lowering:`.windowList` → `-t <connectKey> shell hidumper -s
  WindowManagerService -a -a`(CHG-2026-008 INV-1 真机验证形态);
  `.componentTree` 在 captureAction 与 lower 两处 fail closed(原因含
  windowId);
- 新增 `DeviceProviderArgvContractTests`(argv 逐 token 断言 + 两条
  componentTree 负例 + 步骤映射);修正既有 `-t` sweep 测试的 scope;
  发现自写 sweep 与 #798 的
  `testEveryDeviceScopedHDCPlanUsesDescriptorBoundTarget` 语义重复,按
  PRODUCT-LOOP §5 删除重复保留既有。

## 命令与结果

- `swift test`(Packages/ArkDeckKit,非 /private/tmp 检出):
  **702 tests / 1 skipped / 0 failures**;
- `scripts/check-sdd.sh`:**0 error / 0 warning / 114 acceptance IDs**;
- `catalog_gen generate.py --check`:**exit 0(零 drift)**;
- 首次 CI guard 红(实证):`catalog_gen/test_generate.py` 钉死 stdout
  action 引用集与 `Catalog/schema/operation.schema.json` 词表——三条 pin
  (observed step 映射、generated Swift 引用计数、schema 词表 lockstep)
  随本 PR 同步更新;复跑 `test_generate.py` **38 OK**、
  `test_check_sdd.py` **63 OK**;
- E0 只读发现(`hdc list targets -v`,host 级命令):一台 DAYU200 候选
  USB 可见、状态 `Offline`(设备侧信任未完成)→ UDR-AC-4 如实 pending。

## AC 结论

- UDR-AC-1 PASS;UDR-AC-2 PASS;UDR-AC-3 PASS(细节见 verification.md);
- UDR-AC-4 PENDING-HARDWARE(下一次已接管设备 E0 运行补记)。

## 偏差与遗留

- componentTree 深层 dump 需 windowId 契约修订后另行垂直交付(已在
  proposal Out of scope 登记);
- 旧 durable intent 若携 componentTree scope,恢复路径重新 lower 时将
  fail closed 而非重放伪命令——符合 §15,无补偿义务。
