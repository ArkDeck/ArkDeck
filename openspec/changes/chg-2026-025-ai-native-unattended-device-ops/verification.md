# Verification Plan

> Change:CHG-2026-025-ai-native-unattended-device-ops@r5
> Status:planned # 结论经维护者在 PR 中确认
> Revision review:2026-07-22 已逐项对照 r2 security-remediation、TASK-AIN-005/006/
> 008/007 与 AIN-004 stop gate;本计划不复用 superseded #296 readiness/authorization。
> r3 addition:2026-07-28 加入通用 Agent operation/human blocker、E0/E1 capability
> executors、HAP/SO deployment 与闭环调试；新增任务在 r3 merge 与各自 readiness 前均
> 不执行实现或真机。
> r4 remediation:2026-07-28 TASK-AIN-010 readiness audit 发现 E1 capability carrier/
> provenance/usage 与 E0/E1/E2 durable authority correlation 未冻结，新增
> TASK-AIN-009R；009R/010 各自 readiness 合入前不执行实现或真机。
> r5 remediation:2026-07-29 TASK-AIN-011 readiness audit 发现 exact E0 collection
> integration authority/production lowering 与 status path 不闭合；新增
> TASK-AIN-010P 先由 Agent 在本 scoped V3 contract 下执行 registration capture，
> 后继独立 integration change 再登记/adopt；各门合入前不执行后续实现。

## Environment

- Core baseline:CORE-2.1.0 + 本 change approved delta overlay;archive 时 ratify
  CORE-3.0.0
- Host:macOS(现行 Swift 全量基线为回归底线);Device:DAYU200(RK3568),
  pinned 参考镜像 7.0.0.33
- toolchain/HDC/Provider 版本与全部 hash 于各任务 readiness PR 钉定(全 OID)
- authorized-agent persistence 采用 AIN-005 + AIN-008 的 closed contract：
  authorization-usage `1.0.0`，Manifest/Journal `2.1.0` Rockchip toolchain 与
  descriptor-bound executable identity；v1/v2 历史 bytes/语义不改写
- r3 control plane:agent-device-operation `1.0.0` + human-action-required `1.0.0`；
  exact version/hash、HDC/profile、E1 capability 与真机 target 于 TASK-AIN-009—016
  各自 readiness 固定
- r4 authority persistence:per-device capability、execution-authority/usage 与
  Journal/Manifest 2.2 的 exact schema/version/compatibility matrix 由
  TASK-AIN-009R readiness 固定；2.1 Rockchip historical bytes/语义保持可读且不改写
- r5 registration capture:exact device/build/HDC、八个 E0 typed argv、time/byte
  budgets、human boundary、change-local V3 evidence instance 与 privacy allowlist 由
  TASK-AIN-010P readiness 固定；capture 不建立 integration support
- r3 hardware:至少一个 pinned OpenHarmony device/build/HDC 完成 E0/E1 product-path；
  人类只执行 human-boundary registry 中的物理/配置/治理动作

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| AC-FLASH-015-01 | AIN-003 历史回归 + AIN-006 无授权可信门 dispatch=0 + TASK-AIN-004 真机负探针 | passed | TASK-AIN-003/006/004 run 记录 |
| AC-FLASH-015-02 | AIN-006 逐项篡改/过期/超次/读回不符 real-fault + TASK-AIN-004 真机负探针 | passed | TASK-AIN-006/004 run 记录 |
| AC-FLASH-015-03 | AIN-007 产品内 fake executor 端到端 + DAYU200 无人值守真机执行(v3 evidence,executor.kind=agent) | passed | TASK-AIN-007 tests;TASK-AIN-004 脱敏 transcript + EVD 记录 + hardware-matrix 行 |
| AIN-DOC-001(change-local) | 全仓 grep 复核:`AGENTS.md`/`governance/`/`verification/`/`templates/` 无残留"只能由人类执行/Agent 零设备命令"矛盾表述(archive/ 与历史 evidence 除外) | passed | TASK-AIN-001 run 记录附 grep 输出 |
| AIN-SCHEMA-001(change-local) | jsonschema 脚本:正例全 accept,反例(agent 缺 authorizationRef/未知 kind/缺目标确认)全 reject | passed | TASK-AIN-002 run 记录 |
| AIN-AUTH-PROV-001(change-local,r2) | provenance contract：任意 caller file/worktree override/历史 main/伪造 carrier/无 CODEOWNER approval 全 reject；fresh protected-main grant accept | passed | TASK-AIN-006 run 记录 |
| AIN-FACT-001(change-local,r2) | caller context 注入、stale readback、非 durable binding、tool/plan drift 全 dispatch=0；可信 port 同 Job 关联正例通过 | passed | TASK-AIN-006 run 记录 |
| AIN-USAGE-001(change-local,r2) | 并发/崩溃/重试 fault test：`maxRuns=1` 只有一个 durable reservation，crash 不退款、不重复 dispatch | passed | TASK-AIN-006 run 记录 |
| AIN-CONTRACT-001(change-local,r2) | authorizedAgent manifest/journal/usage round-trip + AIN-008 Manifest/Journal 2.1 Rockchip persistence/identity regression；standardAgent destructive success 与无 ref intent 全 reject；v1/v2 历史仍可读 | passed | TASK-AIN-005/008 run 记录 |
| AIN-DISPATCH-001(change-local,r2) | AIN-008 descriptor-bound admission 前置 + AIN-007 fake descriptor executor 端到端：grant→reservation→intent→固定 argv→semantic outcome→manifest；handoff/external-shell dispatch=0 | passed | TASK-AIN-008/007 run 记录 |
| AIN-COMP-001(change-local,2026-07-28 remediation) | TASK-AIN-003R contract tests：production composition 处 adapter profile hash == RockchipAuthorizationFacts 的 pinnedProduction 断言(正向)；错误 profile 注入 fail closed 且 015-01/02 无授权/不匹配 dispatch=0 不放宽(负向)；全量基线零回归 | passed | TASK-AIN-003R run 记录 |
| AIN-BKMK-001(change-local,2026-07-28 remediation) | TASK-AIN-BKMK-001 tests：pinned tool 宿主前置消费与创建者 code-signing 身份解耦——签名身份不同的两个构建产物先后消费同一已安装第 1 项前置,load() 层消费成功(正向)；bookmark/前置缺失、stale、实体 hash 不中等既有 fail-closed 门零放宽且 015-01/02 无授权/不匹配 dispatch=0 不回退(负向)；全量基线零回归 | passed | TASK-AIN-BKMK-001 run 记录 |
| AC-WF-003-01 | E0 fixture integration + real device observation/HiLog run；无 device window/人工代跑 | passed | TASK-AIN-011/015/016 run 记录 |
| AC-WF-003-02 | E1 capability 每字段 real-fault、expiry/usage/concurrency/crash + 真机负探针 | passed | TASK-AIN-010/012/013/014/016 run 记录 |
| AC-WF-003-03 | request schema/semantic adversarial vectors + public API/source audit | passed | TASK-AIN-009/010/015 run 记录 |
| AC-DEV-009-01 | fixture trust blocker/resume + 真机首次 trust/重新 probe（不以文本建 binding） | passed | TASK-AIN-010/015/016 run 记录 |
| AC-DUMP-009-01 | 四 Recipe fake HDC product executor + 真机 Agent UI Dump | passed | TASK-AIN-012/016 run 记录 |
| AC-TRACE-010-01 | fake Trace capture/receive/compensation/crash matrix + 真机 Agent Trace | passed | TASK-AIN-012/016 run 记录 |
| AC-DEBUG-008-01 | bounded HiLog fixture/ENOSPC/rotation + 真机长时 Agent capture | passed | TASK-AIN-011/013/016 run 记录 |
| AC-DEBUG-008-02 | pinned HAP install/readback/start/diagnostics fake + 真机 Agent run | passed | TASK-AIN-013/016 run 记录 |
| AC-DEBUG-008-03 | app-owned `.so` atomic publish/verify/rollback fault matrix + scoped真机 E1 run | passed | TASK-AIN-014/016 run 记录 |
| AC-DEBUG-008-04 | analysis-generated next request 越权/过期/stale facts 全重新 admission | passed | TASK-AIN-010/014/015/016 run 记录 |
| AIN-OP-CONTRACT-001(change-local,r3) | agent-operation/human-blocker schema 正反 vectors；operation→step/effect mapping 闭包 | passed | TASK-AIN-009 run 记录 |
| AIN-CAP-CONTRACT-001(change-local,r4) | per-device capability/provenance/usage 每字段 vectors + E0/E1/E2 authority union 的 Journal/Manifest 2.2 round-trip、crash/replay correlation 与 2.1 compatibility matrix；真实 capability/dispatch=0 | passed | TASK-AIN-009R run 记录 |
| AIN-E0-CAPTURE-001(change-local,r5) | typed registration runner contract/fault matrix + Agent real-device E0 run + V3 schema/privacy/effect audit；人工仅做 allowlisted 物理/配置动作 | passed | TASK-AIN-010P run + 脱敏 V3 hardware evidence；raw Artifact 受控本地引用 |
| AIN-CONTROL-001(change-local,r3) | submit/status/cancel/reconcile/result 与 bounded debug DAG 端到端；network/shell/raw path surface=0 | passed | TASK-AIN-015 run 记录 |
| AIN-MANUAL-GAP-001(change-local,r3) | 活跃 change/runbook grep 与 dependency audit；非 allowlisted human-only seam=0 | passed | TASK-AIN-017 run 记录 |

## Negative and recovery tests

- 授权缺失/过期/超次、plan hash 漂移、binding revision 不符、身份读回不匹配 →
  一律 dispatch=0(contract + 真机负探针双面);
- caller 提供的 authorization bytes/context/revision/readback/usage 一律不成为可信输入；
  local worktree/main ref 篡改与伪造 GitHub carrier 均 dispatch=0；
- `maxRuns` 并发 reservation 与 intent/outcome crash window 做确定性 fault injection，证明
  ceiling 不超发且 unknown 不退款；
- E1 capability 的 target/binding/transport/tool/profile/operation/namespace/data-impact/
  duration/concurrency/uses/validity/compensation/resume/privilege/destructive-adjacency 任一
  漂移，或 E0/E1/E2 authority kind/ID/blob/usage 交叉替换 → intent/process/device
  dispatch=0；2.1 bytes 不得被 2.2 reader 改写或伪装；
- fake product executor 必须证明实际 argv 只来自 typed Provider plan；测试输出
  `dispatch=0` 的 handoff-only 路径不能再作为 AIN-004 readiness 依据；
- Manifest/Journal v1/v2 不得伪装 Rockchip authorized success；2.1 toolchain
  profile/version/hash/descriptor identity 任一漂移须在 spawn 前拒绝，且 AIN-006
  verified executable receipt 必须与 AIN-007 每次 identity-bound spawn 同次关联；
- 刷机中断电/未回连 → 沿用 POL-RECOVERY-001 outcomeUnknown 语义,恢复路径 =
  CHG-2026-016 Loader wlx runbook(已演练);
- privacy scan:序列号字节不入仓(只入摘要),transcript 脱敏(RF-001/002 先例);
- 回归:Swift 全量基线不低于 readiness 钉定值,POL-* 其余不变式性质测试全绿。
- r3 request adversarial：unknown/duplicate key、executable/argv/shell/remote path、
  caller grant/readback/prerequisite/usage/outcome/effect override 全部在 intent/process 前拒绝；
- E0/E1 effect confusion：E0 plan 混入 cleanup/set/install/send/reboot 恒升级或拒绝；
  profile 不得把 system/vendor/root/remount/no-rollback `.so` publish 降为 E1；
- UI Dump/Trace：stale/ambiguous sidecar、unknown help/tag、invalid UTF-8、timeout/truncation、
  parameter readback mismatch、receive/restore/cleanup fault、rebind ambiguity 与 crash window；
- Debug/deployment：wrong HAP bundle/version/signing/hash、multi-device drift、install exit0
  semantic failure、ELF ABI/hash/target/mode/owner drift、publish/loader/rollback outcomeUnknown；
- debug loop：analysis 越权、旧 capability/readback 复用、budget/deadline/retry exhaustion、
  cancel、restart 与 repeated blocker；不得无限重试或从 derived report 推断 success；
- privacy/storage：Dump/Trace/HiLog/HAP/SO raw 默认本地，序列号/connectKey/path/业务文本按
  policy 脱敏；ENOSPC 保留 journal/partial/finalization headroom；
- 真机 r3：人工只完成 allowlisted 物理/配置动作，capture/deploy/restore/analysis 命令
  全由 product executor dispatch；E2/system/vendor/root/remount/flash 在 TASK-AIN-016 为 0。
- r5 registration：caller target/argv/fact/receipt/support、跨 HDC version result、
  stale/ambiguous binding、server/device drift、unknown step、timeout/cancel/truncation/
  invalid UTF-8/ENOSPC/privacy failure 全部 fail closed/partial；remote write/cleanup、
  buffer/parameter mutation、lifecycle、E1/E2 dispatch 恒为 0，crash 不自动重放。

## Deviations

任何 deviation 必须写明并在 PR review 中确认;不允许隐式豁免。

## Result gate

- [ ] TASK-AIN-001/002/003/003R/BKMK-001/005/006/008/007/004/009/009R/010/010P/011/012/
  013/014/015/016/017 全部 done，且 AIN-004
  使用四项 host remediation 的 fresh main OID 重新 readiness（不复用 #296）
- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] executor.kind=agent 的 evidence 全部携带可解引用的 authorizationRef
- [ ] Traceability updated(AC-FLASH-015-03 + r3 十个 AC 入 registry,111 → 122)
- [ ] AIN-AUTH-PROV/FACT/USAGE/CONTRACT/DISPATCH-001 全部有独立 run evidence，
  且 AIN-008 的 2.1 persistence/descriptor-identity regression evidence 在案
- [ ] standardAgent/ordinary CI 与 caller-supplied context 的 destructive dispatch 恒为 0
- [ ] AIN-004 使用的新 authorization 在执行时 fresh、未超次且由产品 executor 消费
- [ ] E0/E1 真机 evidence 的 executor.kind=agent，人工动作全部属于 human-boundary
  registry，且没有人类代跑 device command
- [ ] TASK-AIN-010P 的 raw registration Artifact 不入仓、V3 evidence 可解引用且
  后继 integration change 明确区分 supported/unsupported；capture 本身未被当成
  AIN-011 production dispatch authority
- [ ] HAP/SO/Trace/UI Dump/HiLog 的 effect mapping、capability/authorization、rollback/
  compensation 与 outcomeUnknown evidence 全部可复查
- [ ] 活跃任务与 runbook 中非 allowlisted human-only seam 为 0；历史
  controlledHumanCapture/golden bytes 未改写
