# TASK-DHA-001 设备窗口计划(DHA-HW-001 / DHA-HW-002)

> **本文件不是授权载体。** 窗口安排属 D2 决策;`DHA-HW-002` 另需维护者
> 经 merged PR 签发的 E1 capability(见 §3)。Agent 零设备命令、零
> capability 签发:以下命令全部由维护者亲手执行并贴回 transcript。

## 1. 前置

1. main 已含 TASK-DHA-001 实现 PR 的合并 commit;
2. 二进制按该 main 重建:`swift build --product arkdeck-agentd --product
   arkdeck`(在 `Packages/ArkDeckKit`);
3. HDC 与设备同 MU-3 窗口(`Ver: 3.2.0f`,hash
   `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`);
4. 状态目录**必须短**(UDS 104 字节上限),例如 `~/adw4`;
5. `DHA-HW-002` 还需:一个可安装的 **debug HAP** 文件,以及 §3 的
   capability 已 merge。

## 2. DHA-HW-001(E0 采集,无需新 capability)

daemon 启动同 MU-3 窗口(`ARKDECK_HDC_PATH` + `--state-dir ~/adw4`)。

```bash
"$BIN/arkdeck" job submit --socket "$HOME/adw4/agentd.sock" \
  --target "<targetId>" --operation "capture.diagnostics@1" --wait --json
```

需要非默认 duration/filter/trace 时,用 Agent 事先起草的请求文件:

```bash
"$BIN/arkdeck" job submit --socket "$HOME/adw4/agentd.sock" \
  --request-file <capture-request.json> --wait --json
```

(`--request-file` 已随本 change 交付并 host 自测:请求原样透传给
daemon,校验仍在 daemon 侧。)

预期:`state: succeeded`;随后

```bash
"$BIN/arkdeck" job status --socket "$HOME/adw4/agentd.sock" --job "<jobId>" --json
```

timeline 应含 `artifact hilog.txt -> ART-…`;若 trace 未请求,
`capture-summary.json` 应把 `trace.htrace` 列为 `missing`。

## 3. DHA-HW-002 的 E1 capability(维护者签发,D2)

**Agent 不得创建、修改或批准。** 维护者以自己的 PR 合入一份 capability
文档(内容形如下,`<…>` 由维护者填写),或经等效的 install 路径:

```json
{
  "capabilityID": "CAP-RT-DAYU200-HAP-001",
  "targetScope": { "kind": "stablePhysicalIdentity", "sha256": "<该设备稳定身份 sha256>" },
  "operationScope": [{ "operationID": "debug.hap", "version": 1 }],
  "effectCeiling": "deviceMutation",
  "inputConstraints": { "bundleName": { "kind": "exactString", "value": "<待调试 bundle>" } },
  "issuedAtUTC": "<YYYY-MM-DDTHH:MM:SSZ>",
  "expiresAtUTC": "<窗口后不久>",
  "maximumUses": 3,
  "issuer": { "kind": "maintainerMergedPR", "reference": "<PR#N + merge OID>" },
  "revocation": { "state": "active" }
}
```

安装(维护者执行):

```bash
"$BIN/arkdeck" capability install --socket "$HOME/adw4/agentd.sock" --file <capability.json>
```

(`capability install|list|revoke` 已随本 change 交付并 host 自测:
安装/列出/撤销三条命令均实跑通过。)

## 4. DHA-HW-002(E1 调试)

```bash
"$BIN/arkdeck" job submit --socket "$HOME/adw4/agentd.sock" \
  --target "<targetId>" --operation "debug.hap@1" --wait --json
```

预期 timeline 关键点(缺任一即不通过):

- `dispatched install-hap; awaiting readback`
- `verified package-readback ["bundleName", "installed"]`
- `dispatched start-ability; awaiting readback`
- `verified process-readback ["bundleName", "running"]`
- `finalizing->succeeded`

随后核对 capability 消耗:

```bash
"$BIN/arkdeck" capability list --socket "$HOME/adw4/agentd.sock" --json
```

预期:`remainingUses` 恰减 1(**整个 recipe 一次消耗**,不是每个 mutation
步各消耗一次)。

## 5. 负向核对(同一窗口内做,证据价值高)

撤销 capability 后重跑 `debug.hap@1`,预期**零 dispatch** 并明确拒绝:

```bash
"$BIN/arkdeck" capability revoke --socket "$HOME/adw4/agentd.sock" --capability CAP-RT-DAYU200-HAP-001 --json
```

## 6. Host 侧自测已覆盖(窗口内不必再验)

2026-07-29 无设备实测:`capability list/install/revoke` 三条全通;
`job submit --request-file` 带 typed inputs 提交成功并在无 HDC 配置时
如预期 fail-closed(`failed preflight-device-storage`);`artifact list`
在空索引下正常返回。**窗口只需验真设备面。**

## 7. 脱敏与失败处置

- connect key/序列号按 MU-3 窗口纪律脱敏;bundle 名若属内部产品,贴回时
  可替换为 `<bundle>`;
- 采集到的 HiLog/dump/trace **不贴回、不入仓**,只贴 artifact 元数据行
  (ID/名称/字节数/状态);
- 任一步失败:停下并原样贴回错误文本,记 blocked-attempt;不重试、不改
  判据、不用 fixture 顶替。
