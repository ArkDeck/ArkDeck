# TASK-DHA-001 设备窗口计划(DHA-HW-001 / DHA-HW-002)

> **本文件不是授权载体。** 窗口安排属 D2 决策;`DHA-HW-002` 另需维护者
> 经 merged PR 签发的 E1 capability(见 §3)。
>
> **执行模型(#785 修订)**:host Runtime 调用由 **Device Runtime Agent**
> 执行(`arkdeck agent run`),不再由维护者逐条复制命令。DHA-HW-001 的
> daemon 也由 Agent 启动；维护者只需①为 DHA-HW-002 签发/安装 E1
> capability、②在 Agent 报出
> `humanAction` 时完成设备屏幕信任、歧义选择或物理拔插。**人工代跑
> host CLI 不满足 `DHA-HW-*`**;若环境没有可用 Agent,AC 保持 blocked。
>
> **attempt#2 修订**:attempt#1 因窗口命令漏传 Catalog 必填的
> `durationSeconds` 在 job 创建前 fail closed（PR #791 /
> `d037768f5e92850861219cd64edf53bfbb4b56ae`）。attempt#2 使用本目录下
> reviewed 的 `dha-hw-001-attempt-2-inputs.json`，只补齐该必填 bounded
> 输入；文件中不存在 `traceCategories`，因此 effective effect 仍为 E0。
> 独立 D2 window PR 合入前不得执行。

## 1. 前置

1. main 已含 TASK-DHA-001 实现 PR 的合并 commit;
2. 二进制按该 main 分别重建（SwiftPM 的重复 `--product` 只构建最后一个
   值）：在 `Packages/ArkDeckKit` 依次执行
   `swift build --product arkdeck` 与
   `swift build --product arkdeck-agentd`;
3. HDC 与设备同 MU-3 窗口(`Ver: 3.2.0f`,hash
   `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`);
4. 状态目录**必须短**(UDS 104 字节上限);DHA-HW-001 attempt#2 固定
   `/private/tmp/adw4` 且 mode `0700`;
5. `DHA-HW-001` attempt#2 还需:承载
   `window-attempt-2-plan.md` 的 D2 window PR 已由维护者 review/merge，
   且当前时间、设备、HDC、inputs hash 与该 plan 逐项匹配；
6. `DHA-HW-002` 还需:一个可安装的 **debug HAP** 文件,以及 §3 的
   capability 已 merge。

## 2. DHA-HW-001(E0 采集,无需新 capability)

daemon 由 Agent 启动，参数同 MU-3 窗口(`ARKDECK_HDC_PATH` +
`--state-dir /private/tmp/adw4`)。

attempt#2 的 reviewed typed inputs 是：

```json
{
  "durationSeconds": 5
}
```

文件：
`evidence/runs/TASK-DHA-001/dha-hw-001-attempt-2-inputs.json`；
SHA-256：
`277918e3016edb145aaee46cb33ee1f0d4a31a70a9a2d160e5d5128ed61585ba`。
Agent 在 dispatch 前必须重算 hash 并逐字确认 JSON **没有**
`traceCategories`；不匹配即零 dispatch、记录 blocked-attempt。

由 Agent 执行：

```bash
"$BIN/arkdeck" agent run --socket "/private/tmp/adw4/agentd.sock" \
  --operation "capture.diagnostics@1" \
  --inputs-file \
  "openspec/changes/chg-2026-049-diagnostics-and-hap/evidence/runs/TASK-DHA-001/dha-hw-001-attempt-2-inputs.json" \
  --json
```

**不得添加 `traceCategories` 或替换 inputs 文件**:那会把 plan 升为 E1
并要求 capability，不属于 `DHA-HW-001` 的 E0 面(remote-file trace 的
真机执行须另持 E1 capability，不得混入 E0 证据)。

预期 receipt 的 `terminalState: "succeeded"`；随后由 Agent 核对：

```bash
"$BIN/arkdeck" job status --socket "/private/tmp/adw4/agentd.sock" \
  --job "<jobId>" --json
"$BIN/arkdeck" artifact list --socket "/private/tmp/adw4/agentd.sock" \
  --job "<jobId>" --json
"$BIN/arkdeck" artifact inspect --socket "/private/tmp/adw4/agentd.sock" \
  --job "<jobId>" --artifact "<capture-summary artifactId>" --json
"$BIN/arkdeck" artifact read --socket "/private/tmp/adw4/agentd.sock" \
  --job "<jobId>" --artifact "<capture-summary artifactId>" --json
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

由 Agent 执行,引用维护者已安装的 capability:

```bash
"$BIN/arkdeck" agent run --socket "$HOME/adw4/agentd.sock" \
  --operation "debug.hap@1" --capability CAP-RT-DAYU200-HAP-001 \
  --inputs-file <hap-inputs.json> --json
```

receipt 应记 `executor: "agent"`、`authorityReference` 为该 capability ID;
job timeline 关键点(缺任一即不通过):

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
