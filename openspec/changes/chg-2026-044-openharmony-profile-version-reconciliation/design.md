# CHG-2026-044 design — living profile version reconciliation

> Status:candidate；仅在 change 获维护者批准后成为设计输入，task 仍须独立 readiness。
> Core baseline:CORE-2.1.0（零 Core 变更）

## 1. Reconciliation tuple

protected main `e5a4267a062f97d50e0583ff7df1551e27420863` 上的候选事实为：

| Input | Current declaration | Candidate disposition |
| --- | --- | --- |
| living profile header | `OPENHARMONY-TOOLS@0.4.0` | 修正为 `0.5.0` |
| living profile device section | `OPENHARMONY-TOOLS@0.5.0` | byte-identical |
| integration lock | `INTEGRATION-PROFILES-0.6.0` → `OPENHARMONY-TOOLS@0.5.0` | byte-identical |
| device registry | `integrationProfile: OPENHARMONY-TOOLS@0.5.0` | byte-identical |

候选选择 `0.5.0` 的 lineage 依据是 CHG-2026-024 approved implementation
`ffca996f41be37d27137e7245c8fba3645fb0fb4` 同时落下 profile 正文、device registry
与 lock；`git blame` 则证明 header 没有随该 commit 更新。该判断仍须由本 change 的
维护者 approval 生效，Agent 不以三票多数自行裁决权威冲突。

## 2. Guard contract

`check_locks_and_conformance` 在现有 path-exists 校验之后，对 integration lock 的
`profiles` collection 执行：

1. 每个 entry 必须是 mapping，并有非空 string `id`、`version`、`path`；
2. `id` 与 `path` 在 collection 内分别唯一；
3. path 必须指向 repository 内可读取的 Markdown 文件；
4. profile leading metadata 中必须各有且仅有一个 `ID` 和 `Version` 行，接受仓库
   现用的 ASCII/full-width colon，但不接受模糊前缀或从正文猜值；
5. header ID/version 必须与 lock entry exact string equal；
6. 所有结构错误追加可定位的 SDD error 并继续其他校验，不因 malformed input
   抛异常中止整次检查。

guard 不比较 `core-conformance.yaml` 中的历史 consumer pins，也不把 registry 的
`integrationProfile` 字段重新定义为 living-header authority。registry/profile closure
仍由各自 approved integration task 验证；本 guard 只保证 lock 所称的 current profile
与该文件自报 identity 一致。

## 3. Mutation proof

contract tests 使用隔离临时 root 构造最小 integration lock/profile：

- exact ID/version/path → no reconciliation error；
- profile version `0.5.0 → 0.4.0` → deterministic mismatch error；
- profile ID mutation → deterministic mismatch error；
- missing 或 duplicate ID/Version metadata → deterministic structural error；
- duplicate lock id 或 duplicate lock path → deterministic duplicate error；
- malformed profile entry 或 unreadable/missing path → error，不抛 uncaught exception。

测试期望值来自明确 mutation，而不是从同一 parser 输出回填；至少一个 mutation-red
proof 须在 run evidence 中记录。

## 4. Data and contract changes

- Core specs/contracts/schema:无变化。
- Integration lock/schema:无变化；lock bytes 必须与 readiness pin 相同。
- Living profile semantics:无新增；只修正 header 以反映已登记的 0.5.0 body。
- CI behavior:新增一类 deterministic consistency failure。
- Migration:无 runtime/storage migration。

## 5. Authority and production reachability

- Production composition root:not applicable；本 change 只修正文档 metadata 与
  repository lint。
- Authority 产生点:维护者 review/merge 本 change 的 approval 与后续 task PR；
  checker success 不产生产品、工具或设备 authority。
- Effect dispatch point:not applicable；不调用 HDC、network、server/device API。
- Fake/simulation 与 production 差异:not applicable；tests 只构造临时仓库文件，
  证明 guard fail/pass，不证明 HDC support。
- Facts/provenance:版本 lineage 来自 protected-main git history、current lock/profile/
  registry bytes；implementation caller 不能用测试 fixture 改写这些事实。

## 6. Failure, cancellation, and recovery

- malformed/missing/duplicate metadata：单项 error，checker 继续报告其余问题；
- header/lock mismatch：CI fail closed，阻止 merge；
- checker 进程取消/失败：沿用现有 CI failure，不写仓库状态；
- crash/restart：无 durable runtime state；重跑读取相同 git tree 得到同一结果；
- rollback：header 与 guard/tests 一起回退，CHG-2026-043 重新保持 blocked。

## 7. Alternatives rejected

- **把 lock/profile entry 降回 0.4.0：**会否认 CHG-2026-024 已登记的 0.5.0
  device-observation lineage，并使 registry 与 lock 再次冲突。
- **把 header bump 到 0.6.0：**本修复没有新增 integration 语义，且会抢占
  CHG-2026-043 的候选版本。
- **只人工修 header、不加 guard：**现有绿色测试已经证明该遗漏可静默存在，不能提供
  mutation-red 防回归。
- **改写 archived CHG-2026-024：**破坏历史 evidence；living correction 必须作为新
  change 留下独立审计链。
