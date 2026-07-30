# TASK-DHA-001 run r2 — 合入后深检与 fail-closed 硬化

- Date:2026-07-29; product-closure continuation:2026-07-30
- Executor:agent
- Audit base:protected-main `915aa93`(#786 merge)
- Final rebase:`9637df1`(#796 merge;包含 #791/#792/#794 hardware evidence)
- Evidence class:contract / fake integration / static review
- Hardware status:`DHA-HW-001` observable runtime succeeded at attempt#2,
  formal acceptance `BLOCKED / NOT CLAIMED`;`DHA-HW-002` 未执行
- Product-closure base:`main@155fbb0a7b888b6b32eb5a8a4db4b38895fba9b9`
  + open PR #798 (`61eb305`);integration also incorporates the later
  main-only CHG-2026-051 archive commit `7ea596b`

## 触发原因

#786 合入后按真实调用链复查,发现 r1 evidence 对若干能力的描述超前于
代码:humanAction token 只是可读字符串且 resume 实际会重跑;HAP lease
被 provider 降为字面量 `<artifact-lease>`;capture 与 HAP 的远端路径按
step 随机生成,send/install/cleanup 不指向同一文件;失败没有执行 catalog
补偿;artifact 的内容-only 短 ID 会让同字节不同声明碰撞,索引与 symlink
负向也没有覆盖。r1 已追加 correction,原文保留用于审计。

## 本次修正

- Agent runner:
  - humanAction request、catalog digest、execution ID 与时间线持久化;
    `arkdeck agent resume --resume-token ... [--selection ...]` 恢复原执行;
  - request/idempotency ID 从稳定 execution ID 派生,恢复不会创建第二个
    runtime job;多 adopted target 不再猜第一个,structured action 直接
    给出 selection options;
  - 所有主动 daemon 调用共享 monotonic `maximumWaitSeconds` 总 deadline;
    `job.run` 失败或返回非终态时仅通过额外有界的 typed `job.cancel`
    请求收敛;终态失败返回 journal 的明确 reason;
  - E0 receipt 的 authority reference 绑定 default policy 与 catalog
    digest,paused catalog 漂移时拒绝恢复。
- Artifact/HAP:
  - artifact ID 绑定 job + 声明名 + 内容 hash;完全相同发布幂等,同名不同
    字节拒绝,相同字节不同声明不碰撞;首版 16-hex ID 保持可读/幂等兼容;
  - root/job/export symlink、畸形/重复 index、文件大小/hash 漂移均
    fail closed;
  - 新增无 host path 的 `lease-v1` 引用,engine 在授权前解析并复验
    Artifact;provider `send` 使用解析出的真实本地文件;
  - provider 以真实 runtime job ID 铸造稳定 owned path,capture/receive/
    cleanup 共享一条,send/install/cleanup 共享一条;路径改为现有
    `/data/local/tmp` 下的 job-isolated flat owned file,不依赖未声明的
    remote mkdir;
  - raw HiLog/UI dump/debug HiLog 保存 provider 捕获的真实 bounded bytes,
    不再用 byteCount JSON 冒充日志;daemon/CLI 补齐 `artifact.export`;
  - default/short-lived retention 分别落 7 天/24 小时 absolute deadline,
    GC 解析 UTC 后比较、跳过 active/pinned 并回收到期项。
- Runtime engine:
  - idempotency duplicate/conflict 在 capability 消耗前判定;
  - Catalog 的数值、长度、数组与 pattern bounds 在授权前校验;
  - `captureDiagnostics=false` 与 `cleanupPolicy=retain` 真实裁剪 optional
    step;失败按 cleanup policy 执行 typed stop/uninstall/remote cleanup,
    cleanup 失败登记 debt;
  - host quota 在 device dispatch 前预检;device storage 预检改为 typed
    `df -k /data/local/tmp` 语义解析,不再以 product model 查询冒充;job
    artifact byte budget 覆盖 raw 与 finalize 产物,超限不再写满 store;
  - WAL intent 记录实际 Artifact ID/hash 与精确 owned path;默认
    `installOrReplace` 降为 `hdc install -r`,nonzero install/start 在
    readback 前即失败,旧包或旧进程不能冒充本次执行成功;
  - unknown 记录原始 step,只用原 typed action reconcile,不再用通用
    `observeDevice` 猜测 mutation 已完成。

## 2026-07-29 检出的 blocker（已由 2026-07-30 产品闭环指令取代）

当前仍有五类不能真实验收或尚未自动闭环的路径:

- diagnostics remote trace 缺 engine-controlled receive destination 以及
  remote stat/size/hash/header 验证链;merged fake 只用 stdout/record ID
  替代真实收取;
- `redactionProfile=strict` 没有独立实现;
- `installPolicy=installFresh` 没有安装前 absence readback;
- `cleanupPolicy=restorePrevious` 与
  `portForwardProfile=debugger-default` 没有 snapshot/restore 或
  port-forward step。
- cleanup debt 已有 fail-closed 持久化 ledger 与显式 settle API,unknown
  也会保留原 typed step,但尚无携带原 job authority 的 durable
  reconcile start/outcome/transition 与 typed re-observe/remove/settle/
  continue；现有 store 单测或只更新 job-record 不能替代自动恢复 AC。

当前代码对前四类分支均在 capability 消耗与 dispatch 前拒绝;不会把 fake
结果、standard redaction、replace install、uninstall 或 no-op 冒充所请求
功能。第五类保持为未结 debt,没有伪报已消费。

该结论是 2026-07-29 当时的审计结论。2026-07-30 的产品闭环恢复指令
明确禁止新建 change/proposal,并要求未完成的 Trace、strict redaction、
installFresh、restorePrevious、debugger-default 直接保持 production
unavailable / submit fail closed；durable recovery 则在 #798 同车补齐。
因此不再把前四项拆成后续 proposal，也不以它们阻塞已可运行的默认产品
路径。

## 2026-07-30 产品闭环续修

- 所有实际访问单设备的 HDC plan（property/storage/capture/receive/
  cleanup/send/install/readback/start/stop/uninstall/forward 及 recovery
  readback）统一从 adopted target facts 取得 connectKey，并以下列前缀
  降低：`-t <connectKey>`；connectKey 缺失时在 child process 启动前
  fail closed。tool/server/list-targets 仍是 host/global observation，不
  依赖 HDC 默认设备。
- `operation.list` 与 `operation.describe` 现在返回 runtime
  `available|unavailable` 及 reasons。Catalog 仅描述 operation；provider
  未注册、provider 未发布完整 typed implementation、HDC executable
  缺失或 Artifact store 缺失都会显示 unavailable。
- `job.submit` 对全部 operation 在 capability 消耗前完成 provider
  availability、descriptor-bound target/tool facts、Artifact lease、
  optional-step selection、每个 provider action、lowered argv 与 journal
  arguments 的完整物化。任一步不能物化即零 capability consumption。
- materialized plan 使用稳定 idempotency-derived job ID，计算 canonical
  SHA-256；capability admission 同时绑定 stable target identity、
  binding revision 与该 plan digest，消费 retry 任一字段漂移均冲突。
- 每个 write-ahead intent 的 exact typed provider action 与 intent event
  correlation 在 dispatch 前写入 job record。重启 reconcile 只解码该
  原 action；legacy unknown 若缺 action 则 fail closed，不从当前 catalog
  构造替代 action。
- 未知 dispatch 保留为已有 durable intent、尚无 outcome；不写入一个
  无法再解析的假 `outcomeUnknown` step outcome。专用 readback 后只为该
  原 intent 补写一次 confirmed outcome，再通过既有 reconcile
  start/outcome/transition 恢复；confirmed-not-executed 终结为 failed，
  不自动重发。clean crash 从 journal-confirmed typed action 边界显式
  resume，且 catalog digest 漂移时 fail closed。
- unknown mutation 只执行专用 read-only postcondition readback
  (package/process/job-owned path/forward presence)，不重发原 mutation。
  cleanup debt 增加 daemon `cleanupDebt.list` /
  `cleanupDebt.continue`：debt ledger 作为显式 retry 的 WAL；retry
  outcomeUnknown 后后续 continue 只能 readback，禁止再次 cleanup。
- #798 原有稳定 job-owned remote paths、capture/receive/cleanup 与
  send/install/cleanup 配对、Artifact lease 授权前解析、`install -r`
  及五类未实现 mode 的授权前 fail-closed 全部保留。

本轮未新增 Acceptance ID、Evidence Schema 或治理状态，未修改
acceptance count，也未新增 change/proposal。

## 可复查验证

1. 定向:

   `CI=true swift test --package-path Packages/ArkDeckKit --filter RuntimeJobEngineContractTests --filter HDCE0ActionPackContractTests`

   结果:18 tests / 0 failures。

2. remote path 配对:

   `CI=true swift test --package-path Packages/ArkDeckKit --filter DiagnosticsAndHAPContractTests.testPairedRemoteActionsShareTheRealJobBoundProviderPath`

   结果:1 test / 0 failures。

3. 加固目标集:

   `CI=true swift test --package-path Packages/ArkDeckKit --filter DiagnosticsAndHAPContractTests --filter RuntimeArtifactContractTests --filter AgentRuntimeExecutorContractTests --filter AgentDaemonContractTests --filter RuntimeJobEngineContractTests --filter HDCE0ActionPackContractTests`

   结果:88 tests / 0 failures。

4. 全量:

   `CI=true swift test --package-path Packages/ArkDeckKit`

   结果:678 tests / 1 skipped / 0 failures。

5. OpenSpec/SDD:

   `scripts/check-sdd.sh`

   结果:0 errors / 0 warnings / 111 acceptance IDs。

6. 产品闭环续修定向:

   `swift test --package-path Packages/ArkDeckKit --filter 'DeviceProviderContractTests|RuntimeJobEngineContractTests|DiagnosticsAndHAPContractTests|RuntimeCapabilityStoreContractTests|AgentDaemonContractTests'`

   结果:72 tests / 0 failures；包含重启后 exact-action reconcile、
   mutation readback、cleanup debt continue 与 outcomeUnknown 零重发。

7. 产品闭环续修全量:

   `swift test --package-path Packages/ArkDeckKit`

   结果:698 tests / 1 skipped / 0 failures。新增回归覆盖:
   unknown send 重启后仅 dispatch owned-path readback、补写原 intent
   confirmed outcome 后从下一 typed step 继续且 send 零重发；clean crash
   从最后 journal-confirmed provider action 继续且已确认 action dispatch
   数为 0。

8. 产品闭环续修 SDD:

   `scripts/check-sdd.sh`

   结果:0 errors / 0 warnings / 114 acceptance IDs（只记录当前基线输出，
   本 PR 未修改 acceptance count）。

## AC 结论

- `DHA-AGENT-001`:contract/fake PASS。resume 现在是持久化的同 execution
  恢复,不是让 Agent/维护者重新制定并重跑任务。
- `DHA-ART-001`:contract/fake PASS。ID/lease、immutable publish、
  symlink/index/hash、retention/GC、bounded read、daemon export 与 raw
  bytes 落盘均有回归测试。
- `DHA-CAP-001`:部分满足。E0 HiLog/UI dump、真实 storage preflight、
  job byte budget、输入 bounds 与缺 capability 零 dispatch 已验证;
  remote trace 因上述 receive/验证链缺口 production unavailable；
  cleanup debt 已可查询、显式续执行并在 unknown 后禁止重发。
- `DHA-HAP-001`:部分满足。artifact lease、双 readback、授权顺序、
  `install -r`、nonzero failure、idempotency、compensation 与 unknown
  原 action fail-closed 与 durable readback reconcile 已验证；
  `installFresh`、`restorePrevious`、`debugger-default` 保持
  production unavailable，不能被默认路径冒充。
- `DHA-HW-001`:attempt#2 的 Agent E0 observable runtime succeeded,
  但 hardware-evidence V2/receipt 字段不闭合,formal acceptance 保持
  `BLOCKED / NOT CLAIMED`;本 run 不改写该真机结论。`DHA-HW-002` 未执行。
  两者均没有要求维护者手工执行 host CLI,也没有把 fake/simulation 记为
  真机证据。
