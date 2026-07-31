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
   | `bm uninstall -n …` | 成功 `uninstall bundle successfully.`;**未安装** deveco 记为 `uninstall missing installed bundle`,但 **OH 3.2 DAYU200 实测 `[R]` 是 `error: failed to uninstall bundle.` + `code:9568386`** —— 串不通用,别按串判 |
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
  ArkDeck 的做法(D4):**本地文件名取远端 basename**,使"目录形"与"文件形"
  落到同一路径,再由 dispatcher 实测该路径的大小与 SHA-256;测不到就是
  `.unknown`,不是失败。
  **该策略已在 hdc 3.2.0f 真机确认 `[R]`**(2026-07-31 窗口,12,456 字节 htrace
  按声明路径落地并通过散列);其他 hdc 版本仍未测。
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
  **两种形态都已真机确认 `[R]`**(2026-07-31):`bm install -p <dir>` 与
  `bm install -p <file> -r` 都回 `install bundle successfully.`,单 HAP 用现形态没错;
  多包的阻塞在 `debug.hap@1` 只收一个 `hapArtifactLease`(input 面,见 D5)。
- `pidof` 可能返回多个空格分隔 PID;进程名等于 bundleName 只对主进程成立。
- **`hdc shell` 只回客户端退出码,远端命令的退出码不过桥 `[R]`**(2026-07-31 实测):

  ```text
  pidof <running>   -> exit 0, "443"
  pidof <stopped>   -> exit 0, ""
  pidof <nonsense>  -> exit 0, ""
  bm dump -n <missing>            -> exit 0, "error: failed to get information..."
  bm uninstall -n <not installed> -> exit 0, "error: failed to uninstall bundle." + "code:9568386"
  ```

  → 任何"用远端退出码判成败"的写法在这条传输上都是死代码。判据只能来自 stdout
  内容:`pidof` 的**空输出**即不在,`bm dump` 的输出**是否含 bundle 名**即在否。
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
- **组件树的路线是 `uitest dumpLayout` 写设备端 JSON 文件,再 `file recv` 解析** `[R]`。
  2026-07-31 DAYU200 实测:`uitest` 在 `/bin/uitest`,`dumpLayout -p <file>`
  **不带 `-w`、不带 `-d`** 即成功,回 `DumpLayout saved to:<path>`。
  即"组件树必须先有 windowId"这一诊断**是错的**——CHG-2026-053 r1 据此拒绝,
  r2 予以更正。真正的阻塞有两层:(a) 产物是设备文件而 `capture-ui-dump` 的 kind
  是 `captureRemoteStdout`;(b) 更关键的是该步骤声明 `effect: readOnly`,而**往设备
  写文件是 deviceMutation**——第二层不是 lowering 能藏的,藏了就等于绕过副作用授权。
  已由 CHG-2026-053 r2 以新增步骤 + `uiComponentTree` 输入的形态交付。
- 节点 `bounds` = `[left, top, right, bottom]`,中心点 `ceil((l+r)/2), ceil((t+b)/2)`。
- **只包含屏幕内可见节点**;视口外的节点 dump 不出来。
- UI 输入(如需):`uitest uiInput click|doubleClick|longClick|swipe|fling|drag|dircFling|inputText|text`;
  文本参数用 base64 过 shell:`"$(printf '%s' '<b64>' | base64 -d)"`。

## 8. 截屏 `[S]`(ArkDeck 尚无此 operation)

```text
hdc -t <k> shell snapshot_display -t png -f <remote.png>   # -t png 必需,见下
hdc -t <k> shell ls -l <remote.png>      # 用第 5 字段(size)判是否真的生成
hdc -t <k> file recv <remote.png> <local>
hdc -t <k> shell rm -f <remote.png>
```

- **`-t png` 是必需的,不是"失败后重试"** `[R]`(2026-07-31 实测,更正原 `[S]` 行):

  ```text
  usage: snapshot_display [-i displayId] [-f output_file] [-w width] [-h height] [-t type] [-m]
  -f <x>.png          -> error: fileName … invalid, suffix must be .jpeg
  -f <x>.jpeg         -> file type: jpeg,   40,941 B
  -t png -f <x>.png   -> file type: png,   449,830 B,魔数 89 50 4E 47 0D 0A 1A 0A
  ```

  该 build **默认类型是 jpeg,且按文件名后缀校验类型**。deveco"先不带 `-t` 再重试"
  是这条规则的症状,不是可选项;照原文写 lowering 第一次下发就会被拒。
  → provider 铸的 owned path 后缀因此是判据的一部分。
- PNG 450KB vs JPEG 41KB(同一屏,11 倍)。ArkDeck 只交付 PNG(无损 + 魔数可校验);
  JPEG 与 `-w/-h` 缩放待有真实预算压力再议。`-m` 语义未探,不猜。

- **成功判据是远端文件大小 > 0,不是退出码**;deveco 在不带 `-t` 失败后重试一次
  `-t png`,最后校验本地 PNG 魔数 `89 50 4E 47 0D 0A 1A 0A`。
  ArkDeck 把这条"`ls -l` 第 5 字段判产物"复用到了 trace 腿(D10):`hitrace` 之后
  紧跟一条 `ls -l`,由 listing 判 verified/failed/unknown。
- **列序已真机确认 `[R]`**(2026-07-31,DAYU200 / toybox 0.8.12):

  ```text
  drwxr-xr-x 2 shell shell 3452 2017-08-06 18:53 debugserver
  mode       links user  group size date       time  name
  ```

  即 size = 第 5 字段,首字符区分常规文件/目录。注意 `ls -l <目录>` 会先打一行
  `total N`,解析器因此只对**文件路径**使用(`total` 不以 `-` 开头,会落 unknown)。
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

## 9.1 hitrace tag 表 `[R]`

`traceCategories` 的取值必须来自设备侧 `hitrace --list_categories`,**不要照抄
仓内 fixture**。2026-07-31 DAYU200(OH 3.2)实测:`ability`、`app`、`ace`、
`ark`、`animation`、`binder`、`disk`、`graphic` 等存在;**`ohos` 不存在**。

`ohos` 曾是 provider lowering 里 `traceCategories` 缺省值,该缺省已删除(缺省
只会产出设备拒绝的命令);现在无 category 即 fail closed。仓内测试与
`TracePresetCatalog.logicalTags` 仍带 `ohos` —— 前者是 fixture,后者当前无消费
方,两者都不产生设备命令,但**不可**被当作 tag 存在的依据。

## 10. 与 ArkDeck 现状的 delta 台账

状态列只有三种:`本车已落地` / `需契约或 Catalog 变更` / `待真机证据`。
"待真机证据"的条目**不得**先转成代码判定。

| # | ArkDeck 现状 | 外部事实 | 状态 |
| --- | --- | --- | --- |
| D3 | `param get` 结果直接 trim 后入 summary | 输出可能是 `key = value` | **本车已落地**(仅剥"请求键 + `=`"前缀) |
| D1 | `capture-ui-dump` = `captureRemoteStdout` + `windowInventory`;`componentTree` lowering fail closed | `uitest dumpLayout` 写设备文件 + `file recv` | **已落地并真机验证 `[R]`**(CHG-2026-053 r2:新增 `uiComponentTree` 输入与 `capture-ui-tree` / `receive-ui-tree` / `cleanup-ui-tree-temp` 三个 optional 步骤,effect 随输入升级;2026-07-31 真机一次跑通,`ui-tree.json` 26,143 字节 / 42 节点。**注意**:该产物是含屏幕文本的 JSON,走会脱敏的 `publish`,**不**走 D4 给 trace 铺的 file-backed 路径) |
| D2 | `stopAbility` / `uninstallPackage` verify **仅**看 exit status 就判 `verified` | `aa`/`bm` 家族有短状态行可判;`bm uninstall` 有 `uninstall missing installed bundle` 这种"0 但没做" | **本车已落地**(两条 mutation 各自降为「mutation + presence readback」序列:stop 后 `pidof`、uninstall 后 `bm dump -n`,判据取 readback 三值——不在=verified、还在=`stopIneffective`/`uninstallIneffective` failed、读不出=unknown;**没有**去解析 `aa`/`bm` 的状态串,所以不占用"待真机证据"的额度。probe 解析与 reconcile 路径共用同一份 helper。**2026-07-31 真机修正**:首版 `processPresence` 要求 `exitStatus == 1` 才判进程不在,而 `hdc shell` 只回客户端退出码,该 shape 生产上永不出现 —— 每次成功的 stop 都落 `.unknown`。已改为按**空输出**判不在、完全不看退出码,并经真机 reconcile 复验) |
| D4 | `receiveOwnedArtifact` lower 为 `["file","recv",<remote>]`(**无本地目标**),且其 verify 要求 `receipt.hostManagedRecordID`,而 process 收据从不携带该字段 → 永远 `.unknown` | recv 本地目标语义不稳,必须按内容校验 | **本车已落地**(argv 补 host 目标;dispatcher 按 `HostLandingExpectation` 实测落地文件的大小与 SHA-256;verdict 全部来自磁盘字节:无文件=`.unknown`、空=`.failed`、超预算=`.failed` 且不做哈希、pin 了哈希则真比对;`trace.htrace` 改从收到的文件发布,不再用 `receipt.stdout`) |
| D10 | trace 腿在 `validateSupportedPlanInputs` 处按 `traceCategories` 整体拒绝(admission 前) | `hitrace -o <file>` 的产物存在性/大小只能由设备侧 `ls -l` 第 5 字段判(同 §8) | **本车已落地**(`capture-trace` 降为 `hitrace` + `ls -l` 两段序列,判据取 listing 的 size 字段而非退出码:>0 verified、=0 `emptyTrace` failed、非常规文件/读不出 unknown;admission 拒绝解除,trace 腿改由 E1 授权路径管辖)|
| D11 | trace 腿现在会真下发,但从未在真机上跑过;`ls -l` 字段序与 `file recv` 落地形态都只有 `[S]` 来源 | deveco 的 `ls -l` 第 5 字段判据取自截屏路径(§8),不是 hitrace 路径 | **已真机确认**(2026-07-31 窗口:DAYU200 / hdc 3.2.0f / toybox 0.8.12,`capture.diagnostics@1` 带 `traceCategories` 一次跑通,`trace.htrace` 12,456 字节且首字节为 `# tracer: nop`;两项来源均由 `[S]` 升为 `[R]`。证据:`evidence/runs/TASK-DHA-001/trace-leg-window-2026-07-31.md`) |
| D12 | `cleanup-uninstall` 失败后 job 仍记 `succeeded`,且**不记债务** —— 债务的门是 `step.kind == .cleanupOwnedRemotePath`、键是 `remotePath`,装着的 bundle 无处可记 | — | **本车已落地**(CHG-2026-049 r3:债务身份推广为 residue = 远端路径 **或** 装着的 bundle;记录门改为"这一步要移除什么",正向与补偿两条路径同等;`succeeded` 附带 `outstandingResidueCount`,不新增终态;结清仍由 readback 判定。**原诊断"要动 step optional 语义"是错的** —— 可选性是 `cleanupPolicy: keep` 需要的,真正的不对称在键上)|
| D5 | `bm install -p <单文件> -r`;`hapArtifactLease` 是标量,引擎与 context 都只解析一条 | 多包必须同目录 + 一条 `bm install -p <dir>` | **已落地并真机验证 `[R]`**(CHG-2026-049 r4:可选 `additionalHapArtifactLeases` + schema 数组型 + `[mkdir -p, send ×N]` / `bm install -p <dir> -r` / `[rm -f ×N, rmdir]` 的目录形 lowering;**不用 `rm -rf`**,沿用 native 族形态。2026-07-31 真机:entry + feature1 一次装成,设备读回 `installed modules: ['entry', 'feature1']`。附加租约在 admission 阶段逐条过绑定校验,不符即零 dispatch)|
| D6 | retry 仅 `preflightAttempts: 2 / mutationAttempts: 1` | transient 串表 + 800/1500/2500 退避 | 待真机证据(transient 分类进判定前需 pin) |
| D7 | 无签名前置判断 | host 侧判 `-signed.*` 后缀 | 待真机证据(后缀是构建约定,只能当提示) |
| D8 | 无 screenshot operation | `snapshot_display` + size 判据 + PNG 魔数 | **已落地并真机验证 `[R]`**(CHG-2026-049 r5:`uiScreenshot` 输入 + 三条 optional 腿,**不新增 operation**;lowering 用 `-t png`(必需)+ `.png` owned 后缀;三层判定 = 设备侧 size / host 侧 size+SHA-256 / PNG 魔数,魔数不符不发布。2026-07-31 真机:449,756 字节、720×1280、魔数正确)|
| D9 | crash 采集形态未定(GJ-3 需要) | `hidumper -s 1201 -a "-p Faultlogger[ -f <file>]"` | 待真机证据(**命令形与空态输出已 pin `[R]`**:service 1201 = HiviewService,无崩溃时回 `No fault log exist.` 与 `******` 空列表;缺口收窄为需要一次真实崩溃才能 pin 条目格式与 `-f <file>` 形态 —— GJ-3 会自然产生,不必造崩溃) |

## 11. 明确不适用(不要抄进来)

- 模拟器全家(`emulator *`)与 `127.0.0.1:<port>` 目标假设:ArkDeck 目标是真机 DAYU200。
- 华为账号 / AGC 云证书 / `signature generate` / provision 配额:HarmonyOS 商用侧。
- `check compat`(arkanalyzer-apiscan)、`docs`、`skills`、MCP/LSP:与 ArkDeck 无关。
- `bm quickfix` / hqf 增量:依赖 DevEco ≥6.1.1 的 hvigor 任务,OH 3.2 侧不保证存在。
- deveco 的 hdc **输出解析器实现**:按 hdc 26 系写的,ArkDeck pin 3.2.0d/f;
  只借"要解析哪些字段",不借解析实现。
