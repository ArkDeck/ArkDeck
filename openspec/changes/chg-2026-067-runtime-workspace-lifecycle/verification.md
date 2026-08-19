# Verification — CHG-2026-067

> Change:CHG-2026-067-runtime-workspace-lifecycle@r1
> Status: proposed；本文件不声称任何 merge 结论。各 AC 在 TASK-RWL-001 的
> 实现 PR 中取证并附 evidence（本机存量树为主要夹具，path-free）。

## Acceptance

- **RWL-AC-1**（血统收养正例）：一棵 baseRevision=B、经一条 applied 未
  reverted attempt 到 R 的树，daemon 重启后收养成功、派生 profile 注册、
  启动日志无 `:revision`。本机存量 `evo-360b54f8…`（B=`701c5bd9…`、
  R=`aed6966b…`）为生产实证对象。
- **RWL-AC-2**（篡改仍拒）：绕过产品路径直接改树内文件（测试夹具内模拟）
  后，测得 revision 无链可推导，收养保持具名 `:revision` 拒绝且零注册；
  revert 折叠与断链/多头矩阵由纯函数测试覆盖。
- **RWL-AC-3**（证词不可由 caller 提供）：`workspace.sweep-isolated-copies@1`
  的输入 schema 恰为 {retainLatestCount, minimumQuiescentSeconds, dryRun}；
  含证词/路径/ID 的请求在 admission 具名拒绝；证词随 durable typed action
  持久化，重放同一 action 不重算证词。
- **RWL-AC-4**（活跃与不可担保者保全）：存在非终态引用 job 的树、收养失败
  （metadata/scopes/revision）的树在清扫中 retained 并具名 disposition；
  负向断言其树字节不变。
- **RWL-AC-5**（dry-run 一致性）：同一存量上 `dryRun: true` 与随后的实扫
  逐树 disposition 一致；差异仅摧毁动作与 reclaimedBytes。
- **RWL-AC-6**（审计幸存）：每棵被摧毁的树留存 teardown 记录、
  `workspace.json` 与 attempt manifests；findings artifact path-free
  （host 绝对路径零出现，机械扫描取证）。
- **RWL-AC-7**（catalog 收敛）：generator 再生后 digest 前进恰一个
  operation；zero-drift 校验绿；全量 `swift test` 零失败；生产链
  `job.submit → dispatcher → manager` 端到端合约测试在位（AF-002）。
