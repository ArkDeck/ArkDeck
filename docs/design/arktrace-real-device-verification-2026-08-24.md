# ArkTrace 迁移真机验证记录（2026-08-24）

> Task：`TASK-AIN-021`
> 结论：`REAL_DEVICE_PASS`
> 数据等级：Trace Artifact 为 sensitive，本记录只保存脱敏身份与验证摘要，不提交原始 trace。

## 1. 验证边界

本次使用当前 Catalog 的 `capture.diagnostics@1`，完成了同一 Artifact 的四段闭环：

```text
OpenHarmony 真机
  → ArkDeck Runtime typed capture
  → published trace.htrace + byte/SHA 校验与显式导出
  → ArkDeckKit arktrace inspect/summary
  → ArkDeck App Trace Viewer 时间线
```

| 项 | 结果 |
|---|---|
| UTC 窗口 | `2026-08-23T19:54:38Z` ～ `2026-08-23T19:54:53Z` |
| Host | Apple silicon macOS `26.6.2` |
| Agent protocol | `1.0.0`，health `ok` |
| Catalog digest | `be7b73616a7b1786f66408056b3a0d4daf811be46368344c2c3da7e3b88715c7` |
| Operation / effect | `capture.diagnostics@1` / `deviceMutation` |
| Target | `sha256:0c1ffd246293`（脱敏 alias），binding revision `4`，OpenHarmony `7.0.0.37`，USB |
| 输入 | `10 s`、`8192 KB`、tags `sched,freq,ace,app`；hilog/crash/UI legs 均关闭 |

## 2. Runtime receipt 与 Artifact

| 项 | 结果 |
|---|---|
| Job | `job-ce954bc07cee6f05583812ee6118dcc4` |
| Terminal | `succeeded`；`outcomeUnknown=false`；`waitingForHuman=false` |
| Cleanup | `outstandingResidueCount=0`；全局 cleanup-debt 列表为空 |
| Artifact | `ART-04bd16a421b93c4912edc2c028153b12` / `trace.htrace` |
| 准入事实 | `published`、`raw`、`sensitive`、`application/octet-stream` |
| Byte count | `2,166,739` |
| SHA-256 | `7ee52dab14917a24fd1f944ebeccbbefdc086e8305d5ccf328c613697513a7cf` |

Runtime timeline 包含 `intent capture-trace`、远端 byte count 验证、
`receive-trace-artifact` 的 byte count / local artifact / SHA 验证、远端临时文件 cleanup，
之后才进入 finalizing 与 succeeded。导出文件再次以 `shasum -a 256` 得到相同 SHA，且
本地 byte count 与 Artifact receipt 相等。

## 3. ArkDeckKit parser / CLI

| 项 | 结果 |
|---|---|
| CLI | `arktrace 0.1.0`，build revision `3f835f0e2cfd0d0ef34eafc075d5977f6d978ac58216191b54cf91f583539724` |
| Parser | `trace_streamer 4.3.7` |
| Canonical parser SHA | `e0167fbb13bf666dd589c7b27d697683bec2762ec66cefc935139e6da49ecbbf` |
| Upstream revision | `447a0a49a7b3b914d6e9bd00648ba5a340f6fbf6` |
| Build recipe | `e71c02d139868e4a350740824435d8cd81d0ed840414b12aca3cec9d4e87103e` |
| Schema | adapter `2`，index `3`，fingerprint `cb34d8b668c21d9a5f50949338e0f4777fcd113f1ecfac4446afcb6ddf25bfc3` |
| Range | `0...10,016,842,000 ns` |
| Capabilities | CPU scheduling、thread states、named slices |

`inspect --json` 与 `summary --json` 均退出 `0`。summary 返回：4 CPUs、8,317 CPU
slices、10,000 bounded thread states、126 named slices、68 processes、213 threads，以及
13,107 trace-source events。`threadStateCount` 达到请求的 10,000 上限，因此结果如实标记
truncation；416 个未知 `stat_type` 值与 bounded relationship probes 作为 data-quality
warning 保留，没有被伪装成完整数据。

## 4. App Viewer 与发布签名

同一导出文件由刚构建并重启的 `ArkDeck.app` 打开。Accessibility tree 与屏幕结果同时
确认：Timeline viewport 为 `0 ns...10.017 s`、94 条 visible tracks，Sidebar 包含 CPUs、
CPU Counters 与真实进程/线程组；Inspector 显示 `10.017 s`、`2.2 MB`、schema
`cb34d8b668c2` 与 cache miss。App 没有调用 PATH helper，也没有复制已签名 helper 后执行。

发布检查结果：

- helper：`ArkDeck.app/Contents/MacOS/trace_streamer`；
- designated identifier：`com.arkdeck.desktop.trace-streamer`；
- flags：`adhoc,runtime`；entitlements 仅 `app-sandbox=true` 与 `inherit=true`；
- 签名后 helper SHA：`4d3228cb47817fbf0472990e38af583584adee092af7d08c6f1f22d498189b94`；
- bundle manifest 的 `binarySHA256` 与上述签名后 SHA 相等；
- canonical source SHA 仍为 §3 的 `e016…fbbf`；App deep/strict codesign 验证通过。

App Sandbox 下，SQLite 不再尝试重新打开 `/dev/fd`。只读数据库必须位于 App 私有存储，
并经过 `O_NOFOLLOW` descriptor preflight、`SQLITE_OPEN_NOFOLLOW` 与 post-open 完整 identity
比较；该路径最终加载同一真机数据库并生成 Timeline。

## 5. 脱敏命令与退出码

以下是本次命令形状；`<target-alias>`、`<inputs.json>`、`<export-dir>` 与本机绝对路径已编辑：

```text
arkdeck agent run --operation capture.diagnostics@1 \
  --target <target-alias> --inputs-file <inputs.json> --json                 # 0
arkdeck job status --job job-ce954bc07cee6f05583812ee6118dcc4 --json        # 0
arkdeck artifact list --job job-ce954bc07cee6f05583812ee6118dcc4 \
  --allow-sensitive --json                                                   # 0
arkdeck artifact export --job job-ce954bc07cee6f05583812ee6118dcc4 \
  --artifact ART-04bd16a421b93c4912edc2c028153b12 \
  --destination <export-dir> --allow-sensitive --json                        # 0
arktrace --json --trace-streamer <canonical-helper> inspect <trace.htrace>   # 0
arktrace --json --trace-streamer <canonical-helper> summary <trace.htrace>   # 0
```

未公开字段包括完整 Runtime target ID、transport connect key、用户目录与 daemon/socket
绝对路径。Job / Artifact ID、Catalog digest、公开 parser provenance、byte count 与 SHA-256
按验收规格保留。原始 `trace.htrace` 仅留在本机显式导出位置，不进入 Git。
