# TASK-AIN-011 readiness audit r1 — blocked on E0 integration provenance/scope

## Classification

- Date:2026-07-29.
- Audit base:`205cfadcd296db7ec2fdc3f62d09e5047e5e5fa7`（PR #761 merge；
  TASK-HSO-002 done）。
- Method:host-only dependency、current/change-local contract、integration authority、
  production source、fixture/resource 与 Allowed-path audit。
- Result:**blocked**。本记录与 r5 scope proposal 不使 TASK-AIN-010P/011 ready，
  不登记 OpenHarmony command family，不产生 capability/authorization/support 或
  hardware evidence。
- Installed-HDC/process/server-lifecycle/device/network/remote-write/deviceMutation/
  destructive dispatch:`0 / 0 / 0 / 0 / 0 / 0 / 0 / 0`。

## Dependency and collision audit

- TASK-AIN-010 implementation PR #758 exact head
  `10dafe8d478fb5b3da63c2bb80554bbb35fa4841` 经维护者 `lvye` APPROVED，
  以 `7a81662070d5dc9361152a7996ffbd96af73c83f` 合入；独立 done PR #759
  exact head `323347590e615904c3e5ecd4251ab8ef9cfaa113` 同样经 `lvye`
  APPROVED，以 `b64fa942aafff6389bc32c9615f33be1ed7ca833` 合入。AIN-011 原始
  declared dependency 已满足，但不自动建立其 readiness。
- CHG-2026-043 TASK-HSO-002 implementation PR #760 exact head
  `e0f4b908eb6454e384b85a24fd598ed994126fb1` 经 `lvye` APPROVED，以 audit
  base 的父提交 `41e19225375ca65551d51251326169558c4e6980` 合入；独立 done
  PR #761 exact head `93d2fdeafb87fcb9cf068a3fe68c5bc66309b979` 同样经
  `lvye` APPROVED，并以 audit base 合入。exact 3.2.0f production commandless
  server observation 依赖已完成，但不登记任何 device command。
- audit 时唯一 open PR 是 #762（CHG-2026-043 verification-only，head
  `60cac06c995345abf036079a7492c0770d4109e3`）；它不修改本 change、
  integration profile/lock/registry、Packages source 或 AIN-011 inputs/outputs。
- AIN-011 声明的新 `AgentReadOnlyOperations/**`、`AgentDeviceOperations/E0/**`
  与 task-local test 尚不存在，无 new-file collision。现有 FakeHDC fixture 只有既有
  HDC server/device family，不含 registered HiLog/HiDumper/current-Trace family。

## Pinned observations

| Input | Git blob OID | Observation |
| --- | --- | --- |
| AIN-011 base `tasks.md` | `5ce9669ca3269de26dd67ddd80aae5cd7556753f` | 6 个 Allowed-path patterns；漏列本 change tasks status path |
| current hardware evidence V2 | `98443833b5bef36f4a1e0fdea9dbaaccf057f4d1` | schema 2.0.0 要求 human `operator`，明确 Agent identity 无效 |
| change-local hardware evidence V3 | `492aa3d5107c6790f56df1fff336280578494364` | CHG-2026-025 scoped delta 才允许 `executor.kind=agent` + `authorizationRef` |
| OpenHarmony profile | `2ae13490e075f327bb7448ccacf908be5ba7e3aa` | `OPENHARMONY-TOOLS@0.6.0`；HiLog 只有原则，无 exact family/resource |
| integration lock | `836d4ccc8c34c5826b6c53dcf9004e678a506d25` | `INTEGRATION-PROFILES-0.7.0`；无 E0 collection registry |
| trace registry | `9c59c102784661fb1f50c31916e29cbeeb6bd457` | exact pack 只绑定 hdc 3.2.0d；不能借给 3.2.0f candidate |
| `HDCProduction.swift` | `c7f71e5af90bc3d468d5f0817734d297f0c339a2` | closed semantic profile/family 无 HiLog/HiDumper/Trace probe lowering |
| readonly registry source | `2dfe8e9d8290d6e939b4e3531ac81bb332a7cc29` | 只采用既有 3.2.0d server/device readonly families |
| supervisor observation source | `589dfec329044b58f4fefec3a70d4af7f9cfd15e` | exact 3.2.0f commandless identity producer；不登记 device command |
| trusted operation host | `d5509f326d53296c70ad10c3c3719fea1c5f1857` | E0 admission seam 可用，但不提供具体 command authority |

profile/lock/trace canonical SHA-256 分别为
`8f70c070c9657f224ed019cddcc207d97f63424e9a032fef0473f58edededde0`、
`1ec25dc1afe9b57ae237afda9e454a53e9b6e3ee2231892af75969a2baa4644c`、
`9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613`。

## Blocking findings

### B1 — AIN-011 cannot write its own readiness status

Base-derived path guard result：

```text
patterns=6
tasks_path_allowed=false
hdc_production_allowed=false
readonly_registry_allowed=false
integration_allowed=false
```

`check_paths` 从 PR base tree 读取 allowlist。AIN-011 不能在同一 PR 增加 `tasks.md`
路径并把自己 `blocked→ready`；这会成为 self-authorized scope。需要先合入独立
scope remediation，任务仍保持 blocked。

### B2 — no exact E0 collection integration authority

current profile 的 HiLog 段只要求 runtime probe，不固定 exact wrapper argv、stream
framing、timeout/cancellation、byte ceiling、termination/result 或 golden/resource
family。HiDumper 样例与旧 human scripts 不是 production registry；Trace pack 的 HDC
identity是 3.2.0d。current HDC production semantic profile 又是 closed constructor，
且没有上述 command family。

因此 AIN-011 即使只在其新目录实现，也只能：

- 临场发明/拼接 argv；
- 从 caller/test constant 接受 target 或 classification；
- 跨 HDC version 借用 trace/readonly support；
- 或把 non-empty/exit 0 当 success。

四种都违反 current integration profile 的 supported-family rule 与 trusted-fact
boundary。增加 parser family/command mapping 必须走独立 integration change，不能把
`HDCProduction.swift`/integration paths 临时塞进 AIN-011。

### B3 — integration change cannot originate Agent hardware evidence yet

current hardware-evidence V2 明确只接受人类 operator，而 Agent-capable V3 仍是
CHG-2026-025 的 approved scoped delta；未 archive 前，独立 integration change 不能
把另一个 change 的 draft 当 current contract。若让维护者亲自运行 registration
commands，则会重新引入本 change 正在消除的非配置型人工窗口。

合法顺序必须是：

1. 在 CHG-2026-025 内由 approved+ready E0 task 使用自身 V3 delta，Agent 执行
   registration capture；
2. 维护者 review/merge accepted、脱敏 provenance；
3. 独立 integration change 再从这些 protected-main bytes 登记 exact family/resource
   并接 production port；
4. AIN-011 显式依赖该 integration adoption 后重做 readiness。

## r5 remediation and sequencing

r5 新增 `TASK-AIN-010P`，scope 只覆盖 reusable typed registration runner、
contract/fault tests 与本 change evidence：

- runner 从 durable binding、production HDC discovery、TASK-HSO-002 server observer、
  registered device row 和 ready-task resolver 取事实；
- caller 不能提供 executable/argv/target/receipt/support；
- readiness 才固定 exact device/tool/八个 typed E0 argv、time/byte budgets、
  HostStorageCoordinator layout、human boundary、V3 evidence 与 privacy allowlist；
- Agent 执行全部 device commands；人工只做接线/供电、解锁/信任、系统权限/凭据配置、
  物理断连恢复与 PR review；
- HiLog/raw output 留在受控本地 Artifact；仓内只放脱敏 receipt/hash/count/statistics；
- 010P 不修改 integration/profile/lock/source authority，也不让 AIN-011 ready。

r5 同时只为 AIN-011 增加本 change `tasks.md` status/readiness path。后继 integration
change 的 ID/task、exact registry/profile/lock versions 与 consumer source paths 必须在
010P accepted bytes 存在后另行 proposal/readiness；不得在本 PR 预先占用。

## Verification

- `./scripts/check-sdd.sh`:0 errors / 0 warnings / 111 canonical acceptance IDs。
- `python3 scripts/test_check_pr_paths.py`:50/50 PASS。
- `python3 scripts/test_check_sdd.py`（repository shared pinned interpreter，
  PyYAML 6.0.3）：56/56 PASS。
- `git diff --check`:PASS。
- task-less remediation envelope:本 proposal 只修改本 change proposal/tasks/
  verification 并增加 change-local blocked audit；不声明 TASK-AIN-010P/011 PR，
  不利用新增 allowlist 自批 scope。
- 真实 process/HDC/device/network、server lifecycle、remote write、mutation 与
  destructive dispatch 全为 0；无 raw device/log bytes 或 secret 入仓。
