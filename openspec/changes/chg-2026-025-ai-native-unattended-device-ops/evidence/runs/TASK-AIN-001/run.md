# TASK-AIN-001 run — 治理文档面同步

- Date:2026-07-22
- Executor:agent(Claude,host-only 文档任务,E0 级零设备)
- Base:main `fbc1b6747f5cb2183c04cfb0965133d23b5f5834`(三 readiness merge 后);
  readiness pins 六文件 blob 于 base 复核逐一命中(无漂移)。

## 做了什么

按 readiness 钉定的 7 处封闭集逐一改写(POL-AGENT-002 新模型:执行分级 E0/E1/E2
+ standing authorization + executor 记录),逐处对照 approved delta 文本,未引入
delta 之外的新语义:

1. `AGENTS.md` Agent 禁令第 2 条:destructive 由"人类亲自执行"改为"须持 merged
   PR standing authorization,执行门 fail closed;E0 无人值守;E1 加 capability
   evidence;evidence 记 executor/authorizationRef;Agent 不得自批授权"。
2. `openspec/governance/enforcement.md` 真实硬件节第 1 条:改为 E0/E1/E2 分级 +
   执行门校验表述;新增普通 CI 边界条(仍限 contract/fake/simulated/plan-only)。
3. 同节 evidence 条:操作者(人类)→ executor(human|agent + authorizationRef);
   "人工目标确认"→"人工物理确认或机器身份读回";补授权/吊销载体 = merged PR。
4. `openspec/verification/policy.md`:"只能由人类执行"→"须持 standing
   authorization,人类亲手或 Agent 无人值守均可,执行门 fail closed"。
5. `openspec/verification/hardware-matrix.md` 序言:"由人类操作者产生"→"由执行者
   产生(人类操作者或持 standing authorization 的自主 Agent)";Required
   dimensions:"人类操作者、物理目标确认"行 → executor + 两类目标确认。
6. `openspec/templates/change/tasks.md` Risk 行注释同步。
7. `openspec/templates/change/evidence-run.md` destructive dispatch 注释同步。

## 命令与结果(AIN-DOC-001)

```
grep -rn -e "只能由人类执行" -e "由人类亲自执行" -e "人类亲自执行" \
  -e "只能产出 plan 与人工执行步骤" -e "由人类操作者产生" \
  -e "授权人类执行" -e "操作者(人类)" \
  AGENTS.md openspec/governance/ openspec/verification/ openspec/templates/
# → 无匹配(exit 1),残留 = 0
grep -rln "standing authorization" AGENTS.md openspec/governance/ \
  openspec/verification/ openspec/templates/
# → 六文件全部命中
./scripts/check-sdd.sh → 0 error / 0 warning / 111 acceptance IDs
```

## AC 结论

- AIN-DOC-001:PASS(封闭集 7 处全部改写,复核面残留 0;guard 绿)。

## 边界与偏差

- `openspec/constitution.md`、`openspec/specs/**`、`openspec/baselines/**`、
  `changes/archive/**`、既有 EVD-* 数据行零接触——constitution/flashing spec 的
  旧文按设计保留至 archive PR 合入 delta,不属于本任务复核面。
- `openspec/verification/policy.md` 第 85 行"操作者与时间"未改:该句描述
  `contracts/hardware-evidence.schema.json` 正本字段,正本当前仍为 v2
  (operator),archive PR 替换 v3 时一并同步,现在改反而与正本矛盾。
- 无其他偏差;遗留风险:无。
