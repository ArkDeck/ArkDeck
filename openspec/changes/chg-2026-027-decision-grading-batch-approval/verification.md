# CHG-2026-027 Verification Plan

> Status:planned
> Change:CHG-2026-027-decision-grading-batch-approval@r1
> Core baseline:CORE-2.1.0(零 Core 变更;canonical Core AC 零认领)

验收面全部为 change-local(见 acceptance-cases.yaml)。任何形式的 auto-merge、
任何把 digest 当作批准依据的表述、任何"批次合并 = 打包一次批准"的语义、
演练中出现判断门后的投机堆叠或未 approved scope 的实现内容,整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| BAP-GOV-001 | BAP-001 | documentReview | enforcement.md 2.1.0 决策分级定义可操作(D0 = 三条件:结论由 main 已合入状态 + 确定性检查完全决定、diff 零新 scope/零新风险接受/零新授权、零权威文件语义变更;D1/D2 门类封闭列举);批次协议明确"按 digest 声明顺序逐 PR 合并 = 逐项批准、digest 无批准语义、遇拒停依赖链、无 auto-merge";AGENTS.md 同步且与 enforcement 零冲突;信任根/权威顺序文本零改动 |
| BAP-DRILL-001 | BAP-002 | documentReview | 首次批次演练全程可复查:≥2 个真实 D0 项(天然产生,非为演练制造)各携独立 AI 合前 review APPROVE 经完整 digest 入队;维护者按 digest 声明顺序逐 PR review/merge;守望会话凭 merge OID 检测(非分支消失/时间推断)自动续跑;批次内零未 approved scope 的实现内容;runbook/模板与实际流程一致,偏差如实记录 |
| BAP-CRED-001 | BAP-003 | documentReview | Agent 环境凭据仅能推送 `agent/**`:正向证据(agent/** 推送成功)+ 负向证据(非 agent/** ref 推送被拒)双向在案;维护者凭据与批准动作不在 Agent 可达进程/密钥环;凭据值/token 零入仓零入 evidence |

## Gate

本 change `verified` 前提:三 task done(各有 merged 交付/执行记录 + 独立
done PR + evidence);三 change-local AC 有可复查证据;首次批次演练 evidence
在案。verified 不构成对后续每个批次的质量担保——逐 PR review 永远是唯一批准
载体;也不构成 guard/CI 机械化四项(伴随 change)的任何完成声明。
