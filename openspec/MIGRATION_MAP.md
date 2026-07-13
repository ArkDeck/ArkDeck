# PLAN → SDD Migration Map

`docs/PLAN.md` 保留为历史输入。下表是迁移覆盖索引；状态为 `migrated` 表示后续实现只能引用目标 SDD，不再引用原章节作为规则。

| PLAN 章节 | SDD 目标 | 状态 |
| --- | --- | --- |
| §1 结论 | `project.md`、`constitution.md`、architecture、相关 specs | migrated |
| §2.1 仓库状态 | `delivery/roadmap.md` | migrated |
| §2.2 附件脚本 | `references/legacy-script-analysis.md`、contracts catalogs、UI Dump/Trace specs | migrated |
| §3 产品范围 | `project.md`、UI Dump spec、planning backlog | migrated |
| §4 总体架构 | `architecture/system.md`、`platforms/macos/profile.md` | migrated |
| §5.1 Device | `specs/device-targeting-auth/spec.md` | migrated |
| §5.2 HDC | `specs/toolchain-hdc-server/spec.md`、`integrations/openharmony/profile.md` | migrated |
| §5.3 Job | `specs/workflow-journal-recovery/spec.md` | migrated |
| §5.4 Typed Step | `specs/workflow-journal-recovery/spec.md`、provider contract | migrated |
| §5.5 Storage | `specs/session-artifact-storage/spec.md` | migrated |
| §6 Process/Clock | workflow spec、platform port contract、platform profiles | migrated |
| §7.1 Discovery | HDC 与 device specs | migrated |
| §7.2 UI Dump | `specs/ui-dump/spec.md` | migrated |
| §7.3 Trace | `specs/trace/spec.md` | migrated |
| §7.4 Debug | `specs/debug-workbench/spec.md` | migrated |
| §7.5 Flash | `specs/flashing/spec.md` | migrated |
| §8 Session | Artifact spec、desktop UX/observability spec、manifest contract | migrated |
| §8.1 Diagnostics | desktop UX/observability spec、platform profiles | migrated |
| §9 信息架构 | desktop UX/observability spec、macOS profile | migrated |
| §10 安全与分发 | Constitution、HDC/security specs、platform profiles | migrated |
| §10.1 macOS Spike | `platforms/macos/profile.md` 与 verification | migrated |
| §10.2 自动更新 | `planning/backlog.md` | migrated |
| §11 测试 | `verification/` | migrated |
| §12 里程碑 | `delivery/roadmap.md`、verification policy | migrated |
| §13 产品问题 | `planning/open-questions.md` | migrated |
| §14 参考 | `references/bibliography.md` | migrated |

## 防双写规则

- 新 Requirement、AC、状态或行为变化只进入 change delta，完成后合入 current spec。
- `PLAN.md` 不再随实现更新。
- 历史背景若尚未进入 SDD，可补入 references 或 ADR；不得把历史描述直接当 normative requirement。
