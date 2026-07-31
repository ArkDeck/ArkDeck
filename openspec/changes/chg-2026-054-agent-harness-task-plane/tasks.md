# Tasks — CHG-2026-054

六个垂直产品任务(PRODUCT-LOOP §4:一个问题、一个垂直任务、一个产品 PR)。全部映射
**GJ-5 Bounded AI Debug Loop**。

共同规矩:

- 每个任务 = 一个实现 PR,同车交付根因说明、产品代码、测试、必要真机结论与最小文档,
  并在同一 PR 内把本任务翻 `done`、把对应 AC 结论写入 `verification.md`;
- **不建** readiness-only / status-only / verified-only / archive-only PR;
- `- Gate:` 是 §20 冻结门的如实登记,由实现 PR 记录门已满足(或记录维护者的提前解冻
  依据);门不通过 status-only PR 维护,任务保持 `ready`;
- 真机结论只能来自真实运行;fake/simulation 不得顶替,缺设备窗口时如实记
  `pending-hardware` 且不得据此宣布 `REAL_DEVICE_PASS`。

## TASK-HTP-001 — Harness Task 平面骨架:typed task、reducer、reconcile、task.* 接口

- Status:done
- Done:2026-07-30;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HTP-AC-1..4 全部 PASS,evidence = `evidence/runs/TASK-HTP-001/run-r1.md`
  (库层 748 tests/1 skip/0 fail,新增 20 例;host 侧进程级实跑真实 UDS + 真实引擎,
  零 dispatch/零 job/零 capability 消耗)。真实设备收敛仍属 TASK-HTP-006。
- Platform:macos
- Requirements/AC:proposal What 1/2/7(typed task 模型与 store、reconciler 与
  reducer、`task.*` daemon 方法与 CLI);change-local HTP-AC-1、HTP-AC-2、
  HTP-AC-3、HTP-AC-4,登记于 `verification.md`
- Gate:**已满足**——维护者 2026-07-30 在会话中显式提前解冻 TASK-HTP-001/002
  (§20 提前解冻;依据:E0-only、零设备 mutation、零源码写入,只消费 GJ-1 已有产物)。
  GJ-1/GJ-2 的 `REAL_DEVICE_PASS` 硬门仍对 TASK-HTP-006 有效
- Depends on:none(change 随本 proposal PR 合入即 approved)
- Hardware required:no(离线 fake provider + 固定 artifact 样本即可交付;真机收敛留
  TASK-HTP-006)
- Scope:`HarnessTask` 值对象与封闭 `DEBUG_CRASH` handler(含内建确定性策略,零模型);
  durable task store 与 append-only task event;`TaskStateReducer`(唯一状态迁移入口 +
  乐观锁);`Reconciler`(一次唤醒至多一个 effectful job);dispatch intent →
  稳定 idempotencyKey → TaskJobLink 三步序与崩溃恢复;daemon `task.submit/list/status/
  result/cancel/pause/resume/reconcile/events` 与对应 CLI;`provenance.harnessTaskId`
  仅作 correlation(不参与 admission)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(新控制面;E0-only、零新设备副作用面;状态迁移与 idempotency 是主要
  风险点,由 HTP-AC-2/AC-3 的崩溃矩阵与非法迁移负例覆盖)

## TASK-HTP-002 — Evaluation Engine:唯一成功判定权与真实字节 observation

- Status:done
- Done:2026-07-30;随本实现 PR 合入生效(维护者 review + merge 即批准)。
  HTP-AC-5、HTP-AC-6 PASS;HTP-AC-7 PASS(fail-closed 与判定面全绿)+ 其「真机字节」
  一半如实保持 pending-hardware(仓内无真机 hilog/crash 字节样本,由 TASK-HTP-006
  的设备窗口关闭)。evidence = `evidence/runs/TASK-HTP-002/run-r1.md`
  (库层 763 tests/1 skip/0 fail,新增 15 例)。
- Platform:macos
- Requirements/AC:proposal What 3(evaluation engine、criterion 模型、observation
  builder);change-local HTP-AC-5、HTP-AC-6、HTP-AC-7,登记于 `verification.md`
- Gate:**已满足**——同 TASK-HTP-001 的维护者提前解冻(2026-07-30);
  前置 TASK-HTP-001 已 done
- Depends on:TASK-HTP-001
- Hardware required:no(用真机已产出的 artifact 字节样本 + fake 供给;真机复验在
  TASK-HTP-006)
- Scope:criterion 模型(metric/operator/expected/minimumSamples/observationWindow/
  evidenceRequirements/mandatory/inconclusivePolicy);verdict 四态;observation
  builder 从真实 hilog/dump/build 产物字节提取 crash signature、liveness、
  artifact digest 一致性;证据缺失/空/hash 不符一律 fail closed;`SUCCEEDED` 只能由
  evaluator 触达(负例:decision 自述已修复不改变结论)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:medium(判定权集中于此;错判为 PASS 会让不成功的修复被宣布成功,故
  INCONCLUSIVE 与证据缺失路径必须有负例)

## TASK-HTP-003 — Policy & Budget Guard、Failure Memory 与 HumanActionRequired 生产者

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 4/8(policy guard、预算、失败指纹、no-progress、
  三层 memory、HumanActionRequired 首个生产者);change-local HTP-AC-8、HTP-AC-9、
  HTP-AC-10、HTP-AC-11,登记于 `verification.md`
- Gate:同 TASK-HTP-001;且 TASK-HTP-001/002 已 done
- Depends on:TASK-HTP-001、TASK-HTP-002
- Hardware required:no(授权缺失、outcomeUnknown、预算耗尽均可在 fake 面构造;真机
  E1 收敛在 TASK-HTP-006)
- Scope:Policy Guard 校验序(task type 允许集 → runtime availability → typed inputs →
  target/binding → effect ceiling → E1 mutation 预算 → failure memory 禁止规则 →
  active job 冲突 → 时间/轮数/artifact 预算 → raw command 面拒绝);预算耗尽安全停止;
  失败指纹与三次规则;no-progress 向量;task/project/failure 三层 memory(写入须带证据
  引用,project memory 只收 PASS 或人工确认结论);产出结构化 `HumanActionRequired`
  并支持 typed resolution 恢复;E2 一律人工、E1 只用既有 standing capability
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(本任务承载全部有界性与授权边界;任何放宽都会让无人值守执行越界,
  故 E2 拒绝、E1 预算、outcomeUnknown 停止三条各有独立负例)

## TASK-HTP-004 — LLM Decision Gateway:可替换端口、严格结构化输出与出站边界

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 5(decision gateway、四类 decision、出站默认 deny);
  change-local HTP-AC-12、HTP-AC-13、HTP-AC-14,登记于 `verification.md`
- Gate:同 TASK-HTP-001;且 TASK-HTP-003 已 done(decision 必须先有 Policy Guard 才能
  被接受)
- Depends on:TASK-HTP-003
- Hardware required:no
- Scope:有界 `DecisionContext` 组装器(声明式裁剪 + 尺寸上限);`HarnessDecision`
  四类严格 schema 与负例集(raw argv/shell/远端路径/状态字段/retry 计数/成功结论/
  未声明 operation 一律整条拒绝);出站默认 deny 与项目级显式开启;开启后只带脱敏、
  有界摘要与 artifact 引用(断言不含设备标识与未脱敏字节);离线确定性 adapter 与
  真实 adapter 共用同一端口,替换 adapter 不改变状态机结论
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `Catalog/**`、`scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(唯一的外部不可信输入面 + 唯一的出站面;拒绝面与脱敏面必须由负例钉死,
  不得依赖模型自律)

## TASK-HTP-005 — 新 provider `arkdeck-workspace` 与 workspace.* typed operations

- Status:ready
- Platform:macos
- Requirements/AC:proposal What 6(新 provider 与六个 workspace operation、preset
  lowering、patch 范围与回滚);change-local HTP-AC-15、HTP-AC-16、HTP-AC-17,
  登记于 `verification.md`
- Gate:同 TASK-HTP-001;且 TASK-HTP-003 已 done(源码写入必须先有 Policy Guard 与
  预算面)
- Depends on:TASK-HTP-003
- Hardware required:no(host 面 provider;真机部署复验在 TASK-HTP-006)
- Scope:`arkdeck-workspace` provider 与 `workspace.inspectSource / applyPatch /
  buildOpenHarmony / runTests / symbolizeCrash / revertPatch` 六个 typed operation
  (catalog 描述符 + 契约 action 与参数面 + 生成器重生成 + digest 更新);ProjectProfile
  build/test/symbol preset;经既有 `DescriptorBoundProcessDispatcher` 真 spawn;
  patch artifact → glob 校验 → applied-patch artifact → revert;provider 不可用时
  `UNAVAILABLE` 带机器可读原因且零 capability 消耗;零 `git push`/`merge`/PR 路径
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/contracts/catalogs/**`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `openspec/contracts/provider-contracts.md`
  - `scripts/catalog_gen/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/capability-registry.yaml`
  - `scripts/**`(仅上列 `scripts/catalog_gen/**` 除外)、`.github/**`、`AGENTS.md`、
    `PRODUCT-LOOP.md`、`ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首个会写入源码并执行构建的 provider;action 集变更命中 stdout/词表
  lockstep 六处,必须同 PR 更新生成器 pin 并断言零 drift——CHG-2026-050/053 先例)

## TASK-HTP-006 — GJ-5 真机端到端:一次 submit 自动收敛,接管后人工步骤 0

- Status:ready
- Platform:macos
- Requirements/AC:proposal 全部交付面的真机复验;change-local HTP-AC-18、
  HTP-AC-19,登记于 `verification.md`
- Gate:GJ-1 与 GJ-2 均 `REAL_DEVICE_PASS`(硬门,不接受提前解冻);TASK-HTP-001..005
  已 done
- Depends on:TASK-HTP-001、TASK-HTP-002、TASK-HTP-003、TASK-HTP-004、TASK-HTP-005
- Hardware required:yes(已接管 DAYU200 + 当前 catalog digest;E1 段需维护者经
  merged PR 已签发的 standing capability,Agent 不得自签)
- Scope:在已接管设备上一次 `task.submit` 驱动 `DEBUG_CRASH` 自动完成 运行 → 采集 →
  分析 → (可选 patch → build → 部署) → 复验,直到 evaluator `PASS` 或安全停止;
  记录人工步骤计数(E0 与已授权 E1 目标为 0)、每轮 decision/job/artifact 链、
  预算消耗与停止原因;真机暴露的产品缺陷在同一 PR 内修复(不新开治理载体);
  据结果如实翻转 GJ-5 状态(仅当前 digest 上的真实运行可写 `REAL_DEVICE_PASS`)
- Allowed paths:
  - `Packages/ArkDeckKit/**`
  - `Catalog/**`
  - `openspec/changes/chg-2026-054-agent-harness-task-plane/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/contracts/**`
  - `scripts/**`、`.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、
    `ArkDeck.xcodeproj/**`、`ArkDeckApp/**`
  - 其他 change 目录
- Risk:high(首次无人值守多轮真机执行,含已授权 E1 mutation;停止条件、
  outcomeUnknown 与预算面必须在此之前全部有测试覆盖,且窗口内保留人工中断能力)
