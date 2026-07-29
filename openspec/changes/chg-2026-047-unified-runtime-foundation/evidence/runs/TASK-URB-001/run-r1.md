# TASK-URB-001 run r1 — MU-2 垂直交付

- Date:2026-07-29
- Executor:agent(实现;批准与合并 = 维护者)
- Base:main `4ef6932`(#774 之后)
- Evidence class:contract / fake integration(进程级 crash fixture 属
  fake 类;零真实设备、零硬件 evidence 主张)

## 交付面

- **T05**:`DeviceProviders/DeviceProviderContract.swift`(协议、封闭
  typed action、facts/plan/receipt/semantic outcome/reconcile、注册表;
  plan 构造 package-only)+ `DeviceProviderAdapters.swift`(HDC 观察族
  adapter 接 `HDCCompatibilityProfile` parser;Rockchip adapter 以
  hostManaged 模式包既有执行宿主,零第二状态机)。
- **T06**:`HDCProduction.swift` 纯移动拆出 `HDCEndpointSelection.swift`
  与 `HDCAuthorizationAndSecurity.swift`;**两段留守的硬约束已成文**
  (dispatch-security 核心的 private/fileprivate 反伪造网 + 兄弟 change
  源码扫描守卫 DP1/DP13/DP19/C6 钉住诊断/观察族的文件路径,物理迁移递延
  T23,文件内 NOTE 记载);新增 `HDCCompatibilityProfile.swift`
  (3.2.0d/3.2.0f 族 profile + 观察族语义 parser,显式
  truncated/invalidEncoding/empty/malformed/unsupportedVersion)。
- **T07**:新目标 `ArkDeckAgentDaemon`(UDS 服务器 + 版本化 JSON 行协议
  + 封闭 method 表 + transport/handler 分离 + flock 单实例)、
  `ArkDeckAgentClient`、`arkdeck-agentd`(生产组装:MU-2 的 dispatcher
  显式拒绝设备 dispatch,fail-closed 等 MU-3 绑定)。
- **T08**:`RuntimeJobEngine.swift`(catalog 校验 → E0 默认策略 / E1+
  capability 原子消耗(reservation=idempotencyKey)→ durable idempotency
  ledger → 每 job durable journal:jobCreated/状态迁移/
  `WriteAheadIntentGate` 生产接线的 stepIntent → dispatch → 语义 verify
  → stepOutcome;outcomeUnknown → waitingForRecovery 零自动重放;
  restart `recoverPersistedJobs` 经 `DurableJournalRecovery` replay;
  mutation 路径接 `DeviceMutationLaneCoordinator`;cancel 安全边界)。
  journal 绑定证据规则实测钉死(host 步零 bindingRevision、device 步
  完整证据三元组)。

## 测试结果(本树,非 /private/tmp 检出)

- `swift test` 全量:**583 tests / 1 skipped / 0 failures**
  (MU-1 基线 557 + 新增 26:DeviceProviderContractTests 6、
  HDCCompatibilityProfileTests 4、AgentDaemonContractTests 8、
  RuntimeJobEngineContractTests 8)
- crash-window fixture(`ArkDeckEngineCrashFixture`,真子进程 SIGKILL):
  两窗口(intent 后 dispatch 前 / dispatch 后 outcome 前)均恢复为
  waitingForRecovery + outcomeUnknown,恢复期 dispatch 计数 0,外部效果
  标记与窗口精确对应
- `scripts/check-sdd.sh`:0 error / 0 warning / 111 AC
- 脚本套件:test_check_sdd 62、test_check_pr_paths 50、
  test_agent_pr_workflow 8、host_loop 644(1 expected failure 基线)全 OK

## AC 结论

- `URB-PROV-001` PASS(双 provider 注册;exit0+garbage→unknown 实测;
  未注册版本→unsupported;rockchip 无 manifest 引用永不 verify;
  读-only reconcile 语义)
- `URB-HDC-001` PASS(159 项既有 HDC 套件零修改零回归;parser 矩阵
  8 格;拆分定界的两条硬约束如实登记——见交付面)
- `URB-DAEMON-001` PASS(双客户端并发;0700/0600 stat 断言;
  major≠1/未知 method/畸形帧结构化拒绝;minor 前向兼容;单实例返回
  既有信息;重启后 job 历史可查)
- `URB-JOB-001` PASS(WAL 生产接线 + 两窗口 crash 矩阵;幂等 dedup
  durable + 漂移冲突;E1 无 taskID 授权 + 缺 capability 拒绝 + 消耗
  原子;cancel 安全边界;互斥按修订后判据——接线 + lane 既有覆盖,
  端到端计数递延首个可运行 mutation op)
- `URB-COMPAT-001` PASS(583/1/0 与基线对账;既有契约测试文件与公有
  facade 零修改)

## 偏差与遗留

- 拆分范围小于 design 初稿:两段留守是**实测发现的硬约束**(安全网 +
  兄弟守卫),非偷懒;design.md §3 已按实况改写,T23 递延。
- 生产 `arkdeck-agentd` 的 dispatcher 显式拒绝设备 dispatch(fail-closed);
  真实 descriptor 绑定 dispatch、facts 解析、durable target 随 MU-3。
- verification.md 三处措辞按实现对齐(互斥判据、两窗口 park、record
  字段面),均为收紧或如实化,无放宽;随本 PR 一并接受。
