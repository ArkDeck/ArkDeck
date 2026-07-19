---
id: CHG-2026-008-ui-dump-hidumper-wrapper
revision: 2
status: approved # r1 经 #68 批准；r2 dependency/readiness revision 仅在本治理 PR 由维护者 review/merge 后生效
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
M0B 真机事实现已合入(EVD-M0B-DAYU200-20260718-001):

1. `hidumper --help` 在该 DAYU200 build 上输出单行错误样文本
   `hidumper: option pid missed. help` 且 **exit code 为 0**——包装不能用
   `--help` 做特性探测,也不能以退出码判成败(与 M0A hdc 无 `[success]` 标记
   同族教训);
2. `hidumper -ls` 正常:`System ability list:` + 服务名多列输出,含
   `RenderService`、`WindowManagerService`、`AbilityManagerService`、
   `UiService` 等 ui 相关 ability。

本 change 即该 integration change:固定包装调用形态与输出判定策略,并落地
M0B 递延的 hidumper capture golden 登记与脱敏政策。

r1 把全部执行硬阻塞在 `TASK-M1-006 done`，目的是避免两个任务同时修改
`Packages/**`。此后 CHG-2026-014 已把固定 M1-006 implementation bytes 以
`TASK-RLC-001` 汇入并登记，且该 consolidation change 已 verified。TASK-UD-001 只需要
已经进入 `main` 的 package/tool 接口与独立的 M0B HiDumper capture；它不消费 M1-006
仍缺失的 HDC integration probe、signed Sandbox XCUITest、source-task AC、platform
conformance 或 support evidence。r2 因此只解耦 implementation scheduling dependency，
不改变 M1-006 的 blocked/非 done 结论或任何验收债务。

## What changes

### In scope

- 固定 HiDumper 调用包装:每个 Recipe 的实际 argv 形态(是否需要
  `-s <ability> -a` 前缀等)、基于输出标记(非退出码)的成败判定、错误样输出
  (如 `option ... missed`)的显式失败分类;
- 依 I5-001/M0B 先例登记 hidumper golden fixture(受控人工采集、脱敏后入
  `Packages/**` 测试资源,`.gitattributes` 先行钉死二进制);
- 对应 contract 测试(fake 输出对抗:标记缺失/错误样输出/exit-0 陷阱);
- integration profile/lock 相应更新。
- 经 CHG-2026-014 允许的独立 consumer dependency revision，将 TASK-UD-001 的
  “package bytes/interfaces 已进入 main、`Packages/**` 排他占用已解除”前置从
  `TASK-M1-006 done` 改为 `TASK-RLC-001 done` + CHG-2026-014 verified；补全任务 DoR
  并在同一治理 PR 起草 `blocked→ready`。

### Out of scope

- 兼容性/支持声明、matrix 行推进(真机复核属未来 M0B-002 之后的观察);
- Flash/Trace/Debug capability;Agent 执行真实 `hdc`(golden 采集由人类按
  runbook 先例执行)。
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

- r2 implementation scheduling gate:`TASK-RLC-001` 已 done，CHG-2026-014 已 verified，
  固定 M1-006 bytes/interfaces 已进入 `main` 且原 `Packages/**` 会话排他占用解除；
  TASK-UD-001 不得消费 M1-006 尚缺的 HDC probe/XCUITest/AC evidence，也不得据此推进
  M1-006 或任何支持声明；
- golden 采集沿用只读白名单与受控位置/脱敏先例;序列号字节不入仓库;
- 零设备写操作;不解除任何 `GAP-DAYU200-*`。

## Approval

- Proposal 经 PR #63 合入 `main`
  `a94b4348e0bf0e7cd0030d0a383ca65633c10b31`（2026-07-18，status:`proposed`）。
- r1 正式批准：PR #68 合入 `main`
  `ee13ba1b64f73d94395549f126b422c49d4ebd6e` 将本 change 置为 `approved`；批准由
  维护者 review/merge 该 approval-only PR 构成。
- r2 dependency/readiness revision:CHG-2026-014/TASK-RLC-001 的 implementation、done 与
  verified 分别由 PR #110、#113、#114 合入；本治理 PR 只修订 CHG-008 的 execution
  dependency、verification environment 与 TASK-UD-001 DoR/status，不修改实现、fixture、
  profile/lock 或 acceptance evidence。r2 与 `TASK-UD-001 ready` 只有在维护者
  review/merge 本 PR 后生效；该 merge 不执行 TASK-UD-001，也不使 CHG-008 verified。
