# TASK-HTP-006 run r1(窗口前) — 让一次 submit 真的能自动收敛

- Date:2026-07-31
- Executor:agent(交互式会话),**host-only,零设备命令**
- Effect:hostOnly。本轮零 HDC dispatch、零设备操作、零 capability 消耗
- 设备窗口:**未执行**。HTP-AC-18 / AC-19 仍为 `pending-hardware`
- 当前 catalog digest:`da101ab62ec92f524b0a961a9bb91d0b436126a5a6aaa67626e1f86730988945`

## 1. 为什么先有窗口前一轮

规矩(`arkdeck-workflow-conventions`):crib 交付前 agent 必须 host 侧自测一切可测项,
设备窗口不消耗在脚本 bug 与产品缺口上。按这条规矩逐门实测,发现**三个产品缺陷**,
每一个都足以让整个 GJ-5 窗口只产出一次「安全停止」。

### 缺陷 1:没有任何东西转动曲柄(实测)

`task.submit` 只落盘并返回;`task.reconcile` 才推进一步;daemon 没有任何 tick。
host 实测:

```text
$ arkdeck task submit --target probe-target --goal "probe whether a submit advances by itself"
$ sleep 20 && arkdeck task status
status=created phase=initializing round=0 version=1
$ arkdeck task events
events: 0
```

即「一次 `task.submit` 自动收敛」当时不是产品的性质,而是**谁在不停敲
`task reconcile`** 的性质 —— HTP-AC-18 按字面不可能成立。

### 缺陷 2:唯一的取证 operation 永远进不了准入

`capture.diagnostics@1` 声明 `durationSeconds` **required**;handler 送的是
`inputs: [:]`(空表)。空表不是保守默认,是**不可运行**的默认:引擎按 descriptor 校验
输入即拒,于是 criteria 要求的 `hilog.txt` 永远采不到。

### 缺陷 3:必需证据被声明为 sensitive,而 sensitive 一律不可读

`capture.diagnostics@1` 的 `hilog.txt` 同时是 `required: true` 与
`privacy: sensitive`;`HarnessObservationBuilder` 对**任何** sensitive artifact 无条件
拒读(`artifactSensitiveNotOptedIn`),且仓内**不存在**任何 opt-in 机制
(`grep sensitiveOptIn|allowsSensitive` 零命中)。三条 mandatory criteria 全部以
`hilog.txt` 为证据要求,于是即使采集成功也永远 `inconclusive` → 轮数耗尽 → `failed`。

三者叠加:窗口跑完只会得到一次 `maxRoundsExhausted`,并且是 8 轮真机采集之后。

## 2. 修法

**曲柄**:新增 `HarnessAutoDriveTicker`(`ARKDECK_HARNESS_AUTODRIVE_SECONDS`,缺省关)。
一次唤醒对每个**可驱动**任务只做一次 reconcile(HTP-AC-1 的「至多一个 effectful
job」仍是进度单位,且任务之间不互相饿死);只驱动 `created`/`running` —— `humanRequired`
虽非终态但不可驱动(需人解),`paused` 是操作员刻意停的;连续 3 次抛错即放弃该任务并
记录,不无限自旋;不新增任何权限,每一步仍过 policy guard 与引擎。**默认关**是刻意的:
按定时器 dispatch 设备操作与只应答请求是两种安全姿态,该由操作员选。

**输入**:handler 按 operation 声明补齐 typed inputs(`durationSeconds: 20`,在 descriptor
的 [1,600] 内);**不送 `traceCategories`** —— 它会把有效 effect 抬到 deviceMutation,
而本 task type 声明 `maxE1Mutations: 0`。另加结构性回归:permittedOperations 里每个
operation 的 required 字段都必须被 planned step 覆盖,且不得出现 operation 未声明的字段。

**证据**:`sensitiveEvidenceAllowList`(按 **artifact 名**,不是开关;
`ARKDECK_HARNESS_SENSITIVE_EVIDENCE=hilog.txt`),缺省空。命名后 evaluator 才在**本机**
测量它;evidence 记录新增 `sensitiveOptIn` 字段,让 reviewer 能区分「没看过这些字节」
与「操作员允许测量了这些字节」—— 同一个 digest 的两种不同断言。出站面不变:
decision context 仍只带 artifact 身份与摘要前缀(TASK-HTP-004)。旧记录无该字段,
解码为 `false`(当时不可能 opt in)。

**一处注释纠正**:`hasApplicationOutput` 原注释称「capture 由 operation 按应用限定作用域」
—— 不送 `hilogFilters` 时并不成立。已按代码实际含义重写(见下「如实登记的边界」)。

## 3. 套件与进程级自测

```text
swift test --package-path Packages/ArkDeckKit          # base = main fd20f23d
Executed 907 tests, with 1 test skipped and 0 failures (0 unexpected)
新增 HarnessConvergenceContractTests 13 例(每个缺陷:先复现,再证明修好)
```

进程级(host,真实 UDS + 真实引擎,零设备):

```text
$ ARKDECK_HARNESS_AUTODRIVE_SECONDS=2 ARKDECK_HARNESS_SENSITIVE_EVIDENCE=hilog.txt \
    arkdeck-agentd --state-dir /private/tmp/adh-006-autodrive
harness may measure sensitive evidence: hilog.txt
arkdeck-agentd listening on …
harness auto-drive every 2s

$ arkdeck task submit --target probe-target --goal "auto-drive turns the crank" \
    --expected-binding-revision 1        # 之后一次 reconcile 都没敲
$ sleep 8 && arkdeck task status
status=humanRequired phase=initializing version=3
$ arkdeck task events                     # 无任何外部推动
created -> running       | taskAdmitted
running -> humanRequired | operationUnavailable:observe.device@1
```

曲柄自己转了(两条事件),且在 `humanRequired` 处**停住**而不是自旋 —— 这台 host 没配
HDC,`observe.device@1` 如实 unavailable,正是 PRODUCT-LOOP §8 的行为。

## 4. 窗口计划(维护者 2026-07-31 决定:同窗重取 GJ-1/GJ-2,装 demo 应用复现 WaterFlow crash)

四腿一窗,顺序由一条**产品事实**决定:

| 腿 | 内容 | 断言 |
|---|---|---|
| L1 | 接管 + `observe.device@1`(当前 digest) | GJ-1 在 `da101ab6…` 上重取 |
| L2 | 导入签名 HAP + `debug.hap@1`(`cleanupPolicy: retain`) | GJ-2 在当前 digest 上重取,且包留在设备上 |
| L3 | 应用在跑、**尚未** crash → 一次 `task submit` | GJ-5 的 PASS 路径(非空洞:有真实应用输出) |
| L4 | 复现 WaterFlow crash 后 → 一次 `task submit` | GJ-5 的 fail→交人路径 + AC-7 真机字节面 |

**L3 必须在触发 crash 之前**:`capture.diagnostics@1` 把 HiLog 降为 `hilog -x`
(实测源码:`["shell", "hilog", "-x"] + filters`),它**dump 整个滚动缓冲**而不是 tail 一个
窗口。fault block 一旦进缓冲,就会出现在**之后每一次**采集里,五个干净样本在缓冲滚掉之前
不可达。两腿顺序颠倒就会白费窗口。

**人工步骤(全部在交接之前,不在环里)**:

1. **在设备上启动应用** —— 没有任何产品 operation 会把 ability 留在运行态:
   `debug.hap@1` 的 `stop-ability` 步骤**不受 `cleanupPolicy` 门控**(只有
   `cleanup-uninstall` 受),所以 `retain` 只保留安装、不保留运行;
2. **做出复现 WaterFlow crash 的手势**(L4 之前);
3. **两次 `task submit`** —— 它们**就是**交接点。

**E1 授权是两趟**:capability 钉 `exactPlanDigest` 与逐输入的精确值(含只有导入后才存在的
artifact lease),所以不可能预先写好。第一趟 `--hap` 跑到 `capability draft` 就停(draft 的
`issuer.reference` 是 `PENDING-MAINTAINER-PR`,daemon 的 `capability.install` 只接受
`PR#<数字>` —— 这条拒绝正是「签发是维护者的行为,不是 agent 的」的结构形式);维护者把
draft 落到本 change 的 `evidence/capabilities/`、把 `issuer.reference` 改成
`PR#<号>`、**合入即签发**;第二趟带 `--capability` 跑完 L1..L4。teardown 的
`cleanupPolicy: uninstall` 是另一组输入,需要**第二份** capability。

## 5. 交给设备窗口的 crib

`crib-gj5-window-r1.sh`:唯一人工步骤是 `task submit`,之后脚本**只读**、
**从不调用 `task reconcile`**(「收敛」因此不可能是操作员转的曲柄);从不读/导出
artifact 字节(HiLog 是 sensitive,窗口需要的是 harness 在本机**测量**它);
除「数一下接了几台设备」这一条可用性探针外,不自己发任何设备命令 —— 发现/接管/观测/
采集全部走产品;打印一律经 `mask()`,序列号不进 transcript。

host 侧已自测:`bash -n` 通过;`--self-test --hdc /usr/bin/true` 跑通 daemon 启动、
socket、`doctor`(digest = `da101ab6…`)、`operation list` 解析;`debug.hap@1` 的请求文档
生成块单独跑通并逐键校验(`documentType`/`schemaVersion`/`requestId`/`idempotencyKey`/
`target`/`operation`/`inputs`/`authorization.capabilityId`)。

**自测抓到三个脚本 bug,全部按源码而非猜测修正**:

1. 初版从 `device list` 读 candidate —— 而 `device list` = `target.list`,只返回**已接管**
   target(`targetId`/`bindingRevision`/`toolVersion`/`adoptedAtUtc`);candidate 在
   `device adopt` 的 `needsSelection` 回复里。已按三种真实回复形态(`adopted` /
   `needsSelection` / `waitingForHuman`)分别处理;
2. 初版手写的 `debug.hap@1` 请求缺 `documentType`/`schemaVersion`/`requestId`/
   `idempotencyKey`,并把 capability 放在 `capabilityId` 顶层 —— 真实结构是
   `authorization: {capabilityId}`(见 `RuntimeOperationRequest`);
3. 初版把 `hapArtifactLease` 填成 `artifactId` —— 导入回复同时给 `artifactId` 与
   `lease`,该输入要的是**lease**。

这正是「窗口不该消耗在脚本 bug 上」。

## 5. 如实登记的边界(窗口前必须先看)

- **HTP-AC-18 / AC-19 仍是 `pending-hardware`**。本轮零设备命令,不写任何真机结论,
  更不动 GJ-5 状态;
- **§20 硬门与 digest**:GJ-1 / GJ-2 的 `REAL_DEVICE_PASS` 取自 2026-07-30、catalog digest
  `3455e050…`;当前 digest 是 `da101ab6…`(007 与 005 各改过 catalog)。按 PRODUCT-LOOP
  「`REAL_DEVICE_PASS` 必须在当前 catalog digest 上取得;旧 digest 的真机记录只证明历史」,
  这两条现在**不在当前 digest 上**。crib 的接管段本身就是 GJ-1 的 observe 腿,可在同一
  窗口内于当前 digest 上重新取得;GJ-2(HAP debug,E1)需要单独一腿与维护者经 merged PR
  签发的 standing capability。**窗口内容(是否同窗重取 GJ-1/GJ-2)是维护者的决定**;
- **`applicationLiveness` 的真实含义**:不送 `hilogFilters` 时,capture 不按应用限定
  作用域,该指标测的是「这次采集拿回了日志行」。因此在**没有被调试应用运行**的设备上,
  三条默认 criteria 会以「无 fault block + 有日志行」通过 —— 这是一次**空洞的 PASS**。
  要让窗口的 PASS 有意义,设备上必须有被调试应用在跑(理想情况:能复现一次真实 crash,
  再由 evaluator 判 fail → 交人);让 criterion 能表达「我的应用活着」需要 task 输入面
  新增应用身份,属 input-surface 变更,不在本任务范围;
- **E1**:仓内 11 份 capability 记录全部 scope 在 `debug.hap@1` /
  `deploy.native-library.app-owned@1`,最晚一份 2026-07-31T10:16:59Z 到期。本轮 host-only
  未消耗任何 capability;窗口若含 patch → build → 部署腿,需维护者另行签发,Agent 不自签;
- **未修的相邻缺口**:`DebugCrashTaskHandler` 的 `permittedOperations` 仍只有
  `observe.device@1` 与 `capture.diagnostics@1`,即 005 交付的五个 workspace operation
  还没有接进修复腿(handler 在 `patching/building/deploying` 相位如实回
  `workspaceOperationsUnavailable`)。AC-18 把 patch/build/部署 列为「可选」,故本轮不扩
  handler;这是 GJ-5 从「有界取证循环」走到「有界修复循环」的下一个产品缺陷。
