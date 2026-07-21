# Tasks — CHG-2026-008 ui-dump HiDumper wrapper integration

> V2 治理:本文件是任务的唯一事实源;任务状态变更仅在维护者 review/merge 后
> 生效。全部真机采集由人类维护者执行,Agent 不执行真实 `hdc`。

## r3 remediation 边界与裁剪记录

r2 readiness 已被复审推翻:M0B evidence 只含 `hidumper --help`/`-ls` 两条命令的流,不是
四个 Recipe 执行;在无目标 build Recipe 输出时 pin argv/golden 违反 ui-dump spec 的
validate-then-pin 规则(spec.md:47)。r3 恢复 `TASK-UD-001 blocked`,补齐 CHG-2026-014
consumer-dependency 表与 `AC-DUMP-003-01` Core 追溯;实现草案 PR #126 永久保留为不可
合并的审计记录。

r3 初稿(PR #128 分支 head `a613b76`,保留于本 PR 提交历史)曾提出 journaled
execution-authority(JAUTH)模型:external Core MAJOR(`TASK-JAUTH-CORE-001`/CORE-3.0.0)、
production supervisor/binding 栈前置、offline receipt verifier 与 7 任务链。经维护者
2026-07-20 review 决定按 **M0B 模型裁剪**(本 PR merge 即该决定生效):

- 人工采集的授权载体 = runbook + 人类维护者亲手执行 + 维护者对 evidence PR 的
  review/merge attestation(先例 TASK-M0B-001,PR #56/#58/#59;AGENTS.md 本就规定
  destructive/真机操作由人类执行并记录 evidence);
- JAUTH 模型不作为本 change 前置。它作为候选未来 Core MAJOR 记入
  `openspec/planning/backlog.md`;本 change 保持 `class:platform` /
  `core_change_level:none`,不新增 journal event/append-chain 字段、不改变 dispatch
  authority;
- 人工采集不依赖 production HDC supervisor/binding 栈(M1-006/M1-007/CHG-2026-015 均
  非本 change 依赖)。未来若产品内自动采集 workflow 需要该栈,由相应 change 自行立项;
- 被裁剪任务的处置见文末"裁剪任务记录"。

r3 合入时本 change 有 4 个任务,全部 `blocked`;r6 增设 capture harness 任务后共 5 个;
r9 因 #219 首次 run 暴露的 FX-1 typed-path echo blocker 增设一个 host-only remediation
任务后共 6 个;r10 因 Phase A token 跨生命周期与 repository-privacy provenance 冲突新增
R2 decision 与 R2→R4 seam 两个串行任务,共 8 个。现行状态一律以各任务 `Status` 行为
准。real-device task 在其全部前置 done、独立 ready-restore PR 合入且具名设备窗口内才
可执行。

## TASK-UD-CAPTURE-HARNESS-001 — Phase A/B 受控采集 harness 前置

- Status:done(TASK-UD-CAPTURE-HARNESS-001 implementation + evidence PR #143 与其
  r7 alignment 修复 PR #148 已由维护者 review/merge 合入 `main`(squash `7978fa7`、
  `ba4b75b`);本独立状态 PR 依据下列 completion evidence 起草 `ready→done`,仅在
  维护者 review/merge 后生效。本状态只关闭 harness 的 host-only contract evidence,
  不改变 TASK-UD-CAP-MUT-001(blocked;其恢复 `ready` 须另起独立状态 PR,引用本
  done 与 merged OID/逐文件 hash,r4 五项 readiness 输入保持有效)、
  TASK-UD-CAP-R4-001/TASK-UD-001(blocked)、change approved、platform/hardware/
  support/release 状态,不构成任何真机、output-family 或 compatibility claim)
- Completion evidence:`evidence/runs/TASK-UD-CAPTURE-HARNESS-001/run.md`(r7
  alignment addendum;alignment source `21029d7cbc20ca7d5c9722e484bd5f13da3b2baa`,
  merged squash `ba4b75b`;三文件 SHA-256 在 addendum 表内且与 `main` 逐一相符——
  README `0a479a4b…`、capture.py `2cc168b4…`、test_capture.py `e83011ba…`;
  `TEST-INT-UD-HARNESS-001` 52 tests/0 failures 于系统解释器与 readiness-pinned
  `.venv-sdd` 双绿,check-sdd 0/0/111,run 记录敏感扫描零命中;安装态 HDC/device/
  network/destructive dispatch count 全为 `0`)。状态 PR 复核(2026-07-20,当前
  `main` `ba4b75b`):52 tests/0 failures 与三文件 hash 相符均复现——该复核只确认
  evidence 在现基线可复现,不构成新的 acceptance 结论。
- Objective:在任何 Phase A/B 设备执行前,交付入库、有测试、可按 OID/hash 引用的
  采集 harness——把 M0B `capture.py` 的信任链(封闭白名单、argv 数组无 shell、
  byte-exact 流分离、掩码、输出侧敏感终检、确定性 manifest)复制到 UD 采集命令面。
  2026-07-20 桌面推演审计裁定:无此工具则 Phase A 无法产出合规 evidence(G1
  BLOCKER——`m0b_capture/capture.py` 白名单不含任何 Phase A 命令且按设计只读,
  shell 重定向会破坏单元素 `-a` payload 边界与 byte-exact/自检保证)。
- Change-local closure:`INT-UD-HARNESS-001` / `TEST-INT-UD-HARNESS-001`。
- Canonical Safety inputs:`REQ-DUMP-005/008`(流分离与 raw 隐私边界的 read-only
  Safety 输入;本 task 不认领任何 canonical PASS)。
- Readiness review(2026-07-20;host-only,零 HDC/device dispatch):
  - Change gate:satisfied on merge。r5 已经 PR #136 合入;本 r6 不改既有任务的
    AC/method/minimum evidence。
  - Scope/base gate:实现范围= `scripts/ud_capture/{README.md,capture.py,test_capture.py}`
    + evidence + 本 tasks.md 状态行;stdlib-only、零第三方依赖、零联网;实现 base=本
    r6 合入后 `main` HEAD,source OID/逐文件 SHA-256 由实现 run.md 执行时记录(不预
    钉);与在飞 `scripts/ui_dump_redaction/`、`Packages/**` 零交集,`scripts/ud_capture/`
    在 `main` 与全部 open PR 中不存在。
  - Environment gate:`<ARKDECK_ROOT>/.venv-sdd/bin/python` 实测 Python 3.14.6+PyYAML
    6.0.3;测试全程 fake runner,零真实 hdc 执行。
  - Precedent gate:`scripts/m0b_capture/capture.py`+`test_capture.py`(PR #56,经
    xhigh review 15 findings 修复)为结构先例;通用机制(流采集/掩码/自检/序列化)
    允许复制改造,白名单命令集必须重建为 runbook 已批准 argv 行的逐字镜像。
  - Review boundary:本 r6 只定义任务并修订 runbook/metadata;实现不得扩展 runbook
    之外的命令,不得触碰真实设备。
- In scope:
  1. 封闭 COMMAND_SPECS:`HP-0/HP-1/HP-2/INV-1/R1/R2/R3/SC-1/SC-2/SC-3/FX-1..FX-4`,
     每条 id→argv 数组模板与 `capture-runbook.md` 逐字一致;运行时占位符强校验——
     `CONNECT_KEY` 只接受本会话 HP 输出值、`WINDOW_ID` 只接受纯 ASCII 十进制、
     `LOCAL_HAP_PATH`/`LOCAL_SIDECAR_DEST` 必须仓库外且经存在性/新建性检查;
     `build_argv` 身份校验、未知 id 拒绝(先例 capture.py);
  2. 无 shell;流分离 byte-exact 写入(O_EXCL、`0o600`)、逐流 SHA-256、retained
     4 MiB cap+truncated flag、per-command timeout 通道(默认 120s,记录不可禁用);
  3. connectkey/home 掩码、逐命令 redacted manifest(schema
     `arkdeck-ud-capture-redacted-1.0.0`,确定性序列化与 `scan.py`/`_json_bytes` 字节
     parity)、输出侧敏感终检 fail-closed、输出目录强制仓库外(三件先例机制);
  4. `capture-hashes` 汇总与 `NN-<id>.<stream>` 受控文件命名;
  5. fake-runner 正反全路径测试、白名单↔README 同步测试、AST no-shell/no-network
     审计;测试零真实 hdc。
- Out of scope:执行真实设备采集(仍属 CAP-MUT/CAP-R4 的人类操作);修改
  `scripts/m0b_capture/**`/`scripts/ui_dump_redaction/**`;新增 runbook 之外的命令;
  任何 Swift/`Package.swift`/治理文件(本 tasks.md 状态行除外)。
- Allowed paths:
  - `scripts/ud_capture/README.md`
  - `scripts/ud_capture/capture.py`
  - `scripts/ud_capture/test_capture.py`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAPTURE-HARNESS-001/**`
  - 本 `tasks.md`(仅该 task 的独立 status/evidence 更新)
- Read-only inputs:`capture-runbook.md`、`scripts/m0b_capture/**`(先例)、
  `openspec/contracts/hardware-evidence.schema.json`。
- Hardware required:no;installed HDC、device/network dispatch 均为 `0`。
- Required environment:`<ARKDECK_ROOT>/.venv-sdd/bin/python`;执行时在 run.md 记录
  实际 path/version/hash。
- Deliverables:三个文件 + `run.md`(source OID/逐文件 hash、测试计数、命令、掩码/
  终检负例演示、偏差与遗留风险)。
- Verification:`TEST-INT-UD-HARNESS-001`=fake runner 下全部命令 id 正反路径、占位符
  强校验负例、掩码/终检/manifest 字节 parity、白名单同步、AST 审计全部 PASS;
  `<ARKDECK_PYTHON> scripts/ud_capture/test_capture.py`;`scripts/check-sdd.sh`;
  `git diff --check`。
- Evidence gate:全部测试同一 revision PASS 才可另起 status PR 起草 `done`;done 后
  `TASK-UD-CAP-MUT-001` 由独立 status PR 恢复 `ready`(引用 harness merged OID/逐文件
  hash;r4 五项 readiness 输入保持有效,无需重做)。
- PR boundary:一个独立 implementation + evidence PR;`ready→done` 独立状态 PR。

## TASK-UD-HARNESS-ECHO-001 — FX-1 exact typed-path echo remediation

- Status:done(TASK-UD-HARNESS-ECHO-001 implementation + evidence PR #228 已由维护者
  review/merge 合入 `main` `b38d028ff821900c7c191c2bccc5951c5c719e7b`;本独立状态
  PR 依据下列 completion evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。
  本状态只关闭 host-only `INT-UD-HARNESS-ECHO-001`,不恢复
  `TASK-UD-CAP-MUT-001 ready`,不授权 installed HDC/device/fixture/Recipe dispatch,
  不重判 #219,也不构成 canonical AC、hardware、compatibility/support/release claim)
- Completion evidence:
  `evidence/runs/TASK-UD-HARNESS-ECHO-001/run.md`(implementation source
  `4049bb0de80160a696e6f8defabb3f70e4135d5a`;merged squash
  `b38d028ff821900c7c191c2bccc5951c5c719e7b`;README/capture.py/test_capture.py
  SHA-256 分别为 `6e5db182…`、`b407aaa0…`、`b29c15b8…`;schema `1.1.0`、exact
  FX-1 stdout span policy 与 synthetic adversarial matrix `63/0` PASS,其中原 52 tests
  全部保留;check-sdd `0/0/111`;AST no-shell/no-network、forbidden raw/user-literal 与
  repository-facing redaction hard gate 审计 PASS;installed-HDC/device/network/GUI/
  destructive dispatch 与 #219 controlled raw/full-manifest read count 均为 `0`)。
  状态 PR 在合入后的 `main` `b38d028…` 复验 `63/0` 与 check-sdd `0/0/111`,三文件
  hash 与 run.md 完全相符;该复验只确认 evidence currency,不授权 CAP-MUT。
- Objective:修复 #219 暴露的 harness evidence-seam blocker——把 controlled raw 中
  `FX-1` stdout 对 exact validated `LOCAL_HAP_PATH` 的预期回显,与 repository-facing
  path 泄漏分成两个独立 gate;仅前者在窄化 policy 下 MAY 通过,后者及任何额外敏感
  literal 仍 fail closed。
- Change-local closure:`INT-UD-HARNESS-ECHO-001` /
  `TEST-INT-UD-HARNESS-ECHO-001`。
- Canonical Safety input:`REQ-DUMP-008`(本地优先与敏感数据边界的 read-only input;本
  task 不执行 diagnostic export、不认领 `AC-DUMP-008-01` 或任何 canonical PASS)。
- Readiness review(2026-07-21;host-only,零 HDC/device dispatch):
  - Change/evidence gate:#219 已由维护者合入 `main`
    `95846eda3c634d4a445a970709e783743b071695`;其 repo-safe evidence 证明 FX-1
    stdout `179` bytes、wholeStream、无 timeout/truncation/drain incomplete,process exit
    `0`,同时 `userPathFound=true`、`localInputPathFound=true`、
    `selfCheckPassed=false`;R1-R3 dispatch `0/0/0`,cleanup 已按 runbook 执行。
  - Base gate:implementation 必须以 r9 merge 后的 `main` 为 base,执行时在 run.md 记录
    full OID 与三个 deliverable hash;本 readiness base 仅为 #219 merge
    `95846eda3c634d4a445a970709e783743b071695`,不得预钉未来实现 OID。
  - Privacy gate:实现与测试只读消费 #219 的 `run.md` 与
    `02-FX-1.redacted-manifest.json` 布尔/hash facts;不得打开、复制、解析或 fixture 化
    #219 controlled raw/full manifest/用户路径。positive/negative bytes 全部 synthetic。
  - Environment gate:`<ARKDECK_ROOT>/.venv-sdd/bin/python`(Python 3.14.6 + PyYAML
    6.0.3),stdlib-only、fake runner、零联网、零 installed HDC/device/process dispatch。
- In scope:
  1. 将 future full/redacted manifest schema 从
     `arkdeck-ud-capture-{manifest,redacted}-1.0.0` 升为 `1.1.0`;旧 #219 `1.0.0`
     evidence 保持 immutable,不得重写或视作新 schema PASS;
  2. 仅当 command identity 为注册表中的 `FX-1`、stream 为 stdout、stream 完整且未
     truncate/drain-incomplete 时,允许 synthetic/real controlled raw 中出现一个或多个
     byte-exact validated `LOCAL_HAP_PATH` span。每个 `_USER_PATH` match 的 byte range
     必须完全落在某个 exact allowed span 内;否则 `unexpectedUserPathFound=true` 并
     STOP。substring/prefix/dirname/sibling、大小写/Unicode/realpath 变体、symlink
     alias、stderr echo 与其他 command/stream 一律不匹配 allowance;
  3. per-stream self-check 保留 `userPathFound`/`localInputPathFound`,并新增确定性 policy
     facts(至少包含 policy id、`expectedLocalInputEchoFound`、
     `unexpectedUserPathFound`);allowed echo 路径只可表现为布尔事实,不得进入 redacted
     manifest、summary、CLI 文本或 repository evidence;
  4. `_assert_redacted_clean` 对 operator home、connect key、window id、local input path、
     generic user path 与 key-material marker 的硬失败保持不变;raw byte-exact 文件、
     whole-stream hash、`0o600`、exclusive-create、timeout/truncation/drain gates 保持不变;
  5. fake-runner/adversarial tests 至少覆盖:FX-1 stdout exact-path positive;同一输出附加
     第二条用户路径;dirname/prefix/sibling/大小写/Unicode/alias 变体;FX-1 stderr;
     非 FX-1 command;key material;truncation/drain incomplete;broken redaction;schema/
     README/runbook sync;manifest deterministic byte parity。existing 52 tests 必须继续 PASS。
- Out of scope:读取真实 raw/full manifest;重跑 #219 或任何 HDC/device 命令;修改 closed
  argv/command ids、target binding、Recipe/sidecar/cleanup semantics;generic path allowlist;
  shell/stdout filter 或丢弃 raw bytes;修改 Core/spec/contracts、redactor、Swift/App code;
  改变 `TASK-UD-CAP-MUT-001` 状态;hardware/compatibility/support/release claim。
- Allowed paths:
  - `scripts/ud_capture/README.md`
  - `scripts/ud_capture/capture.py`
  - `scripts/ud_capture/test_capture.py`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-HARNESS-ECHO-001/**`
  - 本 `tasks.md`(仅本 task 的独立 status/completion evidence 更新)
- Read-only inputs:
  - `capture-runbook.md`
  - `evidence/runs/TASK-UD-CAP-MUT-001/run.md`
  - `evidence/runs/TASK-UD-CAP-MUT-001/redacted-manifests/02-FX-1.redacted-manifest.json`
  - `evidence/runs/TASK-UD-CAPTURE-HARNESS-001/**`
- Forbidden paths:#219 controlled raw/full manifest/session、既有 evidence 修改、
  `openspec/specs/**`、`openspec/contracts/**`、`Packages/**`、
  `scripts/ui_dump_redaction/**` 与上述 Allowed paths 外任何实现文件。
- Risk:high(窄化一个敏感 raw pass/fail gate;必须以 byte-range exactness、command/stream
  identity、schema version 与 repository-facing hard gate 的 adversarial tests 收口)。
- Hardware required:no;installed HDC、device/network/GUI/destructive dispatch 均为 `0`。
- Required environment:`<ARKDECK_ROOT>/.venv-sdd/bin/python`;执行时在 run.md 记录
  actual path/version/hash;不得联网安装或回落默认解释器。
- Deliverables:三份 harness 文件 + `evidence/runs/TASK-UD-HARNESS-ECHO-001/run.md`,记录
  source OID/逐文件 hash、测试清单与计数、schema migration facts、synthetic 正负矩阵、
  敏感扫描、偏差/风险及 installed-HDC/device/network/destructive dispatch `0`。
- Verification:`TEST-INT-UD-HARNESS-ECHO-001` 全部二值断言 PASS;
  `<ARKDECK_PYTHON> scripts/ud_capture/test_capture.py`;
  `ARKDECK_PYTHON=<fixed> scripts/check-sdd.sh`;`git diff --check`;静态 AST no-shell/
  no-network 与 forbidden-path/raw-access 审计。
- Evidence gate:同一 implementation revision 全部验证 PASS 后,以独立 status PR 起草
  `ready→done`;done 生效后另起 CAP-MUT status PR,引用 remediation merged OID/三文件
  hash 与 r4 pins,才可起草 `blocked→ready`。任何一步不得合并实现、done 与 CAP-MUT
  ready-restore。
- PR boundary:r9 只定义 readiness;随后一个独立 implementation + evidence PR、一个
  remediation done status PR、一个 CAP-MUT ready-restore status PR。

## TASK-UD-CAP-MUT-001 — R1-R3 首次 target-build 人工 deviceMutation 采集

- Status:done(TASK-UD-CAP-MUT-001 Phase A evidence PR #248 已由维护者 review/merge
  合入 `main` `79b795b7916c863376b3c1f9c37456b0089283dd`;本独立状态 PR 依据下列
  completion evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。本状态只关闭
  `INT-UD-CAPTURE-MUT-001` 的单一 DAYU200 / OpenHarmony 7.0.0.34 / API 26.0.0 /
  HDC 3.2.0d / USB 人工受控采集 protocol。R1/R2/R3 均保持 `unknownOutput`,不认领
  Recipe success、任何 canonical `AC-DUMP-*`、compatibility/support/conformance/release
  PASS;R4 dispatch 保持 `0`,`TASK-UD-CAP-R4-001` 仍 blocked 并等待独立 approved R2
  structural decision、same-session selector seam 与 R4 readiness)
- Completion evidence:
  `evidence/runs/TASK-UD-CAP-MUT-001/attempt-3-complete-20260721/run.md`、
  `hardware-evidence.json`、`capture-hashes.md` 与 `redacted-manifests/`(evidence ID
  `EVD-UD-CAP-MUT-DAYU200-20260721-003`;25 个 schema `1.1.0` harness invocations 全部
  exit `0`、complete/untruncated/non-drain-incomplete/self-check PASS;共 `51` 个分立
  whole-stream/whole-file origin;同会话 target binding 与每次 explicit `-t` gate 通过;
  R1/R2/R3 各 dispatch `1`,分类均为 `unknownOutput`;R2 在 absent pre-state 后新建 regular
  sidecar,SC-2 接收并扫描 `866256` bytes,SC-3 exact-path 删除且 SC-1 复查 absent;R1/R3
  post-state absent;FX-3/FX-4 teardown 完成;Agent installed-HDC/device/destructive dispatch
  `0/0/0`)。hardware evidence 通过 schema `2.0.0`,其 `26/26` artifact SHA-256 与仓库
  文件一致,repository-sensitive/path scan PASS;claimed operator/physical target 与 run
  叙述真实性由 #248 review/merge attestation 保证。前序
  `attempt-2-reflash-abort-20260721/run.md` 保持 **ABORTED / NOT REUSABLE / NOT PASS**:
  人类刷机使当次 state 失效,没有任何 key/window/artifact 被 attempt 3 复用;exact flash
  command/image digest/time 不可得的偏差与聊天中 transient window id/有限 stdout 摘录的
  privacy deviation 均已如实记录且原值未进入 repository evidence。状态 PR 在 #248
  merged `main` 上复验 evidence validator、artifact hash、敏感扫描、hardware schema、
  harness `63/63`、SDD `0/0/111` 与 `git diff --check` 全部 PASS;本状态 PR 新增 device/
  network/GUI/mutation/destructive/fixture/Recipe dispatch 均为 `0`。
- Objective:由人类维护者按 `capture-runbook.md` Phase A 在 DAYU200 真机上首次执行
  R1-R3 三个 Recipe 的受控采集,记录逐流 byte-exact raw(仓库外)、redacted manifest 与
  hardware evidence,为后续 argv/output-family decision 提供事实输入。
- Change-local closure:`INT-UD-CAPTURE-MUT-001` / `TEST-INT-UD-CAPTURE-MUT-001`。
- Canonical Safety inputs:`REQ-DUMP-002/005/006/007/008`;本 task 不认领其 canonical
  AC/Test PASS,逐项 ownership 见下表。
- Readiness review(2026-07-20;host-only,零 HDC/device dispatch):
  - Change gate:satisfied。r3 裁剪版已经 PR #131 合入 `main`
    `d99ba58`;change 保持 `approved`,采集授权模型=M0B 先例(runbook+人类亲手执行+
    evidence PR attestation)。
  - Fixture gate:satisfied on merge。fixture HAP tuple 固定为:
    - artifact:`entry-default-signed.hap`,SHA-256
      `9453a396e81d55abfb05b4d7f9a512dea139e5843462051a6e1cc3586849fac8`
      (维护者本机 DevEco 构建产物;本地路径不入仓,repo-facing run.md 只记录
      `<local-hap-path>` 占位符并复算 hash);
    - bundleName:`com.example.waterflowdemo`(与 M0B evidence 已知 bundle 一致,
      M0B 曾受控采集其 uninstall);mainElement/ability:`EntryAbility`;
      versionCode `1000000`、compileSdkVersion `26.0.0.25`(与设备 OH 7.0.0.34/API 26
      匹配)、debug 签名(module.json 实测读取);
    - 静态页面内容:WaterFlow 布局样例,合成列表数据,无用户/敏感内容;
    - window 规则:取 `INV-1` 输出中与 fixture bundle/ability 对应的唯一前台窗口的
      `WinId`;零个或多个候选即停。
  - INV-1 gate:satisfied on merge。字面 argv 已固定入 runbook(官方 hidumper 文档
    确认 `-a` 全窗口信息含 `WinId`);首次执行与 Recipe 同等保守分类,其输出在
    decision revision 登记前为 `unknownOutput`,但 `WinId` 字段可按 window 规则读取。
  - Sidecar gate:satisfied on merge。唯一 literal path 已固定入 runbook:
    `/data/app/el2/100/base/com.example.waterflowdemo/haps/entry/files/arkui.dump`
    (官方文档 recv 路径模式;`userId=100` 为设备默认主用户假设——若实际不符,前后
    清单将如实记录 absent/absent,sidecar 不收集、不影响 stdout 采集,该 residual risk
    已披露,不得为此改用全局搜索)。
  - Operator/window gate:操作者=维护者 `lvye`(fuhanfeng)本人;时间窗=本 readiness
    合入后由维护者确认的首个设备窗口,执行前在 run.md 记录实际日期/窗口,窗口内无
    其他设备操作并行(与 RISK-001 检查单第 5 项同型规则)。
  - Environment gate:HDC executable hash/version 按 runbook `HP-0` 在执行时复验
    (pinned 值来自 M0B evidence);hardware-evidence schema 校验工具身份执行时记录。
  - Review boundary:本 readiness PR 只更新本 change 的 tasks/runbook/proposal/
    acceptance metadata 与 verification 头部,不含实现/evidence,不改变其他任务状态,
    不执行任何 HDC/device 命令。
- Depends on:
  - r3 经维护者 review/merge 合入(已满足:PR #131,`main` `d99ba58`);
  - r4 readiness PR 经维护者 review/merge(已满足:PR #132,五项 readiness 输入已批准);
  - `TASK-UD-CAPTURE-HARNESS-001 done`(已满足:#143 implementation、#148 r7
    alignment、#149 done 与 #154 ready-restore 已合入);其历史 merged OID/逐文件 hash
    与 future remediation OID/hash 均须记入本任务 hardware-evidence 的
    `toolchain.other`(先例:M0B evidence 按 hash 引用 `capture.py`);
  - `TASK-UD-HARNESS-ECHO-001 done`(r9 新增);其 implementation merged OID/三文件
    SHA-256 与 schema `1.1.0` completion evidence 必须由独立 CAP-MUT ready-restore
    status PR 引用。#219 failed session/evidence 不复用、不重判,恢复后从 fresh controlled
    session 重新开始 `HP-0`;
  - 物理 DAYU200 在场,人类维护者亲手执行(Agent 零 dispatch)。
- Runbook gates(全文见 `capture-runbook.md`,要点):
  - 全部设备命令与流采集必须经 pinned harness(`scripts/ud_capture/capture.py`)以
    argv 数组执行;禁止 shell 重定向或任何 harness 之外的手工采集(r6);
  - 人工 preflight:`hdc version`/`hdc list targets -v` 输出记录并与 M0B pinned
    hash/version 对照;恰一台预期 DAYU200 Connected,缺失/多台/歧义即停;`HP-2` 在
    `INV-1` 与每个 `Rn` 前各复查一次,漂移即停。不执行任何显式 server lifecycle/
    subserver 命令(与 M0B 同)。(r7:HP-1/HP-2 钉为 verbose 形式——M0B evidence
    证明纯 `list targets` 只输出序列号无状态列,`Connected` 状态仅在 `-v` 输出中,
    r4/r6 的纯形式无法满足自身 stop condition;由 PR #143 对抗审查在任何设备执行前
    发现);
  - connect key 只取自同一会话 `list targets -v` 输出,每条设备命令显式 `-t`,禁止
    默认目标;key/serial 字节不入仓库(redacted manifest 用占位符,serial 只入
    hardware-evidence 的 device identity 字段,先例 M0B);
  - R1-R3 首次 target execution 全部保守分类 `captureRemoteFile/deviceMutation`,无
    stdout-only/readOnly 分支,事后不得降级;
  - `-a` payload 为单数组元素(含空格),禁止 split-token/quoted fallback、fallback
    argv 与重试换边界;
  - exact-path sidecar 前后清单:每个 Recipe 前后对同一 literal path 执行 runbook 固定
    的清单命令并记录输出;pre 必须证明 path 不存在,post 区分新建 regular
    file/预存在/未变/歧义;只回收本次运行证明归属的 exact path,禁止全局搜索、
    wildcard、递归删除、覆盖既有文件;归属不明即保留并记 `needsAttention`;
  - stdout/stderr/sidecar 分立 raw origin,逐流 SHA-256;exit 0 不单独成功,
    `option ... missed` 显式失败,其余输出在 decision revision 登记前一律
    `unknownOutput`(采集完成 ≠ Recipe 成功)。
- Allowed paths(evidence):
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-MUT-001/**`
  - 本 `tasks.md`(仅本任务状态与 completion evidence,独立 status PR)
- Hardware required:yes,human only。
- Required evidence:`run.md`、`redacted-manifests/`(harness 逐命令生成;下一 fresh run
  要求 schema `arkdeck-ud-capture-redacted-1.1.0`,#219 `1.0.0` 只保留为 immutable
  failure evidence;先例 M0B 复数目录)、`capture-hashes.md`(逐流
  SHA-256)、`hardware-evidence.json`(schema 2.0.0,provider none,含 claimed
  operator、physical target/serial、firmware、toolchain、transport、executedAt、本任务
  acceptance ID、actual step kinds 与 artifact hashes)。raw 字节全部留在仓库外
  operator-controlled `0o700` 目录。schema 校验工具的 path/version 在 `run.md` 执行时
  记录(不预钉 hash)。
- Verification:hardware-evidence 过 schema 2.0.0 校验;capture-hashes 与 redacted
  manifest 自洽;敏感自检(key/serial/用户路径不入仓)通过;R1-R3 与 `INV-1` 的每次
  dispatch 均有记录且由人类执行,Agent/destructive dispatch count `0`。claimed operator
  的真实性由维护者对 evidence PR 的 review/merge attestation 保证。
- Forbidden now:任何 implementation、installed HDC、device dispatch、fixture
  install/start、remote inventory/receive/cleanup 或 evidence 起草。
- PR boundary:一个 evidence PR;`blocked→ready` 由 readiness PR、`ready→done` 由独立
  status PR 分别起草。

### Capture task canonical Safety boundary

| Canonical Requirement | Canonical AC / Test | Capture task disposition |
| --- | --- | --- |
| `REQ-DUMP-002` | `AC-DUMP-002-01` / `TEST-AC-DUMP-002-01` | read-only Safety input;window ID 来自 runbook 固定的 inventory 命令记录,但本真机 task 不关闭 `adapterGolden` |
| `REQ-DUMP-005` | `AC-DUMP-005-01` / `TEST-AC-DUMP-005-01` | 强制 stdout/sidecar 分离;仅贡献事实 evidence,不替代 canonical `artifactContract` |
| `REQ-DUMP-006` | `AC-DUMP-006-01` / `TEST-AC-DUMP-006-01` | 强制 owned-only cleanup;不替代 canonical `ownershipCleanupContract` |
| `REQ-DUMP-007` | `AC-DUMP-007-01` / `TEST-AC-DUMP-007-01` | 强制 stale/unknown fail closed;不替代 canonical `sidecarFaultInjection` |
| `REQ-DUMP-008` | `AC-DUMP-008-01` / `TEST-AC-DUMP-008-01` | 仅作 raw/derived/privacy Safety 输入;本 task 不执行 diagnostic export,也不关闭 platform evidence |

## TASK-UD-R2-DECISION-001 — Phase A R2 derived output-family 人工决策

- Status:ready(r10 candidate;仅在维护者 review/merge 本治理/readiness PR 后生效。该
  merge 只授权维护者离线处理已合入 #248 对应的受控 R2 raw,不授权 installed HDC、
  device、fixture、Recipe、network 或 GUI dispatch,也不使 R4 ready)
- Objective:由人类维护者在仓库外对 Phase A attempt-3 的 proven-owned R2 sidecar 运行
  已固定 `uidump-derived-redaction-v1`,逐字审查 derived bytes 与必要的 controlled raw
  structural context,提交 privacy-reviewed derived fixture + receipt/hash 链与 R2
  success/failure/unknown structural-family decision;固定 deterministic component-candidate
  locator/basis,但不复用或提交 Phase A exact token。
- Change-local closure:`INT-UD-R2-DECISION-001` / `TEST-INT-UD-R2-DECISION-001`。
- Canonical Safety inputs:`REQ-DUMP-003/005/008`(component preflight、raw/derived 分离与
  privacy read-only inputs;本 task 不认领任何 canonical AC/Test PASS)。
- Readiness review(2026-07-21;governance-only,Agent raw/HDC/device dispatch `0`):
  - Phase A gate:satisfied。evidence PR #248 合入
    `79b795b7916c863376b3c1f9c37456b0089283dd`,status PR #251 已合入
    `d5aded75d30fbd7ae048005b692b7f4138b23055` 且
    `TASK-UD-CAP-MUT-001 done`;R2 sidecar origin 为 `866256` bytes、SHA-256
    `ec6663e6b7d42053ba089ccbfa89df74cb183a5a583f80a69f103b047014b077`,对应
    repo-safe manifest/ledger 已由 #248 attestation 固定。controlled raw path/bytes 不入仓。
  - Redactor gate:satisfied。`TASK-UD-REDACTOR-001 done`;只允许使用 merged
    `scripts/ui_dump_redaction/` 的固定 algorithm/empty allowlist/receipt schema 与 readiness
    Python。input hash 必须精确等于上项,output/receipt 必须仓库外 exclusive-create。
  - Human/privacy gate:只有维护者可打开 controlled raw 或 derived 作语义判断;Agent raw
    read count 必须为 `0`。derived 在进入 Git 前必须由维护者逐字审读,receipt 的 raw hash、
    derived hash 与 policy hashes 全闭合,repository-sensitive scan 零命中;merge 即 privacy
    与 output-family decision attestation。
  - Negative-decision gate:redactor failure、derived privacy failure、无法固定 repo-safe
    positive structural fixture、zero/multiple candidate locator 或任何歧义,均可形成 truthful
    negative decision 并使本 task done,但 `TASK-UD-R2-R4-SEAM-001` 与 R4 保持 blocked。
- In scope:
  1. 用固定 CLI 将上述 R2 sidecar 转为 deterministic derived + redaction receipt;raw 只读、
     不覆盖,稳定错误只记录 error name/code,不把 raw/path/literal 写入 stdout/evidence;
  2. 提交经维护者逐字审读的 repo-safe derived fixture、receipt 与 `run.md`,复核
     raw-manifest→receipt→derived bytes 的 SHA-256 链、line/token/replacement 统计和敏感
     扫描;
  3. 新增 `decisions/r2-element-tree-v1.{md,json}`:登记 exact approved R2 argv、target tuple、
     raw-origin hash、derived/receipt hash、success structural family、既有
     `option ... missed` failure precedence 与 otherwise-unknown rule;禁止 exit-0/digest-only
     success;
  4. decision 只记录 derived placeholder locator/basis、candidate cardinality/format 与
     same-session selection requirement。Phase A exact token 不记录、不复用;future R4 exact
     token 由每次 Phase B selector 从 fresh same-session R2 raw 私下 materialize。
- Out of scope:修改 redactor/capture harness/Swift/Core/spec/contracts;实现 selector 或 R4;
  读取 #219/attempt-2 raw;Agent 打开/复制任何 controlled raw;提交 raw、raw 片段、页面文本、
  window/component literal、private token/nonce/bundle;HDC/device/network/GUI dispatch。
- Allowed paths:
  - `.gitattributes`(仅在提交 reviewed derived fixture 前登记 byte-exact pattern)
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/decisions/r2-element-tree-v1.md`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/decisions/r2-element-tree-v1.json`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-R2-DECISION-001/**`
  - 本 `tasks.md`(仅该 task 的独立 status/completion evidence 更新)
- Read-only inputs:`attempt-3-complete-20260721/{run.md,capture-hashes.md,
  hardware-evidence.json,redacted-manifests/14-R2.redacted-manifest.json,
  redacted-manifests/16-SC-2.redacted-manifest.json}`、对应仓库外 controlled R2 sidecar、
  `scripts/ui_dump_redaction/**`、本 runbook 与 official source routing hints。
- Risk:high(人类读取真实 UI raw 并登记新 output-family/selection semantics;必须以 reviewed
  derived positive fixture、receipt hash 链、zero/multiple fail-closed 与独立 status PR 收口)。
- Hardware required:no new hardware;只处理既有 human realHardware raw。Agent/raw/HDC/device/
  network/destructive dispatch `0`。
- Required environment:固定 Python 3.14.6 + PyYAML 6.0.3;不得联网安装或默认回落。
- Verification:`TEST-INT-UD-R2-DECISION-001`:redactor receipt/schema/hash chain、derived
  byte parity、repository-sensitive scan、decision JSON closed-key/required-field validation、
  positive structural fixture与 failure/unknown precedence、candidate cardinality/locator review
  全部二值 PASS;
  `scripts/check-sdd.sh`;`git diff --check`。机器测试不得打开 raw;raw/derived 对照与
  claimed semantic role 由维护者 review/merge attest。
- Evidence gate:evidence+decision PR 合入后另起 status PR 起草 `ready→done`;只有 positive
  decision done 才可为 `TASK-UD-R2-R4-SEAM-001` 起草独立 readiness,negative/ambiguous
  decision 永久保持后续 blocked。
- PR boundary:一个 human evidence + decision PR;`ready→done` 独立状态 PR;不得夹带
  selector/harness 实现或 R4 readiness。

## TASK-UD-R2-R4-SEAM-001 — same-session private selector + R4 harness seam

- Status:blocked(等待 `TASK-UD-R2-DECISION-001` positive done 与独立 readiness PR;当前
  `scripts/ud_capture/` closed allowlist 明确不含 R4,不得提前修改或 dispatch)
- Objective:依 approved R2 decision 实现 stdlib-only host selector 与 capture-harness R4
  typed seam:从每次 Phase B fresh R2 raw 产生 repository-external private selection bundle,
  再由 harness 通过 path + expected SHA-256 的 typed reference 验证 decision/session/
  raw-origin/bundle binding 并内部 materialize exact component token;repo-facing evidence
  不含 token/nonce。
- Change-local closure:`INT-UD-R2-R4-SEAM-001` / `TEST-INT-UD-R2-R4-SEAM-001`。
- Depends on:
  - `TASK-UD-R2-DECISION-001 positive done`与 merged decision OID/hash;
  - 独立 readiness PR 固定 implementation base、closed files/schema、token format、bundle/
    receipt字段与 Phase B exact host CLI;在该 PR 合入前本 task 不可执行。
- Required implementation boundary(candidate;仅 future readiness 合入后生效):
  1. `scripts/ui_dump_component_selection/` closed parser读取 approved decision manifest与
     fresh R2 raw,要求 raw hash 与同会话 capture manifest 一致,并按 approved structural
     family/locator 得到 exactly-one candidate;不得要求 fresh raw hash 等于 Phase A raw hash,
     也不得把 digest 当 success family。zero/multiple/family mismatch/truncation/invalid token
     全部 nonzero 且不产出 bundle;
  2. private bundle 在 controlled root exclusive-create `0o600`,含 exact token、256-bit random
     nonce、decision id、raw hash、window/session binding;bundle 永不入仓、不打印、不进入
     redacted manifest。repo-safe receipt 只含 locator/cardinality、fresh raw hash、decision
     derived-fixture/receipt hash、bundle SHA-256、validation booleans 与占位符,不含 token/
     nonce;
  3. `scripts/ud_capture/` 增加 R4 closed command,只接受 typed private-bundle reference(path +
     expected SHA-256);harness no-follow 读取并验证 mode/schema/content hash/session/decision/
     fresh raw-origin/token format后在内存中 materialize one-element `-a` payload。CLI/env/
     manual component token与任意普通文件输入继续拒绝;
  4. synthetic/adversarial tests 覆盖 valid bundle、zero/multiple、stale Phase A token、wrong
     decision/raw/window/session、tamper/symlink/mode/path、token injection、stdout/stderr/
     manifest leak、timeout/truncation 与零 HDC/network/process dispatch。
- Candidate allowed paths(future readiness 必须逐一固定):
  - `scripts/ui_dump_component_selection/{README.md,select.py,test_select.py,
    selection-bundle.schema.json,selection-receipt.schema.json}`
  - `scripts/ud_capture/{README.md,capture.py,test_capture.py}`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-R2-R4-SEAM-001/**`
  - 本 `tasks.md`(仅该 task 状态/completion evidence)
- Forbidden now:任何实现/fixture/evidence、读取真实 raw、HDC/device/network/GUI、R2/R4
  dispatch、exact token/nonce/bundle 入仓、放宽 raw digest family或 repo-sensitive gate。
- Hardware required:no;future implementation/tests synthetic-only,installed-HDC/device/network/
  destructive dispatch `0`。
- Verification(candidate):decision-manifest parser contract、bundle/receipt closed-schema +
  deterministic serialization、OS randomness/permission/path gates、same-session binding、R4 exact
  argv equality与 all-negative zero request/dispatch,existing 63 harness tests不回归;
  `scripts/check-sdd.sh`;`git diff --check`;AST no-shell/no-network audit。
- PR boundary:positive decision done 后独立 readiness PR;一个 implementation+evidence PR;
  一个 `ready→done` status PR;随后另起 `TASK-UD-CAP-R4-001 blocked→ready` PR。任何 PR
  不得合并相邻阶段。

## TASK-UD-CAP-R4-001 — R4 componentDetail 后置人工 deviceMutation 采集

- Status:blocked(`R4` dispatch count 必须为 `0`;Phase A token 不可跨 fixture/window 生命周期
  复用,十进制格式或 hash 不构成 component provenance)
- Change-local closure:`INT-UD-CAPTURE-R4-001` / `TEST-INT-UD-CAPTURE-R4-001`。
- Canonical Safety inputs:`REQ-DUMP-003/005/006/007/008`(`AC-DUMP-003-01` 仍由
  `TASK-UD-001` 的 canonical contract test 关闭;其余 disposition 同上表;本 task 不认领
  任何 canonical PASS)。
- Depends on:
  - `TASK-UD-CAP-MUT-001 done`;
  - `TASK-UD-R2-DECISION-001 positive done`:登记 R2 success/failure/unknown structural
    family与 deterministic candidate locator/basis,附 privacy-reviewed derived positive fixture
    和 Phase A R2 raw-origin hash;不登记/复用 Phase A exact token;
  - `TASK-UD-R2-R4-SEAM-001 done`:pinned selector + capture harness 能在 fresh Phase B 同一
    fixture/window 生命周期内执行 R2、生成 private bundle并验证后 materialize R4 token;
  - `TASK-UD-CAPTURE-HARNESS-001 done`(r6 新增;R4 同样只经 pinned harness 执行,
    OID/hash 引用规则同 Phase A);
  - 独立 readiness PR(继承 Phase A fixture/清单/窗口要求,固定 Phase B exact sequence与
    selector/bundle hashes;`COMPONENT_ID` 只取自 validated private bundle,禁止 CLI/env/
    普通 file/现场手输)。
- Runbook gates:同 Phase A 的 harness/preflight/connect-key/保守分类/exact-path 清单/
  分立 raw origin/结果判定规则;Phase B 在同一 session/window 中先 fresh R2 + owned-sidecar
  receive/cleanup,再 host selector,再 HP-2 与 R4;R4 payload 为单数组元素。R2 到 R4 之间
  禁止 UI state mutation、fixture restart/reinstall或其他非 runbook device command。
- Allowed paths(evidence):
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-CAP-R4-001/**`
  - 本 `tasks.md`(仅本任务状态与 completion evidence,独立 status PR)
- Hardware required:yes,human only。
- Required evidence:同 Phase A(`run.md`、`redacted-manifests/`、`capture-hashes.md`、
  `hardware-evidence.json`),另附 decision/seam merged OID/hash、fresh R2 raw hash、repo-safe
  selection receipt与 private bundle SHA-256;exact token/nonce/bundle bytes不入仓。
- Forbidden now:component 选择、selector/bundle、Phase B R2/R4 capture/evidence、复用 Phase A
  token、manual/CLI/env/普通 file component ID、installed HDC/device dispatch。
- PR boundary:同 Phase A。

## TASK-UD-REDACTOR-001 — deterministic derived-golden redactor 前置

- Status:done(TASK-UD-REDACTOR-001 implementation + evidence PR #144 已由维护者
  review/merge 合入 `main`(squash `3019e8e`);本独立状态 PR 依据下列 completion
  evidence 起草 `ready→done`,仅在维护者 review/merge 后生效。本状态只关闭 redactor
  的 host-only synthetic contract evidence,不改变 TASK-UD-001(blocked;其 ready
  前置之一由本 done 满足,其余前置不变)、CAP-MUT/CAP-R4、change approved、canonical
  platform(`AC-DUMP-008-01` 不被认领)、hardware/support/release 状态;
  `safe-literals-v1.txt` 保持空 allowlist,任何未来保留字仍须在实现 PR review 中逐项
  维护者批准)
- Completion evidence:`evidence/runs/TASK-UD-REDACTOR-001/run.md` 与
  `review-remediation-2026-07-20.md`(merged squash `3019e8e`;remediation 表六文件
  SHA-256 与 `main` 逐一相符——redact.py `938cc117…`、test_redact.py `0543f70e…`、
  algorithm-v1.json `a75778fd…`、safe-literals-v1.txt `e3b0c44…`(空)、receipt
  schema `f4bffe70…`、README `18befd7c…`;合前两项建议均已纳入合入版:
  `allow_abbrev=False` 与 run.md SUPERSEDED 标注,第 21 个测试即前者的回归;零真实
  raw/HDC/device/network dispatch)。状态 PR 复核(2026-07-20,当前 `main`
  `ba4b75b`):21 tests/0 failures 与六文件 hash 相符均复现——该复核只确认 evidence
  在现基线可复现,不构成新的 acceptance 结论。
- Objective:在 `TASK-UD-001` ready 前,以独立 host-only task 实现并固定 fail-closed
  `uidump-derived-redaction-v1`:确定性 transform 把受控 raw 转为可入仓 derived bytes,
  并产出记录完整 hash 链的 redaction receipt;golden 实现 PR 不能决定保留哪些 UI 文本。
- Change-local closure:`INT-UD-REDACTOR-001` / `TEST-INT-UD-REDACTOR-001`。
- Canonical Safety input:`REQ-DUMP-008` → `AC-DUMP-008-01` → `TEST-AC-DUMP-008-01`;本
  task 不执行 diagnostic export、不认领 canonical platform PASS,只对 derived-golden 输入
  加严隐私边界。
- Readiness review(2026-07-20;host-only,零 HDC/device/network dispatch,零真实 raw):
  - Change gate:satisfied。CHG-008 保持 `approved`;r3 裁剪版(#131)与 r4 CAP-MUT
    readiness(#132)均已合入;本 r5 只固定本任务实现范围/base 并翻转状态,不修改任务
    契约、AC/method/minimum evidence 或其他任务。
  - Dependency gate:satisfied。本任务无采集前置——synthetic-only,可与 Phase A 并行;
    与 `TASK-UD-001` 的关系是前者的 done 是后者 ready 的前置,方向不反转。
  - Scope/base gate:satisfied on merge。实现 base 固定为本 readiness 合入后的 `main`
    HEAD(实现 PR 在 run.md 记录实际 base OID 与逐文件 SHA-256,不预钉);实现范围
    严格等于 Allowed paths 所列 6 个 `scripts/ui_dump_redaction/` 文件 + evidence +
    本 tasks.md 状态行;stdlib-only(不引入第三方依赖、不联网安装,receipt 的 schema
    校验用自带验证器,先例 `scripts/archive_characterization/` 封闭 schema+自带验证器
    与 `scripts/m0b_capture/capture.py`);零 Swift/`Package.swift`/product 变更。
  - Environment gate:satisfied。`<ARKDECK_ROOT>/.venv-sdd/bin/python` 实测 Python
    `3.14.6`、PyYAML `6.0.3`(2026-07-20 于 `main` `08b01dd`);实现/测试仅需该
    interpreter、stdlib 与本地临时目录,执行时在 run.md 记录实际 path/version/hash。
  - Path/concurrency gate:satisfied。`scripts/ui_dump_redaction/` 在 `main` 与全部
    open PR(当前 0 个)中均不存在,无会话占用;不触碰 `scripts/m0b_capture/`、
    `scripts/partition_decode/`(只读先例参考)或任何 Swift/治理路径。
  - Review boundary:本 readiness PR 只更新本 `tasks.md` 的该任务状态与 readiness
    记录及 change revision metadata;`safe-literals-v1.txt` 的每个保留字仍按任务契约在
    实现 PR 的维护者 review 中逐项批准,本 PR 不预先选择任何 literal;synthetic 测试
    永不冒充 raw capture 或人工 privacy review。
- Blocking dependencies/gates:
  - 独立 readiness revision 固定实现范围与 base(即本 r5 readiness PR;完成时在
    evidence 记录 source commit OID 与逐文件 SHA-256,执行时记录、不预钉);
  - transform CLI 形态:
    `<ARKDECK_PYTHON> scripts/ui_dump_redaction/redact.py --algorithm-manifest scripts/ui_dump_redaction/algorithm-v1.json --safe-literals scripts/ui_dump_redaction/safe-literals-v1.txt --input <CONTROLLED_RAW_PATH> --expected-input-sha256 <RAW_SHA256> --output <DERIVED_PATH> --receipt <RECEIPT_PATH>`;
    data path 只能是 token,不接受 stdin/raw bytes/network;input 的实测 SHA-256 必须
    等于 `--expected-input-sha256`(即 capture manifest 中的 raw whole-stream hash),
    否则拒绝;output/receipt 必须事先不存在,创建后不得覆盖;
  - algorithm manifest 逐字固定 strict UTF-8、line-ending normalization、token/line
    grammar、typed ordinal placeholder 格式、ordering、escaping、duplicate 处理、resource
    limits 与错误码;未知/invalid UTF-8/control/bidi/confusable/未分类 token 或 line 必须
    fail closed,不得透传;
  - `safe-literals-v1.txt` 每个保留字在本 task 的维护者 review 中逐项批准,只允许结构
    语法;package/ability/page/window/component/path、用户/设备标识与任意页面文本不得
    通过 pattern、prefix、fallback 或"看似无害"启发式进入 allowlist;
  - redaction receipt(`redaction-receipt.schema.json`)记录:algorithm/manifest/
    allowlist hash、raw SHA-256/size、derived SHA-256/size、replacement counts、replay
    命令行与 completedAt;receipt 与 derived 均先落在仓库外,由 `TASK-UD-001` 的 golden
    PR 一并提交并接受维护者逐字审读;
  - 输出侧敏感终检:transform 完成后对 derived 做敏感字面量扫描(serial/key/用户路径/
    非 allowlist 文本),命中即硬失败不产出(先例 `scripts/m0b_capture/capture.py` 的
    输出侧终检门);raw 只读打开,任何路径不得修改/覆盖 raw;
  - offline adversarial/property tests 只用 synthetic bytes,至少覆盖:invalid
    UTF-8、CRLF/CR、NUL/control/bidi/confusable、Unicode normalization、
    package/ability/path/serial/window/component/长数字/页面文本、未知 token/line、
    overlong input、ordering/duplicate、allowlist/manifest/input hash drift、
    output=input/receipt=input 路径冲突、重复运行的 byte-determinism 与零敏感字面量
    搜索;任何 unclassified/unsafe input 必须 nonzero 且不覆盖 raw、不产出可提交
    derived。
- Allowed paths(仅在 readiness revision 合入后生效):
  - `scripts/ui_dump_redaction/README.md`
  - `scripts/ui_dump_redaction/redact.py`
  - `scripts/ui_dump_redaction/test_redact.py`
  - `scripts/ui_dump_redaction/algorithm-v1.json`
  - `scripts/ui_dump_redaction/safe-literals-v1.txt`
  - `scripts/ui_dump_redaction/redaction-receipt.schema.json`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-REDACTOR-001/**`
  - 本 `tasks.md`(仅该 task 的独立 status/evidence 更新)
- Read-only inputs:`openspec/specs/ui-dump/spec.md`、本 change 的 privacy boundary、
  `scripts/m0b_capture/**`(先例);不读取真实 capture raw。
- Hardware required:no;installed HDC、device/network dispatch 与真实 UI raw input 均为
  `0`。
- Required environment:与 SDD guard 相同的固定 Python
  (`<ARKDECK_ROOT>/.venv-sdd/bin/python`,Python 3.14.6 + PyYAML 6.0.3);执行时在
  run.md 记录实际 path/version/hash。
- Required evidence:`run.md` 记录 source/manifest/allowlist/schema/test hashes、exact
  CLI、synthetic transform chain hashes、negative outcomes、deterministic replay hash 与
  敏感字面量审计;不得声称 synthetic tests 是 raw capture、人工 privacy review 或
  canonical `AC-DUMP-008-01` PASS。
- Forbidden now:创建/修改上述实现文件、选择 safe literals、读取/复制真实 raw、生成
  derived golden、起草 PASS/done。

## TASK-UD-001 — 固定 HiDumper 调用包装 + golden 登记 + 对抗测试

- Status:blocked(r3 review-remediation candidate;仅在本治理 PR 由维护者 review/merge
  后生效。本 PR 不执行 TASK-UD-001,不产生 implementation/acceptance evidence,也不使
  CHG-008 verified)
- Blocking review(2026-07-19 初判,2026-07-20 裁剪后复核;只读审计,零真实 HDC/device
  dispatch):
  - Capture/decision blocker:`EVD-M0B-DAYU200-20260718-001` 只含 `hidumper --help` 与
    `hidumper -ls`,没有任一 Recipe 成功输出;official source 只能作 routing hint,不能
    证明目标 build output mode。在 `TASK-UD-CAP-MUT-001`/`TASK-UD-CAP-R4-001` 与后续
    decision revision 完成前,不存在可批准的 argv/success family;执行者不得自行发明
    argv、marker 或用自造 fake/golden 自证通过;
  - Core-trace blocker(已在 r3 关闭定义):`REQ-DUMP-003` / `AC-DUMP-003-01` /
    `TEST-AC-DUMP-003-01` 必须由本任务闭环——缺失、空值、非法格式及参数/shell
    injection 形状的 component ID 必须在 argv/`ProcessRequest` materialization 前失败,
    request 与 dispatch counter 均为 `0`;
  - Consumer-dependency:r2 未按 CHG-2026-014 规则提供逐 deliverable 表,r3 在下表补齐;
    结论全部为"不需要 M1-006 source AC",但 R2 decision/seam、R4 capture/output-family
    未完成前每项仍
    `remains blocked`;
  - SDD-environment gate:执行前必须以 `<ARKDECK_ROOT>/.venv-sdd/bin/python`(Python
    3.14.6 + PyYAML 6.0.3)preflight `import yaml` 并设 `ARKDECK_PYTHON` 运行 guard;
    实际 interpreter path/version/hash 在 run.md 执行时记录。缺 `yaml` 的默认 `python3`
    与联网安装均不可用;
  - Draft disposition:PR #126 的 argv/marker/fixture 与 PASS evidence 建立在未批准的
    假设上,不属于本 task acceptance evidence,只作为不可合并 draft 审计记录保留。

### CHG-2026-014 consumer dependency review

| Consumer deliverable | 使用的 consolidated interface | 是否需要 source AC | 结论 |
| --- | --- | --- | --- |
| typed Recipe、window/component token validator 与 argv materializer | 纯 ArkDeckOpenHarmony typed value;不调用 M1-006 probe/lifecycle/authorization | no | remains blocked:Phase A 已完成,但 R2 decision/seam 与 R4 capture 尚未完成 |
| success/failure/unknown semantic evaluator | `ArkDeckProcess.ProcessOutputChunk`、`ProcessExecutionResult`、`ProcessSemanticEvaluating`、`ProcessSemanticResult` | no | remains blocked:四 Recipe output family/marker 未登记 |
| Process/HDC preflight-to-request seam 与零 launch 证明 | `ArkDeckProcess.ProcessRequest` recording factory/dispatch counter;明确不使用 `HDCProduction`、`HDCProcessCommandRunner` 或真实 child | no | remains blocked:Core negative matrix 尚未在获批实现 revision 二值执行 |
| derived golden fixture 与 SwiftPM resource contract | `Bundle.module` resource seam;不消费 M1-006 source behavior/evidence | no | remains blocked:R4 capture + output-family decision + redaction receipt 链尚未闭环 |
| OpenHarmony profile / Integration lock 登记 | integration registry/schema;不消费 M1-006 source AC | no | remains blocked:R4 argv seam 与四 Recipe output-family decision 尚未闭环 |

所有 `no` 仅表示该 deliverable 不需要 M1-006 source AC,不等于当前可执行。两个人工采集
task 按 M0B 先例由人类直接使用 installed `hdc`,同样不消费 M1-006 source AC/evidence;
`TASK-M1-006` 保持 `blocked`/非 `done`,本 change 不重判其任何 evidence。

### Requirement → AC → Test trace

| Requirement/source | Acceptance | Canonical Test ID / method | TASK-UD-001 closure |
| --- | --- | --- | --- |
| `REQ-DUMP-003` | `AC-DUMP-003-01` | `TEST-AC-DUMP-003-01` / `recipeSchemaContract` | 缺失、空、非法、注入型 component ID;零 argv/request/dispatch |
| CHG-008 wrapper integration | `INT-UD-WRAPPER-001` | `TEST-INT-UD-WRAPPER-001` / adversarial contract | 获批 argv exact equality;仅登记 family 可成功;exit-0/unknown fail closed |
| CHG-008 golden registration | `INT-UD-GOLDEN-001` | `TEST-INT-UD-GOLDEN-001` / golden registration | capture raw hash → redaction receipt → derived bytes 逐级 hash 一致;profile/lock/resource 一致;repo 无敏感字面量 |

- Objective:仅在两个人工采集 task 与后续 decision revision 固定精确 argv/output family
  后,实现四个 canonical ArkUI Recipe wrapper、Core component ID preflight、derived
  golden 登记与 fake/adversarial contract tests。
- Requirements/AC:`REQ-DUMP-003` / `AC-DUMP-003-01`,以及 change-local
  `INT-UD-WRAPPER-001`、`INT-UD-GOLDEN-001`。
- Unblock prerequisites(全部满足后另起 readiness revision,不能由实现 PR 顺带改写):
  - `TASK-UD-CAP-MUT-001 done` 与 `TASK-UD-CAP-R4-001 done`:四个 Recipe 各有真实
    target-build 输出记录;若某 Recipe 在目标 build 无法成功,平台结论必须如实为
    blocked/nonConformant,不得由 fake 补齐;
  - 后续 approved decision revision 逐 Recipe 固定精确 argv 与 success/failure/unknown
    family;只允许可由 repo-safe synthetic/derived fixture 正向覆盖的文本 marker 或结构
    parser family,raw byte-fingerprint/digest family 明确 unsupported(若未来需要,另起
    approved change 先固定 privacy-safe、复用 production stream→digest 路径的
    conformance seam);
  - `TASK-UD-REDACTOR-001 done`:redaction toolchain 与 receipt schema 已合入;每个拟入
    仓 golden 均有 redaction receipt(raw hash 与 capture manifest 一致、derived hash 与
    拟提交 bytes 一致);本任务只读消费该 toolchain,不得修改;
  - derived bytes 的隐私复核由维护者在 golden PR 中逐字审读完成——merge 即构成
    privacy review attestation(先例 M0B evidence PR;attestation 载体是 PR review 本身);
  - `TASK-RLC-001 done` + CHG-2026-014 verified 继续只作为 package bytes/interfaces
    provenance;上表经 readiness revision 复核仍无 `yes`;
  - SDD interpreter preflight 通过;r3 与 readiness revision 均经维护者 review/merge;
  - Agent 不得执行真实 `hdc`/device capture,也不得以公开文档、simulation 或 fake 代替
    human target-build evidence。
- Allowed paths:
  - `.gitattributes`(仅新增 HiDumper golden binary/byte-exact pattern;fixture 提交前
    固定,先例 I5-001)
  - `Packages/ArkDeckKit/Package.swift`(仅为 ArkDeckContractTests 登记 HiDumper Golden
    `.copy` resource tree,不改变 product/dependency)
  - `Packages/ArkDeckKit/Sources/ArkDeckOpenHarmony/HiDumperWrapper.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperWrapperContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/HiDumperGoldenResourceContractTests.swift`
  - `Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/HiDumper/Golden/1.0.0/**`
  - `openspec/integrations/openharmony/profile.md`
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/evidence/runs/TASK-UD-001/**`
  - `openspec/changes/chg-2026-008-ui-dump-hidumper-wrapper/tasks.md`(仅 TASK-UD-001
    状态与 completion evidence)
- Read-only inputs:
  - `openspec/specs/ui-dump/spec.md`
  - `openspec/contracts/catalogs/dump-recipes.yaml`
  - 本 change `capture-runbook.md` 与两个采集 task 的已合入 repo-safe evidence
  - `openspec/changes/chg-2026-006-dayu200-m0b-bringup/evidence/runs/TASK-M0B-001/**`
  - `openspec/changes/chg-2026-014-remote-lock-legacy-consolidation/**`
    （2026-07-21 archive currency note:该 change 已 verified 后归档,目录现位于
    `openspec/changes/archive/2026-07-21-chg-2026-014-remote-lock-legacy-consolidation/**`;
    本行原文按惯例保留,引用按新路径解读,字节以 git 历史为证）
  - `scripts/ui_dump_redaction/**`(只读消费;修改属 TASK-UD-REDACTOR-001)
  - decision revision 合入的 reviewed derived fixture/receipt 与后续 R4 evidence(golden PR
    输入;仓库外 raw path/bytes 对本 task 不可达)
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/contracts/**`、
    `openspec/baselines/**`、`openspec/platforms/**`、hardware matrix
  - TASK-M1-006 源码/任务/evidence 与其他 change/task evidence
  - `scripts/ui_dump_redaction/**` 的任何修改
  - 任何真实 raw path/bytes
  - 上述 Allowed paths 以外的 App/Package source、tests、fixtures 或 integration inputs
  - 已安装真实 `hdc`、真实设备、capture/collector、非 loopback 网络、GUI/系统授权、
    device mutation/destructive dispatch
- Risk:medium(固定新的 argv/output-family 语义并导入 derived fixture;必须以 redaction
  receipt hash 链 + 维护者逐字审读闭环隐私,以 fake 对抗测试覆盖 exit-0 陷阱)。
- Hardware required:no。真机输入只来自两个具名前置 realHardware task 的已合入
  evidence;本实现/contract verification 必须 headless、无设备。
- Required environment:锁屏 macOS headless shell;Swift 6.3.3、`xcrun swift-format`
  6.3.0、SwiftPM;固定 Python `<ARKDECK_ROOT>/.venv-sdd/bin/python`(Python 3.14.6 +
  PyYAML 6.0.3),执行时在 run.md 记录实际 path/version/hash 并设 `ARKDECK_PYTHON`。
  不得联网下载、启动 GUI/真实 HDC/真实设备或取得新系统授权。
- Deliverables:
  - 四个 Recipe 的 approved fixed typed argv composition;window/component ID 只作为已
    验证 token 插入,不接受 shell/free-form text;componentDetail 的缺失/空/非法/注入
    输入在产生 argv/`ProcessRequest` 前失败,recording request/dispatch count 均为 `0`;
  - 只依 approved decision revision 登记的 output family 做 success/failure/
    unknownOutput classification;exit code 0 不能单独成功,`option ... missed` 明确
    失败,未登记/marker 缺失 fail closed;实现者不得新增自己的 success marker;
  - byte-exact **derived** HiDumper golden pack(附逐 fixture redaction receipt)、
    registry/hash/provenance、`.gitattributes` 与 Bundle.module resource contract;raw
    永不入仓且本 task 不读取 raw;
  - OpenHarmony profile 与 Integration lock 版本化、一致登记;未登记 family 保持
    unknown/unsupported;
  - fake/adversarial tests 与 `evidence/runs/TASK-UD-001/run.md`,记录 base revision、
    输入/输出 hash、命令、二值 AC、偏差/风险及真实 HDC/device dispatch count `0`。
- Verification:
  - `TEST-AC-DUMP-003-01`:componentDetail 的 missing、empty、非法字符/格式、leading
    option、whitespace/newline、shell metacharacter 与 argument-injection cases 全部
    preflight failure;argv/request materialization count `0`,recording dispatch count
    `0`;合法 token positive control 只证明能 materialize,不启动真实 HDC;
  - `TEST-INT-UD-WRAPPER-001`:四 Recipe 对 approved decision 的 argv exact equality;
    每个已登记文本 marker/结构 parser success/failure/unknown family 均由 repo-safe
    synthetic/derived fixture 通过 exact production semantic-evaluator path 正向覆盖;
    raw byte-fingerprint/digest registration 被拒绝;exit-0 trap、marker absence、chunk
    boundary、stdout/stderr precedence 与无 shell composition 的 fake/adversarial
    branches 全覆盖;
  - `TEST-INT-UD-GOLDEN-001`:每个入仓 golden 的 bytes SHA-256 等于其 redaction receipt
    的 derived hash,receipt 的 raw hash 等于对应 capture manifest 的 whole-stream
    hash,algorithm/manifest/allowlist hash 与 TASK-UD-REDACTOR-001 evidence 一致;
    fixture 树、registry、profile/lock 与 Bundle.module path/hash 一致;仓库 fixture 经
    敏感字面量扫描零命中;receipt 缺失、hash 断链、未审读 derived 一律 fail;
  - Commands:`xcrun swift-format lint` 变更 Swift 文件;
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperWrapperContractTests`;
    `swift test --package-path Packages/ArkDeckKit --filter HiDumperGoldenResourceContractTests`;
    `swift test --package-path Packages/ArkDeckKit`;SDD interpreter preflight 后以
    `ARKDECK_PYTHON` 运行 `scripts/check-sdd.sh`;`git diff --check`;fixture SHA-256 与
    禁止 dispatch 静态审计;
  - Core Test ID 与两个 change-local Test ID 均有同一 implementation revision 的可复查
    PASS evidence 才能起草 `done`;不构成 M1-006、HDC compatibility、platform
    conformance、hardware、support 或 release claim。
- PR boundary:一个独立 TASK-UD-001 implementation + evidence PR;`blocked→ready` 由
  readiness revision、`ready→done` 由独立 status PR 分别起草,不得混入其他任务。

## 裁剪任务记录(r3,2026-07-20)

下列 r3 初稿任务经维护者裁剪决定移除,其必要内容去向如下;完整初稿文本见本 PR 提交
历史(`a613b76`):

| 初稿任务/前置 | 处置 | 必要内容去向 |
| --- | --- | --- |
| `TASK-UD-PREFLIGHT-001`(production supervisor/binding 前置) | 移除 | 人工 preflight 步骤并入 `capture-runbook.md`(hdc version/list targets 记录、恰一设备、批次前复查);production 栈依赖整体取消 |
| `TASK-UD-HWE-SEM-001`(离线 8-receipt semantic verifier) | 移除 | hardware evidence 校验 = schema 2.0.0 校验(工具身份执行时记录)+ 维护者对 evidence PR 的 review;未来如需自动一致性检查,可作非 gate 辅助脚本另行立项 |
| `TASK-UD-PRIVACY-REVIEW-001`(独立两 receipt 人工复核 task) | 移除 | 人工 privacy review 并入 TASK-UD-001 golden PR 的维护者逐字审读(merge = attestation);hash 链由 redaction receipt 承载 |
| external Core MAJOR(`TASK-JAUTH-CORE-001`/CORE-3.0.0) | 不作为前置 | 记入 `openspec/planning/backlog.md` 候选项;人工采集授权按 M0B 模型 |
| registered sidecar inventory typed operation(独立 contract change) | 不作为前置 | runbook 固定 literal path 前后清单命令并记录;typed operation 留给未来产品化 capture change |
| versioned typed component-tree extractor | r3 时不作为前置;r10 重新拆分 | decision 只登记 structural locator;future seam selector 从 fresh same-session R2 私下选 token并通过 typed bundle reference 交给 R4 |
