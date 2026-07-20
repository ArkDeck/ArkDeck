---
id: CHG-2026-008-ui-dump-hidumper-wrapper
revision: 5
status: approved # r1 经 #68 批准;后续 revision 仅在对应治理 PR 由维护者 review/merge 后生效
class: platform
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Integration:依 M0B 真机事实固定 ui-dump 的 HiDumper 调用包装

## Why

`ui-dump` spec 明确:候选参数映射的"实际 HiDumper 调用包装 SHALL 在 M0B 真机
验证后经 integration change 固定,验证前不得据此宣称兼容性"(spec.md:47)。
M0B 真机事实现已合入(EVD-M0B-DAYU200-20260718-001),但其 HiDumper capture 只执行了:

1. `hidumper --help` 在该 DAYU200 build 上输出单行错误样文本
   `hidumper: option pid missed. help` 且 **exit code 为 0**——包装不能用
   `--help` 做特性探测,也不能以退出码判成败(与 M0A hdc 无 `[success]` 标记
   同族教训);
2. `hidumper -ls` 正常:`System ability list:` + 服务名多列输出,含
   `RenderService`、`WindowManagerService`、`AbilityManagerService`、
   `UiService` 等 ui 相关 ability。

该 evidence 的"四个流"是上述两条命令各自的 stdout/stderr,不是四个 canonical Recipe
执行。它不能证明 `-s WindowManagerService -a` 的实际 argv 参数边界,也没有任一 Recipe
成功输出可用于登记 success output family。公开文档/示例可以指导人类 capture,但不能
替代目标 DAYU200 build 的受控实测。因而本 change 的 integration 决策仍未具备足够输入,
执行者不得自行发明 argv、marker 或 fake fixture 后让自己的测试通过。

r1 把全部执行硬阻塞在 `TASK-M1-006 done`。r2 试图引用 CHG-2026-014 的 consolidated
implementation bytes 解耦 scheduling dependency,但没有按其强制规则提供逐 deliverable
consumer dependency 表;同时 TASK-UD-001 未追溯 `REQ-DUMP-003` / `AC-DUMP-003-01`,
也没有要求缺失、非法或注入型 component ID 在产生 `ProcessRequest` 或 dispatch 前被阻断。
r2 的 Required environment 还没有把 `scripts/check-sdd.sh` 所需 PyYAML 解释器作为 DoR
preflight;默认 `python3` 缺少 `yaml` 时,命令无法按任务原文执行。

r3 是 review remediation:恢复 `TASK-UD-001 blocked`,补齐 consumer dependency、Core
追溯和 SDD 环境 gate,固定 one-element `-a` candidate boundary,并把首次 target
execution 全部保守归为 `deviceMutation`(official source 不能证明 target output mode,
不存在可批准的 stdout-only Recipe 采集)。真机采集拆为两个人类任务:
`TASK-UD-CAP-MUT-001`(Phase A,R1-R3)与 `TASK-UD-CAP-R4-001`(Phase B,R4,等待
approved R2 output-family decision 记录选定 component token);另设
`TASK-UD-REDACTOR-001` 在 golden 入仓前固定确定性脱敏 transform 与 redaction receipt。

r3 初稿曾提出 journaled execution-authority(JAUTH)模型(external Core MAJOR
`TASK-JAUTH-CORE-001`/CORE-3.0.0、production supervisor/binding 栈前置、offline receipt
verifier 与 7 任务链;全文见 PR 提交历史 `a613b76`)。经维护者 2026-07-20 review 裁剪:
人工采集的授权载体回归 M0B 先例——runbook + 人类维护者亲手执行 + 维护者对 evidence PR
的 review/merge attestation;JAUTH 记入 backlog 候选,不作为本 change 前置。此前实现
草案 PR #126 仅保留为不可合并的审计记录。

## What changes

### In scope

- 固定 HiDumper 调用包装:每个 Recipe 的实际 argv 形态(是否需要
  `-s <ability> -a` 前缀等)、基于输出标记(非退出码)的成败判定、错误样输出
  (如 `option ... missed`)的显式失败分类;
- 依 I5-001/M0B 先例登记 hidumper **derived** golden fixture:敏感 raw 永远留在受控
  仓库外位置,仓库只提交经 `uidump-derived-redaction-v1` 确定性转换、带 redaction
  receipt 且经维护者在 golden PR 逐字审读的 derived bytes,`.gitattributes` 先行钉死
  资源;
- 对应 contract 测试(fake 输出对抗:标记缺失/错误样输出/exit-0 陷阱);
- output-family contract 仅允许具备 repo-safe synthetic/derived positive fixture 的文本
  marker 或结构 parser;raw byte-fingerprint/digest family 不属于本 change;
- integration profile/lock 相应更新;
- r3 治理修订只做 remediation:把 TASK-UD-001 恢复为 `blocked`;新增
  `capture-runbook.md`(人工 preflight、候选 argv boundary、保守 effect、exact-path
  清单、evidence 与 raw/derived 隐私链);新增两个人类采集任务与 redactor 任务;增加
  CHG-2026-014 逐 deliverable consumer dependency 表;将 `REQ-DUMP-003` /
  `AC-DUMP-003-01` / `TEST-AC-DUMP-003-01` 纳入验证闭环;固定 PyYAML 解释器
  preflight。r3 merge 后没有 ready 的 real-device task。TASK-UD-001 只有在两个采集
  task、decision revision 与 redactor 完成后才能再次起草 `blocked→ready`。

### Out of scope

- 兼容性/支持声明、matrix 行推进(真机复核属未来 M0B-002 之后的观察);
- Flash/Trace/Debug capability;Agent 执行真实 `hdc`(golden 采集由人类按 runbook
  先例执行);
- 依据公开示例推断目标 build 的单参数 `-a` 边界,或把 `--help`/`-ls` 输出当作 Recipe
  success family;用自造 marker/fake 输出关闭验收;
- 在采集任务仍 blocked 时执行任何 HDC/Recipe,或把 R1-R4 首次 target capture 降级为
  readOnly;偏离 runbook 固定命令做 ad-hoc 清单/清理、全局搜索或递归删除远端文件;
- 在 approved R2 decision 未记录选定 component token 时执行 R4,或从
  operator/CLI/env/file 现场取得 component ID;
- journal event/append-chain 字段、dispatch authority 变更或任何 Core delta(本 change
  保持 `class:platform` / `core_change_level:none`;JAUTH 属未来独立 Core MAJOR,见
  backlog,不是本 change 前置);
- HDC 默认目标、connect key 来自同会话 `list targets` 之外的任何来源、显式 server
  lifecycle/subserver 命令,或将 connect key/serial 字节提交进仓库;
- 将 raw UI Dump bytes、片段、页面文本、包/组件/窗口标识符或用户路径提交进仓库;把
  derived golden 错标为 raw,或声称 raw/derived byte-exact equality;
- 在 `TASK-UD-REDACTOR-001 done` 前生成 derived golden 或让 TASK-UD-001 ready;由
  golden 实现者临时决定 redactor algorithm/safe literals;在 TASK-UD-001 内修改已固定
  redaction toolchain;TASK-UD-001 在任何阶段读取 raw;
- 在本 change 登记 raw byte-fingerprint/digest output family;若未来需要该 family,必须
  另起 approved change,先固定 privacy-safe 且复用 production stream→digest 路径的
  conformance seam;
- 将 `TASK-M1-006` 标为 done/verified,重判其任何 HDC/XCUITest evidence,或把本依赖
  解耦解释为 HDC compatibility、platform conformance、hardware/support/release claim。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- ui-dump spec:按 spec.md:47 预留的 integration 钩子固定包装(spec 文本本身
  是否需措辞澄清,在 design 阶段判定;如需修改另行 revision)
- Platform Profile / Integration lock:更新(golden 登记)
- Planning:`openspec/planning/backlog.md` 增加 JAUTH 候选条目(由本 r3 PR 一并提交)

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | revalidate ui-dump contract tests | 包装与 golden 变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- `TASK-RLC-001` done 与 CHG-2026-014 verified 只证明固定 bytes/interfaces 已进入
  `main`,不能提供 M1-006 source AC;consumer 是否可用必须逐 deliverable 按
  CHG-2026-014 的表格规则判定。TASK-UD-001 的表格结论全部为"不需要 M1-006 source
  AC";两个人工采集任务按 M0B 先例由人类直接使用 installed `hdc`,同样不消费 M1-006
  source AC/evidence;
- 当前 M0B manifest 仅证明 `--help` 与 `-ls`,不得标成四 Recipe capture、success marker
  或 wrapper compatibility evidence;其旧 connect key 必须在采集会话内重新观察;
- `capture-runbook.md` 固定唯一 one-element `-a` candidate boundary、人工 preflight
  (`HP-0..HP-2`:HDC hash/version 对照、恰一目标、批次前复查)与显式 `-t` 规则。官方
  ArkUI source 只作 routing hint;R1-R4 首次 capture 全部为
  `captureRemoteFile/deviceMutation`,不得事后降级;
- 采集授权 = runbook + 人类维护者亲手执行 + evidence PR 的维护者 review/merge
  attestation(先例 TASK-M0B-001;AGENTS.md 规定 destructive/真机操作由人类执行并记录
  operator/设备/时间)。hardware evidence 过 schema 2.0.0 校验,校验工具身份在执行时
  记录;claimed operator 的真实性由维护者 review attest,不由自动化声称;
- component ID preflight 必须在任何 `ProcessRequest` materialization 和 dispatch 之前;
  缺失、空值、非法格式及 shell/argument injection 输入的 request/dispatch count 均为
  `0`;
- Phase A/B 只回收本次运行证明归属的 exact literal sidecar path;全局搜索、wildcard、
  递归删除、覆盖既有文件一律禁止;归属不明保留并记 `needsAttention`;
- UI Dump raw 默认敏感并留在仓库外;仓库 evidence 只含 whole-stream hash/metadata。
  derived golden 必须经 `TASK-UD-REDACTOR-001` 固定的确定性 transform(unknown token
  fail closed、输出侧敏感终检硬失败)与 redaction receipt(algorithm/allowlist/raw/
  derived hash 链 + replay 命令),由 TASK-UD-001 golden PR 提交并接受维护者逐字审读,
  merge 即 privacy attestation;`TEST-INT-UD-GOLDEN-001` 机器侧复核 hash 链与敏感
  字面量零命中;
- 每个登记 output family 都必须能在干净 checkout 以 repo-safe synthetic/derived fixture
  走 production classifier 正向复验;本 change 禁止 raw byte-fingerprint/digest family;
- 本 r3 治理 PR 本身零 HDC/device dispatch;merge 后仍没有 ready 的 real-device task。
  所有 future capture 的 destructive/Agent dispatch count 为 `0`,且不解除任何
  `GAP-DAYU200-*`。

## Approval

- Proposal 经 PR #63 合入 `main`
  `a94b4348e0bf0e7cd0030d0a383ca65633c10b31`(2026-07-18,status:`proposed`)。
- r1 正式批准:PR #68 合入 `main`
  `ee13ba1b64f73d94395549f126b422c49d4ebd6e` 将本 change 置为 `approved`;批准由
  维护者 review/merge 该 approval-only PR 构成。
- r2 dependency/readiness revision:由 PR #115 合入并把 TASK-UD-001 起草为 ready。后续
  review 发现 r2 的 capture、consumer dependency、Core AC trace 与 SDD environment gate
  不充分。
- r3 review remediation 只修订本 change 的 proposal/tasks/verification/acceptance
  metadata,新增 plan-only `capture-runbook.md` 与 backlog 条目,恢复 TASK-UD-001
  `blocked`,声明两个人类采集任务、redactor 任务与两阶段拆分,且不包含 harness 实现、
  fixture、profile/lock 或 task evidence。r3 初稿(`a613b76`,含 JAUTH/receipt-chain
  模型)经维护者 2026-07-20 review 裁剪为本版本;裁剪对照见 tasks.md"裁剪任务记录"。
  r3 仅在维护者 review/merge 对应治理 PR 后生效;该 merge 同时构成裁剪决定的批准,
  不执行任何 capture/TASK-UD-001,也不使 CHG-008 verified。r3 已经 PR #131 合入
  `main` `d99ba58`。
- r4 readiness-only revision:固定 `TASK-UD-CAP-MUT-001` 的五项 readiness 输入
  (fixture HAP 元组含 artifact SHA-256、`INV-1` 字面 argv、唯一 literal sidecar path 与
  `SC-1` 清单命令、fixture 生命周期 `FX-1..FX-4` 字面 argv、操作者与时间窗规则),并把
  该任务起草为 `ready`;不改 scope/AC/spec、不含实现或 evidence、不改变其他任务状态。
  仅在维护者 review/merge 对应 readiness PR 后生效;merge 即构成五项输入的批准。实际
  采集另需维护者确认的设备时间窗,执行与 evidence 按 runbook/task 契约进行。r4 已经
  PR #132 合入。
- r5 readiness-only revision:固定 `TASK-UD-REDACTOR-001` 的实现范围与 base 规则
  (6 个 `scripts/ui_dump_redaction/` 文件、stdlib-only、无采集前置、fixed interpreter
  实测)并把该任务起草为 `ready`;不改 scope/AC/spec、不含实现或 evidence、不改变
  其他任务状态、不接触真实 raw。仅在维护者 review/merge 对应 readiness PR 后生效。
  `safe-literals-v1.txt` 逐项批准仍发生在实现 PR 的维护者 review 中。
