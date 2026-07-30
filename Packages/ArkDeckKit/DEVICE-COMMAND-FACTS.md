# OpenHarmony 设备命令事实表(外部来源:deveco-cli)

Provider lowering 的外部参考。归属 `TASK-DHA-001`,与 `ArkDeckWorkflows/DeviceProviders`
的 lowering/verify 代码同车维护。

来源:`https://gitcode.com/openharmony-sig/deveco-cli`(openharmony-sig,MIT,
DevEco Studio ≥6.1.0 / Command Line Tools ≥26.0.0)。内容提取自其实现文件
(`src/utils/hdc-adapter.ts`、`src/utils/hdc-param.ts`、`src/utils/hilog-adapter.ts`、
`src/ui/**`、`src/apply/install-hqf.ts`、`src/utils/project.ts`、
`src/toolchain/tool-provider.ts`),不是其 README 的用法说明。

## 0. 使用规则(先读)

- **标记含义**
  - `[S]` sourced:来自 deveco-cli 实现的外部事实。**不是 ArkDeck 真机证据**,
    不得写入 evidence,不得据此声明 `REAL_DEVICE_PASS`,也不得直接转成判定代码。
  - `[P]` pinned:ArkDeck 已在真机窗口验证过的事实。本文件初版无 `[P]` 行。
- **唯一作用是收窄搜索空间**:把"这条命令该长什么样"从多轮试错变成一次验证。
  任何一条落成代码判定前,仍按 `verify-every-gate-before-naming-a-blocker` 逐门实测。
- **适用性**:deveco-cli 面向 HarmonyOS + DevEco SDK(hdc 26 系);ArkDeck pin 的是
  `OPENHARMONY-HDC-3.2.0-FAMILY@1`(3.2.0d/3.2.0f)。`bm`/`aa`/`hilog`/`hidumper`/
  `param`/`uitest`/`snapshot_display` 都是 OpenHarmony 原生组件,命令面基本共享;
  **输出格式与解析器跨 hdc 版本不保证一致**,凡涉及解析的行按 `[S]` 对待。
- 本表不放宽 `PRODUCT-LOOP.md` §10「AI/CLI/App 禁止执行 Raw Command」:这些 argv
  只能出现在 provider lowering 内部,不构成可由调用方下发的命令面。

## 1. 工具链定位 `[S]`

```text
hdc      = <sdk>/default/openharmony/toolchains/hdc[.exe]
hvigor   = <tools>/hvigor/bin/hvigorw.js      # 用工具链自带 node 执行
ohpm     = <tools>/ohpm/bin/pm-cli.js
```

- DevEco Studio(macOS)根下多一层 `Contents/`;CLT 根以 `version.txt` 识别。
- 解析优先级:`DEVECO_CLI_STUDIO_PATH` > `DEVECO_CLI_CLT_PATH` > `DEVECO_HOME` >
  `DEVECO_PATH` > 自动发现。
- 运行 hvigor 必须注入 `DEVECO_SDK_HOME=<sdkPath>` 并把 java bin 放进 `PATH`;
  CLT 模式没有自带 JBR,需要外部 `JAVA_HOME`。

## 2. 目标选择与设备清单 `[S]`

```text
hdc list targets        /  hdc list targets -v      # ArkDeck 用 -v
hdc -t <connectKey> <...>                           # 每条设备命令都显式带 -t
```

- 解析跳过 `[Empty]` 行,并**丢弃 `unauthorized` 行**:未授权设备执行任何
  `hdc shell` 都会失败,提前过滤比在下游解释错误便宜。
- `127.0.0.1:<port>` 前缀是"本机模拟器"的唯一判据(ArkDeck 目标是真机,仅备注)。
- 设备可读名按序回退:`ohos.qemu.hvd.name` → `const.product.name` →
  `const.product.model`(去掉 `const.product.brand` 前缀)→ `const.build.product`;
  字面量 `emulator` 视为无效名。
- 设备详情键:`const.product.devicetype`、`const.ohos.apiversion`、
  `const.ohos.releasetype`。

## 3. 判定语义(本表最高价值的一节)`[S]`

1. **退出码在两个方向上都不可信。**
   - deveco 对 `bm install` 的成功判据是 stdout 含 `install bundle successfully.`;
   - ArkDeck 的 `installPackage` verify 注释记录了同一件事:真机上 `hdc install`
     曾 exit 0 而未安装,所以 install/start 只由 readback 判定。
   - 反向同样成立:transient 通道错误给非零退出码,语义是"重试"而非"失败"。
2. **exit 0 时禁止用 stdout 子串做致命错误探针。** `hilog`/`hidumper` 的正常输出
   经常包含 `not found`、`fail` 等子串,宽匹配会把正常采集判成致命错误。
   deveco 的 `detectHdcSentinel()` 第一行就是 `if (exitCode === 0) return null`。
   → 推论:窄判定只可用于**短状态行**输出(`aa`/`bm` 家族),绝不可用于采集类 payload。
3. **transient / fatal 分类**(deveco `classifyHdcOutput`):
   - transient(退避重试):`communication channel is being established`、
     `please wait for several seconds and try again`、`device offline`、
     `[E000004]`、`not connected`
   - fatal(不重试):`[Fail]`、`fail!`、`not found`、`permission denied`、
     `device unauthorized`
   - 退避 `800 / 1500 / 2500 ms`,共 4 次尝试(≈4.8s 墙钟)。
4. **成功/状态串**

   | 命令 | 判定串 |
   | --- | --- |
   | `bm install -p …` | `install bundle successfully.` |
   | `bm uninstall -n …` | 成功 `uninstall bundle successfully`;**未安装** `uninstall missing installed bundle` |
   | `hdc file send` / `file recv` | stdout 以 `FileTransfer finish` 开头 |
   | `bm quickfix …` | 匹配 `/succe(ed|ss)/i` |
   | `uitest uiInput …` | exit 0 且 stdout 不含 `illegal`/`fail`/`error`/`incorrect`/`please confirm that the coordinate values are correct`(白名单 `no error`) |

5. **`param get` 输出可能是 `key = value`,也可能是裸值。** deveco 取第一个 `=`
   之后的内容;ArkDeck 采用更窄的形式:仅当输出以**本次请求的属性键**开头才剥前缀,
   避免值本身含 `=`(如 base64)时被截断。见
   `DeviceProviderAdapters.verify(.queryProperty)`。
   批量取多键时 deveco 用 `param get k1; echo <DELIM>; param get k2; …` 拼一次 shell,
   **且保留逐键回退**——某些 hdc 版本对分号串联行为不一致。

## 4. 文件传输 `[S]`

```text
hdc -t <k> file send <localPath> <remotePath>
hdc -t <k> file recv <remotePath> <localDest>
```

- **`file recv` 的本地目标语义在不同版本/平台上不稳定。** deveco 依次尝试
  `recv <remote> .`(带 cwd)→ `recv <remote> <dir>` → `recv <remote> <dir>/<name>`,
  再**在接收目录里搜索实际落地的文件**并校验魔数。
  → 结论:不要假定 `recv` 会按给定路径落地;收完必须按内容校验(大小 + 魔数/可解析)。
- 推送安装包的标准形态是"目录":`shell mkdir <dir>` → 逐个 `file send` 进该目录 →
  `bm install -p <dir>` → `shell rm -rf <dir>`。

## 5. 安装 / 卸载 / 启动 / 停止 / 存活 `[S]`

```text
hdc -t <k> shell bm install -p <remoteDirOrFile>
hdc -t <k> shell bm uninstall -n <bundleName>
hdc -t <k> shell bm dump -n <bundleName>                    # 包 readback(ArkDeck 现用)
hdc -t <k> shell aa start -a <abilityName> -b <bundleName>
hdc -t <k> shell aa force-stop <bundleName>
hdc -t <k> shell pidof <bundleName>
```

- **多包应用必须一次装完**:entry + feature + 远端 HSP 依赖全部 send 进同一目录,
  由**一条** `bm install -p <dir>` 安装;逐个装单文件不是等价操作。
  ArkDeck 现在只 lower 单文件 + `-r`,单 HAP 场景之外未覆盖。
- `pidof` 可能返回多个空格分隔 PID;进程名等于 bundleName 只对主进程成立。
- `error:install sign info inconsistent` = 签名主体变了,先卸载再装。
- **真机不接受未签名包**:deveco 在 host 侧先判 `-signed.hap` / `-signed.hsp` 后缀,
  不满足直接报错、不下发。注意该后缀是 DevEco 构建约定而非设备要求,只能当作
  廉价前置提示,不能当作签名有效性证明。

## 6. 日志与崩溃 `[S]`

```text
hdc -t <k> shell "hilog -x [-T <tag>] [-L <D|I|W|E|F>] [-D <domain>] [-P <pid>] [-e <regex>]"
hdc -t <k> shell hilog -G <size>                                    # 缓冲区,如 16M
hdc -t <k> shell hidumper -s 1201 -a "-p Faultlogger"               # 列崩溃日志文件名
hdc -t <k> shell hidumper -s 1201 -a "-p Faultlogger -f <filename>" # 取某个崩溃日志内容
```

- `-x` = 一次性输出后退出;follow 模式就是**不带** `-x`。
- hilog 家族在 deveco 里走**流式读取**,注释写明理由:不缓存 stdout/stderr,避免
  `maxBuffer` 溢出。→ 对 ArkDeck 的含义:`outputByteBudget` 是截断策略,不是缓冲
  策略;采集必须流式落盘再判 truncated。
- **时间窗与 tail 是 host 侧过滤**,不是 hilog 参数。
- 崩溃日志文件名末尾带时间戳,取最新 = 按末段降序第一条;Faultlogger 的 SA id 是
  `1201`,`-p`/`-f` 整体作为**一个** argv 元素跟在 `-a` 之后。

## 7. 窗口与 UI Dump `[S]`

```text
hdc -t <k> shell hidumper -s WindowManagerService -a -a          # 窗口清单(= ArkDeck INV-1 形态)
hdc -t <k> shell uitest dumpLayout -p <remote.json> [-d <displayId>] [-w <windowId>]
hdc -t <k> file recv <remote.json> <local.json>
hdc -t <k> shell rm -f <remote.json>
```

- 窗口表解析:表头行以 `WindowName` 开头,列序 `WindowName DisplayId Pid WinId Type`,
  遇 `----`/`Focus window`/`total window` 结束;聚焦窗口来自尾部 `Focus window: <id>`;
  应用窗口 = `Type == 1`。
- **组件树的已知路线是 `uitest dumpLayout` 写设备端 JSON 文件,再 `file recv` 解析**,
  不是 `hidumper -s WindowManagerService -a "-w <id> -element -c"` 的 stdout。
  deveco 的 `-w` 是**可选**参数(按显示屏 dump 时只带 `-d`),所以"组件树必须先有
  windowId"这一诊断并不完整;真正的阻塞是**产物形态**:dumpLayout 产出设备文件,
  而 `capture.diagnostics@1` 的 `capture-ui-dump` 步骤 kind 是 `captureRemoteStdout`。
  换成这条路线需要 `captureRemoteFile` + `receiveFile` + `cleanupOwnedRemotePath`
  的步骤形态,即契约 + Catalog 变更(已发布 operation 的修改,走 OpenSpec)。
- 节点 `bounds` = `[left, top, right, bottom]`,中心点 `ceil((l+r)/2), ceil((t+b)/2)`。
- **只包含屏幕内可见节点**;视口外的节点 dump 不出来。
- UI 输入(如需):`uitest uiInput click|doubleClick|longClick|swipe|fling|drag|dircFling|inputText|text`;
  文本参数用 base64 过 shell:`"$(printf '%s' '<b64>' | base64 -d)"`。

## 8. 截屏 `[S]`(ArkDeck 尚无此 operation)

```text
hdc -t <k> shell snapshot_display [-i <displayId>] -f <remote.png> [-t png]
hdc -t <k> shell ls -l <remote.png>      # 用第 5 字段(size)判是否真的生成
hdc -t <k> file recv <remote.png> <local>
hdc -t <k> shell rm -f <remote.png>
```

- **成功判据是远端文件大小 > 0,不是退出码**;deveco 在不带 `-t` 失败后重试一次
  `-t png`,最后校验本地 PNG 魔数 `89 50 4E 47 0D 0A 1A 0A`。
- 注意 `-t` 的双重含义:`hdc -t <connectKey>` 与 `snapshot_display -t png` 不是
  同一个 `-t`,拼 argv 时不要复用常量。

## 9. Host 侧构建产物定位 `[S]`(HAP artifact lease 的上游)

- 工程根 = 向上找到含 `app` 段的 `build-profile.json5`。
- `bundleName` ← `AppScope/app.json5` 的 `app.bundleName`;
  原子化服务 = `app.bundleType === "atomicService"`。
- 模块类型 ← `<module>/src/main/module.json5` 的 `module.type`
  (`entry`/`feature`/`shared`/`har`);ability 取 `module.abilities[]`,优先
  `EntryAbility`,否则第一个。
- **产物不要 glob,读元数据:**

  ```text
  <module>/build/<product>/intermediates/{hap_metadata|hsp_metadata}/<target>/output_metadata.json
      → hapName / hspName + isSigned (+ dependRemoteHsps[])
  <module>/build/<product>/outputs/<target>/<该 name>
  ```

  `*-unsigned.hap` 存在时,同目录若有同名 `*-signed.hap` 则优先取签名件。
- 构建链:`ohpm install`(总是跑)→ `hvigor --sync`(配置未变可跳过)→
  `assembleHap|assembleHsp|assembleHar`:

  ```text
  node <hvigorw.js> assembleHap --mode module \
      -p module=<m1@target,m2@target> -p product=<name> -p buildMode=<debug|release> \
      --analyze=normal --parallel --incremental
  node <hvigorw.js> clean --analyze=normal --parallel --no-daemon
  node <hvigorw.js> --stop-daemon
  ```

  `--product` 不带 `--modules` = 整产品 `assembleApp`(产物 `.app`);依赖模块按
  `oh-package.json5` 的本地 `file:` 依赖递归收集,`har` 不进安装集。

## 10. 与 ArkDeck 现状的 delta 台账

状态列只有三种:`本车已落地` / `需契约或 Catalog 变更` / `待真机证据`。
"待真机证据"的条目**不得**先转成代码判定。

| # | ArkDeck 现状 | 外部事实 | 状态 |
| --- | --- | --- | --- |
| D3 | `param get` 结果直接 trim 后入 summary | 输出可能是 `key = value` | **本车已落地**(仅剥"请求键 + `=`"前缀) |
| D1 | `capture-ui-dump` = `captureRemoteStdout` + `windowInventory`;`componentTree` lowering fail closed | `uitest dumpLayout` 写设备文件 + `file recv` | **需契约或 Catalog 变更**(本车只把拒绝原因从"无 windowId-free 形态"更正为"stdout 步骤形态无法承载文件型产物",并指向本文件 §7) |
| D2 | `stopAbility` / `uninstallPackage` verify **仅**看 exit status 就判 `verified` | `aa`/`bm` 家族有短状态行可判;`bm uninstall` 有 `uninstall missing installed bundle` 这种"0 但没做" | **待真机证据**(`debug.hap@1` 在 stop/uninstall 之后没有 readback 步骤,直接改成 `.unknown` 会让每次运行都落 `reconcileRequired`;闭合路径二选一:设备窗口 pin 状态串,或加 readback 步骤=Catalog 变更) |
| D4 | `receiveOwnedArtifact` lower 为 `["file","recv",<remote>]`(**无本地目标**),且其 verify 要求 `receipt.hostManagedRecordID`,而 process 收据从不携带该字段 → 永远 `.unknown` | recv 本地目标语义不稳,必须按内容校验 | **需契约或 Catalog 变更**(接收腿需要 host 侧目标路径 + 大小/哈希校验;是 GJ-2「抓取 Trace」的真实阻塞,建议独立一车) |
| D5 | `bm install -p <单文件> -r` | 多包必须同目录 + 一条 `bm install -p <dir>` | 待真机证据(单 HAP 之外未覆盖) |
| D6 | retry 仅 `preflightAttempts: 2 / mutationAttempts: 1` | transient 串表 + 800/1500/2500 退避 | 待真机证据(transient 分类进判定前需 pin) |
| D7 | 无签名前置判断 | host 侧判 `-signed.*` 后缀 | 待真机证据(后缀是构建约定,只能当提示) |
| D8 | 无 screenshot operation | `snapshot_display` + size 判据 + PNG 魔数 | 需契约或 Catalog 变更(新 operation) |
| D9 | crash 采集形态未定(GJ-3 需要) | `hidumper -s 1201 -a "-p Faultlogger[ -f <file>]"` | 待真机证据 |

## 11. 明确不适用(不要抄进来)

- 模拟器全家(`emulator *`)与 `127.0.0.1:<port>` 目标假设:ArkDeck 目标是真机 DAYU200。
- 华为账号 / AGC 云证书 / `signature generate` / provision 配额:HarmonyOS 商用侧。
- `check compat`(arkanalyzer-apiscan)、`docs`、`skills`、MCP/LSP:与 ArkDeck 无关。
- `bm quickfix` / hqf 增量:依赖 DevEco ≥6.1.1 的 hvigor 任务,OH 3.2 侧不保证存在。
- deveco 的 hdc **输出解析器实现**:按 hdc 26 系写的,ArkDeck pin 3.2.0d/f;
  只借"要解析哪些字段",不借解析实现。
