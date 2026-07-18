# CHG-2026-014 Verification Plan

> Status:planned
> Change:CHG-2026-014-remote-lock-legacy-consolidation@r1
> Core baseline:CORE-2.0.0

## Environment

- 锁屏 macOS 的 headless shell；Swift/Xcode/Python 使用仓库现有 toolchain；
- 只使用仓库 fixture、临时目录和 loopback ephemeral endpoint；
- 禁止 GUI automation、Developer Mode/系统授权变更、NSOpenPanel/PowerBox、已安装真实
  `hdc`、真实设备和非 loopback 网络。

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| RLC-LEGACY-IMPORT-001 | git object/path/hash review | manifest 的 source Task、完整 OID、parent/base、逐文件 disposition/hash、未关闭 AC 与实际对象精确一致；未提交 worktree/branch 名不作为 authority | pending |
| RLC-FAIL-CLOSED-001 | static reachability + fake/loopback contract/fault tests | 导入后真实 HDC/device/non-loopback/automatic lifecycle/subserver/device-migration dispatch count 为 0；未验证路径不能铸造执行 authority；PD collector 未运行 | pending |
| RLC-NONBLOCKING-001 | tasks/dependency/claim document review | source Task 保持非 done、当前状态与原 AC/evidence 如实不变；本任务不依赖 source done；没有 consumer dependency 被自动改写；conformance/hardware/support/release gate 均未放宽 | pending |
| RLC-AUDIT-ROLLBACK-001 | one-PR diff + revert simulation/document review | consolidation 是一个 TASK-RLC-001 implementation PR，可独立 revert；旧 evidence immutable；无 secret/locator/raw sensitive artifact | pending |

## Negative and recovery tests

- source OID 缺失、OID/path/hash 不一致、出现未登记文件：整体 fail；
- public/import/runtime scan 发现 App 或外部模块可直接构造 argv/dispatch authority：整体 fail；
- 任一测试尝试真实 HDC、真实设备、NSOpenPanel、Developer Mode 或非 loopback 网络：整体 fail；
- 旧 blocked evidence 被修改、重判或复制成 passing evidence：整体 fail；
- 任一 consumer dependency 在本 PR 被改写：整体 fail，须拆为独立 task revision；
- import 后 build/test 失败：revert/停止，不以 legacy 标签豁免。

## Result gate

- [ ] 四项 change-local AC 均有同一 revision 的可复查 headless evidence；
- [ ] 原 M1-006/PD-001 Task 均保持非 done，当前状态与未关闭 AC 完整列出；
- [ ] 自动真实 process/device/server mutation dispatch count 为 0；
- [ ] 一个实现 PR、来源完整 OID、逐文件 disposition 与 rollback 点齐备；
- [ ] 未修改 Core/spec/contract/baseline/integration/platform/acceptance；
- [ ] 维护者确认“implementation scheduling non-blocking”未被解释为 verification/release
      non-blocking。

本 change verified 也只证明 consolidation 机制按批准范围执行；不会验证 source Task、
macOS platform、HDC compatibility、DAYU200 或任何 release capability。
