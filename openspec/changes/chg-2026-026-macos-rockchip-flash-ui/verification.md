# Verification Plan — CHG-2026-026

> Change:CHG-2026-026@r3
> Status:planned
> Note(2026-07-24):r3 只把一次 E1 characterization window 的 exact firmware pin 从
> `7.0.0.34` 替换为 E0 读回的 `7.0.0.33`；r2 其余 pins、Core/AC/schema 均不变。

## Environment

- Baseline：`CORE-2.0.0` + 实现开始时已批准的 scoped delta；若 CHG-2026-025 归档/baseline
  变化，重新 pin 并做 spec-impact review。
- Platform：macOS 14+；Swift 6；signed Sandboxed Developer ID/Hardened Runtime App 形态。
- Tool：TASK-RKFUI-001/001A 的 read-only discovery 使用外部用户选择的 clean
  `rkdeveloptool ver 1.32` / SHA-256 `bbd7bdc0…9923` / upstream `304f0737…`，且
  version/hash/trust 与 r2 后的 Rockchip registry 完全匹配；既有 destructive
  Provider/Profile 继续 pin `038a8a0e…3611`，r2 不构成 destructive repin。生产不使用
  BlueTool/upgrade_tool。
- Fixtures：fake rkdeveloptool、版本化 `ld/ppt/wlx/rd` stdout/stderr、valid/corrupt/drift/
  path-traversal tar.gz、journal crash points、postflight observations。
- Hardware：TASK-RKFUI-001 E0、TASK-RKFUI-001A 对 exact DAYU200 /
  OpenHarmony `7.0.0.33` / HDC `3.2.0d` / USB 组合的 E1 mode transition 与
  TASK-RKFUI-004；其余测试无设备、零真实 dispatch。r2 允许 001A 为 001 提供 Loader
  前置态，r3 只修正当前 firmware pin；两份 evidence 分离，001A 明确禁止 destructive
  command。

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| AC-FLASH-001-01 | parser golden/real-fault + E0 `ld` | 仅 2207:350a Loader applicable；其他/畸形阻断，相似命令 0 | TASK-RKFUI-001 |
| AC-UX-007-01 | signed Sandbox E0 matrix | permission/driver/offline 可区分；sudo/helper/install/system mutation 0 | TASK-RKFUI-001 |
| AC-FLASH-003-01 | archive drift/corrupt/unsafe fixture | execute 与 planned-success 均 blocked | TASK-RKFUI-002/003 |
| AC-FLASH-004-01 | plan/manifest encode-decode + UI | mode 在 UI/Job/manifest/History presentation 持续可见 | TASK-RKFUI-002 |
| AC-FLASH-005-01 | plan-only integration | exact plan 含 mutation/destructive steps，runner 0，terminal planned | TASK-RKFUI-002 |
| AC-FLASH-005-02 | plan Artifact finalization fault | terminal failed，非 planned | TASK-RKFUI-002 |
| AC-FLASH-002-01 | prerequisite fault matrix | required unknown/unsatisfied 在强确认前阻断 | TASK-RKFUI-003 |
| AC-FLASH-007-01 | UI/authorization negative test | 取消任一确认时 updater/flash/reset 0 | TASK-RKFUI-003/004 |
| AC-FLASH-008-01 | fake long-running `wlx` + quit/cancel | 不 force kill，安全边界后停止下一 step | TASK-RKFUI-003 |
| AC-FLASH-009-01 | fake sleep/wake + power spy | journal/reconcile；activity 全路径成对释放 | TASK-RKFUI-003 |
| AC-FLASH-010-01 | binding drift/reappearance fault | 未确认 identity 时 mutation 0，旧确认失效 | TASK-RKFUI-003/004 |
| AC-DEV-001-01 | HDC original target creation/replay | 原目标和 revision 1 在 mode transition 前 durable，UI 变化不能改写 | TASK-RKFUI-001A/003 |
| AC-DEV-002-01 | transition fake/E1 + journal replay | reboot 只用 intent 所 pin revision；Loader rebind revision durable 后才继续 | TASK-RKFUI-001A/003 |
| AC-DEV-002-02 | missing/wrong target + multi-device fault | 无默认 target；错误/缺 binding 时 HDC/RockUSB mutation 0 | TASK-RKFUI-003 |
| AC-DEV-003-01 | pre/post identity evidence matrix | 仅强证据单候选可 auto-rebind；否则等待人工确认 | TASK-RKFUI-001A/003 |
| AC-DEV-003-02 | weakened profile/unique-loader fault | VID/model/唯一候选不能降低 Core threshold，flash 0 | TASK-RKFUI-003 |
| AC-DEV-006-01 | ambiguous/declined rebind | Loader 可显示但下一 device mutation 0 | TASK-RKFUI-003/004 |
| AC-DEV-008-01 | concurrent Flash/mode-transition lane | 同 physical device 同时最多一个 mutation Job | TASK-RKFUI-003 |
| AC-FLASH-011-01 | unknown-total fake output | indeterminate phase，不按步骤伪造百分比 | TASK-RKFUI-002/003 |
| AC-FLASH-012-01 | exit0/marker/postflight cross product | 只有写入+reset+postflight 全语义确认才 succeeded | TASK-RKFUI-003/004 |
| AC-FLASH-013-01 | disconnect/postflight deadline | 非 succeeded，unknown 与 RecoveryGuide 可见 | TASK-RKFUI-003/004 |
| AC-FLASH-015-01 | authority matrix | 非适用 authority policyBlocked，real dispatch 0 | TASK-RKFUI-003/004 |
| AC-FLASH-015-02 | target/archive/tool/provider/plan pin tamper | 任一 mismatch real dispatch 0，不能事后追认 | TASK-RKFUI-003/004 |
| AC-UX-001-01 | XCUITest cross-navigation | Flash Job 阶段/状态/操作跨页面可见 | TASK-RKFUI-002/004 |
| AC-UX-005-01 | accessibility inspection/XCUITest | 风险、影响、确认文字/图标/控件可读，不只靠颜色 | TASK-RKFUI-002/003 |
| AC-UX-006-01 | UI + exported presentation round-trip | plan-only badge 不因完成/导出消失 | TASK-RKFUI-002 |
| AC-I18N-001-01 | localization key lint + zh-Hans/en/pseudo smoke | 无缺 key，长文本不截断关键确认，不拼接关键控件 | TASK-RKFUI-002/003 |
| AC-FLASH-014-01 | precise realHardware App run | 精确设备/固件/tool/App build 全 required AC PASS 后才可追加 matrix | TASK-RKFUI-004 |

## Negative and recovery tests

- Tool：missing/non-executable/hash drift/version mismatch/quarantine/trust unknown/permission denied。
- Discovery：空、多个、重复 LocationID、Maskrom、未知 PID/mode、截断、额外垃圾、timeout。
- Mode transition：already Loader skip；HDC offline/unsupported/empty target；command nonzero/exit0
  无 disconnect；disconnect 后无 Loader、`0x5000`/Maskrom/wrong mode、多 candidate、deadline、
  sleep/wake；pre/post topology/fingerprint match/mismatch；用户拒绝 rebind；physical fallback。
- Archive：hash/size/member drift、缺失/重复成员、corrupt gzip/tar、absolute/`..` path、
  symlink/hardlink/device entry、trailing payload、ENOSPC/read-only volume/bookmark expiry。
- Authorization：旧 plan、旧 binding、错误 physical target、取消/不完整双确认、非交互 authority。
- Process：每个 intent/outcome 窗口 crash；exit nonzero、exit0 无 marker、partial marker、无限输出、
  timeout、disconnect、sleep/wake。
- Cancellation：preflight immediate、写前 immediate、`wlx` critical deferred、safe boundary 后停止。
- Recovery：intent-only → outcomeUnknown/zero replay；postflight 未回连 → RecoveryGuide；raw
  Artifact 不原地修改。
- Privacy：默认日志/fixture/evidence secret/path/serial scan；外部网络与自动上传调用 0。

## Deviations

- signed Sandbox direct non-elevated USB access 若失败，TASK-RKFUI-003/004 不得用 sudo/helper
  绕过；如实 blocked 并新建平台/分发 change。
- r2 clean discovery repin 若未在 registry/resource closure/Swift/Python probe 四面原子完成，
  或当前 artifact/`7.0.0.33` firmware/HDC/binding 与 readiness pins 任一漂移，001/001A
  均 fail closed；
  不得回退到 quarantined artifact、接受两个 hash 或用 destructive Provider 的旧 pin 冒充。
- r3 合入前，`7.0.0.33` 只是一条 blocked E0 observation，不构成 E1 授权或 capability
  evidence；probe implementation、`reboot loader` 与 `ld` transition observation dispatch
  必须为 0。r3 merge 后仍只允许原窗口剩余的单次 exact run，不得把未消费次数解释为可重试。
- `REQ-FLASH-015` 交互式 App executor 解释未获维护者明确确认时，execute 不实现；不得把
  plan-only/handoff 记作一键真机刷机。
- DAYU200 exact combination 的 `reboot loader` E1 capability 未证明 supported 时，Route B
  默认关闭并展示物理按键 Route C；不得用 BlueTool 静态行为或相似型号替代 evidence。
- BlueTool 行为只作参考，不构成 ArkDeck AC evidence 或第三方资产授权。

## Result gate

- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] E0 signed Sandbox access gate passed，或 execute task 明确保持 blocked
- [ ] E1 HDC→Loader exact-combination capability 有诚实 verdict；unsupported/unknown 默认
      physical fallback，destructive dispatch 0
- [ ] Real hardware App path 由适格操作者执行，evidence 精确 pin 全组合
- [ ] Traceability updated（无新 Core AC ID；记录现有 AC → 新 tests/evidence）
- [ ] 无 shell/sudo/helper/BlueTool asset、无 secret/真实 serial/raw 敏感输出入库
