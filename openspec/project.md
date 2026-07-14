# ArkDeck Project Context

> Product spec：1.0.0  
> Core baseline：CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Declared target platforms：macOS、Windows、Linux（同一 Core，不另建产品规则）  
> Delivery/support lifecycle source：`platforms/PLATFORM-PROFILES.lock.yaml`

平台的 current delivery、not started 与 conformance 状态记录在 `platforms/PLATFORM-PROFILES.lock.yaml`，不写入 Core baseline。新增平台实现或推进既有端口发布新的 Platform 状态与平台 evidence，并继承相同 Core Requirement、AC 和 release gate。

Platform 的 `verified` 不是对整个 OS 家族的概括声明，只覆盖实际验证过的 OS/architecture/构建产物组合与证据有效期。发布新构建而无新证据时，状态回到 needsReverification；未验证的组合一律不得声称支持。

## 产品定位

ArkDeck 是 OpenHarmony 桌面设备工作流工具，用于设备连接、刷机、调试、ArkUI UI Dump/Trace 采集以及 Session/Artifact 管理。它不是一层任意脚本执行壳。

## MVP 范围

- 外部优先的 HDC 工具发现、共享 server 监督、设备授权和能力探测；
- ArkUI UI Dump 的四个正式 Recipe；
- hitrace/bytrace 动态适配、参数快照/恢复和 raw/derived trace；
- hilog、应用操作、端口转发和一次性安全命令；
- 一个经真实硬件验证的 HDC/flashd Provider；
- Session、journal/checkpoint、manifest、Artifact、历史和诊断包；
- 简体中文和英文 UI。

## Dump 术语

- **ArkUI UI Dump**：窗口、组件树和组件详情；当前 MVP。
- **Fault/Crash Artifact**：FaultLoggerd/HiviewDFX 的 C++/JS crash、Rust panic、AppFreeze、coredump/minidump/主动抓栈；非 MVP。
- **System Diagnostic Snapshot**：HDC `bugreport` 或整机诊断快照；非 MVP。

UI 和对外文档必须使用完整术语，不能把三类能力都暗示为已支持。

## 首版非目标

- 自研 ArkTS/C++ 源码级调试器；
- 所有芯片/厂商刷机协议；
- 内嵌完整 Trace 时间线查看器；
- 任意 shell 脚本插件；
- 完整 PTY/VT100 终端；
- Fault/Crash Artifact 与 System Diagnostic Snapshot；
- 默认遥测、自动崩溃上传或自动更新；
- 假设一个 bundled HDC 可覆盖全部固件。

## 关键术语

| 术语 | 含义 |
| --- | --- |
| OriginalTargetSnapshot | Job 创建时不可变的初始 endpoint、transport 和设备身份快照 |
| CurrentDeviceBinding | 当前已确认的寻址和身份绑定，包含递增 revision 与 evidence |
| HDCEndpoint | HDC client/server 连接端点及其 tool、version、ownership、generation |
| Job | 可持久化、可恢复的工作流实例 |
| Session | Job 的目录、journal、manifest、日志和 Artifact 边界 |
| Raw Artifact | 不可修改的设备或工具原始证据 |
| Derived Artifact | 从 raw 可重复生成的过滤、合并或转换产物 |
| outcomeUnknown | 已记录 intent，但无法证明外部副作用结果 |
| Device hazard | 归档后仍可能存在的远端任务、参数变更或未知设备状态 |
| Core baseline | 跨平台产品行为、Safety invariant、contract 和 AC 的锁定集合 |
| Platform profile | 平台 API、UI、权限、打包和平台验证实现，不得覆盖 Core |

## 设计默认值

- HDC 外部优先；bundled 仅作为未来经过兼容、许可证、签名和供应链评审的 fallback。
- 默认不 kill external/unknown HDC server。
- TCP 目标只允许显式添加；授权与链路保护分开显示，无法验证加密时按未保护策略处理。
- 不修改 raw Artifact，不自动上传设备数据。
- 不确定 destructive outcome 不自动重放。
- 总体工期保持 `TBD / 待硬件确认`，M0B 之后再锁定 Flash 估算。

## 规范与实现边界

Cross-platform spec 只描述可观察行为、状态、数据 contract 和验收。Swift Actor、SwiftUI、WinUI、GTK/Qt、Foundation Process、Windows Process API、POSIX spawn、flock/Mutex、IOPM/Power Request/systemd inhibitor 等内容属于 platform profile 或 design。Core 的物理复用模型是共享 language-neutral contracts/fixtures/conformance vectors、各平台 native conforming implementation；见 `architecture/core-portability.md`。
