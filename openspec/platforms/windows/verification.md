# Windows Verification Profile

> Status：planned  
> Core baseline：CORE-1.0.0  
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash  
> Conformance：notStarted

Windows SHALL 执行与 macOS 相同且 hash 固定的 Core conformance suite，并增加平台 Port 和分发验证。Windows Profile 不得删除 acceptance index 中的 AC，也不得自行声明 `notApplicable`；任何 applicability 变化都必须通过 Core change 修改 suite manifest。

## Required platform suites

- Process argv/no-shell/process-tree/timeout/cancel/large stream；
- Named Mutex 单实例与主实例激活；
- Power Request 引用计数和异常释放；
- Volume GUID 归组、drive letter 变化、可移动卷拔出/重挂；
- 文件选择/跨启动访问；
- Authenticode、Mark-of-the-Web、SmartScreen 和 Defender；
- DeviceAccessAdvisor 的 USB/UART driver、设备状态与权限 allow/deny 诊断，以及提权、安装 driver、修改系统策略调用数为 0；
- ETW/结构化日志隐私、轮转和诊断导出；
- elapsed clock 跨 sleep 继续推进、active-work clock 跨 sleep 暂停、wake 后 ETA reset，以及关机请求/critical step 协调；
- PlatformFileRevealer 的 Explorer reveal、文件缺失、无权限与 Explorer 不可用 fallback；
- MSIX/installer、签名、升级、卸载和 clean-host smoke；
- `zh-Hans`/`en`、键盘、屏幕阅读器和危险确认。

## Release condition

所有适用 Core MUST/Safety AC 必须为 verified。实现进度只由 Change/Task/run 表达，不新增 `implemented`、`partial` 等 Platform lock 状态；没有完整 PCE 时 `conformance_status` 不得标记 `verified`。真实 Flash 支持仍需要精确设备/固件/HDC/Provider 的硬件矩阵证据。

Release PCE 必须 exact 覆盖 `conformance-cases.yaml` 的平台 case/support cell，并固定 source commit、MSIX/installer artifact hash、Windows build、architecture、toolchain 与有效期；未列 tuple 不构成 Windows 支持。
