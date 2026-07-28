# TASK-AIN-010 readiness audit r2 — blocked on readiness status path

## Classification

- Date:2026-07-28.
- Audit base:`d029cc4ebb9b91c647e904d943a65bef5ee95001` (PR #751 merge;
  TASK-AIN-009R done).
- Method:host-only dependency, contract, source-surface and path-guard audit.
- Result:**blocked**. This record and its scope remediation do not make
  TASK-AIN-010 ready and are not implementation, capability acceptance,
  authorization, device dispatch or hardware evidence.
- Installed-HDC/server-lifecycle/process/device/mutation/destructive/network
  dispatch:`0 / 0 / 0 / 0 / 0 / 0 / 0`.

## Dependency and prior-blocker closure

- TASK-AIN-009 implementation/done remain protected-main ancestors.
- TASK-AIN-009R implementation PR #750 exact head
  `fdfe74a1aa5f1be4ea4174013e0b34073bc208bf` was approved by `lvye` and
  merged as `ec1cf659618edf96bdbfdc09a4a8182276bd3c58`. Its independent
  done PR #751 exact head
  `7279692e818349115e7a4edf5060b35a3883994f` was approved by `lvye` and
  merged as the audit base.
- The r1 capability-carrier, E0/E1/E2 authority-union, E1 usage,
  Journal/Manifest 2.2 and encoder/replay scope blockers are therefore
  available for a fresh readiness decision. The CLI/App control surface
  remains assigned to TASK-AIN-015 and is not part of TASK-AIN-010.
- The new `AgentDeviceOperations/**`, `HumanActionRequired.swift` and two
  task-local test files remain absent, so there is no new-file collision.
  Existing storage/HDC files named by r4 exist. `Package.swift` discovers
  new source/test files without modification.

## Blocking finding

TASK-AIN-010 has 14 base-derived Allowed-path patterns, but they do not include
its active change `tasks.md`:

```text
python3 -c '<load TASK-AIN-010 through scripts.check_pr_paths>'
patterns=14
tasks_path_allowed=false
```

The checker blob is
`d3c3fe299487c7c8512569c75ba1827b7f3433b9`; the audited tasks blob is
`5c5135ed9abda32580eb4bc506e285c90dfcf9ea`. `check_paths` obtains the
allowlist from the pull request base tree. A readiness candidate therefore
cannot authorize itself by adding the missing path and flipping
`blocked→ready` in one PR; it would fail closed before review.

This is narrower than r1: no additional product source, test, contract,
operation, effect, authority or external system is missing from the r4 scope.
The audit found no need to modify `Package.swift`, current specs/contracts,
`StrictJSON.swift`, Rockchip-specific provenance/admission/execution sources,
CLI/App code or any capability/authorization instance. A fresh readiness must
still pin the exact generic-host APIs, trusted ports, 2.2 compatibility,
negative/fault matrix and implementation-input blobs; this record does not
pre-approve those choices.

## Remediation and sequencing

This D1 remediation adds exactly one Allowed-path entry:

```text
openspec/changes/chg-2026-025-ai-native-unattended-device-ops/tasks.md
  (only TASK-AIN-010 status/readiness pins/evidence references)
```

It also preserves the task as `blocked` and records the r2 finding. It changes
no product behavior, implementation surface, Requirement/AC, authority,
risk acceptance, hardware state or external configuration. After this
remediation is approved and merged, a separate fresh D1 readiness PR must:

1. re-pin then-current protected main and both dependencies;
2. re-run collision, input-blob, baseline, privacy and no-dispatch checks;
3. freeze binary request/host/authority/blocker/persistence APIs and the
   exact verification matrix;
4. make the only `blocked→ready` change.

TASK-AIN-010 implementation and all dependent TASK-AIN-011—017 product work
remain prohibited until that readiness PR is separately approved and merged.

## Verification

- `./scripts/check-sdd.sh`:0 errors / 0 warnings / 111 acceptance IDs.
- `python3 scripts/test_check_pr_paths.py`:50/50 PASS.
- Task-less remediation-envelope probe:
  `declared_task=None changed_paths=2` PASS; both paths are under
  `openspec/**`, which the approved sensitive-path table intentionally leaves
  open for governance changes without a task self-authorizing its own scope.
- `git diff --check`:PASS.
- Open PR audit at the base found only #752, which changes
  CHG-2026-043 `tasks.md` and has no path overlap with this remediation or
  TASK-AIN-010 inputs/outputs.
