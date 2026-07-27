# CHG-2026-040 Verification Plan

> Status:planned
> Change:CHG-2026-040-automation-decoupling@r2
> Core baseline:CORE-2.1.0（零 Core 变更;canonical Core AC 零认领）

验收面全部 change-local。总原则：每项修复必须有一个「撤销该修复即变红」
的测试（变异门）;任何协议常量取值漂移、任何 fail-open 方向的语义放宽、
任何对历史持久化载体（lease refs / cursor Issue / 既有 PR body）的解析
回归破坏，整体 fail。

## Change-local

| Evidence ID | Task | Method | Expected result |
| --- | --- | --- | --- |
| DEC-CONF-001 | DEC-001 | contract | automation_config.json 五项与原硬编码逐字节相同（对照测试）;缺失/未知 key/空表/非字符串/重复项五种畸形各有红 fixture;敏感判定对既有 fixture 语料零行为漂移;README 边界地图覆盖 scripts/ 全部一级条目 |
| DEC-CONST-001 | DEC-002 | contract | instance.py 每个搬移值有字节相等冻结测试;lease 命名空间/task 文法/base 分支各余恰一处定义（grep 清点入 evidence）;全量套件与 check-sdd 基线保持;对线上 lease ref、cursor Issue、既有 worker PR body 的解析回归绿 |
| DEC-SDD-001 | DEC-003 | contract | A-H1 跨界吸收、A-H2 空 scope、A-M1 双行/零行与词表尾边界、A-M2 重复 id、A-M4 各 null 形态——每项红 fixture + 撤销即红;sdd-guard 运行 test_check_sdd 与 host_loop 套件的 CI run 证据;现仓 guard 0 error 保持（或附存量清点与处置记录） |
| DEC-PRP-001 | DEC-004 | contract | 自扩权 fixture（同 PR 放宽 tasks.md + 触敏感路径）被拒;散文吸收 fixture 零吸收;--event 伪 base fixture 被拒;homoglyph 标题致歧义错误;--identity-only 对读回篡改变红;对现仓全部 active tasks.md 的解析清点报告（吸收项归零或逐项裁决）;全部修复撤销即红 |
| DEC-HL-001 | DEC-005 | contract | 3xx 以状态呈现、不跨主机、token 不外发;read/observed_main 拒 refname 不等与多行（正对照通过）;异主 renew → FenceLost（同主正对照通过）;GIT_CONFIG 注入失效;403+限流头 → TransportError;Python minter 等死代码退役零残留;NEVER_CLAIM_ROOTS 含 TASK-DEC 根且现循环对 DEC 任务零认领;真实远端只读冒烟不变 |
| DEC-REV-001 | DEC-006 | contract | 尾部引用 VERDICT 不再翻转（旧钉测试反转 + 变异门）;(number,head) 去重双向 fixture;`(#N)` 尾锚定双向 fixture;phantom header/跨行 id 修复;confirm_merge 零引用;历史 worker PR body 语料解析回归绿 |
| DEC-NAV-001 | DEC-007 | contract | 空值/散文捕获改省略任务（合法续行正对照仍解析）;cursor 损坏 → exit 20（健康路径 exit 语义不变）;假 correction 消除;corrections 进 reconcile 轮 detail;test_discovery_contract 直跑与模块跑计数相等;全仓 active tasks.md 解析清点报告 |
| DEC-LEFT-001 | DEC-009 | contract | `observed_main` 拒绝 refname 不等/多行（正对照:单行精确匹配仍读出 OID）;`FakeApi` 的 `GET /issues/{n}` 路由补齐后套件全绿且 `test_closed_cursor_issue_is_refused` 真正驱动其 fake;TASK-DEC-005 的 Allowed/Forbidden 交集归零;每项配「撤销即红」变异门 |
| DEC-MINT-001 | DEC-008 | contract + D2 receipt | staged 阶段注入失败 → trap 清理零残留（成功路径正对照）;sidecar root 属主 600 断言;弱断言替换;D2 窗口 receipt:重装前后双 digest、干跑 exit 语义不变、token 600 复核 |

## Gate

九条全 PASS 且各任务 evidence run 在案，任务方可 done;DEC-008 的 done
另需维护者 D2 重装 receipt。change verify 于全部任务 done 后独立 PR
收口。台账（review-findings.md）中 noted-not-tasked 项不构成本 change
验收面，其处置（立项/接受/搁置）由维护者裁量。
