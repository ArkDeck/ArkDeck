# 规格 / 设计 / 实现全页差异扫描与修正

日期：2026-08-27 · 基线：`e1d52e68db435bdfeb326962767ca4626a77322b`

## 1. 范围与判定方式

覆盖 **8 个主页面、动态设备页、独立 Settings / Trace Viewer / 帮助、所有子标签与关键弹层**，
共 **62 个检查单元、20 个 App View 文件、31 个组件预览文件**（F41 将窄窗筛选弹层、F42 将 HiLog 摘要单列）。文件、路由和子标签清单由
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
| F03 | “再次运行”承诺预填，但没有 typed inputs 传递 | 保存原始 JSON；仅校验过的只读 observe/capture 可生成新草稿；显示 thread；明确另行启动新 Job；变更操作/旧 Marker/漂移/unknown 拒绝；F44 清除旧 History 来源上下文并将新草稿滚入视口 |
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

以下 **62 个检查单元**均已纳入并完成首轮源码、设计和接线核对；真机与字段级复查继续记录新差异（如 F29）。“已接线”不等于本轮硬件通过。浏览器/App fixture 验证范围见 §4。
2026-08-29 起，每轮逐行核对结论另存 [UI 一致性台账](references/ui-consistency/)；本表只保留每个单元的现行结论。

### 主窗口、全局层、动态设备（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| shell.navigation | 主窗口、菜单、八项导航、空设备、恢复窗口、更新提示 | 八页完整；Settings/Trace Viewer/帮助独立 scene；Automation 退役。F48 将侧栏分组与 Job 检查器词表对回 App，并补 ⌘⇧J；F49 让 Debug/Flash 的窗口标题等于 App 的裸页面名 |
| shell.inspector | 折叠/展开、loading/empty/failed/active/terminal、mode/identity | 精确详情、标准日志显式读取、活动 Job 取消请求已接通；取消先核对 fresh identity；恢复操作不混入控制面。F46 让演示 timeline 双语，F48 补「打开历史记录」并对齐动作文案；F54 补 Runtime 不可用 / 正在刷新 / 空档案三态，以及残留计数、临界写入提示与 established-current-epoch 关系；F56 把两个 Feature 共用的执行模式徽章移入 `DesignSystem/`；F57 把 Job 事实与恢复关系两张表收敛到共享事实网格 |
| shell.recovery | needsAttention、unknown、等待人工、安全边界、等待归档、History 入口 | F40：精确 Job 跳转、清除旧筛选并定位记录行。F41：有界滚动、多记录计数与窄窗工作区保留；原生精确行定位仍在复测，不能视为通过。所有主工作区共享；独立窗口不显示。不确认后续刷、不在 App 归档 |
| device.details | adopted、offline、gone、authorized-unadopted、unknown | 设备行不是隐式 scope；已授权不等于接管。F50 用 `?page=device&deviceDetail=…` 补齐五种候选状态、`stateObservedAt`、CLI 接管说明，并把字段标签与两条说明对回 `Localizable.xcstrings` |
| device.trust | idle/polling/E000002/timedOut/E000003/ready | 有界等待；超时不当 denied；HDC 去 Overview。F47 移除原型残留的「重启共享 HDC server」危险 sheet；F55 把信任页改为与设备详情同构的两栏（状态与操作 + Runtime 事实，缺失字段不补值），补 `device.wait.unavailable` 第四态，并修好使 polling 态整页渲染失败的缺失倒计时格式化函数；F56 把七处自写通知换成共享 `WorkspaceNotice`，八种信任/等待状态共用同一语义色、符号与边框；F57 事实栏九行改用共享行，行距 6→4 |
| device.rename | 右键 rename/re-check、空名称/取消、显示别名 | 不改 binding，重新检测只读候选 |

### Overview（GJ-1/2/4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| overview.main | scope、SSH source、下一步、调试线；empty/ready/多目标/离线/未绑定/stale | 已接线；只列当前在线观察，真实 target→source，不取第一台服务器。F53 补齐设备三态、来源五态、记录四态、按调试线分组与「显示另外 N 次」、需要处理的下一步与四种拒绝原因，并补 ⌘R |
| overview.environment | collapsed/expanded、healthy/mismatch/unknown/permissionDenied | HDC/tool/hash/endpoint/channel/能力完整保留；F53 把披露标题对回 `overview.environment.title`；F54 按 App 重建为服务器与工具链 / 能力 / 所选设备与通道 / 需处理事项四组加高级诊断，能力矩阵为三列并含探测中与探测失败两态 |
| overview.resume | 来源检查 sheet、loading/无参数/target/binding漂移/unknown | F02/F03/F20；精确记录；导航与准备分开；仅安全只读输入复制至新草稿，原始 thread 保留，不复制 authority/session |
| overview.hdcImpact | impact sheet、generation漂移、确认/拒绝 | 已接线；无 proof 不可执行，不自动重启 external server |

### Flash（GJ-4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| flash.main | 镜像 empty/importing/invalid/ready/blocked；主动作；hardwareGated；缓存计划可用性刷新 | 导入和 exact plan 已接线；同页说明影响，不恢复第二确认框；F32 修 Runtime 投影，F33 让缓存计划随当前可用性撤下/恢复动作。F46 让演示 Job 的阶段与终态文案双语；F53 补齐 checking / noDevice / importing / invalid 与失败终态，并让每种阻断都不派发演示 Job |
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
| viewer.main | empty/loading/captured/search/selection/geometryUnavailable/failed | explicit target、同 Job screenshot/tree/hash；不默认伪造 capture。F46 让树、分隔条、搜索导航的 AX 名称与节点计数双语；F54 补历史加载、两种空态原因、抓取失败、坐标不可证明（并撤下命中区）、截图不可用、搜索无匹配与「未测量」页脚 |
| viewer.properties | Properties；identity/state/geometry/paint/missing | 已接线；Provider 技术词表保留英文 |
| viewer.layout | Layout；bounds/root/geometryUnavailable | 无 geometry 不编造命中区域 |
| viewer.accessibility | Accessibility；semantics/focus/missing | 只读观测字段，不把缺值解释成通过 |
| viewer.raw | Raw dump；raw/missing/large | raw origin 不合并覆盖 |
| viewer.advanced | Advanced Dump；lazy/search/noNumericIDs/retry/failed | 已接线；原型/DS 补第五标签 F18；合法 component ID；Fault/Crash/System Snapshot 不属首版 |

### Trace 与独立 Viewer/帮助（GJ-1）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| trace.capture | checking/unavailable/ready/invalid/unitChange/quick | 5/10/15/30秒、1/2/3分钟；原型 F06 已修正。F53 补 checking 可用性、无已接管目标与刷新入口，阻断状态零提交 |
| trace.runtime | submitting/active/cancel/terminal/unknown/blocked | Runtime 状态，typed cancel；原型不证明设备结果。F53 补 Job ID + 取消入口与三种终态（完成 / 结果未知 / 无可查看 Trace） |
| trace.artifact | empty/published/loading/hashMismatch/retry/open | 唯一 raw trace.htrace 校验后打开，不替换失败文档。F53 补已就绪文件名、准备中与校验失败＋重试三态 |
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
| diagnostics.hilogSummary | complete/partial/unrecognized/empty/corrupt/reload/history | F42：已发布 HiLog 摘要的独立只读回访；核对 Job/Artifact、来源 ID 与标准摘要字节，不读取原日志，不把行首统计解释为设备健康或完整采集 |
| diagnostics.concept | 显式未来 capture/recording/finalizing/session/partial/clockGap | 有界 ringBuffered 与部分自动 Marker 已发布；交互式会话/视频/校准仍为单独概念，不混入当前默认。F46 补齐概念页窗口标题与静态 AX 名称；F55 把正文、三个演示 Session 的数据、时间轴上按事实生成的 AX 名称、对齐与原始日志弹层全部改为语言对，设备画面占位仍保留设备原文 |

### History（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| history.list | 八类、search/status/mode/session/target/time/saved/loadOlder/empty | App已实现；原型补筛选，空列表不留无关详情 |
| history.filters | 窄窗筛选与已存筛选弹层；status/mode/session/device/time/reset/Escape | F41 从纵向堆叠改为可展开入口；活动选择与搜索常显。F45 补显式 Escape/外部 pointer 关闭并完成双语浏览器验证；原生与截图验证见 F41/F45 |
| history.detail | Summary/Timeline/Correlation/Evidence/Parameters/Artifacts/Recovery；loading/failed/missing/partial | job与Artifact按需加载；F37/F38 不再补造事实；F39 补全 Summary、Correlation、Evidence 与恢复状态的已实现字段，缺失与明确空清单分开；F56 起执行模式徽章由 `DesignSystem/RuntimeExecutionModeBadge.swift` 提供，History 与 Job 检查器同源；F57 把 Summary / Correlation / Evidence / Parameters 四张表与 `row(...)` 收敛到共享事实网格，等宽值 13→12pt |
| history.export | sensitive preview/cancel/chunk/hashMismatch/save/reveal | 目的地不传daemon；byteCount/hash复算；F37 按 exact Artifact 预览，未发布禁用；与App诊断导出不同 |
| history.context | 在 Flash/Debug/Viewer/Trace/Device/Diagnostics 打开 | App 全部六类保留精确来源；F39 补原型遗漏的来源信息与 Inspector 跳转字段；Diagnostics 可将校验过的 Trace 转交 Viewer；不重放，原型不读取历史文件 |

### Settings（GJ-1—4）

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| settings.general | General；keycap/waveform/build/localOnly | 已接线，版本取bundle。F56 起面板骨架、说明行与构建事实列表走 `WorkspacePage` / `WorkspaceHeaderBar` / `WorkspaceFactGrid` |
| settings.toolchains | Toolchains；loading/choose/probe/missing/activeJobs | 已接线；只影响新Job；来源/hash/ownership保留。F53 补运行中任务时的不同说明与共享的加载/失败/成功行；F56 事实列表改用共享行，路径与 hash 的单行中段省略、悬停全值与可选中由 `WorkspaceFactRow` 承载 |
| settings.servers | Servers；empty/list/refresh/add/edit/remove | 已接线，只读SSH来源，不是四connector。F56 失败横幅换成共享 warn 通知 |
| settings.serverEditor | password/key/defaultKey/probe/fingerprint/root/drift/save/refused | 未验证不能保存；秘密仅Keychain；次级原型已补中英文，修改输入使 demo 验证失效。F56 编辑器内两处失败提示同样换成共享通知 |
| settings.serverDelete | 移除确认/cancel/bindingStale | 只移本地来源，不删远端文件 |
| settings.storage | root/quota/margin/retention/invalid/unknown/pinned | soft claim不保证物理块；不删pinned。F53 补校验失败、未分类字节与用量不可用三态，用量不可用时不显示数字；F56 位置与用量两张事实列表走共享行，存储策略表单因是三列可编辑输入而保留自写 `Grid` |
| settings.traceCache | Trace→Cache；loading/inventory/refresh/purge/activeEntries | 已接线，仅 inactive derived；普通文案双语 |
| settings.traceLicenses | Trace→Licenses；lazy/loading/notice/missing/reveal | 已接线，14 reviewed components；许可证原文保留 |
| settings.updates | idle/checking/current/available/download/verify/consent/error/reveal | 独立Settings，签名校验，显式Finder handoff，不静默安装。F56 面板骨架走 `WorkspacePage` |
| settings.diagnostics | destination/preview/scope/hash/estimatedBytes/export/error | 始终排除device raw；本地显式导出，无上传。F56 预览事实列表走共享行，成功/失败提示换成共享通知的 ok/warn 两态 |

### 系统面与设计镜像

| ID | 页面 / 状态 | 对比结论 |
| --- | --- | --- |
| system.panels | Flash镜像、入口 HAP / 附加 HAP/HSP / .so / HDC / key / root / Trace 导入；日志/Artifact/诊断包保存；Finder | 系统panel已纳入所属流程；不计为新业务页；HTML不真实读写 |
| design.components | Workspace chrome；32预览；light/dark/narrow/focus/disabled | 25 个已声明映射由 24 个新受控组件闭合；SessionSurfaces 与 F51 新增的 ViewerSurfaces 覆盖两组组合式组件；ArkTrace canvas 属上游插图，远程库未同步。BudgetMeters/OperationList/StageTrack/StatusStrip 按 spec §5.11 保留为退役 Automation 资料，原型已无消费方。F56 收敛 App 侧六份重复实现，`WorkspaceFactRow` 扩出四个可选行为承载它们；F57 把 14 处手写键值列表与 8 个行辅助函数收敛到 `WorkspaceFactGrid` / `WorkspaceFactRow`，余下 4 处三列表格/表单记 exception 并由回归强制写明理由 |
| automation.retired | 旧Automation/HTASK稿 | CHG-2026-064已移除；旧URL只解释退役，不是待办 |

### 生产 View 文件索引（23/23）

以下每个文件都由上表中的对应页面/子面覆盖，包含同文件的私有 View；ViewModel/facade/资源随交互追到调用点。

- [App / scenes / navigation](../../ArkDeckApp/App/ArkDeckApp.swift)
- [Workspace chrome](../../ArkDeckApp/DesignSystem/WorkspaceChrome.swift)、[执行模式徽章](../../ArkDeckApp/DesignSystem/RuntimeExecutionModeBadge.swift)
- [Device detail / trust](../../ArkDeckApp/Features/Devices/DeviceWorkspace.swift)
- [Overview record](../../ArkDeckApp/Features/Overview/OverviewRecordView.swift)、[Resume sheet](../../ArkDeckApp/Features/Overview/OverviewResumeSheet.swift)、[HDC / impact](../../ArkDeckApp/Features/HDC/HDCStatusView.swift)
- [Flash workspace](../../ArkDeckApp/Features/Flash/FlashWorkspaceView.swift)、[plan](../../ArkDeckApp/Features/Flash/FlashPlanDetailsView.swift)、[runtime activity](../../ArkDeckApp/Features/Flash/FlashRuntimeActivityView.swift)
- [Debug 五标签与 sheets](../../ArkDeckApp/Features/Debug/DebugWorkspaceView.swift)
- [Viewer 五 Inspector](../../ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift)
- [Trace workspace](../../ArkDeckApp/Features/Trace/TraceWorkspaceView.swift)、[configuration](../../ArkDeckApp/Features/Trace/TraceConfigurationView.swift)、[artifacts](../../ArkDeckApp/Features/Trace/TraceProgressArtifactsView.swift)、[Viewer / Help / Trace Settings](../../ArkDeckApp/Features/Trace/TraceViewerWorkspaceView.swift)、[Trace 标记编辑器](../../ArkDeckApp/Features/Trace/TraceFlagDraftEditor.swift)、[标记标签编辑器](../../ArkDeckApp/Features/Trace/TraceFlagTagEditor.swift)
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

**2026-08-29 F44 继续任务草稿焦点复核**：原生 App 准备新草稿时会清除旧的 History
来源上下文，网页稿仍保留旧上下文和工作区滚动位置；从较低位置点击“准备参数”后，
新草稿可能完全位于视口上方。网页稿现在先清除旧来源、切换到目标工作区，再将工作区
及文档滚动位置归零；不清除底层只读 reader，也不提交 Job。既有交互测试加入旧来源与
非零滚动断言，最终 61/61 通过。

同一浏览器标签完成中英文两轮普通交互。中文轮从 HiLog complete History 样本打开旧
摘要上下文，再为 `S-0826-04` 准备草稿；英文轮在关闭草稿后复用同一 HiLog reader。
两轮准备前工作区滚动均为 454.5px、文档滚动为 35px，准备后均归零；草稿顶部位于
工作区顶部下方 20px，旧来源不存在，HiLog 摘要仍保留，任务检查器均为无运行中 Job。
关闭草稿后 reader 仍可见。两张截图和结构化测量只留本机；这些是设计样本验证，不是
原生 App 或真机证据。本项不修改 App、Runtime、Catalog、准入或历史记录。

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
4. **剩余真机验收与远程设计库**：GJ-1 的新观测、多通道诊断、原生 Diagnostics/Trace/History/Viewer 与录屏已有实测结果；冷启动、原生 stale-frame 和实际 entry+shared HSP 均已有通过记录。2026-08-28 明确授权 HardwareCampaign 后，新 canonical Flash 实际成功并独立核验，campaign 已关闭。F36 合入后双语真实 App 只读回访已通过，活动、精确 History 与旧 unknown 保留均核验；F37 是该回访新发现的稿件摘要/Artifact 差异修正，不重复刷写来补 UI 证据。HiLog 摘要已在 PR #1577 合入，维护者合入后的真实 Runtime 验证已通过；App 只读回访断点的修正与验证见 F42。远程设计库未连接，当前只同步仓库稿件与参考图。

5. **UI 一致性核对的未闭合项**：2026-08-29 首轮全量核对登记的九类差异见文末 F52，
   其中稿件状态补齐属设计工作，App 侧共享件收敛与 Viewer 检查器本地化需要 App 改动与
   对应原生回归；三条待裁决项同处该节。它们不阻塞上述四项能力，也不因登记而被视为已修。

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


## 2026-08-28 F41：恢复提示不能占满工作区

GJ-1—4 的全局恢复呈现。F40 后继续核对多记录状态：原型已有滚动上限，原生 App
却使用无界 VStack；全部记录的自然高度直接挤占下方工作区。修复不超过当前 detail
高度的 45%，并尽可能为下方工作区保留 400pt；空间不足时保留最多受比例上限约束的
96pt 提示视口。短提示按内容收缩，超出后滚动；多条显示总数，宽度不超过 600pt 时
动作移到说明下方。所有 Job 和 unknown 事实保持，不新增执行、归档或重试入口。

复用 History fixture 增加五种恢复状态，并扩展原生回归检查两种窗口尺寸、中英文、
全部五项的可达性、旧筛选清除及 exact History 行。夹具详情明确没有 Runtime 证据，
不借用默认成功详情。前四次执行受系统 automation / LocalAuthentication 阻塞，均未
进入断言。维护者解锁后，真实的 900×652 窗口暴露了纵向筛选挤占空间和分栏越界：
窄窗改为可展开的筛选弹层，活动选择与搜索常显，列表和详情约束在剩余高度内。
弹层筛选功能及三条既有原生回归曾通过；更严格的完整行边界检查仍发现清除空筛选后
部分目标行没有滚到可见区。仅延后滚动和只重建 List 都不足以解决。2026-08-29
系统自动化状态变化后，连续回归实际执行了全部阶段：英文 archive 行仍不可见，中文
human 行状态文字被裁切，均已查看原生截图确认；另有一处键盘切换及其后续断言失败，
日志显示 Return 期间框架重新激活 App。后续安静回合没有再出现键盘断言失败，但
直接在尺寸回调中定位的试验仍有十处行可见性失败，已撤回。当前修正只在显式 Job
路由时一起重建 List 和滚动定位器，明确整行 ID，并用可取消、校验代际的任务居中
定位；普通筛选、翻页和选择保持身份。该修正的最终连续回归已通过：一个 XCTest
入口完成九个阶段，0 失败，495.750 秒；20 次恢复精确跳转与完整行边界检查全部通过。
前一轮二十次跳转同样通过，但两处默认 History 命中测试被其他 App 的文件超时提示
遮挡，截图已确认；提示自行消失后用完全相同的源码重跑通过，没有放宽断言。
此前的初始化超时与锁屏中断记录完整保留；
未代填认证信息、未改系统权限。

同轮按维护者要求合并自动化：六个既有用例的 83 处断言调用保留，改由一个连续入口
执行。原需九次 App 启动，现在每种语言启动一次；实际九个阶段的进程附件确认
英文、中文各自始终使用同一个 PID。阶段间经普通导航/刷新清理页面状态，清理已存
筛选、历史上下文和窗口尺寸；同页精确跳转的轮次不离开 History。后续复测先检查窄窗
恢复，阶段间激活已有 App，并减少重复 AX 几何查询，不放宽完整可见性或滚动次数上限。
最终通过回合的启动日志与九份附件确认启动总数为二、每种语言 PID 不变，四张原生
宽窄窗截图均已查看。这是 App 呈现夹具验收，不是真机操作证据；此前其他工程并发
构建及遮挡导致的失败回合独立保留，不与最终通过回合混用。

设计回归 **60/60**、设计包及镜像构建通过；窄窗筛选与已存筛选弹层已同步网页稿，
中英文五字段边界、筛选后焦点保留、保存/恢复与清除功能有对应检查。Enter/Escape 与
点击外部关闭没有得到成功结果，原因未确认，不声称键盘验收。原生回归结束后的
浏览器复试同样如此；对照的普通语言按钮也未被 Enter 激活，不能据此认定是浮层
实现的根因，也未添加仅为测试通过的事件补丁。浏览器中英文 20 项
工作区、10 项精确跳转检查通过；中断批次与完整复测分开保留。末项截图又暴露原型
搜索随记录滚走，已改为仅记录区滚动；新的 10 项跳转检查同时确认整行位于记录视口、
搜索仍可见。测试只滚动恢复提示区来使按钮完整可见，不代替产品滚动 History。
四张最终原图均已查看。首次全量 Swift 并行车道调度 1,833 项，一项 1 GiB
有界读取测试超时；保持原阈值，在安静环境下修复分支与未改动 main 的同项对照分别
以 0.780 秒、0.841 秒通过。最新 App/测试代码以两个 worker 完整重跑已通过：1,833 项并行测试、
1 项 identity race、5 项 scale，三条 Swift 车道 exit 0；App/UI-test bundle 编译通过。
18 项 planner、9 项 workflow、49 项 catalog、10 项 SwiftPM wrapper、7 项 Xcode wrapper
及 SDD / 生成物零漂移均通过。补齐网页弹层后的统一入口也已通过，最后的搜索视口
修改只触及网页稿与组件分类，设计测试/构建另行通过。此后本轮又调整了原生定位与
连续回归，原生通过后再次完整执行统一入口：gate 05 退出 0，1,833 项并行车道
（1,188 秒）、1 项 identity race、5 项 scale 均退出 0，App/UI-test bundle
再次编译通过；通用闸全部通过，源码哈希与原生通过回合一致。
原超时保留，未用单项结果替代全量。浏览器键盘/外部点击验收仍开放，
后续继续时，旧浏览器标签已关闭，新标签内的复试仍未取得键盘/外部点击通过结果，
显示到前台的请求返回排队。生产/测试源码哈希未变。整轮修正提交为草稿 PR 供审查，
网页未验收项继续保留，不提前声称整项或整体 goal 完成。

已发布 Runtime 的只读全分页查询返回 1,962 条历史、4 条旧 unknown、0 条当前恢复提醒。
因此本轮不能声称真实设备验证了多提醒布局，也不制造设备异常来补图。浏览器样本、
编译/单测与原生验收分别记录于
[验证记录](references/v1.6-goal/recovery-bounded-layout-verification-2026-08-28.json)。

## 2026-08-29 F42：HiLog 摘要成功后的只读回访

对应 GJ-2：有界 HiLog 采集、分析及 History 只读回访。

PR #1577 已将 `analyzer.summarize-hilog@1` 的实现合入。由干净的 reviewed main
`7bfe2892` 构建并签名本机开发 helper，再经 `agentd update` 更新；这不是公证发行包。
HDC、工作区、ArkTrace、ArkForge 配置与已有 Job 历史均保持不变。
已发布 CLI 完成新的有界只读 HiLog 采集，随后同一 daemon 连续完成三条独立摘要 Job；
PID 未变，派生字节一致，独立行首计数匹配，前后读取的原日志字节不变。
全分页核对确认旧 Job 和 unknown 记录未改写。真实日志、标识和哈希仅保存在本机
私有记录；不复制进本 PR。这一结果是 Runtime 真实采集/分析验收，不是 App 呈现验收。

扫描发现 History 已把分析记录归入 Diagnostics，但旧 reader 只接受
`capture.diagnostics@1`；成功的摘要回访因此得到 `diagnostics_unsupported_operation`。
本次增加独立的 HiLog 摘要 reader 和呈现：验证 fresh Job correlation、成功的
hostOnly 分析、来源 lease 标识、标准摘要的 size/SHA-256、闭合 canonical envelope、
版本、计数一致性与 analyzer-output hash。只读至多 16 KiB 标准摘要，不读取原日志，
不连接设备、不提交 Job，不把当前 daemon 的版本当作历史分析器的身份。

页面区分 complete/partial/unrecognized/empty 行首识别状态；明确它们不证明采集完整、
正文编码有效、无故障或设备健康。来源 ID 与 Job 输入一致；来源哈希/大小按已记录事实
展示，不宣称 App 重新读取了原始文件。摘要页没有 Marker/采集/时钟对齐控件，损坏或
相关性失败会清除旧结果。History 返回采集记录时恢复原来的 session reader。

原生连续测试扩展现有 Diagnostics 用例：保留采集、敏感预览和全局日志检查，每种语言
只启动一次，再在同一进程里经过四种摘要状态、损坏拒绝和恢复；重复加载不重启 App。
继续回合补齐损坏摘要的重试拒绝，再返回原采集会话，检查摘要被替换且此前的敏感预览
不会自动恢复；这两个分支仍在同一进程内。它们是新增断言，不是已通过的原生证据。
独立的真实回访用例读取三条已完成 Runtime Job 的私有预期，只经 production XPC
回看，不重新采集或分析；用例将为每条完成的回访保留本机窗口截图供逐图检查，不上传真实标识。
设计稿通过 `?page=diagnostics&hilogSummary=partial` 等显式
样本呈现同样状态；样本数据不充当真实证据。

验证结果：

- 首轮 focused 合约 47 项通过；随后补充的元数据拒绝用例已纳入最终全量回归。
  统一本地闸 exit 0：18 项 planner、9 项 workflow、SDD 0 error/0 warning、49 项
  catalog 与生成物零漂移、10 项 SwiftPM wrapper、1,843 项并行 Swift 测试、1 项进程
  身份竞态、5 项 Viewer 性能测试，以及 7 项 Xcode wrapper 与 App/UI-test bundle
  `build-for-testing` 均通过。
- 最终设计交互 61 项与两种设计构建通过。同一浏览器标签连续核对中英文四种覆盖状态、
  损坏拒绝、重读及恢复；核对精确 History Job，摘要无采集、时钟对齐或原日志预览入口。
  默认窄 viewport 下的来源信息、摘要独立滚动、哈希展开及深色外观已查看；6 张原始
  JPEG 仅留本机。滚动时重载入口相对工作区位置不变，不声称浏览器与原生逐像素等价。
  继续回合在同一标签完成中英文“采集预览 → 摘要 → 原采集”往返：摘要被替换、
  对齐说明恢复、采集仍禁用、旧敏感预览不自动恢复；这仍只是设计样本验证。
- 原生源码和断言在前五次尝试间保持不变。第 1、3、4、5 次在系统启用 automation mode 时
  超时，未进入用例；第 2 次遇到系统输入法授权弹窗后中断。只读主机诊断进一步确认
  测试服务等待 `Enable UI Automation` 的 LocalAuthentication；维护者的前一次认证
  成功时旧测试已结束，第 5 次仍需要新的系统认证。没有代填认证或改变权限。
  第 5 次 exit 65 后才补充上述往返/重试断言，不把旧源码的运行当作新断言通过。
  两个原生用例仍未通过，真实 App 的三条摘要回访也不能登记为通过。

F41 浏览器 Escape 与外部点击关闭的复试仍未取得通过结果，整体 goal 保持开放。
本项以草稿 PR 交付代码，原生验证明确待完成。兼容说明：TASK-AIN-021 仅用作既有
路径护栏，不修改 accepted requirement、Catalog、准入策略或旧治理状态。

## 2026-08-29 F43：共享动作行的尾部对齐与窄窗边界

对应 GJ-1—4 的工作区呈现。F42 已在 PR #1578 合入；本项基于随后更新仓库交付规则的
`5c8252cb`。HiLog 原型的重载按钮仍紧贴标题，而原生 toolbar 使用 `Spacer`；浏览器
实测网页 spacer 宽度为 0、flex-grow 为 0。补齐共享动作行的伸缩间隔与换行后尾部
对齐，覆盖八处既有写法：HiLog、诊断采集、诊断 Marker、History 来源、Overview
只读草稿、全局 Inspector、Trace Viewer 工具栏和事件/范围检查器。不新增检查单元。

逐处检查还发现两处与尾部动作相关的窄窗问题：全局 Inspector 的列最小宽度合计
576px，超出当前 558px 容器，导致右侧说明被裁切；详情列现可收缩，最终 scrollWidth
与 clientWidth 均为 558px。英文 Trace 空窗的采集入口曾独自落到下一行左侧，现将
尾部查看器操作分组，换行时整体靠右，保留显隐/停靠/采集入口的原行为。

最终网页源码在同一标签内完成 18 个中英文连续阶段，覆盖上述八处写法、HiLog 重载、
Trace 空窗/事件/范围/底部停靠/隐藏后恢复；可见尾部元素与所属动作行右边界一致。
检查会排除被祖先裁切的隐藏节点；首轮误包含折叠 Inspector 后代的测量、英文 Trace
换行失败，以及两次草稿标题尚在视口外的未完成检查均保留，未计作最终通过。
相关原始图片已逐图查看，只留本机，不上传示例中的设备字段。新草稿未自动滚入视口
的问题仍需另行修正，本项只在手动滚到草稿后核验动作布局，不声称该路由已通过。

设计交互 61 项、设计包与 review 构建均通过。统一入口退出 0：planner/workflow、
SDD、49 项 catalog 与生成物零漂移通过；路径分类为纯设计/文档，不分配 Swift/App
编译车道。浏览器服务文件与本项提交的原型字节一致。

本项不修改 App、Runtime、Catalog 或准入策略，不执行设备操作。F42 的第 5 次原生
尝试仍因本机 `Enable UI Automation` 身份认证超时而以 65 退出，未开始断言；另一次
Computer Use 连接中断也未完成真实摘要回访。原工作区补充的同实例往返/重试断言
已通过完整本地闸的编译，但未执行，不包含在此布局 PR 中。F41 的网页 Escape/外部
关闭及整体 goal 仍未完成。

## 2026-08-29 F45：History 窄窗筛选弹层显式关闭

对应 GJ-1—4 的 History 交互。F41 已把窄窗筛选改为原生 `popover="auto"`，但完全依赖
浏览器的隐式 light-dismiss。最新稿件在同一浏览器标签重新加载后可稳定复现：弹层已在
top layer，Escape 后仍为 open；点击搜索区域会被弹层遮挡；点击位于弹层外的全局外观
按钮时按钮动作正常完成，弹层仍悬浮。因此先前失败不再只归因于坐标或焦点不确定性。

网页稿现在为当前打开的 History popover 增加显式兼容处理。Escape 关闭弹层并把焦点
交还对应触发按钮；外部 pointer down 先关闭弹层，但不阻止目标控件继续处理点击。
弹层内部与自身触发按钮被排除，保留表单交互和触发按钮的原生切换；从“筛选历史”
切换到“已存筛选”时只保留后者。已有筛选变更后的 DOM 重建、弹层重挂和字段焦点
恢复保持不变。模态框 Escape 仍优先处理，不改变独立 modal 的焦点圈。

交互测试在中英文既有 popover 用例中加入 Escape、内部 pointer、触发按钮与外部 pointer
分支，最终 61/61 通过。同一浏览器标签完成中英文普通交互：两种弹层均可由 Escape 和
外部工具栏点击关闭，Escape 返回精确触发按钮，外观切换仍执行；筛选变更后弹层保持
打开且英文 Status 恢复焦点，触发按钮再次点击可关闭，两个触发按钮之间切换正确。
修正前状态、两张修正后截图与结构化测量只留本机。这里验证的是设计样本，不是原生
App 或真机证据；本项不修改 App、Runtime、Catalog 或设备状态。F42 原生 HiLog reader
回归仍等待本机 automation 身份认证，整体 goal 继续保持开放。

## 2026-08-29 F46–F52：首轮全量 UI 一致性核对

按 [UI 稿与实现一致性核对任务](ui-consistency-audit-task.md) 执行的**首轮全量**回合，
基线 `17a309720954be9d2a2395b538fff029e0b5a2e6`。范围是覆盖表全部 62 个 surfaceID 的六项
协议，加上 `arkdeck-ds/src/index.ts` 的 59 个受控导出与 App 侧重复模式横扫。逐行结论、
证据与 verdict 见 [2026-08-29 台账](references/ui-consistency/2026-08-29-ledger.md)；本节只记
本轮登记的差异。本轮不修改 App、Runtime、Catalog 或准入策略，不执行设备操作，也不翻转
任何 Golden Journey 状态。

**F46（GJ-1—4）设计稿的双语与无障碍名称回落中文。** 英文界面下，原型外框（窗口、工具栏、
侧栏、Job 检查器面板）、Viewer（完整 UI 树、树行「选择组件…」、树/属性分隔条及其
`aria-valuetext`、上一个/下一个搜索结果、检查器标签列表、页脚节点计数）以及 Flash 与
Diagnostics 演示 Job 写入 timeline 的阶段名和终态说明，全部只有中文；这些字符串会出现在
Job 检查器和 History 里。现按 `UIDumpLocalizable.xcstrings` 的既有键值成对补齐，Viewer 复用
App 的 `viewer.tree.label` / `viewer.separator.label` / `viewer.search.previous` /
`viewer.search.next` 措辞，节点计数使用 `viewer.footer.nodes` 的形式。被抓设备自身的界面
文本（节点 text、日志正文）仍保留原文，不翻译。新增两项回归分别断言英文 Flash timeline
不含中文、Viewer 的四个 AX 名称与 App 目录逐字相同。

**F47（GJ-1—4）稿件保留了已退役路径。** 侧栏的「添加 TCP / UART 目标…」入口虽然 `hidden`，
但连同 `addTargetModal()` / `addTarget()`、`.addlink` 样式与本地化键一起留在稿中；
「重启共享 HDC server」危险 sheet（`restartSrvModal`）已被 Overview 的影响预览取代却仍在；
`advanceJob` 的 `pauseAt` 分支与 `rebindOk` / `rebindAbort` 保留了 rebind 确认/中止路径，而
spec §5.8 明确要求当前已发布的 USB / RockUSB Flash 不绘制该控件；`cancelJob` 无调用方；
`historyPreset` 与工具栏实际调用的 `applyHistorySavedAction` 重复实现同一预设逻辑，且当时
只有测试在调用它——测试因此覆盖的是界面从不执行的那条路径。以上函数、样式（`.job`、
`.rebind`、`.addlink`）与对应的 `CLASS_TO_COMPONENT` 条目一并移除，预设测试改为调用工具栏
真正使用的入口。新增回归断言这些标识符不再出现在稿中。

**F48（GJ-1—4）壳层词表与键盘路径与 App 不一致。** 侧栏分组在中文下是「功能」，而 App 的
`app.navigation.section.workflows` 是「工作流」；Job 检查器在中文下是「任务」，而 App 的
`jobInspector.action.show/hide` 用「Job 检查器」——稿件自身也自相矛盾：只有 Device 页在
`render()` 里把这两个标签改写成正确值。现统一到 App 词表并删除该页面特例。检查器的动作
文案对回 `打开此记录` / `请求取消` / `刷新 Job` / `在本机读取日志`，并补上 App 折叠条里有、
稿中缺失的「打开历史记录」。spec §1 要求的 `⌘⇧J` 展开 Job 检查器此前只在 App 里存在，
现已在稿中绑定（`⌘⇧D` 早已存在）。

**F49（GJ-1—4）窗口标题与 App 的 `navigationTitle` 不同。** Debug 页把标题栏写成
「Debug 工作台 / Debug Workbench」，Flash 页在中文下写成「刷机」；App 两页的
`navigationTitle` 都是裸页面名 `Debug` / `Flash`（`app.navigation.*` 在两种语言中均为英文）。
现改为裸页面名，并由回归断言标题集合中不再出现「工作台 / Workbench / 刷机」。

**F50（GJ-1）设备详情只有一种状态，字段标签也已过期。** `DeviceDetailView` 按候选状态渲染
ready / authorized-unadopted / offline / needs-recheck / unknown 五种说明，并在已授权未接管时
说明接管由 CLI 执行；稿件固定渲染一条「已接管且已连接」提示，其余状态不可达。事实栏
缺少 `device.fact.stateObservedAt`，`model` / `firmware` / `transport` 仍用旧的
「观测机型 / 观测固件 / 观测传输」，重新检测说明与来源说明也停留在旧文案。现补
`?page=device&deviceDetail=ready|authorizedUnadopted|offline|needsRecheck|unknownState`
五种状态，文案逐字取自 `Localizable.xcstrings` 的 `device.trust.*` / `device.state.*` /
`device.fact.*` / `device.detail.*`，CLI 接管说明只在 authorized-unadopted 出现。回归覆盖
五状态 × 中英文，并直接与 App 的本地化目录比对，任何一侧改名都会失败。

**F51（GJ-1）五个受控 Viewer 组件没有 preview。** `ViewerWorkspace`、
`ViewerInspectorStack`、`ViewerScreenshot`、`ComponentTree`、`DumpInspector` 有
`CLASS_TO_COMPONENT` 映射和 App 对应物（`UIDumpWorkspaceView.swift`），却既没有自己的
preview，也不被任何 preview 引用——59 个受控导出里唯一的一组缺口（其余 24 个 session 组件
由 `SessionSurfaces.tsx` 覆盖）。新增 `.design-sync/previews/ViewerSurfaces.tsx`，按这五个
组件真实的组合形态给出联动选择与默认隐藏边界两个样本；截图是内联绘制的示意图，明确
声明为设计样本，不冒充 capture。`implementation-coverage.json` 的 `previewFiles` 随之为
32 个，32 个 preview 均可独立打包。

**F52（GJ-1—4）本轮登记但未在本 PR 修正的项。** 以下差异已逐条核实并写入台账，修正需要
另一轮设计工作或触碰 App 代码与原生回归，本轮不静默放过、也不冒充已修：

1. **原型缺少已实现的状态**（实现有、稿不可达）。Overview 的多目标选择、未绑定/stale/
   不可用的编译来源、记录区 loading/unavailable/empty、下一步的 attention/empty 与四种
   拒绝原因、按调试线分组与「此前 N 次」展开；Flash 的 checking / noDevice / importing /
   invalid / failed；Viewer 的 loading / geometryUnavailable / failed 与 footer「未测量」；
   Trace 的 checking 可用性、无已接管目标、刷新入口，以及「查看 Trace」的已发布文件名 /
   准备中 / 校验失败与重试；Trace 运行态的 terminal 与 outcomeUnknown；Job 检查器的
   Runtime 不可用、残留计数、临界写入提示与 established-current-epoch 关系；
   Settings 七个面板的 loading / error / success；`device.wait.unavailable`。
2. **概念页与样本数据单语**。Diagnostics 概念页的窗口标题与静态 AX 名称已在 F46 补齐，
   但该页可见正文与时间轴上按事实生成的 AX 名称（Marker、截图、Trace event、日志点、
   时间光标）仍只有中文。History 样本记录的 `when` / `day`（「今天 14:32」「昨天」）与
   四条 `what` / `detail`（「设置页组件树」「应用响应 · 30 秒」「设置页启动闪退」
   「128 个节点 · /settings/display」）在英文 Overview 与 History 中原样显示；它们是记录
   摘要文案而不是设备原文，应当成对。改法需要把 `HIST` 的展示字段与语言解耦，
   影响面大于本轮批次，故登记。
3. **信任页缺 Runtime 事实栏**。App 对每种状态都渲染「当前状态与操作 + Runtime 事实」
   两栏；稿件的 `auth` 页是独立卡片，没有事实栏（spec §5.2 要求接管引导在同一详情中）。
4. **App 侧共享件未被复用**（C-DUP，需 App 改动与原生回归）：
   `DeviceWorkspace.swift` 的 `deviceNotice(...)` 在同一文件已经使用 `WorkspaceNotice`
   的情况下另写了一份等价实现并调用 8 次；`SettingsRootView.swift` 的
   `SettingsErrorBanner` / `SettingsSuccessBanner` 重复 `WorkspaceNotice`、
   `SettingsPaneContainer` 重复 `WorkspacePage`、`SettingsPaneHeader` 重复
   `WorkspaceHeaderBar`、`SettingsValueGrid` 重复 `WorkspaceFactGrid` + `WorkspaceFactRow`
   （后者额外需要单行中段省略，收敛时应扩展共享件而不是保留副本）；
   `DiagnosticsWorkspaceView.swift`（39 处）与 `DeviceWorkspaceView.swift`（30 处）用
   `.font(.system(size:…))` 和字面间距绕过 `WorkspaceFont` / `WorkspaceMetrics`，占全 App
   此类写法的全部；九个 Feature 文件里 19 处手写 `Grid(` 键值列表未使用
   `WorkspaceFactGrid`；跨 Feature 共用的 `RuntimeExecutionModeBadge` 定义在
   `Features/History/RuntimeHistoryView.swift` 而不是 `DesignSystem/`。
5. **App 普通 UI 绕过本地化目录**。`UIDumpWorkspaceView.swift` 的 `ViewerInspectorCopy`
   把「选择一个组件」「原始字段不可用」「重试」「搜索字段或值」「清除搜索」「没有匹配的
   字段或值」等普通文案硬编码为英文，而 `UIDumpLocalizable.xcstrings` 里这些键都有中文
   译文且无人引用。spec §5.3 只把 `Properties / Layout / Accessibility / Raw dump /
   Advanced Dump` 等 Provider 技术词表列为保留英文，空态提示与搜索控件是否属于该豁免
   需要维护者裁决——见下方待裁决清单。
6. **资源里的已移除路径残留**：`debug.apps.install.fresh`、`debug.apps.cleanup.restore`
   （F26 后策略固定，不再渲染）等 11 个 Debug 键、13 个 Diagnostics 交互式会话键、
   29 个 Flash 旧审阅页键、6 个 History 表列键与 4 个 Settings 标题键当前无引用。
7. **退役 Automation 的稿件样式残留**：`.op-list`、`.budget-grid`/`.metric`/`.meter`、
   `.stage-line`/`.stage-node`、`.summary-strip`/`.summary-cell` 仍有 CSS 与组件映射，
   但原型已无任何标记使用它们。spec §5.11 要求把 OperationList / BudgetMeters /
   StageTrack / StatusStrip 保留为历史组件资料，因此本轮不删，只登记。
8. **preview 无构建守护**：`tsconfig.json` 只包含 `src/**`，`npm run build:review` 只打包
   `session-review.tsx`，因此 32 个 preview 既不被类型检查也不被 npm 脚本打包；本轮的
   逐个打包是手工执行的。
9. **`Select` 没有原型 class 映射**：稿件用 `<select class="inp">`，`.inp` 已映射到
   `TextField`，而 `CLASS_TO_COMPONENT` 是 class→component 单向检查，因此该导出永远不会
   被守护。语义等价存在，故记 exception。

### 待维护者裁决

1. **内容区是否允许重复工具栏页面标题。** spec §8 明确「任何工作区的内容区都不再画与
   toolbar 同名的主标题」，但 `DiagnosticsWorkspaceView` 的自绘工具条渲染
   `diagnostics.title`（两种语言都是 `Diagnostics`），与 `navigationTitle` 完全同名；
   原型的 Diagnostics 页同样在内容区显示 `<b>Diagnostics</b>`。两侧一致而与 spec 冲突，
   按纪律不静默改任一侧。建议：删除两侧的重复标题，把重新加载与对齐状态留在同一行。
2. **Viewer 检查器的英文保留范围。** 上述第 5 条需要一条边界：哪些是 spec §5.3 所指的
   Provider 技术词表（保留英文），哪些是应走目录的普通 UI。建议按「字段名与分类保留英文、
   空态/动作/搜索控件走目录」裁决，并据此清理无人引用的中文键。
3. **App 侧 C-DUP 的收敛取舍。** 第 4 条列出的重复实现是否收敛为共享件、以何种顺序收敛，
   属产品判断；收敛会改变实际呈现（例如 `WorkspaceNotice` 会给 Settings 的成功/失败横幅
   加上语义色边框与浅底），需要对应的原生回归窗口。

### 验证

- 设计侧：`npm test` **65 项通过**（本轮新增 4 项回归：设备详情五状态双语、退役路径无
  残留与窗口标题、壳层词表与演示 timeline 双语、Viewer AX 名称与节点计数）；
  `npm run build` 与 `npm run build:review` 通过；`check:tokens` 报告每个原型 class 均已
  分类；32 个 preview 逐个独立打包通过。
- 统一本地闸按实际 diff 分类为纯设计/文档车道，不分配 Swift / App 编译车道。
- 本轮没有浏览器像素走查，也没有原生或真机验证；上述结论只证明稿与代码的一致性范围，
  不构成 App 呈现验收或硬件验收。

## 2026-08-29 F53：原型状态补齐（Overview → Flash → Trace → Settings）

首轮全量核对（F46–F52）的第二批，基线 `98bedbbe`（PR #1586 合入后的 `main`）。范围是
F52 第 1 条登记的「实现有、稿不可达」在这四个工作区上的部分；逐行结论见
[2026-08-29 批次二台账](references/ui-consistency/2026-08-29-states-ledger.md)。本批只改设计侧，
不修改 App、Runtime、Catalog 或准入策略，不执行设备操作。

所有新增状态都由显式 URL token 到达，文案逐字取自 App 的本地化目录，并由新增的四项回归
直接与 `.xcstrings` 比对——任一侧改名即失败。

**Overview**（`overviewDevice` / `overviewServer` / `overviewRecords` / `overviewEvidence`）。
设备域此前只有一台已绑定设备：现补「多目标 picker + 选择一台设备…」与「暂无在线设备」。
编译来源此前只有已绑定：现补正在读取、未绑定、绑定需要处理与无法读取，各带 App 的说明句。
记录区此前只有一份可用列表：现补正在读取、无法读取（含 reason code）与空态。记录本身此前是
四条扁平行：现按 `OverviewRunRecordProjection` 的规则分组为调试线——needsAttention 置顶、
每线一条 featured run、其余收进有界的「显示另外 N 次」，并给样本数据补了一条两次运行的
Viewer 调试线。每行的「再来一次」改为 `resumeDisposition` 的完整六分支：可重复、需要重新
授权、未读取证据（禁用）、不可重放、仍在运行、未记录效果分级、未上报 typed inputs——后四种
显示拒绝原因而不是按钮。下一步区补「需要处理」形态与空态。补 `⌘R`，且和 App 一样只在
Overview 可见时生效；环境披露标题对回 `overview.environment.title`。

**Flash**（`flashState` 扩为 `checking|hardwareGated|noDevice|importing|invalid|failed`）。
补正在检查 Runtime 可用性、需要设备、正在导入镜像、镜像无效（含重新校验）与失败终态。
`flashBlocker()` 按 App 的顺序（可用性 → 目标 → 镜像导入与校验）返回第一条阻断原因，
主动作被原因取代，`runFlash()` 在任一阻断下零派发——回归对四种阻断都断言选完镜像后仍
不创建 Job。失败终态显示「刷机已停止」＋Runtime 失败说明＋未提供完整刷写后证明，
不出现成功标题。镜像选择帮助文案与成功说明对回 App（旧稿说「支持 Runtime 已发布的镜像包」，
App 说的是受支持的三种压缩格式）。

**Trace**（`traceState` 扩出 `checking|noTarget`，新增 `traceCapture` 与 `traceArtifact`）。
可用性补「正在检查…」第三态；无已接管目标时设备行显示 `trace.target.empty` 并以
`trace.blocker.target` 阻断提交。采集页脚按 App 的单一可行动行渲染：进行中、提交失败、
三种终态（抓取完成 / 结果未知 / 抓取已结束但没有可查看的 Trace）、首个阻断、本地保存说明。
进行中时开始按钮替换为 Job ID ＋取消。「查看 Trace」区补已就绪文件名、正在校验并打开、
校验失败＋重试打开三态——**终态成功与「有可查看的 Trace」是两件事**，稿件现在分开表达。
补刷新入口。

**Settings**（`settingsState` / `settingsJobs` / `settingsStorage`）。七个面板共用的加载、
失败与成功三行此前完全不可达，现按 App 的共享行补齐并对每个面板断言。工具链在有运行中
任务时改用 `settings.toolchains.futureJobsActive` 的不同说明。存储补校验失败、未分类字节
与用量不可用三态；用量不可用时不再显示任何用量数字。

同批还关闭了 F52 第 2 条的 History 样本一半：`when` 与四条 `what` / `detail` 改为语言对，
经新的 `histText()` 解析，Overview 与 History 两处渲染同步；设备原文不受影响。

### 本批未覆盖

- Job 检查器的 Runtime 不可用、残留计数、临界写入提示与 established-current-epoch 关系
  （F52-1 剩余部分）。
- Viewer 的 loading / geometryUnavailable / failed 与 footer「未测量」（F52-1 剩余部分）。
- Overview 环境披露的 Selected Device/Binding 与 Needs Attention 分组、能力矩阵三列。
- Diagnostics 概念页正文与时间轴 AX 名称的单语（F52-2 剩余部分）。
- 信任页缺 Runtime 事实栏（F52-3）；App 侧 C-DUP 与 Viewer 检查器本地化（F52-4/5）；
  资源残留、退役 Automation 样式、preview 构建守护、`Select` 映射（F52-6~9）。
- F52 的三条待裁决项保持开放。

### 验证

- `npm test` **69 项通过**（新增 4 项：Overview 状态与调试线分组、Flash 四种阻断零派发与
  失败终态、Trace 可用性/终态/产物三组分离、Settings 七面板三行状态）。四项都直接读取
  `Localizable` / `FlashLocalizable` / `TraceLocalizable` / `SettingsLocalizable`，用 App 的
  字符串断言，不复制第二份词表。
- `npm run build`、`npm run build:review` 通过；`check:tokens` 每个原型 class 均已分类。
- 统一本地闸退出 0，按实际 diff 分类为纯设计/文档，不分配 Swift / App 编译车道。
- 未做浏览器逐页走查、未跑原生 XCUITest、未执行设备操作；本批只证明稿与代码一致。

## 2026-08-29 F54：原型状态补齐（Job 检查器 + Viewer + Overview 环境披露）

首轮全量核对的第三批，基线 `93b24ae3`（PR #1587 合入后的 `main`）。范围是 F52 第 1 条在
这三处的剩余部分；逐行结论见
[2026-08-29 批次三台账](references/ui-consistency/2026-08-29-inspector-ledger.md)。
只改设计侧，不修改 App、Runtime、Catalog 或准入策略，不执行设备操作。

**Job 检查器**（`inspectorState` / `jobFacts`）。此前 `job.list` 的可用性根本不进稿：无论
Runtime 是否可达都直接渲染一份列表。现按 App 分出正在刷新、Runtime 不可用（含 reason code
与「启动或重新连接 ArkDeck Runtime」指引）与「Runtime 可访问但尚无 Job」三态，折叠条同步
显示对应摘要。逐 Job 的事实补齐：残留计数（列表用紧凑徽标、详情用整句）、临界写入提示、
以及 established-current-epoch 关系——后者把状态标签换成「当前状态已建立」、显示恢复关系
ID 与**原始记录状态**，并撤下未知结果警告与取消入口，与 App 的 `hasEstablishedCurrentEpoch`
分支一致。折叠条补进行中计数与已运行时间。

**Viewer**（`viewerState` 扩为 `loading|captured|geometryUnavailable|screenshotUnavailable|
noMetrics|failed`，新增 `viewerEmpty`）。空态此前只有一种说明，现分出「先选择一个绑定完整的
已纳管目标」与目标不可抓取两种原因，并在抓取失败时显示失败原因而不是沉默。打开历史 capture
是独立的加载态，不再被当成「还没有 capture」。坐标系无法证明时，页头标注、页脚说明齐备，
**并且不再渲染任何截图命中区**——树与 Raw dump 仍可读，这正是 App 的做法。截图无法解码时
显示「截图不可用」。页脚在没有采集 metrics 时显示「未测量」，不再总是打印同一组数字。
树搜索无匹配时说明「没有匹配的组件。当前选中项未改变。」，选中项确实不变。

**Overview 环境披露**（`overviewCapabilities` / `overviewAttention`）。此前是两张概括卡
（HDC、能力与需要处理的事项）。现按 `HDCStatusView` 重建为 spec §5.1 要求的四组加高级诊断：
服务器与工具链（健康、来源、绝对路径、哈希、平台信任、三个版本、端点 + 选择 HDC）、
能力（归属、子服务器能力、服务器恢复 + 三列能力矩阵）、所选设备与通道（授权、通道保护、
近期设备事件）、需处理事项（无事项说明或逐条事项＋原因＋最小下一步），以及只保留影响预览的
高级诊断。能力矩阵补探测中与探测不可读两态；探测失败时不显示任何能力行。

### 本批未覆盖

- Diagnostics 概念页正文与时间轴 AX 名称的单语（F52-2 剩余）。
- 信任页缺 Runtime 事实栏（F52-3）。
- App 侧共享件收敛与 Viewer 检查器硬编码英文（F52-4/5）——需要 App 改动与原生回归。
- 资源里的已移除路径键、退役 Automation 样式、preview 构建守护、`Select` 映射（F52-6~9）。
- F52 的三条待裁决项保持开放。

### 验证

- `npm test` **72 项通过**（新增 3 项：Job 检查器三态与逐 Job 事实、Viewer 六态与无匹配
  搜索、Overview 环境五组与矩阵三态）。三项都直接读取 `JobsLocalizable` /
  `UIDumpLocalizable` / `Localizable`，用 App 的字符串断言。
- `npm run build`、`npm run build:review` 通过；`check:tokens` 每个原型 class 均已分类。
- 统一本地闸退出 0，纯设计/文档车道，不分配 Swift / App 编译车道。
- 未做浏览器逐页走查、未跑原生 XCUITest、未执行设备操作。

## 2026-08-29 F55：Diagnostics 概念页双语与信任页 Runtime 事实栏

首轮全量核对的第四批，基线 `e914beed`（PR #1588 合入后的 `main`）。范围是 F52 第 2 条剩余
部分与第 3 条；逐行结论见
[2026-08-29 批次四台账](references/ui-consistency/2026-08-29-concept-ledger.md)。
只改设计侧，不修改 App、Runtime、Catalog 或准入策略，不执行设备操作。

**先更正一处上一批的过头结论。** F54 的记述写了「F52 第 1 条至此全部闭合」，但该条列举的
`device.wait.unavailable` 当时并未实现，批次三也没有触碰信任页。正确说法是：F52 第 1 条在
批次二、三闭合了 Overview / Flash / Trace / Settings / Job 检查器 / Viewer 六处，
`device.wait.unavailable` 直到本批才补上。原记述保留，不改写，以本段为准。

**Diagnostics 概念页双语。** 概念页的正文此前几乎全部只有中文：当前画面与三种缺画面说明、
选中事件与光标离开事件的说明、邻近日志与无法对齐说明、时间轴标题与所有按事实生成的 AX
名称（录屏 Frame、Marker 截图、Trace event、日志点、Marker、时间光标）、新建诊断页的
preset、通道、高级设置与边界说明、录制页与生成结果页的全部文案、Marker 状态行，以及时间
对齐弹层与原始顺序日志弹层。三个演示 Session 的 `label` / `alignChip` / `alignRows` /
`alignNote` / `partialReasons` / marker 标签，以及演示采集结束后生成的新 Session，也都是
稿件自己写的文案，现在统一存为语言对，由通用的 `bi()` 解析（原 `histText()` 泛化并保留为
别名）。被抓设备自身的界面占位（设置 / 搜索设置项 / WLAN 已连接等）与 HiLog 正文、
Trace event 名保持原文不译——它们是设备输出，不是 ArkDeck 文案。

**信任页 Runtime 事实栏。** spec §5.2 要求未授权设备的接管引导位于同一设备详情中，
`DeviceDetailView` 对每种状态都渲染「当前状态与操作」和「Runtime 事实」两栏；稿件的
`auth` 页此前是一张独立卡片，没有事实栏。现改为与设备详情同构的 `device-layout` 两栏，
文案逐字取自 `Localizable.xcstrings`（`device.trust.waiting` / `stepsTitle` / `step1–3`、
`device.detail.statusTitle` / `factsTitle` / `recheckNote`、`device.action.beginWait` /
`retryWait` / `recheck`）。事实栏只列未授权候选真正报告的三项——connect key（脱敏）、
报告状态、状态观测时间——**不为 target、binding revision、机型、系统版本补演示值**，回归
直接断言这些行不存在。有界等待补齐第四态 `device.wait.unavailable`（「无法检查设备授权」
＋ reason code），与超时区分开：不可检查不是已知拒绝。信任成功后按 App 的语义显示
「已授权。该设备尚未被接管为持久目标。」并给出 CLI 接管说明，而不是把信任当成接管。

**顺带修好一处稿件缺陷。** `fmtLeft()` 被信任页的倒计时和轮询 tick 引用了两处，却从未定义。
结果是：只要进入 polling 态，`pAuth()` 抛 `ReferenceError`，整页停止渲染——点击「开始等待
授权」在浏览器里是坏的。这在合入的 `main` 上可复现，属于既有缺陷而非本轮引入。现补上
mm:ss 的格式化实现，并由回归断言倒计时确实渲染。

### 本批未覆盖

- App 侧共享件收敛与 `ViewerInspectorCopy` 硬编码英文（F52-4/5）——需要 App 改动与原生回归。
- 资源里的已移除路径键、退役 Automation 样式、preview 构建守护、`Select` 映射（F52-6~9）。
- F52 的三条待裁决项保持开放。

### 验证

- `npm test` **74 项通过**（新增 2 项：概念页四个视图与三个 Session 在英文下无中文回落且
  弹层同样覆盖；信任页两栏结构、缺失字段不补值、四种等待答复与倒计时渲染）。两项都直接
  读取 `Localizable.xcstrings` 或按设备输入白名单排除设备原文。
- 全页英文扫描：20 组页面/状态组合中，除设备画面占位与设备日志正文外，**不再有中文回落**。
- `npm run build`、`npm run build:review` 通过；`check:tokens` 每个原型 class 均已分类。
- 统一本地闸退出 0，纯设计/文档车道，不分配 Swift / App 编译车道。
- 未做浏览器逐页走查、未跑原生 XCUITest、未执行设备操作。

## 2026-08-30 F56：App 侧共享件收敛（C-DUP，第一批）

首轮全量核对的第五批，基线 `9e80901f`（PR #1589 合入后的 `main`）。范围是 F52 第 4 条
登记的 App 侧重复实现里**成套重写共享件的那一半**：设备详情自写的通知、Settings 自写的
面板骨架/说明行/事实列表/成功失败横幅，以及两个 Feature 共用却放在 History 里的执行模式
徽章。逐行结论见
[2026-08-30 台账](references/ui-consistency/2026-08-30-shared-chrome-ledger.md)。
本批**触碰 App 代码**，因此跑了原生 XCUITest 全套作为回归；不改 Runtime、Catalog 或准入
策略，不执行设备操作，也不新增任何产品能力。

**先更正一处登记时的计数。** F52 第 4 条写 `deviceNotice(...)` 「调用 8 次」，实测是
**7 处调用 + 1 处定义**；第 4 条还写这两个工作区的 `.font(.system(size:…))` 「占全 App 此类
写法的全部」，实测 73 处里有 4 处在 `UIDumpWorkspaceView` 与 `FlashWorkspaceView`。两处都
不影响该条的结论，但台账按实测数记。

**设备详情的通知。** `DeviceWorkspace.swift` 在同一文件已经使用 `WorkspaceNotice`
（有界等待的 polling 态）的情况下，另写了一份 `deviceNotice(_:systemImage:color:identifier:)`
并调用 7 次。两者的内边距、圆角与描边透明度逐字相同，差别只在：自写版用 `Label`、把
12pt 字号也套在图标上、`.secondary` 态直接用 `Color.secondary.opacity(0.08)` 而不是共享的
`quaternaryLabelColor` 中性底，且不做 `accessibilityElement(children: .combine)`。现在七处
全部改用 `WorkspaceNotice`，语义色按既有取值映射（orange→`.warning`、green→`.ok`、
red→`.danger`、secondary→`.neutral`），符号逐个原样传入，标识符不变。**可见变化**：两处
中性态（`device.trust.offline`、`device.trust.unknownState`）的底色与描边改为 App 其余中性
通知的取值，图标由 12pt 回到 13pt，八处通知都成为一个合并的可访问性元素。

**Settings 的五份副本。** `SettingsPaneContainer` 重写 `WorkspacePage`、`SettingsPaneHeader`
重写 `WorkspaceHeaderBar`、`SettingsValueGrid` + `SettingsValueRow` 重写
`WorkspaceFactGrid` + `WorkspaceFactRow`、`SettingsErrorBanner` / `SettingsSuccessBanner`
重写 `WorkspaceNotice`。六个类型全部删除，六处面板、五张事实列表与七处横幅改走共享件。
按 F52 的判断，事实列表**扩展共享件而不是保留副本**：`WorkspaceFactRow` 增加四个默认关闭的
可选行为——`usesTabularDigits`（非等宽值仍保持数字列对齐）、`usesMonospacedName`（键本身
是值，例如 Runtime 参数名）、`isSelectable`、`elidedValue`（单行中段省略 + 悬停全值 +
VoiceOver 读全值）。**可见变化**：面板上下内边距由 24/24 改为共享的 20/28；说明行不再被
620pt 的行宽夹住；失败与成功横幅从「整行橙/绿字 + 中性描边」变为共享通知的「语义色符号与
描边 + 浅底 + 常规字色」，即颜色不再是唯一载体（spec §2、§4.4）。

**执行模式徽章的归属。** `RuntimeExecutionModeBadge` 由 History 与 Job 检查器两个 Feature
渲染，却定义在 `Features/History/RuntimeHistoryView.swift`。现移入
`ArkDeckApp/DesignSystem/RuntimeExecutionModeBadge.swift`，实现逐字不变，只补一段说明它
为何不属于 History。`appViewFiles` 随之为 21 个，§3 的生产 View 索引同步。

### 本批未覆盖

- F52 第 4 条的另一半：9 个 Feature 文件里 19 处手写 `Grid(` 键值列表（其中 15 处是事实
  列表、4 处是三列表格或可编辑表单），以及 73 处 `.font(.system(size:…))` 绕过
  `WorkspaceFont` / `WorkspaceMetrics`。两者都会改变实际字号与行距，单独成批更好复核。
- `ViewerInspectorCopy` 硬编码英文（F52-5）——等待第 2 条裁决。
- 资源里的已移除路径键、退役 Automation 样式、preview 构建守护、`Select` 映射（F52-6~9）。
- F52 的三条待裁决项保持开放；本批只收敛「共享件已存在且语义等价」的重复，不替维护者
  决定第 1、2 条。

### 本批发现但未修的原生失败（新登记）

原生 XCUITest 全套在**未改动的 `main`** 上就是红的，本批没有把它变绿，也不声称它绿。
三条失败在同一台机器上跑了三次（改前全套、改后全套、clean `main` 定向）逐条归因；
完整对照表见台账第 6 节。其中一条是环境前置，已修；另两条登记如下。

1. **`AppShellUITests.testDebugHAPSelectionAddsHSPRejectsDuplicatesAndClearsInBothLanguages`
   顺序/负载相关不稳定。** 全套跑两次都失败在 `AppShellUITests.swift:1154`
   （`app.popUpButtons["debug.apps.postRun"]` 15 秒内不存在），**单独跑通过**。该 Picker 在
   `DebugWorkspaceView.lifecycleSection` 中无条件渲染，本批未触碰 Debug 工作区。是产品缺陷
   还是测试对全套环境的依赖，**本轮未定根因**，不臆断。
2. **`AppShellUITests.testHistoryAndRecoveryContinuousSessionInBothLanguages` 的精确行定位
   断言在 `main` 上失败。** clean `main` 单独跑复现同一断言、同一 viewport
   `(483.0, 448.5, 342.0, 189.5)`。测量事实：表格 viewport 高 189.5pt（底边 638），被要求
   完整可见的记录行在 y=626 / y=696，20 次滚动后仍未进入视口。这与 §3 `shell.recovery`
   行里既有的「原生精确行定位仍在复测，不能视为通过」是同一条，本条补上可复现的几何数字。
   **根因未定**，本批不改 History。

第三条 `HDCStatusUITests.testProductionSandboxRejectsRepositoryFakeBeforeAnyHDCProbe` 是
环境前置缺失——`Packages/ArkDeckKit/.build/debug/ArkDeckFakeHDCFixture` 在本工作副本里
从未构建。补齐后改后运行即通过（失败 3→2、通过 45→46）。这是本批对原生结果的唯一正向影响，
与共享件收敛无关。

### 验证

- **原生 XCUITest 全套跑了三次**：改前基线（`9e80901f`，未改动）**45 通过 / 3 失败 /
  11 跳过**；改后 **46 通过 / 2 失败 / 11 跳过**；另在 clean `main` 上定向重跑两条失败用例
  归因。**两次全套都是红的**，逐条归因见上一节与台账第 6 节；本批没有引入新的失败，
  唯一的正向变化来自补齐 HDC fixture 前置。macOS UI 套件是本地门禁，不在 CI。
- 原生断言覆盖到设备信任/等待八处通知与各 Settings 面板的可达性；**没有**覆盖 Settings
  的失败/成功横幅（App 无可确定性触发 Settings 错误的 fixture 参数，本批不为凑断言新增
  测试专用产品路径），也没有测量内边距、行宽与通知底色这类纯呈现变化。
- `npm test` **75 项通过**（新增 1 项结构回归：副本确已消失、共享行带齐四个可选行为、
  八处设备通知仍可按标识符寻址、徽章声明在 `DesignSystem/` 而不在 History）。
- `npm run build`、`npm run build:review` 通过；`check:tokens` 每个原型 class 均已分类。
- 统一本地闸 退出 0；本轮首次分配 App 编译车道（分类为 `app: true` / `swift: false`，`build-for-testing` 通过），SDD、catalog 与设计车道同跑通过。
- 未做浏览器逐页走查，未执行设备操作。**绿的部分只证明这些断言覆盖到的行为未回归，
  不构成 App 呈现验收，不构成真机验收，不翻转任何 Golden Journey 状态。**

## 2026-08-30 F57：键值列表全部走共享事实网格（C-DUP，第二批）

首轮全量核对的第六批，基线 `fb6e5993`（PR #1590 合入后的 `main`）。范围是 F52 第 4 条剩下的
两半里的第一半：9 个 Feature 文件里 19 处手写 `Grid(` 中**属于键值事实列表的 14 处**
（第 15 处 `SettingsValueGrid` 已在 F56 收敛）。逐行结论见
[2026-08-30 批次六台账](references/ui-consistency/2026-08-30-fact-grid-ledger.md)。

**14 处列表与 8 个行辅助函数。** 每个工作区都自己写了一份「`GridRow` + 次要色键 + 带字体的
值」：History 的 `row(...)`、Job 检查器的 `factRow` / `recordedStateFactRow`、Flash 的
`summaryRow`、Flash 运行态的 `factRow`、HDC 的 `field(...)`、Debug 的 `planFact`、Diagnostics 的
`hilogCount`，以及设备详情里逐行展开的九个 `GridRow`。八个辅助函数现在一律返回
`WorkspaceFactRow`，设备详情新增同名的 `deviceFact` 收口；容器一律 `WorkspaceFactGrid`。
`HDCStatusView.FieldTextStyle` 随之删除——它的 plain / monospaced / digits 三态正好就是共享行的
`isMonospaced` 与 `usesTabularDigits` 两个选项。

**可见变化（两类，都是被修的缺陷本身，不是顺带）：**

1. **等宽值 13pt → 12pt。** History、Job 检查器、Flash 计划摘要与 Flash 运行态此前用
   `.body.monospaced()`（13pt），共享行用 `WorkspaceFont.monospacedValue`（12pt）。spec §2 的
   「路径、hash、版本、序列号、设备与 Job ID = 12 mono」只有一个尺寸，收敛即对齐。
2. **行距 6pt → 4pt。** History 三张表与设备详情事实栏此前用 `WorkspaceMetrics.tightGap`(6)，
   共享网格用 `rowGap`(4)，即原型 `.kv{gap:4px 14px}`。Flash 计划摘要的字面 12/6、
   Diagnostics 计数表的字面 24/8、Debug 的 `blockGap` 横向间距同样归一到 14/4。

**保留自写 `Grid(` 的四处，逐条写明理由（记 exception）。** Settings 存储策略是「标签 + 输入框
 + 单位」三列可编辑表单，行内是控件而非只读值，需要更大的行距；`FlashWorkspaceView`
的计划阶段摘要、`HDCStatusView` 的能力矩阵与设备事件表都是带表头行与分隔线的三列表格。
理由写进代码注释，并由回归强制——任何 App View 文件里出现裸 `Grid(` 而上方两行没有写
「not a WorkspaceFactGrid」，测试即失败。

**HDC 诊断字段刻意不可选中，这条约束被显式保留。** 原注释记着：macOS 上开启文本选中会改变
可访问性表示，使只读值对 UI 自动化不可见，所以该处值是换行而非截断、也不可选中。收敛后
`field(...)` 让 `isSelectable` 与 `elidedValue` 保持默认关闭，注释改写为解释这一点，并由回归断言。

### 本批未覆盖

- F52 第 4 条的另一半：73 处 `.font(.system(size:…))` 绕过 `WorkspaceFont` / `WorkspaceMetrics`
  （Diagnostics 39、Device 30、UIDump 2、Flash 2）。其中 10pt、12pt-medium、11pt-medium 在
  `WorkspaceFont` 里没有等值角色，必然改变实际字号，下一批单独做。
- `ViewerInspectorCopy` 硬编码英文（F52-5）——等待第 2 条裁决。
- 资源里的已移除路径键、preview 构建守护（F52-6、F52-8）。
- 退役 Automation 样式（F52-7）与 `Select` 映射（F52-9）保持 exception。
- F56 登记的两条既有原生失败保持开放。

### 本批实测：原生 XCUITest 套件在相同代码上结果不稳定（新登记，优先级高）

本批第一次全套跑出 44/4，比批次五的 46/2 差，且两条新失败正好落在本批改过的 HDC 与
Debug 上。没有直接归因为噪声，而是补跑到五次全套逐条比对：

| 运行 | 代码 | 结果 | 失败集合 |
| --- | --- | --- | --- |
| A | `main`（本机并行有构建） | 45/3 | DebugHAP、History（signal kill）、Sandbox（fixture 未构建） |
| B | 批次五 | 46/2 | DebugHAP、History |
| C | 批次六 | 44/4 | DebugHAP、History、EnglishFixtureSweep、zhLocalizationSweep |
| D | `main`（空载） | 45/3 | DebugHAP、History、Sandbox（Environment 断言） |
| E | 批次六（与 D 同条件，代码与 C 逐字相同） | **47/1** | UserPickerPersistsBookmark（同一条 Environment 断言） |

**C 与 E 是同一个提交、同样空载，失败数 4 与 1；D 与 E 里同一条断言打在两个不同的测试上。**
五次运行里共有 6 个不同的用例至少失败过一次。批次六最好的一次（47/1）优于 `main` 最好的
一次（45/3）。C 的两条新失败在同一分支上单独重跑通过。故 C 的 44/4 判为套件方差，不是回归。

**方差的一个已定位来源**：`ArkDeckAppUITests/HDC/HDCStatusUITests.swift:494` 的
`expandAdvancedDiagnostics` 用「固定次数滚动 + 单次 click + 5 秒等待」找
`hdc.toolchain.path`，没有重试；它被 `walkEveryDiagnosticState` 共用，因此失败会记在恰好
抽到不利布局/时序的那个测试上，而不是记在这个 helper 上。F56 登记的
`testDebugHAPSelection…` 在三次运行里失败在三个不同的行（1154 / 1227 / 1180），是同一类。

**影响**：macOS UI 套件作为本地门禁，目前**无法在 1–4 条失败的粒度上区分回归与噪声**。
后续批次（尤其是要大改 Diagnostics 与 Device 字号的下一批）如果只跑一次全套，结论不可靠。
建议在下一批之前单起一批专门稳定原生门禁；本批不顺手改，避免把收敛与测试稳定性混在
同一个 PR 里。**在此之前，本审计对原生结果的所有陈述都以「多次运行的失败集合」为准，
不以单次运行的通过/失败为准。**

### F57 验证

- App 编译 `** BUILD SUCCEEDED **`，0 error。
- 原生 XCUITest 全套在本提交上跑了两次：44/4 与 **47/1**；第一次的两条新失败在同一分支单独
  重跑通过。上面的方差表是这一结论的依据；**不以单次运行判定**。
- `npm test` **76 项通过**（新增 1 项：裸 `Grid(` 扫描与四处 exception 的理由、8 个行辅助
  函数返回共享行、HDC 字段刻意不可选中）。
- `npm run build`、`npm run build:review` 通过；`check:tokens` 每个原型 class 均已分类。
- 统一本地闸退出 0；App 编译车道（`app: true` / `swift: false`）`build-for-testing` 通过。
- 未做浏览器逐页走查，未执行设备操作；不构成 App 呈现验收或真机验收。

## 2026-08-30 F58：稳定原生门禁（F56/F57 欠账的第一批）

第七批，基线 `373edb9b`。范围是 F56 登记的两条既有原生失败与 F57 登记的「套件在相同代码上
结果不稳定」。**本批只动测试侧**；同族的产品侧修复（History / Viewer reveal 竞态）由维护者
指派的另一会话执行（chip task_3c640d76，分支 `agent/scroll-reveal-settlement`），本批不重复做，
见下文「与并行会话的分工」。逐行结论见
[2026-08-30 批次七台账](references/ui-consistency/2026-08-30-native-gate-ledger.md)。

**一个贯穿四处的模式：异步状态变化之后只采样一次。** 四处失败根因不同，形状相同——驱动一个
异步动作，然后立刻读一次结果，读到的是动作生效之前的状态。

1. **Debug tab 切换用了裸 `.click()`。** `testDebugHAPSelection…` 里
   `app.buttons["debug.tab.apps"].click()` 之后直接等 `debug.apps.postRun` 15 秒。失败运行导出的
   AX hierarchy 显示 App 仍停在 **Artifacts**（Debug 的默认页，可见 `debug.artifacts.bundle` /
   `debug.artifacts.logicalName`），也就是这一 click 根本没落地，而它等的控件只在 Apps 页存在。
   本套件其余每一处 Debug 分页切换都走 `clickCorrectingNavigationSplitAXOffset`（该 helper 的存在
   本身就是因为 macOS 会发布带偏移的 AX 代理），唯独这里没有。现改为走同一 helper，最多重试
   三次，并在继续之前断言切换确实生效。
2. **`chooseDebugPackage` 可能把路径打进错的输入框。** ⌘⇧G 之后取
   `panel.textFields.firstMatch`，而 open panel 本身就带有自己的文本框，于是可能选中一个**本来
   就存在**的字段、把路径打进去、什么也没选中，症状是 `package was not selected`。现改为优先
   定位 Go to Folder 那张 sheet 自己的输入框；并把键盘布局 pin **移到第一次合成按键之前**
   （原来在 ⌘⇧G 之后，而 ⌘⇧G 本身就需要布局已 pin 才能生效）；失败时附上 panel hierarchy，
   让下一次失败自带诊断而不是又一条裸消息。
3. **Environment 披露靠固定次数滚动 + 单次 click。** `expandAdvancedDiagnostics` 点丢了就静默
   不展开，而它被 `walkEveryDiagnosticState` 共用，于是失败被记在**恰好调用它的那个测试**头上——
   这正是同一条断言在两次运行里落在两个不同测试上的原因。现改用 ⌘⇧D（该披露自己的快捷键，
   不需要命中测试），并用按钮自己发布的 `accessibilityValue` 判断按键是否生效，因而不依赖
   界面语言；顺带删除随之失去消费方的 `overviewScrollView`。
4. **`applyFixtureState` 在上一次刷新还在飞时就打下一个 fixture。** Refresh 控件在刷新期间自我
   禁用，5 秒不总是够，症状是**下一条**断言读到上一个状态的值（期待 `timed out` 读到 `denied`）。
   超时提到 20 秒，等 App 空闲再驱动。

`waitUntil(timeout:_:)` 收进 `KeyboardInputSourcePin.swift`（该文件已是共享测试工具的所在地），
不在两个测试类里各写一份。

### 与并行会话的分工（避免两份产品修复打架）

F56 的 History 精确行定位，本会话先做的是测试侧 10 秒轮询——**结果证明轮询修不好：行永远不进
viewport**（实测落在下方 12–58pt，有一次是 `(0, 956, 0, 0)`，即尚未布局）。据此判定为产品侧
缺陷：显式路由会换掉 List 的 identity，行在 `.task` 起来之后才装上，`scrollTo` 对尚未注册的行
**静默 no-op**。本会话据此写过一版「几个 runloop turn 内重复 anchor」的产品修复，**已撤回**：
并行会话持有该 chip，且其机制更好——把重锚挂在 `onScrollGeometryChange(contentSize)` 上，
即行安装/量行的**真实完成条件**，无定时器、无次数上限，符合仓规「等真实完成条件，别靠负载
统计」。本会话的三条实证（12–58pt、未布局帧、10 秒轮询无效）移交对方 commit 归档。
main 上现有的 `XCTWaiter` 5 秒 settled-state 等待保留不动。

### 本批实测到的跑道运维事实（登记，脚本不在本 Task 的 Allowed paths 内，不改）

- **`scripts/ci/run-ui-tests.sh` 默认 DerivedData 是全机固定路径**，跨 checkout / worktree 共用一个
  `build.db`，并发即 `database is locked`。本批改用 `ARKDECK_UI_TEST_DERIVED_DATA` 独立路径。
- **该脚本开头的两行 `pkill` 按进程名全局杀**，任何会话调用都会打死其他会话在飞的 runner；
  受害方看到的是 `Test crashed with signal term while preparing to run tests`，很容易被误读成
  自己的回归。本批被误伤两次。
- **UI 跑道全机唯一，必须跨会话串行**：系统只有一个 `testmanagerd`、只有一个前台焦点，
  后启动的一方拿到 `Timed out while enabling automation mode`，互撞还会把 testmanagerd 搅坏。
- **换新 DerivedData 路径的首跑必然吃一次 automation-mode 超时**（脚本头注释已载明）。
- **一次 run 是否有效，先看有没有** `Failed to activate application` / `database is locked` /
  `enabling automation mode` / `signal term` **四类信号**；有就是无效 run，不能当红、更不能当
  回归证据。**F57 的 A–E 方差表因此作废**：当时无从得知另一会话正在同一台机器上跑同一套件，
  那组数字不能证明套件「在相同代码上不稳定」，相关结论以本批重新测量为准。

## 2026-08-30 F59：字号回到共享刻度（C-DUP 第三批，收尾 F52 第 4 条）

第八批，基线 `5fa29c0b`。范围是 F52 第 4 条最后剩下的一半：73 处 `.font(.system(size:…))`
绕过 `WorkspaceFont`。逐行结论见
[2026-08-30 批次八台账](references/ui-consistency/2026-08-30-type-scale-ledger.md)。

**只收敛有精确等值的 39 处，其余 34 处按裁决保留或继续待裁决。** 收敛不是「全部换成最近的
角色」——那会改变实际字号与字重，属产品判断。按 spec §2 的角色表（body 13/regular、
secondary 12/regular、section title 13/semibold、monospace 11–12）与 `WorkspaceFont` 交叉，
只有四种写法是逐字等值：

| 现写法 | 共享角色 | 处数 |
| --- | --- | --- |
| `.system(size: 11)` | `WorkspaceFont.caption`（11/regular） | 28 |
| `.system(size: 13, weight: .semibold)` | `WorkspaceFont.sectionTitle` | 7 |
| `.system(size: 12, design: .monospaced)` | `WorkspaceFont.monospacedValue` | 2 |
| `.system(size: 11, design: .monospaced)` | `WorkspaceFont.monospacedDense` | 2 |

分布：`DiagnosticsWorkspaceView` 23 处、`DeviceWorkspaceView` 16 处。**零视觉变化**——
这批不改变任何一处的渲染尺寸或字重，只是让它们经由共享词表表达。

**10pt 一档：维护者裁决保留（20 处）。** spec §2 最小的非 mono 角色是 secondary 12，
`WorkspaceFont` 另补了 label / caption 两个 11 的角色，10pt 在两者之下，**共享刻度里没有
这一档**。把它提到 11 会改变采集时间轴、HiLog 条这些密集表面的布局密度，因此裁决为保留现状。
理由写在 `WorkspaceFont` 的文档注释里（一处覆盖全部调用点），并由交互测试按名单锁住这一档
的规模（19 处 bare + mono、1 处 semibold）。

**medium 字重 11 处：维护者裁决收敛到最近角色。** 判法是**尺寸就近优先**——保持字号不变、
只动字重，对布局的影响最小；字重再按语义定：

| 现写法 | 收敛到 | 字重变化 | 处数 | 判据 |
| --- | --- | --- | --- | --- |
| `.system(size: 12, weight: .medium)` | `WorkspaceFont.secondary` | medium → regular（**变细**） | 6 | 12pt 只有 `secondary` 一个角色 |
| `.system(size: 11, weight: .medium)` | `WorkspaceFont.label` | medium → semibold（**变粗**） | 5 | 11pt 有 `label`(semibold) 与 `caption`(regular) 两个角色，medium 到两者字重等距；这 5 处全是徽章与「标题 + 10pt 说明」结构，正是 `label`（列头、chip 与装饰）的定位 |

**可见变化**：Diagnostics 的六处强调标题（采集不可用、预览名、partial 警告、Marker 标题、
notDerived / missing 标题）变细；Device 的五处徽章与标题（stale 徽章、性能标题、条目标题、
无空间警告、帧率读数）变粗。字号一律不变，因此不影响这两个工作区的布局密度。

### 仍未收敛（3 处，记 exception）

`.system(size: 9, weight: .semibold)`、`.system(size: 36)`、`.system(size: 28, weight: .semibold)`
各一处，是空态与大字形的离群值，不属于正文刻度的任何角色，逐个搬到共享刻度既无对应角色也
无收益，记 exception 保留。加上裁决保留的 10pt 一档 20 处，共 23 处仍写 `.system(size:)`，
全部由交互测试按名单锁住，新的脱离字号出现即失败。

**至此 F52 第 4 条全部完成**：通知与 Settings 副本（F56）、键值列表（F57）、字号刻度（本批
50 处，39 处零渲染变化 + 11 处按裁决改字重）。F52 只剩两条待裁决（内容区重复工具栏标题、
Viewer 检查器英文保留范围）与它们各自堵着的项。

### 本批发现的一条既有失败（登记，非本批引入）

`AppShellUITests.testDiagnosticsReadsPublishedSessionAndGlobalLogWithoutInventingAlignment`
在 `c222fc69` 上失败于 `Unable to find hit point for ScrollView, {{252.0, 441.0}, {648.0, 0.0}}`，
**在未改动的 `main` 同一 commit 上以完全相同的消息与完全相同的几何复现**，两次运行的七条
有效性信号均为 0。因此与本批字号改动无关——这也反过来印证了本批 39 处等值替换确实零渲染变化。

**该宿主的高度是 0**（`{648.0, 0.0}`）。与 F58 记录的另一处同族：批次七尝试给
`debug.apps.entry.choose` 加 `scrollIntoView` 时，失败是
`Unable to find hit point for ScrollView, {{1647.0, 200.0}, {245.0, 318.0}}`，那个宿主在屏外。
两者共同点是 **`scrollIntoView` 选中了一个无法命中的滚动宿主**——helper 目前只按「宽度非零
且横向包含目标 x」挑最小面积的宿主（`AppShellUITests.swift` 的 `scrollIntoView`），
**没有任何「宿主本身必须可命中」的判据**，于是高度为 0 的容器与屏外的容器都会被选中。
根因指向该 helper 的选择判据而不是被测产品，但本批不改它：动共享 helper 会影响其八处调用点，
需要独立一批与足够的重复运行。已登记。

## 2026-08-31 F60：清掉已移除路径的本地化键（F52 第 6 条）

第九批，基线 `b056126d`。范围是 F52 第 6 条：本地化目录里已无任何渲染路径的键。
逐行结论见[2026-08-31 台账](references/ui-consistency/2026-08-31-retired-keys-ledger.md)。

**先修正登记时的一个数字，并说明为什么之前那个数字不可信。** 批次六期间我曾粗扫得到 224 条
「无引用键」，与 F52-6 登记的 63 条相差悬殊。本批做了严谨测量后确认：**63 条是对的**，
224 是我那次粗扫的误报上界。差别在于判据——静态可达性单独**不足以判死一个键**：

- App 有大量**变量查表**：`Text(LocalizedStringKey(serverHealthKey))`、
  `field(_ titleKey: String, …)`、`Text(LocalizedStringKey(item.nextStepKey))` 等 20 余处；
- 还有**插值构造**：`"debug.tab.\(tabID)"`、`"job.state.\(state.rawValue)"`。

因此判据是三条并集：键以**字面量**出现在任一 Swift 源文件里；或其**生成的 camelCase 访问器**
被使用；或源码中任一**插值前缀**是该键的前缀。按此测得每个目录的无引用数与 F52-6 登记
**逐一吻合**：Debug 11、Diagnostics 13、Flash 29、History 6、Settings 4 = 63。

**本批删 59 条，保留 4 条。** Debug 11 + Diagnostics 13 + Flash 29 + History 6 已删除；
`settings.general.title` / `settings.storage.title` / `settings.toolchains.title` /
`settings.diagnostics.title` 四条**不删**——它们是面板标题键，而**待裁决第 1 条正是「内容区
是否允许重复工具栏页面标题」**；若裁决为允许，这四条正是要复用的键。绑定裁决，不静默清掉。

**删除方式**：按文本块精确删除，不重写 JSON。首次尝试用 `json.dumps` 重写导致 9970 行插入
（键序与缩进被改），已回退；四个目录里 Debug / Flash / History 是紧凑单行格式、Diagnostics 是
展开格式，文本块删除对两者都只产生纯删除 diff（合计 267 行，零插入），删后逐个校验仍是合法
JSON 且目标键确已不在。

### 本轮新发现、未处理的 26 条（登记）

F52-6 登记时未列，本批也**不删**——它们没有经过首轮那样的逐条核实：

| 目录 | 键 | 处数 |
| --- | --- | --- |
| `Localizable` | `overview.record.action.*`（5）、`overview.record.availability.*`（4）、`overview.record.empty.*`（5）、`overview.status.*`（4）、`history.column.*`（3）、`app.unavailable.*`（2）、`overview.record.recent.rules` | 24 |
| `JobsLocalizable` | `jobInspector.readOnly` | 1 |
| `DeviceLocalizable` | `device.record.stop` | 1 |

其中 `overview.status.server` 一类尤其需要人工确认再动：它与 UI 测试用的**可访问性标识符**
`overview.status.server.value` 同名前缀，但标签文字实际来自 `overview.serverHealth.*`
（`HDCStatusView.serverHealthKey` 的 switch 返回值）。**同名前缀不等于同一用途**，这类键必须
追到消费方再判，不能只看扫描结果。

### `UIDumpLocalizable` 的 25 条仍与 F52-5 绑定

`viewer.tab.*` / `viewer.group.*` / `viewer.field.*` / `viewer.value.*` /
`viewer.properties.*` 共 25 条无引用，正是 F52 第 5 条所指——`ViewerInspectorCopy` 把这些
文案硬编码成英文，而目录里的译文无人引用。**待裁决第 2 条（Viewer 检查器英文保留范围）没有
结论之前不能删**：若裁决为「空态/动作/搜索控件走目录」，这些正是要接上的键。

交互测试同时守三处：四个已清理目录不得再出现无引用键；`UIDumpLocalizable` 的 25 条与
`SettingsLocalizable` 的 4 条按数量钉住，清理与裁决都不能悄悄漂移。

## 2026-08-31 F61：preview 纳入构建守护（F52 第 8 条）

第十批，基线 `99b244f6`。范围是 F52 第 8 条：`.design-sync/previews` 下的 32 个 preview
既不被类型检查也不被任何 npm 脚本打包。逐行结论见
[2026-08-31 台账](references/ui-consistency/2026-08-31-preview-guard-ledger.md)。

**先说清被修的是什么。** `tsconfig.json` 的 `include` 只有 `src/**`，`build:review` 只打包
`scripts/session-review.tsx`。因此审计记录里那句「32 个 preview 逐个独立打包通过」是**手工
执行的循环**，不是脚本产物——换个人、换台机器都无法复现。本批把它变成 `npm run build` 的一部分。

**三步排除的两层假象。** 单纯把 previews 加进 `include` 会报 38 个
`Cannot find module 'react'`；改成把 `react` 映射到 `./node_modules/react` 会变成 71 个
`Could not find a declaration file`。两次都不是 preview 代码的问题：前者是 preview 位于仓库根的
`.design-sync/` 下、模块解析走不到本包的 `node_modules`；后者是映射指到了实现文件而非类型声明。
把 `react` 与 `react/jsx-runtime` 映射到 `@types` 并设 `typeRoots` 后，**32 个 preview 零类型
错误**。若在第一步就下结论，会得出「preview 有 38 处类型问题」这种完全错误的判断——**preview
代码本身一直是干净的，缺的只是配置**。

**落地三件：**

1. `docs/design/arkdeck-ds/tsconfig.previews.json`——把 previews 纳入类型检查，
   两条 `paths` 映射与 `typeRoots` 都是承重的，配置里写明了原因；
2. `scripts/build-previews.mjs`——**逐个** preview 一个 entry point 打包。合并成单一入口会让
   「某个 preview 只因兄弟文件替它引入了依赖才编译得过」这种情况蒙混过关；任一失败即
   `exit 1`；
3. `package.json`：新增 `check:previews` 与 `build:previews`，并接进 `npm run build` 链。

**守护做了负向验证，不是套套逻辑。** 往 `Chip.tsx` 注入一个不存在的 prop，
`check:previews` **退出码 2** 并精确报出 `error TS2322`；还原后退出码 0。

交互测试固定这套接线：两个脚本的定义、它们必须出现在 `build` 链里、tsconfig 必须伸到
`.design-sync/previews` 且经 `@types` 解析 React、打包器必须逐个入口且失败即非零退出，
以及它走的 preview 集合等于覆盖表的 `previewFiles`。

**至此 F52 九条里可执行的部分全部完成**，剩余全部是两条待裁决及其直接堵住的项。

### F61 顺车修复与一个覆盖缺口（登记）

rebase 到 `bec43c53`（#1606 *modernize SwiftUI surfaces*）之后，`npm test` 在**干净 `main`**
上就是 76 通过 / 2 失败：`History compact activity picker…` 与
`all actual navigation items and subtabs are audited`。两者都因为测试正则锚在 SwiftUI 的**写法**
上——`workspace.size.width >= 890` 改成了 `onGeometryChange` + `workspaceWidth >= 890`，
`Label(settingsText(…))` 换成了 `Tab(settingsText(…))`——而被审计的事实（890 阈值、七个 Settings
面板及顺序）一个都没变。已在本批顺车改为锚定事实：阈值正则接受两种拼写，面板正则只认
`settingsText("settings.tab.X")`，不再关心外层容器。

**缺口**：CI **不跑** `npm test`（PR 检查只有 `ds-tokens` 等），因此把交互测试改红也能合入，
而这套测试正是本审计「矩阵行 ID 必须等于 `surfaceIDs`」等不变量的唯一守护。
`.github/**` 不在 TASK-AIN-021 的 Allowed paths 内，本批只登记，不改 CI。
建议由维护者决定是否把 `npm --prefix docs/design/arkdeck-ds test` 加入 PR 检查。

## 2026-08-31 F62：#1606 引入的表面漂移增量核对

第十一批，基线 `e4218110`。**不是新一轮全量**，而是 brief §10 规定的增量轮：
`bec43c53`（#1606 *modernize SwiftUI surfaces*）实质改动了 App 表面，触发对受影响行的重核。
逐行结论见[2026-08-31 增量台账](references/ui-consistency/2026-08-31-modernization-drift-ledger.md)。

**先界定漂移面，避免把 API 现代化当成漂移。** #1606 改了 21 个文件、771 增 568 删，但逐项测量后
真正的新增呈现只有三条：

- **可访问性标识符增删完全对称**（各 5 个：`device.history.loading`、`device.screen.empty`、
  `device.screen.image`、`viewer.history.loading`、`viewer.tree.scroll`），即代码位置移动，
  可达性面未变；
- **新增本地化键三条**，稿件侧此前**零对应**：`viewer.tree.expand`、`viewer.tree.collapse`
  （`UIDumpLocalizable` +34 行）、`device.record.saveFailed`（`DeviceLocalizable` +17 行）。

按 §6 分类，三条都是 **P-DRIFT**（实现有、稿无），本批同车补齐稿件。

**组件树的展开/折叠必须是有名字的控件。** App 现在把它渲染成 `HStack` 里**两个并列的
Button**——一个带 `viewer.tree.expand/collapse` 名称的 chevron 按钮，一个包住图标与标签的选择
按钮。稿件此前是**一个 button 包住整行**，chevron 只是 `aria-hidden` 的装饰、靠事件委派区分
点击区域：指针可达，**按名称不可达**。现改为同构的两个控件——行降为 `role="treeitem"` 容器，
chevron 成为带 `aria-label` 与 `aria-expanded` 的按钮，其余内容成为 `.viewer-tree-select` 按钮
（新 class 已加入 `CLASS_TO_COMPONENT` 映射到 `ComponentTree`），键盘导航改在选择按钮上找同辈。

**保存失败是与采集失败不同的一态。** `device.record.saveFailed` 发生在帧已采集之后、写盘失败时，
App 以 alert 呈现（标题为该键，正文是写入器自己的原因）。稿件新增 `recordStage="saveFailed"`
与 `recordingSaveFailed` scenario（URL token `?deviceState=recordingSaveFailed`），与既有
`failed`（采集失败）分开。**呈现形态差异如实记录**：App 是模态 alert，稿件是内联提示——稿件的
`modal()` 已映射到 `DangerConfirmDialog`（危险确认语义），拿它装信息 alert 会制造新的组件映射
错误，故不硬凑形态；两侧状态可达、文案同源，形态差异登记为已知差异。

### 本批自己引入又修掉的一个缺陷

补 saveFailed 的样本原因时，最初在 `deviceDraftState()` 里调用了 `deviceLocale()`。
该函数**在 `S` 初始化之前**就被顶层调用，于是 `?deviceState=recordingSaveFailed` 一经命中即
`ReferenceError: Cannot access 'S' before initialization`，**整页停止渲染**。由 harness 直接渲染
抓到（肉眼与静态检查都看不出）。改为存 `{zh,en}` 语言对、渲染期用 `bi()` 解析，并由回归断言
`deviceDraftState` 内不得出现 `deviceLocale(`。

同时复犯了一次批次四的老错：手打英文文案，把 App 原文里的 curly apostrophe（`Couldn’t`，
U+2019）写成直引号。现改为从 `.xcstrings` 逐字取值。两条教训已记入共享 memory。

## 2026-08-31 F64：把 #1618 拆出的两个 Trace 编辑器纳入覆盖清单

增量修复，基线 `fa7c5348`。`npm test` 在 `main` 上失败于
`every App View file and preview is covered and linked`：扫描得 23 个声明 View 的 App 文件，
而 `implementation-coverage.json` 的 `appViewFiles` 是 21 个。缺的两个是 #1618 从
`TraceViewerWorkspaceView` 拆出的 `TraceFlagDraftEditor.swift` 与 `TraceFlagTagEditor.swift`。

**这是两个各自为绿、合起来才红的 PR。** #1618 新增文件、#1619 把该套件挂进 PR 门，两者分别
合入时都是绿的；红只在 union 出现。由于新车道的触发面含 `Packages/`，这条红**阻塞了全仓的
本地闸**，不只是设计侧的改动。

**修法不是只改清单。** `coverage.appViewFiles` 同时被另外三条审计消费——裸 `Grid(` 扫描、
精确字号角色、字号档位名单。把文件加进清单等于让它们受这三条约束，所以先逐条实测：两个文件
**零裸 `Grid(`、零 `.font(.system(size:`**，本就合规，因此加入清单是正确的核对结论，不是让
断言闭嘴。

**是否引入稿件漂移**：#1618 未触碰任何 `.xcstrings`，两个编辑器是既有 Trace Viewer 时间轴标记
编辑逻辑的**拆分**（该 PR 修的是异步更新期间的 SwiftUI 状态保持），无新增可见文案，故稿件侧
无需变化。§3 矩阵的 Trace Viewer 行覆盖它们，生产 View 索引由 21/21 更新为 23/23。
## 2026-08-31 F65：两条待裁决落地

第十二批，基线 `ea5776f2`。维护者给出两条结论，本批同车落地：
**①内容区不允许重复工具栏页面标题；②Viewer 空态和搜索控件走目录。**
逐行结论见[2026-08-31 裁决落地台账](references/ui-consistency/2026-08-31-rulings-ledger.md)。

**先更正 F52 第 5 条的一处不实陈述。** 该条写「`UIDumpLocalizable.xcstrings` 里这些键都有中文
译文且无人引用」，并列举了六条。实测**六条里只有两条成立**：`Select a component`
（`viewer.properties.selectPrompt`）与 `Raw fields are unavailable`
（`viewer.properties.rawUnavailable`）确实是有译文的无引用键；而 `Retry`、
`Search fields or values`、`Clear search`、`No matching fields or values`
**在目录里根本没有键**。因此落地裁决 ② 不是「接上已有译文」，而是**新增键并新译**。
原记述保留不改写，以本段为准。

**裁决 ② 的分类：9 条走目录，其余保持英文。** 对 `ViewerInspectorCopy` 的 34 个成员逐条按
渲染点分类，并对每条非 english 的判断做了对抗复核（复核方被要求「措辞未明确覆盖就驳回」）：

| 结果 | 数量 | 内容 |
| --- | --- | --- |
| 走目录（复核 confirmed） | 9 | 空态 3：`selectPrompt`、`rawUnavailable`、`advancedUnavailable`；搜索控件 6：`advancedSearch` 及其 placeholder / shortcut / results / clear / noResults |
| 保持英文 | 23 | tab 名、分组名、字段名、chip、字段列表里的值（`Yes`/`No`/`Available`/`Verified`）——spec §5.3 的 Provider 词表 |
| **复核驳回** | 2 | `advancedLoading`（加载态）、`advancedIdentifiersUnavailable`（失败原因）——裁决只说「空态和搜索控件」，二者都不在措辞内 |

**不擅自扩大裁决**：`retry` 是失败分支里的恢复动作、`show(_:)` 是动作、`Yes`/`No` 是技术字段
列表里的值，裁决均未覆盖，全部保持英文。这条边界写进了 `ViewerInspectorCopy` 的类型注释，
免得下一个人再问一遍。新增 7 条目录键（`viewer.advancedDump.*`），中英成对。

**裁决 ① 的落地与一个连带效果。** `DiagnosticsWorkspaceView` 的自绘工具条此前用三元表达式
渲染标题：HiLog 上下文显示 `diagnostics.hilog.title`（**与工具栏不同名，合规**），普通上下文
显示 `diagnostics.title`（**与工具栏同名，违规**）。故不能整行删除——改为只在 HiLog 上下文
渲染。稿件侧 `pDiagnostics()` 内容区那句字面 `<b>Diagnostics</b>` 一并删除。

连带效果：`diagnostics.title` 随之成为死键（窗口标题走的是导航项的 `localizationKey`，
不是这个键），已删除。`settings.{general,storage,toolchains,diagnostics}.title` 四条此前正是
**因这条裁决未决**而在 F60 保留的，现确认为死键，一并删除——`SettingsLocalizable` 的无引用
键归零。

**同车更新一条 UI 断言。** `AppShellUITests.swift:622` 原本断言
`app.staticTexts["diagnostics.workspace.title"]` 等于 `"Diagnostics"`——它**钉住的正是被裁决
判为违规的行为**。改为断言该元素不存在。这不是回归，是断言对象本身被裁掉了。
除此之外，20 处相关 UI 断言全部**不受影响**：它们一律按 accessibility identifier 查询，
不依赖文案，所以文案中文化不会打红它们。

### 本批自己引入又修掉的两个回归

原生跑动抓到两处编译与设计测试都发现不了的问题，均为本批改动所致：

1. **性能**：九条文案改成 `static var { viewerText(…) }` 后**每次访问都查 Bundle**，而
   Advanced Dump 搜索每敲一个字符重建数百行，正是热路径——`typing a field query must not
   block on rebuilding hundreds of rows` 实测 3.71s、上限 2.0s。改回 `static let`（只求值一次；
   语言由启动参数固定），理由写进类型注释。
2. **时序**：把 `assertDisplayed`（会等待）换成 `XCTAssertFalse(...exists)`（立即返回），
   顺手删掉了一个隐式同步点。改为先等该页自己的内容到位再断言。

### `testEnglishSweepOfEveryWorkspace`：既有失败，非本批引入

该测试在本批分支上失败，失败点在 `:699`（`sweep` 内 Debug 面板检查）与 `:1796`（快照匹配）
之间摇摆。**在干净 `main` 上取三个样本：1 次 `:1793` 快照、2 次 `:699` Debug 面板，消息与本批
逐字相同**（`:1793` 与 `:1796` 是同一处，本批改测试文件多出 3 行）。两侧在同样两处之间摇摆、
全部样本有效性信号为 0，故判为既有缺陷，本批既不引入也不负责修绿。

先排除了文案原因：Debug 面板标题取自 `DebugLocalizable`，而本批的资源改动只涉及
Diagnostics / Settings / UIDump 三个目录。**归因一律先在干净 `main` 上取样，不因「没碰那个
工作区」就推给既有**——上面那两个回归当初都「看起来不是我的」。

### CI 门状态更新

F61 登记的「ds 交互测试不在任何 PR 门里」已由维护者拍板加门（chip `task_519ac5fa`），
并由另一会话实现、推上 `agent/ain-022-ds-interaction-gate`：在 `swift-ci.yml` 的 plan 车道体系
里新增第三条 `ds` 车道，触发面为套件真实读取的四个目录（`ArkDeckApp/`、`ArkDeckAppUITests/`、
`Packages/`、`docs/design/`），折进现有 `swift` required 聚合器。状态由「已登记待决策」
翻为**已决策、已实现、待合入**。

## 2026-08-31 F66：`scrollIntoView` 的宿主选择判据（防御性，非修复现存失败）

基线 `06f75fd4`。F58 与 F59 都指向同一个缺口：`AppShellUITests.scrollIntoView` 选滚动宿主时
只要求 `frame.width > 0`，随后**取面积最小者**。

**缺陷在自身逻辑上成立且是确定性的**：高度为 0 的滚动视图面积恰为 0，因此它一旦出现在候选里
就不是「可能被选中」，而是**必然胜出**——随后既无法滚动也没有命中点，报成
`Unable to find hit point for ScrollView`，读起来像产品缺陷。本批加上 `frame.height > 0`。

**但必须如实说明：这个修复在今天的 `main` 上观测不到任何差异。**

| 运行 | hit-point 报错 | 实际失败 |
| --- | --- | --- |
| 本批分支 | 0 次 | `Not hittable: Button, {{956.0, -688.5}, {204.0, 24.0}}` |
| **干净 `main` 对照** | **0 次** | **完全相同** |

我一度把「hit-point 报错归零」当作修复生效的证据；**对照当前 `main` 后该推断被推翻**——
main 本来就是 0 次。F59 记录的 `{{252.0, 441.0}, {648.0, 0.0}}` 出现在**旧 main**
（`c222fc69` 时代），此后随 #1606 / #1618 等改动，塌陷宿主的场景已不复现。
F58 记录的屏外宿主（x=1647）则是当时我自己加 `scrollIntoView` 引发、随即回退的，
同样不构成对现状的实证。

因此本批的定位是**防御性守卫**：选择规则在自身逻辑上是错的，故予以修正；但它**不修复任何
当前可观测的失败**，也不声称如此。曾一并加入的「宿主须与窗口有交集」条件已**去掉**——
判别实验显示加与不加失败完全相同，没有实证支持，不留无证据的条件。

**顺带更正一处计数**：F58 与 F59 都写该 helper「有八处调用点」，实测为 **20 处**。

**该 Diagnostics 测试当前红于另一原因**：目标按钮停在 y=-688.5，滚动未能将其带回视口。
干净 `main` 上同一按钮、同一坐标，故为既有缺陷，与本批无关，根因未定，继续登记。
