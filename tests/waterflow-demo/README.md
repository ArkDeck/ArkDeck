# waterflow-demo

设备侧 fixture：一个真实的 OpenHarmony 应用，供两条闭环使用。它不是示例代码，是被测对象。

## 两种模式

模式由 `entry/src/main/ets/fixture/FixtureMode.ets` 里的 `MODE` 单选，二者互斥：

| `MODE` | 服务对象 | 行为 | 期望终态 |
|---|---|---|---|
| `FixtureMode.crashProbe`（默认） | ArkDeck 自动调试闭环 | 启动约 12 s 后主动 abort | 进程崩溃并留下 fault block |
| `FixtureMode.traceWorkload` | ArkTrace 真实调试闭环 | 按固定节奏刷新 feed，进程存活 | 稳定产出可比较的工作量 |

**为什么是一个选择器而不是两个布尔开关**：它们曾经是各自独立的开关，crash probe 默认开着，
结果在没人注意的情况下把 ArkTrace 的三次采集从中间打断。模式不可能被"设了一半"。

### crashProbe 参数

- `CRASH_DELAY_MS`（12000）—— 延迟是有意的。`debug.hap@1` 要先安装、拉起 ability、回读进程
  存活并做一次有界采集；崩得更早会让部署 job 直接失败，而不是在日志缓冲区留下 fault block
  给下一个观察者。
- `CRASH_SIGNATURE` —— `SIGABRT+WaterFlowCrashProbe_RecoverBack`，criterion 声明的就是它。

### traceWorkload 参数

- `RELOAD_INTERVAL_MS`（500）—— 刷新节奏。没有驱动的话，这个 app 的 trace 就是一台空闲设备的
  trace，两份这样的 trace 无法比较。
- `USE_BLANKET_RELOAD` —— reload 策略：
  - `true`：复现反模式，每次 reload 都 `onDataReloaded()`，LazyForEach 丢弃并重建全部 item，
    嵌套 WaterFlow 整棵重测；
  - `false`：按 identity signature 比较，只对真正变化的行发 `onDataChange(index)`，
    完全相同则不通知。

把 `USE_BLANKET_RELOAD` 从 `true` 翻成 `false`，就是 ArkTrace Phase 6 闭环施加的那处变更。
DAYU 200 上 10 s 窗口、500 ms 节奏实测：App 进程从单核 2.75% 降到 0.49%，主线程承担了基线
97% 的开销，named ArkUI slice 从 3,348 掉到 50。重跑闭环复现了同一判定，无需改动任何源码。

## 与 Runtime 的耦合点

下列任何一项变动都会让已 pin 的 workspace profile 与已铸造的 capability 失效：

- 项目路径 —— LaunchAgent 的 `ARKDECK_WORKSPACE_PROJECTS=demo-app=<本目录>`；
- 模块与构建目标 —— `waterflow-debug` preset 固定为 `--mode module -p module=entry@default`；
- 产物路径 —— `entry/build/default/outputs/default/entry-default-unsigned.hap`；
- `bundleName` / `abilityName` —— `com.example.waterflowdemo` / `EntryAbility`；
- 崩溃签名 —— 见上。

改路径需要 `arkdeck agentd update --workspace-project <新路径>`，且必须同时重新提供
`--harness-model-*` 参数——harness 的 CLI 工作目录由 workspace 路径推导，只传前者会被
`Harness local CLI working directory must be the validated demo-app project` 拒绝。

## 构建

```bash
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  --mode module -p module=entry@default assembleHap --no-daemon
```

`build-profile.json5` 的 `signingConfigs` 是空的，签名材料不入库。构建只产出 unsigned HAP，
签名由 `workspace.sign-openharmony-hap@1` 用 closed preset 完成——生产链路本来也只消费 unsigned
那一份。需要本地签名包时在 DevEco 的 Project Structure → Signing Configs 里自行填写。

## 部署

全程走 typed 链路，不要手工推 HAP：

```text
arkdeck artifact import-hap  ->  workspace.sign-openharmony-hap@1  ->  debug.hap@1
```

`traceWorkload` 模式采集前还需要把设备置于场景前置条件：唤醒并解锁屏幕、把息屏超时调长
（`power-shell timeout -o 1800000`），否则 App 会退到后台，采到的又是一台空闲设备。
