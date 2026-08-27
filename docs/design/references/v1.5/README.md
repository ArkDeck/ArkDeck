# Device v1.5 设计参考

本版把 Device 交互稿回写到当前 SwiftUI：默认空态、按需截图、按帧录屏，以及旧画面拒绝输入。可点击入口为 [`prototype.html?page=device-control`](../../prototype.html?page=device-control)。去掉 `reference=1` 后可使用窗口外的状态、语言、外观及宽／窄窗评审控件。

本轮参考图由内置浏览器的 **1280×720 viewport** 直接截取，保留浏览器返回的 JPEG，不裁剪、不加工。区别于旧版 1180×760 PNG 基线：宽窗画布为 1180×720，窄窗为 960×720；两侧背景是 viewport 留白。不要把下列图当作原生 App 截图或真机证据。

| 文件 | 原型参数／复现步骤 |
| --- | --- |
| `device-empty-zh-Hans.jpg` | `?reference=1&page=device-control&lang=zh-Hans&appearance=light` |
| `device-empty-en.jpg` | `?reference=1&page=device-control&lang=en&appearance=light` |
| `device-preflight-en.jpg` | 同上；点击「Record」后立即截取「Checking storage」，帧数和录制按钮均禁用。阶段延迟仅为演示计时。 |
| `device-quota-refused-zh-Hans.jpg` | `?reference=1&page=device-control&deviceState=quota&lang=zh-Hans&appearance=light`；点击「录制」，预检后显示需要 2.6 MB／剩余 1.5 MB，以及「22 帧 放得下」。 |
| `device-runtime-unavailable-zh-Hans.jpg` | `?reference=1&page=device-control&deviceState=runtimeUnavailable&lang=zh-Hans&appearance=light`；点击「录制」，预检后显示 Runtime 入口未接通，未开始采集且没有可导出的结果。 |
| `device-ready-dark-zh-Hans.jpg` | `?reference=1&page=device-control&deviceState=ready&lang=zh-Hans&appearance=dark` |
| `device-ready-compact-zh-Hans.jpg` | `?reference=1&page=device-control&deviceState=ready&deviceWidth=compact&lang=zh-Hans&appearance=light`；点击「在访达中显示」，让结果区滚入视野。这个按钮只发布演示提示，不打开访达。 |

宽窗内容区为 922 px，画面 602 px + Inspector 320 px。窄窗内容区为 702 px，画面高 420 px，Inspector 接在其后，可整体滚动。英文空态的负载提示完整显示；截图、结果、边界没有横向溢出。深色图中的 1.80 fps、40 帧和 `/tmp/ArkDeck-recording-demo.mov` 是演示值，没有生成录像。

## 验证

- `node --test docs/design/arkdeck-ds/scripts/device-interactions.test.mjs`：12 项演示状态机测试，包括 stale、unknown 不重发、预检期间锁定控件、配额拒绝、缺帧、Runtime 入口未接通与迟到回调隔离。
- `node docs/design/arkdeck-ds/scripts/check-tokens.mjs`：v1.5 token 与组件覆盖检查。
- 仓库完整本地闸：SDD、Catalog generator、Swift 全量测试及 App/UI-test bundle 构建。
- 原生 `AppShellUITests/testDeviceWorkspaceNameAndEmptyStateInBothLanguages`：使用 fixture 的 App 呈现测试通过；没有执行本轮真机输入或采集。
- 原生 `AppShellUITests/testDeviceRecordingLocksControlsWhileCheckingStorage`：修复前复现预检期间两个控件仍可用；修复后通过锁定、拒绝后恢复、缩短至 22 帧但不自动录制。使用延迟配额 fixture，在读取任何帧归档前拒绝，不是硬件结果。

## 本轮真机结果

见 [真机走查记录](real-device-validation.md)。已完成 CLI 真实截图／输入／40 帧序列采集，以及 App 截图、旧图拒绝和刷新恢复。App 真机录屏仍被已安装 Runtime 的 XPC 入口遗漏阻断，源码已修、尚待更新受保护 Runtime 后再验。`deviceState=runtimeUnavailable` 可演示该失败边界，不会产出伪视频。
