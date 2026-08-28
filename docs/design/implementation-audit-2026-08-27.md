# 规格 / 设计 / 实现全页差异扫描与修正

日期：2026-08-27 · 基线：`e1d52e68db435bdfeb326962767ca4626a77322b`

## 1. 范围与判定方式

覆盖 **8 个主页面、动态设备页、独立 Settings / Trace Viewer / 帮助、所有子标签与关键弹层**，
共 **60 个检查单元、20 个 App View 文件、31 个组件预览文件**。文件、路由和子标签清单由
[机器覆盖表](implementation-coverage.json) 与
[交互/覆盖测试](arkdeck-ds/scripts/workspace-interactions.test.mjs) 核对。

对比顺序是 Safety/POL → PRODUCT-LOOP → living specs / Catalog / contracts → 设计稿 → 实际调用链。
不仅看 View 是否存在，还追到 ViewModel、facade、RPC、参数和 Artifact 校验。主线映射为
GJ-1（设备/观测/Trace/Diagnostics）、GJ-2（HAP）、GJ-3（Native）、GJ-4（Flash）；
GJ-5 的 external Agent 边界用于识别已退役 Automation，不重启旧 task 平面。

本文“已接通/修正”指本工作区代码，不表示已合入受保护 main、真实设备通过或远程设计库已更新。
本轮未修改 accepted requirement / AC / 安全策略，未发布新 operation/provider/profile。
产品修正通过 `agent/ui-design-alignment-20260828` 分支交付维护者审查；提交或合并不替代剩余真机验收。
设计 demo、原生 App fixture、单元/合约验证和真实设备证据分别记录。

## 2. 差异处理

| 编号 | 原差异 | 修正后与保留边界 |
| --- | --- | --- |
| F01 | Diagnostics 按钮只改变本地状态，却显示已布防/已标记 | 删除假状态；arm/mark 保持禁用并说明缺少会话接口 |
| F02 | Overview 查看记录只打开 History，丢失 Job ID | 传递 exact Job；清除旧筛选后选择该记录；原生回归覆盖 |
| F03 | “再次运行”承诺预填，但没有 typed inputs 传递 | 保存原始 JSON；仅校验过的只读 observe/capture 可生成新草稿；显示 thread；明确另行启动新 Job；变更操作/旧 Marker/漂移/unknown 拒绝 |
| F04 | 导航和旧稿仍把 Automation/task.* 画成当前功能 | 八页导航同步；旧链接只说明 CHG-2026-064 退役，历史组件不算产品能力 |
| F05 | Settings 混入主导航，子页不完整 | 独立七标签及 Trace Cache/Licenses；App 内重复更新设置不再作为现行稿 |
| F06 | Trace 非法输入被改成默认值，单位/quick values 与 App 不符 | 保留输入并给出校验；单位转换和快捷值一致；unavailable/invalid submit 不启动 |
| F07 | Debug secondary UI 与真实能力/参数边界不同 | 五页及 SSH browser/editor/plan 对齐；HAP 与 Native 分别镜像 14/11 个 Catalog 步骤；旧不支持能力仍明示 unavailable |
| F08 | App diagnostics 设计允许带 device raw，但 exporter 始终排除 | 删除无效选项；敏感 device Artifact 在 History 单独显式导出 |
| F09 | History 缺活动类别、筛选/保存/分页；按标题猜 Artifact | 首轮补八类、筛选和选择关系；F38 继续纠正按 kind 推断的详情、精确身份与风险筛选，见文末 |
| F10 | 默认 Diagnostics 稿展示完整 ring/视频/校准，误报 current 能力 | 默认镜像当前 reader；完整联动只在 concept URL；纠正“ring/自动 Marker 全未实现”的旧说明：bounded ringBuffered 和部分自动标记已发布 |
| F11 | 全局 Inspector 没有设计中的日志/取消/恢复控制 | 接 exact detail、标准日志按需读取与 fresh identity 后取消请求；unknown 不重放；rebind/archive 没有 App RPC，仍是缺口 |
| F12 | History Diagnostics 分支不读取 Session；publish 无生产调用 | 新严格 reader 读取 index/summary/markers，校验 identity/byteCount/SHA-256、required/completeness；展示 partial/notDerived/无时间/无校准；已发布 Trace 可转交原生 Viewer |
| F13 | 独立 Trace Viewer 的 loaded/search/event/range/mark/dock/help 在稿中缺失 | 增加可操作的合成 loaded 样本、筛选/匹配导航/范围校验与显式应用/本地标注/停靠、loading/error/recent 和完整快捷键；不把样本当真实 Trace |
| F14 | Trace Viewer/Cache/Licenses 普通 UI 英文固定；Debug/授权辅助稿中文固定 | App 普通 UI（含搜索输入的 placeholder/AX label）、恢复说明和帮助双语；使用上游中文 shortcut 字段；稿件次级表单/弹层补英文；raw、进程名与许可证正文保留 |
| F15 | DS 版本/导航/图标过期，25 个组件映射仍缺失 | 补 24 个受控组件覆盖 25 个映射，31 个 previews；新画廊覆盖 empty/partial/unaligned/unknown/stale/disabled；远程设计库未连接 |
| F16 | 九页 briefs 漏入口，历史 HOW 被误当规范 | 补完整索引与明确历史限制；同步本轮真实能力与剩余边界，不刷新旧治理任务 |
| F17 | trust 超时稿直接重启共享 HDC，设备授权与接管混淆 | 超时去 Overview impact/proof；未授权候选深链正确；无 proof 不执行 HDC 恢复；不暗示已接管 |
| F18 | Viewer 只有四标签稿，实际有五种 Inspector | 增加 Advanced Dump、惰性读取/搜索/noNumericIDs/retry/failed；技术字段保持原词 |
| F19 | HAP 已实现，稿仍固定不可用，步骤也过时 | 根据 availability 演示；Catalog 14 步、身份/策略/1–300 秒联动；提交预览不伪造 Runtime Job |
| F20 | Overview sheet 外层 AX 标识吞掉子项 | 明确 contain 分组，说明和按钮可按各自标识访问；回归检查精确来源与 typed draft |
| F21 | 环境快捷键丢失；扫页误查折叠子项；窗口外框被当内容尺寸 | 恢复 ⌘⇧D，明确展开/收起；记录真实 frame/content/layout。尺寸回归验证默认窗未退到最小窗，按实际 native chrome 约束外框；不声称改变了 App 默认尺寸 |
| F22 | Native 计划仍旧 7 步；SSH 未验证可保存；日志/网络字段未联动 | Native 同步 11 步和真实 Artifact 名称；SSH 输入变更使验证失效，demo 不保存秘密；HiLog 五字段与 1–600 秒、512 MiB预算；删除未采集时假日志与旧1GB轮转说明；Native 输入立即更新计划按钮；forward/reverse 明确选择，默认不伪造设备规则清单 |
| F23 | 保存会话读取可能把 JPEG 通道误报为缺 PNG；弱类型参数可能误判 completeness | JPEG/PNG 可满足截图通道，但不豁免单独声明的 required 文件；按请求类型报告缺失，不伪造时间；错误布尔/trace 数组类型拒绝；单测覆盖显式 raw 读取与完整性失败 |
| F24 | 带 UI Dump / Trace 的真实诊断采集归类到 Viewer / Trace，不能进入 Diagnostics reader；Trace 入口又静默拒绝 Viewer 来源 | History 对 exact capture.diagnostics@1 另给只读 Diagnostics 入口，保留原分类和 exact Job；Trace 按确切 operation 与重新校验的 Artifact 接受只读转交，不要求改写来源分类；真机双语 UI 回归通过 |
| F25 | 真实 HiLog 含非 UTF-8 字节，Diagnostics 拒绝整份文本预览 | SHA-256/byteCount 完整校验后，仅 text/plain 允许显示替换字符并醒目标注；JSON 保持严格 UTF-8；原始制品不变，120k 显示上限与 2 MiB 读取上限保持 |
| F26 | HAP App、caller 和稿件仍接受 Catalog 已不支持的 installFresh / restorePrevious | 安装策略固定 installOrReplace，清理仅 uninstall/retain；caller 先拒绝未发布值，保留 retain/running；行为测试与稿件选项对照当前 Catalog，未放宽 Runtime 准入 |
| F27 | 真实 loaded Trace 默认显示文件信息，稿件却自动选择首个事件；两处文件信息漏译 | 稿件默认无选区并展示文件信息，显式选事件才切换检查器；无选区不生成标注；App 文件大小/Schema 指纹补齐双语，真机用例断言这些标签 |
| F28 | 冷启动候选列表虽预热，设备名称/系统版本仍同步等待新 HDC 属性读取；实测超过 2 秒 | 补显示信息预热、独立观察时间和 5 秒缓存；离线/未授权/失败及旧在途结果失效。更新至已合入的 `2f05ea02` Runtime 后，独立真机 XCUITest 实测 0.994 秒，通过原 2 秒门限；同日组合批次 3.643 秒失败仍保留，不外推为所有负载下均达标 |
| F29 | `debug.hap@1` 已发布 additionalHapArtifactLeases，同 bundle 的 feature HAP / HSP 可一次安装，但 App 与稿件只允许一个 entry HAP | App/稿件补入口与最多 16 个附加包的选择、移除和清空；逐文件有界校验/导入后提交同一 Job，拒绝重复文件与绑定漂移。CLI/App entry+feature 已成功；2026-08-28 原生 App 的真实 entry+shared HSP 新 Job 成功，两个导入哈希、共享函数 HiLog 标记及停止/卸载/清理均核验。原生双语选择、静态文本角色、重复拒绝、禁用、移除/清空自动化通过，不以 fixture 代替安装证据 |
| F30 | Apps 同时选择“保持运行”和“运行后卸载”未解释实际结果，填写后 Bundle/Ability 没有可见标签；附加包容器覆盖移除按钮的自动化标识 | App/稿件增加按真实策略显示的中英文提示，不修改已发布策略或静默改值；保留字段标签、文件和移除按钮独立标识。双语原生四种策略组合通过；XCTest 原生 click 命中可见 picker 上方 21pt，改用当前 frame 中心后同一用例通过，未删减断言 |
| F31 | Trace 真机已有时刻标记的重命名、换色、删除和本机重载保留，稿件只有范围标记与保留复选框；清空选区还会隐藏所有标注 | 原型补时刻标记入口、完整范围、临时/保留标记演示、名称编辑/换色/删除；无选区仍显示注释，编辑保留检查器滚动位置。明确原型不落盘，不把演示当真实 sidecar；40 项设计测试通过，真实 Trace 中文事件/范围/标记已手动验证 |

F32（2026-08-28，GJ-4）：ArkForge 通道连接成功被直接投影为 Flash 可用，默认
`hardwareGated` 却只能生成 assessment。真实请求在外层 capability 已消费后才被拒绝，
没有设备副作用。现改为从同一次 composition 传递执行可用性，保留只读 lane；标准和兼容
入口均在 Job/capability 创建前拒绝。具名硬件验收配置不改为生产资格，逐计划的
mechanics/authority seals 与 Runtime 安全门不变。原型增加
`?page=flash&flashState=hardwareGated&lang=en`（或 `zh-Hans`）的受阻状态。
见[本次验证记录](references/v1.6-goal/flash-hardware-gate-verification-2026-08-28.json)。

F33（2026-08-28，GJ-4）：继续检查发现 App 的 `canSubmit` 只检查已有计划和前置条件，
Runtime 刷新为 unavailable 后，同一目标的缓存计划仍可保留刷写按钮。现要求当前
availability 为 available；checking/unavailable 的原因替代主动作，不删除只读计划。
原型同步动作替换语义，原生中英文测试覆盖 available → hardwareGated → available，
不点击刷写。F32 的 PR #1567 在补充验证期间已合入，F33 基于其 merge commit
`b564e990` 单独交付产品修正，不创建状态或验收专用 PR。

F34（2026-08-28，GJ-4）：授权后的真实 canonical Flash 成功，但 App 的活动/attention
筛选和 postflight 详情请求仍硬编码旧 `flash.dayu200`，导致新记录缺席、精确详情关联失败。
现统一使用已发布的 canonical/历史兼容引用分类器，新提交按 `flash.full-restore@1` 读取详情；
只有成功终态、无 blocker 且固件/绑定读回匹配才显示成功。当前稿件与双语可用性文案同步，
不改写旧历史。两项隔离双语原生回归通过，覆盖 unknown、运行中、成功及证据未验证的拒绝；
fixture 不连接 Runtime，不构成真机证明。真实运行与独立核验见
[F34 验证记录](references/v1.6-goal/flash-canonical-verification-2026-08-28.json)。

同次真实 App 检查发现 F35：设备访问诊断直接打开沙箱内 ArkForge Unix socket，路径超限且
不符合 App 的 XPC 边界；该项单独修复，不能用本次刷写成功或 F34 fixture 关闭。

### 关键实现入口

- [Session reader](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/DiagnosticSessionApplicationReader.swift)：fresh correlation、发布清单、两份索引一致性、受限读取、完整性与缺失判断。
- [History facade](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift)：原始 typed parameters 与至多 16 MiB 的显式 Artifact reader；顺序分块和最终 SHA-256；sensitive 需 opt-in。
- [只读延续 caller](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeWorkspaceContinuation.swift)：fresh source/target、Catalog 校验、新 request/idempotency/Job、一次 run；unknown/deduplicated/foreign Job 不继续。
- [取消 caller](../../Packages/ArkDeckKit/Sources/ArkDeckWorkflows/RuntimeJobControlApplicationFacade.swift)：独立于只读 History；fresh job.status 的 Job/operation/target/session 必须一致，已知非终态才发 cancel；请求不等于已取消。
- [新增组件](arkdeck-ds/src/components/session.tsx)与[可交互画廊](session-components.html)：25 个已声明 class 映射对应 24 个组件；输入边界、缺图、缺校准、未知结果不由组件补造。

## 3. 全入口矩阵

以下 **60 个检查单元**均已纳入并完成首轮源码、设计和接线核对；真机与字段级复查继续记录新差异（如 F29）。“已接线”不等于本轮硬件通过。浏览器/App fixture 验证范围见 §4。

### 主窗口、全局层、动态设备（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| shell.navigation | 主窗口、菜单、八项导航、空设备、恢复窗口、更新提示 | 八页完整；Settings/Trace Viewer/帮助独立 scene；Automation 退役 |
| shell.inspector | 折叠/展开、loading/empty/failed/active/terminal、mode/identity | 精确详情、标准日志显式读取、活动 Job 取消请求已接通；取消先核对 fresh identity；恢复操作不混入控制面 |
| shell.recovery | needsAttention、unknown、等待人工、安全边界、等待归档、History 入口 | F40：所有主工作区逐项显示；精确 Job 跳转、清除旧筛选并定位记录行；独立窗口不显示。不确认后续刷、不在 App 归档 |
| device.details | adopted、offline、gone、authorized-unadopted、unknown | 设备行不是隐式 scope；已授权不等于接管 |
| device.trust | idle/polling/E000002/timedOut/E000003/ready | 有界等待；超时不当 denied；HDC 去 Overview |
| device.rename | 右键 rename/re-check、空名称/取消、显示别名 | 不改 binding，重新检测只读候选 |

### Overview（GJ-1/2/4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| overview.main | scope、SSH source、下一步、调试线；empty/ready/多目标/离线/未绑定/stale | 已接线；只列当前在线观察，真实 target→source，不取第一台服务器 |
| overview.environment | collapsed/expanded、healthy/mismatch/unknown/permissionDenied | HDC/tool/hash/endpoint/channel/能力完整保留 |
| overview.resume | 来源检查 sheet、loading/无参数/target/binding漂移/unknown | F02/F03/F20；精确记录；导航与准备分开；仅安全只读输入复制至新草稿，原始 thread 保留，不复制 authority/session |
| overview.hdcImpact | impact sheet、generation漂移、确认/拒绝 | 已接线；无 proof 不可执行，不自动重启 external server |

### Flash（GJ-4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| flash.main | 镜像 empty/importing/invalid/ready/blocked；主动作；hardwareGated；缓存计划可用性刷新 | 导入和 exact plan 已接线；同页说明影响，不恢复第二确认框；F32 修 Runtime 投影，F33 让缓存计划随当前可用性撤下/恢复动作 |
| flash.plan | 计划/前置条件 disclosure；target/hash/partitions/Loader/missing | Loader 激活属于执行前身份关联；历史目标缺失明确占位；测试显式选择当前目标后才 materialize exact plan，不静默换目标 |
| flash.runtime | prepare/write/reboot/verify/failed/cancelled/unknown | bytes比例不是成功；postflight后才成功；unknown不重放 |

### Debug（GJ-2/3）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| debug.artifacts | Artifacts；local/ssh/empty/importing/invalid/ready/failed | 单个 signed app-owned .so 已实现；batch/abc/SMB/WSL/独立重启未实现 |
| debug.browser | SSH browser sheet；roots/loading/entries/up/selected/refused | 只读 SSH/SFTP 已实现，不越 verified root |
| debug.plan | 单库计划 sheet；review/submitting/blocked | target/ABI/hash/readback/rollback；restartAbility 在 typed plan 内 |
| debug.logs | Logs；bounded/active/pausedViewport/filter/shards/failed | 暂停视口不是停止设备；不能画无界“实时流” |
| debug.logConfirm | 本地清屏、设备 buffer、保存日志 | buffer operation 未发布保持禁用；NSSavePanel 显式导出 |
| debug.apps | Apps；HAP选择/计划/install/start/debug/库存/失败 | typed HAP 流已接通，原型固定不可用与旧计划已修 F19；独立包行 lifecycle 禁用有依据 |
| debug.network | Network；forward/reverse/invalid/add/remove/补偿 | typed 端口1024–65535；不输入任意 shell |
| debug.commands | Commands；select/inputs/disclosure/running/failed/rawArtifact | 闭集只读模板；Root 等缺口不画执行入口 |

### Viewer（GJ-1）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| viewer.main | empty/loading/captured/search/selection/geometryUnavailable/failed | explicit target、同 Job screenshot/tree/hash；不默认伪造 capture |
| viewer.properties | Properties；identity/state/geometry/paint/missing | 已接线；Provider 技术词表保留英文 |
| viewer.layout | Layout；bounds/root/geometryUnavailable | 无 geometry 不编造命中区域 |
| viewer.accessibility | Accessibility；semantics/focus/missing | 只读观测字段，不把缺值解释成通过 |
| viewer.raw | Raw dump；raw/missing/large | raw origin 不合并覆盖 |
| viewer.advanced | Advanced Dump；lazy/search/noNumericIDs/retry/failed | 已接线；原型/DS 补第五标签 F18；合法 component ID；Fault/Crash/System Snapshot 不属首版 |

### Trace 与独立 Viewer/帮助（GJ-1）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| trace.capture | checking/unavailable/ready/invalid/unitChange/quick | 5/10/15/30秒、1/2/3分钟；原型 F06 已修正 |
| trace.runtime | submitting/active/cancel/terminal/unknown/blocked | Runtime 状态，typed cancel；原型不证明设备结果 |
| trace.artifact | empty/published/loading/hashMismatch/retry/open | 唯一 raw trace.htrace 校验后打开，不替换失败文档 |
| traceViewer.recent | 独立窗口 empty/recent/missing/open/remove/reveal | 已实现；原型覆盖 empty/recent/missing/open/remove 和合成 loaded 样本 |
| traceViewer.timeline | loaded/noTimedEvents/filter/search/lane/zoom/focus | ArkTrace canvas/query 已接线；真实 event identity |
| traceViewer.event | Event Inspector/rightDock/bottomDock/hidden | 已接线；合成稿覆盖 event/range、hidden/rightDock/bottomDock；不替代原生 parser 验证 |
| traceViewer.range | Range Inspector/aggregate/counter/selectionChange | 已接线；查询限额和来源 identity |
| traceViewer.annotation | marks/flags/tag editor/edit/remove | 已接线；local sidecar 不作 device fact |
| traceViewer.loading | hashing/cache/indexing/cancel/schema/error/reload | 有分母才百分比；普通错误/恢复操作双语，原始诊断留在 disclosure |
| traceViewer.shortcuts | 独立 Keyboard Shortcuts；keyboard/pointer/search/focus | App 使用上游中文 action/title/gesture；通用稿镜像 pinned catalog 的 3 组/19 条 |

### Device 与 Diagnostics（GJ-1）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| device.control | empty/captured/stale/unknown/inputFailed/history | 每次手势一个 typed input；confirmed/unknown使图过期；无持续预览/键盘 |
| device.recording | preflight/quota/refused/capture/assemble/validate/ready/failed | 默认40、2–300帧；实测fps/缺帧；本机 .mov；无设备端视频编码 |
| device.events | capture/input/refusal/recording/save log | 本地反馈与 Runtime 事实区分；不当硬件证据 |
| diagnostics.capture | noSession/noTarget/adoptedTarget/disabledArm/disabledMark | F01；不会假布防或保存 Marker |
| diagnostics.reader | partial/marks/noPicture/missing/notDerived/alignment | History → fresh correlation → index/summary/markers bounded read/hash → publish；无校准/时间不猜；PNG/JPEG 通道兼容；文本显式读取 |
| diagnostics.concept | 显式未来 capture/recording/finalizing/session/partial/clockGap | 有界 ringBuffered 与部分自动 Marker 已发布；交互式会话/视频/校准仍为单独概念，不混入当前默认 |

### History（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| history.list | 八类、search/status/mode/session/target/time/saved/loadOlder/empty | App已实现；原型补筛选，空列表不留无关详情 |
| history.detail | Summary/Timeline/Correlation/Evidence/Parameters/Artifacts/Recovery；loading/failed/missing/partial | job与Artifact按需加载；F37/F38 不再补造事实；F39 补全 Summary、Correlation、Evidence 与恢复状态的已实现字段，缺失与明确空清单分开 |
| history.export | sensitive preview/cancel/chunk/hashMismatch/save/reveal | 目的地不传daemon；byteCount/hash复算；F37 按 exact Artifact 预览，未发布禁用；与App诊断导出不同 |
| history.context | 在 Flash/Debug/Viewer/Trace/Device/Diagnostics 打开 | App 全部六类保留精确来源；F39 补原型遗漏的来源信息与 Inspector 跳转字段；Diagnostics 可将校验过的 Trace 转交 Viewer；不重放，原型不读取历史文件 |

### Settings（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| settings.general | General；keycap/waveform/build/localOnly | 已接线，版本取bundle |
| settings.toolchains | Toolchains；loading/choose/probe/missing/activeJobs | 已接线；只影响新Job；来源/hash/ownership保留 |
| settings.servers | Servers；empty/list/refresh/add/edit/remove | 已接线，只读SSH来源，不是四connector |
| settings.serverEditor | password/key/defaultKey/probe/fingerprint/root/drift/save/refused | 未验证不能保存；秘密仅Keychain；次级原型已补中英文，修改输入使 demo 验证失效 |
| settings.serverDelete | 移除确认/cancel/bindingStale | 只移本地来源，不删远端文件 |
| settings.storage | root/quota/margin/retention/invalid/unknown/pinned | soft claim不保证物理块；不删pinned |
| settings.traceCache | Trace→Cache；loading/inventory/refresh/purge/activeEntries | 已接线，仅 inactive derived；普通文案双语 |
| settings.traceLicenses | Trace→Licenses；lazy/loading/notice/missing/reveal | 已接线，14 reviewed components；许可证原文保留 |
| settings.updates | idle/checking/current/available/download/verify/consent/error/reveal | 独立Settings，签名校验，显式Finder handoff，不静默安装 |
| settings.diagnostics | destination/preview/scope/hash/estimatedBytes/export/error | 始终排除device raw；本地显式导出，无上传 |

### 系统面与设计镜像

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| system.panels | Flash镜像、入口 HAP / 附加 HAP/HSP / .so / HDC / key / root / Trace 导入；日志/Artifact/诊断包保存；Finder | 系统panel已纳入所属流程；不计为新业务页；HTML不真实读写 |
| design.components | Workspace chrome；31预览；light/dark/narrow/focus/disabled | 25 个已声明映射由 24 个新受控组件闭合；新增 SessionSurfaces 双语画廊；ArkTrace canvas 属上游插图，远程库未同步 |
| automation.retired | 旧Automation/HTASK稿 | CHG-2026-064已移除；旧URL只解释退役，不是待办 |

### 生产 View 文件索引（20/20）

以下每个文件都由上表中的对应页面/子面覆盖，包含同文件的私有 View；ViewModel/facade/资源随交互追到调用点。

- [App / scenes / navigation](../../ArkDeckApp/App/ArkDeckApp.swift)
- [Workspace chrome](../../ArkDeckApp/DesignSystem/WorkspaceChrome.swift)
- [Device detail / trust](../../ArkDeckApp/Features/Devices/DeviceWorkspace.swift)
- [Overview record](../../ArkDeckApp/Features/Overview/OverviewRecordView.swift)、[Resume sheet](../../ArkDeckApp/Features/Overview/OverviewResumeSheet.swift)、[HDC / impact](../../ArkDeckApp/Features/HDC/HDCStatusView.swift)
- [Flash workspace](../../ArkDeckApp/Features/Flash/FlashWorkspaceView.swift)、[plan](../../ArkDeckApp/Features/Flash/FlashPlanDetailsView.swift)、[runtime activity](../../ArkDeckApp/Features/Flash/FlashRuntimeActivityView.swift)
- [Debug 五标签与 sheets](../../ArkDeckApp/Features/Debug/DebugWorkspaceView.swift)
- [Viewer 五 Inspector](../../ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift)
- [Trace workspace](../../ArkDeckApp/Features/Trace/TraceWorkspaceView.swift)、[configuration](../../ArkDeckApp/Features/Trace/TraceConfigurationView.swift)、[artifacts](../../ArkDeckApp/Features/Trace/TraceProgressArtifactsView.swift)、[Viewer / Help / Trace Settings](../../ArkDeckApp/Features/Trace/TraceViewerWorkspaceView.swift)
- [Device](../../ArkDeckApp/Features/Device/DeviceWorkspaceView.swift)、[Diagnostics](../../ArkDeckApp/Features/Diagnostics/DiagnosticsWorkspaceView.swift)
- [History](../../ArkDeckApp/Features/History/RuntimeHistoryView.swift)、[Jobs / recovery](../../ArkDeckApp/Features/Jobs/GlobalJobInspectorView.swift)、[Settings 七标签](../../ArkDeckApp/Features/Settings/SettingsRootView.swift)

## 4. 验证与证据分类

### 首轮后续验证快照（F01–F23）

以下为 goal 启动前的实际结果，原始日志保留在本机 `/private/tmp`。分批结果、日志 SHA-256 与原生截图来源记录于[验证摘要](references/v1.6-followup/verification-summary.json)。它是历史快照，不覆盖随后 F24/F25 的代码。

| 检查 | 结果 |
| --- | --- |
| 全入口覆盖 | 60 单元、20 View 文件、31 previews；导航/子标签/文件清单自动核对 |
| Prototype / DS 交互 | **38 tests，0 failures**；含保存会话、typed draft、Trace event/range、19 shortcuts、取消不造终态、Native即时输入/计划/日志空态、SSH漂移、次级英文 |
| DS build / previews | **通过**：token/class 检查、TypeScript declarations、JS/CSS、画廊 build；**31 个 TSX previews** 全部独立 bundle |
| 原生 App | 全批 **24 用例：20 通过、2 失败、2 真机跳过**；两个失败的中英文 sweep 修正后单独重跑 **2/2 通过**；最后 Trace 双语/搜索占位/帮助重跑 **1/1 通过**。按最后结果去重为 **22 通过、2 跳过**，不声称同一批次全绿 |
| 统一本地闸 | **退出码0**：SDD 0 errors / 0 warnings / 121 AC IDs；catalog generator 49 tests 与零漂移通过；Swift **1815 并行 + 1 identity race + 5 scale = 1821 tests**，全部车道退出0；App / UI-test bundle **TEST BUILD SUCCEEDED** |
| 浏览器可见交互 | 已实测范围 Apply/Mark/Keep/dock、筛选空态、Diagnostics 显式敏感预览/retry/Trace转交、readonly草稿无派发、取消不变终态/日志/精确History、SSH检查后输入漂移、组件帧数300→301拒绝；均为设计样本 |
| 真实设备 | 未运行；两个原生真机用例因未显式开启而跳过；没有新 HDC/Flash/capture 验收，不登记 REAL_DEVICE_PASS |

该次统一本地闸覆盖当时生产 Swift、资源与 UI 测试代码。随后 goal 真机验证又产生 F24/F25 修复，须单独重跑；未把 compile-only 当作 XCUITest 断言通过。

### Goal 真机验证与修复（F24–F35，进行中）

**2026-08-28 F34 最新真机结果**：PR #1568 已合入 `59158aed`，维护者明确授权继续及
具名 `ui-alignment-20260828` HardwareCampaign。使用已签名的 reviewed `b564e990` Runtime，
重新核对同一镜像哈希、目标 r4、fresh plan 后，仅执行一次新 `flash.full-restore@1`：
`job-8e32139af1945d755f5716b67f4f8bde` 于 03:21:37Z—03:24:27Z 成功，machine readback 为
OpenHarmony-7.0.0.37 / r4，无 unknown、人工步骤或残留。独立 `agentd verify` 的五项检查与
三份 Artifact 字节校验均通过。随后关闭 campaign，完整安装配置恢复原值；新的只读 Observe
再次成功。四条已终止 unknown 历史未改写，先前明确未执行的 Flash 请求保留。
这是具名硬件验收成功，不授予 ProductionVerified，也不证明未复验的 App 呈现。
真实 App 回看暴露 F34/F35；修复后的全部真实只读 UI 回访仍待完成，goal 未完成。
F34 两项双语原生用例共 43.803 秒、零失败；六张附件已逐图检查（活动详情在折叠区下方，
由精确 AX 断言覆盖，截图不外推为该区像素验收）。42 项设计测试、1,832 项 Swift 测试与
App/UI-test bundle 编译通过。首轮夹具绑定/定位错误的失败日志保留，未放宽产品判断。

**2026-08-28 F32/F33 历史复验**：F32 已合入 `b564e990`；从该干净 main 快照构建并通过
既有安装入口更新已签名的本机 Runtime。两个 Flash 引用均返回 `hardwareGated / unavailable`，
HDC、ArkForge、workspace 与 Trace 配置及四条终止的 unknown 历史原样保留，具名 campaign 仍为空。
随后真实只读 `observe.device@1` Job `job-fca1ec9b8ff627215b233fea2037221c` 成功，
receipt、trusted evidence、postflight 与三个 Artifact 核验通过，无 unknown / residue。
这只证明 Runtime 受阻投影与只读设备链路，不证明 Flash 成功。此前获擦写授权后的一次 Flash
请求明确未执行；额外 HardwareCampaign 授权仍未获得，没有再次请求刷写。
F33 的完整隔离原生 fixture 中英文用例通过（20.142 秒），当前可用性变化会撤下/恢复缓存计划的
动作并保留镜像；41 项设计测试、1,832 项 Swift 测试及 App/UI-test bundle 编译均通过。
原生 fixture、设计样本、真实只读观测和未执行的 Flash 请求分别记于
[本次验证记录](references/v1.6-goal/flash-hardware-gate-verification-2026-08-28.json)。

**2026-08-28 F24–F31 验证快照**：基于 `86b284d0` App 生产代码与已安装的 `2f05ea02` Runtime，
冷启动（0.994 秒）、HAP/HSP 选择与四种策略组合（同一用例覆盖中英文）、Device stale-frame
三项独立 XCUITest 均通过。stale-frame 完整时间窗口恰有两次截图和一次 `input.tap@1`，
第二次点击拒绝，没有新增输入 Job；三张图逐图核对。真实 App 的 entry+shared HSP
Job `job-b6762567bef468c88ac8dc536a06a932` 成功，导入哈希、共享函数日志、停止/卸载/暂存清理
均核验，零 unknown / residue。原始截图、日志和签名材料仅留本机；
[后续复验元数据](references/v1.6-goal/followup-verification-2026-08-28.json)保留失败与跳过尝试。
当时 ArkForge 已通过发布安装入口配置，未提交新的刷机 Job；该快照不证明 Flash 真机通过。
随后擦写授权、hardwareGated 拒绝与可用性修正以上方 F32/F33 记录为准，goal 未完成。
本次最终路径分类闸退出 0（SDD、49 项 catalog 测试、零漂移、App/UI bundle 编译），
40 项设计交互测试通过；仅测试和文档改动，未选择 Swift package 车道，不用编译代替 UI 断言。

以下为各次历史尝试，后续通过不删除或改写先前失败：

已重新确认已安装的 signed protected-main Runtime 健康；旧 v1.5 的 Runtime 不可用记录不是当前状态。
新的 `observe.device@1` 与包含 HiLog、UI Dump、UI tree、截图和 Trace 的 `capture.diagnostics@1`
均以 `execute` 在同一已接管 USB 设备上成功，Runtime 报告无 unknown outcome / evidence blocker。
诊断采集发布九个经字节校验的 Artifact。详情和 SHA-256 见
[真机记录](references/v1.6-goal/real-device-validation.md)。

原生 App 实际打开该 Job 后，Diagnostics metadata 完整加载，未伪造跨时钟对齐；也因此发现
Viewer 分类入口、Trace 转交与非 UTF-8 HiLog 预览缺陷。F24/F25 修复已在真实制品的中英文
XCUITest 中通过（1 case / 2 locales，245.808 秒）；四张原生图已逐张查看，
[附件哈希与无重放核对](references/v1.6-goal/native-ui-verification.json)单独记录。
之前两次 automation mode 超时没有执行断言，保留为失败尝试，不混入通过计数。
F24/F25 的 Swift 全量 1,823 项和 App/UI bundle 编译通过；后加 F26/F27 仍须最终回归。
设计交互测试再次通过 38/38；[新增参考图](references/v1.6-goal/README.md)仅为设计样本。
五项后续真机 UI 批次已结束：**4 通过、1 失败（exit 65）**。Diagnostics/Trace 双语（含 F27）、
exact History、真实 40 帧录屏和 Viewer capture 通过，六张原生图已查看；仅新增两个成功的设备 Job。
冷启动为 4.223 秒，单项重跑为 4.644 秒，改动前隔离基线也为 7.647 秒，均未达到 2 秒标准。
主机其他项目构建是尚未排除的影响因素，不能直接声称本轮回归或环境误报。
详见[批次结果及附件哈希](references/v1.6-goal/ui-batch-verification.json)；未放宽门限，也未将整个 goal 标为完成。

本轮还新增已签名 HAP、Native 库和 entry+feature 多包的真实执行，结果均为 succeeded；
Native 验证包括 hash / process / maps，多包流程包括安装、停止、卸载与暂存清理，清理无残留。
精确参数、Artifact / receipt 哈希与不覆盖项见[Debug 真机元数据](references/v1.6-goal/debug-real-verification.json)。
原生 App 又通过文件选择器选择真实 entry + feature，经生产 XPC 导入并提交新 Job
`job-2c4e67f6d107999cc5a996403387ac3a`，结果 succeeded、无 unknown / 残留；三份产物导出后哈希一致。
HSP 仅检查了本地选择，不从 feature HAP 成功推断 HSP 真机安装通过。
真实 HiLog 编码提示及 HAP / Native 的 History→Debug 精确上下文已补逐图检查，
[本机截图的哈希](references/v1.6-goal/manual-native-verification.json)不包含 raw 图片。
F29 定向 Swift 34 项与设计测试 39 项通过；本次完整闸发现 App 使用旧式字符串格式化，
已改为类型安全本地化资源，随后完整闸退出 0：Swift 调度 1,826 + 1 identity race + 5 scale = 1,832 项，
三条车道均通过；SDD、catalog generator 49 tests、零漂移和 App/UI-test bundle 编译通过。
见[最终本地闸元数据](references/v1.6-goal/local-gate-verification.json)。该闸覆盖 F28–F30 生产代码；
F31 仅改设计与参考图，另行通过设计交互和构建，不把 compile-only 当作 UI 断言通过。
原生文件选择测试两次未能初始化系统 automation mode，
未执行断言；不能记为通过。Computer Use 已核对选择/重复拒绝/移除/清空，并发现和修正按钮标识覆盖。
F30 四种生命周期组合的设计测试通过；原生中文提示及填写后的 Bundle/Ability 标签已逐图核查。
后续 AX 检查发现跨列文本合并会吞掉警告标识，分栏 contain 后确认警告标识独立、策略切换移除提示；
HSP 移除按钮也确认保持独立标识。附加区与文件行 contain 已在实际 App 复查，文件名与移除按钮独立。
恢复控制后又发现入口文件名仍与下方说明合并，改为显式 accessibility element/label；重建 App 后确认
空状态和实际文件名独立读出。再补静态文本 trait 与既有用例的角色断言，最终角色的原生复验仍待完成。
中文四种策略组合、HSP 重复拒绝、提交禁用、移除和清空已通过 Computer Use 核对，截图仅留本机。
五次新的初始化超时见[失败尝试记录](references/v1.6-goal/native-ui-initialization-attempts.json)。
只读采样确认旧测试服务停在本地认证同步等待；此前 SIGTERM 并未重启服务，记录已更正。
确认旧服务退出后重跑仍未开始断言。Computer Use 曾恢复，但打开 Settings 后其服务在 Array.remove
调用中崩溃；独立窗口读取也超时。英文和剩余 Device 原生交互未验收，没有修改系统安全设置。
不将这些失败当作产品断言通过。goal 目录现有 13 张设计参考，均已逐图查看。
F31 来自真实 Trace 字段级复查：键盘事件选择、范围聚合/缩放、Flag 改名及重载保留已观察，
本次测试 Flag 已删除；原型补齐相同操作，不引入新 Runtime 能力。40 项设计交互测试及设计包构建通过。
继续对照锁定的 ArkTrace `TraceDocumentController.addMark` / `TimelineNSView.drawAnnotations`：
临时 Mark 只保留最后一个，保留 Mark 累积；名称与颜色按当前同类条目数分配，ID 不复用。
原型已修正替换语义并显示范围色带，中英文浏览器核对保留 3.800–5.050 s、替换为 0.600–1.780 s。
两张参考图已更新、逐图查看；40 项设计交互及 7 项既有设计同步合约通过。

### 尺寸与 UI 测试修正说明

原断言把 AX 外框高直接与 `.defaultSize(height: 760)` 相等，基线也失败。
实际测得 frame/content 为 1180×783，contentLayout 为 1180×731；通用 style-mask 估算又得到不同值，
因此不再采用固定标题栏高度补偿。新 opt-in 探针只记录真实 NSWindow，不调整 frame 或用户存储位置。
回归检查实际外框与 AX 一致、宽度 1180、未落入最小窗，并用实测 native chrome 约束高度。
这修正的是测量契约，**没有修改 App 的默认尺寸，也不是像素一致性验收**。
原生系统 chrome、首轮 1180×760 浏览器视口、后续实际 1280×720 视口分别标注；后者内的 reference window 仍固定为1180×760，部分图存在滚动，不能作为像素对齐证据。

依据：[Apple fullSizeContentView](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/fullsizecontentview)、
[contentLayoutRect](https://developer.apple.com/documentation/appkit/nswindow/contentlayoutrect)、
[SwiftUI defaultSize](https://developer.apple.com/documentation/swiftui/scene/defaultsize(width:height:))。
跨窗口装饰样式的测试边界是结合实际测量作出的工程选择，不是声称文档规定了固定 23pt 标题栏。

全量扫页还发现 Job 详情标题现在为 AXHeading，旧测试强制用 StaticText 查询失败；已改为稳定
`jobInspector.runtimeFacts` 标识，保留 heading 语义。Trace Help 与 Window 菜单存在同名项，测试现限定 Help 菜单。
Flash 历史入口会正确 pin 已失联的旧目标；测试必须显式选择 fixture 当前目标，不能要求产品默换设备。

### 可复现命令

```sh
npm --prefix docs/design/arkdeck-ds test
npm --prefix docs/design/arkdeck-ds run build
npm --prefix docs/design/arkdeck-ds run build:review

python3 scripts/ci/plan.py --repo-root . --base-revision origin/main \
  --head-revision HEAD --merge-base --include-worktree --run-local

sh scripts/ci/run-ui-tests.sh \
  -only-testing:ArkDeckHDCUITests/AppShellUITests \
  -only-testing:ArkDeckHDCUITests/OverviewRecordUITests
```

UI 测试必须与其他构建串行执行。真实设备用例没有显式环境开关时跳过；fixture 永远不记为硬件证据。

### 参考图

首轮 [v1.6 的 63 张图](references/v1.6/README.md) 保留为首轮快照；后续变更页面需以新补充图为准。
[后续参考图](references/v1.6-followup/README.md)包含 **49 张浏览器图 + 9 张原生 PNG**，均已逐张查看、校验尺寸与 SHA-256。原生附件未缩放或重绘。
浏览器图是 design demo；原生 Diagnostics/Inspector 是 fixture，Trace 空窗包含本机 Recent 元数据但没有打开 Trace。
**原生 loaded Trace / 全部交互状态的像素验收未做**；不能拿合成 timeline 替代 parser/设备结果。原生 `.xcresult` 的主机身份和无关 App 附件不写入仓库。

## 5. 仍需后续产品任务的能力

1. **Diagnostics 交互式会话**：arm/append-marker/stop、会话内视频和跨时钟校准；现有 bounded ringBuffered、markers.json 和 reader 不等于该完整体验。缺失 operation/并发契约不得从 App 接 raw HDC 补洞。
2. **全局恢复操作**：Runtime 已有保守恢复语义，但 App 没有可直接接线的 rebind/archive RPC；保持只读证据/History，不把用户确认变成 authority，也不重放 unknown intent。
3. **变更操作的参数复用**：当前延续闭集仅安全只读观测；Flash/Native/HAP/含变更 Trace 不带旧 lease/authority 复跑。未来交互须独立设计 fresh import/plan/admission。
4. **剩余真机验收与远程设计库**：GJ-1 的新观测、多通道诊断、原生 Diagnostics/Trace/History/Viewer 与录屏已有实测结果；冷启动、原生 stale-frame 和实际 entry+shared HSP 均已有通过记录。2026-08-28 明确授权 HardwareCampaign 后，新 canonical Flash 实际成功并独立核验，campaign 已关闭。F36 合入后双语真实 App 只读回访已通过，活动、精确 History 与旧 unknown 保留均核验；F37 是该回访新发现的稿件摘要/Artifact 差异修正，不重复刷写来补 UI 证据。HiLog 摘要操作仍报告未实现。远程设计库未连接，当前只同步仓库稿件与参考图。

这些边界不通过删除 accepted requirements 或将 fake/simulation 标成真实结果来关闭。
不创建 readiness/status-only 载体；确需新 operation/provider/profile 或安全策略变化时按现有治理处理。


## 2026-08-28 F35：Flash 只读设备诊断的沙箱边界

GJ-4。真实 Flash 完成后的 App 回访发现：设备访问 facade 直接以 App 的 Application Support
拼接 ArkForge Unix socket。沙箱内路径为 124 bytes，超过 Unix socket 上限；更根本的问题是
App 不应直连该 socket。不能缩短路径或用 IOKit USB 存在替代 ArkForge 的真实访问探测。

现把同一 public `discoverDevices` 调用迁至 Runtime 的已配置 ArkForge 目录；App 仅发无参数的
`flash.device-access` 只读 XPC。返回闭集只有模式与数量，不导出原始设备身份、路径、诊断文本，
不接受调用方 socket/target/authority，不创建 Job、binding、capability 或设备副作用。这里新增的是
App 只读查询适配，不是 Catalog operation/provider/profile，destructive 准入保持不变。

App 区分成功的空 RockUSB 观察、Maskrom、Runtime 不可达、探测失败与格式错误；失败不变成
“未发现设备”，HDC-normal 不变成 Loader 就绪。稿件补三种设备访问状态与双语重新检查，
重新检查保留展开区；未选择镜像时只显示设备已选择，不再提前显示完整计划或安全检查通过，镜像样本
的必需检查数同步原生三项。阶段表按 Catalog 计算最高 effect，包含重启的收尾阶段
不再错误标成 readOnly；未降低任何实际 operation 的 effect。五个组件预览同步受支持的
.tar.gz 示例、三项检查与 canonical 引用；能力卡用 hardwareGated 不可用样本，不再仅凭
Catalog published 标成可用。

本项在 `agent/flash-device-access-xpc-20260828` 独立交付。生产 Runtime 未安装候选代码，
campaign 保持关闭；只有合入后的真实 App 只读回访才能关闭该差异。F34 的真实 Flash
与独立核验另随 PR #1569 提交，不以本项 fixture 或设计样本替代。

验证：最终本地闸 exit 0（Swift 1,836 项、App/UI-test bundle build-for-testing、SDD、
49 项 catalog generator 测试与零漂移）；设计交互 44 项、DS/build:review 与 31 个独立
组件预览打包通过。三项双语原生测试通过，共 72.062 秒，10 张原始 PNG 已逐张查看；
其中 F34 activity 现滚动至可见区再截图。新增 8 张浏览器图只证明设计样本状态。
首次 UI automation mode 初始化超时、测试 import 编译失败等尝试保留记录，未计为通过。
完整选择性元数据见[验证记录](references/v1.6-goal/flash-device-access-verification-2026-08-28.json)。

## 2026-08-28 F36：Flash 活动选择与精确历史回访

GJ-4。F35 已合入 PR #1570（`f18ca0c7`），随后从该 reviewed tree 构建并更新本机 Runtime。
真实 App 两次只读探测均正确显示空 RockUSB 观察；新 `observe.device@1` 成功且独立五项核验
通过，原 binding r4 不变。更新后的首次目标观察失败保留；已有成功 Flash 复核通过，未再次刷写，
HardwareCampaign 仍关闭，四条历史 unknown 完全不变。详见 F35 验证记录的 post-merge 部分。

同次真实 App 回访发现：History 的分页答复会把保留的 attention 记录放在前面，Flash 卡片却以
数组首项作为最新记录。旧 alias-resolved unknown 因而遮住 canonical 成功；从成功 History
进入 Flash 后，来源上下文与活动卡片也指向不同 Job。“打开 Runtime 记录”只切换通用 History，
没有携带卡片所示 Job ID。

修正为共享的只读展示投影：按 Runtime 时间排序，unknown → 人工等待 → 其他恢复阻塞 → 当前
活动 → 最新记录；已有 Runtime 恢复关系的旧 unknown 不再充当当前风险，但原状态、结果和关系
均保留。缺失时间保持缺失，相同时间按 ID 稳定排序。Flash 主阻塞区与详情卡使用同一选择策略，
记录按钮传 exact Job ID，结果页在已有 submission 时也打开对应 Job。没有新增设备 operation、
Provider、profile、能力或恢复策略。

稿件补活动、保留旧 unknown、未解决风险优先和精确 History 交互；浏览器实测还修正跳转继承
Flash 滚动位置、把已选详情留在屏幕外的问题。六张双语设计参考均已查看，不是设备证据。
35 项 History 合约和 47 项设计交互已通过；首轮完整闸发现架构测试仍要求各 View 直接筛选，
现改为检查共享投影的 canonical/legacy 分类与 View 调用链。完整闸重跑 exit 0：Swift 1,839 项、
App/UI-test bundle 编译、SDD、49 项 catalog generator 测试与零漂移全部通过。
原生 UI 四次均停在系统认证或 automation mode 初始化，零断言执行，不计为通过。
随后按相同隔离参数启动最终 App，以 Computer Use 完成双语检查：旧 unknown 精确跳转到非首行、
旧已恢复记录不遮住最新成功、成功卡片打开对应 History，旧 unknown 行保留。六张截图逐张查看，
只保留本机；真实 Runtime 的 1,962 条 Job 前后完全相同。此手动 fixture 检查不替代 XCTest 或真机证据。
当前仍需原生断言与合入后真实 App 只读回访，不能将本项标为目标完成。
各次结果与原始日志哈希见 [F36 验证记录](references/v1.6-goal/flash-history-focus-verification-2026-08-28.json)。


### F36 合入后的真实验证（2026-08-28）

PR #1571 已合入 `3a9474f1`。相同生产源码先通过原生双语 fixture 回归
（1 项、45.738 秒、零失败），随后通过真实 App 双语只读回访（1 项、93.497 秒、零失败）。
后者没有设备/History fixture：通过生产 XPC 读取已安装的 reviewed Runtime，检查 canonical
成功活动、设备访问空观察及重新检查、精确 History 跳转、返回工作区与四条旧 unknown 保留。
临时本机验收方法仅加入既有测试文件，完成后恢复原字节；整棵源码再次与 reviewed main 相同。
三次本机测试方法修正前的失败/中断保留，不混入通过计数。

八张真实 App PNG 与两张 fixture PNG 均已逐图查看，只保留私有目录。前后 **1,962 条 Job
完全相同**；没有新设备操作或重复刷写。已有真实 Flash 再次通过终态、postflight、可信证据、
Artifact 和通道五项独立核验；HardwareCampaign 保持关闭。App 的 204 条已加载记录不等于
完整库存数量。详见 [F36 post-merge 元数据](references/v1.6-goal/flash-history-focus-verification-2026-08-28.json)。

## 2026-08-28 F37：Flash 摘要、详情与 Artifact 稿件对齐

GJ-4。真实回访及 `RuntimeHistoryApplicationFacade` 确认：App 摘要分页使用
`includeTimeline=false`，打开 exact History 后才加载完整详情。原型却在活动卡复用了样本
时间线，并在详情/全局 Inspector 按 Flash 类型补出过期 `plan.json` / `flash.log`、固定
binding rev 3、9 steps 和假示例哈希。

原型现保持摘要/详情边界：活动卡不含时间线，History 的 Journal 摘要只显示该记录提供的
条目；状态确定性、effect、目标/绑定及 Artifact 只取显式字段。canonical 样本明确列出
`post-flash-facts.json`、`post-flash-hilog.txt` 和 `flash-report.json`，没有提供的大小/哈希
显示未报告。unknown 样本无 Artifact 清单时不推断文件，也不提供导出。

Artifact 按原生详情改为逐项卡片，修正窄栏表格截断导出按钮；预览准确选择该文件并区分
sensitive / standard，非 published 项禁用。全局 Inspector 保留原 unknown/时间线字段，
不再把不存在的 `flash.log` 当成可读取标准日志。所有数据仍标为设计样本，不连接 Runtime。

48 项设计交互/覆盖测试、设计包与 review 构建已通过；60 个单元、20 个 View 与 31 个
preview 的源码清单再次一致。10 张中英文浏览器图已查看（刷新 6 张、新增 4 张），
其中包括摘要、精确 History、Journal/Artifact、导出预览和 unknown 优先；无浏览器错误。
本项只修改设计与必要验证记录，未改 App/Package/Catalog 或安全策略。
详见 [F37 验证元数据](references/v1.6-goal/flash-summary-verification-2026-08-28.json)。

F37 最终路径分类闸 exit 0：仅设计/文档，未分配 Swift/App 编译车道；18 项 planner、9 项 workflow、SDD 0/0、49 项 catalog 测试与生成物零漂移全部通过。

## 2026-08-28 F38：History 全类型事实与筛选对齐

GJ-1—4，基线为 #1572 合入后的 `0dc61e0f`。F37 修正 Flash 分支后，继续逐字段核对发现
非 Flash 分支仍按类型补出固定 binding / manifest / hash / 文件，并把 cancelled 解释为
补偿已执行、参数已恢复；旧 History brief 还会要求设计者重新画回这些错误。筛选另把
Job ID 当 Session、显示设备名当 target、“需要关注”当 interrupted，漏掉 operation 搜索。

所有类型现在共用详情与逐项导出：状态、certainty、effect、target/binding、Journal、typed
inputs 和 Artifact 均取显式字段。旧记录未报告与明确空参数分开；before/after 只接受显式
traceParameters，unchanged / changed / unverified 不被替换成“已恢复”。当前样本的文件名、
role、privacy 和输入字段由测试逐项对照 published Catalog；不补造 byteCount 或 SHA-256。
只有选中且 published 的 Artifact 可打开自己的导出预览，标准日志入口也来自实际清单。

筛选同步原生的 exact Job / Session / operation / target / state / mode、active、unknown mode、
过去一小时/一天/一周和已报告时间排序；有恢复关系的旧 unknown 不因旧 unknown 本身继续
报警，残留项仍需关注。保存/恢复/删除、两种预设与清除均可操作。Native 演示任务进入
History 保留原 Job ID、明确 kind/operation 与字段快照，不另造 Session ID、不按标题猜类别。
取消演示不再宣称补偿完成。同步 History brief 与交互规格，防止旧指令把差异重新引入。

52 项设计交互/覆盖测试、设计包和 review 构建已通过；60 个检查单元、20 个 App View、
31 个组件 preview 的清单仍一致。这些是源码/设计测试，不构成真机验收。
浏览器停在被 URL policy 阻止的内部错误页，F38 的浏览器截图及窄栏视觉验收尚未完成；
不得把 F37 的旧图或本轮原生 fixture 截图当作 F38 稿件已通过。
已合入 main 的全页原生巡检与后续独立复测单独记录，失败不删除，不据此标记 goal 完成。

五项选定原生方法均已有完整通过记录：批次中的工作区空态、Trace Cache/Licenses、
Trace Viewer/帮助通过；中文全页独立复测 30.427 秒、英文全页独立复测 168.233 秒通过。
初次 XCTest 初始化超时、第二批的三条断言失败、第三次 runner SIGKILL 都保留，不称为
一次干净的五项批次。10 张原生截图已查看；App 源码始终为干净的 `0dc61e0f`，未为重试
修改代码、超时或断言。此轮只证明 App 呈现，不新增设备验收，也不能替代 F38 的 HTML
视觉检查。详情见 [F38 验证记录](references/v1.6-goal/history-facts-verification-2026-08-28.json)。

F38 本地统一闸 exit 0：18 项 planner、9 项 workflow、SDD 0/0、49 项 catalog 及生成物零漂移通过；设计/文档差异不分配 Swift/App 编译。当时浏览器视觉验收未完成；用户随后手动恢复预览，补验及其发现的修正见 F39，不把当时的门禁结果视为视觉通过。

## 2026-08-28 F39：History 只读来源和详情投影补齐

GJ-1—4。#1573 已合入 `71eb0b07`，源码与 F38 最终提交完全相同。再次逐字段检查
`RuntimeHistoryView` / `RuntimeHistoryWorkspaceContext` / App 的路由发现：原型的工作区
入口多数只切页，没有保留来源；全局 Inspector 的缺省跳转另造 Diagnostics 行，丢掉
operation、unknown 与身份；详情虽不再补造值，仍少了已实现的关联与证据分组。

修正：六类工作区显示可关闭的 exact Job / target / operation / state / Artifact 来源快照，
仅在对应页面可见；Viewer/Trace 转交 Diagnostics 不改原分类。Debug 页按当前 published
operation 选择 Apps / Artifacts / Logs / Network。Inspector 复用同一 Job 投影，保留原
类型、unknown、identity、时间与 Journal，不创建新的默认 Diagnostics 记录。

详情补齐 Session、三个时间字段、身份匹配的 Correlation 与同 Session 筛选、Evidence 的
Provider/Catalog/binding/authority/观测/终态/mode/effect/首条证据/step/blocker，及 Artifact
来源操作、媒体类型、状态原因。未报告清单与明确空/plan-only 清单分开，缺失恢复标志
不默认为无需恢复。只有显式样本字段参与展示，不造 hash、authority 或固件事实。
设计仍不读取历史文件，来源信息明确说明工作区示例不是该 Job 的真实 Artifact。

新增三项回归先复现缺口（52 通过、3 失败），修正后 55 项全部通过。首次设计构建识别出
五个尚未登记的页面布局 class；现逐项登记为组合既有组件的 History 布局，没有放宽检查。
原有 60 个检查单元、20 个 App View、31 个 preview 清单一致；
这只证明覆盖清单，没有将源码数量作为页面视觉一致的证据。

用户手动打开本机预览后，复用该标签完成 F38/F39 浏览器走查，未绕过此前 URL policy。
实测又修正：改条件导致完整筛选收起、搜索必须失焦才更新、按 viewport 而非工作区切栏、
长详情带走记录列表、工具栏标签拆行、Inspector 的 `waitingForRecovery` 裁切，以及切换
语言后深色外观误标为系统外观。现在即时搜索保留焦点/光标；筛选保持展开；890 工作区
边界与原生一致，窄窗活动选择器、双栏独立滚动和更窄时上下排列均可用。

六类工作区双语来源回访、关闭/跨页隐藏、Viewer 转交 Diagnostics、精确 Session/target、
保存/清除/恢复/删除、时间与 planned 筛选、旧 cancelled 缺失事实、unknown 与已恢复关联
保留、Inspector 精确跳转、深色外观和弹层 Escape 焦点返回已实际点击验证。六类共 21 个
样本文件分别完成中英文逐项导出预览（42 次），隐私与缺失大小/哈希正确；演示确认明确
说明未写出文件。34 张原始 JPEG 已查看、核对尺寸与 SHA-256。实际 viewport 为 842×750；
两张宽栏 reference 为 1180×760 CSS 窗口的 fullPage 输出，保留额外画布，不作像素等价证明。

浏览器记录保留 80 条通过断言及 3 次未通过尝试：一次批量清空未生效后用实际键盘清空
复测；两次断言误要求 UI 未显示的 recovery ID / 错误 handler 名，经核对原生代码和实际
控件身份后修正检查。没有为这些断言修改产品语义。外观标签新增回归先得到 57 通过/1
失败，修正后最终 **58/58**；设计包和 review 构建均通过。

本项没有生产 App/Runtime/Catalog 变化，不重复设备操作；既有真机和原生结果保留原记录
范围及失败尝试。本项浏览器缺口已补验，后续仍须维护者 review/merge，不提前标记 goal
完成。完整字段、截图与日志哈希见 [F39 验证记录](references/v1.6-goal/history-readonly-verification-2026-08-28.json)。

最终统一路径闸 exit 0：18 项 planner、9 项 workflow、SDD 0 error/0 warning（121 AC）、
49 项 catalog 与生成物零漂移通过。44 个改动均为设计/文档/参考图，Swift/App 编译车道
均未分配；未把此闸作为新增设备验收。

## 2026-08-28 F40：Recovery 精确 History 入口与记录定位

GJ-1—4。#1574 已合入 `f5637703`，树与已测 `742068f4` 相同。合入后 58 项设计测试、
3 项原生 History 用例通过；原生首次仅发生自动化初始化超时，重跑通过，保留两次日志。
现有真机 Flash 回执由 reviewed Runtime 再次只读核验：终态、postflight、可信证据与三个
Artifact 校验均通过，没有新刷机、重新打开 campaign 或安装候选 Runtime。

本轮发现全局 Recovery 的无参 callback 丢失了横幅对应的 Job ID。已经在 History 中
筛选/选择其他记录时，点击“在历史记录中检查”仍停在旧记录。现在该入口传递精确 ID，
清除旧筛选；History 消费一次导航请求，确保再次点击同一 Job 也会重新定位。截图进一步
发现 List 保留旧滚动位置、目标行可能在视口外，现用稳定 Job ID 将该行滚动到可见区域。

原型移除三处页面内硬编码横幅，改为主窗口全局挂载；八个主页面、动态设备详情与信任页
共享同一 family，独立 Settings / Trace Viewer / 帮助及退役 Automation 不显示。按显式
History 字段投影 unknown、人工处理、安全边界、等待归档和等待恢复，文案与原生词表
一致；已建立 current epoch 的旧 unknown 不再作为当前提醒，原事实仍保留。每项都精确
打开并滚动到同一 Job，不提供恢复、重试、归档或授权动作。设计工具镜像的当前示例同步，
历史概念示例仍明确标注未实现；未删除 accepted requirements。

回归保留完整过程：初始跨页用例因页面重建恰好选中最新记录而通过，不能作为复现证据；
收紧为同页旧筛选后，中英文共 4 条断言失败。修正路由后 4 项通过，但图片发现滚动缺口；
新增行可见性断言再复现 2 条失败。最终 **5 项原生用例、0 失败、105.893 秒**，覆盖双语
重复点击、可见目标行、History 筛选/来源和 canonical Flash 回访。8 张修正前后原生 PNG
已查看，仅本机保存；全部属于 App fixture，不记为真机验收。

设计回归先复现身份缺口，最终 **59/59**；设计包、review 与 Recovery 镜像构建通过。
浏览器中英 **48 条断言通过**，覆盖上述十个主窗口入口、五种提示、重复跳转、独立窗口、
旧 unknown 排除和深色模式；13 张原始 1280×720 JPEG 已查看并核对尺寸/哈希。一个包含
既有样本 connect key 的设备详情图保留本机，不进入仓库。未做浏览器 viewport resize，
不将这些图片称为逐像素等价或原生多 banner 布局验收。

统一闸通过：18 项 planner、9 项 workflow、49 项 catalog、7 项 Xcode wrapper；
SDD 0 error/0 warning（121 AC），生成物零漂移。按实际 App 改动编译 App/UI-test bundle；
未改 Package，不分配 Swift Package 全量车道。详见
[F40 验证记录](references/v1.6-goal/recovery-exact-history-verification-2026-08-28.json)。
本项仍需维护者 review/merge；§5 未实现能力保持开放，不提前标记整体 goal 完成。
