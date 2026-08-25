# Verification — CHG-2026-071

> Change:CHG-2026-071-interactive-device-control@r1
> Status:planned；proposal merge 只批准 scope，不代表实现或验收通过

## Environment

- macOS 26 / Xcode 26.6 / Swift 6.3；`swift test --package-path
  Packages/ArkDeckKit --parallel` 全量 + `build-for-testing`。
- IDC-AC-1..4 与 IDC-AC-5..8 的真机腿需台架：已接管的 DAYU200
  （OpenHarmony 5.0.0.71，USB），Spike 另需可控滚动负载 HAP 与
  ground-truth HAP。CI 无设备时真机用例 `XCTSkip`，不计通过。
- 本机内存紧张时全量 parallel 可能假红（fixtureTimeout 族），以 CI 判。

## Acceptance matrix

| AC ID | Verification method | Expected result / 量化门槛 |
| --- | --- | --- |
| IDC-AC-1 输入延迟三档（Spike） | 真机测量 ≥50 次/档 | 三档 p50/p95 落 evidence；**产品门槛：交互路径（选定形状）tap 端到端 p95 ≤ 400 ms**。不达标 → T02 的 Toolkit 输入退回「截图上点选 → 显式确认发送」形态，本门槛写进 App 契约测试的形态开关 |
| IDC-AC-2 截图延迟与扰动（Spike） | 真机测量 | JPEG 捕获 p95 ≤ 1.5 s、PNG ≤ 2.5 s；滚动负载下单次截图注入停顿实测值落 evidence（≤1 vsync 为理想；超出则 Timeline instrumentation 痕迹成为 T03 必做项，已在设计中） |
| IDC-AC-3 环形能力（Spike） | 真机探测 | `--trace_begin/dump/finish` 可用且 dump 覆盖 Marker 前 ≥10 s；`--trace_clock` 支持面与默认时钟记录在案。不可用 → T03 blocker，Marker 设计回炉（结论如实落盘，不得绕过） |
| IDC-AC-4 时钟 ground-truth（Spike） | 测试 HAP 对拍 | Trace↔HiLog 偏差分布落 evidence；**±N ms 档启用门槛：p95 ≤ 30 ms 且 drift 可分段建模**；Marker host↔device（USB RTT 校准）p95 ≤ 20 ms。未达标 → 产品长期保持两态词表，UI 不出现 ±N ms |
| IDC-AC-5 输入 operation 正确性 | fake 面 + 真机 | fake 断言真实 argv 形态（`-t <connectKey>` + `uitest uiInput …` 完整子命令）与 stdout 白名单判据；epoch/display facts 漂移 → fail closed；队列滞留 >1 s → `inputExpired` 作废且零派发；unknown → 零重放；连续两次同坐标 tap = 两个 intent（各自新 idempotency key，无静默去重）；真机各输入种类至少一次 confirmed |
| IDC-AC-6 会话准入与并发 | 契约测试 + 真机 | 会话准入一次完整 admission；会话内截图/输入子意图逐条 intent-before-effect 入 ledger；binding/display 漂移 → 会话 fail closed；另一 client 对同设备 mutation → typed `deviceBusyBySession`（非静默排队）；断连后恢复只结算不派发，ledger 与 capability outcome 闭合 |
| IDC-AC-7 环形会话端到端 | 真机一次完整会话 | 手动 + 自动 Marker 的会话产出 `markers.json` + 回溯 trace（覆盖首个 Marker 前 ≥10 s）+ hilog + 截图（记录实际拍摄时刻）；全部 Artifact 过 status/privacy/byte/SHA 校验；App reader 仅按时间事实联动，两态对齐，`+N ms` 标注与 Partial/无法对齐降级可达 |
| IDC-AC-8 Toolkit 面 UX 契约 | UI 契约测试 + 走查 | pending 触点 ≤ 100 ms 出现且与 confirmed 视觉可分；长按（≥500 ms, <6 pt）产出 long-press 而非 tap，tap 锚定 down 点；stale 时 pointer down 被拒且有说明；录屏 Assembling→Validating→结果条（实测帧率 + 位置 + Finder/另存为/再录一段）；开始前配额 preflight 失败即阻断；production-boundary 与 performance notice 不可删除 |

## 不在本次验收内

- 设备侧编码录屏与 remote artifact reference（proposal 非目标；另立 change）。
- 流式预览通道；`已校准 ±N ms` 的产品化（仅 AC-4 给出启用门槛）。
- 「诊断会话内 Toolkit 复现」的同会话注册（机械就位，范围留给后续）。
- Android / iOS 任何能力。
