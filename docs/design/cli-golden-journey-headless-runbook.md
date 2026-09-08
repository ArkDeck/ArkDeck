# CLI headless Golden Journey rerun runbook

本轮验收：TASK-SVC-005；历史入口：TASK-AIN-021（产品规格 §13.2、§15.3、§18；
`PRODUCT-LOOP.md` §6）。

GJ-1～GJ-5 必须有**当前发布构建与 Catalog digest** 上的 headless 结果，并按
`PRODUCT-LOOP.md` §6 的四态逐条记录。机器门
（`openspec/contracts/cli-feature-coverage.json` 的 `summary.fullFunction`）不替代真机证据。
先核对现有 Runtime 记录及其构建适用性，只重验本轮变更影响或尚未通过的部分，说明原因；
不得只因 Catalog digest 相同就把旧协议、旧构建的结果标成本轮通过。

本文只描述 CLI 与 Runtime 的已发布面；不含 raw HDC、外部 shell、authority 写入或
unknown replay。任何一步需要绕过这些面，就是 `BLOCKED_BY_PRODUCT_DEFECT`，记录原文后停止。

## 0. 约定

- 每条命令都带 `--output json`，stdout 原样保存到
  `/private/tmp/arkdeck-gj-headless-<date>/<journey>-<step>.json`（不入仓）。可入仓的是
  §7 的脱敏元数据。这只是输出目录，不是新的 Runtime state 目录。
- 控制面命令给一个可读的 `--control-request-id`（如 `gj1-doctor`），失败 envelope 的
  `meta.controlRequestId` 与之对应；`--version` 与本地 `runtime service` 命令不接受此参数，
  保留它们自动生成的 ID。每个新操作有独立 `--execution-id`，后续从该 ID 读取状态，
  人工动作后消费 Runtime 给出的 `resumeReference`。
- 四态只能是 `NOT_STARTED` / `IMPLEMENTING` / `BLOCKED_BY_PRODUCT_DEFECT` /
  `REAL_DEVICE_PASS`；`REAL_DEVICE_PASS` 只在当前 digest 上成立。
- `agent run/status` 的 `result.state` 是 execution 状态；operation 结果读取
  `result.job.state` 与 `result.evidence`，也可用 `job result/evidence` 重取。
  下文的 `terminalState`、`actualStepKinds`、`blockers` 均指 Job evidence 字段；
  §7 的 `evidenceBlockers` 是脱敏记录的字段名，取自实际 `evidence.blockers`。
- 任何 `outcomeUnknown` / `reconcileRequired` 先读 `job show/evidence`；确认当前发布实现遵守
  完整证明要求后，才用 `arkdeck job reconcile --job <id>` 做独立读回，不重放请求。
  任何 `humanActionRequired` 都走 `human-action show` → `agent resume --resume-reference`；
  两者都记进元数据，不算失败也不算通过。HAR 的 crash-resume 能力本身是 §2.1 的判据。
- 所有设备 operation 都用 `agent run --operation <id@version>`，人工动作后用 `agent resume`。
  `debug hap`、`debug native deploy`、`flash run` 等便捷名称不作为本轮验收的替代入口。
  查询、import 与首次接管仍使用各自已发布的 typed resource 命令。
- `deviceMutation` / `destructive` 由 protected-main Runtime 按 `POL-AGENT-002` 从完整
  materialized plan 和 fresh trusted facts 生成、reserve、consume RuntimeCapability。
  ArkForge 的 named hardware campaign 只选择已发布的硬件验收 qualification，不能替代
  Runtime authority。获得本轮真机验收授权时可使用 §5 的命名 staging 路径，保留
  `hardwareCampaign` 分类；不提供旧 campaign authority 字段或管理 capability，也不以
  人工确认替代完整证明。
  unknown 不等于零执行；`actualStepKinds: null` 不得解释成没有执行。只有
  `POL-RECOVERY-001` 的机械证明成立时 Runtime 才能独立 complete-overwrite recovery；
  缺证明时零新 dispatch，不清空状态、换 state 目录、改 evidence 或补写证明。
- 负向用例的台账核对：调用前后 `arkdeck job list --page-size 1000 --output json`，
  有后续 cursor 时读完所有页，比较完整 `items` 数量与 `jobId` 集合。结合 Runtime 给出的
  零新 dispatch 证明判断；仅最新 Job 相同、空步骤列表或未创建新 Job 均不能替代执行事实。

固定事实（写元数据时逐项核对，不从记忆抄）：

| 事实 | 读取方式 |
|---|---|
| Catalog digest 与 operation 集合 | `arkdeck operation list --output json` → `result.catalogDigest` 及实际返回的 operation；与本轮 protected-main 构建生成的 Catalog 核对，记录 canonical operation 数及每项 availability，不从文件数或历史 29/30 推算 |
| Runtime 构建与可执行文件哈希 | `arkdeck runtime service status --output json`、`arkdeck runtime bundle list --output json`；与已验证发布包的完整 protected-main commit 配对记录 |
| CLI 构建 | `arkdeck --version --output json` → `buildIdentity` |
| 目标与 binding revision | `arkdeck target show --target <TGT> --output json`；记录本次读取值，刷机后的 revision 必须重新读取 |
| HDC 选择 | `arkdeck runtime tool list --output json`、`arkdeck runtime hdc status --output json` |

## 1. 前置（窗口开始前 15 分钟）

```text
arkdeck doctor --deep --require-healthy --output json
arkdeck runtime service status --output json
arkdeck runtime hdc status --output json
arkdeck runtime tool list --output json
arkdeck operation list --output json
```

记录 `doctor` 的实际退出码与具名 findings；确认本轮要运行的 operation 可用，并核对
`operation list` 的 digest、operation 集合与该 published build 一致。某项 operation 不可用时，
记录具体条件，只停止依赖它的 Journey；不要求与本轮无关的 operation 全部 `available`。
需要正常模式的 Journey 还须由 HDC status 与 target availability 确认当前 DAYU200。
Runtime 不是预定 protected-main 构建时，先按
`openspec/changes/chg-2026-025-ai-native-unattended-device-ops/evidence/host-prerequisites/installation-runbook.md`
（`runtime bundle register` → `runtime service update` → `runtime service verify`）更新到
protected `main` 的 Runtime，再继续；这一步不是 Journey 的一部分。
`runtime service verify` 不带 `--job` 会新执行一次 observe，并非被动健康查询。
本轮在 §2 的 `agent run` 成功后使用 `runtime service verify --job <observe-job-id>`
读回同一份结果；不以该命令隐式新建的操作替代 `agent run` 验收。

若 `runtime service status` 仍报告 `workspaceProjectPath` / `devecoSDKPath`，它们是旧版
LaunchAgent 注入，不是当前 Runtime-owned workspace 注册。用当前拼写执行一次
`arkdeck runtime service update --output json`（需要替换 helper 时同时传已验证的 `--daemon`），
省略这两个 legacy path 参数；更新回执和 status 应不再含这两个字段，`workspace project list`
及 `workspace preset list --project <ref>` 的注册资源必须保持不变。冻结的 `agentd update` 省略
参数时仍保留旧值，只用于兼容验证，不能用来完成这项迁移。

输入物料（放在 `/private/tmp/arkdeck-gj-headless-<date>/inputs/`）：

- GJ-2：已签名单入口 HAP（08-28 记录用的同一包可复用），`bundleName`/`abilityName`；
- GJ-3：已签名 `armeabi-v7a` `.so`（见 `arkdeck-gj3` 记录）、`targetBundle`、
  `libraryLogicalName`；
- GJ-4：`OpenHarmony-7.0.0.37` 归档，SHA-256
  `4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674`（730 783 514 字节）；
  实际 import lease、设备身份、binding 与 full-restore plan 由 Runtime 准入时核对，
  归档存在或人工同意本身均不授权刷机；
- GJ-5：已注册的 `openharmony` 项目与 build/signing preset（`workspace project list`、
  `workspace preset list --project <ref>`）、crash-probe fixture 工程与其已签名 HAP
  `inputs/crash-probe-signed.hap`，以及**固定的修复补丁** `inputs/gj5-fix.patch`（run-r2 落地的
  形态：只删 `EntryAbility.ets` 中 `armCrashProbe()` 的调用与 import，共 -3 行，不翻
  `FixtureMode.MODE`）。补丁是输入物料，不在窗口内现场生成。

## 2. GJ-1 Device Observe（约 10 分钟）

```text
arkdeck device candidates --output json
# 未接管时：
arkdeck target adopt --candidate <key> --observation <observation-id> \
  --observation-generation <generation> --output json
arkdeck target show --target <TGT> --output json
arkdeck target availability --target <TGT> --output json
arkdeck agent run --operation observe.device@1 --target <TGT> \
  --execution-id gj1-<date> --maximum-wait 5m --output json
arkdeck agent status --execution-id gj1-<date> --output json
arkdeck job result --job <job-id> --output json
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
arkdeck runtime service verify --job <job-id> --output json
```

`observe.device@1` 的唯一输入 `refreshServerFacts` 默认 `true`，不需要 inputs 文件。
判据：`terminalState == succeeded`、`outcomeUnknown == false`、`blockers == []`、
3 个 Artifact 全部可 `artifact read`（经 digest 校验）。

`PRODUCT-LOOP.md` §6 GJ-1 的「bounded HiLog → UI Dump」两跳由设备级 `capture.diagnostics@1`
承接（GJ-2 的采集是 app-scoped，不算）。`gj1-capture.json` 只给必填项：缺省即 HiLog + UI Dump，
effect 停在 `readOnly`，不需要 capability：

```json
{ "durationSeconds": 5 }
```

```text
arkdeck agent run --operation capture.diagnostics@1 --target <TGT> \
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
arkdeck device candidates --output json
# 2. 不带 --target 启动 execution：Runtime 持久化 physicalConnection（connectDevice）HAR
arkdeck agent run --operation observe.device@1 \
  --execution-id gj1-<date>-har --maximum-wait 10m --output json
# 3. 模拟客户进程在拿到 receipt 后崩溃：丢弃步骤 2 的 stdout，不从中抄任何 resumeReference
# 4. 插回 USB，只用 execution ID 重取
arkdeck agent status --execution-id gj1-<date>-har --output json
arkdeck human-action list --owner-kind agentExecution --owner gj1-<date>-har --output json
arkdeck human-action show --human-action <id> --output json
arkdeck agent resume --resume-reference <ref> --output json
arkdeck agent status --execution-id gj1-<date>-har --output json
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
arkdeck agent run --operation debug.hap@1 --target <TGT> --inputs-file gj2.json \
  --execution-id gj2-<date> --maximum-wait 10m --output json
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
arkdeck agent run --operation deploy.native-library.app-owned@1 --target <TGT> \
  --inputs-file gj3.json --execution-id gj3-<date> --maximum-wait 10m --output json
arkdeck job wait --job <job-id> --output jsonl
arkdeck job evidence --job <job-id> --output json
```

判据：ELF/ABI/Build ID/hash 校验、受控 staging、远端 hash、原子发布、进程重启、
`hashProcessAndMaps` 加载验证全部 `verified`。rollback 腿需由 Runtime 在发布后的确定性
验证失败中自动执行，evidence 必须证明备份已回滚且目标进程恢复。先核对固定失败夹具的
签名、ABI 与当前目标适用性，再以独立 execution 提交。ABI 不匹配若在准入前拒绝，只证明
该负向输入被拒绝，不能充当 rollback 通过。没有适用夹具或未到达回滚路径时保留未验；
不人为制造 unknown。

## 5. GJ-4 Flash Recovery（约 15 分钟，其中擦写约 3 分钟）

```text
arkdeck flash device-access --output json
arkdeck flash bootloader-status --output json
arkdeck flash prerequisites --target <TGT> --device-profile dayu200 --output json
arkdeck flash install-binding --output json
arkdeck artifact import flash-bundle --import-request-id gj4-<date> --target <TGT> \
  --file inputs/OpenHarmony-7.0.0.37.tar.gz --device-profile dayu200 --output json
arkdeck flash lane-preview --target <TGT> --device-profile dayu200 \
  --archive-sha256 4fd35765fa75b9e2ce7c11f614144804f72efdc955a197e657014df1349ac674 --output json
arkdeck flash bind-loader --target <TGT> --expected-binding-revision <n> --output json
```

`flash install-binding` 建立首次接管所需的 durable cross-mode binding。已存在有效 binding
时保留它，先读回核对。2026-09-07 曾因缺少该前置停在 `waitingForRecovery`、
`outcomeUnknown`，daemon 侧的原话是
`Rockchip binding requires Runtime Loader onboarding: storeFailure("previous target binding
lineage is missing or ambiguous")`。Job 没有记录 step kind 不证明零执行。

它必须在板子处于 **hdc-normal** 时执行：cross-mode 别名的两半都描述 hdc-normal 人格，而
DAYU200 在两种模式下 serial 与 IOKit topology 都可能不同。板子若已在 Loader，
`install-binding` 会拒绝并报 `durable binding differs from the only connected Loader;
explicit rebind is required`。保留原 binding 与拒绝结果；不得用 `--rebind` 覆盖缺失的
identity/lineage 证明或解除 unknown。首次接管需要人工物理动作时，按 Runtime 发布的
human action 完成后 `agent resume`；没有可用产品路径时记录 `BLOCKED_BY_PRODUCT_DEFECT`。

`gj4.json`：

```json
{
  "artifactLease": "<lease>",
  "deviceProfileRef": "dayu200",
  "intent": "fullRestore",
  "verification": "full"
}
```

先读取 `runtime service status` 的已验证 ArkForge bundle 配置与 `operation list`。
若仅因空 campaign 报 `hardwareGated`，在已获授权的本轮硬件验收中可以使用已有发布配置面：
先确认没有正在派发或等待人工动作后继续的工作；update 会重启 daemon，所有已 durable
的 unknown 记录必须保留。

```text
arkdeck runtime service update --daemon <absolute-verified-published-helper.app> \
  --hdc <absolute-current-verified-hdc> --arkforge-bundle <absolute-validated-ArkForge.bundle> \
  --arkforge-campaign gj4-<date> --output json
arkdeck runtime service status --output json
arkdeck operation list --output json
```

此命名只开启该 bundle 的 `hardwareCampaign` qualification；不代表
`productionVerified`。显式固定已发布 helper 与 HDC，避免选择 CLI 旁的候选 helper，
随后核对其 hash、bundle 与 campaign 读回。设备请求仍须通过 materialization、fresh facts、完整 plan、精确
RuntimeCapability reservation/consumption 和 durable intent。旧
`campaignReservation` / `standingAuthorization` / `evolutionCampaignConfirmation` 不是
当前请求字段。若缺少机械事实或存在 unknown/lineage 冲突，保留 blocker；改 campaign
不能解除它们，不手工提供 capability 或补写证明：

```text
arkdeck agent run --operation flash.full-restore@1 --target <TGT> --inputs-file gj4.json \
  --execution-id gj4-<date> --maximum-wait 30m --output json
arkdeck job wait --job <job-id> --output jsonl
arkdeck job evidence --job <job-id> --output json
```

结束 staging 时重跑相同 update，保留显式 `--arkforge-bundle` 并省略
`--arkforge-campaign`，读回 `campaign: ""`；两项都省略会保留旧值，字符串 `none` 也不是清除值。

判据：当前 Job evidence 的 `actualStepKinds` 含 `waitForReconnect`/`probeDevice`/`flashPartition`/`verifyRemoteState`/
`rebootDevice`/`captureRemoteStdout`；machine readback 为 `OpenHarmony-7.0.0.37`；
`outcomeUnknown == false`、`humanActions == []`、`outstandingResidueCount == 0`。
随后完成 §6 的「重新发现并接管设备 → 恢复正常 Debug Runtime」：

```text
arkdeck device candidates --output json
arkdeck target show --target <TGT> --output json        # binding revision 若前进，记录新值
arkdeck agent run --operation observe.device@1 --target <TGT> \
  --execution-id gj4-<date>-postflight --maximum-wait 5m --output json
```

记录 Runtime 的实际 capability/reservation/epoch 引用及 postflight 结果，不修改这些记录；
历史 unknown 保持原状。独立 recovery 只有在 Runtime 发布完整证明和 supersession 后
才记录为已完成，不能把原始 unknown Job 重标成功。

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
arkdeck agent run --operation debug.hap@1 --target <TGT> --inputs-file gj5-repro.json \
  --execution-id gj5-<date>-repro --maximum-wait 10m --output json
arkdeck job evidence --job <job-id> --output json
arkdeck artifact list --job <job-id> --output json
arkdeck artifact read --job <job-id> --artifact <crash-index ART> --output json
arkdeck agent run --operation analyzer.extract-crash-signature@1 --target <TGT> \
  --inputs-file gj5-crash.json --execution-id gj5-<date>-analyze --maximum-wait 5m --output json
arkdeck agent run --operation workspace.prepare-isolated-copy@1 --inputs-file gj5-isolate.json \
  --execution-id gj5-<date>-isolate --maximum-wait 15m --output json
arkdeck artifact import workspace-patch --import-request-id gj5-<date>-patch --target <TGT> \
  --file inputs/gj5-fix.patch --output json
arkdeck agent run --operation workspace.apply-patch@1 --target <TGT> --inputs-file gj5-patch.json \
  --execution-id gj5-<date>-patch --maximum-wait 5m --output json
arkdeck agent run --operation workspace.build-openharmony@1 --inputs-file gj5-build.json \
  --execution-id gj5-<date>-build --maximum-wait 15m --output json
arkdeck agent run --operation workspace.sign-openharmony-hap@1 --target <evolution-…> \
  --inputs-file gj5-sign.json --execution-id gj5-<date>-sign --maximum-wait 10m --output json
arkdeck artifact export --job <sign-job> --artifact <signed ART> --allow-sensitive \
  --destination inputs/signed --output json
arkdeck artifact import hap --import-request-id gj5-<date>-verify --target <TGT> \
  --file inputs/signed/<signed>.hap --output json
arkdeck agent run --operation debug.hap@1 --target <TGT> --inputs-file gj5-verify.json \
  --execution-id gj5-<date>-verify --maximum-wait 10m --output json
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
再 `artifact import hap --target <TGT>` 才能进 `debug.hap@1`。副本是 Runtime 自有的任务副本，
其变更仍由当前 Catalog、精确 revision/scope 与 Runtime 准入控制；不向原项目扩展写入范围，
不添加人工 grant。副本不单独注册：它的 Job 取用来源项目
（`demo-app`）的注册、preset 与 toolchain pin，所以 `buildPresetRef`/`signingPresetRef`
仍是 `workspace preset list --project demo-app` 里的引用。daemon 重启后副本由
`adoptRuntimeWorkspaces` 重新登记。若副本引用解析失败，先用原 isolation 的 execution ID
读取 `agent status` 和 `job result`；不能靠重提操作解除不确定状态。已完成结果无法重开时，
记录产品缺陷并修复该读回路径。

负向用例（零派发）：同一补丁 lease、`expectedWorkspaceRevision` 取已被取代的 revision，
以独立 execution ID 通过 `workspace.apply-patch@1` 提交。记录当前 Runtime 的具名拒绝、
`newDispatchCount` 证明和 §0 的完整 Job 集合前后对照；最新一条 Job 相同本身不足以证明
集合未变化。2026-09-02 的候选 CLI/domain leaf 结果是历史参考，不能作为当前 `agent.run`
路径的输出或本轮验收结果。

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

先比较本轮 published Catalog 与上次通过构建的实际差异。`CHG-2026-073` 的
`debug.template@1` 是历史新增 operation；本轮是否需要补验以当前覆盖记录为准，
不能把它假定成任意两次 digest 的唯一差异。

```json
{ "templateId": "device.uptime" }
```

```text
arkdeck debug template list --output json
arkdeck agent run --operation debug.template@1 --target <TGT> --inputs-file gj-template.json \
  --execution-id gj-template-<date> --maximum-wait 5m --output json
arkdeck job result --job <job-id> --output json
```

判据：`template list` 返回的 `templateId` 集合与 `operation describe --operation debug.template@1`
的 enum 一致；Job `succeeded`、effect `readOnly`、Artifact 可读且非空。结果只进 §7 的覆盖矩阵。

## 6b. App 呈现（约 10 分钟，不产生任何 Job）

TASK-SVC-005 Deliverable 3 要求验证设备/导入/任务/History/Settings 的 App 呈现。
本节只读取生产 Runtime 已有结果；headless operation 仍在前面的 Journey 中执行。
`AppShellUITests` 的纯呈现 opt-in 不提交 operation，这个边界不适用于同一 target 中的
所有设备测试。

**目标名不是目录名。** 源码在 `ArkDeckAppUITests/`，但 XCUITest target 叫
`ArkDeckHDCUITests`（`ArkDeck.xcodeproj/project.pbxproj:485`），`-only-testing:` 只认后者。

**必须走 `scripts/ci/run-ui-tests.sh`**，它负责 ad-hoc 签名、独立 DerivedData 和键盘布局守卫；
裸 `xcodebuild` 的失败形态看起来像机器坏了。UI 栈是**全机唯一**的（一个 testmanagerd、一个前台，
`scripts/ci/run-ui-tests.sh:152-155`），窗口期间不要与任何其他 UI 跑道并行。

**开关必须带 `TEST_RUNNER_` 前缀，否则 opt-in 测试会跳过。** 例如 History Viewer
需要同时提供 startup gate 和精确 Job ID：

```sh
TEST_RUNNER_ARKDECK_REAL_DEVICE_STARTUP_ACCEPTANCE=1 \
TEST_RUNNER_ARKDECK_REAL_DEVICE_VIEWER_JOB_ID=<jobId> \
sh scripts/ci/run-ui-tests.sh \
  -only-testing:ArkDeckHDCUITests/AppShellUITests/testRealDeviceHistoryReopensExactViewerCapture
```

### 读取真实 Runtime 的纯呈现 opt-in

以下测试没有启用 fixture；缺少各自前置时会 `XCTSkip`，必须记录为未执行。

| 开关（记得加 `TEST_RUNNER_` 前缀） | 测试 | 覆盖面 |
| --- | --- | --- |
| `ARKDECK_REAL_DEVICE_STARTUP_ACCEPTANCE=1` | `ArkDeckHDCUITests/AppShellUITests/testRealDeviceColdStartShowsConnectedDeviceWithinTwoSeconds` | 设备（冷启动 ≤ 2 s） |
| `ARKDECK_REAL_DEVICE_STARTUP_ACCEPTANCE=1` **及** `ARKDECK_REAL_DEVICE_VIEWER_JOB_ID=<jobId>` | `ArkDeckHDCUITests/AppShellUITests/testRealDeviceHistoryReopensExactViewerCapture` | History（重开精确 capture 的 screenshot 和 component tree） |
| `ARKDECK_REAL_DEVICE_DIAGNOSTICS_JOB_ID=<jobId>` | `ArkDeckHDCUITests/AppShellUITests/testRealDeviceDiagnosticsReopensExactCaptureAndItsTraceInBothLanguages` | History + 任务（双语） |
| `ARKDECK_REAL_DEVICE_HILOG_EXPECTATIONS=<path>` | `ArkDeckHDCUITests/AppShellUITests/testRealDeviceHilogSummariesReopenInOneSessionPerLanguage` | History（hilog 摘要） |
| `ARKDECK_REAL_RUNTIME_UNKNOWN_FLASH_JOB_ID=<jobId>` | `ArkDeckHDCUITests/AppShellUITests/testRealRuntimeHistoryKeepsUnknownFlashEvidenceInspectableInBothLanguages` | History（保留 unknown Flash 的事实和“未报告”步骤，双语） |
| `ARKDECK_REAL_RUNTIME_STORAGE_STATUS=<path>` | `ArkDeckHDCUITests/AppShellUITests/testRealRuntimeStorageSettingsMatchReadbackInBothLanguages` | Settings（与当前 CLI 读数比较，取消目录选择后保持设置，双语） |

- Cold start 需要当前已观察并接管的设备，断言设备行在 2 秒内显示。
- Viewer 和 Diagnostics 的 `<jobId>` 必须是已完成的 `capture.diagnostics@1`。Viewer
  需要 screenshot 与 component tree；Diagnostics 还需要完整 HiLog 与可解析的 Trace，
  并断言该测试所针对的未对齐状态。GJ-1 默认 HiLog/UI Dump 采集没有这些全部材料，
  不能随意填进两个 opt-in。优先复用适用的 headless 记录；缺材料时先按当前 Catalog 的
  typed inputs 完成 headless capture，核对实际 effect 与 Runtime 准入后再做呈现验证。
- HiLog expectations 是本地小于 32 KiB 的 JSON 数组，恰好列出三个不同的已完成分析 Job，
  每项含 `jobID`、`sourceArtifactID`、`headerCoverage`、`lineCount`、`levelCounts`。
  数值从真实 Runtime 结果读取，不能填 fixture 期望值。
- Unknown Flash 使用已存在且仍为 unknown、步骤未报告的 Job，仅检查呈现；不为这个
  测试制造新的 unknown，也不以测试通过证明 Flash 或 recovery 成功。
- Storage status 文件是测试前原样保存的 `arkdeck runtime storage status --output json`
  成功结果。测试只比较 root/quota/margin/retention，并打开后取消目录选择；不保存设置。
  测试后再读相同命令，比较 `sessionDomain` 的 generation、root 与 policy，确认未改变。
  测试不覆盖实际更换存储根、Keychain 密码提示或签名材料更新。

### 不属于本节的测试

`DeviceStaleFrameUITests/testASecondPressOnASpentPictureIsRefusedAndNotSent` 会执行 capture、
首次 tap 和 recapture；只有第二次 tap 被断言为拒绝。
`DeviceRecordingUITests/testRealDeviceRecordingCapturesFortyFramesAndOffersALocalMovie`
会启动新的真实录屏。两者都需要 `ARKDECK_UI_TEST_DEVICE_REAL_DEVICE=1`，前者还需要
操作者已观察的安全触点；它们是设备操作验收，不能计为“零新 Job”的纯呈现验证或替代
本轮 `agent run/resume`。本节命令不运行这两套设备操作测试。

`SettingsStorageStateTests`、`RemoteBuildSourceStateTests`、`TraceFlagTagEditorTests`、
`HistoryFilterDependenciesTests` 编译进同一个 runner，但它们**从不构造 `XCUIApplication`**——
是编译进 UI runner 的 view-model headless 测试（`SettingsStorageStateTests.swift:6-7`：
「The controlled provider never reaches the Runtime, a device or the Keychain」）。它们绿了**不构成
任何 App 呈现证据**。普通 fixture 驱动的 App assertions 可以证明其呈现行为，结果须标明
fixture 类别，不能证明真实 Runtime 已通过相同链路。

### 本节仍覆盖不到的导入结果

- **导入**：现有断言没有读取一次真实 headless import 结果的 opt-in；headless import
  成功本身不证明 App 呈现。

这是需要明确处置的验收缺口，不是自动豁免。记录实际已完成的 App assertions、证据
类别和仍未覆盖的生产读数；若规定验收需要补充 assertion，按原实现 Task 的受控范围
交付最小补充，缺少路径时提出具体范围补充。补齐前不得把导入或 SVC-AC-10 标为全通过。

### 记录

App 呈现不套用 §0 的四态——四态属于 Journey。按测试逐条记 `pass` / `fail` / `未执行`，
附完整调用命令与 `xcresult` 路径。任何 App 侧失败按 §0 的产品缺陷规则处理：报
`BLOCKED_BY_PRODUCT_DEFECT`，用**原实现 Task 的 ID 与 Allowed paths** 提修复 PR，
合入后再验，不把代码修复塞进 TASK-SVC-005 的文档/evidence 权限。

## 7. 记录模板与落点

每条 Journey 一个对象（脱敏：只留 SHA-256、jobId、executionId、计数与 UTC 时间，不留
connectKey、序列号、原始输出）。

**落点由执行本轮的 Task 决定。** 记录必须写进该验收 PR 所声明 Task 在可信 base 上的
Allowed paths；其他 Task 拥有更宽路径不自动扩大本 Task 范围。

- 本轮（TASK-SVC-005）落在 `docs/design/references/single-v1/gj-headless-rerun-<date>.json`。
- 历史记录留在原处不动：`docs/design/references/v1.6-goal/gj-headless-rerun-2026-09-02.json`
  是 TASK-AIN-021 落的（#1701、#1707），不要为了统一路径去搬它。
- 换成别的 Task 执行时，先按同样方法确认落点在那个 Task 的 Allowed paths 内，再开跑。

记录形状如下；所有示例 ID、digest、revision、时间和计数均替换为实际读回值：

```json
{
  "date": "<YYYY-MM-DD>",
  "goldenJourney": "GJ-1",
  "state": "REAL_DEVICE_PASS",
  "evidenceKind": "redacted-metadata-derived-from-real-runtime",
  "catalogDigest": "<actual catalog SHA-256 from operation list>",
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

同一文件另含一个 `operationRealDeviceCoverage` 对象，本次 `operation list` 中的 canonical
operation 每个一行，记录总数及不可用原因，让
「全功能」的真机边界可见，而不是由五条 Journey 暗示：

```json
{
  "catalogDigest": "<actual catalog SHA-256 from operation list>",
  "operations": [
    { "operationReference": "observe.device@1", "state": "realDevicePass", "jobIDs": ["job-…"] },
    { "operationReference": "input.tap@1", "state": "notExercised", "jobIDs": [] }
  ]
}
```

`state` 只有 `realDevicePass`（当前 digest 上至少一个 `succeeded` 且 `outcomeUnknown == false`
的 Job）与 `notExercised`；不从旧 digest、fixture 或 contract test 推断。

本轮在 `TASK-SVC-005` 的同一验收 PR 中交付真实运行元数据、`evidence/runs/TASK-SVC-005/run.md`、
SVC-AC-01～10 结果和 Swift 契约基线。覆盖摘要使用本次读取的 operation 总数作分母。
按任务的 base-tree Allowed paths 做 preflight；不沿用 TASK-AIN-021 的历史文档写入范围。
任何一条为 `BLOCKED_BY_PRODUCT_DEFECT` 时，把脱敏后的失败原文、Runtime 引用与复现 argv
写进记录，并由原实现 Task 交付完整调用链修复；没有适用范围时提出最小具体补充。
不因单个 Journey、fixture 或 App assertion 通过修改整项 change 的批准或验证状态。
