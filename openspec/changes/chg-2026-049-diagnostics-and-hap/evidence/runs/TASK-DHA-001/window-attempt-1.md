# TASK-DHA-001 设备窗口 attempt#1（2026-07-29）— DHA-HW-001 BLOCKED

- Executor:Device Runtime Agent（`executor=agent`）
- Evidence class:**realHardware / blocked-attempt**
- Base:main `915aa937efcb266ab66652c74ee7e11e6ed50509`（PR #786）
- Operation:`capture.diagnostics@1`
- Authority:`default-read-only-policy`（E0；未提供 capability）
- Result:**BLOCKED before job creation and before any operation step dispatch**

## 环境事实

| 项 | 值 |
| --- | --- |
| Device | DAYU200（RK3568），USB；Agent 自动 adopt |
| Durable target | `TGT-958780b2ffb7`（稳定物理身份 SHA-256 前 12 位） |
| Binding revision | `1` |
| HDC | `Ver: 3.2.0f`，SHA-256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` |
| HDC path | `<DEVECO_SDK>/default/openharmony/toolchains/hdc` |
| State dir | `<PRIVATE_TMP>/adw4`（mode `0700`，短 UDS 路径） |
| `arkdeck` | SHA-256 `25d89d494763a5dc33e3f3aa3f7047114b50316c590b7b453bcc894bf0581ed7` |
| `arkdeck-agentd` | SHA-256 `1c4db85bda5fe6e6866d9c8393e554d098ce4863a9da234d456759c9641c46c1` |
| Catalog digest | `a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717` |

## 预检

在 `Packages/ArkDeckKit` 从上述 main OID 构建：

```text
swift build --product arkdeck
swift build --product arkdeck-agentd
```

两产品构建成功。daemon 使用显式 HDC 路径启动：

```text
ARKDECK_HDC_PATH=<TOOL> <BIN>/arkdeck-agentd --state-dir <STATE>
```

daemon 报告：

```text
arkdeck-agentd listening on <STATE>/agentd.sock
```

typed `doctor` 结果：

```json
{
  "adoptedTargetCount": 0,
  "bootstrap": "ready",
  "catalogDigest": "a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717",
  "protocolVersion": "1.0.0",
  "providers": ["hdc"],
  "targetStore": "ready"
}
```

## 唯一一次 Agent execution

严格按 `device-window-plan.md` §2 执行，不传 `--inputs-file`，以避免
`traceCategories` 选择 E1 remote-file trace：

```text
<BIN>/arkdeck agent run --socket <STATE>/agentd.sock \
  --operation capture.diagnostics@1 --json
```

runner 自动 adopt 到上述 target/binding，随后在 operation 输入校验阶段
被拒：

```text
arkdeck agent: rejected(ArkDeckWorkflows.RuntimeOperationErrorCode.invalidInput,
"required input durationSeconds is absent")
```

脱敏 receipt：

```json
{
  "artifacts": [],
  "authorityReference": "default-read-only-policy",
  "bindingRevision": 1,
  "catalogDigest": "a5a1205c5b6a3202a87d99ded5af4cf50b8e4bd4bd47693c517aa249e0a6d717",
  "executor": "agent",
  "finishedAtUTC": "2026-07-29T11:22:48Z",
  "humanActions": [],
  "operationReference": "capture.diagnostics@1",
  "startedAtUTC": "2026-07-29T11:22:48Z",
  "targetID": "TGT-958780b2ffb7",
  "terminalState": "rejected"
}
```

receipt 无 `jobID`、artifact 为空。`RuntimeJobEngine.submit` 在生成 job ID、
写 journal、授权与 operation step dispatch 之前调用 `validateInputs`；
因此本次 **零 capture job、零 capture operation step dispatch、零
mutation**。runner 在此之前已通过 typed daemon API 完成 E0 doctor 与
target discovery/adopt；这些只读 bootstrap 操作不冒充为 diagnostics
采集。daemon 随后干净停止。

## 根因

设备窗口步骤与已经发布的 operation contract 不一致：

- `Catalog/operations/capture.diagnostics.v1.json` 将
  `durationSeconds` 声明为 `required:true`，范围 `1...600`；
- generated Swift 与 contract test 同样锁定该字段必填，并显式验证缺失时
  返回 `invalidInput`；
- `device-window-plan.md` §2 却要求完全不传 `--inputs-file`。

不选择 trace 只要求 inputs 中不存在 `traceCategories`，并不意味着可以
省略必填的 `durationSeconds`。本 attempt 不修改 Catalog、实现或验收判据，
也不临时补参数重试。

## AC 判定与后续门

| AC | 判定 | 依据 |
| --- | --- | --- |
| `DHA-HW-001` | **BLOCKED / NOT PASS** | 已完成 E0 target adopt，但未创建 capture job、未 dispatch capture step、未产出 artifact 集合；receipt 如实记录 Agent 与 E0 authority |
| `DHA-HW-002` | **NOT RUN** | 本窗口在 DHA-HW-001 首次失败后停止；且 E1 capability 未进入本次范围 |

下一次执行前须修订设备窗口输入，使请求携带合法、typed、
bounded `durationSeconds` 且仍不携带 `traceCategories`，并由维护者重新
确认 D2 窗口。完成该门之前不得重跑，不得用 fixture/simulation 顶替。

## 安全与隐私

- target discovery/adopt 仅执行 E0 只读 bootstrap；零 capture step
  dispatch、零 deviceMutation、零 destructive；
- Agent 未创建、修改或使用 capability；
- connect key/完整序列号未入仓；
- 无 HiLog/UI dump/trace 产生或入仓；
- 设备失败没有被重试或降级为 simulation。
