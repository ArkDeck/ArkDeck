---
id: CHG-2026-018-hdc-acceptance-applicability
revision: 1
status: archived # 2026-07-21 本 archive PR(=CORE-2.1.0 ratification 载体,先例 #178/#21);verified 于同日 #201 `aeed69d`
class: core
core_change_level: minor
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# HDC 条件化 acceptance 适用性:AC-HDC-006-01 / AC-HDC-009-01 的处置载体

## Why

TASK-M1-006 实现已经 PR #191 合入(maintainer review,squash `c61e10e`)并经 PR #192 依
`evidence/runs/TASK-M1-006/run.md` addendum 23 诚实收口为 `blocked`。addendum 23 认定的三项
缺口中,本 change 只处置第 ②③ 两项——它们不是实现缺陷,而是 **ratified acceptance 前提与
maintainer-accepted integration 事实之间的结构性矛盾**:

- ② `AC-HDC-006-01`(Scenario 前提:「GIVEN 平台权限阻止当前 HDC 访问其 key」):
  `OPENHARMONY-HDC-READONLY-PROBES@1.0.0`(CHG-2026-015,PR #159/#163,provenance
  #141/#155/#156)将 `keyAccessDiagnostics` family 登记为 `unsupported`,理由原文:
  "No configured or user-approved HDC key locator was identified; the captured
  conventional-path absence cannot grant production path authority."。同时
  `REQ-HDC-006` 明文规定默认 key 路径「SHALL NOT 被 Core 硬编码为稳定 API」。在 pinned
  3.2.0d tuple 上,ArkDeck 没有任何被授权的方式定位 key,该 GIVEN 前提无法被合法产生;
  零访问负向测试不构成、也不得冒充该 AC 的 platform file-access denial evidence。
- ③ `AC-HDC-009-01`(Scenario 前提:「GIVEN HDC 宣称支持 subserver」):同一 registry 将
  `subserverCapability` 登记为 `unsupported`,理由原文:"The reviewed upstream source is
  3.2.0b rather than the exact 3.2.0d target and proves no client-local,
  zero-lifecycle/device-migration observation command for the target revision."。上游命令面
  审读(#141)证明不存在零副作用的 capability 观察命令,该 GIVEN 前提同样无法被合法产生。

`CORE-CONFORMANCE-2.0.0` 的 applicability rule 规定平台不得自行删除 acceptance ID、改变
expected result 或宣称 not applicable——"Any applicability change requires a Core change and
a new conformance-suite version."。本 change 就是该规则要求的 Core change 载体。

不处置的后果:CHG-2026-002 的 Gate 要求全部 62 个 Core AC 有可复查证据,而 ②③ 在当前
registry 事实下永远无法闭合,M1 收官被结构性卡死;唯一替代路径(为凑 evidence 而发明 key
路径权限或 subserver 探测命令)恰恰违反 REQ-HDC-006/POL-HDC-001 的安全边界,已被 M1-006
review 链(addenda 16-23)多轮否决。

## What changes

### In scope

- `TASK-CA-001`:对 `openspec/verification/core-conformance.yaml` 做一次 additive 修订并升版
  `CORE-CONFORMANCE-2.1.0`:
  - 新增 `applicability.integration_conditional` 机制,仅登记 `AC-HDC-006-01` 与
    `AC-HDC-009-01` 两条:当且仅当 pinned OPENHARMONY-TOOLS readonly-probes registry 以
    maintainer-accepted provenance 将对应 family(`keyAccessDiagnostics` /
    `subserverCapability`)显式登记为 `unsupported` 时,该 AC 在受影响平台的 verification
    arithmetic 中记为 `notApplicable(integrationConditional)`,合规平台结果 = registered
    fail-closed unsupported 诊断 + 零未授权 dispatch(M1-006 已交付并证明);registry 将
    family 翻为 `supported` 时,该 AC 立即恢复 applicable,依赖排除的任何 verified/
    conformance 结论转 needsReverification。**缺 registry、family 缺失、hash 不符或
    provenance 不可追时,排除不成立,AC 保持 applicable(未满足)**——排除只能由显式登记
    的 unsupported 事实构成,不能由沉默构成。
  - `shared_inputs` 补记 `OPENHARMONY-TOOLS@0.3.0` profile、`readonly-probes.yaml`
    registry 与 `INTEGRATION-PROFILES-0.4.0` lock(additive;0.2.0 Golden 输入原条目保留)。
  - acceptance index/cases 的 111 计数与全部 canonical method/expected result **零变更**。
- 起草 `openspec/baselines/CORE-2.1.0.yaml`(supersedes CORE-2.0.0,change 为本 change,
  core_change_level minor);按 baseline change_rule,ratification = 维护者 review/merge 本
  change 的 archive PR,此前仅为待批准声明。

### Out of scope / Non-goals

- 不修改 `openspec/specs/**` 任何 Requirement/Scenario 原文;`REQ-HDC-006`(不复制/删除/
  上传/记录私钥)与 `REQ-HDC-009`(SHALL NOT 自动 spawn-sub/killall-sub)的义务全量保留,
  且已有 M1-006 零 dispatch 仪表化 evidence 背书。
- 不删除任何 acceptance ID,不改变任何 canonical method/expected result/minimum evidence;
  不触碰 `acceptance-cases.yaml`/`acceptance-index.txt`。
- 不修改 readonly-probes registry、integration profile/lock、platform profile/lock 或任何
  fixture(变更须走独立 integration change)。
- 不处置 addendum 23 缺口 ①(production App-root participant/critical-state inventory
  feed)——其处置须另行立项;本 change 合入后 TASK-M1-006 仍因缺口 ① 保持 `blocked`。
- 不翻转 TASK-M1-006 状态、不构成 CHG-2026-002 verified、platform conformance、
  hardware/support 或 release claim。CHG-2026-002 账本(Gate 算术引用 2.1.0 suite)的同步
  属后续独立 governance ledger PR(先例 #193),不在本 change allowed paths。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR(先例 #55/#89/#171)。
其后按「readiness PR → 实现(manifest+baseline 起草)PR → archive PR(=ratification)」
推进;`TASK-CA-001` 在 approve + readiness 双前置满足前保持 `blocked`。

## Approval

- r1 proposal 经 PR #194 合入 main(squash `0f87bd7`,status:proposed)。
- 正式批准:2026-07-21 由本 approval-only PR(先例 #55/#89/#171)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。merge 即批准 design.md normative
  草案所列 delta 形态:`integration_conditional` 机制及其 fail-closed 排除条件、仅
  `AC-HDC-006-01`/`AC-HDC-009-01` 两条登记、reactivation/needsReverification 语义、
  `CORE-CONFORMANCE-2.1.0` suite 升版与 `CORE-2.1.0` baseline 起草授权。
- 本批准不产生任务执行:`TASK-CA-001` 保持 `blocked`,须独立 readiness PR(确认执行时
  base revision 与 registry/provenance pins 无漂移)转 `ready`;实现后 `done` 翻转与
  archive PR(=ratification)各为独立 PR。本批准不翻转 TASK-M1-006 状态(缺口 ① 仍在),
  不构成 CHG-2026-002 verified、platform conformance、hardware/support 或 release claim。

## Verification closure(2026-07-21)

- 依据:TASK-CA-001 done(实现 PR #197 squash `3e85073` 与 review head 零树差;done
  状态 PR #199 squash `e8584b6`);change-local acceptance matrix 两行
  `CA-HDC-APPLICABILITY-001/002` 均 `passed`,evidence 在
  `evidence/runs/TASK-CA-001/run.md`。
- Gate 复核:两个 Evidence ID 均 PASS 且有 run 记录 ✓;`CORE-2.1.0.yaml` baseline 草案
  在案(status: draft)✓;canonical 111 与 specs 零变更 ✓;`check-sdd` 0/0/111 ✓。
- 本 `verified` 由维护者 review/merge 本 PR 构成(先例 #175/#176)。它不构成
  ratification——archive PR 另行(移目录入 archive + baseline `draft→ratified`);也不
  翻转 TASK-M1-006 状态,不构成 CHG-2026-002 verified、platform conformance、
  hardware/support 或 release claim。macOS `conformance_status` 保持 `notStarted`。
