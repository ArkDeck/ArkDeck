# TASK-AFP-004 evidence addendum — CHG-2026-029 r5

- Date: 2026-07-23（Asia/Shanghai）
- Evidence class: `documentReview`
- Implementation audit base:
  `31865366f7bdb8e5ca33f0c8d41c15f6daba7933`
- Pre-edit handbook blob:
  `6fbb1a706bcf488aa39db672b51f0327a92cdf9b`
- Scope: current `AFP-CORRECT-001` Fact audit and the `AF-014` correction required by
  CHG-2026-029 r5
- Dispatch: device/HDC/network/process/effect/destructive dispatch = **0**；真实硬件 = **无**

> 本 addendum 不修改
> [`run.md`](run.md) 的历史 bytes（blob
> `4eed9d2f5ab8d79ef681a6d1473ed31b71d5242b`）。该旧 run 的
> `AFP-CORRECT-001: passed` **仅在 `AF-014` 这一面被 superseded**：旧 run 漏检了
> “public enum case”并非一手记录所述机制。旧 run 对其他行的历史处置不被追溯改写；
> r5 之后的 change verification 对当前 36 条 Fact 采用本 addendum。

## Audit method and inventory

按 implementation base 中手册 `Observed cases` 的出现顺序分配稳定 ID `F01`…`F36`。
每行都回到 protected-main 上的 pinned source bytes，并记录相对路径、完整 Git blob
OID、可检索 locator、verdict、disposition 与依据。PR/merge 顺序类事实同时用完整
commit OID 的 Git ledger 复核；本 change 的 proposal/design/verification、会话记忆与
跨会话摘要均未作为 Fact source。

计数为 36 条 Fact，按 AF 分布
`2/1/2/2/2/2/2/2/1/3/3/2/2/2/2/2/2/2`。其中旧手册没有本行或本 block
直接 Markdown source link 的五条为 `F05`、`F24`、`F28`、`F29`、`F36`；下表均显式
补出 source。

## Current Fact matrix

| Row | AF | Fact 定位/摘录 | 一手 source（相对路径 + blob OID） | 可检索 locator | Verdict | Disposition | 判定依据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| F01 | AF-001 | full-suite 依赖表不在初始 allowed paths，先阻断后精确修订 | [RKFUI run](../../../../chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md) `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | `Full-suite blocker`、`hard-coded dependency table`、PR #301/#303 | `supported` | retained | source 明记依赖表不在 allowed paths、任务停下并由独立 remediation 扩路径。 |
| F02 | AF-001 | M0B-002 readiness 与 fail-closed 回退，依据另立 CHG-022 | [CHG-006 tasks](../../../../chg-2026-006-dayu200-m0b-bringup/tasks.md) `779ff6ac060ab7ba82ddaf955b65702ec52285db`；[CHG-022 proposal](../../../../chg-2026-022-hdc-supervisor-observability/proposal.md) `63fa348e8f08276d17b1655532714d5da3a67482` | `TASK-M0B-002` blocked/readiness；proposal 的 production source/deep-check scope | `supported` | retained | 前者保留阻断/回退，后者登记独立 change，未把 scope 缺口静默塞回原任务。 |
| F03 | AF-002 | FANOUT 无 production data source；COUNTER 无不可伪造 production origin | [CHG-022 review](../../../../chg-2026-022-hdc-supervisor-observability/review.md) `d03118ab83cbeb278910c08e55573094edbd5169` | `Findings` 1–2：`no production data source`、`no satisfiable unforgeable production origin` | `supported` | retained | source 逐项给出生产 composition 缺口、caller-supplied enum 风险及 identity-bound spawn hook 替代面。 |
| F04 | AF-003 | P0-AUTH/P0-FACT：caller 可控制 authorization carrier 与 execution facts | [CHG-025 review](../../../../chg-2026-025-ai-native-unattended-device-ops/review.md) `197e4adc47f75444a54eefadf00e58b4681e5202` | `P0-AUTH-001`、`P0-FACT-001` | `supported` | retained | 两个 finding 分别记录 carrier/provenance 未验证及 prior-run/binding/prerequisite facts 可由 caller 声明。 |
| F05 | AF-003 | P0-DISPATCH：正例 contract 的真实 dispatch 为 0 | [CHG-025 review](../../../../chg-2026-025-ai-native-unattended-device-ops/review.md) `197e4adc47f75444a54eefadf00e58b4681e5202` | `P0-DISPATCH-001` | `supported` | retained | 无内联链接行已显式回源；finding 将证据边界限定为 comparison/contract，非产品执行链。 |
| F06 | AF-004 | Objective-C `NSNumber(int)` JSON `1` 与 Python `is True` 类型缝隙 | [PD attempt](../../../../archive/2026-07-21-chg-2026-009-dayu200-partition-decode/evidence/runs/TASK-PD-002/platform-attempt-2026-07-20.md) `e0f3b1b77f54b4b7cb1ff17c39316e8e70c29179` | `Root cause`：`NSNumber`/`int`/`is True`/`==` | `supported` | retained | source 把首次真实 producer→consumer attempt 的 blocked 根因精确定位到跨语言布尔表示。 |
| F07 | AF-004 | 同一 E0 面 Swift/Python 两侧套件通过；receipt schema 与 `probe.py` 直接输出对齐 | [RKFUI run](../../../../chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md) `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | Swift/Python commands；`receipt was transcribed manually`、`schema-aligned`、`direct probe.py` | `supported` | retained | source 同时记录两侧套件结果与人工转录边界，没有把该 receipt 冒充新 E0 run。 |
| F08 | AF-005 | UD redactor 的陈旧 hash/literal/test count 在事实原位逐项 `SUPERSEDED` | [UD redactor run](../../../../chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/run.md) `172ea48fba64819d0bf0743816323b8da68b6ec3` | 文件头 supersession 声明及 source-hash/safe-literal/test-count 行 | `supported` | retained | source 在各陈旧事实旁逐项标记，而非只留文末泛化注记。 |
| F09 | AF-005 | RKFUI sanitized receipt 为人工转录，schema 对齐；下次直接由 `probe.py` 生成 | [RKFUI run](../../../../chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/run.md) `0f24bb2424e43edb34de0fffaa0eee3c4e5cbec3` | `manually transcribed`、`schema`、`next E0`/`probe.py` | `supported` | retained | 无沿用旧 run 曾删去的 `rawValue`/key-set 说法；当前表述逐句由 source 支持。 |
| F10 | AF-006 | CHG-028 列出 guard/revision/pin/PR carrier 四类漂移 | [CHG-028 proposal](../../../../chg-2026-028-guard-ci-mechanization/proposal.md) `d7718251c074f3b23bb32f8703c863efc9912245` | `Why` 四类实例及“诚实边界” | `supported` | retained | source 分列四个 drift class 与先例，并明确 guard 覆盖边界。 |
| F11 | AF-006 | CHG-015 archive 曾因 active references 暂缓，后以 provenance re-pin 收口 | [archived CHG-015 proposal](../../../../archive/2026-07-22-chg-2026-015-hdc-readonly-probe-registration/proposal.md) `b09301e257619d176c6adb0530847d499e97b6e6` | archive relocation scope、active-root reference scan；Git commit `583b1c1d4de1a77fc0554908f9b45e28fe604a56` subject `archive with provenance re-pin (#351)` | `supported` | retained | pinned proposal 记录引用阻断与归档边界，Git ledger 确认 #351 的实际 re-pin carrier。 |
| F12 | AF-007 | build-path 回溯改为 bundle-only，byte parity guard，并做一字节篡改反例 | [RKFUI hermetic record](../../../../chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md) `659f99f470cea5f03984de6ea28ce1395e391287` | build path/`Bundle.module`/byte equality；`one-byte tamper` | `supported` | retained | source 同时给出失败形态、bundle 修复、fail-closed parity 与 negative tamper。 |
| F13 | AF-007 | MECH runner pin 首轮被实测推翻，重钉后通过，三轮 attempt 在案 | [MECH-001 run](../../../../chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md) `f5e51fad2f2a429748126eee27ab61df282c2f23` | attempt 1 `macos-15`、attempt 2 `macos-26` ceiling、attempt 3 green/red | `supported` | retained | source 逐轮保留假设、证伪、重钉与最终结果。 |
| F14 | AF-008 | M1 四轮跨轮反复出现 path/inode/rename/typed/unknown/FIFO/writer-lock/identity 面 | [initial](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md) `f615d3fabb42450621e05aa1daa5b837906f41d3`；[round 2](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-2-2026-07-18.md) `309a7f39f5befd20f3df93f95dcc42b3c02cf975`；[round 3](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-3-2026-07-18.md) `8911811f11710ab1692b5ae834b21dfe020ea56e`；[round 4](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md) `e336f498db72ba4c7a4abcd4303d595e152bcb2a` | initial path/inode/rename；r2 typed/identity/unknown；r3 FIFO/non-regular；r4 writer-lock/identity/path replacement | `supported` | retained | 当前措辞明确“跨轮反复而非每轮各一”，与四份 source 的实际分布一致。 |
| F15 | AF-008 | TR-002R 对真实 artifact store publication barriers 做 fault injection | [CHG-021 tasks](../../../../chg-2026-021-trace-adapter-capture/tasks.md) `14703a488170143e02b15d3ae496d23cf390864e`；[TR-002R run](../../../../chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-002R/run.md) `23434076488e8ef6a10d9d93121cefc4e1c6fd80` | TASK-TR-002R gate ②；`Scope implemented`；13 `Publication fault injection` barriers | `supported` | retained | 两个 source 均明确调用真实 `SessionArtifactStore.publish`，并逐项记录 fault 与 cleanup=0。 |
| F16 | AF-009 | V1 key/ledger/identity/服务假设失效及 V2 决策 | [governance postmortem](../../../../../planning/postmortem-2026-07-governance.md) `308d260be9d545b8e27d20a6a30e0719cd76fd19` | `评审结论` 1–5、`决定`、`废止` | `supported` | retained | source 直接记录同 UID keys、临时 runner 空 ledger、relock/re-pin 自伤、缺失服务与 git-native 替代。 |
| F17 | AF-010 | 删除 hardcoded-zero tautological counter，改验 server state/audit trace | [M0A-003 run](../../../../archive/2026-07-21-chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-003/run.md) `7fc3ab1d4fd3b2000b74ea04b0356d9a6c56fce6` | `Tautological counter removed` | `supported` | retained | source 明记方法返回硬编码 0、测试又断言该值，以及替代断言。 |
| F18 | AF-010 | archived M1 tasks 登记两类套套逻辑清理及 literal-as-runtime-metric | [archived M1 tasks](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/tasks.md) `2ea2ba6672b03f7ab6a86a6a7b136c5d531d9ac9` | `TASK-M1-010` Objective/In scope：测试回显字面量、套套逻辑计数器 | `supported` | retained | source 同时登记 evidence metric 更正与常量/重复 decode 零计数清理。 |
| F19 | AF-010 | CHG-022 计数入口在 production 不可达 | [CHG-022 review](../../../../chg-2026-022-hdc-supervisor-observability/review.md) `d03118ab83cbeb278910c08e55573094edbd5169` | Findings 1–2 | `supported` | retained | production source 与 unforgeable origin 均缺失，故原计数入口不能证明真实 production dispatch。 |
| F20 | AF-011 | 空 trace 即使 exit 0 也不判 succeeded | [CHG-021 design](../../../../chg-2026-021-trace-adapter-capture/design.md) `ac83328d9718a78633cd637020780442d826da1c` | `009 artifact completeness` | `supported` | retained | source 逐字登记 `空 trace exit 0 不判 succeeded (exit0≠成功准则)`。 |
| F21 | AF-011 | AC-FLASH-012-01 要求 exit/marker/postflight 叉乘与全语义确认 | [CHG-026 verification](../../../../chg-2026-026-macos-rockchip-flash-ui/verification.md) `f4aea707ded798680aacb7811a4786247a94dac8` | `AC-FLASH-012-01` | `supported` | retained | matrix 明确只有写入、reset、postflight 全部语义确认才 succeeded。 |
| F22 | AF-011 | RF Provider 以语义 postflight 判定，exit 0 不等于 succeeded | [RF-002 run](../../../../archive/2026-07-21-chg-2026-020-dayu200-real-flash/evidence/runs/TASK-RF-002/run.md) `8869ad61b9ebf6e5397e7e6007318e11cb26429d` | `assessOutcome`；`AC-FLASH-012-01` | `supported` | retained | source 的实现清单与 AC 行均明确该语义。 |
| F23 | AF-012 | rehearsal attempt 4 的 heredoc 抢占 `python3 -` stdin，管道数据丢失 | [RH attempt 4](../../../../archive/2026-07-21-chg-2026-016-dayu200-recovery-rehearsal/evidence/runs/TASK-RH-001/rehearsal-attempt-4-2026-07-21.md) `6af1a69bea454251bac9a16ba26e58f2483702da` | `python3 -`、`stdin`、`heredoc`、`读到空` | `supported` | retained | source 明记 blocked-attempt 根因及改走 argv 文件路径的修复。 |
| F24 | AF-012 | CHG-008 harness echo remediation 已完成，#229 合入 | [CHG-008 tasks](../../../../chg-2026-008-ui-dump-hidumper-wrapper/tasks.md) `abaee6a12290108f4daeac9f84a3ff6700971433` | `TASK-UD-HARNESS-ECHO-001` Status/Completion evidence；Git commit `3ac44f2d759bd8bec8f95405b85281d70f89cad0` subject `mark harness echo remediation done (#229)` | `supported` | retained | 无内联链接行已回源；tasks 记录 task done，Git ledger 固定独立 done PR/OID。 |
| F25 | AF-013 | TR-001 harness hardening 补上 Job-UUID isolation 与 verified-receive-before-cleanup | [CHG-021 tasks](../../../../chg-2026-021-trace-adapter-capture/tasks.md) `14703a488170143e02b15d3ae496d23cf390864e`；[TR-001 run](../../../../chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-001/run.md) `6069642a7b3c13d741383fbbdd17a0f921c6b9f2` | tasks `runbook/harness` 复用面；run `Approved harness chain` 与 `Post-run harness deviation and remediation`；hardening commit `628653c69afdf5f1b3c69e0b9eda03ba111fa5bc` | `supported` | retained | tasks 记录复用 m0b/ud harness 形态；pinned run 固定 hardening OID、UUID owned path 与 receive/cleanup gate 偏差及修复，Git ledger 的该 OID 可复查精确 hardening diff。 |
| F26 | AF-013 | “复用既有 discovery 面”实际需要独立观察面 | [CHG-022 review](../../../../chg-2026-022-hdc-supervisor-observability/review.md) `d03118ab83cbeb278910c08e55573094edbd5169` | Finding 1：arbitrary-device support requires a separate integration change | `supported` | retained | source 明确既有 selected binding 面不能替代 arbitrary-device observation/integration。 |
| F27 | AF-014 | 四条 gate：target+exact revision、matching publication、per-device capability、capability-bound reliable total | [CHG-021 tasks](../../../../chg-2026-021-trace-adapter-capture/tasks.md) `14703a488170143e02b15d3ae496d23cf390864e`；[TR-002R run](../../../../chg-2026-021-trace-adapter-capture/evidence/runs/TASK-TR-002R/run.md) `23434076488e8ef6a10d9d93121cefc4e1c6fd80` | tasks `实现序与二值门` ①–④；run `Scope implemented` lines for rebind/publish/parameter/reliable totals | `supported` | **rewritten** | 两个一手 source 均记录：expected target + exact `revision + 1`、matching `PublishedArtifact`、membership alone 非 capability、reliable-total 只能由 current-adapter `capability=true` factory mint；不存在 public enum bypass 机制。 |
| F28 | AF-014 | 四个 gap 在 TR-002 实现合入后由后续 scoping/adversarial review 登记，旧 review 不追溯改写 | [CHG-021 tasks](../../../../chg-2026-021-trace-adapter-capture/tasks.md) `14703a488170143e02b15d3ae496d23cf390864e` | TASK-TR-002 Status merge `cec2cc20…`；TASK-TR-002R readiness scoping #276、implementation #278、独立 done #279 | `supported` | retained | 无内联链接行已回源；同一 tasks bytes 中的完整阶段顺序证明 remediation 晚于原 implementation，历史 TASK-TR-002 结论仍保留。 |
| F29 | AF-015 | M1 同类 adversarial 问题在多轮再现 | [initial](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-2026-07-18.md) `f615d3fabb42450621e05aa1daa5b837906f41d3`；[round 2](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-2-2026-07-18.md) `309a7f39f5befd20f3df93f95dcc42b3c02cf975`；[round 3](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-3-2026-07-18.md) `8911811f11710ab1692b5ae834b21dfe020ea56e`；[round 4](../../../../archive/2026-07-21-chg-2026-002-macos-m1-infrastructure/evidence/runs/TASK-M1-009/review-remediation-round-4-2026-07-18.md) `e336f498db72ba4c7a4abcd4303d595e152bcb2a` | 与 F14 相同 locators，取“跨轮再现”面 | `supported` | retained | 无内联链接行已补全四份 source；各轮存在同族 path/identity/unknown/non-regular/writer-lock finding。 |
| F30 | AF-015 | hermetic 修复只部分收口，其余同族明确留作限制 | [RKFUI hermetic record](../../../../chg-2026-026-macos-rockchip-flash-ui/evidence/runs/TASK-RKFUI-001/hermetic-contract-test-2026-07-22.md) `659f99f470cea5f03984de6ea28ce1395e391287` | `Known limitation`/same-family scope boundary | `supported` | retained | source 没有把未迁移的 fixture/registry family 写成已解决。 |
| F31 | AF-016 | MECH runner 假设未经探针即入 pin，后被 CI run 证伪并重钉 | [MECH-001 run](../../../../chg-2026-028-guard-ci-mechanization/evidence/runs/TASK-MECH-001/run.md) `f5e51fad2f2a429748126eee27ab61df282c2f23` | attempt 1–3 与 `macos-15`/`macos-26` | `supported` | retained | source 保存原假设、实测 ceiling 与重钉结果，未用会话摘要替代。 |
| F32 | AF-016 | CHG-022 r1 把 abbreviated SHA 当 blob pin | [CHG-022 review](../../../../chg-2026-022-hdc-supervisor-observability/review.md) `d03118ab83cbeb278910c08e55573094edbd5169` | Finding 4 | `supported` | retained | source 逐字要求未来 readiness 记录 actual base、完整 Git blob OID 与 file SHA。 |
| F33 | AF-017 | CHG-008 r3 JAUTH 初稿被裁为 M0B gates，候选入 backlog；#128 未合并、#131 合入 | [CHG-008 tasks](../../../../chg-2026-008-ui-dump-hidumper-wrapper/tasks.md) `abaee6a12290108f4daeac9f84a3ff6700971433`；[backlog](../../../../../planning/backlog.md) `fc20c3de0187f3f4b4a7e60129163c33a6d1c6c3` | tasks `r3 remediation 边界与裁剪记录`/`裁剪任务记录`；backlog `JAUTH`；Git `a613b76fd88d93efbe372c66ed09df8e36c706cb` 与 `d99ba58042b9cad64de39d6f4baa5994b2c351b2` | `supported` | retained | source 明记 #128 仅为初稿 head、M0B 裁剪决定与 backlog 去向；Git ledger 确认 #131 merged subject。 |
| F34 | AF-017 | V1 约 12,900 行 guard、0 产品代码受影响，恢复方向一度更重 | [governance postmortem](../../../../../planning/postmortem-2026-07-governance.md) `308d260be9d545b8e27d20a6a30e0719cd76fd19` | 开篇 `约 12,900 行`；评审结论 5；lessons `0 行产品代码` | `supported` | retained | 三个量化/方向性表述均在同一一手 postmortem 中。 |
| F35 | AF-018 | CHG-021 并行推进以文件级分工作为 readiness 前置 | [CHG-021 tasks](../../../../chg-2026-021-trace-adapter-capture/tasks.md) `14703a488170143e02b15d3ae496d23cf390864e` | TASK-TR-002 `竞争面`：`文件级分工`、零文件交集 | `supported` | retained | source 明确列出 Trace 新文件与 OBS/CHG-008 文件面的零交集。 |
| F36 | AF-018 | dated observation：#356 readiness 与 #355 r2 并行导致四个 pin 漂移并重钉 | [current change tasks](../../../tasks.md) `6a83270179915096373d1f3b4b4b11ff5724dbcd` | TASK-AFP-001 `r1 readiness 已失效（pin drift）`；Git merge OIDs `e73b025dab3c12162465040bd0829470b2409ae9` (#356) 与 `de6b79aafa95700297a94dc311e94b1283f8abdd` (#355) | `supported` | retained | 无内联链接行已回源到 readiness 合入后的 process record；两个 merge OID 及 base tree 分别显示 r1 pins 与 r2 对四个 change artifact 的改动。 |

## AF-014 before/after mapping

| Location | Before（handbook blob `6fbb1a7…`） | After（本 implementation） | 一手依据 |
| --- | --- | --- | --- |
| Signal | “公开的枚举 case 可直接构造门所需的能力值” | 没有验证 reliable-total receipt/capability 是否只能由当前 adapter capability factory 的唯一 minting point 产生 | TR-002R run `Scope implemented`：reliable totals 无 public initializer，只能在 current adapter capability 明确为 true 且 total 合法时由 factory mint |
| Observed cases F27 | “一个公开枚举 case 可绕过能力门” | expected target + exact `revision + 1`；matching `PublishedArtifact`；catalog membership alone 非 per-device capability；current-adapter `capability=true` factory/receipt | CHG-021 tasks `实现序与二值门` ①–④ + TR-002R run 的四个 `Scope implemented` bullet |
| Preflight | “调用方能否自行构造该凭据（尤其注意公开枚举 case）” | capability/receipt 的唯一 minting point 是否绑定当前 adapter，调用方能否绕开 factory | TR-002R run reliable-progress factory boundary |
| Negative verification | “以公开枚举直接构造能力值” | missing/false/drifted/invalid capability 或 factory bypass；断言 indeterminate/authority none/dispatch 0 | TR-002R run rows `TRACE-PROGRESS-CAPABILITY-001`、`TRACE-ATOMIC-PUBLISH-001` 与 publication-fault matrix |

`公开枚举` / `public enum case` 机制在当前手册命中 **0**。F27 旧表述 verdict 为
`partially-supported`：前三个 gap 的方向可由 CHG-021 tasks 支持，第四个 gap 的具体
机制不受支持；当前 F27 已按两份一手 source 改写为 `supported`。F28 不依赖该错误机制，
保持 `supported`/retained。

## Audit conclusion

- 36/36 current Fact rows 已逐条复核：**35 retained + 1 rewritten（F27）**；
  implementation 后 verdict 为 **36 supported / 0 partially-supported / 0 unsupported**。
- 五条无直接 Markdown source link 的 Fact 已全部显式补证。
- `Inference` 18 行均保持 `Inference`，未扩写、删改或误标为 Fact。
- `AF-NNN` ID、taxonomy/两轴、八字段契约与顺序、`Automation status` 取值域、
  positive/negative 方法数与首屏边界均未因本 addendum 改变。

因此本 addendum 为 r5 下 `AFP-CORRECT-001` 提供当前 `documentReview` 输入；它本身不
翻转 TASK-AFP-006 状态，也不构成 change `verified`。
