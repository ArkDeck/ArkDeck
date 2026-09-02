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
  不重放请求；任何 `humanActionRequired` 都走 `human-action show` → `agent resume --resume-reference`；
  两者都记进元数据，不算失败也不算通过。HAR 的 crash-resume 能力本身是 §2.1 的判据。
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
  `workspace preset list --project <ref>`）、crash-probe fixture 工程与其已签名 HAP
  `inputs/crash-probe-signed.hap`，以及**固定的修复补丁** `inputs/gj5-fix.patch`（run-r2 落地的
  形态：只删 `EntryAbility.ets` 中 `armCrashProbe()` 的调用与 import，共 -3 行，不翻
  `FixtureMode.MODE`）。补丁是输入物料，不在窗口内现场生成。

## 2. GJ-1 Device Observe（约 10 分钟）

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
3 个 Artifact 全部可 `artifact read`（经 digest 校验）。

`PRODUCT-LOOP.md` §6 GJ-1 的「bounded HiLog → UI Dump」两跳由设备级 `capture.diagnostics@1`
承接（GJ-2 的采集是 app-scoped，不算）。`gj1-capture.json` 只给必填项：缺省即 HiLog + UI Dump，
effect 停在 `readOnly`，不需要 capability：

```json
{ "durationSeconds": 5 }
```

```text
arkdeck agent run --require-protocol 2 --operation capture.diagnostics@1 --target <TGT> \
  --inputs-file gj1-capture.json --execution-id gj1-<date>-capture --maximum-wait 5m --output json
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
```

判据：`terminalState == succeeded`、`outcomeUnknown == false`；Artifact 含 HiLog 与 UI Dump 两项，
均非空且 `artifact read` 经 digest 校验；capture summary 为 `complete`、`missingRequired == []`。

最后一步是 §6 的「Daemon 重启后仍可查询结果」（observe 与 capture 两个 Job 都要在重启后可读）：

```text
arkdeck runtime service restart --output json
arkdeck job show --job <job-id> --output json
arkdeck job result --job <job-id> --output json
```

首次信任提示（`targetTrustPending` / `humanActionRequired`）按 §0 走 HAR 恢复，
记入元数据 `humanActions`。

### 2.1 HAR crash-resume（计入 GJ-1，约 3 分钟）

规格 §15.3 要求客户进程在 HAR 前后崩溃都能仅凭 execution ID 重取并继续。载体用规格 §7.1 的
zero-candidate discovery 分支——它是唯一能确定性触发的 AgentExecution HAR：

```text
# 1. 拔掉设备 USB，确认 candidates 为空
arkdeck device candidates --require-protocol 2 --output json
# 2. 不带 --target 启动 execution：Runtime 持久化 physicalConnection（connectDevice）HAR
arkdeck agent run --require-protocol 2 --operation observe.device@1 \
  --execution-id gj1-<date>-har --maximum-wait 10m --output json
# 3. 模拟客户进程在拿到 receipt 后崩溃：丢弃步骤 2 的 stdout，不从中抄任何 resumeReference
# 4. 插回 USB，只用 execution ID 重取
arkdeck agent status --require-protocol 2 --execution-id gj1-<date>-har --output json
arkdeck human-action list --require-protocol 2 --owner-kind agentExecution --owner gj1-<date>-har --output json
arkdeck human-action show --require-protocol 2 --human-action <id> --output json
arkdeck agent resume --require-protocol 2 --resume-reference <ref> --output json
arkdeck agent status --require-protocol 2 --execution-id gj1-<date>-har --output json
arkdeck job result --job <job-id> --output json
```

判据：步骤 2 以 `humanActionRequired` / exit 75 返回且 `newDispatchCount == 0`；步骤 4 的
`agent status` 在没有任何本地文件的情况下给出 `waiting` 的 action 与 `nextAction.resumeReference`，
`human-action show` 的 `resumeReference` 与之逐字相同；resume 后 action 变为 `resolvedByFreshProbe`，
execution 继续到 Job terminal `succeeded`，target 与 binding revision 与本节前文相同（不得因重插
而重绑）。HAR 产生前崩溃的 durable commit 由契约测试覆盖，窗口内不重复。若 Runtime 在步骤 2
直接 terminal 拒绝而不产生 HAR，或步骤 4 依赖 CLI 本地状态，记 `BLOCKED_BY_PRODUCT_DEFECT`。

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
arkdeck debug hap --target <TGT> --inputs-file gj2.json \
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

## 6. GJ-5 Bounded AI Debug Loop——外部 Agent 闭环能力判据（约 20 分钟）

本 Journey 验证 ArkDeck 向外部 Agent 交付的闭环能力：`PRODUCT-LOOP.md` §6 的每一跳
（运行 → 采集 → 分析 → 生成下一次 typed request → admission → 部署 → 复验 → 停止）都只用
已发布 CLI 面走通，且判据全部是 CLI/Runtime 可验的确定性事实。它**不验证**执行者的修复
智能：补丁是 §1 的固定物料，谁来「分析问题」不改变判据。执行者可以是与 `chg-2026-064`
`TASK-AND-002` run-r2 同构的 headless 外部 agent 会话（宿主只许 `arkdeck` CLI 与只读工具），
也可以是人工照跑；两者记同一份元数据。

预算按 `PRODUCT-LOOP.md` §6 必含的九项（`maxRounds`、`maxWallClock`、`maxArtifactBytes`、
`maxE1Mutations`、`allowedOperations`、`stopOnRepeatedFailure`、`stopOnOutcomeUnknown`、
`stopOnHumanActionRequired`、`stopOnAuthorizationRequired`）随任务书保存。Runtime 侧只
enforce capability 预算与 allowed-paths/revision 准入；其余由执行者会话承担，并在元数据里
记录实际消耗（rounds、E1 job 数、wall clock、Artifact bytes）。预算是停止条件，不是通过判据；
超预算写进 `notes`。

复现用 `gj5-repro.json`（run-r2 的机制教训：12 s 崩溃窗必须以 `retain` + `running` 观测）：

```json
{
  "hapArtifactLease": "<crash-probe lease>",
  "bundleName": "<bundleName>",
  "abilityName": "<abilityName>",
  "installPolicy": "installOrReplace",
  "cleanupPolicy": "retain",
  "postRunAbilityState": "running",
  "captureDiagnostics": true,
  "diagnosticsDurationSeconds": 20
}
```

```text
arkdeck workspace project list --output json
arkdeck workspace preset list --project <project-ref> --output json
arkdeck artifact import hap --import-request-id gj5-<date>-probe --target <TGT> \
  --file inputs/crash-probe-signed.hap --output json
arkdeck debug hap --target <TGT> --inputs-file gj5-repro.json \
  --execution-id gj5-<date>-repro --output json                  # 复现
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
arkdeck artifact read --job <job-id> --artifact <crash-index ART> --output json
arkdeck analyze crash-signature --target <TGT> --inputs-file gj5-crash.json \
  --output json                                                    # 期望 answered
arkdeck workspace isolate --inputs-file gj5-isolate.json --output json
arkdeck artifact import workspace-patch --import-request-id gj5-<date>-patch --target <TGT> \
  --file inputs/gj5-fix.patch --output json
arkdeck workspace patch --target <TGT> --inputs-file gj5-patch.json --output json
arkdeck workspace build --inputs-file gj5-build.json --output json
arkdeck workspace sign --target <evolution-…> --inputs-file gj5-sign.json --output json
arkdeck artifact export --job <sign-job> --artifact <signed ART> --allow-sensitive \
  --destination inputs/signed --output json
arkdeck artifact import hap --import-request-id gj5-<date>-verify --target <TGT> \
  --file inputs/signed/<signed>.hap --output json
arkdeck debug hap --target <TGT> --inputs-file gj5-verify.json \
  --execution-id gj5-<date>-verify --output json                 # 复验：部署修补构建，一次即可
```

签名凭据前置：设备只装它信任的 profile。`install-sdk-release` 装的是 OpenHarmony 样例 release
材料（profile 只对样例 bundle 有效），DAYU200 对 waterflowdemo 报 `code:9568329 verify signature
failed`；可用的是 DevEco 自动签名的 debug profile（device-ids 含本机 UDID）。用
`runtime signing install --build-profile <DevEco build-profile.json5> --keystore <同一 storeFile>
… --key-alias debugKey --project-ref demo-app` 免 TTY 安装；换凭据前先 `workspace preset remove`
掉钉住旧凭据的 signing preset，再 `runtime signing remove`，装完再 `workspace preset register
--kind signing --credential <新 credential>` 并 `runtime service restart`。

作用域配对：`analyze crash-signature` 与 `workspace patch` 都消费一个绑定在 `<TGT>` 上的
Artifact lease（crash-index 采自该设备；补丁由 `artifact import workspace-patch --target <TGT>`
上传），所以这两条 host-only 请求必须显式 `--target <TGT>`——省略会让 typed discovery 选
`demo-app`/`analyzer-host` 作用域，lease 以「target/binding/identity does not match the
materialized request」被拒，零派发。`--target <TGT>` 不会 adopt 或 pin 设备（receipt 的
`bindingRevision` 为空），projectRef 仍决定工作树根。`expectedWorkspaceRevision` 没有读面：
它是 Runtime 对 profile 内文件的确定性摘要（`WorkspaceProviderSupport.workspaceRevision`），
执行者按同一算法自行计算，`workspace isolate` 的 `isolated-workspace.json` 会把
`sourceWorkspaceRevision` 回显以供核对。

修复腿的作用对象是隔离副本，不是 `demo-app` 本体：`workspace isolate` 的
`isolated-workspace.json` 给出副本的 `projectRef`（`evolution-…`）与 `workspaceRevision`，
后续 `workspace patch/build` 的 `projectRef` 都填这个副本引用，
`expectedWorkspaceRevision` 填副本的 revision（副本上的 patch 必填此项）。`workspace sign`
是 host-only、签名凭据绑定在 `demo-app` 上，所以 `gj5-sign.json` 的 `projectRef` 填 `demo-app`、
`signingPresetRef` 填已注册的 `preset-…`，并以 `--target <evolution-…>` 指向 build 产物
（`unsigned.hap` lease）所在的副本作用域；签出的 `signed.hap` 用 `artifact export` 落盘后
再 `artifact import hap --target <TGT>` 才能进 `debug hap`。副本是 Runtime 自有的任务副本，E1 变更由
Runtime 自动签发 capability；对 `demo-app` 本体的 E1 请求仍然要求显式 grant（当前没有
安装面，故必然 `authorizationRequired`）。副本不单独注册：它的 Job 取用来源项目
（`demo-app`）的注册、preset 与 toolchain pin，所以 `buildPresetRef`/`signingPresetRef`
仍是 `workspace preset list --project demo-app` 里的引用。daemon 重启后副本由
`adoptRuntimeWorkspaces` 重新登记；若副本引用解析失败，用同一 `--execution-id` 重跑
`workspace isolate` 即可重新登记而不会再拷贝一份。

负向用例（零派发）：同一补丁 lease、`expectedWorkspaceRevision` 取已被取代的 revision。
2026-09-02 在当前 Runtime/Catalog digest 上用候选 CLI 复跑后，domain leaf 返回
`ok:false`、`error.code: invalidInput`、exit 65；`error.details` 同时给出
`wireCode: invalidInput`、`method: job.submit`、`phase: preAdmission` 与
`newDispatchCount: 0`。2.x `job list --page-size 1` 在调用前后都以
`job-cf76e61adb789f8b2bda5172a490d803`（`2026-09-02T09:56:27Z`）为 newest Job，
精确证明没有创建 Job；这组结构化证据与台账不变量共同满足 §8.4/§9。

判据：

- 复现：liveness `UNHEALTHY` / `targetProcessNotRunning`，crash-index 新增恰一条，
  `analyze crash-signature` 为 `answered`（不是 `unreadable`）；
- 修复腿：isolate、import、patch、build、sign 全部 `succeeded`、`outcomeUnknown == false`，
  `workspace patch` 的 evidence 载明 `previousWorkspaceRevision` → 新 revision；
- 复验：install-readback 把部署字节钉到 signed.hap 的 SHA-256；崩溃窗（12 s）后一次观测
  liveness `HEALTHY`，crash-index 计数与修复前相同；
- 负向：具名拒绝 + 台账相同；
- 纪律：全程只有已发布 CLI 面，raw 设备命令 0、App 0、仓库文件写入 0；HAR 若出现按 §0 记录；
  crash-resume 能力已由 §2.1 证明，本节复用同一 execution 机制不再重做。

run-r2 的「五个干净样本」与「agent 自行拒绝非最小修复」是对执行者的评估，不进四态；修复
效果只需一次复验。

## 6a. digest 变更 operation smoke（约 2 分钟，不计入任何 GJ 四态）

`CHG-2026-073` 发布的 `debug.template@1` 是当前 digest 与上一 digest 的唯一差异；它自己也
需要一条当前 digest 的真机记录，否则「digest 变了所以全部 GJ 复跑」的理由本身没有证据。

```json
{ "templateId": "device.uptime" }
```

```text
arkdeck debug template list --output json
arkdeck debug template run --target <TGT> --inputs-file gj-template.json \
  --execution-id gj-template-<date> --output json
arkdeck job result --job <job-id> --output json
```

判据：`template list` 的四个 `templateId` 与 `operation describe --operation debug.template@1`
的 enum 一致；Job `succeeded`、effect `readOnly`、Artifact 可读且非空。结果只进 §7 的覆盖矩阵。

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

同一文件另含一个 `operationRealDeviceCoverage` 对象，29 个 canonical operation 每个一行，让
「全功能」的真机边界可见，而不是由五条 Journey 暗示：

```json
{
  "catalogDigest": "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684",
  "operations": [
    { "operationReference": "observe.device@1", "state": "realDevicePass", "jobIDs": ["job-…"] },
    { "operationReference": "input.tap@1", "state": "notExercised", "jobIDs": [] }
  ]
}
```

`state` 只有 `realDevicePass`（当前 digest 上至少一个 `succeeded` 且 `outcomeUnknown == false`
的 Job）与 `notExercised`；不从旧 digest、fixture 或 contract test 推断。

同一 PR（docs-only，声明 `TASK-AIN-021`）同时：在 `real-device-validation.md` 追加一节指向
该 JSON；把产品规格 §13.2 的 GJ 行改为按 Journey 逐条写四态并附覆盖矩阵摘要
（`realDevicePass` 计数 / 29；全部 `REAL_DEVICE_PASS` 时删除该行，并在 §13.1 记录 digest、
日期与矩阵摘要）；`PRODUCT-LOOP.md` 的 Journey 状态由维护者
另行更新。任何一条为 `BLOCKED_BY_PRODUCT_DEFECT` 时，把失败 envelope 原文（脱敏后）与
复现 argv 写进 `notes`，并按「一个问题 = 一个垂直产品任务」开修复 Task，不在 CLI 里补
执行器绕过。
