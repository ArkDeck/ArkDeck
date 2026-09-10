# Verification — CHG-2026-076

> Change:CHG-2026-076-declared-scope-extension@r1
> Status:planned; nothing in this file approves the change.

## Environment

- Hosted runners of `.github/workflows/agent-pr.yml` (`actions/setup-python` 3.x) and the macOS
  reference host for the local run; Git ≥ 2.40.
- Fixtures: temporary Git repositories built by `scripts/test_check_pr_paths.py` with real commits;
  the shipped `scripts/automation_config.json`.

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| DSE-AC-01 in-band extension admitted | fixture repository: base Task `a/**`, head `tasks.md` adds `b/c/**`, commit trailer `Scope-Extension: b/c/**`, paths under both | Task returned; `scope_extension == ("b/c/**",)`; offenders empty | `evidence/runs/TASK-DSE-001/` |
| DSE-AC-02 every condition fails closed | negative matrix, one fixture per condition 1–7 of the proposal | `CheckError` naming the condition; no partial admission | same |
| DSE-AC-03 two declaration sources agree | preflight (commit body) and event mode (PR body) on one fixture; mismatch and one-sided cases | agree → pass; otherwise error naming the source | same |
| DSE-AC-04 configuration | missing key, empty list, non-string, duplicate, old schema; shipped file | every guard run fails on a bad table, including a task-declared PR with no offenders; shipped file equals the anchor | same |
| DSE-AC-05 reporting | stderr block, `--scope-extension-summary`, workflow body and step-summary steps | block present iff `E` non-empty; workflow contract tests green | same |
| DSE-AC-06 documentation and no other change | `AGENTS.md` bullet; module docstring; full existing suites | suites green; no change to undeclared-path, supplement, archive or bootstrap behaviour | same |

## Negative and recovery tests

- Failure injection: each condition of the rule; a broken configuration; a confusable trailer token.
- No cancellation, crash or device paths exist for a CI guard.
- Privacy and secret scan: not applicable (no secrets handled).

## Deviations

Any deviation is written here and confirmed in the PR review; no implicit exemption.

## Result gate

- [ ] DSE-AC-01..06 passed with reviewable evidence
- [ ] The live probe on real commits recorded (one admitted extension, one refused kernel attempt)
- [ ] `AGENTS.md` wording merged with the implementation
