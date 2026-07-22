---
id: CHG-2026-028-guard-ci-mechanization
revision: 1
status: proposed
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.1.0
platforms: [macos]
---

# guard/CI 机械化:把四类人工核验面转为机器可判定门

## Why

本 change 是 CHG-2026-027(决策分级与批次审批,propose #315 合入
`7a58b026646a3b1ed543cc5e941ddb1d1e02206f`)design §6 预告的伴随 change,两者
无先后硬依赖。D0"机器可判定"当前有四处仍靠人工核验补位,且每一处都有已发生
的事故/漂移先例:

1. **"guard 绿 ≠ Swift 绿"**:CI 只跑 sdd-guard,从不编译/测试 Swift;每个实现
   PR 合并前的全量 suite、update-branch 后合成树的重跑,全部依赖人工执行与
   诚实汇报——这是逐 PR review 中最重的机械负担(workflow-conventions 专条)。
2. **三方 revision 同步漂移**:proposal `revision` / acceptance-cases
   `change_revision` / verification `@rN` 漏同步是反复出现的漂移类
   (#129/#152/#275 三例),guard 不校验,全靠 review 抓。
3. **pins 截断**:"pins 一律全 OID/全 hash"是 review 约定,#257/#267 两次
   截断前缀都靠人(且一次是 reviewer 自己犯)。
4. **载体与内容一致靠肉眼**:enforcement"PR 载体与内容一致"与 tasks.md
   allowed paths 的遵守没有机械近似;状态 PR 夹带实现、实现越出授权面
   (#28 规则、#126 误合类、#301 remediation 类)只能靠 review 逐行比对。

每一项机械化都直接降低批次审批中 D0 项的人工核验成本,把维护者的 review
时间留给真正的判断。

## What changes(四任务,全 host-only,各自独立交付)

- **TASK-MECH-001 — macOS Swift build+test CI job**:新 workflow
  `swift-ci.yml`(macOS runner,public repo 免费额度;零 secret、
  `contents: read`);对 PR 与 `agent/**` push 运行 ArkDeckKit `swift test`
  全量;路径感知(diff 未触碰 Swift 面则快速 success,为未来 required check
  铺路,避免 path-filter + required 死锁);SwiftPM cache + timeout +
  concurrency 取消。App/XCUITest 面不进 CI(签名/模拟器面,out of scope)。
- **TASK-MECH-002 — guard 三方 revision 同步校验**:`check_sdd.py` 对 active
  changes(`archive/**` 豁免,勿改写历史)校验 proposal front matter
  `revision` == acceptance-cases.yaml `change_revision` == verification.md
  header `@rN`,不一致即具名 err;合成 fixture 正反例测试(CHG-017 形态)。
- **TASK-MECH-003 — pins 结构化全 hash 校验**:定义 fenced `pins` block 结构
  约定(readiness/评估文档中的机器可读 pin 载体);guard 校验 block 内
  git OID 必须 40 hex、sha256 必须 64 hex,截断即具名 err。**opt-in 收紧**:
  无 block 的既有文档不校验、不追溯改写;新 readiness 采用 block 后截断
  不再可能(design §3 诚实边界)。
- **TASK-MECH-004 — PR allowed-paths diff 校验**:新 CI job(PR event):
  实现 PR 声明所属 `TASK-*`(分支名/标题/body 约定)→ 解析该任务 tasks.md
  的 Allowed paths → 校验 `git diff --name-only base..head` 全落授权面内,
  超出即红;未声明任务的 PR 触碰敏感面(`Packages/**`、`ArkDeckApp/**`、
  `ArkDeckAppUITests/**`、`scripts/**`、`.github/**`)即红,纯 docs/governance
  diff 通过(propose/approval/readiness/状态 PR 形态);解析失败 fail closed。

Out of scope / Non-goals:

- **授权语义零改动**:"CI 红 = 不能合并;CI 绿 ≠ 批准"逐字保持;新增 checks
  全部只读、零 secret、不承担任何批准/授权判断。
- 新 check 翻转为 branch protection required status = 维护者 GitHub 设置动作
  (CHG-2026-027 分级下的 D2),不属任何实现 PR;evidence gate 见 tasks。
- 既有漂移的修复不混入 guard 实现 PR:实现前扫描,如有存量漂移,以漂移所属
  change 名义独立 PR 先行修复(readiness 钉扫描结果)。
- `archive/**` 全体豁免全部新校验(归档 = 冻结历史)。
- Core spec/contract/schema/constitution/enforcement 零改动;CORE baseline
  不升版;POL-* 原文不动。
- 设备/硬件零涉及;XCUITest/App 构建、性能基准、覆盖率门不进本 change。

Observable behavior before/after:

- Before:Swift 全量、revision 同步、pins 完整性、diff 授权面四项全靠人工
  核验与诚实汇报;CI 只报规格结构一致性。
- After:四项均有机器门,PR 页直接可见红绿;人工 review 聚焦语义与判断。
  合并语义、批准载体、信任根与 before 完全一致。

## Scope(涉及的 Requirement/AC)

- Requirements:无(canonical Core AC 零认领)
- Acceptance:四条 change-local(`MECH-CI-001`/`MECH-REV-001`/`MECH-PIN-001`/
  `MECH-PATH-001`,见 acceptance-cases.yaml)
- Core baseline bump:不需要

## Safety, privacy, and compatibility

- Failure modes:**每个新 check 必须证明会红**(canary 反证,先例 TR-002R
  real-fault;exit0≠成功教训)——只有绿证据的 check 不接受;guard 新校验的
  误报以 0/0/111 基线保持为门(实现前后全仓零新 err);MECH-004 解析失败
  fail closed(err 而非静默跳过)。
- 边界诚实性:MECH-004 是 guard-rail 不是安全边界——任务声明可谎报,防线仍是
  维护者 review 与"载体与内容一致"条款;它机械关闭的是无意混装与状态 PR
  夹带实现两类事故形态。
- 隐私:CI 全部只读公开仓内容,零 secret、零设备、零外部上传。
- 兼容:MECH-002/003 同改 `check_sdd.py`/`test_check_sdd.py`,两任务串行交付
  或同会话协调(readiness 钉基 blob);对既有 active changes 的校验以实现前
  扫描 + 先行修复保证零新 err;workflow 文件推送若受凭据 workflow scope 限制
  (BAP-003 凭据分离后预期收紧),交付形态 = agent 起草 + 维护者应用,仍走
  PR(design §5)。
- Rollback:每项独立 revert 即回到人工核验;无持久状态、无数据迁移。

## Approval and flow

V2 治理:本 propose PR 合入仅登记提案;批准须独立 approval-only PR;四任务
各自独立 readiness/实现/done PR。change verified = 四 AC 有可复查证据(含
各自 canary 红反证)+ 0/0/111 基线与 Swift 基线保持(另行 verify PR)。
