# Spec impact — CHG-2026-063

- **AFD-0001**（transport 依赖策略）：修订——`arkforge-usb` 单 crate 内
  允许 IOKit FFI；三方依赖仍为零；其余 crate 维持无 unsafe/FFI。
- **architecture.md 9.2**（双半边）：不变。hdc 半边仍归 ArkDeck；变化仅在
  Rockchip 半边内部——vendor 子进程换成 arkforged 自身的 typed 端口。
- **architecture.md 14.1**（unknown 不重放）：不变；typed 端口消灭 stdout
  marker 判定后，unknown 的来源更少。
- **成熟度模型**：toolchain 身份新增原生种类；组合级 campaign 门照旧
  （AFA-AC-7 为新组合的验收 campaign）。
- **CHG-2026-059**：其"ArkDeck 不做 lowering"的结论不变并被强化——退役
  vendor 工具后 ArkDeck 连观察半边的工具依赖也归零。
