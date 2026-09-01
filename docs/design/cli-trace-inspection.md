# Trace offline inspection CLI

`arkdeck trace inspect` 对已发布的原始 Trace Artifact 做确定性本地解析。它不采集设备、
不提交 Job，也不把派生结果登记成新的 evidence。采集仍由
`arkdeck agent run --operation capture.diagnostics@1` 的 typed trace preset 完成。

## 命令

```text
arkdeck trace inspect \
  --job <job-id> \
  --artifact <artifact-id> \
  --allow-sensitive \
  [--timeout 2m] \
  [--require-protocol 2] \
  [--output json]
```

`--allow-sensitive` 必须显式提供。`--timeout` 是 Runtime parser 的执行预算，默认 `2m`，
范围为 `1ms...10m`；CLI transport 只增加 5 秒用于接收 Runtime 的取消/清理结果。

请求只包含 versioned owner、Artifact ID、敏感内容 opt-in 和毫秒预算：

```json
{
  "owner": {"kind": "job", "id": "job-..."},
  "artifactId": "ART-...",
  "allowSensitive": true,
  "timeoutMs": 120000
}
```

没有 raw host path、parser path、executable、argv、cache root 或 device selector。

## Runtime owner

`trace.inspect` 只接受 control protocol v2。Runtime 在调用 parser 前依次证明：

1. Job record 存在且可读；
2. Artifact 属于该 Job，并且状态为 `published`；
3. `sourceOperation == capture.diagnostics@1`；
4. name 为 `trace.htrace`，media type 为 `application/octet-stream`；
5. privacy 为 `sensitive` 且未标记 redaction；
6. lease 的 Artifact ID、SHA-256、byte count 与 binding snapshot 和 metadata 完全一致；
7. 以 `VerifiedRegularFileDescriptor` 打开并校验源文件，只把持有期间的 inode path 交给
   固定 parser owner；解析后再次校验 descriptor identity。

生产 parser 由 `trace-summary@1` AnalyzerProfile 固定。ArkDeck 使用 ArkTrace protected-main
commit `e98a753ef61f616c8f95693cc4c4201c6b1e3393` 的
`TraceOfflineInspectionService`，parser executable 与 manifest 来自同一可信 distribution bundle。
ArkTrace session 固定为 `ephemeral`，不读写共享 derived cache。

## Machine result

成功结果的 schema 是 `arkdeck.trace-inspection/1`。closed decoder 同时在 daemon 返回前和 CLI
输出前校验完整 shape：

- exact owner、Artifact ID、digest、byte count 与四个 typed metadata；
- ArkTrace version/build/source revision；
- parser name/version/upstream revision/binary SHA-256/adapter/build recipe；
- schema fingerprint、adapter/index version 与 upstream database identity；
- duration、closed capability set；
- closed、排序且无重复的 data-quality category/scope/count；
- `storageMode: "ephemeral"`；
- `deviceEvidenceCreated: false`。

结果不含 source、bundle、parser、database、cache 或 staging path，也不含 parser 的自由文本消息。

## Failures

所有 owner failures 都带 `phase: traceInspectionOwner`、`newDispatchCount: 0` 和
`deviceEvidenceCreated: false`。CLI 只在这些结构化事实存在时保留以下精确 code：

- `invalidInput`
- `operationUnavailable`
- `resourceNotFound`
- `artifactIntegrityFailed`
- `recordUnreadable`
- `operationFailed`

连接失败、超时或 malformed response 仍按 CLI 全局 failure mapping 处理。解析超时会先取消并
drain parser task，再返回 `operationFailed`；不会把未知 parser 状态报告成成功。

## Acceptance

合入 protected `main` 后，真实设备验收按以下顺序执行：

1. 用 `arkdeck agent run` 提交 `capture.diagnostics@1` 的 trace preset；
2. 从同一 Job 的 `artifact list` 取得 `trace.htrace` 的 exact Artifact ID；
3. 运行 `arkdeck trace inspect --job ... --artifact ... --allow-sensitive --output json`；
4. 核对 source digest/byte count 等于 Artifact metadata，parser/schema provenance 完整，
   `storageMode == ephemeral` 且 `deviceEvidenceCreated == false`；
5. 再读 Job evidence/timeline，确认 inspect 没有增加 device dispatch 或 evidence。

fixture、simulation 或 plan-only 结果只能验证 host contract，不能记为 `REAL_DEVICE_PASS`。
