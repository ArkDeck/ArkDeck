# Design — CHG-2026-063

## 分层

```
crates/arkforge-usb          新 crate：IOKit FFI 收容层（唯一允许 unsafe/FFI）
  - 枚举：匹配 vendor 0x2207，读取描述符（serial、topology/locationID）
  - 独占打开 + claim 接口 + bulk in/out + 超时
crates/arkforge-provider     RockUSB 协议引擎（纯 Rust，无 unsafe）
  - CBW/CSW 风格 31 字节命令块封帧
  - TEST_UNIT_READY / READ_LBA / WRITE_LBA / DEVICE_RESET / READ_CAPACITY…
  - name→LBA：复用 session.observed_table()（写前已强制核对 offset）
crates/arkforged             端口双轨
  - trait RockUsbPort（typed 语义面，替代 argv/stdout）
  - VendorToolPort：现 FixedToolPort 包一层（过渡期 fallback）
  - NativeRockUsbPort：新实现
```

## 协议参考的规范来源

**不要**从记忆或本文档拼写 opcode。以 pinned vendor 工具的开源源码为规范
参考（rockchip-linux/rkdeveloptool，与 `231a05ef…` 对应的版本），逐条对照
`ld`/`ppt`/`wlx`/`rl`/`rd` 的实际 USB 交互实现（必要时 A/B 抓包比对）。
兼容性判据是"与 vendor 工具对同一设备产生逐字节相同的读回、相同的写后
读回摘要"，不是"看起来像文档"。

## Typed 端口消灭的整类脆弱性

vendor 路径的判定靠 stdout marker（"Write LBA from file (100%)"），曾因
截断保头弃尾把成功的 2 GB 写误判 outcome-unknown（gap 24 / AD-032）。
原生端口返回 typed 结果（写入字节数、每块回执、错误码），marker 类判定
全部删除。receipts 形状保持（digest/facts），evidence 更强。

## A/B 互证（campaign 期间）

- 读路径先行：原生 `rl`/`ppt`/枚举 与 vendor 工具对同一设备逐字节比对。
- 写路径：原生写 → vendor 读回验摘要；vendor 写 → 原生读回验摘要。
- 每一步 A/B 差异都是 blocker，不是噪声。

## Toolchain 身份与成熟度

- `ToolchainKind` 增加原生种类（如 `nativeRockUsb`）。
- identity digest = arkforged 自身构建摘要（`--arkforged-sha256` 已有）。
- `publish_dayu200_maturity` 为新组合发布；无 campaign 时 `hardwareGated`
  照旧成立——这是治理正确性，不是回归。

## ArkDeck 观察半边换源（TASK-NRU-003）

现在 Loader 观察是双源：IOKit（`ProductRockchipRuntimeUSBProbe`）+ vendor
`ld` 回执。vendor 退役后第二源改为 **arkforged `discoverDevices`**
（daemon 面已存在；`DeviceObservation` 携带 serial_evidence /
topology_digest / identity_strength，facts 足够）。涉及：

- `ArkForgeControlPerformer` 的 `waitForLoader`/`rebindLoader` 动作路径
  （`RockchipRuntimeActionHost` 中 `observeLoader(executable:)` 的调用点）；
- `flash.bind-current-loader`（重绑流程）同源替换；
- 双源规则不变：IOKit 观察 + daemon 观察回执，缺一仍拒。

## 已知运维事实（实现者必读，2026-08-18 实测）

- 板子身份会漂移：Loader serial、hdc key、USB locationID 都可能在
  replug/首启后变化；重连接受"单设备 + (topology 或已知 key 别名) 任一
  匹配"，两者同时漂移 = 需要 rebind（已实现，勿回退）。
- 完整覆写后的首启 1–8 分钟（userdata 初始化）；postflight 等待预算 600s
  在 `verifyBoundBuild` 内部（勿改回 15s，勿改错到 reconnect 动作上）。
- 部署验证：注释不进二进制——验证安装件用**新字符串字面量**或对 staged
  已签名件做摘要比对。
- 台架重启仪式：`bootout` → `pkill -9 -f "arkforged --runtime-dir"` →
  `pkill -f "toolchains/hdc"`（argv 里 `-m` 在末尾，"hdc -m" 模式匹配不到）
  → 删 `arkforge/*.sock` → `agentd update`（全套 lane flag）。
- 每次刷机消费一个 capability 代（maxUses=1）；请求**不带** authorization
  块由 runtime 默认策略铸下一代；上一代 use 未了结时先 `job reconcile`
  （unknown 的 lane job 会走"对设备验证"了结）。
