# Goal 真机修复设计参考

2026-08-27—28 · 基线 `e1d52e68` + 后续 F24–F33 修正。十五张设计样本均已查看。
真机执行与原生 App 证据另见[验证记录](real-device-validation.md)，不由这些图片证明。

浏览器实际 viewport 为 1280×720；前七张使用 1180×760 reference window，新增多包、生命周期、Trace 标记与 Flash 受阻八张使用默认自适应窗口。截图保留原始 JPEG，
未缩放或重绘；预览图包含滚动后的局部，不作为全窗逐像素验收。
[manifest.json](manifest.json)记录 URL、操作、尺寸、字节数和 SHA-256。

| 图片 | 状态与操作 |
| --- | --- |
| [History 新入口](history-diagnostics-entry-en.jpg) | History 选择 S-0826-03；保留 Trace 分类，同时提供 Open Workspace / Open Diagnostics |
| [英文编码提示](diagnostics-encoding-warning-en.jpg) | Diagnostics loaded + repaired encoding 样本；显式读取 HiLog，滚动至编码提示 |
| [中文编码提示](diagnostics-encoding-warning-zh-Hans.jpg) | 同上，zh-Hans；原始 Artifact 不因显示替换字符而改变 |
| [英文 HAP 策略](hap-published-policies-en.jpg) | 安装策略固定，清理策略仅 uninstall/retain |
| [中文 HAP 策略](hap-published-policies-zh-Hans.jpg) | 同上，未发布策略不提供选项 |
| [英文 Trace 文件信息](trace-file-metadata-en.jpg) | loaded 默认无选区，显示文件信息 |
| [中文 Trace 文件信息](trace-file-metadata-zh-Hans.jpg) | 同上；显式选择 DrawFrame 后切换为事件检查器 |
| [英文多包选择](hap-multipackage-en.jpg) | 入口 + feature HAP + HSP；有界添加、移除与清空，局部滚动参考 |
| [中文多包选择](hap-multipackage-zh-Hans.jpg) | 同上，明确每包大小与一次 Job 的提交边界 |
| [英文生命周期提示](hap-running-cleanup-en.jpg) | 同时选择卸载和保持运行时，解释实际结果与保留应用选项 |
| [中文生命周期提示](hap-running-cleanup-zh-Hans.jpg) | 同上；切换到保留后提示消失，不改动已发布请求规则 |
| [英文 Trace 标记](trace-annotations-en.jpg) | 先按中文操作，再切换 EN；临时 Mark 替换后只保留新范围，已保留 Mark 不变，时间线同步显示范围色带 |
| [中文 Trace 标记](trace-annotations-zh-Hans.jpg) | 时刻标记 + 新临时范围 0.600–1.780 s + 已保留范围 3.800–5.050 s；截图后重载清空页面演示状态 |
| [英文 Flash 受阻](flash-hardware-gated-en.jpg) | 已连接的 assessment-only 通道；选择镜像后以受阻原因替代擦写动作，不显示安全检查通过 |
| [中文 Flash 受阻](flash-hardware-gated-zh-Hans.jpg) | 同上；显示硬件资格门原因，不把镜像选择或设备在线当作执行资格 |

这些操作不连接 Runtime、不读取真实敏感文本、不创建真实 Job。
