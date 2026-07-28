# Tasks

## TASK-OPVR-001 — Reconcile the living profile header and mechanize the invariant

- Status:done
- Done confirmation(2026-07-28；D0 机械状态推进；仅在维护者 review/merge 本
  status-only PR 后生效):
  - **Implementation/evidence merge:**PR #747 exact head
    `0e3fa305cf02466404633b65351cba2beb62b9cb` 由维护者 `lvye`
    `APPROVED`，并以
    `5ac17f6c11664fd83858554e403e9b2fd8dfd8d9` 合入 protected main。该 PR
    精确包含 living profile header、checker、checker tests 与 same-revision run
    四个批准路径；Agent PR open-pr/allowed-paths、SDD Guard 与 Swift CI 均为
    `SUCCESS`。
  - **Evidence and AC closure:**host-only run
    `evidence/runs/TASK-OPVR-001/run.md`（protected-main blob
    `3570f7f04d9b6ce0afadee26121748ece148e573`）对
    `OPVR-HEADER-LOCK-001`、`OPVR-MUTATION-001`、
    `OPVR-NONINTERFERENCE-001` 均记录 `PASS (contract)`；显式记录
    `0.5.0 → 0.4.0` mutation-red、恢复 green、forbidden blobs byte identity 与
    installed HDC/device/network/lifecycle/mutation/destructive dispatch 0。
  - **Protected-main output identity:**profile/checker/test blobs 分别为
    `4bfe204b1c13e53b93b35f840652206274614299`、
    `aa7dc6e34d187cb6458689d72ac28564b58fb29b`、
    `7e6c47044b31065d2752ce78d9185b6a3869732b`；profile 删除唯一
    `> Version...` 行后的 SHA-256 仍为
    `ab57ba2877ed6b8bd124e8aa21f7c05a8f9b91762fb8cdf736a80d28aef6d43c`。
    deliverables 完成、task-local TODO = 0、无 scope deviation。
  - **Post-merge deterministic replay:**`scripts/check-sdd.sh` = 0 errors /
    0 warnings / 111 canonical AC；`scripts/test_check_sdd.py` = 56/56 PASS；
    `scripts/test_check_pr_paths.py` = 50/50 PASS；`git diff --check` = PASS。
  - **Boundary:**本 PR 仅翻转本任务状态并引用已合入 evidence；零新 scope、风险接受、
    authority、实现或 evidence。CHG-2026-044 仍未 verified，须后续独立状态 PR；
    CHG-2026-043 `TASK-HSO-001` 仍保持 blocked 并须在 verified gate 后另做 fresh
    D1 readiness。
- Fresh readiness review(2026-07-28；host-only，零 HDC/设备；仅在维护者
  review/merge 本独立 D1 readiness PR 后生效):
  - **Audit base:**protected main
    `ef33f8f5f4307aebeb7f1fe592459f6787998e48`。该 base 包含 approval-only
    PR #743 merge `8929027501c7a33c6330c93feb580f22690bcd9b`；#743 exact head
    `c038444d6e944035e816c5d05dcd2584a68b2777` 由维护者 `lvye`
    `APPROVED`。其后的 #744 只修改 CHG-2026-025 proposal，与本 task 的 change、
    profile、lock、checker、tests 和 allowed paths 零交集。audit 时 open PR = 0。
  - **Approval/dependency gate:**CHG-2026-044 current proposal blob
    `f0a8fd9e373c86e9d2417855b3390319fe09d22a` 为 `status: approved`；
    revision 1 与 verification `@r1`、acceptance `change_revision: 1` 一致。
    task 无前序实现依赖、无需硬件/toolchain capture，也不需要新的产品、安全或版本
    决策；正式 implementation 仍必须等本 readiness PR merge。
  - **Version/lineage decision:**current profile blob
    `8889864cb023e43a745862e99a3f307d168e410c` 的 header 是 `0.4.0`，正文
    device section 是 `0.5.0`；current lock blob
    `9297820f25b9276859c60ba6bd89ab399066dcd0` 为
    `INTEGRATION-PROFILES-0.6.0` / `OPENHARMONY-TOOLS@0.5.0`，device registry
    blob `399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a` 也绑定 `0.5.0`。
    `git blame` 证明 header 仍来自 `171a269d`，而 approved CHG-2026-024
    implementation `ffca996f41be37d27137e7245c8fba3645fb0fb4` 同时落下 0.5.0
    profile body、lock 与 device registry，却未改 header。故本 task 只执行已批准的
    `0.4.0 → 0.5.0` header correction，不 bump lock/profile、不占用 CHG-2026-043
    的 `0.6.0/0.7.0` candidates。profile 删除唯一 `> Version：...` 行后的基线
    SHA-256 为
    `ab57ba2877ed6b8bd124e8aa21f7c05a8f9b91762fb8cdf736a80d28aef6d43c`；
    implementation 必须保持该 body digest 不变。
  - **Checker/consumer reachability:**current `check_locks_and_conformance` 已由
    `main()` 调用，SDD Guard 又在 push/PR 中执行 `check-sdd.sh` 和完整
    `scripts/test_check_sdd.py`；现有 `scripts/README.md` 已登记两个脚本，PyYAML
    `6.0.3` 与 Python `3.14.6` 可得，且 `re`/`Path`/strict YAML loader 均已存在。
    因此无需修改 workflow、README、requirements 或新增脚本。allowed paths 足以在
    一个 implementation/evidence PR 内闭环；任何需要这些额外路径的发现都按
    verification deviations 保持 blocked。
  - **Closed header contract:**只解析 Markdown H1 后的第一个连续 blockquote metadata
    block；metadata 行必须完整匹配 `ID` 或 `Version` + ASCII/full-width colon，
    trim 值与 Markdown trailing spaces，不从正文、后续 blockquote 或模糊前缀猜值。
    ID/Version 各恰一条且为非空 string；lock `profiles[]` 每项必须是 mapping，
    `id`/`version`/`path` 为非空 string，id 与 path 分别唯一，path 存在且指向可读
    Markdown。所有错误追加稳定诊断并继续后续独立检查，不抛 uncaught exception。
  - **Binary mutation matrix:**clean full-width-colon 与 ASCII-colon controls 均无
    reconciliation error；header version mismatch、header ID mismatch、missing/
    duplicate/empty metadata、non-mapping 或 wrong-type lock entry、duplicate id/path、
    missing/non-Markdown path 各产生确定性 error；坏 profile 与一个独立
    core-conformance error 同时存在时两者都被报告。至少记录一次
    `0.5.0 → 0.4.0` mutation-red 和恢复后的 green control，expected strings 由
    fixture 独立给出，不从 parser 结果回填。
  - **Baseline results:**`scripts/check-sdd.sh` = 0 errors / 0 warnings /
    111 canonical AC；`scripts/test_check_sdd.py` = 48/48 PASS；
    `scripts/test_check_pr_paths.py` = 50/50 PASS；`git diff --check` = PASS。
    当前绿色只证明输入与 harness 可用，不算三条 `OPVR-*` 的 implementation
    evidence。
  - **Effect/PR boundary:**readiness 未修改 profile/checker/tests/evidence，未执行
    installed HDC、设备、network 或 server/device lifecycle/mutation/destructive
    effect。implementation/evidence 只可使用下列 allowed paths；`ready→done`、
    change `verified` 与 CHG-2026-043 fresh readiness 仍是后续独立 PR。
- Platform:macos
- Requirements:change-local integration consistency；canonical Core Requirement 零认领
- Acceptance:`OPVR-HEADER-LOCK-001`、`OPVR-MUTATION-001`、
  `OPVR-NONINTERFERENCE-001`
- Depends on:本 change proposal #742 与 approval-only #743 合入（已满足）；
  独立 D1 readiness（本 PR，merge 前不得实现）
- Readiness input pins:

  ```yaml pins
  - commit: ef33f8f5f4307aebeb7f1fe592459f6787998e48
  - commit: 8929027501c7a33c6330c93feb580f22690bcd9b
  - commit: ffca996f41be37d27137e7245c8fba3645fb0fb4
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/proposal.md
    blob: f0a8fd9e373c86e9d2417855b3390319fe09d22a
  - path: openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/verification.md
    blob: e8774b51e96510d7286fd652f693b0ffc48ce782
  - path: openspec/integrations/openharmony/profile.md
    blob: 8889864cb023e43a745862e99a3f307d168e410c
    sha256: 6bcf7e8ed5ee74215bc72963a5b0a7e862010e48bad03438445ae442c235cfd2
  - path: openspec/integrations/INTEGRATION-PROFILES.lock.yaml
    blob: 9297820f25b9276859c60ba6bd89ab399066dcd0
    sha256: 802d87819b8ce39f197b7b59bfffde24d074cf7db33c3e80c89f9f8b3a5f8b46
  - path: openspec/integrations/openharmony/device-observation-probes.yaml
    blob: 399c5a102c7737bf6466e8a2c4c6a1d1b1bc0b6a
    sha256: 79814e45901ab7e4d9f9a271645cad62b0053a50534cba884cdff0c2e50b9d49
  - path: openspec/integrations/openharmony/readonly-probes.yaml
    blob: 99e8cc3d9929f9502a3e978a53cd56ad285d2aad
    sha256: b0ac1564109b8138c7a73cbb83684400967633f6e6b04701175a22d314d88da6
  - path: openspec/integrations/openharmony/trace-probes/1.0.0/registry.yaml
    blob: 9c59c102784661fb1f50c31916e29cbeeb6bd457
    sha256: 9d2a390b84092f1d78d86c10bf182884bc3a2ef8b3cdc3d35ed8e7e2b087b613
  - path: openspec/verification/core-conformance.yaml
    blob: 799d0051463f9aed50ff3c9e50045ef06f61c35e
    sha256: 9e7b1e2c0c0cbb26fd3ab8881c80aeea04dd55e24853fba54bfc4bce1053adc5
  - path: openspec/platforms/macos/profile.md
    blob: e4bcf6da97f94c55efaf0a13806881038efa12e0
    sha256: 8ae19225659b2974db6adc8b150537e5c35c17bf0bfdbe21633297bc2fd91f99
  - path: scripts/check_sdd.py
    blob: 3144f77e33d500d64d49ca1f087868dfa50493b4
  - path: scripts/test_check_sdd.py
    blob: e61e3c5439aedc40dc0b347005ffcb74e985cc38
  - path: scripts/check-sdd.sh
    blob: 7668f5aea9e8d4aeb4620b3047926a8802c1746a
  - path: scripts/requirements-sdd.txt
    blob: f62ce0c56db2b5d134cff98f7fb1625023cd2874
  - path: scripts/README.md
    blob: b82ba7da8562537bf2fbaedfc3e9e66747e6c222
  - path: .github/workflows/sdd-guard.yml
    blob: 1ab1db896b4ee83207e006b2720cdbe1c0d27e70
  - path: scripts/test_check_pr_paths.py
    blob: bb53f50ec1c198defc2a0439c11cf1dd6132b55c
  - path: openspec/changes/chg-2026-043-hdc-320f-supervisor-observation/tasks.md
    blob: fdd59a55246da65d39bfebd40e514a283afc2ffe
  - path: openspec/changes/archive/2026-07-28-chg-2026-024-hdc-device-snapshot-registration/evidence/runs/TASK-I24-001/run.md
    blob: 931d8c0009ab999b1f4e84741887132c07d4df05
  ```
- Applicable failure patterns:`AF-001`（shared checker/lock consumer 与 allowed paths）、
  `AF-006`（version/status/pin/PR boundary 漂移）、`AF-010`（必须有 mutation-red，
  不能用同源常量自证）、`AF-016`（fresh protected-main pins）、`AF-018`
  （open PR/共享文件 overlap 复核）
- Production reachability:not applicable；host-only profile metadata correction 与
  repository SDD lint，不接 production composition root 或 effect dispatcher
- Trusted fact sources:protected-main git history与 current profile/lock/device-registry
  bytes；CHG-2026-024 implementation merge
  `ffca996f41be37d27137e7245c8fba3645fb0fb4` 提供 lineage。临时 test fixture 只能
  证伪 guard，不能建立 profile version authority
- Allowed paths after readiness:
  - `openspec/integrations/openharmony/profile.md`（仅 header version
    `0.4.0 → 0.5.0`）
  - `scripts/check_sdd.py`
  - `scripts/test_check_sdd.py`
  - `openspec/changes/chg-2026-044-openharmony-profile-version-reconciliation/evidence/**`
  - 本 change `tasks.md`（仅本任务状态/evidence 引用）
- Forbidden paths:
  - `openspec/integrations/INTEGRATION-PROFILES.lock.yaml`
  - `openspec/integrations/openharmony/device-observation-probes.yaml`
  - `openspec/integrations/openharmony/readonly-probes.yaml`
  - `openspec/integrations/openharmony/trace-probes/**`
  - `openspec/verification/core-conformance.yaml`
  - `openspec/platforms/**`
  - `openspec/specs/**`、`openspec/contracts/**`、`openspec/baselines/**`
  - `Packages/**`、`ArkDeckApp/**`、`ArkDeckAppUITests/**`、`ArkDeck.xcodeproj/**`
  - archived CHG-2026-024 与其他 change 的 tasks/evidence
- Risk:medium（错误 header 或过宽 guard 会误述 current integration authority 或阻断
  无关 profile）
- Hardware required:no；禁止 installed HDC、真实设备与任何外部 effect
- Decision-Grade:D1（首次 readiness 的 exact lineage、scope 与 mutation matrix 接受）

### Deliverables

- living profile header 精确声明 `OPENHARMONY-TOOLS@0.5.0`，正文除该 header 行外
  byte-identical。
- integration lock profile entry 与 referenced Markdown header 的 generic exact-match
  guard，malformed input fail closed 且不中止其余诊断。
- clean、mismatch、missing/duplicate/malformed 与 mutation-red contract tests。
- host-only run evidence，包含 exact base/pins、命令、三条 AC 结论、禁止路径
  byte-identity 和 HDC/device/effect dispatch 0。

### Verification

- `OPVR-HEADER-LOCK-001` → independent metadata extraction + lock/profile comparison →
  current header/lock/body/device-registry lineage 全部为既有 0.5.0，lock bytes 不变。
- `OPVR-MUTATION-001` → focused checker unit tests + recorded mutation-red →
  version/id mismatch、missing/duplicate/malformed input 全部确定性报错，clean control
  恢复为 green。
- `OPVR-NONINTERFERENCE-001` → forbidden-path diff/blob audit + full SDD/guard suite →
  profile 正文、lock、registries、Core/platform/production bytes 不变，零外部 dispatch。
- Commands:`python3 -m unittest scripts.test_check_sdd`、`scripts/check-sdd.sh`、
  repository PR allowed-path contract suite、`git diff --check` 与 secret scan。

### Notes / handoff

- proposal、approval、readiness、implementation/evidence、`ready→done` 与 change
  `verified` 分别使用独立 PR。
- 本 task done/本 change verified 都不使 CHG-2026-043 自动 ready；其
  `TASK-HSO-001` 仍须 fresh D1 readiness 重钉 candidate versions 与 provenance。
