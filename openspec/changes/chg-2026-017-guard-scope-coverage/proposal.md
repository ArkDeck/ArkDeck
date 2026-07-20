---
id: CHG-2026-017-guard-scope-coverage
revision: 2
status: approved # r1 经 PR #181 批准;r2 acceptance-ID grammar 修订仅在维护者 review/merge 本 governance PR 后生效
class: implementation-only
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# check_sdd guard:per-change scope 覆盖校验

## Why

2026-07-20 全任务面深度 review 的 CHG-2026-002 pre-verify 台账发现 **AC-JOB-003/004
归属断链**:两个 AC 在 `scope.yaml` 的 `acceptance:` 列表内,但**没有任何任务的
`Requirements/AC:` 行认领它们**,导致 `verification.md` 的"任务分配并集 == scope"
不变式为假。该缺口**静默存在**,只在人工 pre-verify 审计时才被发现(已由追溯修复
PR #138 补认领)。

根因是 guard 能力缺口:当前 `scripts/check_sdd.py` 只校验 change artifact 结构、
三方 AC 集合(specs/index/cases)一致与 capability registry 1:1,**不校验各 change
内部"scope.yaml acceptance 列表 ⊆ 各任务 Requirements/AC 认领并集"**。本 change 增强
guard 以自动拦截该类断链,把"人肉双开发现"变为机器侧 fail-closed——这是 backlog 已
登记的 guard 增强项(`openspec/planning/backlog.md`)。

## What changes

### In scope

- `TASK-GUARD-001`:在 `scripts/check_sdd.py` 增加 per-change scope 覆盖校验——对
  **含 `scope.yaml` 的 change**(当前 M0A/M1/CHG-005/M0B 四个),校验 `scope.yaml` 的
  `acceptance:` 列表中每个 acceptance ID 都被该 change 至少一个任务的
  `Requirements/AC:` 行(含其缩进续行)以**不透明、大小写敏感的完整字符串**
  精确认领;未认领即 `err`(fail-closed)。语法不限于 `AC-*`,同样覆盖
  `MAC-*`/`HW-*` 与未来写入 scope 的 acceptance ID。不含 `scope.yaml` 的
  change 跳过(与现状一致,guard 不强制 scope.yaml)。
- 新增 `scripts/test_check_sdd.py`:合成 fixture 证明——完整覆盖通过、故意漏认领一个
  scope acceptance ID 即被具名 err;`AC-*`/`MAC-*`/`HW-*`、反引号、
  `、`/`；`/`;`/空格分隔与缩进续行正例;以及 `…`/`*`/`01/02`/`等`
  **不构成隐式认领**的反例。
- 实现前必须先由独立 traceability remediation PR 将四个现有 scoped change
  的认领改为显式完整 token,再经新 readiness PR 复跑证明四者全部通过;
  未满足时 `TASK-GUARD-001` 保持 `blocked`。

### Out of scope

- 反向校验(任务认领 ⊆ scope):任务可引用 canonical Safety input 等 scope 外 AC
  (read-only,不认领 completion),故只做单向 `scope acceptance ⊆ claimed`;
- 从 `…`、`*`、`01/02`、`等` 或自然语言推断未写出的 acceptance ID;
- 在本 grammar 修订 PR 内修改旧 change 的 `scope.yaml`/`tasks.md`;显式追溯补齐
  必须使用后续独立 remediation PR;
- 为无 scope.yaml 的 change 补建 scope.yaml(属各 change 自身治理,不在本 change);
- `requirements:` 覆盖校验(本 change 只做 acceptance 覆盖,requirements 覆盖可后续
  revision 追加);
- 任何 spec/contract/baseline/product/设备变更。

## Approval

- r1 proposal 经 PR #180 合入 main(`status: proposed`)。
- r1 正式批准由 approval-only PR #181 的维护者 review/merge 构成。
- r2 grammar 修订由维护者 review/merge 本独立 governance PR 构成;修订只
  固定精确认领语义,不产生任务执行。`TASK-GUARD-001` 保持 `blocked`,
  仍须 traceability remediation + 新 readiness PR。

## Risk and boundary

- 风险=false positive(把已显式认领误报)或 false negative(从简写推断认领):
  由不透明 ID 动态精确匹配、标识符边界、简写拒绝 fixture 与后续
  "current main 四 change 全过"基线共同钉死;任一 false positive 必须修解析器,
  不得放宽语义。
- class `implementation-only`、`core_change_level: none`:仅改 guard 工具与新增测试,
  零 spec/contract/baseline/conformance/product 变更,无 ratification 成分。
- 不改变任何既有 change 的状态或 AC;增强生效后现状 guard 仍 `0/0/111`。
