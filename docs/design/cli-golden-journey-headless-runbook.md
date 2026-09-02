# CLI headless Golden Journey rerun runbook

Task: TASK-AIN-021（产品规格 §13.2、§15.3、§18；`PRODUCT-LOOP.md` §6）

规格 §18 的 macOS「全功能」结论现在只剩一项阻断：GJ-1～GJ-5 必须在**当前 Catalog digest**
上从 CLI headless 完整复跑，并按 `PRODUCT-LOOP.md` §6 的四态逐条记录。机器门
（`openspec/contracts/cli-feature-coverage.json` 的 `summary.fullFunction`）已经闭合，
它不替代真机证据。本 runbook 把设备窗口要做的事写成可以照跑的 argv 序列、判据与
记录模板，目的是让窗口时间只花在执行，不花在回忆。

本文只描述 CLI 与 Runtime 的已发布面；不含 raw HDC、外部 shell、authority 写入或
unknown replay。任何一步需要绕过这些面，就是 `BLOCKED_BY_PRODUCT_DEFECT`，记录原文后停止。

## 0. 约定

- 每条命令都带 `--output json --require-protocol 2`，stdout 原样保存到
  `/private/tmp/arkdeck-gj-headless-<date>/<journey>-<step>.json`（不入仓）。可入仓的是
  §6 的脱敏元数据。
- 每条命令都给一个可读的 `--control-request-id`（如 `gj1-doctor`），失败 envelope 的
  `meta.controlRequestId` 与之对应；同一 execution 重入必须复用同一 `--execution-id`。
- 四态只能是 `NOT_STARTED` / `IMPLEMENTING` / `BLOCKED_BY_PRODUCT_DEFECT` /
  `REAL_DEVICE_PASS`；`REAL_DEVICE_PASS` 只在当前 digest 上成立。
- 任何 `outcomeUnknown` / `reconcileRequired` 都走 `arkdeck job reconcile --job <id>` 读回，
  不重放请求；任何 `humanActionRequired` 都走 `human-action show` → `agent resume`；
  两者都记进元数据，不算失败也不算通过。
- 台账零派发判据：负向用例前后 `arkdeck job list --page-size 1000 --output json` 的
  `items` 数量与 `jobId` 集合相同。

固定事实（写元数据时逐项核对，不从记忆抄）：

| 事实 | 读取方式 |
|---|---|
| Catalog digest | `arkdeck operation list --output json` → `result.catalogDigest`；期望 `508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`，与 `arkdeck --version --output json` 无关 |
| Runtime 版本与可执行文件哈希 | `arkdeck runtime service status --output json`、`arkdeck runtime bundle list --output json` |
| CLI 构建 | `arkdeck --version --output json` → `buildIdentity` |
| 目标与 binding revision | `arkdeck target show --target <TGT> --output json`；上次记录为 `TGT-958780b2ffb7` / r4（刷机后 revision 可能前进） |
| HDC 选择 | `arkdeck runtime tool list --output json`、`arkdeck runtime hdc status --output json` |

## 1. 前置（窗口开始前 15 分钟）

```text
arkdeck doctor --deep --require-healthy --output json
arkdeck runtime service status --output json
arkdeck runtime service verify --output json
arkdeck runtime hdc status --output json
arkdeck runtime tool list --output json
arkdeck operation list --output json
```

判据：`doctor` exit 0；`operation list` 的 `catalogDigest` 等于期望值且 29 个 canonical
operation 全部 `available`；HDC status 报告一个 `normal` 的 DAYU200。digest 不等 → 先按
`openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/host-prerequisites/installation-runbook.md`
（`runtime bundle register` → `runtime service update` → `runtime service verify`）更新到
protected `main` 的 Runtime，再继续；这一步不是 Journey 的一部分。

输入物料（放在 `/private/tmp/arkdeck-gj-headless-<date>/inputs/`）：

- GJ-2：已签名单入口 HAP（08-28 记录用的同一包可复用），`bundleName`/`abilityName`；
- GJ-3：已签名 `armeabi-v7a` `.so`（见 `arkdeck-gj3` 记录）、`targetBundle`、
  `libraryLogicalName`；
- GJ-4：`OpenHarmony-7.0.0.37` 归档，SHA-256
  `4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674`（730 783 514 字节）；
  E2 授权由维护者按 08-28 的 HardwareCampaign 流程在 host authority 侧启用，CLI 没有授权
  写入面（`capability draft/install/revoke` 永久拒绝）；
- GJ-5：已注册的 `openharmony` 项目与 build/signing preset（`workspace project list`、
  `workspace preset list --project <ref>`），以及 crash-probe fixture 工程。

## 2. GJ-1 Device Observe（约 5 分钟）

```text
arkdeck device candidates --require-protocol 2 --output json
# 未接管时：
arkdeck target adopt --candidate <key> --observation <observation-id> \
  --observation-generation <generation> --output json
arkdeck target show --target <TGT> --output json
arkdeck target availability --target <TGT> --output json
arkdeck agent run --require-protocol 2 --operation observe.device@1 --target <TGT> \
  --execution-id gj1-<date> --maximum-wait 5m --output json
arkdeck agent status --execution-id gj1-<date> --output json
arkdeck job result --job <job-id> --output json
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
```

`observe.device@1` 的唯一输入 `refreshServerFacts` 默认 `true`，不需要 inputs 文件。
判据：`terminalState == succeeded`、`outcomeUnknown == false`、`evidenceBlockers == []`、
3 个 Artifact 全部可 `artifact read`（经 digest 校验）。最后一步是 §6 的
「Daemon 重启后仍可查询结果」：

```text
arkdeck runtime service restart --output json
arkdeck job show --job <job-id> --output json
arkdeck job result --job <job-id> --output json
```

首次信任提示（`targetTrustPending` / `humanActionRequired`）按 §0 走 HAR 恢复，
记入元数据 `humanActions`。

## 3. GJ-2 HAP Debug（约 10 分钟）

```text
arkdeck artifact import hap --import-request-id gj2-<date>-entry --target <TGT> \
  --file inputs/entry-signed.hap --output json
arkdeck artifact import inspect --import-request-id gj2-<date>-entry --output json
```

取 import 回执的 `result.lease`，写 `gj2.json`：

```json
{
  "hapArtifactLease": "<lease>",
  "bundleName": "<bundleName>",
  "abilityName": "<abilityName>",
  "installPolicy": "installOrReplace",
  "cleanupPolicy": "uninstall",
  "postRunAbilityState": "stopped",
  "captureDiagnostics": true,
  "diagnosticsDurationSeconds": 10
}
```

```text
arkdeck debug hap --require-protocol 2 --target <TGT> --inputs-file gj2.json \
  --execution-id gj2-<date> --output json
arkdeck job wait --job <job-id> --output jsonl
arkdeck job result --job <job-id> --output json
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
```

判据（对应 §6 GJ-2 的每一跳）：远端文件 readback、`install -r` 与 package readback、
Ability 启动与 PID readback、HiLog、UI Dump、Trace、停止应用与 staging 清理在 evidence 的
step 列表里逐一 `verified`；`outstandingResidueCount == 0`；Artifact 数与 08-28 记录同量级
（当时 9 个已发布 Artifact，缺省 `captureDiagnostics: true`）。

## 4. GJ-3 Native Debug（约 10 分钟）

```text
arkdeck artifact import native-library --import-request-id gj3-<date>-lib --target <TGT> \
  --file inputs/libexample.so --output json
```

`gj3.json`：

```json
{
  "libraryArtifactLease": "<lease>",
  "targetBundle": "<bundleName>",
  "libraryLogicalName": "libexample.so",
  "expectedABI": "armeabi-v7a",
  "restartProfile": "restartAbility",
  "verificationProfile": "hashProcessAndMaps",
  "rollbackPolicy": "autoRollback"
}
```

```text
arkdeck debug native deploy --require-protocol 2 --target <TGT> --inputs-file gj3.json \
  --execution-id gj3-<date> --output json
arkdeck job wait --job <job-id> --output jsonl
arkdeck job evidence --job <job-id> --output json
```

判据：ELF/ABI/Build ID/hash 校验、受控 staging、远端 hash、原子发布、进程重启、
`hashProcessAndMaps` 加载验证全部 `verified`。rollback 腿（`autoRollback` 在验证失败时
触发）按 `arkdeck-gj3` 记录的造法做一次：用与 `expectedABI` 不匹配的库再提交一次，
期望 terminal 为失败但 `evidence` 显示备份已回滚、目标进程恢复；这一腿也计入 GJ-3。

## 5. GJ-4 Flash Recovery（约 15 分钟，其中擦写约 3 分钟）

```text
arkdeck flash device-access --output json
arkdeck flash bootloader-status --output json
arkdeck flash prerequisites --target <TGT> --device-profile dayu200 --output json
arkdeck artifact import flash-bundle --import-request-id gj4-<date> --target <TGT> \
  --file inputs/OpenHarmony-7.0.0.37.tar.gz --device-profile dayu200 --output json
arkdeck flash lane-preview --target <TGT> --device-profile dayu200 \
  --archive-sha256 4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674 --output json
arkdeck flash bind-loader --target <TGT> --expected-binding-revision <n> --output json
```

`gj4.json`：

```json
{
  "artifactLease": "<lease>",
  "deviceProfileRef": "dayu200",
  "intent": "fullRestore",
  "verification": "full"
}
```

维护者在 host authority 侧启用 HardwareCampaign（记录 campaign 名与启用/关闭 exit code，
同 08-28 的 `flash-canonical-verification-2026-08-28.json`），然后：

```text
arkdeck flash run --require-protocol 2 --target <TGT> --inputs-file gj4.json \
  --execution-id gj4-<date> --output json
arkdeck job wait --job <job-id> --output jsonl
arkdeck job evidence --job <job-id> --output json
```

判据：`stepKinds` 含 `waitForReconnect`/`probeDevice`/`flashPartition`/`verifyRemoteState`/
`rebootDevice`/`captureRemoteStdout`；machine readback 为 `OpenHarmony-7.0.0.37`；
`outcomeUnknown == false`、`humanActions == []`、`outstandingResidueCount == 0`。
随后完成 §6 的「重新发现并接管设备 → 恢复正常 Debug Runtime」：

```text
arkdeck device candidates --require-protocol 2 --output json
arkdeck target show --target <TGT> --output json        # binding revision 若前进，记录新值
arkdeck agent run --require-protocol 2 --operation observe.device@1 --target <TGT> \
  --execution-id gj4-<date>-postflight --maximum-wait 5m --output json
```

campaign 关闭并恢复启用前配置后再写元数据；历史 unknown 记录不得被重放或改写。

## 6. GJ-5 Bounded AI Debug Loop（约 60 分钟）

会话形态照 `chg-2026-064` `TASK-AND-002` run-r2：headless 外部 agent，宿主只许 `arkdeck`
CLI 与只读工具，循环内人工步骤 0。预算文件（`maxRounds`、`maxWallClock`、
`maxArtifactBytes`、`maxE1Mutations`、`allowedOperations`、`stopOnRepeatedFailure`、
`stopOnOutcomeUnknown`、`stopOnHumanActionRequired`、`stopOnAuthorizationRequired`）
随任务书一起保存。会话内的最小 CLI 序列：

```text
arkdeck workspace project list --output json
arkdeck workspace preset list --project <project-ref> --output json
arkdeck debug hap … --execution-id gj5-<date>-repro            # 复现（crash-probe fixture）
arkdeck artifact read --job <job-id> --artifact <ART> --output json
arkdeck analyze crash-signature --inputs-file gj5-crash.json --output json
arkdeck workspace isolate --inputs-file gj5-isolate.json --output json
arkdeck artifact import workspace-patch --import-request-id gj5-<date>-patch --target <TGT> --file fix.patch --output json
arkdeck workspace patch --inputs-file gj5-patch.json --output json
arkdeck workspace build --inputs-file gj5-build.json --output json
arkdeck workspace sign --inputs-file gj5-sign.json --output json
arkdeck debug hap … --execution-id gj5-<date>-sample-<1..5>    # 五个干净样本
```

负向用例（零派发）：同一补丁 lease、`expectedWorkspaceRevision` 取已被取代的 revision，
期望 `invalidInput`（`workspace.revisionConflict`）、exit 65，`job list` 前后台账相同。
判据同 run-r2：五样全 HEALTHY、crash-index 不变、`task.*`/App/人工步骤 0、预算未超。

## 7. 记录模板与落点

每条 Journey 一个对象，合并写入
`docs/design/references/v1.6-goal/gj-headless-rerun-<date>.json`（脱敏：只留 SHA-256、
jobId、executionId、计数与 UTC 时间，不留 connectKey、序列号、原始输出）：

```json
{
  "date": "<YYYY-MM-DD>",
  "goldenJourney": "GJ-1",
  "state": "REAL_DEVICE_PASS",
  "evidenceKind": "redacted-metadata-derived-from-real-runtime",
  "catalogDigest": "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684",
  "runtimeSourceRevision": "<main sha>",
  "runtimeExecutableSHA256": "<sha256>",
  "cliBuildIdentity": "<from --version>",
  "targetID": "TGT-…",
  "bindingRevision": 4,
  "executionIDs": ["gj1-<date>"],
  "jobs": [
    {
      "jobID": "job-…",
      "operationReference": "observe.device@1",
      "terminalState": "succeeded",
      "outcomeUnknown": false,
      "evidenceBlockers": [],
      "humanActions": [],
      "artifactCount": 3,
      "startedAtUTC": "…",
      "finishedAtUTC": "…"
    }
  ],
  "zeroDispatchChecks": [],
  "notes": ""
}
```

同一 PR（docs-only，声明 `TASK-AIN-021`）同时：在 `real-device-validation.md` 追加一节指向
该 JSON；把产品规格 §13.2 的 GJ 行改为按 Journey 逐条写四态（全部 `REAL_DEVICE_PASS`
时删除该行，并在 §13.1 记录 digest 与日期）；`PRODUCT-LOOP.md` 的 Journey 状态由维护者
另行更新。任何一条为 `BLOCKED_BY_PRODUCT_DEFECT` 时，把失败 envelope 原文（脱敏后）与
复现 argv 写进 `notes`，并按「一个问题 = 一个垂直产品任务」开修复 Task，不在 CLI 里补
执行器绕过。
