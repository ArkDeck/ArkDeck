# TASK-XPA-003 — execution record

Date: 2026-09-09. Base and fetched `origin/main`:
`2893280895b6d8a0520a9f9c4d274dcd52ed8f73` (#1827, r8).
Branch: `agent/xpa-003-macos-facade-20260909`.

## Outcome

Implementation has not started. The requested existing helper build/install delivery
needs a packaging scope decision. The task status and its three r8 readiness pins
are unchanged. This record is not approval, verification, a completed implementation,
hardware evidence, or an implementation PR. No production service was changed.

The user explicitly requires stopping when implementation needs paths outside the
base task's Allowed paths. The existing local and release packaging entry points
are outside that list:

- `Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`
- `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh`

## Code facts and proposed minimal resolution

The local script, lines 86–88 and 105–120 at this base, builds only the Swift CLI
and Swift daemon, copies that daemon to `ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`,
then signs the helper and outer CLI bundle. The release script, lines 70–72 and
89–105, does the same before notarization and assessment. Neither has a Rust build,
paired daemon packaging step, or hook for one. Merely modifying LaunchAgentService
cannot supply a Rust executable absent from the artifacts those scripts produce.

`LaunchAgentService.install`, lines 398–484, consumes and validates one complete
helper bundle, copies it, and records its executable digest. A signed bundle carrying
both executables can preserve the CLI's existing single `--daemon` input for update
and the typed retained bundle input for initial install. Therefore this inspection
does **not** establish that `ArkDeckRuntimeCommands.swift` needs an Allowed-path
extension. Adding a second CLI flag is unnecessary for the proposed bundle shape.

The proposed packaging implementation is a shared builder under `rust/**`, called
by both existing helper scripts before signing. It would package the Rust facade
and same-release Swift helper together, retaining a standalone Swift rollback
artifact and the existing provisioning/notarization checks. Wiring those two
entry points requires the two paths above. A separate manual repackaging command
could produce an experimental bundle but would leave the user-specified build
command and the existing release pipeline producing Swift-only artifacts.

`LaunchAgentServiceContractTests.swift`, lines 229–272, explicitly consumes both
scripts and checks their build, resource, signature and release verification steps.
Tests for the paired packaging can remain in the already allowed contract-test
directory. No entitlement, admission, capability or storage extension is proposed.

This is a delivery-scope gap identified from the current code, not a change to the
architecture's conclusions. Requested maintainer resolution: authorize those two
packaging entry points in the protected-main TASK-XPA-003 scope before implementation.
The checker reads production authority from base; changing head's allowlist alone
does not authorize these files. The user subsequently requested a PR for this scope correction. This PR adds only
these two exact Allowed paths and this record; it does not exercise the proposed
new authority. Compatibility note: this separately requested scope decision follows
the user's explicit instruction; implementation remains one vertical delivery.

## Commands and results

- `git status --short`: exit 0, initially clean; HEAD initially detached at the base above.
- `git fetch origin main`: initial sandbox attempt exit 255 because FETCH_HEAD was
  not writable; controlled escalation exit 0. Fetched main equals the stated base.
- `git switch -c agent/xpa-003-macos-facade-20260909 origin/main`: exit 0.
- Read-only source/contract inspection: facts above; no build or device invocation.
- The following calls the actual checker on the two proposed paths without making
  a synthetic commit or changing either file. Exit 1, expected scope refusal:

```bash
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
import check_pr_paths as checker
repo = Path.cwd()
base = '2893280895b6d8a0520a9f9c4d274dcd52ed8f73'
context = checker.PullRequestContext(
    'Implement macOS facade (TASK-XPA-003)', 'Task: TASK-XPA-003',
    'agent/xpa-003-macos-facade-20260909', base, base)
paths = [
    'Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh',
    'Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh',
]
try:
    checker.check_paths(repo, context, paths)
except checker.CheckError as error:
    print(error)
    sys.exit(1)
PY
```

Result: `declared task TASK-XPA-003 has paths outside Allowed paths` for both
scripts. The checker supplement permits new change/evidence namespaces, not an
extension of base-authorized production paths (`check_pr_paths.py`,
`vertical_change_supplement_patterns`). This probe is not the final committed-PR
preflight and is not an automatic approval-review rejection.

## Acceptance not executed

All items below remain pending because implementation stopped at packaging scope:

| Item | Result |
| --- | --- |
| XPA-AC-3, facade and Swift black-box subsets | Not run; no implementation build |
| XPA-AC-5, per-row IPC p95 versus SPK-1 | Not measured; no regression conclusion |
| XPA-AC-6, foreign euid, wrong XPC signature, private secret, forged origin | Not run |
| Per-frame foreground console and appXPC preservation | Not run |
| XPA-AC-7, before-forward kill window | Not run; no zero-dispatch claim |
| XPA-AC-7, after-forward/Swift interruption window | Not run; no journal/replay claim |
| XPA-AC-9, rollback, App Overview/History and CLI | Not run; no service update |
| GJ-1, GJ-2, GJ-3, GJ-4, GJ-5 | NOT_STARTED for this facade rerun; no Job IDs or new hardware result |
| SDD and unified local gate | Scope-PR validation recorded below; implementation acceptance remains pending |
| Final commit preflight and CI | Scope-PR results reported with the PR; no implementation acceptance claim |

Existing Swift/SPK-2 results are not reused as facade acceptance. No new
`gj-headless-rerun` JSON was written. GJ-4 additionally still requires the user's
explicit go before opening the destructive campaign window.

## Residual ownership and maintainer decisions

- TASK-XPA-003: packaging scope resolution, then all implementation and acceptance
  above. No TASK-XPA-012 or Windows work started.
- Design L.1 item 3: whether release signing requirements add the Developer ID
  intermediate certificate clause remains for the maintainer. The intended
  implementation uses the SPK-2 production-shaped anchor/team/identifier requirement.
- L.1 items 6 and 17: preserve App entitlements and the stated same-user boundary;
  no alternative trust model is proposed.

## Scope PR validation

- `sh scripts/check-sdd.sh`: exit 0; 0 errors, 0 warnings, 121 acceptance IDs.
  The existing primary-checkout SDD environment satisfied the dependency pins;
  no bootstrap or dependency installation was necessary.
- `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`:
  exit 0. Both documentation files were classified; public checks passed.
  Swift, App, design-system and Rust build lanes were not selected for this diff.
- The final committed scope diff is checked again before push. Its preflight and
  hosted check results are reported on the PR; the earlier expected refusal above
  concerns hypothetical script modifications, which this PR does not contain.
