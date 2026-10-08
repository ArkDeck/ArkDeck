# Windows Fluent 页面改造实施方案

日期：2026-10-08。范围：Windows App 的 13 个页面及设置页的 9 个分类。

## 目标与完成条件

采用已确认的「Fluent 单列」方向：概览和表单以一列为主；记录和查看器在空间足够时使用分栏，窄窗口和大字号下回到一列。完成公共框架、逐页改造、原生界面验证和当前用户的本地开发安装。使用仓内 Windows 11 x64 签名 RC 的 xcopy 形式，沿用现有 App / Runtime 状态目录。

本次是呈现改造。兼容说明：沿用当前跨平台 UI 语义、品牌强调色和 Runtime authority；Windows 的排版、布局、主题层次按 Fluent 2 实现。所有 AutomationId、双语文案、已有动作及确认流程继续有效。

## PowerToys 实现依据

参考 [PowerToys Settings UI](https://github.com/microsoft/PowerToys/tree/main/src/settings-ui/Settings.UI)，重点采用以下结构，而非复制其整套依赖：

- [MainWindow](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/MainWindow.xaml) 使用 Mica；[ShellPage](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/Views/ShellPage.xaml) 将标题栏与导航、内容分层。
- [SettingsPageControl](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/Controls/SettingsPageControl/SettingsPageControl.xaml) 把页面标题放在滚动区外，正文宽度受控，窄窗口重新排列内容。
- [App.xaml](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/SettingsXAML/App.xaml) 使用 1000 epx 正文上限、2 epx 设置行间距，以及原生控件资源。[SettingsGroup](https://github.com/microsoft/PowerToys/blob/main/src/settings-ui/Settings.UI/Controls/SettingsGroup/SettingsGroup.xaml) 将分组标题与卡片分开。
- PowerToys 的 SettingsCard / SettingsExpander 来自 CommunityToolkit。ArkDeck 已有原生控件与共享构造器，本轮在这些构造器中实现相同的标题、描述、内容排列，保留现有按钮、列表与对话框行为。

微软规范：[字体层级](https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/typography)、[Mica 分层](https://learn.microsoft.com/en-us/windows/apps/design/style/mica)、[窗口单位](https://learn.microsoft.com/en-us/windows/apps/develop/ui/windowing-overview)、[打包部署](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/)。上述来源按本方案日期核对；PowerToys 的 main 链接会继续变化。

## 公共框架

1. 页面标题 28 epx、正文 14 epx、说明 12 epx，采用 WinUI 字体样式；技术标识与原始数据保留等宽字体。Windows 的系统字体回退负责中文。
2. 导航展开宽度 240 epx；采用 NavigationView 的原生自适应模式。标题栏、Mica 导航区、内容 Layer、Card 四层分别使用对应主题资源。
3. 页面标题和刷新固定；正文单独滚动。普通页面正文上限 1000 epx，工作台利用剩余宽度。页面留白 24 epx、组间距 24 epx、卡片圆角 8 epx、卡片内边距 16 epx。
4. 新增共享自适应列布局。按可用内容宽度和 Windows `UISettings.TextScaleFactor` 决定分栏或堆叠，系统字号变化时重新布局；测试字号乘数只用于测试。列表行横向伸展，长路径、摘要与 digest 在列内换行。
5. 设置行左侧标签、右侧值或控件；窄窗口与大字号时标签移到上方。设置分组标题置于卡片外。
6. 窗口初始大小以 epx 表达，再按当前 DPI 转成 AppWindow 的物理像素；限制在显示器工作区内。
7. Job Inspector 默认显示紧凑状态栏，显式打开 Job 时自动展开；原有详情、取消确认、日志和恢复入口保持可达。空、加载、失败和 unavailable 状态同样采用完整布局。

## 逐页改造

| 页面 | 实施内容 |
| --- | --- |
| 概览 | 单列四组：当前范围、下一步、最近工作、环境；设备与远端服务器使用明确列宽，组内摘要与展开内容分层。 |
| 设备 | 屏幕工作区、候选设备、已采纳 Target 分组；Target 列表与详情在宽窗口并排，窄窗口顺序排列。 |
| 历史 | 筛选工具区在上，记录与详情并排；原有导出、打开工作区和只读提示保持可达。 |
| Sessions | 清理动作在工具区；会话列表与详情并排，导出和保留操作留在详情中。 |
| Agents | 待人工处理与执行记录组成列表栏，右侧统一呈现选中详情与后续动作。 |
| Imports | 上传表单独立分组；Import 列表与详情并排，状态与上传进度紧贴所属动作。 |
| Debug | 当前设备作为明确的设置行；五个分类共用统一分组、原生控件尺寸与正文宽度。 |
| Flash | 当前设备和准备步骤分层，准备区为视觉主区域；详情保留已有显示/隐藏语义与确认流程。 |
| Trace | 采集字段按设备、配置、时长排列；结果查看独立分组，控件不随长文案挤压。 |
| Trace Viewer | 文档与最近记录占三分之二，检查事实占三分之一；缺少解析器时继续显示真实的 unavailable 状态。 |
| UI Dump Viewer | 截图、组件树、属性分栏；窄窗口顺序排列，树内滚动、搜索、选择和键盘操作继续有效。 |
| Diagnostics | 采集工具区、会话与标记、产物分组；宽窗口并排阅读会话事实与标记。 |
| 设置 | 九个分类改为可选择的侧栏；窄窗口在正文上方换行排列，默认字号的 720 epx 窗口下占三行。通用、Runtime、工具链、远端来源、存储、Trace、更新、诊断、工作区统一采用分组和设置行。 |

## 实施顺序与验证

先完成共享样式、页面容器与自适应列；随后改造 13 页和设置分类，再构建和验证。

本地检查：Release 构建；受影响的页面语义、组件映射、文案与 App.Core 测试；原生 UIA 测试覆盖导航、动作焦点、225% 文本缩放、高对比度及已有关键流程。增加固定标题、宽窄窗口重排和分栏边界验证，并为所有页面生成截图进行视觉检查。文档运行 SDD 检查。

界面验收同时检查：所有页面有清晰的标题与主次层级；正文、按钮不越出视口；记录选择后详情在对应区域出现；标题在正文滚动时保持原位；分栏切换不丢失选择；深浅主题及高对比度保留可读性。测试 transport 截图只证明软件呈现，不构成真机或 hardware evidence。

原生截图由 WinUI `RenderTargetBitmap` 渲染实际 XAML 树。桌面当前无法提供有效的屏幕像素，渲染图使用系统主题的 Mica 不透明回退，不包含系统标题栏按钮与合成器的 Mica 效果；这些效果未做屏幕像素验收。`--render-snapshot`、`--test-theme` 仅在显式测试 transport 下有效，正常启动仍跟随 Windows。键盘顺序测量使用补偿滚动偏移的文档坐标；展开态语义测试先显式打开 Job Inspector，再执行原有断言。

225% 字号检查通过测试乘数执行；高对比度检查验证系统颜色 token 的映射。本次没有切换 Windows 的实际文本缩放或对比度主题，也未进行 Narrator 人工听读。系统字号变化的重排已接入 `UISettings.TextScaleFactorChanged`；上述检查不能代替这些系统级人工验收。

## 本地安装与交付

本机尚无正式安装，已有一个手动运行的 RC Runtime。用户选择当前用户版：签名程序安装到 `%LOCALAPPDATA%\Programs\ArkDeck\App`，通过开始菜单的 ArkDeck 入口启动；Windows「设置 → 应用」显示 `ArkDeck (Development)`，卸载注册项位于 HKCU。启动和卸载辅助脚本放在同级 `Installer` 目录，使用 Windows 自带 PowerShell，不依赖开发环境。

程序复用本机已信任的开发签名；启动器只为自己的进程配置精确的 daemon 路径和签名 pin。开发签名只用于本地测试；生产发布仍走仓内发布签名与维护者审阅流程。曾生成 MSIX，但安装要求整机信任开发证书；自动审批拒绝向 `LocalMachine\TrustedPeople` 添加证书，理由是扩大整机信任边界。用户随后明确选择当前用户版，最终包使用 `-SkipMsix`，没有改变系统证书信任。

安装前完成构建和 UI 检查，记录包版本、源码版本与文件摘要；旧 Runtime 通过自身 CLI 的 `runtime service uninstall` 判断是否允许停止，保留 `%LOCALAPPDATA%\ArkDeck\Agentd`，再由新包 CLI 启动。安装后核对文件摘要、注册身份、启动入口和正常连接。更新保留上一版 App 备份；卸载器在 App 打开时拒绝删除，通过 Runtime 的 typed stop 后才删除已验证的安装目录，并保留用户状态。

实际安装验收发现，本机的 `doctor` 读取约需 14 秒，超过 App 原有 10 秒预算。`doctor` 和 `operation.list` 两类只读投影改用与 CLI 相同的 30 秒预算，其他请求继续使用原预算；连接仍执行同一身份认证、health preflight、契约校验和禁止重放规则。真实安装的 UI 检查等待两次投影读取的有界总预算，原有结果断言保留。

## 执行记录

实现与当前用户安装已完成。安装包来自 `agent/windows-fluent-redesign` 分支的未提交源码快照，基于 `d13b95279a46a97f67befd25e33e7433585812ee`；打包 manifest 如实记录 `dirty=true`。安装版本为 `0.1.0`，构建号 `5`，卸载项版本为 `0.1.0.5`，不构成正式发布。

Local targeted checks：下列检查均为 exit 0。命令的工作目录为 `windows`，SDD / diff 检查从仓库根目录执行。

| 检查与命令 | 结果与本机日志 |
| --- | --- |
| `dotnet build App/ArkDeck.App.csproj -c Release --no-restore -p:Platform=x64`；打包脚本随后执行 Release publish | 构建成功，0 warning / error；`App/bin/fluent-redesign/build-final.log` 为界面构建日志；最终 publish 的调用记录见 `AppPackages/fluent-final-package.log`。 |
| `dotnet test App.Tests/ArkDeck.App.Tests.csproj -c Release --no-restore -p:Platform=x64`，筛选 ShellContract、WindowsComponentMapping、Catalogue、AppCoverage、Surface、DeviceScreen | 58 / 58；`App.Tests/bin/fluent-redesign/fluent-final-contracts.trx`。 |
| `dotnet test ClientKit.Tests/ArkDeck.ClientKit.Tests.csproj -c Release -p:Platform=x64`，筛选 ClientTests、DeviceRunDeadlineTests | 17 / 17，覆盖有界等待、超时及禁止重放；`ClientKit.Tests/bin/fluent-redesign/fluent-client-bounds.trx`。首次沙箱 NuGet 审计联网失败，恢复正常网络访问后通过。 |
| `dotnet test App.UITests/ArkDeck.App.UITests.csproj -c Release --no-restore -p:Platform=x64`，筛选 FluentLayoutTests、SemanticSnapshotTests.PagesMatch | 76 / 76：54 个宽窄窗口 / 深浅主题布局案例、22 个双语语义案例；`App.UITests/bin/fluent-redesign/fluent-release-ui.trx`。 |
| 同一 UIA 项目，筛选 AccessibilityTests；关键界面流程 | Tab 顺序 25 / 25、225% 字号 40 / 40、高对比度 token / access key / Escape 检查通过；关键流程 14 / 14。日志为 `fluent-final-layout-semantics.trx`、`fluent-layout-accessibility.trx` 和 `fluent-final-flows.trx`。这些较早的组合 run 含展开态 Inspector 测试准备失败，不作为整个 run 通过的证据；修正显式展开准备后，最终 76 项矩阵全部通过。 |
| `scripts/package-rc.ps1 -SigningMode development -AllowDirty -SkipMsix -Smoke`，指定新的输出目录与现有签名证书 | 签名包安装、doctor、App UIA、卸载与状态保留均 PASS；包目录中的 `smoke.json` 记录完整步骤，调用记录见 `AppPackages/fluent-final-package.log`。 |
| 同一 UIA 项目，筛选 InstalledRcTests，指向实际当前用户安装及其 endpoint / signer pin | 1 / 1，正常连接、真实诊断、协议及按钮检查通过；`App.UITests/bin/fluent-redesign/fluent-installed-final.trx`。 |
| 开始菜单入口与卸载保护检查 | 原生窗口已打开，真实 doctor 可读，无 fixture transport / recovery banner；App 打开时卸载拒绝且文件与注册项保留。`AppPackages/installed-shortcut-summary.json`、`uninstall-protection.log`。 |
| `python rust/scripts/run-cargo.py fmt -p <crate> -- --check`，覆盖全部 workspace crate | 13 / 13，exit 0。全仓 `fmt --all --check` 触发 Windows 命令长度上限（error 206），改为同一缓存内逐 crate 检查；日志见 `AppPackages/fluent-pr-fmt.json`。 |
| `bash scripts/check-sdd.sh`；`git diff --check` | SDD 与 diff 格式检查通过；日志见 `AppPackages/fluent-sdd.log`。 |

CI：本次安装验收记录整理于 PR 提交前，尚无 GitHub CI 结果。提交后的 PR 号、run id 和结论在 PR 正文记录。本机未运行完整统一门；Rust 源码和契约输入未修改，仅打包时执行 `cargo build --release --locked`。

本地安装：365 个安装文件的大小和 SHA-256 均与最终 manifest 一致，三个程序的签名已验证。最终 xcopy ZIP 的 SHA-256 为 `326143c105e96f4132bfb919b5760df078ced01a2cff9774966512a9d8d77bb8`。新 Runtime 从当前用户安装目录运行，协议 `1.0.0`，原有 37 条 Job 完整保留。`AppPackages/installed-final-summary.json`、`installed-final-doctor.json` 记录本机检查。本机 HDC 与设备发现仍未配置，doctor 如实显示该配置阻塞；本轮没有执行设备操作。

视觉检查图位于 `windows/App.UITests/bin/fluent-redesign/screenshots`，包括全部页面、九个设置分类、选中记录详情与 Viewer 三栏的深浅主题 / 宽窄窗口图。示例：`overview-1280-light.png`、`settings-general-1280-dark.png`、`settings-general-720-light.png`。截图和机器日志保存在本机忽略目录，方案不包含账户、SID 或真实设备标识。
