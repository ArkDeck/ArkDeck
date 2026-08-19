# Spec impact — CHG-2026-067

- **`openspec/specs/**` 九个正本**：零改动（本 change 全部落在 runtime 平面
  与 Catalog）。
- **Catalog**：新增恰一个 operation `workspace.sweep-isolated-copies@1`
  （hostOnly / binding none，形态对齐 `workspace.prepare-isolated-copy@1`）；
  既有 operation 零变化。
- **CHG-2026-061**：其 RIW-REQ-002「daemon 重启后收养同一 manifest 与字节」
  被本 change 补全到「含合法生命史的树」——之前只有未修补的树满足该承诺。
  061 的 manifest 不可变语义保持（血统来自 attempt 记录，不改 manifest）。
- **CHG-2026-064**：其 design.md §5 勘误第 1 条与 LaunchAgents README 操作者
  注记登记的两个遗留（GC 面、收养拒绝合法修补树）由本 change 关闭；064 的
  「决策平面不存在」断言不受影响——清扫是显式 typed job，不是自主循环。
- **`EvolutionWorkspaceGCDisposition` 封闭词表**：如需新增取值（如
  `unreferencedRetained`），实现 PR 同步其封闭形状测试；不复用语义不符的
  既有取值。
- **`AGENTS.md` / `PRODUCT-LOOP.md`**：零改动。
