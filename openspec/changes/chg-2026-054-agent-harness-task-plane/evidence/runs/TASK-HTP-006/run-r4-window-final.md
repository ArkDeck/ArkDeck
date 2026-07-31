# TASK-HTP-006 run r4 — GJ-5 有界取证循环在真机上一次 submit 自动收敛

- Date:2026-07-31(UTC 07:47–07:49)
- Executor:**agent**(维护者 2026-07-31 明确指示由 agent 执行本窗口)
- Source baseline:`main@421e835a`(#881 已合入)
- Device:DAYU200(RK3568),USB,`TGT-958780b2ffb7`,binding revision `1`
- 稳定身份 SHA-256:`958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
- HDC:`3.2.0f`,sha256 `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`
- **Catalog digest:`6b2191e87a71eb8a5bc11d3801c74d2ecf921261b9e7a836b57fc24ec894b076`**(当前)
- State dir:`/private/tmp/arkdeck-gj5-final`,0700
- HAP:`entry-default-signed.hap`,1,512,211 字节,sha256 `e873aeb0a0da520e…`
- E1 授权:`CAP-RT-AUTO-20260731T072452Z-DA607C97EE79`(经 **PR#881** 合入签发)

## 1. 结果

| 腿 | 结果 |
|---|---|
| L1 接管 + `observe.device@1` | **succeeded**(`job-debc3f91f1bfe166210ca2351a53ac22`) |
| L2 `debug.hap@1`(retain + **postRunAbilityState=running**) | **succeeded**(`job-ad0d2d2930b47def800909773694b6fa`),应用留在**运行态** |
| L3 GJ-5 一次 `task submit` | **succeeded**(`HTASK-8B0A5F8D2A2C`),六轮 evaluation,40 秒,**零 reconcile** |

## 2. L2:产品第一次能把应用留在运行态

```text
timeline(节选):
  capability consumed before first mutation
  send-hap verified [stagedAt] → install-hap → package-readback verified [bundleName, installed]
  start-ability → process-readback verified [bundleName, running]   ← 产品自己确认活着
  capture-diagnostics verified [byteCount] → artifact debug-hilog.txt
  skipped stop-ability: step not selected by the request inputs      ← 本轮新增输入生效
  skipped cleanup-uninstall: step not selected by the request inputs ← cleanupPolicy=retain
  cleanup-remote-staging verified [cleaned] → finalizing->succeeded
outstandingResidueCount: 0
```

授权面:`remainingUses: 0`,一条 consumption —— `effect: deviceMutation`、
`jobID: job-ad0d2d2930b47def800909773694b6fa`、`consumedAtUTC: 2026-07-31T07:47:30Z`。
**没有人、也没有 agent 直接跑过一条 HDC 命令**:安装、启动、读回、采集、清理全部由产品执行
(crib 对 hdc 的唯一调用是数设备台数的可用性探针,不属任何一条腿)。

## 3. L3:一次 submit,零 reconcile,真机收敛

```text
$ arkdeck task submit --target TGT-958780b2ffb7 --expected-binding-revision 1 \
    --goal "No fatal signature and a live application across five bounded captures"
submitted HTASK-8B0A5F8D2A2C     ← 此后脚本只读,一次 task reconcile 都没敲

[  0s] created   initializing round=0
[ 10s] running   deviceReady  round=2  job=job-8217a0ef19b975d6a7b74010e42583b2
[ 20s] running   collecting   round=4  job=job-107e006da3a6ebcc858420140d5b0cec
[ 30s] running   collecting   round=5  job=job-e2fcdccb7d58049626c07992ae1dab29
[ 40s] succeeded collecting   round=6
```

harness 自己派发的 job(全部 succeeded):`observe.device@1` ×1 +
`capture.diagnostics@1` ×5(`job-8217a0ef…`、`job-107e006d…`、`job-4325f670…`、
`job-af1b0a90…`、`job-e2fcdccb…`)。

样本门逐轮如实推进 —— **不是一次采集就宣布成功**:

```text
round 1  inconclusive  DC-1 samples=0
round 2  inconclusive  DC-1 samples=1  (DC-2/DC-3 已 pass)
round 3  inconclusive  DC-1 samples=2
round 4  inconclusive  DC-1 samples=3
round 5  inconclusive  DC-1 samples=4
round 6  pass          DC-1 samples=5  → verdict=pass, reasonCode criteriaPassed
```

末轮证据与测量:

```text
hilog.txt            852,165 字节  verified=true  sensitiveOptIn=true  sha256 477b8a9a1cea9a0d…
artifact-index.json      781 字节  verified=true  sensitiveOptIn=false sha256 94e60e077af5ca9e…
measurements: matchingCrashCount=0  newFatalSignatureCount=0  applicationLiveness=healthy
samples:      每项 5
未 opt-in / 未选中的 artifact 如实记为 blocker(ui-dump.json / ui-tree.json / trace.htrace),不参与判定
```

**接管后人工步骤 = 0**(submit 即交接);**reconcile 调用 = 0**;harness task 的
**E1 消耗 = 0**(`maxE1Mutations: 0`,全程只有 E0 operation)。

## 4. 窗口抓到并在同一任务内修掉的四个缺陷

1. **crib 在 macOS 自带 bash 上死掉**:`mapfile` 是 bash 4 内建,`/bin/bash` 是 3.2.57。
   自测当时跳过探针块 → 那行从未被执行。已改为 bash 3.2 实现,并让 `--self-test` 用
   fixture 覆盖该解析路径。
2. **flag 形 `job submit` 跑不了任何设备 operation**:请求缺 `expectedBindingRevision`。
   已由 `RuntimeOperationRequest.operatorFlagForm` 在提交前拒绝并点名缺的 flag(#875)。
3. **sensitive opt-in 只接了一半**:builder 被允许看,store 的 `read` 默认
   `allowSensitive: false` → 真跑得到 `evidenceIntegrity:artifactUnreadable:hilog.txt`,
   任务停在 `humanRequired`。已在 artifact port 强制同一份清单(两道门)。
4. **产品无法把应用留在运行态**:`stop-ability` 无条件执行 → GJ-5 只能在「应用没在跑」
   的设备上测 liveness。新增 `postRunAbilityState`。**第一版实现把该步标成 `optional`,
   套件立刻打回**:optional 同时决定失败是否可容忍,于是一次 `stopIneffective` 被记成跳过、
   job 仍报成功。改为 `stepIsRequested`(是否被请求)与 `isOptional`(失败是否容忍)分开。

另有一条**授权面的正例**如实记下(r3):demo 应用在起草与使用之间被重新构建,
`debug.hap@1` 因 `inputConstraintViolated: input hapArtifactLease violates constraint` 被拒,
**且拒绝发生在消耗之前**(旧凭据至今 `consumptionCount: 0`)。授权绑定的是字节。

## 5. 如实登记的边界(未覆盖的部分)

- **GJ-5 的「部署修复」腿未覆盖**:PRODUCT-LOOP 的 GJ-5 目标含 `部署修复 → 复验`,
  而 `DebugCrashTaskHandler.permittedOperations` 仍只有 `observe.device@1` 与
  `capture.diagnostics@1`(005 交付的五个 workspace operation 未接入)。**故 GJ-5 状态
  不改为 `REAL_DEVICE_PASS`,保持 `IMPLEMENTING`**;本轮关闭的是「有界取证循环」这一半。
- **fail → 交人路径在真机上无证据**:需要一次真实 crash。所用 demo 工程
  (WaterFlowLayoutDemo)**没有任何 crash 路径、也没有 native 模块**(ETS 源码无
  crash/abort/throw,最后改动 06-03),因此无法复现
  `SIGABRT+WaterFlowPattern::RecoverBack`。host 侧 fixture 已覆盖该判定(HTP-AC-5/6/7)。
- **`applicationLiveness` 的语义仍弱**:本轮应用**确实在运行**(L2 的 `process-readback`
  产品侧确认 + `stop-ability` 被跳过),所以这次 PASS 的**布置**是真实的;但该指标本身测的
  仍是「这次采集拿回了日志行」——`capture.diagnostics@1` 未按应用限定作用域(harness 不送
  `hilogFilters`)。要让 criterion 表达「我的应用活着」需要 task 输入面带应用身份,属
  input-surface 变更,不在本任务范围。
- **GJ-1 / GJ-2 未按各自完整口径重取**:本轮在当前 digest 上取得 `observe.device@1` 与
  `debug.hap@1` 各一次真机成功,但 GJ-1 的 daemon 重启后 readback、GJ-2 的
  stop+uninstall 收尾形态本轮未做(本轮刻意 retain + keep running)。**故两者状态也不改**。
- **设备遗留**:`com.example.waterflowdemo` 仍**已安装且在运行**(本轮授权只够一次
  `retain + running`)。恢复窗口前状态需要一份 `cleanupPolicy: uninstall` 的凭据,或由
  维护者在设备上手工卸载。
