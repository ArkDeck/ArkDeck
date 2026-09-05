# Goal 真机验证记录（进行中）

日期：2026-08-27—28。此记录只描述已实际执行的步骤，不声明全部页面或全部 Golden Journey 通过。
原始 receipt、状态、敏感 Artifact 和原生截图留在本机 `/private/tmp/arkdeck-ui-goal-real-20260827/`，
不写入仓库。可提交的选择性元数据见 [real-device-metadata.json](real-device-metadata.json)。

2026-08-28 最新续验见[后续元数据](followup-verification-2026-08-28.json)：
已更新 protected-main Runtime，真实 App entry+shared HSP、原生双语选择器、冷启动和
stale-frame 均已有通过结果。随后 Flash 真实请求在设备副作用前被硬件资格门拒绝，
见[Flash 续验](flash-hardware-gate-verification-2026-08-28.json)。随后获得明确 HardwareCampaign
授权，新 canonical Flash 已成功，详见下节与 [F34 元数据](flash-canonical-verification-2026-08-28.json)。
下文旧批次的失败保持历史含义；不声明 goal 完成。

## 2026-08-28 授权 Flash 结果

在 PR #1568 合入后，重新核对目标 `TGT-958780b2ffb7` / r4 与镜像 SHA-256
`4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674`，通过已发布 CLI
启用获授权的 `ui-alignment-20260828` campaign，使用 fresh exact plan 提交一次新请求。
`job-8e32139af1945d755f5716b67f4f8bde` 于 03:21:37Z—03:24:27Z 执行成功，
machine readback 为 OpenHarmony-7.0.0.37 / r4，unknown=false、residue=0。
Runtime 独立验证的 terminal、trusted evidence、postflight、Artifact 与连接健康检查均通过；
三份输出的大小与哈希保留在元数据，raw 输出不提交。

随后 campaign 关闭，所有安装配置恢复启用前原值；新的 `observe.device@1`
`job-7b17f20b5619f24d61145f4c4b8dec0e` 成功。原四条终止 unknown 与首次未执行请求不变，
没有重放 unknown。具名硬件验收成功不等于产品生产资格或 notarized distribution 验收。

真实 App 的 History/Flash 只读回访发现 F34（canonical 记录筛选与详情引用过旧）及
F35（App 沙箱直接访问 Unix socket）。F34 已随 #1569 合入；F35 在 #1570 将只读探测移到
Runtime XPC，完整本地闸、44 项设计测试与三项双语原生 fixture 回归通过。
两项修复后的真实 App 只读回访仍未完成，详见 [F35 元数据](flash-device-access-verification-2026-08-28.json)。
不把 fixture 当真实设备结果，也不为 UI 回访重复擦写。下文“剩余验证”保留此前历史快照，
当前 Flash 硬件结论以上述新记录为准。

## Runtime 与执行边界

- 首批使用已安装、签名的 protected-main `09c44c16` Runtime；当时 `e1d52e68` 基线相对它仅增加 Diagnostics UI 命名修正。后续已通过发布安装入口更新到合入的 `2f05ea02`，哈希及四条历史 unknown 记录不变核对见后续元数据。
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

## 2026-08-28 原生与 HSP 续验

App 生产代码基线 `86b284d0`，Runtime `2f05ea02`，Catalog digest 不变。系统认证恢复后，
首轮两项测试实际运行并失败：中文菜单点击落在可见 picker 上方 21pt；冷启动为 3.643 秒。
只修正测试点击方式为激活窗口、滚动至控件、使用当前 frame 中心，未改策略或删减断言。
同一双语选择器用例随后通过（416.121 秒），覆盖四种生命周期组合、入口文件名及 staticText
角色、HSP 添加、重复拒绝、提交禁用、移除和清空。两张原生附件已查看；该用例仍是 fixture
选择测试，不是 HSP 安装证据。冷启动独立重跑通过，实际设备行显示耗时 **0.994 秒**，
测试总时长 3.906 秒不是启动指标；2 秒要求不变。组合批次失败保留，不声称性能普遍达标。

另用现有官方 SDK 测试签名材料在私有目录为真实 entry + shared HSP 生成同 bundle 的签名，
未改全局签名预设、Keychain 或 Runtime 信任事实。App 实际选择两个包并提交一次新 Job：
`job-b6762567bef468c88ac8dc536a06a932`，01:24:13Z—01:24:28Z，succeeded。
Runtime 导入的两个完整 SHA-256 与本地签名产物一致；install/process readback 成功，
HiLog 含由 shared 模块函数输出的唯一标记 `ArkDeck HSP acceptance 20260828`。
停止、卸载、暂存清理均 confirmed，unknown=false、residue=0；三份 Artifact 大小及哈希核验通过。
安装报告不枚举模块名，所以共享模块运行证明另取其真实函数日志。先前两次错误 profile 的失败不改写。
最近 Job 列表经截图核对与 Runtime 一致，AX 文本相邻行合并不误记为状态错误。

stale-frame 原生用例通过（27.144 秒）：测试点来自最新锁屏空白画面，归一化坐标 (0.5, 0.73)。
首次点击 confirmed 后出现过期标记，第二次点击拒绝，等待后无新输入结果，重新截图清除标记。
完整时间窗口内恰有 `capture.diagnostics@1`、`input.tap@1`、`capture.diagnostics@1` 三个新 Job，
均 succeeded / 零 unknown / 零 residue；唯一输入为 `job-3cd710c28da0892be31b861603732c4a`。
三张附件逐图查看且仅留本机。首轮未加 `TEST_RUNNER_` 导致 opt-in 未传入 runner，测试跳过，
没有设备动作；按仓库既有方式重跑才是本次通过结果。未更改系统安全设置。

## 剩余验证

- HAP/HSP 实际安装、共享代码运行和原生双语选择器均已有通过结果；未把历史错误签名尝试或 fixture 算作硬件通过。
- Trace timeline/search 与双语入口已通过；中文事件/范围/缩放/本地标记流程已补手动核查，其他未记录状态不外推为通过。
- 冷启动独立复测达到 2 秒要求；Viewer capture、40 帧录屏、独立视频解码及 stale-frame 原生交互已通过。各次运行范围单列，不声称所有用例在同一批次全绿。
- 安装 pinned ArkForge 后曾报告 28/29 个 operation available；这包含两种 Flash 入口的误报（F32）。收到指定设备/镜像的擦写授权后，`job-e9e5e3d7ae56af47ef69c94079fa6652` 实际提交一次，exit 1、failed、`executionConfirmedNotPerformed`，零 unknown / residue，ArkForge 在 startExecution 前拒绝；不是硬件通过。额外启用 HardwareCampaign 的配置审批被拒，未执行配置修改；不得把擦写确认当作该额外授权，也不重放原请求。`analyzer.summarize-hilog@1` 仍如实报告未实现。
- 最新全量闸覆盖 F28–F30 生产代码并退出 0：Swift 调度 1,826 + 1 identity race + 5 scale = 1,832 项，所有车道成功，SDD/catalog/零漂移与 App/UI-test bundle 编译通过。F31 只改设计、测试与参考图，另行通过 40/40 设计交互和设计包构建。详见 [local-gate-verification.json](local-gate-verification.json)。
- 本次 picker 测试修正的路径分类器最终闸退出 0：SDD 0 errors / 0 warnings、catalog 49 tests 与零漂移、App/UI-test bundle 编译通过；仅测试/文档改动，未选择 Swift package 车道。40 项设计测试也通过，日志哈希见后续元数据。Flash 尚未通过，goal 仍未完成；编译、合约与设计测试不替代真机断言。

## 2026-08-28 Flash 与 F35 合入后续验

上节保留的是 F31 之前的验收状态，不代表最新 Flash 结果。具名 HardwareCampaign 获得授权后，
canonical Flash `job-8e32139af1945d755f5716b67f4f8bde` 已真实成功，三份 postflight Artifact
独立核验通过，随后关闭 campaign。F34/F35 分别修复 canonical UI 关联与沙箱内只读探测。

F35 PR #1570 合入 `f18ca0c7` 后，官方 helper 构建/签名和 Runtime 更新完成；真实中文 App
两次重新检查均通过 Runtime 返回空 RockUSB 观察，正确显示离线或未进入 Loader，无 socket
错误或 Loader 就绪误报。首次设备观测未找到匹配目标而失败，unknown=false / residue=0；
随后标准 Agent Observe `job-fa633ec83c9a19986c543cdbcb4c2302` 成功，原目标与 r4 绑定不变，
机器回读 OpenHarmony-7.0.0.37；独立终态、postflight、可信证据、Artifact 与通道五项核验通过。
未重绑或再次刷写。前后 Job 清单只增加这两次 readOnly Observe，四条旧 unknown 逐项保持不变。

F35 的真实诊断路径已复验，但发现 F36：旧已恢复 unknown 在 Flash 活动中遮住最新成功，
记录入口未精确选择 Job。正在同一垂直修复中补齐展示、设计与回归；合入后的真实只读 App
复验仍待完成。原生 F36 测试四次停在系统初始化，不能用设计样本或编译代替断言。
选择性 metadata、哈希和失败记录见 [F35 验证记录](flash-device-access-verification-2026-08-28.json)。

F36 最终 App 的隔离双语手动检查已通过活动选择和 exact History 跳转，旧 unknown 行保留；
真实 Runtime Job 清单前后完全一致。该记录属于 fixture UI，不是硬件验证，亦不是 XCTest 通过。


## 2026-08-28 F36 合入后的双语真实 App 回访

PR #1571 合入 `3a9474f1` 后，原生 fixture 测试通过（45.738 秒），实际生产 XPC 回访也
通过（93.497 秒），各 1 项、零失败。两者分别分类：前者不连接设备，后者读取 reviewed
Runtime 的真实 Flash 与保留历史，没有设备或 History fixture，也没有再次刷写。

真实回访在中英文均确认最新 canonical 成功活动、只读设备访问及重新检查、exact History
详情和 Artifact、返回 Flash 的 exact Job 上下文，以及四条旧 unknown 保留。前后 1,962 条
Job 全部逐项相同，已有成功 Flash 的五项独立核验仍通过，HardwareCampaign 关闭。
八张实际 App 与两张 fixture 原始 PNG 均已查看，raw 截图/日志仅保留本机；仓库只记录哈希。

临时验收方法的前三次失败/中断来自错误等待元素、布局变化后的旧点击坐标、摘要时间线
假设和带标签的 AX 字符串匹配，已如实保存；没有改生产行为来迎合断言。验收方法完成后
恢复原文件并确认与 reviewed main 整树一致。

对照还发现 F37：稿件把摘要页没有的 Journal 与过期 plan/log 文件放到了 Flash 展示中。
本轮将稿件改为摘要/详情分离和精确 Artifact 预览，不把设计截图当硬件证据。
完整命令范围、二进制/截图/日志哈希与失败记录见
[F36 post-merge 元数据](flash-history-focus-verification-2026-08-28.json)。


## 2026-09-02 全功能 CLI headless 复跑（digest `508783ac…`）

按 `docs/design/cli-golden-journey-headless-runbook.md` 在当前 Catalog digest
`508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684` 上，只用已发布 `arkdeck`
CLI 面对同一台 DAYU200（`TGT-958780b2ffb7`，binding revision 4，hdc 3.2.0f，固件
OpenHarmony-7.0.0.37）headless 复跑五条 Golden Journey，并做了 `debug.template@1` smoke。
脱敏记录（只留 SHA-256、jobId、executionId、计数与 UTC 时间）见
[gj-headless-rerun-2026-09-02.json](gj-headless-rerun-2026-09-02.json)，其中
`operationRealDeviceCoverage` 给出 29 个 canonical operation 的真机覆盖矩阵。2026-09-03
补跑后为 29 个 `realDevicePass`、0 个 `notExercised`；每个 operation 的代表 Job ID 均记录在
同一脱敏文件中。

| Journey | 四态 | 关键事实 |
|---|---|---|
| GJ-1 Device Observe | `REAL_DEVICE_PASS` | `agent run`/`job submit` 两条路径的 `observe.device@1` 各一次 succeeded；设备级 `capture.diagnostics@1`（hilog + ui-dump）；`runtime service restart` 后两条 Job 仍可读；§2.1 HAR crash-resume：拔线后 `agent run` exit 75/`newDispatchCount 0`，仅凭 execution ID 重取到 waiting action 与逐字相同的 `resumeReference`，插回后 resume（经一次 `ambiguousIdentity` 确认）继续到 `succeeded`，target/binding r4 不变 |
| GJ-2 HAP Debug | `REAL_DEVICE_PASS` | `debug.hap@1` 完整周期、retain/running、bundle 级 diagnostics（hilog/ui-dump/ui-tree/screenshot/trace/liveness）、cleanup |
| GJ-3 Native Debug | `REAL_DEVICE_PASS` | `deploy.native-library.app-owned@1` 的 verify-remote-staging/backup/atomic-publish/restart/verify-loaded-library；幽灵依赖候选触发 `rollback-native-library` 与补偿 cleanup |
| GJ-4 Flash Recovery | `REAL_DEVICE_PASS` | canonical `flash.full-restore@1` 经命名 campaign 的 Runtime capability 提交，ArkForge 23/23 步、readback OpenHarmony-7.0.0.37、残留 0，campaign 用后即关（lane 回到 hardwareGated） |
| GJ-5 Bounded AI Debug Loop | `REAL_DEVICE_PASS` | 复现（retain/running → 窗后 liveness `UNHEALTHY`/`targetProcessNotRunning`、crash-index 恰一条、`analyzer.extract-crash-signature@1` answered）→ `workspace isolate/patch/build/sign`（隔离副本、Runtime 自动签发 capability）→ 签出 HAP `artifact export` + `artifact import hap` → `debug.hap@1` 复验（install-readback 钉到 signed.hap SHA-256，启动后 43 s liveness `HEALTHY`，crash-index 不变）；负向 stale revision 被 `workspace.revisionConflict` 拒且台账零新增 |

复跑本身暴露并修掉的产品缺陷（每条都在当前 digest 上用 CLI 复现后修复、再实测通过）：

- Runtime 启动：真机 hdc 3.2.0f 的 dual-stack 监听被 managed-server 身份检查拒；执行台账时间
  形式非毫秒规范（PR #1694）。
- GJ-5 修复腿：CLI 导入的补丁 lease 绑设备 target 而 host-only 请求绑 projectRef
  （PR #1696）；隔离副本不在 2.x 项目注册表、legacy `--workspace-project` 根下注册 preset
  不可用、sign 步骤 validator 钉常量、durable-history 校验在 77 行 legacy 行与 4 个旧 digest
  `waitingForRecovery` Job 上 fail-closed（PR #1699）；DevEco 自动签名凭据无法 headless 安装
  （PR #1700，`runtime signing install --build-profile`）。
- Runtime service legacy workspace 清理：2026-09-02 用同一 Team provisioned 的本机候选执行
  当前 `runtime service update`，省略 workspace/SDK path 后回执与 status 均不再含旧根，plist 的
  5 个 workspace/analyzer 环境键全部消失；服务保持 ready、digest 不变、HDC/ArkTrace/ArkForge
  identity 不变。`demo-app` 与 build/signing preset 仍为 active，target/binding 仍为
  `TGT-958780b2ffb7` / r4，最新 Job 仍是更新前的
  `job-cf76e61adb789f8b2bda5172a490d803`，4 个 `waitingForRecovery` unknown-outcome 历史原样保留。
  legacy `agentd update` 的 omission-preserves 行为由 compatibility test 冻结。
- Project lifecycle：当前 digest 上，派生 workspace 的非终态
  `workspace.read-source-range@1` Job `job-b475fb7ed5388acd20f58d9790413dc4`
  使来源项目 `demo-app` 的 remove 在 `workspaceProjectOwner` 阶段以 `resourceConflict`
  fail closed；Job succeeded 后同一 remove 越过 active/uncertain 引用扫描并由既有 preset 阻止，
  项目 generation、preset、四条历史 unknown Job 与 residue 均未改变。

运行环境观察（不是 CLI 功能缺陷）：`install-sdk-release` 装的样例 release
凭据对设备不可信（`code:9568329`），可用凭据是 DevEco 为该 bundle 签发、device-ids 含本机
UDID 的 debug profile；本机磁盘低于 4 GiB 预留时 ArkForge prewarm 会以零派发拒绝 Flash。

同日闭合的 preflight 投影缺陷不再列为残留：在当前 Runtime/Catalog digest 上以候选 CLI
重跑 stale `workspace.revisionConflict`，结果为 `ok:false` / `invalidInput` / exit 65，
并包含 `phase: preAdmission`、`newDispatchCount: 0`；2.x Job ledger newest ID 与时间戳在调用
前后逐字相同。

### 2026-09-03 `TASK-AIN-021` 候选收口

在同一 Catalog digest 上，用最终 Team-provisioned arm64 候选补跑原先未单独覆盖的 17 个
operation；涉及设备的行继续使用同一 target 与 binding。候选 CLI executable SHA-256 为
`03385f2f0b42c78bf9d566888376ee4c4dd6d70cbf3e43910dc4cba1f0c3a6e6`，已安装 Runtime
executable SHA-256 为
`b5931c7a144011222ea7934de48371e01cbe624cb1a31301bcd04e62fd24a4d6`，最终服务状态为 `ok`。

- Analyzer/trace：`analyzer.analyze-trace@1`、`analyzer.summarize-trace@1`、
  `analyzer.summarize-hilog@1` 均 succeeded。
- Device interaction：`capture.screen-sequence@1`、tap/long-press/swipe 与 port-forward
  create/remove 均 succeeded；port lowering 修正为 HDC `fport`/`rport` tuple，并以 exact list
  readback 验证。
- Workspace：checkpoint、diff、source inspect/range、patch/revert、tests、sweep 与
  symbolize-crash 均 succeeded。`workspace.symbolize-crash@1` 只接受来自 HDC
  `capture.diagnostics@1` 的 device-bound crash-log Artifact；错误 hilog provenance 在建 Job 前
  拒绝。
- Runtime invariants：跨 Catalog digest 复用同一 execution/idempotency key 返回
  `idempotencyConflict`，没有创建 Job 或产生新 dispatch；隔离副本不再复用绝对路径绑定的嵌套
  SwiftPM `.build` cache。

原来阻止 `TASK-AIN-021` 收口的五类缺陷也已在同一候选中闭合：preflight rejection 发布
`preAdmission`/零派发证据与 exit 65；USB 重插在 fresh exact identity + binding proof 后不再追加
冗余 `ambiguousIdentity` HAR，且被取代 action 的终态正确；`runtime service update` 清除五个
legacy workspace/SDK/analyzer key；派生 Job 保留来源项目引用；App 的 Debug template 统一经
Runtime Job 投影。USB 修复由生产 HAR 合约锁定；2026-09-02 旧执行中出现的第二轮确认仍作为
修复前历史观察保留，不回写成新的真机运行。

Typed workspace sweep 随后删除 3 个本轮覆盖副本；另外 3 个 unknown 或 revision-drifted 副本由
fail-closed GC 原样保留，没有用手工文件删除绕过 Runtime。上述结论是待维护者 review 的候选
证据，不替代 protected `main` 批准。

## 2026-09-02 Debug template 真实 App 投影

使用本分支 Developer ID 签名的 Release App，通过生产 XPC 连接已安装 Runtime；未启用 App、
Runtime 或设备 fixture。Debug → 只读工具只显示四个 approved template，没有自由文本 command、
argv 或 path 输入。首次运行 `device.packageInventory` 得到 succeeded Job，但 UI 没有显示 Runtime
已经发布的两个 Artifact；根因是 Debug 工作区 Job decoder 漏掉 `debug.template@1`，不是 Runtime
或设备失败。补齐 exact operation allowlist 与回归测试后重新构建、验签并运行。

最终 App 创建 `job-60fa9ca0dacfbdabba52db0d116ba691`，clientName 为
`ArkDeckApp.DebugWorkspace.Commands`，operation 为 `debug.template@1`，target
`TGT-958780b2ffb7` / binding r4。Job 于 13:45:23Z—13:45:24Z succeeded，
`actualEffect=readOnly`、`outcomeUnknown=false`、residue 0；Runtime evidence 无 blocker，两个
Artifact 均 published 且 bytesVerified。真实界面同步显示 exact Job、已知终态、两个 Artifact
的名称、大小、digest 前缀、privacy 与各自导出入口；截图已逐图检查，原图只留本机。

构建哈希、签名结果、完整脱敏 Job/Artifact 元数据、发现阶段和截图哈希见
[App Debug template 验证记录](app-debug-template-job-verification-2026-09-02.json)。结合上节的
17 个 operation 补跑与 USB HAR 修复合约，这一 App 投影不再是 `TASK-AIN-021` 的未覆盖项。

## 2026-09-05 单 v1 Runtime 真机复跑窗口：`BLOCKED_BY_PRODUCT_DEFECT`

DAYU200 已接、维护者已批准更新本机 Runtime 并执行 GJ-4；窗口在 runbook §1 的 Runtime 更新处停止：
按 `main e8c4f1df`（TASK-SVC-001 #1733 之后）用 `build-local-helpers.sh` 构建并 `runtime service
update` 安装的 daemon 无法启动——`admitted job job-be448cb20f06aae340e1ccfe5275be81 has no
readable durable record after recovery projection`，launchd 循环重启 248 次，socket 始终不存在。
根因：#1733 把 `RuntimeOperationRequest.schemaVersion` 从 `2.0.0` 改为 `1.0.0` 并精确拒绝其他值，而本机
2,041 条 `job-record.json` 内嵌的提交请求全部是 `2.0.0`；启动恢复投影到第一条非终态（`waitingForRecovery`）
的 2026-08-04 刷机 Job 即失败。没有手工改动任何历史记录；已回滚到 SVC-001 之前的构建，五条 Journey 均未开始，
digest `508783ac` 上的 `REAL_DEVICE_PASS` 仍以 2026-09-02 记录为准。完整事实、复现步骤与归属见
`openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-001/run.md`
（「Real-device window 2026-09-05」）；修复归 CHG-2026-075 `TASK-SVC-002`（durable 记录整合），在它落地前
任何跑过 2.x Runtime 的主机都不能升级到 SVC-001 之后的构建。
