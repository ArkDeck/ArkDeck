# TASK-AIN-002 run — hardware-evidence schema 3.0.0 定稿

- Date:2026-07-22
- Executor:agent(Claude,host-only,E0 级零设备、零联网、零装包)
- Base:main `fbc1b6747f5cb2183c04cfb0965133d23b5f5834`;readiness pins 复核:
  v3-draft blob `62fc3a73…` 与 v2 正本 `98443833…` 于 base 逐一命中(无漂移)。

## 做了什么

1. **定稿 v3 schema**(`contracts/hardware-evidence.schema.v3-draft.json` 就地
   定稿,文件名保留待 archive PR 替换正本时更名):`$id` 去 `-draft` 后缀 →
   `arkdeck://contracts/hardware-evidence/3.0.0`,title 同步;字段面与 readiness
   钉定的 draft 语义零变化(executor 对象、kind=agent 条件必填
   authorizationRef、physicalTargetConfirmation.method 二枚举)——**AIN-003 只读
   依赖的 executor/confirmation 语义未动,其 readiness 无须重查**。
2. **校验脚本**:`validate_v3.py`,stdlib only(readiness 实测 `.venv-sdd` 无
   jsonschema),实现 schema 的封闭断言集(required/enum/pattern/条件 required/
   additionalProperties/嵌套对象),非通用 JSON Schema 实现,schema 修改须同步。
3. **正反例 9 件**(`cases/`,全部标注"校验 fixture,非真实执行记录",占位
   hash,永不计入任何硬件验收):正例 = human/humanVisual、agent/authorizationRef/
   machineReadback;反例 = agent 缺 authorizationRef、未知 kind(ci)、缺
   method、非法 method、v2 形态(operator 字符串)、v3 带多余 operator 字段、
   非法 sha256。

## 命令与结果(AIN-SCHEMA-001)

```
.venv-sdd/bin/python validate_v3.py --cases cases
→ 9/9 PASS(2 正例全 accept;7 反例全 reject,拒绝原因逐条命中预期断言)
→ AIN-SCHEMA-001:PASS
./scripts/check-sdd.sh → 0 error / 0 warning / 111 acceptance IDs
```

## v2 兼容性与迁移说明

- v2 历史实例(`operator` 字符串形态,EVD-M0B/RF001/RF002 族)在 v3 下判定为
  **reject**(缺 executor、operator 为非法字段、schemaVersion 不符)——这是
  预期行为:v2 记录**不迁移、不改写**,以 `schemaVersion` 判别双版并存;
  v3 只用于 CHG-2026-025 生效后的新记录。
- archive PR 动作:本定稿替换 `openspec/contracts/hardware-evidence.schema.json`
  (更名、`$id` 保持 3.0.0),同步 `verification/core-conformance.yaml` 的
  operator 注记与 `verification/policy.md` L85 的"操作者"表述(AIN-001 run
  记录同一结论)。

## AC 结论

- AIN-SCHEMA-001:PASS(正反例二值行为可复跑复查,脚本与 fixture 均入 evidence)。

## 边界与偏差

- `openspec/contracts/**` 正本零接触;只写 change 目录 `contracts/**` 与
  `evidence/**`。无偏差;遗留风险:无。
