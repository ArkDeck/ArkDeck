# TASK-DHA-001 设备窗口 — trace 腿真机首跑(2026-07-31)

## 结论

- Runtime observable result:**SUCCEEDED**
- 覆盖面:`capture.diagnostics@1` **带 `traceCategories`**,即 7-30 两条
  Golden Journey 未覆盖的那一段(当时 remote Trace 仍 production unavailable)
- Evidence classification:真实 DAYU200 runtime transcript。**不**声称任何
  `realHardware` AC 的 PASS —— 与 attempt#2 同一条理由:hardware-evidence
  contract 仍无法编码 Agent executor,本记录不把 runtime success 冒充 AC PASS
- 人工 HDC 命令:执行段 **0**(设备早已受信;输入准备与本记录的两条只读
  `ls -l` / `hitrace --list_categories` 属诊断,不计入执行证据)

## 执行

| 项 | 值 |
| --- | --- |
| 代码 | `main` @ `545dbcc8`(含 #857 D4 / #860 D10 / #861 D2)+ 本 PR 的缺省 category 修复 |
| hdc | 3.2.0f(DevEco SDK 内置) |
| 设备 | DAYU200,connect key `1501…4900`,stable identity `958780b2ffb7…` |
| Target | `TGT-958780b2ffb7`,binding revision 1 |
| Catalog digest | `1ee1c1a68486f45f8406fd362770655eb9d5dc983e1da27a87235d95eeb01a94` |
| 入口 | `arkdeck agent run --operation capture.diagnostics@1`(executor=agent) |
| Inputs | `durationSeconds: 5`、`traceCategories: ["ability", "app"]`、`traceBufferKB: 8192`、`uiDump: true` |
| Job(run#1,修复前) | `job-ec013badcb73eab6aa2f3254777b7e68`,`succeeded` |
| Job(run#2,修复后=本 PR 代码) | `job-2ca5fe049b3ac8e5a7b3af52a9537f0b`,`succeeded`,`outcomeUnknown: false`,`humanActions: []`,`actualEffect: E1` |

`traceCategories` 取值经设备侧 `hitrace --list_categories` 确认存在。
**仓内测试长期使用的 `ohos` 不在该设备的 tag 表里** —— 它是 fixture 值,
不是设备事实;真机输入不要照抄。

## 产物

| Artifact | 状态 | 字节 |
| --- | --- | --- |
| `hilog.txt` | published | 868,895 / 882,549 |
| `trace.htrace` | published | **12,456 / 18,258** |
| `ui-dump.json` | published | 1,691 / 1,691 |
| `artifact-index.json` | published | 632 / 632 |
| `capture-summary.json` | published | 693 / 693 |

(两列为 run#1 / run#2。两次 `capture-trace`、`receive-trace-artifact`、
`cleanup-remote-temp` 判定完全一致;trace 与 hilog 字节数不同是设备活动不同,
不是判定差异。)

`capture-summary.json` 记 `completeness: complete`、`missingRequired: []`。
`trace.htrace` 前若干字节解码为 `# tracer: nop\n#\n# entries-in-...`,是真实
ftrace/htrace 头 —— **不是** `FileTransfer finish` 横幅(D4 修的正是这一点)。

## 逐步判定

| Step | 判定 | summary 键 |
| --- | --- | --- |
| `capture-trace` | verified | `remoteByteCount` |
| `receive-trace-artifact` | verified | `byteCount` / `localArtifact` / `sha256` |
| `cleanup-remote-temp` | verified | `cleaned` |

清理复查:设备 `/data/local/tmp/` 无 `arkdeck-*` 残留;host staging
(`$TMPDIR/arkdeck-receive`)在发布后已删除。

## D11 的两项未 pin 项:本窗口关闭

1. **`ls -l` 列序**(此前只有 deveco 截屏路径的 `[S]` 来源)。设备为
   toybox 0.8.12,实测一行:

   ```text
   drwxr-xr-x 2 shell shell 3452 2017-08-06 18:53 debugserver
   ```

   列序 `mode links user group size date time name` —— **第 5 字段是 size**,
   与实现读的 `fields[4]` 一致;`fields[0]` 首字符区分常规文件/目录也成立。
   `capture-trace` 判 verified 并带出 `remoteByteCount`,说明该解析在真机上
   走通(解析失败时代码返回 `.unknown` 且无此键)。

2. **`file recv` 的落地形态**。实现采用"本地文件名 = 远端 basename",使
   目录形与文件形落到同一路径。`receive-trace-artifact` 判 verified 并带出
   `byteCount`/`sha256`,说明文件确实落在声明的目标路径且被完整散列 ——
   在 hdc 3.2.0f 上该策略成立。

## 授权面(需要维护者知情)

本次 E1 授权来自**运行时自动策略**,不是维护者签发的 capability:

```text
kind: runtimeCapability
reference: CAP-RT-POLICY-F880F9DC9ED4479832AB5EA26BA4D5F4B8887682-G1
validUntil: 2026-08-30T02:43:20Z
```

这是 #860 解除 admission 拒绝后的既有产品策略(`defaultPolicyIssuance`
在 `capture.diagnostics` 上是 enabled,与 `debug.hap@1` 同路径),不是本窗口
新增的东西。若不希望 trace 走自动签发,需要改 Catalog —— 属另一车。

## 本记录**不**证明的事

- 不证明任何 `DHA-HW-*` AC 通过(见上"Evidence classification");
- 不证明 `hitrace` 在其他 tag 组合/更长时长/更大 buffer 下同样成立;
- 不证明 `file recv` 在其他 hdc 版本上的落地形态(只测了 3.2.0f);
- 不覆盖 `debug.hap@1` 的 stop/uninstall readback(D2)—— 本窗口只跑
  `capture.diagnostics@1`,那两条的真机复验仍未做。
