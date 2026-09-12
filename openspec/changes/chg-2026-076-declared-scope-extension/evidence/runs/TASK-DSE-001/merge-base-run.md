# TASK-DSE-001 run record — compare pull requests at the merge-base

- Date: 2026-09-12
- Base: protected `main` `9831fee5` (#1871). The branch itself was cut at `33808eb9` (#1869) and
  deliberately not rebased: it is the case this record is about.
- Maintainer request: a pull request whose base is not the latest `main` commit was refused by the
  guard (`pull_request base … is not an ancestor of head …; rebase the branch on the base commit`)
  although nothing in the pull request needed the rebase. Remove that restriction.
- Delivered in one PR under this Task's Allowed paths: `scripts/check_pr_paths.py`,
  `scripts/test_check_pr_paths.py`, this record. No workflow, config or `AGENTS.md` change.

## What the guard does now

`assert_base_is_ancestor()` is gone. Every mode resolves the compared base first with
`resolve_merge_base(repo_root, base, head)` = `git merge-base base head` and uses that commit for
the diff and for the base-tree Task definitions: the preflight rebinds `--base-revision` (the
workflow passes `origin/main`), event and API mode rebind `base.sha` after the identity checks.
When the base already is an ancestor of the head, the merge-base is the base itself and nothing
changes. A base sharing no history with the head fails closed (`share no history`).

Why this keeps the B-H4 property (the pull request cannot choose the compared base): the
measured substitution pointed the base at a side branch already carrying the offending file, and
a raw `git diff side..head` dropped the file. The merge-base of that side branch and the head is
their last common trunk commit, where the file is new again, so the substitution no longer hides
anything — it is neutralised rather than refused. A base that is an ancestor of the head off
`main` is already excluded by the identity checks that pin `base.ref` to `main` in API mode and
by the workflow passing `origin/main` to the preflight, exactly as before.

The one-time bootstrap tuple is matched on the base as given, not on the merge-base: a branch
cut from the pinned old `main` keeps that OID as its merge-base for ever, and the fuse must stay
blown once `main` moved away from it (`test_one_time_bootstrap_matches_the_base_as_given_not_the_merge_base`).

## Verification

| Check | Result |
| --- | --- |
| `python3 scripts/test_check_pr_paths.py` | 84 tests OK (81 before; the two B-H4 cases rewritten around the merge-base, plus `test_a_base_sharing_no_history_with_the_head_fails_closed`, `test_a_branch_behind_an_advanced_main_is_judged_on_its_own_changes` and the bootstrap fuse case) |
| `python3 scripts/test_agent_pr_workflow.py` | 12 tests OK, workflow text unchanged |
| `python3 scripts/ci/plan.py --merge-base --include-worktree --run-local` | common checks only; the planner selects no compiled lane for this diff |

`test_a_branch_behind_an_advanced_main_is_judged_on_its_own_changes` is the requested case in
both modes: a docs-only head whose `main` moved on with a sensitive change passes with
`task=none (docs/governance-only); changed_paths=1` (event mode) and prints `none` (preflight),
whereas the raw diff against the advanced tip would have charged `scripts/reach.py` to it. The
converse is pinned in the same test: a head adding a byte-identical copy of the sensitive file
`main` added is still refused with `touches sensitive paths: scripts/reach.py`, although the raw
diff against the advanced tip is empty.

## Live probe on real commits

A scratch worktree cut from `a3b384d3` (#1865, five commits behind `origin/main` `9831fee5`)
with one docs-only commit `7cdf8e0a` appending a line to `docs/README.md`; merge-base with
`origin/main` = `a3b384d3`. Both checkers ran against `--base-revision origin/main`; the old one
is the checker committed at `a3b384d3` itself. The worktree was removed afterwards.

```text
old preflight: check_pr_paths: ERROR: pull_request base 9831fee5… is not an ancestor of head 7cdf8e0a…; rebase the branch on the base commit   (exit 1)
new preflight: none                                                                                                                              (exit 0)
old event mode (base.sha = 9831fee5…): the same ancestor error                                                                                  (exit 1)
new event mode (base.sha = 9831fee5…): check_pr_paths: PASS; task=none (docs/governance-only); changed_paths=1                                    (exit 0)
```

A second scratch commit on the same behind-`main` branch adding `scripts/probe_sensitive.py`:

```text
new preflight: check_pr_paths: ERROR: preflight found no base-tree active task whose Allowed paths cover the full diff; sensitive paths: scripts/probe_sensitive.py; closest base-tree task(s): …   (exit 1)
```

The sensitive path is named and refused as before; being behind `main` is no longer itself a
reason to refuse.
