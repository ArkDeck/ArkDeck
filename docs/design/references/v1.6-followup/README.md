# v1.6 后续修正参考图

2026-08-27 · 基线 `e1d52e68` + 当前工作区修正。**49 张浏览器设计图、9 张原生 App UI 测试截图**，均逐张查看。

这些图补充并覆盖[首轮快照](../v1.6/README.md)中的受影响页面；不代表已合入 main、远程设计库已同步或真实设备验收。完整范围见[全页报告](../../implementation-audit-2026-08-27.md)。

## 来源与尺寸

- 浏览器：实际 viewport **1280×720**；prototype 的 reference window 固定为 **1180×760**。部分图有水平留白、纵向滚动，不能当作 1180×760 全窗图或与 App 做逐像素验收。新增组件画廊使用其自适应页面。
- 原生：保留 XCUITest 附件原始 PNG 字节及像素尺寸；未缩放、重绘或裁剪。Diagnostics / Inspector 使用显式 fixture；Trace 空窗仅保留本机最近记录元数据，没有打开真实 Trace。
- 图片只证明可见区域；长表/页面和滚动后的局部在操作列注明。App 设备身份、取消、产物校验等行为由合约测试另行覆盖，不能由图片推断。
- [manifest.json](manifest.json) 给出精确 URL / 操作、来源测试、文件大小、MIME、尺寸与 SHA-256；[verification-summary.json](verification-summary.json) 记录分批测试结果。

## 复现

在 `docs/design` 下运行 `python3 -m http.server 8765 --bind 127.0.0.1`。画廊需先运行 `npm --prefix docs/design/arkdeck-ds run build:review`。将 viewport 设为 1280×720，按下表 URL 与操作截图，不导入真实文件、不连接 Runtime 或 SSH。

原生截图需通过仓库脚本运行对应 XCUITest，再从 `.xcresult` 导出附件。不要用 HTML 样本替代原生 App 截图。

## 浏览器设计图

| 图片 | 地址 | 操作 |
| --- | --- | --- |
| [components-en-light.jpg](components-en-light.jpg) | [打开](http://127.0.0.1:8765/session-components.html?lang=en) | 直接打开 |
| [components-en-light-device.jpg](components-en-light-device.jpg) | [打开](http://127.0.0.1:8765/session-components.html?lang=en) | Scroll to the Device section by selecting the No screenshot heading. |
| [components-zh-dark.jpg](components-zh-dark.jpg) | [打开](http://127.0.0.1:8765/session-components.html?lang=zh-Hans&appearance=dark) | 直接打开 |
| [components-zh-dark-device.jpg](components-zh-dark-device.jpg) | [打开](http://127.0.0.1:8765/session-components.html?lang=zh-Hans&appearance=dark) | Set frames to 300; enter 301 and verify the controlled field stays at 300; scroll to Device. |
| [trace-viewer-loaded-en.jpg](trace-viewer-loaded-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loaded&lang=en) | 直接打开 |
| [trace-viewer-search-en.jpg](trace-viewer-search-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loaded&lang=en) | Search Draw and choose Next match; selected sample event is DrawFrame. |
| [trace-viewer-range-mark-bottom-en.jpg](trace-viewer-range-mark-bottom-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loaded&lang=en) | Select range, set From to 1, Apply range; Mark Selection and Keep; dock at Bottom. |
| [trace-viewer-loaded-zh.jpg](trace-viewer-loaded-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loaded&lang=zh-Hans) | 直接打开 |
| [trace-viewer-empty-zh.jpg](trace-viewer-empty-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&lang=zh-Hans) | 直接打开 |
| [trace-viewer-failed-en.jpg](trace-viewer-failed-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=failed&lang=en) | 直接打开 |
| [trace-viewer-loading-en.jpg](trace-viewer-loading-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loading&lang=en) | 直接打开 |
| [trace-shortcuts-zh.jpg](trace-shortcuts-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-shortcuts&lang=zh-Hans) | 直接打开 |
| [trace-shortcuts-en.jpg](trace-shortcuts-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-shortcuts&lang=en) | 直接打开 |
| [trace-viewer-filter-empty-en.jpg](trace-viewer-filter-empty-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&traceViewerState=loaded&lang=en) | Search Draw and select the result; filter processes by unmatched. Selected event is preserved while the lane list becomes empty. |
| [diagnostics-loaded-en.jpg](diagnostics-loaded-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&diagnosticsState=loaded&lang=en) | 直接打开 |
| [diagnostics-loaded-zh.jpg](diagnostics-loaded-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&diagnosticsState=loaded&lang=zh-Hans) | 直接打开 |
| [diagnostics-preview-zh.jpg](diagnostics-preview-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=zh-Hans&diagnosticsState=loaded) | Click 在本机读取敏感内容, then hilog.txt heading to bring the explicit preview into view. |
| [diagnostics-partial-en.jpg](diagnostics-partial-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=en&diagnosticsState=partial) | 直接打开 |
| [diagnostics-failed-zh.jpg](diagnostics-failed-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=zh-Hans&diagnosticsState=failed) | 直接打开 |
| [diagnostics-trace-source-en.jpg](diagnostics-trace-source-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=en&diagnosticsState=trace) | Scroll to Session artifacts; the published sensitive Trace has an explicit handoff button. |
| [overview-prepare-en.jpg](overview-prepare-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en) | Click Continue… on S-0826-04, the fourth Recent work row. |
| [overview-readonly-draft-en.jpg](overview-readonly-draft-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en) | S-0826-04 → Continue… → Prepare Inputs, then scroll to New draft from history. No Job submitted. |
| [overview-prepare-zh.jpg](overview-prepare-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=zh-Hans) | Click 继续… on S-0826-04 (fourth row). |
| [overview-readonly-draft-zh.jpg](overview-readonly-draft-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=zh-Hans) | S-0826-04 → 继续… → 准备参数, then scroll to 来自历史记录的新草稿. |
| [job-inspector-running-en.jpg](job-inspector-running-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en&jobState=running) | Open the global Job inspector. |
| [job-inspector-cancel-request-en.jpg](job-inspector-cancel-request-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en&jobState=running) | Open inspector → Request Cancellation. The state remains running. |
| [job-inspector-log-en.jpg](job-inspector-log-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en&jobState=running) | Open inspector → Request Cancellation → Read Log · capture.log. Scroll to the explicit log preview. |
| [job-inspector-unknown-zh.jpg](job-inspector-unknown-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=zh-Hans&jobState=unknown) | Open global inspector; unknown outcome has no cancellation, replay, archive or confirmation override. |
| [debug-artifacts-en.jpg](debug-artifacts-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | 直接打开 |
| [debug-logs-en.jpg](debug-logs-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=logs&lang=en) | 直接打开 |
| [debug-apps-en.jpg](debug-apps-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&lang=en) | 直接打开 |
| [debug-network-en.jpg](debug-network-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=net&lang=en) | 直接打开 |
| [debug-commands-en.jpg](debug-commands-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=cmd&lang=en) | 直接打开 |
| [debug-artifacts-zh.jpg](debug-artifacts-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=zh-Hans) | 直接打开 |
| [debug-apps-zh.jpg](debug-apps-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&lang=zh-Hans) | 直接打开 |
| [debug-logs-zh.jpg](debug-logs-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=logs&lang=zh-Hans) | 直接打开 |
| [debug-network-zh.jpg](debug-network-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=net&lang=zh-Hans) | 直接打开 |
| [debug-commands-zh.jpg](debug-commands-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=cmd&lang=zh-Hans) | 直接打开 |
| [debug-native-plan-en.jpg](debug-native-plan-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Choose local .so… → Target bundle com.example.app → Validate and review plan, wait for the demo plan sheet. No file read or device effect. |
| [debug-native-plan-steps-en.jpg](debug-native-plan-steps-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Choose demo .so, bundle com.example.app, Validate and review plan; scroll within Materialized steps to finalize-session (step 11). |
| [ssh-manager-en.jpg](ssh-manager-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Remote server → Manage servers…; design fixtures only. |
| [ssh-editor-unverified-en.jpg](ssh-editor-unverified-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Remote server → Manage servers… → Edit. Save remains disabled before probing the current draft. |
| [ssh-editor-verified-en.jpg](ssh-editor-verified-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Remote server → Manage servers… → Edit → Username builder → Test connection and inspect host key. This is a synthetic probe, not SSH. |
| [ssh-editor-drift-en.jpg](ssh-editor-drift-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | After synthetic verification, change Host or IP to build-changed.example.internal. Verify Save verified server is disabled again. |
| [ssh-browser-en.jpg](ssh-browser-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=artifacts&lang=en) | Remote server → Browse remote .so…; synthetic root-confined directory sample. |
| [settings-trace-cache-en.jpg](settings-trace-cache-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=cache&lang=en) | 直接打开 |
| [settings-trace-cache-zh.jpg](settings-trace-cache-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=cache&lang=zh-Hans) | 直接打开 |
| [settings-trace-licenses-en.jpg](settings-trace-licenses-en.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=licenses&lang=en) | 直接打开 |
| [settings-trace-licenses-zh.jpg](settings-trace-licenses-zh.jpg) | [打开](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=licenses&lang=zh-Hans) | 直接打开 |

## 原生 App 图

| 图片 | 来源测试 | 像素尺寸 |
| --- | --- | --- |
| [diagnostics-session-en.png](native/diagnostics-session-en.png) | `AppShellUITests/testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment` | 2360×1566 |
| [diagnostics-preview-en.png](native/diagnostics-preview-en.png) | `AppShellUITests/testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment` | 2360×1566 |
| [diagnostics-session-zh.png](native/diagnostics-session-zh.png) | `AppShellUITests/testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment` | 2360×1566 |
| [diagnostics-preview-zh.png](native/diagnostics-preview-zh.png) | `AppShellUITests/testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment` | 2360×1566 |
| [trace-viewer-empty-en.png](native/trace-viewer-empty-en.png) | `AppShellUITests/testTraceViewerAndShortcutHelpUseBothLanguages` | 2560×1600 |
| [trace-viewer-empty-zh.png](native/trace-viewer-empty-zh.png) | `AppShellUITests/testTraceViewerAndShortcutHelpUseBothLanguages` | 2560×1600 |
| [trace-shortcuts-en.png](native/trace-shortcuts-en.png) | `AppShellUITests/testTraceViewerAndShortcutHelpUseBothLanguages` | 1040×1240 |
| [trace-shortcuts-zh.png](native/trace-shortcuts-zh.png) | `AppShellUITests/testTraceViewerAndShortcutHelpUseBothLanguages` | 1040×1240 |
| [job-inspector-en.png](native/job-inspector-en.png) | `AppShellUITests/testEnglishSweepOfEveryWorkspace` | 2360×1566 |
