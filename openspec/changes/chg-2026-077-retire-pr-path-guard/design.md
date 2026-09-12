# Design — CHG-2026-077 retire the PR allowed-paths guard

## Context and constraints

- Proposal revision 1; `class: implementation-only`, `core_change_level: none`, CORE-3.0.0.
- Related: `scripts/check_pr_paths.py` (TASK-MECH-004 lineage; TASK-DEC-001 moved the sensitive
  table to `automation_config.json`; TASK-DEC-004 closed the allowlist half of B-H2 by reading Task
  definitions from the base tree; TASK-DSE-001 / CHG-2026-076 added declared scope extension and
  merge-base comparison), `.github/workflows/agent-pr.yml`, `.github/workflows/sdd-guard.yml`,
  `scripts/host_loop/worker.py` (`REQUIRED_PR_CHECKS`, the HLR-003 verdict table),
  `scripts/agent-guides/contributing.md`.
- Repository evidence: 25 path-only pull requests since 2026-08-01 (proposal); B-H2 kept open in
  the checker's docstring; `guard` is the only required status check.

## Requirement mapping

| Requirement / AC | Design component | Verification |
| --- | --- | --- |
| RPG-AC-01 guard retired | deletions; both workflows; `test_agent_pr_workflow.py` forbidden names | `git grep` over the head tree; contract-test mutations |
| RPG-AC-02 PR identity stays fail-closed | `scripts/agent_pr_identity.py` `--pull-list` / `--pull-request`; `open-pr` wiring | identity matrix, pull-list matrix, CLI read-back tests carried over from the retired suite |
| RPG-AC-03 `Task:` is traceability only | `--commit-task <revision>` | subject with / without / with several tokens; no `tasks.md` lookup |
| RPG-AC-04 host loop | `REQUIRED_PR_CHECKS = ("guard",)`; verdict table under a two-name fixture set | `scripts/host_loop` suite; documented push / edited shapes |
| RPG-AC-05 documentation and live probe | the listed texts; evidence run record | text assertions; the retired checker run once more against a base carrying this proposal |

## Architecture and data flow

After the change, a push to `agent/**` does exactly this in `open-pr`: read the first task token of
the final commit subject (`agent_pr_identity.py --commit-task`, or `none`); list the open pull
requests for the branch and select the unique one (`--pull-list`, with `--allow-zero` before
creation); create the pull request when there is none, with the optional `Task:` line and the
standard body; list again and require exactly one; read the pull request back and validate its
identity (`--pull-request` with the six expectations); publish the number. No diff is computed and
no `tasks.md` is read. `sdd-guard.yml` keeps `guard` and `ds-tokens`; `guard` gains one step running
the helper's tests. The `pull_request: [reopened, edited]` trigger stays because the host loop's
check dispatch (an `edited` body update) is how a merge-ref `guard` run is obtained, and the verdict
table still lets that run fail a round.

`scripts/agent_pr_identity.py` is the identity half of the retired checker, unchanged in behaviour:
`select_unique_pull_request_number`, `validate_pull_request_identity`,
`pull_request_context_from_object` and the JSON / shape helpers, plus `commit_task_declaration`,
which runs `git log -1 --pretty=%s` on the head OID and returns the first `TASK_TOKEN_TEXT` match.
The token grammar stays byte-identical to `scripts/host_loop/instance.py`; the parity test that
used to load the checker loads the helper.

The host loop keeps its claim gate "no declared allowed paths → not claimable" (reader-only; it
grants nothing) and its dispatch logic; only the required-check set shrinks. With one required
name, a push head whose `guard` executed successfully is green without a dispatch, and a head whose
`guard` is still in flight receives exactly one dispatch, as before.

## Data and contract changes

- Deleted: `scripts/automation_config.json` (`arkdeck-automation-config/v2`) and its loader; the
  `Scope-Extension:` trailer; the one-time bootstrap tuple; the `--preflight`, `--event`,
  `--infer-task`, `--allow-bootstrap` and `--scope-extension-summary` modes.
- Kept, moved: `--pull-list [--allow-zero]` and the `--pull-request --expected-*` identity mode
  (the `--identity-only` flag disappears because identity is now the only thing that mode does).
- New: `--commit-task <revision>`.
- No durable format, wire contract, Catalog or spec changes.

## Authority and production reachability

Not applicable: the change is to a repository CI guard and a PR-opening workflow; no production
composition root, authority, capability or effect dispatch is involved.

- Production composition root: not applicable (no product code path).
- Authority 产生点: unchanged — maintainer review + merge into protected `main`.
- Effect dispatch point: not applicable.
- Fake/simulation 与 production 的结构差异: the helper's tests use JSON payloads shaped like the
  GitHub API responses the workflow reads, and a real temporary Git repository for the commit
  subject; there is no fake path in production.
- Facts/provenance: the pull request identity comes from the GitHub API read-back pinned to the
  pushed ref and OID; the commit subject is data written by the pull request under review, which
  is why the `Task:` line is never treated as authority.

## Failure, cancellation, and recovery

`open-pr` either publishes a validated number or fails the run with a named reason; a failed run
opens nothing and leaves nothing to reconcile (the next push retries create-or-find). There is no
cancellation or crash path beyond the runner's own.

## Security and privacy

- The identity checks that keep the bot from acting on the wrong pull request are unchanged and
  keep their tests; untrusted fields are still parsed from JSON in Python.
- The trust root (`scripts/**`, `.github/**`, `AGENTS.md`) and the security kernel are no longer
  mechanically two-step. They were never mechanically protected against a deliberate change (B-H2);
  the maintainer's review of the diff is, and stays, the control.
- No secrets, logs or device data are involved. Workflow permissions do not widen; the retired job
  had `pull-requests: read`, the surviving one keeps `contents: read` + `pull-requests: write`.

## Alternatives and ADRs

- Keep the guard and widen `never_self_extend` exceptions or Allowed paths further: still one
  round-trip per unforeseen path for the trust root and kernel, and CHG-2026-074 r9 / CHG-2026-076
  already tried both halves; rejected.
- Make the check advisory (non-blocking): a red advisory still stops honest agents and still
  produces scope PRs, and it keeps about 5,000 lines of checker and tests for a signal the reviewer
  gets from the diff; rejected.
- Run the guard from a trusted checkout to close B-H2: closes the wrong problem — the cost is the
  honest path, not the bypass; rejected.
- Retire the host loop's footprint claim gate in the same change: separable, and the loop is the
  one remaining reader of the field; deferred (maintainer decision 3).
- No new ADR: the decision is recorded here and in `scripts/agent-guides/contributing.md`.
