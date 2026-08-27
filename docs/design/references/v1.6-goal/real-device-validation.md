# Goal 真机验证记录（进行中）

日期：2026-08-27—28。此记录只描述已实际执行的步骤，不声明全部页面或全部 Golden Journey 通过。
原始 receipt、状态、敏感 Artifact 和原生截图留在本机 `/private/tmp/arkdeck-ui-goal-real-20260827/`，
不写入仓库。可提交的选择性元数据见 [real-device-metadata.json](real-device-metadata.json)。

## Runtime 与执行边界

- 使用已安装、签名的 protected-main `09c44c16` Runtime；当前 `e1d52e68` 基线相对它仅增加 Diagnostics UI 命名修正。本轮未替换 Runtime。
- 新请求通过已发布 typed CLI；设备身份、fresh binding、plan 与 capability 均由 Runtime 验证。没有 raw HDC、外部 shell、authority 注入或 unknown replay。
- Runtime 与工作区 Catalog digest 一致：`b8c7148fc7cd9f7a413167262a6d44bf35e049a62a94613f3a94248ab08784ce`。
- 同一 USB 设备；binding revision 4；设备只保留 stable identity 的 SHA-256，不记录原始序列号或 connectKey。

## 已执行的设备步骤

| Operation | Job | 结果 |
| --- | --- | --- |
| `observe.device@1` | `job-704b93164b06d96278528e3c27335e7a` | execute/readOnly；succeeded；3 个经字节校验的 Artifact；无 unknown / blocker |
| `capture.diagnostics@1` | `job-c0df89f6b6f6d12997666448c25010db` | execute/deviceMutation；Runtime-owned capability；succeeded；9 个发布 Artifact；无 unknown / blocker，清理无残留 |
| `capture.screen-sequence@1` | `job-bb6e9a12d4c005dd329d9f4db0a8d109` | 原生 App 发起；execute/deviceMutation；40 帧成功读回、清理无残留；本机 .mov 已显示 ready |
| `capture.diagnostics@1` | `job-e8d650ad2fdb55d9a61c17488806e4f5` | 原生 Viewer 发起；execute/deviceMutation；截图与 173 个节点成功读回；无 unknown、清理无残留 |
| `debug.hap@1` | `job-ff7578b8e20756c2aeb6406e6d0c9e78` | 已签名的单入口包；install/process readback 与有界 HiLog；succeeded，无 unknown / blocker |
| `deploy.native-library.app-owned@1` | `job-5e0d1123a7a3512c28ffeadfb7744bf4` | 已签名 armeabi-v7a 库；hashProcessAndMaps 验证哈希、进程及实际加载；succeeded，无 unknown / blocker |
| `debug.hap@1`（entry + feature） | `job-7dd6c251aa54620e77b24134c693cb85` | 当前 r4 重新导入两个包；同一目录安装、启动/进程读回、停止/卸载和清理全部完成；无 unknown / blocker / residue；不证明 App 多选或 HSP |

诊断请求为 5 秒，bounded ringBuffered，HiLog + UI Dump + UI tree + PNG + Trace；
Trace categories 来自该目标的 fresh probe，使用 sched/freq/ace/app，8192 KiB buffer，128 MiB 总预算。
capture-summary 显示 complete、missingRequired 为空。14 条清单中的另 5 条是未请求的可选文件，
不把它们算成已发布 Artifact，也不因此伪造 partial。

同一 raw Trace 随后通过 `analyzer.summarize-trace@1` 做本机只读解析，
Job `job-1135caed2f0ca45f14222dbd8002ebc4` 成功；摘要 2,286 bytes，SHA-256
`b48ee7da4a30761fafa50fa4e1aa5d78c8fcee404d52a33349e6faeb330f97d9`。
来源 Trace SHA-256 与采集一致；解析出 5.736493 秒、84 process、255 thread、4,408 CPU slice、
54 named slice。数据质量报告含 dropped/unavailable/probeTruncated 警告，未隐藏，也不解释为零丢失。
这证明真实 Trace 的解析链路，不是新增设备操作或原生 timeline 呈现通过。

## 实际 App 验证及发现

使用工作区原生 App，未启用 Runtime/设备 fixture：History 打开上述 exact Job，新增 Diagnostics
入口加载同一 Session 的 summary、index、marker metadata，显示无法对齐；没有自动读取 raw 文本。
显式读取 HiLog 触发 `diagnostics_preview_not_utf8`，揭示真实日志含非 UTF-8 字节。
Diagnostics → Trace 又因原始 workspaceKind 为 viewer 被旧 guard 静默拒绝。
对应 F24/F25 已修改源码；更新构建后双语 XCUITest 已通过（1 case、245.808 秒、exit 0），
验证 exact Job / Session、complete、无法对齐、显式真实 HiLog 预览及真实 Trace timeline / search。
四张原生附件逐张查看，哈希见 [native-ui-verification.json](native-ui-verification.json)。
该次回访没有新增 Job；库存仅增加测试前已执行的 Trace 摘要分析。

此前两次 opt-in XCUITest 批次在启用 automation mode 时超时（exit 65），断言未开始。
这不等于产品断言失败，也不等于通过。原生 Computer Use 的早期观察与后来的 XCTest 分开记录。
逐图检查又发现 Trace 文件信息的两个标签漏译、稿件默认误选首个事件，F27 已修正并扩展真机断言。

后续五项真机 UI 批次于 2026-08-28 结束：**4 通过、1 失败，exit 65**。
Diagnostics/Trace 双语（含 F27 标签）、exact History 回看、40 帧录屏和 Viewer capture 通过；
冷启动为 4.223 秒，未达到现有 2 秒要求。单项重跑仍为 4.644 秒；该期间主机还有其他项目构建，
不据此单独归因。改动前 `e1d52e68` 隔离基线也失败，实测 7.647 秒；这仍不是排除全部主机
负载变量的性能比较。F28 的显示缓存源码已补回归，尚未安装到受保护 Runtime。六张原生截图已逐张查看。
该批次仅新增上述录屏、Viewer 两个 Job，均为 succeeded；不存在回看重放。
各用例时长、图片/日志/视频哈希及脱敏 Job 结果见 [ui-batch-verification.json](ui-batch-verification.json)。
录屏显示实测 1.29 fps；App 在显示 ready 前已用 AVFoundation 读回视频轨、尺寸和时长。
本机 ffprobe 因缺失 libass 动态库不能运行；改用系统 AVAssetReader 独立解码成功，
实际 40 帧、720×1280、30.943 秒，PTS 严格递增。视频 SHA-256 与原始 .mov 一致；
没有把一次工具启动失败记为视频失败，也没有安装或修补系统依赖。

单包 HAP 与 Native 的精确输入哈希、绑定、策略、readback Artifact 和 receipt 哈希见
[debug-real-verification.json](debug-real-verification.json)。导入器先拒绝了一份没有 ELF 签名的库；
随后用既有已签名测试产物重新进行标准导入/验证并执行，没有修改签名规则或绕过拒绝。
Native receipt 未记录设备型号/固件观察项；History 保持显示“—”，不从其他 Job 补造。
原生回访确认两项 exact Job 分别打开 Apps / Artifacts 标签；表单是新草稿，未自动重新提交。

F25 的真实 HiLog 编码提示已通过 Computer Use 在屏幕上检查（中文）：截断范围与替换字节提示
均可见，原始 Artifact 与 SHA-256 不变。上述只读回访截图逐张查看，实际媒体类型为 JPEG；
图片只留本机，哈希和观察范围见 [manual-native-verification.json](manual-native-verification.json)。

F29 原生 App 多包执行于 2026-08-27T17:35:19Z—17:35:35Z 完成：
`job-2c4e67f6d107999cc5a996403387ac3a` 由真实文件选择器选中 entry + feature HAP，
经生产导入与一次 `debug.hap@1` 提交，绑定 r4，安装/进程回读、停止、卸载、暂存清理均成功。
Runtime 报告无 unknown、残留为零。三份 Artifact 已本机导出并独立核对字节数/哈希；
输入和 plan digest 读取该 Job 的只读记录，不重放 Job。诊断时长 30 秒是请求上限，
并非实测连续日志时长。HSP 的 53 字节选择样本仅用于本地 UI 检查，从未导入或执行。
选择、重复拒绝、移除与清空已由 Computer Use 检查；自动化两次停在系统初始化，没有执行断言。
F30 再修正移除按钮的标识覆盖，补 Bundle/Ability 持续可见标签及“卸载 + 保持运行”的中英文说明。
最新构建的中文警告与填写后的两项标签已在屏幕上核对，未提交新安装请求。
分栏 contain 修正后，AX 已独立报告 `debug.apps.runningCleanupHint`；保留/运行及保留/停止时均无警告。
附加区与文件行 contain 已在实际 App 复查，HSP 文件名和移除按钮保持独立标识。
入口文件名仍与下方说明合并，改为显式 accessibility element/label 后重建 App，确认空状态和文件名
独立读出；随后补静态文本 trait 和既有用例的角色断言，最终角色的原生复验仍待完成。
中文四种策略组合、重复拒绝、提交禁用、移除清错及清空均已通过 Computer Use 检查，未提交安装。
Device stale-frame 原生用例也停在系统 automation mode 初始化（exit 65），没有执行任何用例断言；
日志显示测试会话授权成功，自动化模式等待 60 秒超时。没有更改系统权限或把超时记为通过。
只读采样发现旧测试服务停在本地认证同步等待，并确认此前 SIGTERM 并未让它退出，重启记录已更正。
之后确认旧服务退出，再次独立运行仍在初始化超时；[五次尝试](native-ui-initialization-attempts.json)
保留日志哈希，没有一次开始用例断言。Computer Use 恢复后补完上述中文检查，但打开 Settings 后
其服务在 Array.remove 调用中崩溃；独立窗口读取也超时。原生英文提示、最终文本角色及剩余 Device
交互尚未复验，不能把服务恢复或编译当作通过。

真实 Trace 的中文交互已补 Computer Use 核查：键盘选择 `thread_state:967`，检查器显示
hilogd（PID/TID 198）、开始 570.566 ms、时长 8 µs；拖选 413.904 ms—1.908 s 后显示
范围聚合，缩放保留该范围，重置与 Escape 恢复文件信息。标尺创建 1.161 s 的本机标记，
重命名后重载同一 Trace 仍保留；随后删除本次测试标记。四张截图均已查看，未发起设备操作。
这证明这些 UI 状态与真实来源的接线，不替代对全部分析指标的独立数学验证。

## 剩余验证

- 真实 HiLog 编码提示及 App entry+feature 一次提交已有实测；HSP 真机安装尚未验证。F29/F30 原生自动化与最新构建手动复查继续。
- Trace timeline/search 与双语入口已通过；中文事件/范围/缩放/本地标记流程已补手动核查，其他未记录状态不外推为通过。
- 冷启动 2 秒要求仍未通过；Viewer capture、40 帧录屏及独立视频解码已通过，继续其余适用设备流程。
- 29 个 operation 当前有 26 个 available；`analyzer.summarize-hilog@1` 报未实现；两种 Flash operation 缺 ArkForge bundle 配置。不可将 unavailable 的稿件演示当成真实执行。
- 最新全量闸覆盖 F28–F30 生产代码并退出 0：Swift 调度 1,826 + 1 identity race + 5 scale = 1,832 项，所有车道成功，SDD/catalog/零漂移与 App/UI-test bundle 编译通过。F31 只改设计、测试与参考图，另行通过 40/40 设计交互和设计包构建。详见 [local-gate-verification.json](local-gate-verification.json)。
- 原生文件选择和 Device stale-frame 尚未通过；五项真机 UI 批次也不是全绿。编译、合约与设计测试均不替代这些断言，不调低验收要求，goal 仍未完成。
