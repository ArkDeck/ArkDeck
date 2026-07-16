# TASK-M1-003 run — durable journal, reconcile, audited abandonment

## Run identity and classification

- Base revision:`9e96822fda81e82116d976982015021b205dfc39`
  (`governance: define TASK-M1-003 readiness (#26)`)
- Working branch:`agent/task-m1-003`
- Date/timezone:2026-07-16,Asia/Shanghai
- Environment:macOS 26.5.2(25F84),arm64;Xcode 26.6(17F113);Apple Swift 6.3.3
- Execution authority/classification:`standardAgent`;local contract + macOS platform fault
  injection only
- Hardware/network/HDC/device access:none
- Destructive/device dispatch:none.测试中的 side effect 是 dedicated 子进程在临时目录写入的
  synthetic host marker,不是设备操作,不构成真实硬件 evidence。

## Locked inputs

以下 SHA-256 在实现前固定；本任务没有修改 Core、contract、baseline、integration 或 platform
profile。

| Input | SHA-256 |
| --- | --- |
| `openspec/baselines/CORE-2.0.0.yaml` | `07227da529608f26dcbbc8843f1623278b51cb3036cd93e1e9ed4af6f8880aa6` |
| `openspec/verification/core-conformance.yaml` | `293cc22936c1079d434c52e23572b6f575c71715d98d32018cde4ecf0deba839` |
| `openspec/specs/workflow-journal-recovery/spec.md` | `0d94128bd06292b1d9ae24a29353a1cbf5591b6c96cd560a139c37d42c357d25` |
| `openspec/contracts/journal-event.schema.json` | `21df4c44b704d249c2228384b075a331346a4731d3f0b90f66ec8092dded8b19` |
| `openspec/contracts/manifest.schema.json` | `52be768697e75fc98a00a386345162af2e1a8ca3607b86f755adb766cf0ad489` |
| `openspec/contracts/workflow-step.schema.json` | `624d61071070ec1f873a811307fe7eb39f7697c37a68ed3ef8fad774522d1688` |
| `openspec/contracts/provider-contracts.md` | `7ca522f2ef4f518096bbe218730a8952b1c02f7b63fa59fee45133dc47721b77` |
| `openspec/integrations/INTEGRATION-PROFILES.lock.yaml` | `ea4e89905abc02717049a651356ecfe6148ea85e820a7d442aa06686c1a52f04` |
| `openspec/integrations/openharmony/profile.md` | `820eca652a7e237693960aadc6d01a9f45c4a964cff3d8307a8fa0e4e5218734` |
| `openspec/platforms/PLATFORM-PROFILES.lock.yaml` | `6ed7ae92343f93693555fef4e5831cd363f6d0c5dcb7fbdd4d651d6d506a1212` |
| `openspec/platforms/macos/profile.md` | `54bd9b295799cb8d93bf397eeb585f24828463f4f1fce1e59a0693f65369d0bf` |
| `openspec/platforms/macos/verification.md` | `0e3de8749ec5e974ed96ceed1760ee7e049a92eecb052c2cfb47658390ca7072` |
| change `proposal.md` | `59e0107f12957988d5af24071c927f26021267ec8e6bbd205eef718a106f162a` |
| change `design.md` | `659ac7fd165f89be163a49aff108b4fe8b5cbc3815a0d6ee4547d63779df9f14` |
| pre-run change `tasks.md` | `071cc14ce664daa64224ffd65dde4f80037ac3643b11b587733f458cbdfd55e9` |
| change `verification.md` | `d272f88404464ee25f57788cf8c2bbf3576346a4a1476ab0b56fa06e013a02e4` |
| change `scope.yaml` | `2b6157ff202cda41f601445cee986c7fadb8d60a6b2ef2a924f13051a12b6265` |
| change `acceptance-cases.yaml` | `6e9afe53672b7d0ba33e663945658ad6752e013f3b4ca90c1de939600e31ad3e` |

## Work completed

- 用 `ArkDeckCore.WorkflowStep`/`CompensationDescriptor` 实现 `journal-event-1.0.0`
  的 19-kind closed codec；严格拒绝 unknown kind/field、任意对象层级 duplicate member、
  malformed payload、非法 pair、canonical arguments hash/binding/correlation/sequence 不一致。
- 实现 append-only JSONL writer：absolute path、`O_APPEND|O_NOFOLLOW`、完整 write loop、
  `fsync` + macOS `F_FULLFSYNC`、directory fsync；失败后 writer poisoned,不会继续推进。
- 实现同目录临时文件、file full-sync、atomic rename、directory fsync 的 checkpoint；恢复时完整
  journal 是 authority,拒绝超前或与 journal 不一致的 checkpoint,旧 checkpoint 被 journal
  supersede,torn tail 不作为完整 event 接受。生产 writer 在至少存在 durable `jobCreated` 时只截断
  最后一个 incomplete record，并对修复后的 regular file 与 directory entry 同步；随后 reconcile
  和 audited abandonment 可继续追加审计序列。
- 实现 unfinished Session scanner、deterministic recovery decision、Provider/binding evidence gate；
  intent-without-outcome 强制 `outcomeUnknown/waitingForRecovery`,所有 destructive dispatch、
  replay 和 guess-compensation counters 为 0。
- 实现 audited abandonment：durable intent → managed-process stop/safe boundary → durable outcome
  → terminal transition → lane/claim release；任何前置失败均保持 recovery 且 release 为 0。
- Review 修复后，replay 与 append validator 均要求首条完整 event 是 sequence 0
  `jobCreated`，并校验 state/reconcile/abandon/finalized lifecycle；普通与 compensation 的 durable
  `outcomeUnknown` 被显式保留，当前进程立即禁止后续 Step/compensation intent，重启扫描固定为
  `waitingForRecovery/outcomeUnknown`。
- Reconcile 现在 durable 写入 `waitingForRecovery → reconciling → decision state`；进入
  `reconciling` 后的两处 crash window 可 durable 回退后重试，outcome 后、decision transition 前
  的 crash 会补齐既有决定，不重新猜测 Provider 结果。
- Abandonment 现在可从既有 durable intent、`userAbandonRequested`、durable outcome 三个阶段续作；
  续作时以 durable intent 中的 `deviceHazards` 为权威，replay/append validator 均拒绝
  outcome 缩减已审计 hazard。首次 abandonment 还会从 outstanding 或 durable-unknown 的
  `deviceMutation`/`destructive` intent 派生 canonical hazard；coordinator 自动合并，journal
  validator 拒绝调用方遗漏这些风险。
  lane/claim release port 改为可幂等确认，部分成功时准确报告，并可从 durable terminal
  authorization 只重试尚未确认的 release。
- 未完成的 `deviceMutation`/`destructive` intent 现在禁止进入 `finalizing`、terminal
  或写入 `finalized`；唯一例外是已 durable 审计的 abandon `interrupted` 路径，保证 scanner
  不会因伪造终态跳过 unknown external effect。`finalized.terminalStatus` 的状态匹配与该例外分开
  校验，授权 interrupted 也不能接受其他 terminal status。
- Reconcile 的历史 `outcomeUnknown` 决定可被后续全新且 confirmed 的
  Provider/binding evidence 取代；真实 step/compensation unknown 仍是硬阻断。已落盘 outcome
  到 decision transition 补齐前，`requiresRecovery` 持续为 true。
- 实现 manifest recovery/hazard locked-shape codec 和 unresolved-hazard preflight gate；只有
  Provider allow、user override、durable audit 三者齐备才解除 gate,且 gate 自身不派发设备 Step。
- 增加 dedicated `ArkDeckJournalCrashFixture`,通过 absolute executable + argument array 启动；
  四窗口使用 `SIGKILL`,fixture 不启动工具、不接触设备或网络。

## Verification commands and results

| Command | Result |
| --- | --- |
| `swift format lint <TASK-M1-003 changed Swift files>` | passed;0 diagnostics |
| `swift test --package-path Packages/ArkDeckKit --filter JournalRecoveryContractTests` | passed;23 tests,0 failures,0 skips |
| `swift test --package-path Packages/ArkDeckKit` | passed;102 tests,0 failures;1 unrelated opt-in M0A manual idle-sleep observation skipped by design |
| `scripts/check-sdd.sh` | passed;0 errors,0 warnings,111 acceptance IDs |
| `git diff --check` | passed |

## Fault and crash evidence

### Durable intent/outcome/checkpoint gates

| Fault point | Durable/recovered sequence | Dispatch/snapshot conclusion |
| --- | --- | --- |
| journal append admission | none | external dispatch 0 |
| journal write | none | external dispatch 0 |
| journal file sync | sequence uncredited/outcome uncertain | external dispatch 0;writer poisoned;startup recovery required |
| journal directory sync | sequence uncredited until recovery scan | external dispatch 0;writer poisoned;startup recovery required |
| outcome append | checkpoint remains sequence 0 | snapshot advancement 0 |
| checkpoint temporary write | recovered checkpoint sequence 0 | old snapshot remains authoritative under journal |
| checkpoint file sync | recovered checkpoint sequence 0 | old snapshot remains authoritative under journal |
| checkpoint atomic replace | recovered checkpoint sequence 0 | old snapshot remains authoritative under journal |
| checkpoint directory sync | parseable replacement sequence 2 may be visible,publication call fails | scanner still validates against journal;checkpoint alone is never trusted |

### Audited abandonment

| Case | Durable event sequences | State | Lane release | Claim release |
| --- | --- | --- | ---: | ---: |
| abandon intent failure | none | `waitingForRecovery` | 0 | 0 |
| process safe boundary unconfirmed | 10,11,12,13(deferred + rollback) | `waitingForRecovery` | 0 | 0 |
| abandon outcome sync failure | 10,11 | `waitingForRecovery` | 0 | 0 |
| terminal transition persistence failure | 10,11,12 | `waitingForRecovery` | 0 | 0 |
| success | 10,11,12,13 | `interrupted` | 1 | 1 |
| partial release:first attempt | terminal durable | `interrupted`;lane confirmed,claim pending | 1 | 0 |
| partial release:idempotent retry | no new journal event | `interrupted`;both confirmed | 0(already released) | 1 |

### Review recovery vectors

| Vector | Durable/recovered conclusion | External/destructive dispatch |
| --- | --- | ---: |
| step outcome=`outcomeUnknown` | outstanding intent cleared but unknown outcome retained;scanner=`waitingForRecovery/outcomeUnknown` | 0;next intent rejected in current process |
| compensation outcome=`outcomeUnknown` | unknown compensation retained;scanner=`waitingForRecovery/outcomeUnknown` | 0;guess compensation 0 |
| crash after entering `reconciling` | durable `reconciling → waitingForRecovery`,then a new correlated attempt | 0 |
| crash after `reconcileStarted` | incomplete attempt retained for audit;durable rollback and new attempt complete | 0 |
| crash after `reconcileOutcome` | original outcome determines state;missing correlated transition is appended | 0 |
| pending reconcile decision transition | `requiresRecovery=true` until the correlated transition is durable | 0 |
| later confirmed reconcile after historical unknown | fresh confirmed Provider/binding evidence permits resume;actual step/compensation unknown remains blocking | 0 |
| abandon crash after intent/request/outcome | existing audit IDs and durable hazards are resumed;new request cannot clear audited hazards | 0 |
| outstanding external-effect intent with forged terminal/finalized tail | replay and append reject terminal hiding;scanner remains recovery-visible | 0 |
| authorized interrupted + mismatched `finalized.terminalStatus` | append and untrusted replay both reject the inconsistent terminal record | 0 |
| scanner-visible torn tail | writer durably truncates only the incomplete record;reconcile and audited abandonment both append successfully | 0 |
| initial abandon with empty caller hazards and unresolved destructive intent | coordinator derives `unresolved-destructive-intent:<step>:<event>`;direct omission is rejected and outcome preserves it | 0 |
| missing/late `jobCreated` | replay and append both reject recovery input | 0 |

### macOS crash-window matrix (`TEST-MAC-M1-JOURNAL-001`)

| Kill window | Durable sequences after restart scan | State / certainty | Device dispatch | Destructive dispatch/replay | Guess compensation | Release | Synthetic host marker |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| before intent | 0,1,2 | `running` / `confirmed` | 0 | 0 / 0 | 0 | 0 | 0 |
| after durable intent | 0,1,2,3 | `waitingForRecovery` / `outcomeUnknown` | 0 | 0 / 0 | 0 | 0 | 0 |
| after synthetic side effect,before outcome | 0,1,2,3 | `waitingForRecovery` / `outcomeUnknown` | 0 | 0 / 0 | 0 | 0 | 1 |
| after durable outcome,before finalize | 0,1,2,3,4 | `running` / `confirmed` | 0 | 0 / 0 | 0 | 0 | 1 |

## Acceptance conclusions

| Test ID | Evidence class | Binary conclusion |
| --- | --- | --- |
| `TEST-AC-JOB-002-01` | contract | passed:任一 intent durability gate 失败时 external dispatch=0；outcome 未 durable 时 checkpoint 不前进；checkpoint fault 恢复 journal-first。 |
| `TEST-AC-JOB-006-01` | contract | passed:missing 或 durable-unknown destructive/compensation outcome 均只得到 `waitingForRecovery/outcomeUnknown`;当前进程和重启后的 dispatch/replay/compensation 均为 0；torn tail durable 修复后 reconcile 可续作；reconcile 全状态迁移 durable 且三个 crash window 可续作；16 组 resume 条件只有四项全真时允许 marker。 |
| `TEST-AC-JOB-007-01` | contract | passed:四类前置失败 release 均为 0；三个 abandon crash phase 使用既有 audit 续作；首次与续作均保留 journal-derived device hazards；只有 durable outcome + matching interrupted transition 后释放，部分 release 准确报告并幂等重试。 |
| `TEST-AC-JOB-007-02` | contract | passed:Provider allow × user override × durable audit 的 8 组真值组合已穷举；只有三者全真解除 gate,device dispatch 恒为 0,并保留 audit event ID。 |
| `TEST-MAC-M1-JOURNAL-001` | platform | passed:四个真实 macOS 子进程 kill window 的 restart scan 如上；未知结果不重放,fixture device/destructive dispatch 恒为 0。 |

## Deviations and residual risk

- Presentation deviation:`Packages/ArkDeckKit/Package.swift` 曾由 `swift format` 整文件重排；其唯一
  semantic delta 是注册/连接 `ArkDeckJournalCrashFixture`，仍在任务显式允许范围内。
- 本 run 是 local contract/platform evidence,不是 realHardware；未改变 macOS
  `conformance_status:notStarted`,也不构成 capability/release claim。
- directory-sync fault 后 replacement bytes 可能可见但未获得 publication success；实现通过
  journal sequence/state/correlation 复核 fail closed,不会把可见性误当 durability guarantee。
- `syncDirectory` 在 Darwin 上对 directory fd 使用 `fsync` 作为 namespace-entry durability
  barrier；`F_FULLFSYNC` 仅用于 regular-file contents，不假设它支持 directory descriptor。
- 原 3 个 JSON fixture 已收敛为 test target 内编译的 Swift fixture；SwiftPM 不再报告
  unhandled resource warning；`Package.swift` 的实质改动仅限于该 fixture 的注册/连接。
- `tasks.md` 的 `done` 仅为本分支的 closure 草案；只有维护者 review/merge 后生效,change 仍未
  `verified`。
