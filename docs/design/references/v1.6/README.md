# v1.6 设计参考图

> 首轮历史快照。受影响页面以 [v1.6 后续修正](../v1.6-followup/README.md) 为准；下文的未完成说明描述首轮状态，不是当前产品结论。

2026-08-27，基于 `e1d52e68` 与本轮设计修正。全部为 **1180×760 的浏览器原型截图**，保留浏览器原始 JPEG 编码，均已逐张查看；不是原生 App 截图、Runtime 执行结果或真机证据。完整差异见[全页扫描](../../implementation-audit-2026-08-27.md)。

## 复现

在 `docs/design` 下运行 `python3 -m http.server 8765 --bind 127.0.0.1`，将浏览器 viewport 设为 1180×760，再按下表地址与步骤截取 viewport。`reference=1` 不隐藏演示数据声明；有弹层时弹层自身说明演示边界。

[manifest.json](manifest.json) 记录每张图片的精确查询参数、交互步骤、实际 MIME 类型和 SHA-256。

## 验证边界

- 共 63 张。长页面仅保存首个 viewport，不能据此声称所有滚动内容均在截图内；代码与接线覆盖以全页扫描的 60 个检查单元为准。
- Viewer 五个 Inspector、Advanced Dump 拒绝/失败、HAP 参数预览、Trace 输入与单位转换、Overview 继续说明均单列。
- Trace Viewer 与快捷键帮助图只覆盖入口/空态，尚不是 loaded 时间轴或完整帮助镜像。
- `lang=en` 不代表所有文案已翻译；Debug/授权和部分辅助文案仍有中文，Trace Cache/Licenses 内部仍为英文。缺口已列在扫描 F13/F14。
- 原型不连接 Runtime、不导入真实 HAP、不创建真实 Job、不采集设备；示意字段、图片与状态不得作为硬件验收。

## 图片与地址

| 图片 | 复现地址 | 追加交互 |
| --- | --- | --- |
| [debug-apps-en.jpg](debug-apps-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&lang=en) | 无；直接打开地址 |
| [debug-apps-zh.jpg](debug-apps-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&lang=zh-Hans) | 无；直接打开地址 |
| [debug-artifacts-en.jpg](debug-artifacts-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&lang=en) | 无；直接打开地址 |
| [debug-artifacts-zh.jpg](debug-artifacts-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&lang=zh-Hans) | 无；直接打开地址 |
| [debug-commands-zh.jpg](debug-commands-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=cmd&lang=zh-Hans) | 无；直接打开地址 |
| [debug-hap-preview-en.jpg](debug-hap-preview-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&lang=en) | Choose demo HAP, enter com.example.app / EntryAbility, click Import and run: opens a parameter preview only, no file import or Runtime Job. |
| [debug-hap-unavailable-zh.jpg](debug-hap-unavailable-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=apps&hapState=unavailable&lang=zh-Hans) | 无；直接打开地址 |
| [debug-logs-zh.jpg](debug-logs-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=logs&lang=zh-Hans) | 无；直接打开地址 |
| [debug-network-zh.jpg](debug-network-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=debug&debugTab=net&lang=zh-Hans) | 无；直接打开地址 |
| [device-detail-en.jpg](device-detail-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=device&lang=en) | 无；直接打开地址 |
| [device-detail-zh.jpg](device-detail-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=device&lang=zh-Hans) | 无；直接打开地址 |
| [device-empty-en.jpg](device-empty-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=device-control&lang=en) | 无；直接打开地址 |
| [device-empty-zh.jpg](device-empty-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=device-control&lang=zh-Hans) | 无；直接打开地址 |
| [device-trust-en.jpg](device-trust-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=auth&lang=en) | 无；直接打开地址 |
| [device-trust-zh.jpg](device-trust-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=auth&lang=zh-Hans) | 无；直接打开地址 |
| [diagnostics-en.jpg](diagnostics-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=en) | 无；直接打开地址 |
| [diagnostics-zh.jpg](diagnostics-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=diagnostics&lang=zh-Hans) | 无；直接打开地址 |
| [flash-en.jpg](flash-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=flash&lang=en) | 无；直接打开地址 |
| [flash-zh.jpg](flash-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=flash&lang=zh-Hans) | 无；直接打开地址 |
| [history-en.jpg](history-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=history&lang=en) | 无；直接打开地址 |
| [history-zh.jpg](history-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=history&lang=zh-Hans) | 无；直接打开地址 |
| [overview-continue-en.jpg](overview-continue-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en) | Click Continue on the Viewer run: explains navigation only, no prefill, submission or inherited thread. |
| [overview-continue-zh.jpg](overview-continue-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=zh-Hans) | 点击 Viewer 记录的继续：仅打开工作区，不回填、不提交、不继承调试线。 |
| [overview-en.jpg](overview-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=en) | 无；直接打开地址 |
| [overview-zh.jpg](overview-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=overview&lang=zh-Hans) | 无；直接打开地址 |
| [settings-diagnostics-en.jpg](settings-diagnostics-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=diagnostics&lang=en) | 无；直接打开地址 |
| [settings-diagnostics-zh.jpg](settings-diagnostics-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=diagnostics&lang=zh-Hans) | 无；直接打开地址 |
| [settings-general-en.jpg](settings-general-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=general&lang=en) | 无；直接打开地址 |
| [settings-general-zh.jpg](settings-general-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=general&lang=zh-Hans) | 无；直接打开地址 |
| [settings-servers-en.jpg](settings-servers-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=servers&lang=en) | 无；直接打开地址 |
| [settings-servers-zh.jpg](settings-servers-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=servers&lang=zh-Hans) | 无；直接打开地址 |
| [settings-storage-en.jpg](settings-storage-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=storage&lang=en) | 无；直接打开地址 |
| [settings-storage-zh.jpg](settings-storage-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=storage&lang=zh-Hans) | 无；直接打开地址 |
| [settings-toolchains-en.jpg](settings-toolchains-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=toolchains&lang=en) | 无；直接打开地址 |
| [settings-toolchains-zh.jpg](settings-toolchains-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=toolchains&lang=zh-Hans) | 无；直接打开地址 |
| [settings-trace-cache-en.jpg](settings-trace-cache-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&lang=en) | 无；直接打开地址 |
| [settings-trace-cache-zh.jpg](settings-trace-cache-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&lang=zh-Hans) | 无；直接打开地址 |
| [settings-trace-licenses-en.jpg](settings-trace-licenses-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=licenses&lang=en) | 无；直接打开地址 |
| [settings-trace-licenses-zh.jpg](settings-trace-licenses-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=trace&traceSettingsTab=licenses&lang=zh-Hans) | 无；直接打开地址 |
| [settings-updates-en.jpg](settings-updates-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=updates&lang=en) | 无；直接打开地址 |
| [settings-updates-zh.jpg](settings-updates-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=settings&settingsTab=updates&lang=zh-Hans) | 无；直接打开地址 |
| [trace-invalid-en.jpg](trace-invalid-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace&traceState=ready&lang=en) | Enter 601, click Start capture: input is preserved, inline error appears, no capture starts. |
| [trace-ready-minutes-en.jpg](trace-ready-minutes-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace&traceState=ready&lang=en) | Enter 15 seconds, then switch to Minutes: rounds up to 1 min. |
| [trace-shortcuts-en.jpg](trace-shortcuts-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-shortcuts&lang=en) | 无；直接打开地址 |
| [trace-shortcuts-zh.jpg](trace-shortcuts-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-shortcuts&lang=zh-Hans) | 无；直接打开地址 |
| [trace-unavailable-en.jpg](trace-unavailable-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace&lang=en) | 无；直接打开地址 |
| [trace-unavailable-zh.jpg](trace-unavailable-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace&lang=zh-Hans) | 无；直接打开地址 |
| [trace-viewer-empty-en.jpg](trace-viewer-empty-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&lang=en) | 无；直接打开地址 |
| [trace-viewer-empty-zh.jpg](trace-viewer-empty-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=trace-viewer&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-accessibility-en.jpg](viewer-accessibility-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=accessibility&lang=en) | 无；直接打开地址 |
| [viewer-accessibility-zh.jpg](viewer-accessibility-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=accessibility&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-advanced-en.jpg](viewer-advanced-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=advanced&lang=en) | 无；直接打开地址 |
| [viewer-advanced-failed-en.jpg](viewer-advanced-failed-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=advanced&advancedState=failed&lang=en) | 无；直接打开地址 |
| [viewer-advanced-missing-ids-en.jpg](viewer-advanced-missing-ids-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=advanced&advancedState=missingIDs&lang=en) | 无；直接打开地址 |
| [viewer-advanced-zh.jpg](viewer-advanced-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=advanced&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-empty-en.jpg](viewer-empty-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&lang=en) | 无；直接打开地址 |
| [viewer-empty-zh.jpg](viewer-empty-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-layout-en.jpg](viewer-layout-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=layout&lang=en) | 无；直接打开地址 |
| [viewer-layout-zh.jpg](viewer-layout-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=layout&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-properties-en.jpg](viewer-properties-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=attributes&lang=en) | 无；直接打开地址 |
| [viewer-properties-zh.jpg](viewer-properties-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=attributes&lang=zh-Hans) | 无；直接打开地址 |
| [viewer-raw-en.jpg](viewer-raw-en.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=raw&lang=en) | 无；直接打开地址 |
| [viewer-raw-zh.jpg](viewer-raw-zh.jpg) | [打开原型](http://127.0.0.1:8765/prototype.html?reference=1&page=dump&viewerState=captured&viewerTab=raw&lang=zh-Hans) | 无；直接打开地址 |
