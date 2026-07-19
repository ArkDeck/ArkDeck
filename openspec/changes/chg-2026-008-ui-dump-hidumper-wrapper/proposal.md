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
追溯和 SDD 环境 gate，并明确唯一可接受的 capture/decision 输入。r3 不固定未知 argv/marker，
不采纳任何基于猜测的实现或 acceptance evidence；此前实现草案 PR #126 仅保留为不可合并的
审计记录。

## What changes

### In scope

- 固定 HiDumper 调用包装:每个 Recipe 的实际 argv 形态(是否需要
  `-s <ability> -a` 前缀等)、基于输出标记(非退出码)的成败判定、错误样输出
  (如 `option ... missed`)的显式失败分类;
- 依 I5-001/M0B 先例登记 hidumper golden fixture(受控人工采集、脱敏后入
  `Packages/**` 测试资源,`.gitattributes` 先行钉死二进制);
- 对应 contract 测试(fake 输出对抗:标记缺失/错误样输出/exit-0 陷阱);
- integration profile/lock 相应更新。
- r3 治理修订只做以下 remediation：把任务恢复为 `blocked`；固定 human capture 与后续
  decision revision 的最低输入；增加 CHG-2026-014 逐 deliverable consumer dependency
  表；将 `REQ-DUMP-003` / `AC-DUMP-003-01` / `TEST-AC-DUMP-003-01` 纳入验证闭环；固定
  PyYAML 解释器 preflight。只有后续独立 revision 关闭全部 blocker 后才能再次起草
  `blocked→ready`。

### Out of scope

- 兼容性/支持声明、matrix 行推进(真机复核属未来 M0B-002 之后的观察);
- Flash/Trace/Debug capability;Agent 执行真实 `hdc`(golden 采集由人类按
  runbook 先例执行)。
- 依据公开示例推断目标 build 的单参数 `-a` 边界，或把 `--help`/`-ls` 输出当作 Recipe
  success family；用自造 marker/fake 输出关闭验收。
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
- 当前 M0B manifest 仅证明 `--help` 与 `-ls`，不得标成四 Recipe capture、success marker
  或 wrapper compatibility evidence；
- component ID preflight 必须在任何 `ProcessRequest` materialization 和 dispatch 之前；
  缺失、空值、非法格式及 shell/argument injection 输入的 request/dispatch count 均为 `0`；
- golden 采集沿用只读白名单与受控位置/脱敏先例;序列号字节不入仓库;
- 零设备写操作;不解除任何 `GAP-DAYU200-*`。

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
- r3 review remediation 只修订本 change 的 proposal/tasks/verification/acceptance metadata，
  恢复 `blocked` 且不包含实现、fixture、profile/lock 或 evidence。r3 仅在维护者 review/merge
  对应治理 PR 后生效；该 merge 不执行 TASK-UD-001，也不使 CHG-008 verified。
