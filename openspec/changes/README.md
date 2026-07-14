# Change Package Workflow

Current specs 不能直接修改。任何行为、contract、平台设计或实现工作都从 change package 开始。

## 命名与状态

```text
folder: chg-yyyy-nnn-short-name
display ID: CHG-YYYY-NNN
proposed → approved → implementing → verified → archived
        └→ rejected
```

- 状态写在 `proposal.md` front matter 的 `status:` 字段,经 PR 修改;**维护者合并该 PR 即构成状态转换的人类批准**。
- `approved`:范围、delta 与验证计划被维护者认可,任务可以开始。
- `verified`:`verification.md` 中全部 AC 有可复查证据且维护者在 PR 中确认。
- `archived`:delta 已合入 current specs,目录移入 `changes/archive/YYYY-MM-DD-<id>/`。
- 批准后需要改变范围:直接在同一 change 内经 PR 修订 proposal/tasks(修订历史即 git 历史);不再使用 supersession barrier/新 Change ID 仪式。已 archived 的 change 不改写。

## 必需 artifacts

```text
openspec/changes/<change-id>/
├── proposal.md          # why/what、change class、范围(涉及的 Requirement/AC 清单)、平台影响
├── tasks.md             # 任务清单与状态(ready/in_progress/done/blocked),每任务含范围、allowed paths、验证方式
├── verification.md      # 每个 AC 的验证方法、所需 evidence 与结论
└── evidence/            # run 记录与产物(按 task 分子目录;格式轻量,如实分类 simulation/real)
```

可选(按需):

```text
├── design.md                            # 设计与 ADR
├── specs/<capability>/spec.md           # behavior change 的 ADDED/MODIFIED delta
├── spec-impact.md                       # platform/implementation-only change 用,替代 no-op delta
├── acceptance-cases.yaml                # change-local AC 的方法/证据登记
└── review.md                            # 评审记录
```

模板位于 `openspec/templates/change/`。Folder name 使用 lowercase kebab-case;大写审计 ID 写在 proposal front matter。

## Change classes

- `core`:改变跨平台行为、Safety、AC 或 schema;需要 baseline 版本升级(`CORE-x.y.z`)。
- `capability`:在既有 Core 下新增/修改用户可观察能力。
- `integration`:OpenHarmony/HDC/工具版本适配;不得降低 Core。
- `platform`:macOS/Windows/Linux 工程、权限、UI、打包或 Port;不得改变 Core AC。
- `implementation-only`:不改变可观察行为和 pass/fail 的重构、测试或基础设施。

## Delta 格式

规格 delta 使用:

```text
## ADDED Requirements
## MODIFIED Requirements
## REMOVED Requirements
## RENAMED Requirements
```

- MODIFIED 必须包含完整的新 Requirement 文本与完整 Scenario 集,保留该 Requirement 的全部既有 AC ID;新增 AC 可以加入。
- REMOVED/RENAMED 需要在 proposal 中说明迁移与 tombstone;ID 永不复用。
- behavior change 声明 Core MINOR/MAJOR,并简要说明对各 declared platform 的影响(已交付平台需给出 reverify 结论;未启动平台一句带过即可)。

## 实现期的有效规格

```text
pinned current baseline + approved scoped delta overlay
```

Delta 只替换其中列明的 Requirement/AC,其他规则仍来自 baseline。不得借用另一个 change 的新增 ID。

## Archive

change verified 后,由一个 archive PR 完成:

1. 按 approved delta 更新 `openspec/specs/**` 与 acceptance registry(index + cases);behavior/core change 同时升版 baseline 文件;
2. 将 change 目录移动到 `changes/archive/YYYY-MM-DD-<id>/`;
3. CI 校验更新后 specs/registry 一致;维护者 review 该 PR 确认 delta 与 specs 变更精确对应。

Archive 保留 proposal/design/tasks/evidence 作为"为什么改变"的历史;current specs 只保留"现在系统应如何行为"。
