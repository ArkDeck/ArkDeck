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
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-maskrom-still-present-2026-07-24.json
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-hdc-drift-maskrom-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-hdc-drift-maskrom-2026-07-24.json
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-rkdeveloptool-source-drift-2026-07-24.md
evidence/runs/TASK-RKFUI-001A/blocked-capability-preflight-rkdeveloptool-source-drift-2026-07-24.json
evidence/runs/TASK-RKFUI-001B/run.md
evidence/runs/TASK-RKFUI-001C/run.md
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

PR #464/#465 merge 后的新 E0-only preflight 证明 CRLF grammar remediation 已生效，且
DAYU200 serial/firmware、HDC/server 与 discovery tool pins 全部命中；但 exact `ld`
仍返回与前次相同的单个 `0x2207:0x5000 Maskrom` observation。由于 r4 要求
pre-existing RockUSB candidate count 为 0，本次在 original target、revision-1 binding、
typed capability evidence、intent、usage reservation 与 E1 前停止。该物理/身份 blocker
不能通过代码或治理 PR 消除；环境无预存 RockUSB candidate 后才可重新进行 E0 preflight。

PR #468 merge 后的下一次真实 USB E0 preflight 又在 target readback 前发现 HDC pin 漂移：
同一 DevEco absolute path 现为 client/server `Ver: 3.2.0f`、SHA-256 `05b2bf7a…f83`，
不同于 r3 的 `3.2.0d` / `48395ba8…d260`。同次 exact `ld` 仍得到相同 Maskrom record。
target/firmware HDC command、original target、binding、typed capability evidence、intent、
usage reservation 与 E1 均为 0。HDC 需要新的 scoped readiness + registry/probe closure；
Maskrom 则仍须由物理环境消除，二者任一未闭合时 E1 保持 blocked。

`TASK-RKFUI-001B/run.md` 记录 r4 line-termination implementation：canonical registry、
bundled resource mirror、17 个 hash-pinned fixtures、Swift production parser/tests 与
001A Python probe/tests 已形成 homogeneous LF/CRLF closure。bare CR、mixed
terminator、missing final terminator 与 empty record 全部 fail closed；合成 CRLF
Maskrom 仍是一个显式 wrong-mode observation。本任务没有运行 HDC、`rkdeveloptool` 或
USB observation，E1/E2/destructive、intent、binding 和 usage reservation 均为 0。

`TASK-RKFUI-001C/run.md` 记录 r5 host-only exact repin closure：canonical
loader-transition registry、Python probe registry validation、FakeRunner/negative tests 与
README 只接受 HDC `Ver: 3.2.0f` /
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`，并固定
`PR#481@0f0a79aff7ede1519b9fbc0cbdca12b5c687ef07`。旧 version/hash 各自作为
fail-closed drift case，不存在 fallback 或双 pin。本任务没有运行任何 HDC、
`rkdeveloptool`、USB 或设备命令，也不构成逐设备 capability evidence。

PR #484 合入、001A 恢复 E0 preparation 后，fresh real-hardware E0 preflight 已确认
HDC client/server `3.2.0f`、executable hash、唯一 target serial 与 firmware 全部命中；
但 clean `rkdeveloptool` 虽仍命中 version/hash，其所在 `/opt/homebrew` source checkout
HEAD 已变为 `7c2bb3b2…`，不匹配 registry 的 upstream `304f0737…`，且后者不是该
checkout 的 object。preflight 因此在 codesign/quarantine、`ld`、USB observation、
binding/capability evidence、intent、usage 与 E1 前 fail closed。candidate count 未观察，
不得记为 0；详情见
`TASK-RKFUI-001A/blocked-capability-preflight-rkdeveloptool-source-drift-2026-07-24.*`。
