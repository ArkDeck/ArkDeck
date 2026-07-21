# CHG-2026-014 Design — fail-closed legacy consolidation

> Status:candidate;仅在 proposal 经维护者批准后可作为 TASK-RLC-001 readiness 输入。

## Context and constraints

- Core baseline：`CORE-2.0.0`；不修改 Core/spec/contract/AC。
- Source implementation 只以 proposal 列出的完整 commit OID 定位。
- 远程 host 可能持续锁屏；任务执行面必须完全 headless，不尝试改变系统授权。
- 原 Task 的验证债保留在原 change，consolidation 不拥有或关闭它们。

## Two-axis model without a new status

本 change 不新增 Task status。它把两个结论分开记录：

| 结论 | 权威位置 | 含义 |
| --- | --- | --- |
| source Task `ready`/`blocked`（consolidation 不得改为 `done`） | 原 change `tasks.md` | 原 Requirement/AC 尚未全部验证；状态变化仍走独立 status PR |
| `TASK-RLC-001 done` | 本 change `tasks.md` | 固定 bytes 已完成来源审计、fail-closed 集成和 headless 回归 |

因此 `TASK-RLC-001 done` 永不向原 Task 传播 `done`，也不能作为原 AC evidence。consumer
若只依赖编译接口，可在自己的独立 revision 中显式引用 consolidation；若依赖行为/证据，
仍必须依赖原 Task done。

## Import and provenance flow

```text
fixed source OID
  -> path/diff inventory
  -> legacy-import-manifest.md
  -> fail-closed reachability review
  -> headless build/contract/fault tests
  -> one TASK-RLC-001 implementation PR
  -> original tasks remain non-done; a separate governance PR may add the consolidation reference
```

manifest 每个输入至少记录：source Task/change、完整 OID、parent/base、文件清单与 hash、
导入/已在 main/拒绝三态、public/runtime reachability、关联未关闭 AC、验证命令、偏差与
revert commit。branch 名只能作为诊断字段，不能作为来源身份。

## Fail-closed integration boundary

- HDC：App/Workflows 不得直接构造 argv 或获得未经 durable intent/confirmation 的 dispatch
  authority；external/unknown server 的自动 lifecycle/subserver/device-migration count 恒为 0。
- Process：descriptor/inode/hash/intent 不一致时 child launch count 为 0。
- PD decoder：保持 fd-only、零 path fallback；collector 在锁屏环境不运行，旧 blocked
  evidence 不重判。
- 所有真实设备、真实 HDC、非 loopback、GUI automation、NSOpenPanel 和 Developer Mode
  操作在本任务中结构性不可达。

若遗留实现无法在不改变 Core/AC 的前提下满足上述边界，该文件/模块标为 `rejected`，留在
source commit，不得为了“全部合入”而放宽 gate。

## Consumer dependency rule

consumer task revision 必须提供逐项表格：

| Consumer deliverable | 使用的 consolidated interface | 是否需要 source AC | 结论 |
| --- | --- | --- | --- |
| — | — | yes/no | may proceed / remains blocked |

任何 `yes` 行使 consumer 保持 blocked。`no` 行还必须证明无 device mutation、无 release/
support claim，且自己的 verification plan 可在当前环境二值执行。CHG-2026-014 不直接修改
任何 consumer dependency。

## Alternatives rejected

- 把原 Task 直接标为 done：缺 evidence，违反 POL-VERIFY-001。
- 新增 `legacyDone`/`merged` 状态：需要全局治理与 CI 语义变更，超出本 change。
- 自动把全部 downstream dependency 改到 consolidation：可能绕过 safety/realHardware gate。
- 将锁屏或 Developer Mode failure 记为 waived：平台 evidence 仍缺失，不可豁免。
- 合并未提交 worktree：来源不可固定、不可复查。
