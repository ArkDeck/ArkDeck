# Run 记录落点 — CHG-2026-054

每个任务的 run 记录写入 `evidence/runs/TASK-HTP-00N/run-rN.md`,由该任务的实现 PR
同车提交:真实命令、退出码、artifact ID 与 hash、脱敏设备标识、executor 身份与按实际
effect 匹配的 authority reference。simulation/fake 结果必须如实标注,不得记为真机结果。
