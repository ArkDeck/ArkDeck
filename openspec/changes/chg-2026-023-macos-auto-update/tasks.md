# CHG-2026-023 Tasks

> 两任务分期,各自独立 readiness/实现/done PR。本 change 首 PR 只 proposal +
> design,零实现、零依赖引入、零 evidence。

## TASK-AU-001 — 更新机制评估与选型(documentReview,host-only)

- Status:blocked(双前置:① CHG-2026-023 经 approval-only PR 批准;② 独立
  readiness PR——须复核评估维度封闭性与信息源边界)
- Objective:在 {Sparkle 2 sandbox/XPC 模式, 最小自研 check+download+verify} 间
  做有据选型(design §1 五维度逐维落 facts:sandbox/XPC 与 entitlement diff、
  供应链面(首个第三方依赖 vs 自研维护)、验签链 fail-closed、失败/回滚诚实性、
  隐私最小化),产出选型决策记录;owner review/merge = 选型认可。
- Requirements/AC:change-local `AU-EVAL-001`(见 acceptance-cases.yaml)。
- Depends on:approve;信息源 = 官方文档/源码(Sparkle 仓库、Apple 文档)与本
  仓库 ADR-0002/profile 基线,零安装零执行第三方代码。
- In scope:评估文档 + 选型记录 + evidence run;facts 逐条带来源。
- Out of scope:任何依赖引入/实现/网络服务搭建;改 ADR/profile(同步归 AU-002
  或独立 ledger PR)。
- Allowed paths:本 change `evidence/**`、本 change `tasks.md`(仅本任务状态)。
- Risk:low(纯文档评估;选型错误的代价由 AU-002 readiness 前的复核兜底)。
- Hardware required:no。
- Verification:`AU-EVAL-001` documentReview——五维度逐维有据、结论可追溯、
  未选路线的排除理由明确;check-sdd 绿。
- Evidence gate:评估+选型 PR 合入后 `ready→done` 独立状态 PR。

## TASK-AU-002 — 实现与发布管线面

- Status:blocked(三前置:① approve;② TASK-AU-001 done(选型认可);③ 独立
  readiness PR——须钉选型记录 OID、依赖 pin 方案(如适用)、entitlement diff
  声明与实现基线)
- Objective:按选型集成应用内自动更新:检查(手动 + 可开关的自动)、显式同意
  安装、验签 fail-closed 双层(design §0)、隐私最小化字段与披露文案、
  SystemLogger 事件类扩展;发布侧 = feed 生成与 EdDSA 私钥处理规程(私钥永不
  入仓);若引入依赖:版本+hash pin 与 license notice 随实现 PR 交付;若引入
  XPC/entitlement 增项:同 PR 更新 ADR-0002 声明并测试断言一致。
- Requirements/AC:change-local `AU-CONTRACT-001`/`AU-PRIVACY-001`(见
  acceptance-cases.yaml)。
- Depends on:approve、TASK-AU-001 done。
- In scope:`ArkDeckApp/**`、`Packages/ArkDeckKit/Sources/**`(更新检查/验签
  逻辑与测试)、发布规程文档、本 change `evidence/**`、本 change `tasks.md`
  (仅本任务状态);依赖清单文件(如适用)。
- Out of scope:遥测/crash 上报(DEC-008)、delta 更新、分轨、release 本身。
- Risk:medium(首个出站网络面 + 可能的首个第三方依赖;fail-closed 与隐私
  边界是核心不变量)。
- Hardware required:no。
- Verification:`AU-CONTRACT-001` 验签 fail-closed 矩阵(feed 签名坏/缺、下载物
  Team 不符/未签名、中断/截断——全部零安装动作)+ 零静默安装 + entitlement 集
  与声明一致断言;`AU-PRIVACY-001` 更新检查请求字段白名单断言(零设备/用户
  标识)+ 披露文案存在;全量基线零回归。
- Evidence gate:contract 全绿 + 发布规程文档在案后合入;`ready→done` 独立状态
  PR;change verified = ADR-0002 release gate #3 满足(另行 verify PR)。
