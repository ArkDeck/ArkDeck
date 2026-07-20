# macOS Verification Profile

> Status：draft  
> Core baseline：CORE-2.0.0
> Shared inputs：由每个 Task 固定 accepted Integration lock、profile 与 Core conformance hash

## M0A exit criteria

- 完整 Xcode 可运行 SwiftUI/runner prototype；
- 外部 HDC path/version/hash/signature 可诊断；
- HDC main server supervisor prototype 可附着既有 server 且不自动 kill；
- `flock` 单实例、journal durable write 和 power lease prototype 通过故障路径；
- Sandboxed 与非 Sandbox prototype 均完成 HDC `version`、server、USB/TCP/UART、key、外部镜像和输出目录测试；
- Gatekeeper/quarantine clean-VM 矩阵完成；
- 保存签名后 entitlement、相关系统日志和 distribution decision record。

## Platform conformance

| Port | Required evidence | Status |
| --- | --- | --- |
| ProcessExecutor | argv/space/unicode/large-output/timeout/cancel contract tests | pending |
| SingleInstanceGuard | 两进程竞争，第二实例零 HDC/Session side effect | pending |
| AppActivationService | 第二实例只激活持锁主实例后退出，且设备/Session side effect 为 0 | pending |
| PowerActivityController | success/failure/cancel/throw/ref-count release tests | pending |
| VolumeIdentityResolver | 同卷异目录、异卷、拔出/重挂 | pending |
| HostStorageProbe | 容量查询、软预留、卷拔出/只读重挂与 ENOSPC 映射 | pending |
| PersistentFileAccess | restart bookmark、child image/key/output end-to-end | pending |
| ToolTrustInspector | signed/unsigned/quarantined/blocked matrix | pending |
| DeviceAccessAdvisor | USB/UART entitlement/permission 诊断与人工修复引导；提权、安装和系统策略修改调用数为 0 | pending |
| SystemLogger | privacy/redaction/rotation/export | pending |
| ElapsedDeadlineClock / ActiveWorkClock | wall-clock jump、sleep 期间 elapsed 推进/active 暂停、wake 后 ETA reset | pending |
| SleepWakeObserver | sleep/wake 通知、重复通知去抖、wake 后 reconcile/reconnect/ETA segment reset | pending |
| PlatformFileRevealer | Finder reveal 成功、文件缺失和无权限 fallback | pending |

M0A 通过只说明平台 Port 可行，不证明真实 OpenHarmony 设备、Trace parser 或 Flash Provider 已支持。

平台不得从 Core acceptance index 删除 AC 或自行声明 `notApplicable`；适用性变化只能通过 Core change 修改 conformance manifest。

Release PCE 还必须 exact 覆盖 `conformance-cases.yaml` 的平台 case 与 support cell，并固定 source commit、签名 App artifact hash、OS build、architecture、Xcode/Swift toolchain 和有效期。只有该 tuple 可称 verified；不同 App bytes 或环境必须重验。
