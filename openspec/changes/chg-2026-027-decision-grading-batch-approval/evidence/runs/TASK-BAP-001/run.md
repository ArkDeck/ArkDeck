# TASK-BAP-001 run — 决策分级与批次审批协议入正本

- Date:2026-07-22;executor:agent(host-only,docs;零设备/网络/外部进程)。
- Base:main `fac1a12`(#326 合入后;完整 OID 见 PR merge 记录)。
- Pins 复核(readiness #321 钉定 vs 实现分支 base `git ls-tree`):
  `openspec/governance/enforcement.md` =
  `eeea673aa62a6dbd6c0c1c873e451de90f3c01f4` ✓、`AGENTS.md` =
  `096776024275057487fcf14bf574ffe18463049c` ✓ —— 零漂移,按 readiness 开工。

## 改动

1. `openspec/governance/enforcement.md`:header Version 2.0.0 → 2.1.0(dated
   注记);"批准语义"节 ADDED 两小节——"决策分级(D0/D1/D2)"(D0 三条件 +
   拿不准升 D1;D1 封闭列举;D2 物理与授权;与 E* 正交;不引入仓内状态
   字段)与"批次审批协议"(issue 队列载体、入队三门、按序逐 PR 合并、遇拒
   停链、宽度并行零投机堆叠、fail closed)。既有各节(信任模型/批准语义既有
   条目/CI 校验/真实硬件/Baseline/V1 遗留清理)零文本改动。
2. `AGENTS.md`:"执行规则"节 ADDED 批次协作一条(digest 入队、判断门后零
   投机堆叠、D0 连续排入、无 auto-merge、merge OID 确认);其余各节零改动。

## 与 design §0 六不变量逐条对照

1. 信任根零改动:两文件均未触碰信任模型/权威顺序文本;新增文本明写"每次
   合并仍是逐项批准"。✓
2. 无 auto-merge:两处均明写"任何等级(含 D0)不存在 auto-merge"、"CI 绿 ≠
   批准"不变。✓
3. digest 无批准语义:enforcement 协议节明写;issue 仅导航。✓
4. POL-* 零改动:constitution 未触碰;D*/E* 正交明写。✓
5. 宽度并行零投机堆叠:enforcement + AGENTS.md 双载体明写,含预跑豁免边界。✓
6. fail closed:merge OID 确认、不确定即暂停、拿不准分级升 D1。✓

## 检查

- `check-sdd`:0 errors / 0 warnings / 111 acceptance IDs(实现前后一致)。
- 字节级自检:两文件 grep U+200B/U+FEFF 零命中(MECH-001 readiness 起草期
  曾混入 ZWSP 的教训,提交前显式复查)。
- diff 范围 = allowed paths 内三处(enforcement.md、AGENTS.md、本 run);
  tasks.md 未动(实现 PR 不翻状态,#28 规则)。

## AC 结论(candidate)

`BAP-GOV-001`(documentReview):候选 PASS——D0 三条件可操作、D1/D2 封闭
列举、批次语义与六不变量逐条一致、AGENTS.md 与 enforcement 零冲突。终裁于
done/verify 流程由维护者 review 确认。

## 偏差与遗留

- `openspec/templates/batch-digest.md` 尚不存在(TASK-BAP-002 交付);
  enforcement 引用处已注记"交付前以 design §2 字段面为准",非断链。
- 无其他偏差;零 Swift 面、零 fixture、零 evidence 脱敏事项。
