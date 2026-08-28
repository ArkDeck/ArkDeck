# Goal 真机修复设计参考

2026-08-27—28 · 基线 `e1d52e68` + 后续 F24–F37 修正。三十三张设计样本均已查看。
真机执行与原生 App 证据另见[验证记录](real-device-validation.md)，不由这些图片证明。

下表保留 F24–F37 的原采集版本，不作为 F38/F39 验收。用户手动恢复预览后，
F38/F39 的新截图与验证已补齐，见文末「F39 History 回访与交互修正」。

浏览器实际 viewport 为 1280×720；前七张使用 1180×760 reference window，后续二十六张使用默认自适应窗口。截图保留原始 JPEG，
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
| [英文最新 Flash](flash-activity-retained-en.jpg) | 两条旧 unknown 已有 Runtime 恢复关系，活动卡只显示更新的 canonical 成功摘要；不展示详情时间线，不改写旧记录 |
| [中文最新 Flash](flash-activity-retained-zh-Hans.jpg) | 同上；状态、只读说明与入口同步 App |
| [英文精确 History](flash-activity-history-en.jpg) | 从卡片打开 exact S-0826-01；清除旧筛选和滚动位置，保留旧 unknown 行 |
| [中文精确 History](flash-activity-history-zh-Hans.jpg) | 同上；详情与选中行一致 |
| [英文 unknown 优先](flash-activity-unknown-en.jpg) | 较旧但未解决的风险优先于较新成功；无下一次刷写入口 |
| [中文 unknown 优先](flash-activity-unknown-zh-Hans.jpg) | 同上；按钮仅查看对应 Job，不恢复或重试 |
| [英文 Journal / Artifact](flash-history-artifacts-en.jpg) | exact History 展开后显示 Journal 摘要和逐项 Artifact；缺失大小/哈希保持未报告，窄栏按钮完整可见 |
| [中文 Journal / Artifact](flash-history-artifacts-zh-Hans.jpg) | 同上；不按 Flash 类型生成旧 plan.json / flash.log |
| [英文精确导出预览](flash-history-export-en.jpg) | 选择 post-flash-hilog.txt 后预览同一敏感文件；取消，没有实际导出 |
| [中文精确导出预览](flash-history-export-zh-Hans.jpg) | 同上；标准 flash-report.json 另按 standard 预览，不误报为敏感文件 |

这些操作不连接 Runtime、不读取真实敏感文本、不创建真实 Job。


## F39 History 回访与交互修正

2026-08-28 · 基线 `71eb0b07`。用户手动打开本机 HTTP 预览后，在同一标签完成
中英文实际点击；未切换浏览器或绕过 URL policy。下列 **34 张原始 JPEG** 均已查看。
实际 viewport 为 842×750；侧栏开/关分别检查约 510/760 CSS px 的 History 内容区。
宽栏图使用 `?reference&page=history&flashHistory=retained&lang=en` 的 1180×760 CSS
窗口并隐藏侧栏；fullPage 输出保留额外画布，不是重绘或逐像素 App 对齐证据。
其他图从 `?page=history&lang=en` 开始，按图示选择活动、打开详情/来源/导出并切换语言。
unknown 使用 `flashHistory=unknown`；Inspector 使用 `jobState=unknown`；深色使用
`appearance=dark`。参数都是设计样本，不触发 Runtime。

六类共 21 个样本 Artifact 完成双语逐项预览（42 次）；确认只显示演示结束、未写入文件。
三个未通过检查尝试及后续复测均保留，不称为零失败的一次批次。
[完整验证与图片哈希](history-readonly-verification-2026-08-28.json)同时记录字段检查、
来源边界、构建结果和旧真机/原生证据链接。

| 状态 | English | 简体中文 |
| --- | --- | --- |
| Debug 来源 | [English](history-readonly-context-debug-en.jpg) | [简体中文](history-readonly-context-debug-zh.jpg) |
| Device 来源 | [English](history-readonly-context-device-en.jpg) | [简体中文](history-readonly-context-device-zh.jpg) |
| Diagnostics 来源 | [English](history-readonly-context-diagnostics-en.jpg) | [简体中文](history-readonly-context-diagnostics-zh.jpg) |
| Flash 来源 | [English](history-readonly-context-flash-en.jpg) | [简体中文](history-readonly-context-flash-zh.jpg) |
| Trace 来源 | [English](history-readonly-context-trace-en.jpg) | [简体中文](history-readonly-context-trace-zh.jpg) |
| Viewer 来源 | [English](history-readonly-context-viewer-en.jpg) | [简体中文](history-readonly-context-viewer-zh.jpg) |
| 精确 Correlation / Session | [English](history-readonly-correlation-en.jpg) | [简体中文](history-readonly-correlation-zh.jpg) |
| 深色证据与外观标签 | [English](history-readonly-dark-en.jpg) | [简体中文](history-readonly-dark-zh.jpg) |
| 即时搜索空态 | [English](history-readonly-empty-en.jpg) | — |
| 窄栏证据独立滚动 | [English](history-readonly-evidence-compact-en.jpg) | [简体中文](history-readonly-evidence-compact-zh.jpg) |
| 展开的精确筛选 | [English](history-readonly-filters-en.jpg) | — |
| Inspector unknown 身份与完整状态 | [English](history-readonly-inspector-unknown-en.jpg) | [简体中文](history-readonly-inspector-unknown-zh.jpg) |
| 旧取消记录不补造事实 | [English](history-readonly-legacy-cancelled-en.jpg) | — |
| 侧栏展开的单栏列表 | [English](history-readonly-list-en.jpg) | — |
| 类型化输入 | — | [简体中文](history-readonly-parameters-zh.jpg) |
| 精确敏感导出预览 | [English](history-readonly-sensitive-export-en.jpg) | [简体中文](history-readonly-sensitive-export-zh.jpg) |
| 标准导出演示未写文件 | [English](history-readonly-standard-export-en.jpg) | [简体中文](history-readonly-standard-export-zh.jpg) |
| 摘要字段 | [English](history-readonly-summary-en.jpg) | — |
| 未解决 unknown | [English](history-readonly-unknown-en.jpg) | [简体中文](history-readonly-unknown-zh.jpg) |
| 宽三栏保留原 unknown | [English](history-readonly-wide-retained-en.jpg) | [简体中文](history-readonly-wide-retained-zh.jpg) |

## F40 Recovery 精确 History 与全局入口

13 张原始 JPEG，实际 viewport 1280×720，均已逐张查看并核对尺寸/哈希。
中英 48 条浏览器断言覆盖八个主页面、动态设备详情与信任、独立窗口排除、五种提示及
精确/重复跳转；原型数据不连接 Runtime/设备。8 张原生修正前后 PNG 与一张含既有样本
connect key 的设计图仅保留本机。原生最终五项用例通过，属于 fixture；现有真机 Flash
只读复核单独分类，不新增设备执行。完整过程见
[F40 验证记录](recovery-exact-history-verification-2026-08-28.json)。

| 状态 | English | 简体中文 |
| --- | --- | --- |
| 全局 unknown / 人工处理 | [English](recovery-family-en.jpg) | [简体中文](recovery-family-zh-Hans.jpg) |
| 同一列表内的等待归档 / 等待恢复 | [English](recovery-family-lower-en.jpg) | [简体中文](recovery-family-lower-zh-Hans.jpg) |
| 清除旧筛选并定位精确 Job | [English](recovery-exact-history-en.jpg) | [简体中文](recovery-exact-history-zh-Hans.jpg) |
| 安全边界仍只读回访 | [English](recovery-safe-en.jpg) | [简体中文](recovery-safe-zh-Hans.jpg) |
| 等待归档不提供归档动作 | [English](recovery-archive-en.jpg) | [简体中文](recovery-archive-zh-Hans.jpg) |
| 深色 unknown | [English](recovery-dark-en.jpg) | [简体中文](recovery-dark-zh-Hans.jpg) |
| 深色精确详情展开 | [English](recovery-dark-detail-en.jpg) | — |


### F41 · 有界恢复区（2026-08-28）

五类未决记录按总数和滚动区域呈现，History 保留操作空间；窄窗筛选可展开，搜索不随记录滚动。以下四张均为 1280×720
浏览器演示原图，已逐张查看，不是真机或原生 App 截图：

- [英文列表起始](recovery-family-layout-en.jpg)、[英文末项的精确 History](recovery-family-last-record-en.jpg)
- [中文列表起始](recovery-family-layout-zh.jpg)、[中文末项的精确 History](recovery-family-last-record-zh.jpg)

[验证记录](recovery-bounded-layout-verification-2026-08-28.json)分别记录浏览器、全量闸和
原生尝试；系统 automation 初始化失败不计为断言通过。2026-08-29 的最终原生回归
通过九个连续阶段，中英文各启动一次 App，保留原六个用例的断言与每阶段 PID 证据。
它使用呈现夹具，不证明真机执行；原型键盘及外部点击关闭仍未验收。

重复本组回归只需运行这个入口，不再逐一启动旧用例：

```bash
sh scripts/ci/run-ui-tests.sh \
  -only-testing:ArkDeckHDCUITests/AppShellUITests/testHistoryAndRecoveryContinuousSessionInBothLanguages
```
