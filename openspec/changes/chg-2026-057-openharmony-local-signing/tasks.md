# Tasks — CHG-2026-057

单任务垂直交付。`status: approved` 与本 Task 的 `ready` 只有在 proposal PR 经维护者
review/merge 进入 protected `main` 后生效；合入前不得开始实现 PR。

## TASK-OHS-001 — Typed OpenHarmony local signing vertical slice

- Status:in-progress（产品实现、契约测试和四条本地门已完成；仅在本实现 PR 经维护者
  review/merge 后成为 protected-main 能力。真实 SDK host signing 与真机链因当前用户尚未
  安装 preset/Keychain secret，且已安装 LaunchAgent 仍运行 proposal 前 daemon 而保持
  environment-blocked；不以 fake signer 或旧真机记录翻 `done`。）
- Golden Journey:GJ-2、GJ-5
- Platform:macos
- Requirements:`OHS-REQ-001`、`OHS-REQ-002`、`OHS-REQ-003`
- Acceptance:`OHS-AC-1..8`
- Depends on:CHG-2026-057 r1 proposal merge（即 D1 approval）
- Applicable failure patterns:`AF-001`（registry/schema/generator/Swift lockstep）、
  `AF-004`（Catalog producer 到真实 dispatcher/postflight 全链）、`AF-007`（Java/JAR、
  Keychain 与宿主文件依赖必须显式固定）、`AF-008`（trust boundary 对抗矩阵）、
  `AF-011`（不得以 exit 0 或文件名替代 postflight 证明）
- Production reachability:`LaunchAgent → owner-only UDS → RuntimeJobEngine → published
  workspace.sign-openharmony-hap@1 → existing workspace provider → identity-bound Java +
  fixed hapsigner JAR secret-safe PTY → verify-app → RuntimeArtifactStore signed lease →
  debug.hap@1`
- Trusted fact sources:input bytes/size/hash/binding 来自 Runtime Artifact lease store；Java/JAR/
  keystore/cert/profile path、hash、permissions 与 preset identity 来自 Swift installer 写入的
  owner-only receipt，并在每次 dispatch 前重测；secret 只来自当前用户 Keychain；sign/verify
  facts 来自 provider-owned output 与 pinned hapsigner readback。caller/Agent 不能同时构造
  任一事实及其证明。
- Allowed paths:
  - `Catalog/**`
  - `Packages/ArkDeckKit/**`
  - `scripts/catalog_gen/**`
  - `openspec/contracts/workflow-step-registry.yaml`
  - `openspec/contracts/workflow-step.schema.json`
  - `openspec/changes/chg-2026-057-openharmony-local-signing/**`
  - `docs/adr/**`
- Forbidden paths:
  - `openspec/constitution.md`、`openspec/specs/**`、`openspec/verification/**`、
    `openspec/baselines/**`、`openspec/integrations/**`、`openspec/platforms/**`
  - 其他 `openspec/contracts/**`、其他 change 目录
  - `.github/**`、`AGENTS.md`、`PRODUCT-LOOP.md`、`ArkDeckApp/**`、`ArkDeck.xcodeproj/**`
  - raw HDC/shell/command 字符串、PATH/DevEco 自动猜测、password argv/env/plist/receipt、
    Agent-facing signing identity install/remove、capability admin、accepted safety requirement 放宽
- Risk:high（新 operation + secret-bearing host tool；设备 effect 为 hostOnly，但 secret 泄漏、
  错误继承 Artifact binding 或 exit-0 冒充 verify 都是产品安全失败）
- Hardware required:yes（OHS-AC-8；其余 host signing/negative/recovery tests 不需要设备）

### Deliverables

- 新 Catalog operation 与 `signWorkspaceOpenHarmonyHap` typed step 全链 lockstep。
- Swift signing preset install/status/remove、Keychain store、identity/permission verifier 与
  LaunchAgent/doctor availability diagnostics。
- 复用 workspace provider/Runtime 的 signing action、secret-safe PTY dispatcher、sign +
  verify postflight、Job-owned temp、Artifact publication/binding inheritance 与 recovery readback。
- daemon/CLI/Agent UDS 回归、App read-only XPC 回归、secret scan 与最小使用文档。
- host 真实 hapsigner 对真实 unsigned HAP 的验证；设备可用时只经 published typed operation
  将 signed lease 交给 `debug.hap@1` 完成真实安装/readback。设备或权限不可用时如实记录
  blocker，不以 fake/simulation 声称真机通过。

### Verification

- `OHS-AC-1` → Catalog/schema/generator/Swift parity + unknown/mismatched kind negatives。
- `OHS-AC-2` → installer/status/remove contract tests + absolute path/hash/permission drift matrix。
- `OHS-AC-3` → TTY/Keychain/PTY fake + process-table/receipt/log/Artifact secret absence scan。
- `OHS-AC-4` → input Artifact size/hash/ZIP/target mismatch negatives，全部 dispatch=0。
- `OHS-AC-5` → real SDK hapsigner host run + verify-app outputs + signed Artifact/report hashes。
- `OHS-AC-6` → signed Artifact inherits exact source binding and is consumable only by matching
  `debug.hap@1` request；wrong/stale binding拒绝。
- `OHS-AC-7` → cancel/crash/timeout/restart/readback fault matrix；no blind replay、临时文件有界清理。
- `OHS-AC-8` → 可用 OpenHarmony 真机上 `LaunchAgent → UDS → typed sign → signed lease →
  debug.hap@1 → install/package/process readback → Artifact/postflight`，人工 hapsigner/HDC=0。
- 四条本地门全部通过；最终 commit 后、push 前运行
  `python3 scripts/check_pr_paths.py --repo-root . --preflight --base-revision origin/main
  --head-revision HEAD`。

### Stop conditions

- hapsigner 无法在不把 secret 放入 argv/env/log/journal 的前提下由 LaunchAgent 驱动；
- 需要 caller 提供 path/argv/password/private key 或绕过 Artifact lease；
- signed output 无法从 source lease 精确继承 target/binding/stable identity；
- verify-app 无法给出可机械检查的输出，必须用 filename/exit 0 猜测；
- 需要调用 HDC、云账号服务、新 provider/device profile 或改变 E1/E2/destructive policy；
- 测试只有通过放宽 accepted safety requirement 才能通过。

命中任一项即停止受影响实现，按真实原因标记 `BLOCKED_BY_PRODUCT_DEFECT`；不得静默扩大
scope 或把人工确认当证明。

### Notes / handoff

实现 PR 在 `evidence/runs/TASK-OHS-001/` 追加一份 run 记录，包含命令、退出码、Catalog
digest、非秘密 tool/file hashes、Job/Artifact IDs、脱敏 target、AC 结论与遗留风险。
