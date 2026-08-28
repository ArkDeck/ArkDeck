# Goal 真机修复设计参考

2026-08-27—28 · 基线 `e1d52e68` + 后续 F24–F35 修正。二十三张设计样本均已查看。
真机执行与原生 App 证据另见[验证记录](real-device-validation.md)，不由这些图片证明。

浏览器实际 viewport 为 1280×720；前七张使用 1180×760 reference window，后续十六张使用默认自适应窗口。截图保留原始 JPEG，
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
| [英文设备访问空观察](flash-device-access-absent-en.jpg) | 未发现 Loader；重新检查后保留展开区，不创建 Job |
| [中文设备访问空观察](flash-device-access-absent-zh-Hans.jpg) | 同上；提供处理责任方和最小修复步骤 |
| [英文设备访问不可用](flash-device-access-unavailable-en.jpg) | Runtime 不可达显示固定原因码，不伪装为空观察 |
| [中文设备访问不可用](flash-device-access-unavailable-zh-Hans.jpg) | 同上；保留重新检查入口 |
| [英文 Loader 访问](flash-device-access-available-en.jpg) | 只读观察到 1 个 Loader；不代表刷机准入，不提前展示计划 |
| [中文 Loader 访问](flash-device-access-available-zh-Hans.jpg) | 同上；未选择镜像时无“安全检查通过” |
| [英文计划 effect](flash-plan-effects-en.jpg) | 选择演示镜像后显示 3/4/1/6 步阶段；包含重启的收尾阶段最高为 deviceMutation |
| [中文计划 effect](flash-plan-effects-zh-Hans.jpg) | 同上；阶段 effect 不低于 Catalog 中任一步骤 |

这些操作不连接 Runtime、不读取真实敏感文本、不创建真实 Job。
