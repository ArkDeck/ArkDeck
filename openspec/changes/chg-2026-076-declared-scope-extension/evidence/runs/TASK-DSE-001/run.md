# TASK-DSE-001 run record — declared scope extension

- Date: 2026-09-10
- Base: protected `main` `dcae1e63` (CHG-2026-076 proposal merged as #1837).
- Delivered in one PR: `scripts/check_pr_paths.py`, `scripts/automation_config.json`
  (`schema` → `arkdeck-automation-config/v2`, new `never_self_extend`), `scripts/test_check_pr_paths.py`,
  `.github/workflows/agent-pr.yml`, `scripts/test_agent_pr_workflow.py`, one bullet in the
  "提交与 PR" section of `AGENTS.md`, this record and the task status.

## What the guard does now

After the vertical-change supplement declines, `declared_scope_extension()` reads the
`Scope-Extension:` trailers of the declaration body (the final commit body in preflight, the PR
body in event mode). With no trailer the original refusal stands unchanged. With trailers it
requires, in this order and each with its own named `CheckError`: the Task still active in the
head tree; no base pattern removed; the head `tasks.md` adds patterns; the trailer set equal to
the added set; at most 8 patterns; every pattern bounded (no leading `/`, no `.`/`..`, a fixed
prefix at least two segments deep whose directory exists in the base tree); no pattern already
covered by the base Allowed paths; no overlap with `never_self_extend` (fixed-prefix overlap in
either direction, the pattern text matching an entry, or any admitted changed path matching an
entry); and every offender covered by the extension. `CheckResult.scope_extension` carries the
admitted patterns; the preflight prints a `SCOPE EXTENSION` line to stderr and
`--scope-extension-summary` writes a Markdown block (empty when none). The workflow copies the
trailers into the PR body after `Task:` and appends the block to the step summary. An inferred
task with trailers is refused before any inference. Both config tables are validated on every
load, so a malformed `never_self_extend` fails every guard run.

## Verification

| AC | Method | Result |
| --- | --- | --- |
| DSE-AC-01 | `DeclaredScopeExtensionTests.test_declared_extension_is_admitted_and_reported` (glob and exact-path forms) | pass |
| DSE-AC-02 | `test_without_a_trailer_the_original_refusal_stands`, `test_trailers_must_equal_the_added_patterns` (extra, missing, repeated, non-ASCII), `test_a_trailer_without_a_tasks_change_is_refused`, `test_removing_base_patterns_is_refused`, `test_unbounded_patterns_are_refused` (`**`, `*`, `tools/**`, leading `/`, `..`, non-existent prefix), `test_never_self_extend_is_refused_in_both_directions` (kernel file inside, kernel directory above, prefix-less entry against admitted paths, unrelated entries pass), `test_limits_no_ops_and_uncovered_paths_are_refused` (nine patterns, no-op, uncovered offender) | pass |
| DSE-AC-03 | `test_preflight_reads_the_commit_body_and_inferred_tasks_cannot_extend` (preflight admits from the commit body; a PR body without the trailer keeps the original refusal; an inferred task is refused) | pass |
| DSE-AC-04 | `AutomationConfigTests.test_shipped_config_parses_to_the_anchor_exactly` (both tables), `test_never_self_extend_shapes_each_fail_closed_on_every_load` (missing key, empty, non-string, duplicate, old schema — both loaders refuse); the existing sensitive-path matrix unchanged | pass |
| DSE-AC-05 | `test_command_line_reports_and_writes_the_summary` (stderr line, Markdown block, empty file when none); `scripts/test_agent_pr_workflow.py` pins the body-copy line, the `--scope-extension-summary` argument and the step-summary append, and their order | pass |
| DSE-AC-06 | `AGENTS.md` bullet present; module docstring updated; `python3 scripts/test_check_pr_paths.py` 81 tests OK; `python3 scripts/test_agent_pr_workflow.py` 11 tests OK; no change to the undeclared-path, supplement, archive or bootstrap tests | pass |

Existing trust-boundary test `test_a_pull_request_cannot_widen_its_own_allowed_paths` still
passes: widening to `**` without a trailer is the original refusal, and even with a trailer `**`
is refused as unbounded.

## Live probe on real commits

Three scratch commits on top of the implementation, each preflighted against `origin/main`
(`dcae1e63`) with the checker under test, then discarded.

1. `TASK-DSE-001` adds `docs/design/**` to its Allowed paths, touches `docs/design/dse-live-probe.md`,
   commit body `Scope-Extension: docs/design/**`:

```text
exit 0
stdout: TASK-DSE-001
stderr: check_pr_paths: SCOPE EXTENSION: TASK-DSE-001 adds 1 pattern(s): docs/design/**
```

   `--scope-extension-summary` wrote:

```text
### Scope extension declared by TASK-DSE-001

This pull request adds the following Allowed paths to its Task and uses them in the same change. The declaration is not authority: review the extended files before merging.

- `docs/design/**`
```

2. The same, plus `scripts/ci/**` and `scripts/ci/dse-live-probe.txt` with a second trailer:

```text
exit 1
check_pr_paths: ERROR: scope extension pattern scripts/ci/** overlaps never_self_extend entry scripts/**
```

3. The first probe's tree with the trailer removed from the commit body:

```text
exit 1
check_pr_paths: ERROR: declared task TASK-DSE-001 has paths outside Allowed paths: docs/design/dse-live-probe.md
```

## Deviations and residuals

- None to the rule. The initial `never_self_extend` list is the proposal's; editing it is a
  change to `scripts/automation_config.json` under this Task's lineage or a maintainer PR.
- The B-H2 code half (the checker runs from the head checkout) is unchanged and still
  compensated by human review of any diff touching `scripts/**` — which `never_self_extend`
  now also keeps outside in-band extension.
