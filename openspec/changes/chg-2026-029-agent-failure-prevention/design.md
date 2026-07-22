# CHG-2026-029 Design：Agent 失败模式检索与任务期预防

> Status:candidate（随 proposal r1；批准前不构成实现授权）
> Core baseline:CORE-2.1.0（零 Core/product behavior 变更）

## 1. Authority boundary

`agent-failure-patterns.md` 是**非权威导航索引**，不属于 Constitution、spec、contract、
integration/platform profile、enforcement 或 execution policy。它可以：

- 引用 canonical rule 与历史 evidence；
- 概括重复失败的触发信号和预防动作；
- 指出某项防线已由哪个 guard/CI 覆盖，或仍需语义 review；
- 帮助新 task 选择需要显式回答的问题。

它不得：

- 新增、改写或放宽 Requirement/AC/Safety/approval 语义；
- 把某个历史实现细节提升为跨平台产品规则；
- 把未批准建议描述为 required gate；
- 将 evidence 链接本身解释成 task done/change verified；
- 复制 raw evidence、秘密、真实设备标识或大段日志。

手册首屏固定给出权威顺序与冲突处置：发生冲突时忽略手册建议，按 `AGENTS.md`
权威顺序处理；无法裁决时任务 blocked，而不是由手册选择方便解释。

## 2. Pattern record contract

首批每个 `AF-NNN` 使用相同 Markdown 结构：

1. **Signal**：开工/readiness/review 时可观察的触发信号；
2. **Observed cases**：仓库相对路径、PR/完整 Git OID；事实与推断分开；
3. **Root cause**：解释为何现有检查未在更早阶段发现；
4. **Preflight**：实现前必须显式回答的问题；
5. **Verification**：至少一个正向、一个反向/故障向方法；
6. **Canonical references**：仅链接，不复制或重写 normative 语义；
7. **Automation status**：`mechanized` / `partiallyMechanized` / `semanticReview`，
   写明真实边界，CI 绿不解释为批准；
8. **Currency**：最近复核的完整 protected-main OID 与日期。

`AF-NNN` ID 不复用。后续发现只是既有模式的新案例时追加 case/currency；只有根因、
预防动作或验证面不同才新增 ID。任何更新仍需处在 approved change/ready task 的
allowed paths 内并由维护者 review/merge，手册本身不创造该授权。

## 3. Initial taxonomy and routing

| ID | Primary decision point | Existing machine help | Semantic question retained |
| --- | --- | --- | --- |
| AF-001 | readiness/scope | CHG-2026-028 allowed-paths guard（已落地部分） | 所有真实消费者与闭环文件是否已枚举 |
| AF-002 | design/verification | 无通用机械门 | production root 能否取得可信 authority 并到达 effect |
| AF-003 | threat model/authority | schema/contract tests 仅部分 | 谁产生事实、能否由调用者同时伪造事实与证明 |
| AF-004 | integration/platform run | Swift CI/局部 contract | producer 与 consumer 是否在同一真实路径端到端运行 |
| AF-005 | evidence/status | evidence schema/人工 review | 该 PASS 是否仍绑定当前 bytes、输入、环境和 evidence class |
| AF-006 | PR/governance | CHG-2026-028 revision/pins/path checks（分阶段） | PR 载体、状态与真实内容是否一致 |
| AF-007 | readiness/environment | Swift CI 部分覆盖 | 测试是否依赖用户目录、锁屏、隐藏链接或未钉工具链 |
| AF-008 | design/review | fault tests 按任务 | 是否覆盖资源替换、并发、崩溃窗口和 unknown outcome |
| AF-009 | governance design | 无通用机械门 | 机制是否在真实信任边界上阻断了声明的威胁 |

手册不得维护单独的“发生次数真相数据库”。次数只在有完整审计基线与可复查查询时
作为 dated observation 写入，避免新的同步账本。

## 4. Template integration

### tasks template

新增短字段，不复制整份手册：

```text
- Applicable failure patterns:AF-NNN... | none（附理由）
- Production reachability:root → authority → effect，或明确 not applicable
- Trusted fact sources:事实生产者、freshness/binding 与 anti-forgery 边界
```

选择 `none` 不是自动通过；reviewer 可要求改为相关 AF ID。字段本身不改变 task
status，也不替代 Requirements/Acceptance/Allowed paths/Verification。

### design template

在 architecture/failure/security 之间增加 “Authority and production reachability”：

- production composition root；
- authority/permit/capability 的唯一产生点；
- effect dispatch point 与 intent/outcome durable 边界；
- fake/simulation 与 production 的结构差异；
- facts/provenance 是否能由同一调用者同时控制。

对于纯文档/host-only 无 effect 的任务可写 `not applicable`，但必须给出理由。

### evidence-run template

run identity 增加完整 base OID、关键输入 hash/pin、producer→consumer 路径与 evidence
currency：

- `current`：本 run 精确绑定当前被评审 bytes；
- `superseded`：保留历史事实但不得用于当前结论；
- `invalidated`：执行/输入/环境不满足方法，不构成 acceptance evidence。

状态必须在事实原位可见；不得只在新文件尾部写一个模糊 supersession 注记。

## 5. Historical detection drill

AFP-003 固定选择至少六个仓内案例，覆盖全部九个 AF 类别中的主要决策点。最低案例：

1. CHG-2026-026 RKFUI-001 dependency table/allowed-path remediation；
2. CHG-2026-022 OBS production source 与 unforgeable origin 缺失；
3. CHG-2026-025 AIN r2 caller-controlled authorization/facts/dispatch；
4. archived CHG-2026-009 signed broker JSON bool producer/consumer 缝隙；
5. archived CHG-2026-002 M1-009 filesystem/adversarial 多轮 remediation，或 M1-006
   current-revision evidence/supersession；
6. `postmortem-2026-07-governance.md` 的 V1 信任边界错位。

演练表每行记录：若使用新模板，最早在哪个阶段触发、对应 AF ID、需要的阻断/拆分/
验证动作、历史上最终发现该问题的证据。另加入至少一个环境失败反例（例如锁屏、
module cache、缺 PyYAML 或 quarantine），证明手册要求如实分类而不是把环境失败误报为
产品缺陷。

AFP-003 只写本 change evidence，不修改上述历史文件，也不宣称重新验证历史 change。

## 6. Verification strategy

- 结构审读：九个 AF ID 唯一、字段齐全、canonical link 可解析、完整 main OID 格式正确；
- shadow-spec 扫描：手册没有新增 normative `SHALL`、批准/授权状态或产品支持声明；
- 模板 diff 审读：只新增提示字段，不删除/放宽既有 task/design/evidence 条目；
- historical drill：六个固定案例 + 一个环境反例均能映射到具体模板字段和动作；
- repository checks：`scripts/check-sdd.sh`、`git diff --check`，archive diff 为零。

不为这份 Markdown 手册新增 parser 或数据库。若后续复发数据证明某一字段适合机械化，
另立 change，并要求正例与 canary/反例同时证明，避免“只会绿”的检查。

## 7. Task and PR boundaries

- AFP-001：只交付手册与本 task evidence；
- AFP-002：只交付三个模板的小改与本 task evidence；
- AFP-003：只交付 historical drill evidence；
- approval、三次 readiness、三次 implementation/evidence、三次 done、verified 分别保持
  独立 PR；
- 三任务均不得修改 `AGENTS.md`、enforcement、spec/contracts、archive 或产品代码。
