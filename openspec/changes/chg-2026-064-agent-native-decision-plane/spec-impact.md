# Spec impact — CHG-2026-064

- **`openspec/specs/**` 九个正本**：零改动。实测（2026-08-18）`harness`/
  `HTASK`/task-plane 词汇在 specs 与 contracts 命中为 0——任务平面从未进入
  spec 正本，本 change 是纯收缩。
- **Catalog**：零 operation 增删改。`analyzer.extract-crash-signature@1`
  实现归属迁移，可观察契约与 digest 不变（AND-AC-1 钉住）。
- **`PRODUCT-LOOP.md` §6 GJ-5**：判据宿主重述以本 change proposal「GJ-5
  判据重述」节为准；PRODUCT-LOOP 文本不动（维护者签发文件），冲突按其 §2
  一行兼容注记规则处理。预算面逐项映射见同节表格——有界性不减，宿主换位。
- **CHG-2026-054 / CHG-2026-055**：两 change 已 done，归档与 evidence 只读
  留存、不改写。其交付中的执行面（`workspace.*`、workspace capability 主体、
  `analyzer.*`、`HumanActionRequired` 接线）全部保留；宿主面（循环、网关、
  记忆、Attempt、Evolution workspace 管理）由本 change 移除。HTP-INV-6
  （E2 一律人工、E1 只用维护者签发的 standing capability、不自签不续期不扩
  范围）与 HTP-INV-9（不 push/merge/绕过人工 review）对外部 agent 产出方
  **全程继续适用**。
- **CHG-2026-059 / CHG-2026-063**：同向不冲突——批准/执行分离的第三步；
  其「ArkDeck 不做 lowering」结论不受影响。
- **CHG-2026-061**：地位提升——`workspace.prepare-isolated-copy@1` 成为隔离
  工作区制备的唯一路线，并构成 TASK-AND-003 的开工前置（或维护者裁决接受
  能力回退）。
- **`AGENTS.md`**：零改动（实测 harness 命中 0）。「AI 只能提交已发布
  operation + typed inputs」的禁令面由约定收紧为结构事实。
