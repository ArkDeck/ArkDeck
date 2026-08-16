# WaterFlowTraceDemo

ArkTrace 的性能 demo：一个可重复、可比较的真实 OpenHarmony 负载，用来跑通
「采集 → 结构化分析 → 判断 → 改一处 → 复采 → 比较」这条闭环。

它是从 `WaterFlowLayoutDemo` 分出来的。那个是 **ArkDeck 的崩溃 demo**，会在启动约 12 秒后
用 `CrashProbe` 主动 abort 进程，好让 ArkDeck 的自动调试闭环有一个真实的 cppcrash 可查。
那个目的和 trace 的目的直接冲突——进程一崩，任何 10 秒采集窗口里都没有持续负载可测。
所以两件事拆成两个 demo，各自只做一件事。

## 两个 demo 的分工

| | WaterFlowLayoutDemo | WaterFlowTraceDemo（本项目） |
|---|---|---|
| 服务对象 | ArkDeck 自动调试闭环 | ArkTrace 真实调试闭环 |
| 关键机制 | `CrashProbe.ENABLED`，启动 12 s 后 abort | `TraceWorkload`，固定节奏的确定性负载 |
| 期望终态 | 进程崩溃并留下 fault block | 进程存活并稳定产出可比较的工作量 |

## 控制开关

全部在 `entry/src/main/ets/traceworkload/TraceWorkload.ets`：

- `DRIVER_ENABLED` —— 是否按固定节奏刷新 feed。关掉就只是一个静止的 app，
  trace 里会是一台空闲设备，没法做前后比较。
- `RELOAD_INTERVAL_MS` —— 刷新间隔，默认 500 ms（10 s 窗口 = 20 次）。
- `USE_BLANKET_RELOAD` —— 用哪种通知策略：
  - `true`：复现反模式，每次 reload 都 `onDataReloaded()`，LazyForEach 丢弃并重建全部 item，
    嵌套 WaterFlow 整棵重测；
  - `false`：按 identity signature 比较，只对真正变化的行发 `onDataChange(index)`，
    数据完全相同则不通知。

把 `USE_BLANKET_RELOAD` 从 `true` 翻成 `false`，就是 ArkTrace Phase 6 闭环施加的那处变更。
在 DAYU 200 上以 500 ms 节奏、10 s 窗口实测：App 进程从单核 2.63% 降到 0.33%，
主线程占该进程 97% 的开销随之消失。重跑闭环应能复现同一量级的差值。

## 构建

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。

## 部署

走 ArkDeck 的 typed 链路，不要手工推 HAP：

```text
arkdeck artifact import-hap  ->  workspace.sign-openharmony-hap@1  ->  debug.hap@1
```

采集前需要把设备置于场景前置条件：唤醒并解锁屏幕、把息屏超时调长
（`power-shell timeout -o 1800000`），否则 App 会退到后台，采到的又是一台空闲设备。

## 已知约束

`bundleName` 仍是 `com.example.waterflowdemo`，与崩溃 demo 相同。本机的 OpenHarmony 签名
profile 就是按这个 bundle 签发的，改名后签不了名也就装不上。因此两个 demo 靠项目和用途区分，
不靠 bundle 区分——设备上同一时刻只装其中一个，跑哪个就部署哪个。
