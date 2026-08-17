# WaterFlowTraceDemo

ArkTrace 的性能 demo：一个可重复、可比较的真实 OpenHarmony 负载，用来跑通
「采集 → 结构化分析 → 判断 → 改一处 → 复采 → 比较」这条闭环。

这一个工程同时服务两条闭环，靠 `entry/src/main/ets/fixture/FixtureMode.ets` 里的 `MODE`
选择当前扮演哪一个。两条闭环对这个 App 的要求正好相反——crash 要它尽快崩，trace 要它整个
采集窗口都活着——所以模式是一个枚举而不是两个各自独立的布尔，避免出现"半开"的状态。

## 两种模式

| | `crashProbe` | `traceWorkload` |
|---|---|---|
| 服务对象 | ArkDeck 自动调试闭环（GJ-2/GJ-3） | ArkTrace 真实调试闭环（Phase 6） |
| 关键机制 | 启动 12 s 后在具名帧里 abort | 固定节奏的确定性负载 |
| 期望终态 | 进程崩溃并留下 fault block | 进程存活并稳定产出可比较的工作量 |

`crashProbe` 在当前这台设备上**达不到期望终态**，原因见下方「已知约束」，这不是模式本身的缺陷。

## 控制开关

全部在 `entry/src/main/ets/fixture/FixtureMode.ets`：

- `MODE` —— 选择上表两种模式之一。
- `CRASH_DELAY_MS` —— `crashProbe` 模式下从启动到 abort 的延迟，默认 12 s。这个延迟是有作用的：
  `debug.hap@1` 要先安装、拉起 ability、读回进程存活并完成一次有界采集，崩得太早会让部署作业
  失败，而不是留下一个 fault block 给下一个观察者。
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

### 这台 DAYU 200 上无法加载原生库，因此 `crashProbe` 产不出 cppcrash

`crashProbe` 的设计是调用 `libcrashprobe.so` 里的具名帧执行 `std::abort()`，产生一个真实的
cppcrash。**在这台设备（OpenHarmony 7.0.0.37）上它从未成功过**：`.so` 加载失败，ArkTS 侧拿到
`undefined`，于是抛出一个 TypeError，进而记录为 `jscrash` 而不是 `cppcrash`。155 次以上的故障
记录里没有一条 `cppcrash`。

根因**不在本工程、也不在 ArkDeck**，而在设备镜像：

```
$ hdc shell param get const.product.cpu.abilist
default
```

`default` 不是合法的 ABI 名。OpenHarmony NDK 的 `ohos.toolchain.cmake` 只接受
`arm64-v8a` / `armeabi-v7a` / `x86_64`，sysroot 也只有对应的三个目录，所以构建产出的必然是
`libs/arm64-v8a/`。BMS 安装时拿设备 abilist 去匹配包里的 `libs/<abi>/`，匹配不上，于是：

```
applicationInfo.nativeLibraryPath        : ""
applicationInfo.cpuAbi                   : ""
hapModuleInfos[].nativeLibraryFileNames  : []
```

没有注册原生库路径，dlopen 就报 `app lib path not registered in namespace 'default'`。
这台设备上**任何**应用都受此影响，不只是本工程。

排查时已经用实证排除的假设，不必重走：

| 假设 | 证据 |
|---|---|
| `.so` 没打进 HAP | 未签名与签名 HAP 里 `libs/arm64-v8a/libcrashprobe.so` 都在 |
| 签名过程剥掉了 libs | 签名前后 zip 条目一致 |
| `.so` 无效或架构不符 | `ELF 64-bit LSB, AArch64`，带 BuildID |
| 应用进程是 32 位 | 崩溃日志里该进程自己在加载 `/system/lib64/` |
| 模块未声明原生库 | 加 `compressNativeLibs: false` 后进了打包 module.json，**上机行为不变** |

要真实验证 cppcrash 与 GJ-3 原生调试，需要一台 abilist 配置正确的设备或镜像。在此之前，
`crashProbe` 模式在这台设备上只能产出 jscrash——它仍然是一个真实崩溃，只是不是原生崩溃。

诊断入口已内置：`debug.hap@1` 的 `install-readback.json` 现在会记录 `nativeLibraryPath`、
`cpuAbi` 和 `nativeLibraryFileCount`。三者为空/零即表示设备没有接收任何原生库，不必再手工
`bm dump`。

### bundleName 与签名 profile 绑定

`bundleName` 固定为 `com.example.waterflowdemo`。本机的 OpenHarmony 签名 profile 就是按这个
bundle 签发的，改名后签不了名也就装不上。两种模式因此靠 `MODE` 区分，不靠 bundle 区分——
设备上同一时刻只有一个模式在跑，跑哪个就用哪个模式重新构建部署。
