---
id: CHG-2026-008-ui-dump-hidumper-wrapper
revision: 1
status: approved # r1 proposal 经 #63 合入;批准由本 approval-only PR 的维护者 review/merge 构成
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

## What changes

### In scope

- 固定 HiDumper 调用包装:每个 Recipe 的实际 argv 形态(是否需要
  `-s <ability> -a` 前缀等)、基于输出标记(非退出码)的成败判定、错误样输出
  (如 `option ... missed`)的显式失败分类;
- 依 I5-001/M0B 先例登记 hidumper golden fixture(受控人工采集、脱敏后入
  `Packages/**` 测试资源,`.gitattributes` 先行钉死二进制);
- 对应 contract 测试(fake 输出对抗:标记缺失/错误样输出/exit-0 陷阱);
- integration profile/lock 相应更新。

### Out of scope

- 兼容性/支持声明、matrix 行推进(真机复核属未来 M0B-002 之后的观察);
- Flash/Trace/Debug capability;Agent 执行真实 `hdc`(golden 采集由人类按
  runbook 先例执行)。

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

- 执行硬门:`Packages/**` 当前由 TASK-M1-006 会话独占,本 change 全部执行
  blocked 于 M1-006 done 合入 main(见 tasks.md);proposal/approve 可先行;
- golden 采集沿用只读白名单与受控位置/脱敏先例;序列号字节不入仓库;
- 零设备写操作;不解除任何 `GAP-DAYU200-*`。

## Approval

- Proposal 经 PR #63 合入 main(`a94b434`,2026-07-18,status:proposed)。
- 正式批准:2026-07-18 由本 approval-only PR(先例 #14/#40/#55)将本 change 置为
  `approved`;批准由维护者 review/merge 本 PR 构成。本批准不产生任务执行:
  TASK-UD-001 保持 blocked 直至 `TASK-M1-006` done 合入 main(`Packages/**`
  独占解除),解除另需独立 readiness/status PR 复核。
