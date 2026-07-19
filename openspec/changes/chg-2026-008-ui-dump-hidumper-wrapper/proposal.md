---
id: CHG-2026-008-ui-dump-hidumper-wrapper
revision: 3
status: approved # r1 经 #68 批准；后续 revision 仅在对应治理 PR 由维护者 review/merge 后生效
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
M0B 真机事实现已合入(EVD-M0B-DAYU200-20260718-001)，但其 HiDumper capture 只执行了：

1. `hidumper --help` 在该 DAYU200 build 上输出单行错误样文本
   `hidumper: option pid missed. help` 且 **exit code 为 0**——包装不能用
   `--help` 做特性探测,也不能以退出码判成败(与 M0A hdc 无 `[success]` 标记
   同族教训);
2. `hidumper -ls` 正常:`System ability list:` + 服务名多列输出,含
   `RenderService`、`WindowManagerService`、`AbilityManagerService`、
   `UiService` 等 ui 相关 ability。

该 evidence 的“四个流”是上述两条命令各自的 stdout/stderr，不是四个 canonical Recipe
执行。它不能证明 `-s WindowManagerService -a` 的实际 argv 参数边界，也没有任一 Recipe
成功输出可用于登记成功 marker 或 byte family。公开文档/示例可以指导人类 capture，但不能
替代目标 DAYU200 build 的受控实测。因而本 change 的 integration 决策仍未具备足够输入，
执行者不得自行发明 argv、marker 或 fake fixture 后让自己的测试通过。

r1 把全部执行硬阻塞在 `TASK-M1-006 done`。r2 试图引用 CHG-2026-014 的 consolidated
implementation bytes 解耦 scheduling dependency，但没有按其强制规则提供逐 deliverable
consumer dependency 表；同时 TASK-UD-001 未追溯 `REQ-DUMP-003` / `AC-DUMP-003-01`，
也没有要求缺失、非法或注入型 component ID 在产生 `ProcessRequest` 或 dispatch 前被阻断。
r2 的 Required environment 还没有把 `scripts/check-sdd.sh` 所需 PyYAML 解释器作为 DoR
preflight；默认 `python3` 缺少 `yaml` 时，命令无法按任务原文执行。

r3 是 review remediation：恢复 `TASK-UD-001 blocked`，补齐 consumer dependency、Core
追溯和 SDD 环境 gate，并固定 one-element `-a` candidate boundary。进一步审查确认 official
source 不是 DAYU200 target-build output-mode evidence，所以不存在可批准的 stdout-only Recipe
采集：R1-R4 首次 target execution 全部保守归为 `deviceMutation`。r3 新增 blocked
`TASK-UD-PREFLIGHT-001`，要求先由 production host-wide supervisor 固定 existing-server
endpoint/ownership/generation，再由 Core workflow durable 创建 CurrentDeviceBinding revision；
`TASK-UD-CAP-MUT-001` 只负责 R1-R3，且只有在该 preflight、dedicated fixture、confirmation、
registered exact remote-path inventory/ownership/cleanup 与 pinned semantic verifier 全部关闭后才可能
ready。R4 被拆为 `TASK-UD-CAP-R4-001`，必须等待 R2 target output family 与 versioned typed
component-tree extractor/selection receipt 获批后才能执行；十进制校验或人工选择不构成 component
provenance。realHardware semantic verifier 还必须绑定 physical model/serial/identity、binding/intents
与未过期 confirmation scope；它只能检查 claimed operator/attestation 字段一致性，不能证明真人。
此外新增独立 `TASK-UD-REDACTOR-001`，在 golden task ready 前固定 transform source、algorithm
manifest、safe-literal allowlist、receipt schema 与 replay CLI。采集只产生事实输入，不会自行定义
Recipe success marker；此前实现草案 PR #126 仅保留为不可合并的审计记录。

## What changes

### In scope

- 固定 HiDumper 调用包装:每个 Recipe 的实际 argv 形态(是否需要
  `-s <ability> -a` 前缀等)、基于输出标记(非退出码)的成败判定、错误样输出
  (如 `option ... missed`)的显式失败分类;
- 依 I5-001/M0B 先例登记 hidumper **derived** golden fixture：敏感 raw 永远留在受控仓库外
  位置，仓库只提交经 `uidump-derived-redaction-v1` 确定性转换、receipt 与人工隐私复核约束的
  derived bytes，`.gitattributes` 先行钉死 derived 资源；
- 对应 contract 测试(fake 输出对抗:标记缺失/错误样输出/exit-0 陷阱);
- integration profile/lock 相应更新。
- r3 治理修订只做以下 remediation：把 TASK-UD-001 恢复为 `blocked`；新增
  `capture-runbook.md`，在任何真机执行前固定候选 argv boundary、supervised existing-server
  sequence、durable binding materialization、保守 effect、hardware-evidence 与 raw/derived 隐私链；
  新增 blocked preflight、offline hardware-evidence semantic verifier、deterministic redactor、R1-R3
  deviceMutation capture 与后置 R4 capture tasks；增加 CHG-2026-014 逐
  deliverable consumer dependency 表；将 `REQ-DUMP-003` / `AC-DUMP-003-01` /
  `TEST-AC-DUMP-003-01` 纳入验证闭环；固定 PyYAML 解释器 preflight。r3 merge 后没有 ready
  real-device task。TASK-UD-001 只有在 verifier、redactor 与三个 realHardware 前置 task 完成且后续独立
  decision/readiness revision
  关闭全部 blocker 后才能再次起草 `blocked→ready`。

### Out of scope

- 兼容性/支持声明、matrix 行推进(真机复核属未来 M0B-002 之后的观察);
- Flash/Trace/Debug capability;Agent 执行真实 `hdc`(golden 采集由人类按
  runbook 先例执行)。
- 依据公开示例推断目标 build 的单参数 `-a` 边界，或把 `--help`/`-ls` 输出当作 Recipe
  success family；用自造 marker/fake 输出关闭验收。
- 在 `TASK-UD-PREFLIGHT-001`/`TASK-UD-CAP-MUT-001`/`TASK-UD-CAP-R4-001` 仍 blocked 时执行任何
  HDC/Recipe，或把 R1-R4 首次 target capture 降级为 readOnly；在 registered exact-path inventory
  operation 缺失时使用 raw/ad-hoc command、全局搜索/清理远端文件。
- 在 R2 output family、typed component-tree extractor OID/hash、deterministic zero/one/many selection
  rule 未获批时执行 R4，或从 operator/CLI/env/file 取得 component ID。
- 只凭 generic hardware JSON schema 起草 realHardware PASS；semantic verifier 的 source/test path、
  commit OID/hash、binding/server/intent/physical-target/confirmation input schemas 或 exact CLI 未固定
  时执行真机 task；只比较 operator 字符串后声称已证明操作者为人类。
- 由操作者提供 connect key、复用 M0B endpoint、使用 HDC 默认目标，或在 durable binding
  revision/server generation 缺失、不匹配、unknown/drift 时启动进程；隐式启动、停止、重启、
  接管或重新配置 HDC server。
- 将 raw UI Dump bytes、片段、页面文本、包/组件/窗口标识符或用户路径提交进仓库；把 derived
  golden 错标为 raw，或声称 raw/derived byte-exact equality。
- 在 `TASK-UD-REDACTOR-001 done` 前让 TASK-UD-001 ready/读取 raw，或由 golden 实现者临时决定
  redactor algorithm/safe literals/replay CLI；在 TASK-UD-001 内修改已固定 redaction toolchain。
- 将 `TASK-M1-006` 标为 done/verified，重判其任何 HDC/XCUITest evidence，或把本依赖
  解耦解释为 HDC compatibility、platform conformance、hardware/support/release claim。

## Impacted specifications

- Core behavior:none · Core baseline update:no
- ui-dump spec:按 spec.md:47 预留的 integration 钩子固定包装(spec 文本本身
  是否需措辞澄清,在 design 阶段判定;如需修改另行 revision)
- Platform Profile / Integration lock:更新(golden 登记)

## Platform impact and revalidation

| Declared platform | Disposition | Reason |
| --- | --- | --- |
| macOS | revalidate ui-dump contract tests | 包装与 golden 变更 |
| Windows | out of scope; lifecycle unchanged | no implementation or support claim |
| Linux | out of scope; lifecycle unchanged | no implementation or support claim |

## Safety, evidence and compatibility

- `TASK-RLC-001` done 与 CHG-2026-014 verified 只证明固定 bytes/interfaces 已进入 `main`，
  不能提供 M1-006 source AC；consumer 是否可用必须逐 deliverable 按
  CHG-2026-014 的表格规则判定；
- TASK-UD-001 wrapper/golden deliverables 仍按表格不消费 M1-006 source AC；但新增
  `TASK-UD-PREFLIGHT-001` 直接消费 production supervisor 的 endpoint/ownership/generation
  behavior，明确要求 TASK-M1-006 source AC/done 与 registered-probe adoption，不能套用该
  independence 结论；
- 当前 M0B manifest 仅证明 `--help` 与 `-ls`，不得标成四 Recipe capture、success marker
  或 wrapper compatibility evidence；
- `capture-runbook.md` 固定唯一 one-element `-a` candidate boundary。官方 ArkUI source 只作
  routing hint，不是目标 firmware output-mode/success 证明；R1-R4 首次 capture 全部为
  `captureRemoteFile/deviceMutation`，不得事后降级；
- HDC 命令可能隐式启动 host server。preflight 必须先以 commandless registered platform
  observation 固定 existing server 的 endpoint/process-start identity/ownership/generation，写入
  durable Job toolchain snapshot，并在每个 HDC intent 前后重验；absent/unknown/drift 时进程
  dispatch 为 `0`，本 change 不执行 server lifecycle；
- connect key 只能由指定 durable `CurrentDeviceBinding` revision materialize。人类 physical
  selection 后 `bindingCandidate`/`bindingConfirmed` 先写入 locked Session journal，capture
  harness 只接受 receipt ID + fixed revision 并经 production loader replay；operator/default/
  stale/mismatch source 的 intent/request/process count 均为 `0`；
- physical-target receipt 的 canonical model/serial、binding revision 与 identitySnapshotHash 必须和
  hardware evidence、binding receipt、每个 device intent 精确相等且未过期；mutation confirmation
  manifest 的 accepted `actor=user` entry 必须覆盖 exact related intents，scope hash 从 physical
  identity、binding/server、fixture、argv、path/inventory/receive/cleanup 重算。different device、
  stale/substituted/scope mismatch 时 dispatch `0`；
- Phase A mutation task 在 dedicated non-sensitive fixture、registered typed window inventory、
  registered exact-path sidecar inventory operation、durable human confirmation、exact pre/post
  receipt、remote ownership 与 exact cleanup 全部固定前 R1-R3 dispatch count 为 `0`；现有 catalog
  不含该 operation，generic `verifyRemoteState` 不可代用；
- R4 单独等待 R2 output-family/parser decision 与 versioned typed extractor/receipt。extractor 必须
  固定 source/resource、OID/hash、typed component schema、fixture selector 和 exact zero/one/many
  rule；manual/decimal-only/ambiguous source 的 R4 request/process dispatch 为 `0`；
- component ID preflight 必须在任何 `ProcessRequest` materialization 和 dispatch 之前；
  缺失、空值、非法格式及 shell/argument injection 输入的 request/dispatch count 均为 `0`；
- UI Dump raw 默认敏感并留在 repo 外；仓库 evidence 只含 whole-stream hash/metadata，golden
  仅能在 `TASK-UD-REDACTOR-001 done` 后只读重放 pinned exact CLI 生成 derived output，并以
  algorithm/source/manifest/allowlist/raw/derived/replay hashes、replacement counts 与 human privacy
  review receipt 闭环；TASK-UD-001 不得选择或修改 safe literals；
- 三个 future realHardware task 都必须提交 schema 2.0.0 `hardware-evidence.json`，记录 claimed
  operator、physical identity/serial、firmware/toolchain、positive binding revision、执行时间、
  exact acceptance/step kinds 与 artifact hashes，并通过固定 validator + semantic equality check；
  semantic verifier 必须先以独立 host-only task 固定 input schemas、source/test path、commit OID/
  hashes、fixed Python 与 exact CLI，并以 schema-valid physical identity/confirmation/scope mismatch
  negative tests 证明字段一致性。operator 的现实真实性仍仅由维护者 PR review/merge attestation
  保证，自动化不得扩大 claim；
- 本 r3 治理 PR 本身零 HDC/device dispatch；merge 后仍没有 ready real-device task。所有 future
  capture 的 destructive/Agent dispatch count 为 `0`，且不解除任何 `GAP-DAYU200-*`。

## Approval

- Proposal 经 PR #63 合入 `main`
  `a94b4348e0bf0e7cd0030d0a383ca65633c10b31`（2026-07-18，status:`proposed`）。
- r1 正式批准：PR #68 合入 `main`
  `ee13ba1b64f73d94395549f126b422c49d4ebd6e` 将本 change 置为 `approved`；批准由
  维护者 review/merge 该 approval-only PR 构成。
- r2 dependency/readiness revision:CHG-2026-014/TASK-RLC-001 的 implementation、done 与
  verified 分别由 PR #110、#113、#114 合入；r2 由 PR #115 合入并把 TASK-UD-001 起草为
  ready。后续 review 发现 r2 的 capture、consumer dependency、Core AC trace 与 SDD
  environment gate 不充分。
- r3 review remediation 只修订本 change 的 proposal/tasks/verification/acceptance metadata
  并新增 plan-only `capture-runbook.md`，恢复 TASK-UD-001 `blocked`、声明 blocked preflight、
  verifier、redactor 与两阶段 capture tasks，
  且不包含 harness 实现、fixture、profile/lock 或 task evidence。r3 仅在维护者 review/merge
  对应治理 PR 后生效；本 revision 明确拆分 Phase A/R4、登记 operation/extractor/verifier/redactor
  blockers、physical-target/confirmation linkage、operator attestation boundary 与 canonical AC
  ownership boundary。该 merge 不执行任何 capture/TASK-UD-001，也不使 CHG-008 verified。
