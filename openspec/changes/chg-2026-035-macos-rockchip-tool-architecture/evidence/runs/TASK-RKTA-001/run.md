# TASK-RKTA-001 — architecture decision run

- Date: 2026-07-25
- Executor: agent
- Evidence class: `documentReview`
- Audit base / readiness merge:
  `8f035b5eb64c731f5c1a19affd06e58c93a17d5b`
- Outcome: `selected:bundledRockchipComponent`
- Product behavior changed: no
- Hardware required/accessed: no/no

## Readiness and input closure

PR #528 exact head `651b75290c733df213f5aea905836a0e38c262b1`
was approved by `lvye` and merged as
`8f035b5eb64c731f5c1a19affd06e58c93a17d5b`. The decision worktree started
from that merge OID. CHG-2026-035 approval merge
`c74fa46a810f6713b987c639ce23246ddf24a307`, proposal merge
`4bee496d9b33f271fe4d80bb93690befdf5ff30f`, and 001G evidence merge
`2b15a53986054f0984a71a0f113a5a2b807c3914` are ancestors.

All 23 non-self Git blob pins in the r1 readiness matched. The reviewed
readiness `tasks.md` blob at the merge is
`392075b9ef4801b34cfc19474327cd3d06684f99`. Before editing, ADR-0003,
DEC-011, and `evidence/runs/TASK-RKTA-001/` were absent.

The decision used the 001G receipt only for its merged fact: Stage A stopped
at `selectedEntryNotRegularFile`; security scope, bookmark, hash, Process,
Stage B, real tool, USB and device were not reached. The candidate's invalid
pre-bookmark `bookmarkCreated` report was not reused. No 001G source was
reconstructed or run.

At decision preflight, public open PRs were:

- #529 `agent/task-hlr-003-readiness-r2`;
- #523 `agent/chg-2026-034-sdd-runtime-discovery`.

Their changed paths did not overlap this task's allowed paths. No unmerged
branch or chat statement was used as a product/platform fact.

## Environment

- macOS `26.5.2` (`25F84`), arm64;
- Xcode `26.6` (`17F113`);
- Apple Swift `6.3.3`;
- Git `2.55.0`;
- GitHub CLI `2.96.0`.

## Primary-source review

Retrieval UTC was `2026-07-25T06:48:27Z`. The exact Apple page titles, URLs,
short paraphrases and Rockchip commit/tree/blob facts are registered at the
top of `candidate-matrix.md`.

Review-tooling network activity was separated from ArkDeck product activity:

- ten allowed Apple documentation URLs were read;
- the exact Rockchip upstream commit plus `license.txt`, `CMakeLists.txt` and
  `Readme.txt` objects were read through the GitHub API;
- Git/GitHub PR metadata was read to establish ancestry, review/merge and
  concurrency facts.

No dependency or binary was downloaded; no upstream clone/checkout was
created; no App/tool/product network path was constructed or run.

Primary-source conclusions:

- Apple separates user-selected file access, persistent bookmarks,
  cross-process bookmark sharing and executable location. User-selected file
  entitlements do not authorize running a program outside the App
  bundle/container/App Group.
- Apple documents an embedded command-line tool, including one produced by an
  external build system, as a Sandboxed nested-code shape with App Sandbox
  inheritance, Code Sign On Copy, architecture handling and Hardened Runtime;
  the same shape applies to independent Developer ID distribution.
- XPC peer checks, ServiceManagement lifecycle, parent/team launch constraints,
  nested inside-out signing and notarization remain separate security/lifecycle
  boundaries; no “helper” label collapses them.
- Upstream commit
  `304f073752fd25c854e1bcf05d8e7f925b1f4e14` resolves to tree
  `9908d5bd43d32659500e6f0d0734755ee557122e`. Its exact license is GPL-2.0,
  while its pinned macOS CMake file hard-codes libusb 1.0.22 and libiconv
  paths. These facts do not prove legal acceptance, artifact reproducibility,
  dependency closure or release readiness.

## Decision

The complete five-candidate matrix, including all four `brokerOrHelper`
subrows, selected:

> `selected:bundledRockchipComponent`

The selected end state embeds the exact Rockchip executable as App-owned
nested code and launches it directly through the current typed,
identity-bound process seam. It adds no XPC, broker, login item, LaunchAgent,
LaunchDaemon, privileged helper, external-tool fallback or alternate
distribution.

Every selected-row `requires-new-change` is mapped to an ADR-0003
pre-implementation gate: source/artifact reproducibility, GPL-2.0
distribution acceptance, dependency/SBOM closure, nested signing/notarization,
typed composition/file leases, signed E0/clean-host evidence, and an explicit
CHG-2026-026 revision. None is recorded as already satisfied.

## Authority and effect review

The selected future route is:

```text
ArkDeckApp
  -> RockchipFlashApplicationFacade / RockchipFlashExecutionHost
  -> typed plan + confirmed binding
  -> RockchipFlashAuthorizationGate
  -> bundle-owned component descriptor
  -> identity-bound FoundationProcessExecutor + fixed RockchipClosedCommand
  -> process/device dispatch
  -> durable intent + semantic outcome/postflight or waitingForRecovery
```

The App root remains the only production composer and trusted host authority
mint. The component cannot choose itself, accept executable/argv/environment
from a caller, mint authority, or prove its own effect result. Fake,
simulation, and plan-only routes receive no real executor/binding. Unknown
identity/outcome remains `waitingForRecovery`; no restart/replay inference was
introduced.

This document-review task itself constructed none of the route above.

## Commands and checks

Read-only preflight/review commands:

```text
gh pr view 528 --json ...
git fetch origin main
gh pr list --state open --limit 100 --json ...
git worktree add -b agent/task-rkta-001-decision <temporary-worktree> origin/main
git rev-parse HEAD:<pinned-path>
git merge-base --is-ancestor <merge-oid> HEAD
gh api repos/rockchip-linux/rkdeveloptool/git/commits/<pinned-commit>
gh api -H "Accept: application/vnd.github.raw+json" <pinned-upstream-object>
sw_vers
uname -m
xcodebuild -version
swift --version
git --version
gh --version
```

Repository verification:

```text
scripts/check-sdd.sh
python3 scripts/test_check_pr_paths.py
git diff --check
git diff --name-only <readiness-merge>...HEAD
```

The final result of the repository verification commands is recorded below
after the decision carrier is complete.

## Acceptance verdicts

| Acceptance | Verdict | Evidence |
| --- | --- | --- |
| `RKTA-OPTIONS-001` | PASS | `candidate-matrix.md` evaluates all five top-level candidates, four helper subrows and every mandatory criterion with controlled verdict, source and fact/inference label. |
| `RKTA-DECISION-001` | PASS | ADR-0003, DEC-011, macOS profile, matrix and this run use the exact outcome `selected:bundledRockchipComponent`; rejected alternatives, risks, rollback and revalidation triggers are explicit. |
| `RKTA-BOUNDARY-001` | PASS | ADR-0003 and this run trace App root, authority mint, component identity/file leases, fixed command, dispatch and durable outcome; fake/plan-only structural separation is explicit. |
| `RKTA-HANDOFF-001` | PASS | ADR-0003 lists all prerequisite changes/gates; Core, HDC external-first, CHG-2026-026 state and 001G evidence remain unchanged. |
| `AC-FLASH-001-01` | PASS (`documentReview`) | Future discovery/execute reaches only a bundle-owned identity-bound component; missing/drifted/unsupported component blocks without similar-command fallback. |
| `AC-FLASH-005-01` | PASS (`documentReview`) | Plan-only remains a full non-executed plan with zero process/device mutation and cannot import human execution as `succeeded`. |
| `AC-FLASH-015-01` | PASS (`documentReview`) | This task creates no binding/authority/runner and records zero real device/destructive dispatch. |
| `AC-JOB-005-01` | PASS (`documentReview`) | Selected seam requires absolute bundle URL, closed typed argv, empty caller environment and no shell/PATH. |
| `AC-UX-007-01` | PASS (`documentReview`) | No helper/install/privilege/system mutation is added; any future nested component and entitlement work is an explicit approved-change gate. |

These are document-review conclusions for this architecture task, not product,
platform, distribution or hardware conformance evidence.

## Effect counters

| Effect | Count |
| --- | ---: |
| App/probe/fixture build or run | 0 |
| `Process` / `rkdeveloptool` / HDC launch | 0 |
| product network dispatch | 0 |
| picker/bookmark/security-scope operation | 0 |
| XPC/helper/login item/LaunchAgent/LaunchDaemon dispatch | 0 |
| install/register/unregister | 0 |
| USB/device access | 0 |
| E1 device mutation | 0 |
| E2/destructive dispatch | 0 |
| sudo/pkexec/privilege elevation | 0 |
| entitlement/sign/quarantine/xattr mutation | 0 |
| system rule/group/ACL mutation | 0 |

## Privacy, deviations and residual risk

No bookmark bytes, private user path, raw Sandbox log, device identifier,
credential, signature ticket, external binary or unbounded output is stored.
Only public URLs, Git object identities, tool/dependency names, controlled
verdicts and hashes are recorded.

Deviations: none.

Residual risk remains entirely in the follow-on gates: license/distribution
acceptance, reproducible source build, libusb/libiconv closure, SBOM,
nested-code signing/notarization/update, exact child file leases, signed
Sandbox RockUSB E0, clean-host, and later human-authorized destructive
acceptance. Until those gates are merged and evidenced, Rockchip App execute
remains blocked.

## Final repository verification

- `scripts/check-sdd.sh`: PASS, `0 error(s), 0 warning(s), 111 acceptance IDs`.
  The worktree had no local `.venv-sdd`; the checker used an existing
  temporary PyYAML 6.0.3 environment through its documented
  `ARKDECK_PYTHON` override. No dependency was installed or downloaded.
- `python3 scripts/test_check_pr_paths.py`: PASS, 24/24.
- `git diff --check`: PASS.
- Candidate matrix structural audit: PASS, 9 candidate/subrow sections × 26
  mandatory result cells = 234/234 cells beginning with the controlled
  verdict vocabulary.
- Changed-path audit: PASS, exactly eight files across seven task-allowed path
  declarations:
  - `docs/adr/0003-macos-rockchip-tool-execution.md`;
  - `openspec/planning/open-questions.md`;
  - `openspec/platforms/macos/profile.md`;
  - CHG-2026-035 `design.md`, `tasks.md`, `verification.md`;
  - CHG-2026-035
    `evidence/runs/TASK-RKTA-001/{candidate-matrix.md,run.md}` (one allowed
    evidence subtree).
- Forbidden-path audit: PASS; zero forbidden path changed.
- Outcome consistency scan: PASS; ADR-0003, DEC-011, profile, design, tasks,
  verification, matrix and run agree on
  `selected:bundledRockchipComponent`.
- Secret/privacy scan: PASS; no private key marker, credential, bearer token,
  raw bookmark, private user path, raw Sandbox log, device identifier or
  external binary is present.

This PR keeps TASK-RKTA-001 `ready`; a separate D0 PR may mark it `done` only
after this decision/evidence PR is reviewed and merged.
