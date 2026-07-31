# TASK-HTP-005 run r1 — workspace typed operation 闭环

- Date: 2026-07-31
- Executor: agent（交互式会话）
- Effect: hostOnly；零 HDC dispatch、零设备操作、零人工 capability
- Production state root: `/private/tmp/arkdeck-gj5-htp005.fsRrMR`
- Target reference: `workspace-host`（host correlation label，不是设备身份）

## 产品结果

在 TASK-HTP-007 已合入的 `workspace` provider 与 host-only admission 上新增五个
production operation：

- `workspace.apply-patch@1`
- `workspace.build-openharmony@1`
- `workspace.run-tests@1`
- `workspace.symbolize-crash@1`
- `workspace.revert-patch@1`

调用者只能提交 project/preset/Artifact lease 等 typed input。ProjectProfile 持有
executable identity、完整 argv、语义 `argv[0]`、timeout 与文件范围；materialized
plan digest 包含这些字段。Runtime 在 admission 前解析输入 Artifact lease 并要求其
binding snapshot 仅含相同 host target label，`bindingRevision` 与
`stableIdentitySHA256` 均必须为空。

Patch 在 spawn 前验证 hash、size、统一 diff 路径与双层 glob，apply 后以文件 hash
readback 形成 durable `patchAttemptRef`，revert 使用 provider-owned patch 副本并以
原始 preimage hash readback。receipt 丢失只 reconcile exact persisted action，不自动
重发。Build/test 非零退出保持 Job failed，同时保留真实 stdout/stderr log；输出截断
fail closed。

## 生产 Runtime Availability

以 production composition root 启动：

```text
ARKDECK_WORKSPACE_PROJECTS=ArkDeck=<repo-root>
ARKDECK_WORKSPACE_INSPECTOR=/usr/bin/grep
arkdeck-agentd --state-dir /private/tmp/arkdeck-gj5-htp005.fsRrMR
```

`arkdeck operation list --json`：

```text
workspace.apply-patch@1         available
workspace.build-openharmony@1   available
workspace.inspect-source@1      available
workspace.revert-patch@1        available
workspace.run-tests@1           available
workspace.symbolize-crash@1     unavailable: workspace.presetUnavailable
```

未配置精确 symbol preset 时没有猜测替代工具；availability 与 submit 共用同一
provider/dispatcher/materialization gate。

## 真实 build/test Job

两次执行均通过 `arkdeck job submit --request-file ... --wait --json` 进入 Runtime，
没有直接运行 SwiftPM，也没有人工授权。

| operation | Job / plan digest | terminal | Artifact / bytes / SHA-256 |
|---|---|---|---|
| `workspace.build-openharmony@1` | `job-a72404f84a7b3c1cbd040ab95de07a38` / `48af1b1565659b4d5ccc2f890cb3e1873bd9ff8282850afd40c28e8f4073586c` | `succeeded`, `outcomeUnknown=false` | `build.log`, `ART-9f5725533d0422259138f6aa18c25f85`, 120 bytes, `15701567a3b663e94fb7f6149188795f2877da3c34e79bf28079305a110d05c1` |
| `workspace.run-tests@1` | `job-837a2602a7b90fe6351a1a2c30a06576` / `aa9e9f9d542be0763eb5d006a6a5586d2c9a25e6e159bd59438f627369a3a2ed` | `succeeded`, `outcomeUnknown=false` | `test-output.log`, `ART-d312a0bf6f24d5399830bb4036007738`, 280952 bytes, `d4f9e0e7aafd4797073a6a97b485c9ce007eb47187daf3718123371f2603dcd3` |

两个 Job record 与 Artifact binding snapshot 均为：

```text
providerID=workspace
targetID=workspace-host
materializedStableTargetIdentitySHA256=null
materializedBindingRevision=null
artifact.stableIdentitySha256=null
artifact.bindingRevision=null
```

Daemon 使用相同 state root 重启后报告 `recovered 2 persisted job(s)`；两个 Job
仍为 `succeeded/outcomeUnknown=false`，timeline 追加 `recovered: journal clean`。

## 测试

```text
WorkspaceProviderContractTests: 14 passed
HostOnlyAdmissionContractTests: 15 passed
DeviceProviderContractTests: 20 passed
ArkDeckCoreTests: 73 passed
CI=true swift test --package-path Packages/ArkDeckKit: 891 passed, 1 skipped
scripts.catalog_gen.test_generate: 39 passed
scripts/catalog_gen/generate.py --check: exit 0
```

其中 workspace 套件覆盖五操作逐 token lowering、真实 process、host-bound Artifact
lease、apply/readback/revert、越界与 `-p1` 前缀绕过零写入、exact action persistence、
receipt-lost reconcile、runtime unavailable 零 admission、materialized plan digest、
失败 build log 保留且 Job 不伪装成功。

## 范围结论

本任务完成 HTP-AC-15..17，但不宣称 GJ-5 `REAL_DEVICE_PASS`。DAYU200 上由 task plane
一次 submit 自动收敛且接管后人工步骤为零仍属于 TASK-HTP-006。
