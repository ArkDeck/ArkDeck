# CHG-2026-008 Verification Plan

> Status:planned
> Change:CHG-2026-008-ui-dump-hidumper-wrapper@r13
> Core baseline:CORE-2.0.0

本文件是 r3 review-remediation verification plan(经 2026-07-20 维护者裁剪决定收敛,
初稿见 PR #128 提交历史 `a613b76`;r3 已经 PR #131 合入)。r4(PR #132)固定
`TASK-UD-CAP-MUT-001` 五项 readiness 输入;r5(PR #136)固定 `TASK-UD-REDACTOR-001`
实现范围并起草 `ready`。r6 依 2026-07-20 桌面推演审计新增 host-only
`TASK-UD-CAPTURE-HARNESS-001`(`ready`,交付入库采集 harness)并把
`TASK-UD-CAP-MUT-001` fail-closed 回退为 `blocked`(唯一剩余前置=harness done;r4 五
项 pins 保持有效),同步补全 runbook 的 canonical 执行序列、`SC-2`/`SC-3` 字面 argv、
`HP-2` 粒度、truncation/timeout 政策与 abort 规则。`TASK-UD-CAP-R4-001` 与
`TASK-UD-001` 保持 `blocked`;任何 installed-HDC/device 执行或基于未批准 argv/output
family、自造 fake/golden 的既有 PASS 都无效。r7(PR #145)把 `HP-1`/`HP-2` 钉为 verbose
`list targets -v`(M0B merged evidence dispositive);harness 实现经 PR #143 合入、PR #148
完成 r7 对齐,任务於 PR #149 done,redactor 任务於 PR #144/#150 done。r8 为 errata
revision:清理 r7 的两处纯形式残句(runbook Prohibited actions 行与本文件的重新观察句),
把 CAP-MUT evidence set 的单数 redacted-manifest 表述对齐 r6 确立的 `redacted-manifests/`
复数惯例,并同步本文件的任务状态叙述;零命令语义/gate/AC method 变更。首次 Phase A
人工 run 经 #219 合入后在 `FX-1` fail closed:完整 stdout 回显 exact resolved HAP path,
使 r6 harness 将 controlled-raw typed-input echo 与 repository-facing leak 合并判为失败;
R1-R3 dispatch 均为 `0`。r9 新增 host-only `TASK-UD-HARNESS-ECHO-001`,只固定 exact
`FX-1` stdout echo 的窄化 policy、future schema `1.1.0` 与 synthetic adversarial closure;
不含实现/evidence/device dispatch,不重判 #219,也不恢复 CAP-MUT ready。
r9 后续 remediation implementation/evidence PR #228 与独立状态/ready-restore 已合入,新的
Phase A evidence PR #248、独立 done status PR #251 也已合入;R1/R2/R3 均保持
`unknownOutput`,R4 dispatch `0`。r10 只固定 R2 structural decision 与 future Phase B
same-session R2 → private selector bundle → R4 provenance 边界:新增一个 human-offline
decision task(`ready` candidate)和一个 host-only selector/harness seam task(`blocked`),不含
derived bytes、decision、实现、真实 raw 读取或 HDC/device dispatch。r10 决策任务经
#263(`952b0f7`)登记 truthful-negative(`INVALID_UNICODE` / exit `27`,零 derived/
receipt)并经 #267(`c9b3f77`)done;SEAM/R4/UD-001 按 r10 gate 全部保持 blocked。
r11 只登记 truthful-negative 之后的复活路径:新增 `blocked` 的 host-only 只读诊断任务
`TASK-UD-R2-DIAG-001`(根因判定,非内容输出)与两条互斥、均须诊断 done 后由后续
修订授权的分支;本文件在 r11 仅做 revision 同步,该任务的 verification 行与 acceptance
case 由其独立 readiness revision 一并固定。
r12 引用 #695 的 `pinned-input-unavailable` evidence,承认旧 raw 根因永久不可测并
收窄为 recapture-only 任务链:新增 blocked 的 `TASK-UD-R2-RECAPTURE-001` 与
`TASK-UD-R2-REDIAG-001`。前者须独立 D2 readiness 后由人类在具名设备窗口执行既有
harness 的 R2-only sequence,并把 fresh raw 留在非临时 persistent controlled root;
后者须 recapture done 后由独立 D1 readiness 按 fresh length/hash 重钉既有非内容诊断
工具。r12 自身零 readiness、零 raw/evidence、零 installed-HDC/device dispatch。
r13 记录 r12 后 D2 preflight 的 host-only HDC drift：同一 DevEco path 当前 binary
SHA-256 `05b2bf7a…f83`，由 protected-main facts 映射为 `Ver: 3.2.0f`，不再匹配
Phase A/r12 的 `3.2.0d` / `48395ba8…d260`。r13 只为 R2-only recapture 原子替换该
expected pin；不接受 capability evidence、不安排窗口、不使任务 ready，installed-HDC
process/device/fixture/Recipe/raw/destructive dispatch 均为 `0`。
独立 D2 readiness r1 基于 r13 merge
`f065ac90e69ff89c9ebb8817bfb4f9ebb1b0ed7d` 起草 `TASK-UD-R2-RECAPTURE-001
blocked→ready`：固定 current harness/HDC/target/fixture/argv/sidecar/schema/storage
pins，接受 #248/#251 的 exact-device typed capability evidence，并安排 human-only
named one-run exclusive window。该状态只在 readiness exact head 由维护者 merge 后
生效；draft 已 rebase 到 current main
`eaa57f9281c6194e1bada0c740bde1d6e4f48fc6`，intervening CHG-2026-042 tasks 与
本输入零重叠；draft/PR 阶段仍零 installed-HDC/device dispatch，且不包含 capture
evidence。

## Readiness environment

- r3 必须先经维护者 review/merge。`TASK-RLC-001 done`、CHG-2026-014 verified 只提供
  package bytes/interfaces provenance,不提供 M1-006 source AC;TASK-UD-001 的逐
  deliverable consumer dependency 表还须在未来 readiness revision 复核且没有 `yes` 行。
- 当前 M0B manifest 只含 `hidumper --help` 和 `hidumper -ls`,不是四 Recipe capture。其
  旧 connect key 不得假设仍有效,必须在采集会话内经 `hdc list targets -v` 重新观察。
- `capture-runbook.md` 固定 one-element `-a` candidate boundary、人工 preflight
  (`HP-0..HP-2`)、exact-path 清单与结果判定规则。official source 没有 DAYU200
  target-build source/binary mapping,不能证明 output mode;R1-R4 首次 target capture
  全部保守归入 `captureRemoteFile/deviceMutation`,不存在 readOnly Recipe case。
- 采集授权模型 = M0B 先例:runbook + 人类维护者亲手执行 + 维护者对 evidence PR 的
  review/merge attestation。production supervisor/binding 栈、journal 授权链与 offline
  receipt verifier 均不是本 change 前置(JAUTH 候选项见 backlog)。
- `TASK-UD-CAP-MUT-001` 的五项 readiness 输入已由 r4 固定(fixture HAP 元组含
  SHA-256、`INV-1`/`SC-1..SC-3`/`FX-1..FX-4` 字面 argv、唯一 literal sidecar path、
  操作者与时间窗规则;见 tasks.md Readiness review 与 runbook)。r6 追加唯一剩余前置:
  `TASK-UD-CAPTURE-HARNESS-001 done`——全部设备命令与流采集必须经该入库 harness
  执行(byte-exact 流分离/掩码/敏感终检/manifest,禁止 shell 重定向),harness done 后
  由独立 status PR 恢复 `ready` 并引用其 OID/hash。执行仍须维护者在具名窗口内亲手
  进行;窗口外或输入漂移时 R1-R3/`INV-1` dispatch `0`。
- `TASK-UD-CAPTURE-HARNESS-001`(r6 新增;2026-07-20 已 done——实现 PR #143、r7 对齐
  PR #148、状态 PR #149):host-only、stdlib-only、fake-runner
  测试零真实 hdc;实现范围=`scripts/ud_capture/` 三文件,白名单与 runbook argv 行逐字
  一致,source OID/hash 执行时记录;与在飞 `scripts/ui_dump_redaction/` 零交集。
- #219 仍是 immutable failure evidence,不得继续、复用、重判或打开其 controlled raw/full
  manifest。r9 remediation 已由 implementation/evidence PR #228 合入
  `b38d028ff821900c7c191c2bccc5951c5c719e7b`,host-only contract `63/0` PASS;独立状态与
  CAP-MUT ready-restore 已合入。Phase A 新鲜重跑 evidence PR #248 合入
  `79b795b7916c863376b3c1f9c37456b0089283dd`,状态 PR #251 合入
  `d5aded75d30fbd7ae048005b692b7f4138b23055` 后
  `TASK-UD-CAP-MUT-001 done`;R1/R2/R3 仍为 `unknownOutput`,不构成 Recipe success。
- `TASK-UD-R2-DECISION-001` 只在 r10 merge 后 ready:由维护者离线将 #248 的 proven-owned
  R2 sidecar 经固定 redactor 生成 reviewed derived fixture/receipt,登记 structural family、
  failure/unknown precedence 与 deterministic candidate locator。Agent raw read count、HDC/
  device dispatch 均为 `0`;decision 不记录 Phase A exact token。
- `TASK-UD-R2-R4-SEAM-001` 保持 blocked,直到上述 decision positive done 与独立 readiness
  合入。它才可实现 same-session selector/private bundle 与 R4 harness seam;其后仍需独立
  `TASK-UD-CAP-R4-001 blocked→ready` PR。任一 gate 缺失时 R4 dispatch `0`。
- `TASK-UD-R2-RECAPTURE-001` 在 r12/r13 merge 后由本独立 D2 readiness r1 起草
  `ready(on merge)`。它在 protected `main` 重验 harness/tool/device/firmware/fixture/argv/
  sidecar/schema pins（HDC 单一 expected tuple =
  `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` /
  `Ver: 3.2.0f` /
  `05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`）、
  per-device typed capability evidence、操作者/具名窗口与 persistent-root predicate;只可
  人类执行 R2-only sequence,R1/R3/R4 与 Agent dispatch `0`。fresh sidecar 必须在非
  临时仓外 root 保留并在 evidence 后复核 identity。
- `TASK-UD-R2-REDIAG-001` 等待 recapture done 与独立 D1 readiness 重钉 fresh raw
  length/SHA-256、retention、diagnosis tool OID/hash 与 CLI;只测量 fresh raw。它不能
  追溯旧 raw 根因,也不自动授权 redactor/decision/seam/R4/UD-001。
- `TASK-UD-REDACTOR-001` 必须在 TASK-UD-001 ready 前完成:固定
  `scripts/ui_dump_redaction/{redact.py,test_redact.py,algorithm-v1.json,safe-literals-v1.txt,redaction-receipt.schema.json,README.md}`,
  transform 确定性、unknown token fail closed、输出侧敏感终检、safe literals 逐项
  维护者批准;source hash 在 evidence 执行时记录。其 readiness(实现范围/base/
  stdlib-only/interpreter 实测)已由 r5 固定;任务已於 2026-07-20 done(实现 PR #144、
  状态 PR #150),无采集前置。
- derived golden 的隐私复核载体 = TASK-UD-001 golden PR 的维护者逐字审读(merge =
  attestation);`TEST-INT-UD-GOLDEN-001` 负责 hash 链与敏感字面量扫描的机器侧闭环。
- 后续 output-family decision 只允许有 repo-safe synthetic/derived positive fixture 的
  文本 marker 或结构 parser family。raw byte-fingerprint/digest family 在本 change 中
  unsupported/out of scope;若未来需要,须先由独立 approved change 固定复用 production
  stream→digest 路径的 privacy-safe conformance seam。
- mandatory SDD guard 使用 `<ARKDECK_ROOT>/.venv-sdd/bin/python`(Python 3.14.6、PyYAML
  6.0.3);每次执行前 preflight `import yaml` 并在 run.md 记录实际 path/version/hash,
  不得回落默认 `python3` 或联网安装。

## Requirement → AC → Test ownership

| Requirement/source | Acceptance | Test ID / method | Required binary evidence |
| --- | --- | --- | --- |
| r6 capture harness trust chain | `INT-UD-HARNESS-001` | `TEST-INT-UD-HARNESS-001` / offline fake-runner contract | 封闭白名单与 runbook 逐字镜像 + 占位符强校验负例 + 掩码/敏感终检/manifest 字节 parity + 白名单同步与 AST 审计 + 零真实 hdc |
| r9 exact typed-path echo boundary | `INT-UD-HARNESS-ECHO-001` | `TEST-INT-UD-HARNESS-ECHO-001` / offline synthetic fake-runner contract | future schema `1.1.0` + `FX-1` stdout exact-span policy facts + extra/variant/stderr/other-command/key/truncation/redaction negative matrix + unchanged repo hard gate + zero #219 raw/device access |
| r3 conservative Phase A capture | `INT-UD-CAPTURE-MUT-001` | `TEST-INT-UD-CAPTURE-MUT-001` / human runbook deviceMutation capture(经 pinned harness) | R1-R3 exact arrays + HP preflight 记录 + exact-path 清单 + 分立 raw origin + harness OID/hash + hardware evidence |
| r10 R2 structural output-family decision | `INT-UD-R2-DECISION-001` | `TEST-INT-UD-R2-DECISION-001` / human-offline derived-fixture review | redactor receipt/hash chain + reviewed derived positive fixture + structural family/locator + failure/unknown precedence + zero token/raw/device exposure |
| r11 R2 raw 根因只读诊断(readiness r1 固定) | `INT-UD-R2-DIAG-001` | `TEST-INT-UD-R2-DIAG-001` / human host-only read-only diagnosis + offline synthetic adversarial contract | readiness r1 pinned raw 二元组 hash gate(866256 bytes / `ec6663e6…`)+ closed 非内容 JSON 报告 `arkdeck-ud-raw-diagnosis-1.0.0` + 双普查面(UTF-8 结构/码点策略,镜像 `INVALID_UTF8=26`/`INVALID_UNICODE=27` 代码路径)+ synthetic 32 用例族与 AST/policyRefs 审计 + Agent raw read `0` 零设备 dispatch + 维护者 review/merge attest |
| r12/r13 + D2 readiness r1 R2-only persistent recapture | `INT-UD-R2-RECAPTURE-001` | `TEST-INT-UD-R2-RECAPTURE-001` / human closed-runbook deviceMutation recapture | r13 exact HDC repin + 本独立 D2 readiness 的 exact-device capability/window acceptance + existing harness exact sequence + persistent non-temp controlled root + fresh absent→new regular R2 sidecar + separated complete origins/hash + post-evidence retention identity + R1/R3/R4 与 Agent/destructive dispatch `0` |
| r12 fresh R2 raw non-content diagnosis | `INT-UD-R2-REDIAG-001` | `TEST-INT-UD-R2-REDIAG-001` / human host-only fresh-input diagnosis | recapture done + 独立 D1 readiness 重钉 fresh length/hash/tool OID + existing closed diagnosis schema与synthetic 37/37 + fresh-only measurement + Agent raw read/installed-HDC/device dispatch `0` |
| r10 same-session selector/harness seam | `INT-UD-R2-R4-SEAM-001` | `TEST-INT-UD-R2-R4-SEAM-001` / offline synthetic adversarial contract | exactly-one selector + private bundle/receipt closed schemas + typed path/expected-hash reference + session/window/raw binding + R4 exact argv + all-negative zero dispatch/leak |
| r3/r10 conservative Phase B R4 capture | `INT-UD-CAPTURE-R4-001` | `TEST-INT-UD-CAPTURE-R4-001` / decision-bound human deviceMutation capture | fresh same-session R2 + selector receipt/private-bundle hash + R4 exact array + HP preflight + 清单/cleanup + hardware evidence |
| UI Dump derived-golden privacy transform | `INT-UD-REDACTOR-001` | `TEST-INT-UD-REDACTOR-001` / offline adversarial/property contract | deterministic transform + receipt hash 链 + 输出侧敏感终检 + synthetic 负例矩阵 |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | invalid component ID preflight + zero argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | approved exact argv + registered output-family classifier |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / derived golden review | capture-manifest→receipt→bytes hash 链 + registry/profile/lock/Bundle 一致 + 敏感扫描零命中 |

local capture/redactor case 不关闭 canonical Core evidence,其 canonical 输入与 ownership:

| Task | Canonical Requirement → AC → Test inputs | Closure disposition |
| --- | --- | --- |
| `TASK-UD-HARNESS-ECHO-001` | `REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01` | read-only privacy Safety input;synthetic harness policy 不执行 diagnostic export、不关闭 canonical platform evidence |
| `TASK-UD-CAP-MUT-001` | `REQ-DUMP-002/005/006/007/008` → `AC-DUMP-002-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;capture 遵守但不关闭 parserGolden/contract/platform cases |
| `TASK-UD-R2-DECISION-001` | `REQ-DUMP-003/005/008` → `AC-DUMP-003-01/005-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;derived structural decision 不认领 canonical PASS,不登记 exact token |
| `TASK-UD-R2-DIAG-001` | `REQ-DUMP-005/008` → `AC-DUMP-005-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;非内容只读诊断不认领 canonical PASS,不产出 derived/fixture,不解锁任何复活分支 |
| `TASK-UD-R2-RECAPTURE-001` | `REQ-DUMP-002/005/006/007/008` → `AC-DUMP-002-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | Safety inputs;只贡献 fresh proven-owned R2 raw 与 retention facts,不关闭 canonical parser/artifact/cleanup/platform evidence |
| `TASK-UD-R2-REDIAG-001` | `REQ-DUMP-005/008` → `AC-DUMP-005-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;fresh 非内容测量不认领 canonical PASS,不产出 derived/fixture,不解锁 downstream |
| `TASK-UD-R2-R4-SEAM-001` | `REQ-DUMP-003/005/008` → `AC-DUMP-003-01/005-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;synthetic selector/bundle contract 不认领 canonical PASS |
| `TASK-UD-CAP-R4-001` | `REQ-DUMP-003/005/006/007/008` → `AC-DUMP-003-01/005-01/006-01/007-01/008-01` → matching `TEST-AC-DUMP-*` | read-only Safety inputs;`AC-DUMP-003-01` 只在 `TASK-UD-001` 关闭;capture task 不认领 canonical PASS |
| `TASK-UD-REDACTOR-001` | `REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01` | read-only privacy Safety input;synthetic redactor contract 不执行 diagnostic export、不关闭 canonical platform evidence |

## Acceptance matrix

| Evidence ID | Method | Expected result | Status |
| --- | --- | --- | --- |
| INT-UD-HARNESS-001 | offline fake-runner contract over the closed UD capture harness | 封闭 COMMAND_SPECS 与 runbook argv 行逐字一致且未知 id 拒绝;CONNECT_KEY/WINDOW_ID/本地路径强校验;无 shell、流分离 byte-exact+逐流 SHA-256、4 MiB cap+truncated flag、默认 120s timeout;掩码、逐命令 `arkdeck-ud-capture-redacted-1.0.0` manifest 确定性序列化、输出侧敏感终检 fail-closed、仓库外强制;fake-runner 正反全路径、白名单↔README 同步、AST no-shell/no-network 审计全 PASS;零真实 hdc | passed(TASK-UD-CAPTURE-HARNESS-001 done;PR #143 + r7 alignment PR #148;`evidence/runs/TASK-UD-CAPTURE-HARNESS-001/run.md` r7 alignment addendum,52/0) |
| INT-UD-HARNESS-ECHO-001 | offline synthetic fake-runner contract over the exact typed-path policy | full/redacted manifest schema 固定为 `arkdeck-ud-capture-{manifest,redacted}-1.1.0`;只在完整、未截断/未 drain-incomplete 的 `FX-1` stdout 中接受 byte-exact validated `LOCAL_HAP_PATH` span,且每个 generic user-path match 必须完全落入该 span;manifest 确定性记录 policy id、`expectedLocalInputEchoFound=true`、`unexpectedUserPathFound=false`,但 redacted manifest/summary/CLI 不含原 path;extra/variant/dirname/prefix/sibling/alias、stderr/其他 command、key material、truncation、broken redaction 全部 fail closed;existing 52 tests 与新矩阵全 PASS;#219 raw/full-manifest、installed HDC/device/network dispatch 均为 0 | passed(TASK-UD-HARNESS-ECHO-001 done;PR #228;`evidence/runs/TASK-UD-HARNESS-ECHO-001/run.md`,63/0) |
| INT-UD-CAPTURE-MUT-001 | human runbook Phase A first target-build deviceMutation capture | no readOnly Recipe branch;HP-0..HP-2 preflight 记录且恰一目标;每条命令显式 `-t`,connect key 只来自同会话 inventory;R1-R3 exact one-element payloads;exact-path pre/post 清单与 owned-only cleanup;stdout/stderr/sidecar 分立 raw origin 逐流 SHA-256;raw 全部留仓库外;hardware-evidence 过 schema 且 claimed operator 由维护者 review attest;destructive/Agent dispatch 0 | passed(TASK-UD-CAP-MUT-001 done;PR #248 + status PR #251;`evidence/runs/TASK-UD-CAP-MUT-001/attempt-3-complete-20260721/`) |
| INT-UD-R2-DECISION-001 | human-offline deterministic R2 derived-fixture decision review | 固定 redactor 对 #248 R2 sidecar exact raw hash执行;receipt/schema/hash chain 与 reviewed derived fixture byte parity 完整;登记 positive structural family、failure/unknown precedence、deterministic locator 与 exactly-one candidate rule;不登记 token;Agent raw read、HDC/device/network dispatch 均为 0;若无法形成 repo-safe positive fixture或唯一 locator则 truthful negative decision且后续保持 blocked | passed(truthful-negative evidence/decision PR #263 `952b0f7` + status PR #267 `c9b3f77`;fixed redactor 返回 `INVALID_UNICODE`/27,零 derived/receipt,SEAM/R4/UD-001 保持 blocked) |
| INT-UD-R2-DIAG-001 | human host-only read-only non-content diagnosis of the pinned R2 raw + offline synthetic adversarial contract | readiness r1 固定 exact CLI 与 closed schema `arkdeck-ud-raw-diagnosis-1.0.0`;输入门实测长度/SHA-256 精确等于 #248 pinned R2 raw 二元组(866256 bytes / `ec6663e6…077`),失配 `INPUT_HASH_MISMATCH` 零输出;报告只含非内容事实(error name/code、字节总数、invalid 偏移/长度/计数、首末偏移、字节类别直方图、十分位分布与 tail 布尔、工具/policy hash),值类型法则禁止任何 raw 子串/解码文本/内容窗口/页面文本/window/component 字面量,输出侧终检 fail closed;双普查面镜像 redactor 错误路径(`INVALID_UTF8=26`/`INVALID_UNICODE=27`);synthetic 32 用例族 + AST/policyRefs 强制审计全 PASS,零真实 raw;维护者仓外亲手执行 exact CLI,Agent raw read `0`,installed HDC/device/network/GUI/destructive dispatch 均 `0`;done 另需二值根因结论(raw-data 或 pipeline)与独立 status PR,无法判定/歧义/双因则 status 回 blocked;不授权任何复活分支 | blocked(implementation + synthetic evidence 已经 #683 merge `495c7356081a83d18538ae6fcdb3e3580134dfbf` 合入,synthetic 矩阵 37/37 PASS;humanOfflineDiagnosis 半面永久不可执行——pinned exact input 经维护者 2026-07-28 亲手离线检索证实永久不可得,四组目录区级检索全部零命中,见 `evidence/runs/TASK-UD-R2-DIAG-001/input-unavailability.md`;依 readiness r1 fail-closed 条款 status 回 blocked,旧 raw 的 raw-data vs pipeline 根因永久不可测,不引入新根因主张、不授权任何复活分支;复活须新 proposal 修订收窄到重捕分支) |
| INT-UD-R2-RECAPTURE-001 | human R2-only persistent controlled deviceMutation recapture | r13 exact HDC repin 后，本 D2 readiness 重钉 current harness/tool/device/fixture/argv/sidecar/schema pins，接受 #248/#251 exact-device typed capability evidence，并固定 `UD-R2-RECAPTURE-DAYU200-20260728-001` human-only one-run exclusive window（start deadline `2026-08-04T16:00:00Z`）;owner-only persistent root 在 git 与 OS temp/ephemeral roots 外;exact HP/FX/INV-1/R2/SC sequence只 dispatch R2 一次,R1/R3/R4 为 0;R2 sidecar必须 absent→new regular→SC-2 receive→SC-3 exact cleanup→absent,origin 分立且 complete/untruncated/whole-hashed;repo-facing evidence 只含 redacted manifests/hash/placeholder retention facts与 schema-valid hardware evidence;post-evidence no-follow recheck 证明 retained `0o600` raw length/hash不变;Agent/destructive dispatch 0;不作 success/old-root claim | ready(on D2 readiness r1 merge；draft/PR 阶段仍 blocked/零 device dispatch) |
| INT-UD-R2-REDIAG-001 | human host-only non-content diagnosis of the fresh retained R2 raw | recapture done 后独立 D1 readiness 重钉 fresh length/hash、retention、tool OID/hash、policyRefs、interpreter与 exact CLI;复用 closed `arkdeck-ud-raw-diagnosis-1.0.0`,existing synthetic 37/37+AST/policyRefs与输出终检同 revision PASS;报告只登记 fresh raw 的 NONE/INVALID_UTF8/INVALID_UNICODE 非内容 measurement,路径/bytes不入仓且 Agent raw read 0;不追溯 old root、不自动授权 redactor/output-family/SEAM/R4/UD-001 | blocked(等待 recapture done 与独立 D1 readiness) |
| INT-UD-R2-R4-SEAM-001 | offline synthetic adversarial selector/private-bundle/R4 harness contract | selector 只读 fresh same-session proven-owned complete R2 raw并依 approved decision exactly-one 选择;private `0o600` bundle含 token/256-bit nonce/decision/raw/session/window binding且不入仓不输出;repo-safe receipt不含 token/nonce;harness 只接受 typed path + expected SHA-256 reference并内部 materialize R4 one-element payload;zero/multiple/stale/tamper/symlink/mode/path/injection/drift/truncation全为零 request/process/HDC dispatch且零敏感泄漏 | blocked(等待 positive decision done 与独立 readiness) |
| INT-UD-CAPTURE-R4-001 | decision-bound human Phase B deviceMutation capture | positive R2 structural decision与selector/harness seam均 done后,在 fresh Phase B 同一 fixture/window lifetime执行 R2→selector private bundle→R4;Phase A token 不复用,token/nonce/bundle bytes不入仓;R4 exact one-element payload与 Phase A 相同的 preflight/清单/cleanup/privacy gates;repo-safe receipt、bundle hash与hardware-evidence链闭合;destructive/Agent dispatch 0 | blocked |
| INT-UD-REDACTOR-001 | offline deterministic privacy-transform adversarial/property contract | 固定 transform source/algorithm manifest/safe-literal allowlist/receipt schema;expected-input-hash 不符拒绝;unknown/unclassified token fail closed;输出侧敏感终检命中即硬失败;receipt 记录完整 hash 链与 replay 命令;重复运行 byte-deterministic;synthetic 负例矩阵全过且不覆盖 raw、不产出可提交 derived;零真实 raw/HDC/device/network | passed(TASK-UD-REDACTOR-001 done;PR #144;`evidence/runs/TASK-UD-REDACTOR-001/` run.md + review-remediation-2026-07-20.md,21/0) |
| AC-DUMP-003-01 | canonical `recipeSchemaContract` | componentDetail missing、empty、非法格式/字符、leading option、whitespace/newline、shell metacharacter 与 argument injection 全部在 argv/ProcessRequest 前失败;argv/request/recording-dispatch count 均为 0;合法 token positive control 不启动真实 HDC | blocked with TASK-UD-001 |
| INT-UD-WRAPPER-001 | adversarial contract tests | 每 Recipe 与 approved decision exact argv equality;success 只来自登记且有 repo-safe positive fixture 的文本 marker/结构 parser family,不依退出码;raw byte-fingerprint/digest registration 被拒绝;错误样 exit-0 显式失败;未登记/marker 缺失为 unknownOutput;chunk/stream precedence 与无 shell composition 全覆盖;零真实 HDC | blocked with TASK-UD-001 |
| INT-UD-GOLDEN-001 | deterministic derived-golden registration review | 每个入仓 golden bytes SHA-256 = receipt derived hash;receipt raw hash = capture manifest whole-stream hash;algorithm/manifest/allowlist hash 与 REDACTOR evidence 一致;`.gitattributes` 先行;registry、profile/lock 与 Bundle.module path/hash 一致;敏感字面量扫描零命中;receipt 缺失/hash 断链/未审读 derived 一律 fail;TASK-UD-001 raw 访问 count 0 | blocked with TASK-UD-001 |

## Real-hardware evidence gate

`TASK-UD-CAP-MUT-001`、`TASK-UD-R2-RECAPTURE-001` 与 `TASK-UD-CAP-R4-001` 各自
必须提交其 evidence directory 下的 `hardware-evidence.json`,并只读消费
`openspec/contracts/hardware-evidence.schema.json`(version 2.0.0,provider none)。每份
记录必须包含 claimed operator、physical target/serial、firmware、toolchain、transport、
executedAt、该 task exact acceptance ID、actual step kinds 与所有 repo-facing artifact
path/hash。RECAPTURE 另须在 run.md 记录 persistent-root predicate 与 fresh raw
post-evidence retention recheck;raw 的实际路径/bytes 不进入 hardware evidence 或 Git。

evidence PR 必须运行 JSON-schema 校验并在 `run.md` 记录校验工具的 path/version(执行时
记录,不预钉 hash)。schema 校验只证明结构;claimed operator 与 run 叙述的真实性由
维护者对 evidence PR 的 review/merge attestation 保证——与本仓库其他 merge 相同的
信任根(先例 EVD-M0B-DAYU200-20260718-001)。schema 校验失败或 artifact hash 断链时
不构成 realHardware evidence/PASS。

## Gate

- #219 failed session 只保留为 immutable failure evidence,不得继续、复用、重判或读取其
  controlled raw/full manifest。r9 remediation 与 fresh Phase A 已完成;#248/#251 只关闭
  Phase A capture protocol,没有登记 R1-R3 success family,也没有授权 R4。
- #695 已证明 #248 R2 pinned raw 永久不可得;旧 raw 根因不得再猜测或重建。r12 仅声明
  recapture-only 后续链,不使重采 ready。只有独立 D2 readiness 合入后,人类维护者才可
  在具名窗口执行 R2-only sequence;fresh raw 必须落在非临时 persistent controlled root
  并通过 retention identity recheck。随后仍须独立 D1 readiness 按新 length/hash 重钉
  diagnosis;任一步都不自动解锁 SEAM/R4/UD-001。
- r13 只替换 recapture `HP-0` 的 expected HDC identity，不是 D2 readiness。旧
  `3.2.0d` pin 不得作为 fallback；后续 host hash或窗口内 runtime version/hash与
  `3.2.0f` / `05b2…f83` 任一不符时，fixture/device/Recipe dispatch 为 `0` 并重新
  readiness/revision。
- 本 D2 readiness r1 只在 merge 后使任务 ready；named window =
  `UD-R2-RECAPTURE-DAYU200-20260728-001`，human `lvye` only，`maxRuns=1`，start
  deadline `2026-08-04T16:00:00Z`，first installed-HDC dispatch 消费。窗口前/外、
  中断、并发、pin/capability/storage mismatch 或 retry 均为零 further dispatch 并要求
  新 readiness；本 readiness PR 自身不执行窗口。
- expected local HAP echo allowance 只属于 future schema `1.1.0` 的 `FX-1` stdout exact
  validated span。它不允许第二条/变体用户路径,不适用于 stderr/其他 command,不放宽
  key-material、timeout/truncation/drain 或 repository-facing `_assert_redacted_clean` gate。
- 任何设备命令前必须完成 `HP-0..HP-2` 并记录;恰一目标、显式 `-t`、无默认目标;批次前
  复查漂移即停。
- R1-R4 首次执行都按 deviceMutation scope、exact-path 清单与 owned cleanup 执行。R4 仅
  可在 positive R2 structural decision、same-session selector/harness seam done 与独立 R4
  readiness 全部合入后执行;Phase B 必须 fresh same-session R2→selector→R4,不得复用
  Phase A token。
- `TASK-UD-REDACTOR-001` 未 `done`,或其 algorithm/manifest/allowlist/receipt schema 任一
  未固定时,不得生成 derived golden,TASK-UD-001 不得 ready;golden task 不得修改该
  toolchain。
- TASK-UD-001 只有在两个 capture task `done`、每个拟支持 Recipe 有真实输出记录、
  approved decision revision 固定 exact argv 与 success/failure/unknown family、REDACTOR
  done 后才可从 `blocked` 起草 `ready`。fake 只能验证已批准规则,不能定义规则或证明
  目标 build。
- raw byte-fingerprint/digest output family 不得在本 change 登记;干净 checkout 的
  contract tests 必须对每个获批文本 marker/结构 parser family 使用 repo-safe
  synthetic/derived fixture 经 exact production semantic-evaluator path 正向覆盖。
- capture raw 只存在仓库外 `0o700` controlled root;derived golden 必须通过
  `capture-runbook.md` 的 deterministic fail-closed chain;任一 unclassified token/line
  或隐私复核失败都不得提交 fixture。R2 decision 是窄化例外,只可提交维护者审读的
  derived fixture/receipt与 structural decision,不得提交 exact token/nonce/private bundle。
- mandatory SDD guard 先 preflight 固定 interpreter,再以
  `ARKDECK_PYTHON=<fixed-path> scripts/check-sdd.sh` 执行;不得联网安装或默认回落。
- M0B/source/public documentation 都只可作为设计输入,不构成 current Recipe output
  mode/success、compatibility、conformance 或 hardware/support/release claim;
  `TASK-M1-006` 保持 blocked/非 done,本 change 不重判其任何 evidence。
