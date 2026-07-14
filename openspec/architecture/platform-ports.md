# Platform Port Contract

> Status：in baseline CORE-1.0.0（ratification 状态见 `openspec/baselines/CORE-1.0.0.yaml`）  
> Applicability：all desktop platforms

平台实现必须提供以下行为端口。具体类名和 API 属于平台设计，但语义由 Core specs 固定。

| Stable ID | Port | 必须提供的行为 |
| --- | --- | --- |
| `PORT-PROCESS-001` | `ProcessExecutor` | 以绝对 executable 和 argument array 启动；流式 stdout/stderr；受控 timeout/cancel；不经过 host shell |
| `PORT-INSTANCE-001` | `SingleInstanceGuard` | 同一用户/产品只有一个写入实例；第二实例不得访问设备或 Session |
| `PORT-ACTIVATION-001` | `AppActivationService` | 第二实例可请求激活主实例后退出，不替代内核级锁 |
| `PORT-POWER-001` | `PowerActivityController` | critical operation 阻止 idle sleep；引用计数；所有终止路径释放；不承诺阻止合盖/主动睡眠 |
| `PORT-VOLUME-001` | `VolumeIdentityResolver` | 根据真实卷身份而非路径字符串归组 |
| `PORT-STORAGE-001` | `HostStorageProbe` | 查询 free space、处理卷拔出/重挂、报告 ENOSPC |
| `PORT-FILE-ACCESS-001` | `PersistentFileAccess` | 用户选择工具、镜像和输出目录；跨启动最小权限访问 |
| `PORT-TOOL-TRUST-001` | `ToolTrustInspector` | 展示工具 path、hash、version、签名/来源和平台信任状态，不自动绕过安全机制 |
| `PORT-DEVICE-ACCESS-001` | `DeviceAccessAdvisor` | 诊断 USB/UART driver、权限、group/rule/entitlement 状态并给出最小权限引导；不得静默提权、安装 driver 或修改系统规则 |
| `PORT-LOGGING-001` | `SystemLogger` | 有界、可脱敏、可导出的 App 自身诊断 |
| `PORT-CLOCK-ELAPSED-001` | `ElapsedDeadlineClock` | 单调且在系统睡眠期间继续推进，用于 overall deadline/timeout；进程重启不复用旧 tick origin |
| `PORT-CLOCK-ACTIVE-001` | `ActiveWorkClock` | 单调且在系统睡眠期间暂停，用于 active duration、throughput 和 ETA sample |
| `PORT-SLEEP-WAKE-001` | `SleepWakeObserver` | 记录 sleep/wake、重置速率 segment 并触发 reconnect/reconcile |
| `PORT-FILE-REVEAL-001` | `PlatformFileRevealer` | 在 Finder/Explorer 等平台文件管理器显示 Artifact |

## 可替换工程细节

- UI toolkit、窗口与导航布局；
- actor/queue/thread 实现；
- process、lock、power、bookmark/token、volume、device-access diagnostics、logging API；
- 签名、公证/SmartScreen、installer 和 update framework；
- 平台目录与路径表现形式。

## 不可替换产品语义

- Requirement/AC ID、状态机和终态含义；
- binding revision 与重绑定确认；
- server ownership 和 host-wide 影响；
- write-ahead journal、effect/cancellation、recovery 和 hazard；
- raw/derived、manifest、StorageBudget 和隐私；
- plan-only/simulation/execute 的区分；
- 危险确认、风险提示与 release gate。

Windows 或其他端口如果发现某条 Core 规则无法实现，只能创建 Core change proposal 或把该能力标记为 non-conformant；不得在 platform profile 中定义 override。
