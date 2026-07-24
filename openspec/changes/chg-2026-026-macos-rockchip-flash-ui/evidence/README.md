# CHG-2026-026 Evidence

本 change 已由 PR #298 合入 `main` 后成为 `approved`；PR #440 合入 r2 后，
`TASK-RKFUI-001` 与 `TASK-RKFUI-001A` 为 `ready`。PR #452 已合入 r3 的
OpenHarmony `7.0.0.33` exact repin。001A 的首个 r3 implementation preflight 因 Codex
子进程的全量 `ps` 不可见外部 HDC server 而在 E1 前 fail closed；本 implementation
修正为先从 loopback listener 发现 PID，再定向核验进程与 executable。PR #460 已合入该
guarded probe；后续 E0-only capability preflight 又发现真实 `ld` 为 CRLF，并有一个
Maskrom candidate 与 HDC target 同时存在，因此 r4 继续在 E1 前 fail closed。

已有 evidence：

```text
evidence/runs/TASK-RKFUI-001/run.md
evidence/runs/TASK-RKFUI-001/sanitized-e0-receipt.json
evidence/runs/TASK-RKFUI-001/diagnostic-alignment-2026-07-22.md
evidence/runs/TASK-RKFUI-001/review-nits-2026-07-22.md
evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md
evidence/runs/TASK-RKFUI-001/e0-preflight-2026-07-24.md
evidence/runs/TASK-RKFUI-001/clean-discovery-repin-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-preflight-firmware-drift-2026-07-24.json
evidence/runs/TASK-RKFUI-001A/blocked-preflight-server-discovery-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-preflight-server-discovery-2026-07-24.json
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-crlf-maskrom-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-crlf-maskrom-2026-07-24.json
```

未来 run 位置：

```text
evidence/runs/TASK-RKFUI-002/
evidence/runs/TASK-RKFUI-003/
evidence/runs/TASK-RKFUI-004/
```

BlueTool 静态分析是 proposal 输入，记录在 change 根目录 `bluetool-analysis.md`；它不是
ArkDeck platform/realHardware 验收，且未执行任何真实设备命令。

`TASK-RKFUI-001` 当前 run 如实为 `blocked`：contract 定向测试通过，但全量 suite 发现
package-boundary 测试表与已批准设计/Package 依赖不一致，所需测试文件不在任务 allowed
paths；signed Sandbox E0 又在 child launch 前因所选工具带 quarantine fail closed。
该 run 不构成 RockUSB direct-access PASS、真机支持或后续 execute readiness。

`TASK-RKFUI-001A` firmware-drift preflight 只读确认目标 serial、HDC/server 与 clean
`rkdeveloptool` pins 命中，但当前设备报告 OpenHarmony `7.0.0.33`，不同于 PR #440
批准的 `7.0.0.34`。该 run 的 E1/destructive dispatch 均为 0、`maxRuns = 1` 未消费，
不构成 Loader capability evidence；PR #452 随后批准了 r3 repin。

r3 implementation 的 server-discovery preflight 同样在 E1 前关闭：HDC listener
仍为 pre-existing external same-UID pinned executable，但 Codex Python 子进程的全量
`ps` 未返回该外部进程。独立只读复核证明 `lsof` listener discovery 加定向 `ps -p`
可稳定得到同一 PID/UID/command/executable，因此 harness 已改用该闭包并增加 host-only
测试。该 preflight 的 E1/destructive dispatch 与 usage reservation 仍全为 0；它不是
capability verdict，未在本 PR 内重试设备入口。

PR #460 merge 后，两次 E1 start request 均被执行环境在 process start 前拒绝，因为仓内
尚无维护者已接受的逐设备 typed capability evidence；设备 command、intent、binding 与
usage reservation 均未发生。随后独立 E0-only preflight 命中 exact HDC/firmware/tool
pins，但 `rkdeveloptool ld` 的真实 stdout 为 52-byte homogeneous CRLF，现行 LF-only
parser 以 `unexpectedCarriageReturn` 阻断。diagnostic-only byte inspection 显示一个
`0x2207:0x5000 Maskrom` candidate，而 pinned HDC target 同时 online；两者物理关联
unknown。CRLF 修复不能隐藏或放行该 candidate。该 run 的 E1/E2/destructive 与 usage
reservation 全为 0，不构成 capability evidence。
