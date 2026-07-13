# Desktop UX, History, and Observability Specification

> Version：1.0.0  
> Status：review candidate  
> MVP：yes  
> Applicability：all platforms

## Purpose

定义跨平台桌面信息语义、History、Recovery UX、App 自身诊断、本地化和无障碍。具体布局属于平台 Profile。

## Requirements

### Requirement: REQ-UX-001 Stable feature navigation and status semantics

应用 SHALL 提供 Devices/Overview、Flash、Debug、UI Dump、Trace 和 History 能力入口，并提供全局 Job 状态、阶段、日志、取消和恢复入口。平台 MAY 改布局，但状态和风险语义 SHALL 相同。

#### Scenario: AC-UX-001-01 Job 跨页面可见

- GIVEN用户离开正在运行的 Trace 页面
- WHEN切换到其他功能
- THEN全局 Job UI 仍显示阶段、状态和允许的操作

### Requirement: REQ-UX-002 Environment and server diagnostics

Overview SHALL 显示 HDC tool/path/source/version/hash/signature、server endpoint/ownership/health、key strategy、授权、设备能力和 channel protection evidence 状态。

#### Scenario: AC-UX-002-01 Version mismatch 可诊断

- GIVEN client/server mismatch-unverified
- WHEN用户查看 Overview
- THEN可看到双方 version/path/endpoint 和降级状态

### Requirement: REQ-UX-003 Recovery banner and explicit abandonment

存在未 finalize Job 时，启动后 SHALL 优先展示 Recovery Banner。Banner SHALL 区分 resume-safe、waiting、unknown outcome 和“结束恢复并归档 interrupted”，并展示该动作不会证明设备恢复。

#### Scenario: AC-UX-003-01 不能安全放弃

- GIVEN critical child 仍可能写分区
- WHEN用户打开 Recovery Banner
- THEN归档动作禁用或等待安全边界

### Requirement: REQ-UX-004 History preserves semantics and evidence

History SHALL 支持按 Session/状态/设备/时间搜索，查看 manifest、journal 摘要、Artifact、warnings、executionMode、outcome certainty 和 recovery linkage，并支持平台文件管理器定位与显式导出。

#### Scenario: AC-UX-004-01 Interrupted 与 failed 可区分

- GIVEN历史中同时存在 failed 和 user-abandoned interrupted Job
- WHEN用户筛选/查看
- THEN两者使用不同状态与审计详情

### Requirement: REQ-DIAG-001 Structured, bounded app diagnostics

ArkDeck SHALL 按 app、hdcServer、workflow、storage、ui 等类别记录有界结构化诊断和平台系统日志，使用隐私/redaction 处理设备 ID、路径和业务字符串。

#### Scenario: AC-DIAG-001-01 App 日志有界

- GIVEN应用长期运行
- WHEN诊断日志达到配额
- THEN日志轮转或清理而不无限增长

#### Scenario: AC-DIAG-001-02 分类与脱敏

- GIVEN 诊断事件包含设备标识、用户路径和业务字符串
- WHEN app、hdcServer、workflow、storage 或 ui logger 写入事件并导出诊断
- THEN 事件保留规范类别和关联 ID，但敏感值按 redaction policy 脱敏
- AND 原始敏感字符串不出现在默认日志或诊断包

### Requirement: REQ-DIAG-002 User-initiated diagnostic export

诊断包 SHALL 由用户主动触发并可预览。默认 MAY 包含 app/build/platform、脱敏 HDC/tool/server 信息、最近 Job journal/manifest 摘要和 App 日志；设备 raw SHALL 默认排除。

#### Scenario: AC-DIAG-002-01 无自动上传

- GIVEN用户未启用未来明确的 opt-in 遥测
- WHEN App crash 或 Job 失败
- THEN不会自动上传诊断或设备数据

### Requirement: REQ-UX-005 Dangerous actions are explicit and accessible

危险动作 SHALL 使用文字、图标、影响范围和确认摘要，不能只靠颜色。键盘和辅助技术 SHALL 能感知状态、危险程度和确认控件。

#### Scenario: AC-UX-005-01 无颜色判断

- GIVEN用户使用高对比度或屏幕阅读器
- WHEN危险确认出现
- THEN风险和动作含义仍可被读取和操作

### Requirement: REQ-I18N-001 Chinese and English from the first release

ArkDeck 自有 UI、错误摘要、危险确认和恢复指引 SHALL 提供简体中文与英文。设备 raw output、命令和 Artifact SHALL 保持原文；日期、数字、时长和文件大小 SHALL 按 locale 格式化。

#### Scenario: AC-I18N-001-01 长文本和缺失 key

- GIVEN切换中英文或 pseudo-localization
- WHEN运行主要 smoke flow
- THEN关键控件不依赖字符串拼接
- AND缺失 localization key 被测试发现

### Requirement: REQ-UX-006 Execution-mode badges persist

Plan-only 和 simulated SHALL 在 Flash 页面、全局 Job UI、History、manifest 和导出中持续标识，不能因 Job 结束而消失。

#### Scenario: AC-UX-006-01 导出后仍显示模拟

- GIVEN simulated Session 被另一台机器导入或查看
- WHEN读取 manifest
- THEN UI 显示 simulated badge 和 fixture identity

### Requirement: REQ-UX-007 Device access guidance never silently escalates

平台发现 USB/UART driver、entitlement、udev rule、group 或设备权限不满足时 SHALL 显示可诊断状态、平台适用的最小权限指导和需由谁执行；ArkDeck SHALL NOT 自动调用 sudo/pkexec、安装 driver/helper、写系统 rule、修改全局 group/ACL 或降低设备节点权限。用户完成外部修复后系统 MAY 重新 probe，但 SHALL NOT 把缺失权限解释为设备离线或授权拒绝。

#### Scenario: AC-UX-007-01 平台设备访问前置条件缺失

- GIVEN 当前平台可枚举候选 USB/UART 设备，但进程因 driver、entitlement、udev rule、group 或设备权限之一不满足而无法访问
- WHEN DeviceAccessAdvisor 诊断连接失败
- THEN UI 区分 `permissionDenied`、`driverUnavailable` 与 `offline/unauthorized`，并展示当前平台适用的人工修复责任方、最小权限步骤与重新 probe
- AND sudo/pkexec、host privilege elevation、driver/helper 安装、系统 rule 写入、group/ACL 修改和全局设备权限降低调用数均为 0
