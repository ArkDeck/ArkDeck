# Verification — CHG-2026-077

> Change:CHG-2026-077-retire-pr-path-guard@r1
> Status:planned; nothing in this file approves the change.

## Environment

- Hosted runners of `.github/workflows/agent-pr.yml` and `.github/workflows/sdd-guard.yml`
  (`ubuntu-latest`, runner Python 3.x) and the macOS reference host for the local run; Git ≥ 2.40.
- Fixtures: JSON payloads shaped like the GitHub pull-request API and a temporary Git repository,
  both built by `scripts/test_agent_pr_identity.py`; the `scripts/host_loop` suite's fake API.

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| RPG-AC-01 guard retired | `git grep` for the three names over the head tree, excluding archive and historical records; contract-test mutations reinserting a job or the script name | only historical prose remains; every mutation raises `WorkflowContractError` | `evidence/runs/TASK-RPG-001/` |
| RPG-AC-02 PR identity fail-closed | pull-list and identity matrices; CLI read-back with the comparison suspended | each mismatch names its field; the printed number is the response's | same |
| RPG-AC-03 `Task:` is traceability | `--commit-task` on fixture commits | first token or `none`; no `tasks.md` lookup, no failure | same |
| RPG-AC-04 host loop | `scripts/host_loop` suite; verdict table under the two-name fixture set; production-set class | `("guard",)`; documented shapes green / failed / pending as listed in tasks.md | same |
| RPG-AC-05 documentation and live probe | text assertions on the five governance texts; the retired checker run against a base with and without this proposal | no preflight / scope-PR instruction left; probe passes with `TASK-RPG-001` and refuses without it | same |

## Negative and recovery tests

- Failure injection: each identity mismatch; zero and several open pull requests; a malformed
  paginated list; a workflow with a second job or a reinserted retired name.
- No cancellation, crash or device paths exist for a CI workflow.
- Privacy and secret scan: not applicable (no secrets handled; the workflow's permissions do not
  widen).

## Deviations

Any deviation is written here and confirmed in the PR review; no implicit exemption.

## Result gate

- [ ] RPG-AC-01..05 passed with reviewable evidence
- [ ] The live probe recorded (declaration covers the diff; the two-step refusal shown once more)
- [ ] `scripts/agent-guides/contributing.md` wording merged with the implementation
