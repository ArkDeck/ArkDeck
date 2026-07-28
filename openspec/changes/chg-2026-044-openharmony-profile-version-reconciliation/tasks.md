# Tasks

## TASK-OPVR-001 — Reconcile the living profile header and mechanize the invariant

- Status:blocked
- Platform:macos
- Requirements:change-local integration consistency；canonical Core Requirement 零认领
- Acceptance:`OPVR-HEADER-LOCK-001`、`OPVR-MUTATION-001`、
  `OPVR-NONINTERFERENCE-001`
- Depends on:本 change proposal 与独立 approval-only PR 合入；独立 D1 readiness
- Readiness input pins:not yet established；readiness 必须从当时 protected main 重取
  profile、integration lock、device registry、`check_sdd.py`、`test_check_sdd.py`、
  CHG-2026-043 blocker carrier 与 CHG-2026-024 lineage commit 的完整 OID/blob/hash
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
