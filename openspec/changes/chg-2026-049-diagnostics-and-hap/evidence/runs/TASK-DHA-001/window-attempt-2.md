# TASK-DHA-001 设备窗口 attempt#2（2026-07-29）

## 结论

- Runtime observable result:**SUCCEEDED**
- Formal `DHA-HW-001` acceptance result:**BLOCKED / NOT CLAIMED**
- Evidence classification:真实 DAYU200 runtime transcript，**不是**
  schema-valid `realHardware` acceptance evidence
- `DHA-HW-002`:**NOT RUN**

Agent 严格执行了维护者批准的一次 E0 window；operation、artifact 与 receipt
行为满足 DHA-HW-001 的 change-local 可观察判据。但准备正式 evidence 时发现
当前 authoritative hardware-evidence V2 contract 无法编码 Agent executor，
且本 receipt 不具备该 contract 必填的 firmware 与 target-confirmation 时间。
按 evidence-not-task-completion 与 authority-conflict stop condition，本记录
不把 runtime success 冒充为 AC PASS。

## D2 执行门

| 项 | Read-back |
| --- | --- |
| Window PR | #792，`lvye` APPROVED exact head `e244d67476cba0e6db29415e6a04ce9e7978b94f` |
| Window merge OID | `487b4c0ecefd37461c2b83aa9e2f32e90e26fdf9` |
| Runtime HEAD | exact `487b4c0ecefd37461c2b83aa9e2f32e90e26fdf9`，detached，clean |
| Window validity | 执行于 `2026-07-29T11:55:58Z`，早于 `2026-07-30T12:00:00Z` |
| Attempt budget | 一次；实际 `arkdeck agent run` 调用数 = 1 |
| Inputs | `{"durationSeconds":5}`；SHA-256 `277918e3016edb145aaee46cb33ee1f0d4a31a70a9a2d160e5d5128ed61585ba` |
| Closed-key check | keys 恰为 `durationSeconds`；`traceCategories` absent |
| Authority | `default-read-only-policy`；无 capability |

## 环境

| 项 | 值 |
| --- | --- |
| Device | DAYU200(RK3568),USB |
| Durable target | `TGT-958780b2ffb7`（稳定身份 digest 前 12 位） |
| Binding revision | `1` |
| HDC | `Ver: 3.2.0f` |
| HDC SHA-256 | `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| `arkdeck` SHA-256 | `25d89d494763a5dc33e3f3aa3f7047114b50316c590b7b453bcc894bf0581ed7` |
| `arkdeck-agentd` SHA-256 | `1c4db85bda5fe6e6866d9c8393e554d098ce4863a9da234d456759c9641c46c1` |
| State dir | `/private/tmp/adw4`,mode `0700` |
| Catalog digest | `a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717` |

两个 binary 从 exact runtime HEAD 分别重建成功。typed `doctor` 返回：
provider `hdc`、bootstrap/targetStore `ready`、adopted target count `1`。

## 唯一一次 Agent run

```text
<BIN>/arkdeck agent run --socket /private/tmp/adw4/agentd.sock \
  --operation capture.diagnostics@1 \
  --inputs-file <REVIEWED-DHA-HW-001-INPUTS> --json
```

脱敏 receipt：

```json
{
  "artifacts": [
    "ART-311000a55a7f5ab1",
    "ART-8d3a40b4af1a539d",
    "ART-MISSING-trace.htrace",
    "ART-83cbedc187b4c027",
    "ART-a7b54c62105a994c"
  ],
  "authorityReference": "default-read-only-policy",
  "bindingRevision": 1,
  "catalogDigest": "a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717",
  "executor": "agent",
  "finishedAtUTC": "2026-07-29T11:56:01Z",
  "humanActions": [],
  "jobID": "job-3db66f2d-f0c0-47c1-8d8a-91d82dd7975d",
  "operationReference": "capture.diagnostics@1",
  "startedAtUTC": "2026-07-29T11:55:58Z",
  "targetID": "TGT-958780b2ffb7",
  "terminalState": "succeeded"
}
```

## Job timeline

`job.status` 返回 `state=succeeded`、`outcomeUnknown=false`、
`waitingForHuman=false`。timeline：

```text
jobCreated
queued->preflight
preflight->running
host-step preflight-host-storage
intent preflight-device-storage
verified preflight-device-storage ["value"]
intent capture-hilog
verified capture-hilog ["byteCount"]
artifact hilog.txt -> ART-311000a55a7f5ab1
intent capture-ui-dump
verified capture-ui-dump ["byteCount"]
artifact ui-dump.json -> ART-8d3a40b4af1a539d
skipped capture-trace: step not selected by the request inputs
skipped receive-trace-artifact: upstream capture-trace did not run: step not selected by the request inputs
skipped cleanup-remote-temp: upstream capture-trace did not run: step not selected by the request inputs
host-step postprocess-index
host-step finalize-session
running->finalizing
finalizing->succeeded
```

intent 在 provider 调用前 durable 写入，`verified byteCount` 与 published
artifact 证明对应只读 dispatch/outcome 完成。三个 deviceMutation trace
分支均未选择。

## Artifact read-back

| Name | ID | Status | Bytes | Privacy | SHA-256 |
| --- | --- | --- | ---: | --- | --- |
| `hilog.txt` | `ART-311000a55a7f5ab1` | published | 241 | sensitive | `311000a55a7f5ab16bd5b538a06abbd9aac2fecd47996b355aff06002fa4e930` |
| `ui-dump.json` | `ART-8d3a40b4af1a539d` | published | 240 | sensitive | `8d3a40b4af1a539d3848b08cf8cd3d4f2bf974b11f4f9cc3bb16965f7a44ac3f` |
| `trace.htrace` | `ART-MISSING-trace.htrace` | missing | 0 | sensitive | n/a |
| `artifact-index.json` | `ART-83cbedc187b4c027` | published | 606 | standard | `83cbedc187b4c027174c34faaa2e7b0ff5fb7cbf4133afcd44f94aac2a92da4c` |
| `capture-summary.json` | `ART-a7b54c62105a994c` | published | 667 | standard | `a7b54c62105a994cd5771648befd549abf3f5f6034ba6f4cd9f31c6268cffda9` |

Agent 经 `artifact.list`、`artifact.inspect`、`artifact.read` 读取标准级
summary。解码结果：

```json
{
  "completeness": "complete",
  "missingRequired": [],
  "artifacts": {
    "hilog.txt": {"status": "published", "required": true, "byteCount": 241},
    "ui-dump.json": {"status": "published", "required": false, "byteCount": 240},
    "trace.htrace": {
      "status": "missing",
      "required": false,
      "detail": "upstream capture-trace did not run: step not selected by the request inputs"
    }
  }
}
```

sensitive raw HiLog/UI dump 未读取、未导出、未入 Git；只记录其元数据。
daemon 随后干净停止，socket 已移除。

## Formal evidence blocker

当前正本
`openspec/contracts/hardware-evidence.schema.json`
blob `98443833b5bef36f4a1e0fdea9dbaaccf057f4d1`：

- schemaVersion 固定 `2.0.0`；
- required `operator:string` 的 description 明确“An agent identity here is
  invalid”；
- `additionalProperties:false`，无法加入 DHA receipt 的
  `executor/authorizationRef`；
- required `device.firmware` 与
  `physicalTargetConfirmation.confirmedAt` 未由本次 receipt 暴露，不能猜填。

`CHG-2026-025` 的 V3 draft
blob `492aa3d5107c6790f56df1fff336280578494364`
能够表达 Agent executor，但其 approved proposal r5 明确声明：V3 在该 change
archive 前仍只是 scoped delta，其他 change 不得借用为 current contract。
`CHG-2026-049` 没有自己的 hardware-evidence contract delta。

因此不存在一个可由本次字段如实满足的 authoritative schema。把 `operator`
写成 `lvye` 会伪造 executor；直接借用 V3 会越过 authority；补写 firmware/
confirmation 时间会猜测事实。三种做法均禁止。

## AC 与安全结论

| AC | 结论 | 说明 |
| --- | --- | --- |
| `DHA-HW-001` observable runtime | SUCCEEDED | Agent E0 run、artifacts、summary 均符合 change-local行为 |
| `DHA-HW-001` formal acceptance | **BLOCKED / NOT CLAIMED** | hardware-evidence authority/schema 与 receipt 字段不闭合 |
| `DHA-HW-002` | NOT RUN | 无 E1 capability；本窗口明确不授权 |

- `arkdeck agent run` 调用恰一次，零重试；
- 零 capability、零 E1/E2、零 remote trace/temp/cleanup；
- humanAction 为空；人工 host CLI 为 0；
- 完整 connect key/序列号与 raw device artifact 均未入仓；
- runtime success 没有被写成 schema-valid realHardware PASS。

后续必须先通过 authoritative change 关闭 Agent hardware-evidence contract 与
runtime receipt 的 firmware/target-confirmation 字段缺口，再取得新的 ready/D2
窗口复验。现有 `CHG-2026-025` 已承载 V3 方向，但在其 delta 合法晋升前，本
task 保持 blocked。
