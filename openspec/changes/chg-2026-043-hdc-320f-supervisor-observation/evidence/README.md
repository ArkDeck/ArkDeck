# Evidence

本目录在 proposal 阶段只声明 evidence 边界，不含 task run 或结果。

- `TASK-HSO-001` 完成时写入 `runs/TASK-HSO-001/run.md`。
- `TASK-HSO-002` 完成时写入 `runs/TASK-HSO-002/run.md`。
- 每份 run 必须记录 exact base/head/merge OID、执行命令、结果、逐 AC 结论、偏差与遗留
  风险。
- Agent/CI 不得执行 installed HDC 或访问真实设备；fake/system-observer contract 必须
  如实标为 contract evidence，不得记作 hardware/support/release evidence。
