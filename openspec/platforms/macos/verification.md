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

## M1 HDC evidence method

TASK-M1-006 platform evidence fixes the source revision, registry/resource/control-vector hashes,
OS/architecture/Xcode tuple, signed Sandbox App and executable hashes, signing identity, and full
entitlement dump. Contract tests execute only the repository fake executable as a descriptor-bound
child and assert the registered production classifier against every control vector. Signed
XCUITest selects that fake through the system file picker, proves bookmark restoration after App
relaunch, and checks supported/unsupported/unknown diagnostics without invoking a real HDC.

Production composition must make the App-root host actor the only package-visible lifecycle
factory, require a complete participant inventory at that boundary, and fail closed unless both
endpoint identity and participant-impact reliability receipts exist. A terminal manifest-write
failure intentionally remains durable `recoveryRequired` across composition reopen and permits no
subsequent lifecycle dispatch. M1-006 supplies no finalize-retry solver: the terminal journal pins
the manifest SHA while `completedAt` is generated at finalization, so byte-reproducible recovery
requires a separately approved journal/storage change rather than an in-task retry guess.

For `selectedDeviceAuthorizationBinding`, evidence must also prove exact equality with the
registry-captured raw family. A newly observed device row is unavailable even if strict parsing
matches its durable binding; parameterizing that family requires a separately approved integration
change and cannot be inferred by this platform profile.

The run must report automatic lifecycle, subserver, and device-migration dispatch counts and keep
all three at zero for external/unknown or unsupported paths. Evidence is M1 task evidence only; it
does not change the `notStarted` platform conformance state, ADR-0001 distribution decision, real
hardware support, or release status.

M0A 通过只说明平台 Port 可行，不证明真实 OpenHarmony 设备、Trace parser 或 Flash Provider 已支持。

平台不得从 Core acceptance index 删除 AC 或自行声明 `notApplicable`；适用性变化只能通过 Core change 修改 conformance manifest。

Release PCE 还必须 exact 覆盖 `conformance-cases.yaml` 的平台 case 与 support cell，并固定 source commit、签名 App artifact hash、OS build、architecture、Xcode/Swift toolchain 和有效期。只有该 tuple 可称 verified；不同 App bytes 或环境必须重验。
