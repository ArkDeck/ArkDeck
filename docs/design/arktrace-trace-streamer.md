# ArkDeck TraceStreamer 依赖、构建与发布规格

> Status：current（2026-08-24）
> Scope：ArkDeckKit 迁入的 Trace parser、App helper 与 `arktrace` 开发产物。
> 行为规格：[`arktrace-migration-spec.md`](./arktrace-migration-spec.md)。

## 1. 锁定身份

| 项 | 值 |
|---|---|
| Canonical upstream | `https://gitcode.com/openharmony/developtools_smartperf_host.git` |
| Upstream revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6` |
| TraceStreamer version | `4.3.7` |
| Binary architecture | Mach-O `arm64` |
| Unsigned binary SHA-256 | `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf` |
| Source lock | `Packages/ArkDeckKit/ThirdParty/TraceStreamer/source-lock.json` |
| Runtime manifest | `Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/manifest.json` |

`source-lock.json` 同时锁定 13 个源依赖和 GN/Ninja 两个构建工具的 URL、
byte count 与 SHA-256。`manifest.json` 是运行时许可：二进制、upstream revision、
third-party revisions、插件集和 build recipe 必须同时相等。文档中的表格不是第二个
信任根；代码以 manifest 和实际字节为准。

## 2. 调用契约

ArkDeck 生产调用等价于：

```text
trace_streamer <immutable-trace> -e <private-partial-database> -nm
```

- 输入可为 text trace 或 proto trace，格式由锁定 parser 探测；
- `-nm` / `--nometa` 必须传入，防止上游 `meta` 表把输入 / 输出绝对路径写入派生库；
- 退出码 0 不单独构成成功。ArkDeck 还验证 regular file、非空、SQLite
  `quick_check`、required schema、trace range、relationship 与索引版本；
- `<database>.ohos.ts` 只是有界诊断证据，不是 Ready marker；
- 只有 fsync 与全部验证通过后才原子 rename 为 Ready DB。

Parser adapter 始终把 source Trace 拷贝到 session-owned staging。CLI / reviewed helper
分发使用 `immutableSnapshot` 模式：helper 也复制到私有 staging，并对真正执行的快照计算
identity。App 使用 `signedBundleInPlace` 模式：只允许
`ArkDeck.app/Contents/MacOS/trace_streamer` 与同一 App 中固定的 manifest 布局，直接执行
已签名 helper，避免复制破坏嵌套代码身份；working directory、`TMPDIR`、输入与输出仍全部
位于 session-owned staging。两种模式都在执行前后复核 helper/manifest identity。
stdout、stderr 和 sidecar 均有 64 KiB 上限；取消使用 TERM → 500 ms grace → 已知同一
PID 的 KILL，最后显式 wait/reap。

Ready SQLite 的只读打开同样区分宿主边界。CLI 保持 `/dev/fd/<bound-descriptor>` 打开；
App Sandbox 不允许 SQLite 重新打开该 devfs 路径，因此 App 只对自身私有 Cache / Application
Support / temporary 根内的数据库使用路径打开。该分支先以 `O_NOFOLLOW` 绑定 regular-file
descriptor，再以 `SQLITE_OPEN_NOFOLLOW` 打开，随后比较完整 `lstat` identity；私有根外、
symlink 或打开期间身份变化全部 fail closed。

## 3. 锁定插件与许可

构建插件集精确为：

```text
hilog,hisysevent,arkts,bytrace,rawtrace,htrace,ffrt,memory,hidump,
cpudata,network,diskio,process,xpower
```

`hiperf`、`ebpf` 和 `native_hook` 不进入产品二进制，因此没有启用 GPL/LGPL-only
plugin。保守的 source-closure inventory 仍保留 build-only / disabled 依赖的告知，
避免日后开启插件时许可漂移无人发现。

权威资源：

- `Packages/ArkDeckKit/THIRD_PARTY_NOTICES.md`；
- `Packages/ArkDeckKit/ThirdParty/TraceStreamer/license-inventory.json`；
- `Packages/ArkDeckKit/ThirdParty/TraceStreamer/LICENSES/` 下 18 份 exact license / notice 文本；
- `Packages/ArkDeckKit/Resources/ArkTraceCLIResources/LICENSE` 中迁入 ArkTrace 代码的 MIT 许可。

## 4. 本地构建

支持环境是 Apple silicon macOS、Apple clang、Swift 6，并需要 `git`、`jq`、`curl`、
`shasum`、`tar`、`patch`、`perl`、`lipo` 和 `otool`。锁定的 x86 GN/Ninja 归档需要
Rosetta 2，但最终 parser 是原生 arm64。

```bash
Packages/ArkDeckKit/Scripts/build_trace_streamer.sh
Packages/ArkDeckKit/Scripts/verify_trace_streamer_lock.sh
```

构建脚本只在安全的 package-owned `.build/trace-streamer-workspaces/` 中拉取 exact
revision，先验证下载字节再解包，并对 local patch fail closed。默认产物是：

```text
Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/trace_streamer
Packages/ArkDeckKit/ThirdParty/TraceStreamer/macx/manifest.json
```

上游 `mac_depend.sh` 不得执行。它在现代 macOS 会尝试把 dyld shared cache 里的
libc++ 改写为不存在的相对路径。锁定脚本只接受已审阅的 post-link tail
failure，然后用可执行性、version、architecture 和 Mach-O load commands 证明产物。

## 5. App 发布布局

Xcode 使用三段明确 phase 构造嵌套 helper：

1. `Prepare Trace Streamer Helper` 从仓库 canonical binary 复制到 build-products staging，
   使用 identifier `com.arkdeck.desktop.trace-streamer`、hardened runtime 与
   `ArkDeckApp/TraceStreamerHelper.entitlements` 预签名；entitlements 只能包含
   `com.apple.security.app-sandbox=true` 与 `com.apple.security.inherit=true`；
2. `Embed Trace Streamer Helper` 是 Executables destination 的 Copy Files phase，并启用
   `CodeSignOnCopy`，把嵌套代码放入 `Contents/MacOS`；
3. `Copy Pinned Trace Runtime Resources` 只复制 manifest、MIT license、third-party notices
   与 exact license inventory，最后把 bundle manifest 的 `binarySHA256` 更新为最终已签名
   helper 的 SHA-256。

最终布局为：

```text
ArkDeck.app/Contents/MacOS/trace_streamer
ArkDeck.app/Contents/Resources/TraceStreamer/manifest.json
ArkDeck.app/Contents/Resources/ArkTrace/LICENSE
ArkDeck.app/Contents/Resources/ArkTrace/THIRD_PARTY_NOTICES.md
ArkDeck.app/Contents/Resources/ArkTrace/Licenses/*
```

`ArkDeckApp/TraceRuntimeResources.xcfilelist` 声明资源 phase 的 exact canonical inputs；
Copy Files phase 单独拥有 helper，避免同一嵌套代码被两个 phase 覆盖。App 只从上述
bundle-relative 路径解析，不搜索 `PATH`。Sandbox input/output list、实际 bundle inventory、
最终 manifest、helper bytes 与 nested-code validation 之间的任何差异都是发布失败。

仓库 `macx/manifest.json` 的 `binarySHA256` 继续锁定 unsigned canonical source bytes；
bundle manifest 锁定签名后的运行时 bytes。两者不应相等，也不能互相替代。发布验证必须
同时检查 canonical source lock、helper designated identifier、hardened-runtime flag、两项
inherit entitlements、bundle manifest SHA 与外层 App 的 deep/strict codesign。

## 6. SmartPerf palette 移植

`Packages/ArkDeckKit/Sources/ArkDeckTraceRendering/TimelineColorPalette.swift` 是唯一份从
SmartPerf Host *application code* 转写的源码。它保留 upstream hash / state 分配语义，
颜色使用 ArkDeck 已验证的可辨识 palette。行为对齐由
`ArkDeckTraceRenderingTests/TimelinePaletteTests.swift` 的 parity vectors 锁定，Apache-2.0 文本
与 parser 同车发布。

## 7. Re-pin 流程

1. 审阅 upstream 与 required table / CLI / plugin 差异；
2. 更新 `source-lock.json` 和必要的独立 local patch；
3. 在两个 fresh workspace 运行构建，只有二进制 byte-identical 才能更新 manifest；
4. 更新 version / SHA / recipe 证据和本文档的身份表；
5. 运行 lock verification、parser integration tests、全量 `ArkDeckTrace*` 测试与 App build；
6. 用真实 Trace 复核 required schema、range、capabilities、cache key 失效和 Viewer 打开。

不得用浮动 tip、仅 version string、仅签名或 CI 下载成功代替 exact bytes 审查。

## 8. 常见故障

| 现象 | 安全解释 / 处理 |
|---|---|
| App build 提示 helper 缺失 | 运行 §4 构建脚本；不从 `PATH` 复制另一份 binary |
| lock verification 报 recipe drift | 脚本 / lock / patch 改变后必须真实重建并审阅 manifest，不手改绕过 |
| parser 退出 0 但 DB 不可用 | 按失败处理；检查 sidecar 有界摘要、schema / range / quick check |
| bare `arktrace licenses` 失败 | SwiftPM 裸产物不是完整发布；许可命令要求 reviewed resource layout |
| identity drift | 停止解析；恢复 exact reviewed bytes 或完成 §7 re-pin，绝不 fallback |
| App 在 `--version` 前失败 | 检查 helper 是否在 `Contents/MacOS`、是否由 Copy Files + CodeSignOnCopy 嵌入，以及 sandbox/inherit entitlements 是否精确 |
| App 长期停在 `Opening database…` | 采样确认是否在 `/dev/fd`；App 只能从私有缓存路径按 §2 的三段 identity 校验打开，不能降低为任意路径 fallback |
