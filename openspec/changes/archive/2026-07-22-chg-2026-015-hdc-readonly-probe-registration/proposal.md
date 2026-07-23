---
id: CHG-2026-015-hdc-readonly-probe-registration
revision: 3
status: verified # 2026-07-21 本 verification-closure PR(先例 #175/#176/#201/#208);approve 载体 #123;2026-07-22 r3 仅起草 archive provenance 路径迁移/hash-size 重钉例外范围,不改变 verification 结论,仅在本 D1 PR 经独立 AI premerge review 且维护者 review/merge 后生效。原注:r1 proposal 经 PR #121 合入；批准由 approval-only PR #123 的维护者 review/merge 构成；r2 为 plan-only revision（capture-plan.md）
class: integration
core_change_level: none
owner: lvye
core_baseline: CORE-2.0.0
platforms: [macos]
---

# Register four production read-only HDC probe contracts

## Why

`TASK-M1-006` 的固定实现已经由 CHG-2026-014 收拢进 `main`，但 source task 仍按
`evidence/runs/TASK-M1-006/run.md` review-remediation addendum 14 保持 `blocked`。
`OPENHARMONY-TOOLS@0.2.0` 只精确登记了 uninstall、checkserver 与 `-v` 的 raw/
semantic family；它没有登记能够建立下列生产 observation 的封闭 probe contract：

1. server process identity、endpoint 与 generation evidence；
2. selected-device authorization/identity observation 与 durable binding 的匹配输入；
3. key-access diagnostics；
4. subserver capability。

当前实现因此正确返回 unknown/unavailable，并阻止 external-server lifecycle preview、
生产授权继续、key 权限结论和 subserver supported 结论。由实现自行选择 argv、把
`checkserver` 健康输出推断成 generation，或把 fixture enum 当作 production observation，
都会绕过 integration profile 的事实来源边界。

本 change 只建立上述四类 probe 的版本化注册、provenance 和 fail-closed 规则。它不执行
probe、不修改 M1-006 源码，也不声称任何 HDC AC 已通过。

## What changes

### In scope

- 为 `OPENHARMONY-TOOLS` 增加结构化、版本化的 read-only probe registry。每个 entry
  必须固定 probe kind、tool/profile version、executable identity policy、exact argv（若有）、
  endpoint/environment precondition、effect classification、输入/输出 stream、raw/receipt
  family、semantic mapping、authority limit、timeout/cancellation/resource cleanup 与 provenance；
- 登记四个封闭 family：
  - `serverIdentityGeneration`：组合已存在 server 的 process identity、executable
    identity 与 endpoint listener observation；不得接受调用方提供 generation，不得仅凭
    `checkserver`/PID 字段形状建立 ownership。相同 recipe 同时用于 post-dispatch observation；
  - `selectedDeviceAuthorizationBinding`：只观察 profile 声明的选定 device identity/
    authorization state；probe result 只能与既有 durable binding identity/revision 比较，
    不能自行创建或递增 binding revision；
  - `keyAccessDiagnostics`：platform file-access observation，只返回 configured/user-approved
    key locator 的 missing/denied/public-readable/private-unreadable 等诊断与公钥指纹；不读取、
    复制、删除、chmod、上传或记录私钥 bytes/path；
  - `subserverCapability`：只接受经 provenance 证明为 client-local 且零 server lifecycle/
    device migration 的 help/capability family；永不使用 `spawn-sub`、`killall-sub` 或等价
    mutation 作为 probe；
- 对每个 command family，只有 authoritative/controlled-human capture 或维护者认可的
  tool documentation + platform receipt 能证明 exact argv/raw/effect 时才能登记 supported。
  Agent-authored fake bytes 只可用于 negative/control tests，不构成 production provenance；
- 如任一候选命令可能在 server absent 时隐式启动 server，registry 必须要求先有已验证的
  existing-server observation，并在 precondition 不满足时返回 unavailable；不得通过执行
  命令来探测其是否安全；
- bump OpenHarmony integration profile/lock version，并以 resource contract 固定登记文件、
  fixture/receipt hash 与 supported-family closure；未知、缺 provenance、身份不匹配、超时、
  取消或副作用无法证明时统一 unsupported/unknown；
- TASK-I15-001 done 且本 change verified 后，M1-006 是否采用这些 entries、如何恢复执行与
  signed Sandbox XCUITest，必须由独立 task revision/readiness PR 决定。

### Out of scope

- 修改 `TASK-M1-006` 状态、源码、App/UI/XCUITest、platform profile 或既有 evidence；
- 改变 `REQ-HDC-*`、`AC-HDC-*`、Port、contract/schema、Core baseline 或 Safety invariant；
- 执行已安装真实 `hdc`、自动启动/停止 server、访问真实设备、读取真实私钥、使用非 loopback
  网络或执行任何 lifecycle/subserver/device/destructive mutation；
- 把 device authorization 当作 channel protection，或从 connectKey、exit code 0、版本、
  endpoint reuse、PID 或 caller assertion 推断 identity/generation/binding；
- 登记生产 mutation executor、通用 argv runner、新 parser family 或 release/support claim；
- 启用 Developer Mode、解锁 macOS、运行 signed XCUITest；这些仍属于 M1-006 独立 platform
  closure。

## Observable behavior before/after

- Before：四类 production state 只能保持 unknown/unavailable；fixture/presentation 注入不构成
  production evidence。
- After TASK-I15-001 verified：profile consumer 可以按版本读取四类封闭 registry entry；只有
  entry 的 exact precondition/effect/provenance 全满足时才可产生 observation receipt，其他情况
  继续 fail closed。仅完成注册不会使 M1-006 代码自动采用 probe，也不会改变其状态。

## Scope

- Requirements:`REQ-HDC-001`、`REQ-HDC-002`、`REQ-HDC-003`、`REQ-HDC-006`、
  `REQ-HDC-007`、`REQ-HDC-009`、`REQ-HDC-010`；`POL-HDC-001`、`POL-SAFETY-001`、
  `POL-TARGET-001`、`POL-WORKFLOW-001`
- Acceptance inputs:`AC-HDC-001-02`、`AC-HDC-002-01`、`AC-HDC-003-01/02`、
  `AC-HDC-006-01`、`AC-HDC-007-01/02`、`AC-HDC-009-01`、`AC-HDC-010-02`
- Ports:`PORT-PROCESS-001`、`PORT-FILE-ACCESS-001`、`PORT-TOOL-TRUST-001`、
  `PORT-DEVICE-ACCESS-001`
- Integration input:`OPENHARMONY-TOOLS@0.2.0`、`INTEGRATION-PROFILES-0.3.0`
- Core baseline bump:no

## Platform impact

| Platform | Disposition | Reason |
| --- | --- | --- |
| macOS | integration inputs added; no conformance transition | M1-006 后续可映射，当前仍 blocked |
| Windows | deferred / unchanged | 无 capture、实现或支持声明 |
| Linux | deferred / unchanged | 无 capture、实现或支持声明 |

## Safety, privacy, and compatibility

- registry 是允许列表而非 command discovery；未登记即 unsupported，禁止 fallback 到任意 argv；
- authoritative raw input 若包含设备标识、用户路径或其他敏感值，不得直接入仓；只保留维护者
  认可的脱敏 receipt、原始输入 hash 与受控位置引用。私钥 bytes/hash/path 均不得记录；
- registration run 的 installed-HDC/device/server mutation dispatch 必须为 0，也不得停止、
  重启、接管或重新配置执行环境中既有的 HDC server。受控 capture 如需真实工具，由人类
  维护者在本 task 外执行并提供 provenance；Agent 不执行；
- profile/lock 版本升级是显式 adoption boundary。旧 consumer 保持 0.2.0 行为；新 entries
  未被 M1-006 独立 revision 采用前不可达；
- rollback 是独立 revert TASK-I15-001 registration PR；不得改写旧 fixture/evidence，且
  M1-006 保持 blocked/unknown。

## Approval gate

- Proposal 经 PR #121 合入 `main`
  (`93ab61450ef74237c2e586e8512090a1857c51ce`，2026-07-19，`status: proposed`)。
- 正式批准由维护者 review/merge 本 approval-only PR 构成。本批准不产生任务执行：
  `TASK-I15-001` 继续保持 `blocked`；只有独立 readiness PR 确认四类 authoritative
  capture/receipt 输入可得且 provenance 已获维护者认可后，任务才能转为 `ready`。缺任一
  family provenance 时不得开始部分注册，也不得宣称 M1-006 blocker 已解除。

## Archive relocation scope (r3; D1)

本 revision 只为 verified change 的归档建立一个封闭、可复核的路径迁移例外。它不重开
`TASK-I15-001`，不改变七项 `I15-HDC-*` 结论，也不授予新的 probe、device 或 mutation
authority。只有本 D1 revision 经独立其他会话 AI premerge review 并由维护者 review/merge
进入受保护 `main` 后，后续独立 archive PR 才可开工。

- 固定归档目标为
  `openspec/changes/archive/2026-07-22-chg-2026-015-hdc-readonly-probe-registration/`；
- 唯一获准的生产语义字段变化，是四个 entry 的 `provenance.sourcePath` 从当前 change 根
  精确迁移到上述 archive 根。provenance source bytes/source SHA-256、`acceptedBy`、family、
  registry/version、effect、precondition、authority 与 adoption boundary 必须逐字节或逐字段
  保持不变；
- 因 sourcePath bytes 变化而产生的 receipt SHA-256/size、registry SHA-256/size、
  `resources.json` SHA-256/size 及其 living consumer pins 可以且仅可以做传递闭包重钉；
- 既有 evidence/run/provenance 内容和历史结论保持冻结。归档目录内的历史 hash 记录、旧
  OID 与运行结果不得为了匹配新 living pins 而改写；
- 实际目录迁移、living provenance 更新与全部派生 re-pin 必须在同一独立 archive PR 原子
  完成；缺任一 closure、出现归一化结构以外差异或仍有 active-root 生产 provenance 引用时
  fail closed。

## Verification closure(2026-07-21)

- 依据:TASK-I15-001 done(实现 PR #159 squash `7c77672`,done 状态 PR #163 squash
  `3e2d6d4`,合入版独立深度审计零 blocker 零 major);七项 `I15-HDC-*` 验证面全部
  satisfied——四 family 二值登记(serverIdentityGeneration/selectedDeviceAuthorizationBinding
  = supported、keyAccessDiagnostics/subserverCapability = unsupported)逐条绑定
  #141/#155/#156 维护者认可的一手 provenance;19 文件 hash closure 独立重算全命中;
  测试经三组变异证伪为真实断言;fixtures 敏感扫描零命中;零真实
  HDC/device/network/server-mutation dispatch。
- 下游消费实证:registry 已被 M1-006(#191/#207)按 adoption_boundary 只读采用、被
  ratified `CORE-CONFORMANCE-2.1.0`(CHG-2026-018/#203)引用为 integration_conditional
  排除条件的唯一事实源,并经 CHG-2026-002 verified(#208)进入 M1 收官算术。
- 已知 non-blocking residuals(四项 minor/info,tasks.md 在案)保持登记,不触及 gate。
- 本 `verified` 由维护者 review/merge 本 PR 构成。不构成 platform conformance、
  hardware/support 或 release claim。archive 另行:registry/provenance 被 chg-002/
  chg-019 账本与 core-conformance manifest 精确引用,归档前须引用面收口(且
  `openspec/integrations/**` 本体为 living 文件,不随本 change 归档)。
