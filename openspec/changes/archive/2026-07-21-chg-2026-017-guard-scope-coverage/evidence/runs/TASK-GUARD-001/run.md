# TASK-GUARD-001 scope coverage guard implementation run

- Change:`CHG-2026-017-guard-scope-coverage@r2`
- Task:`TASK-GUARD-001`
- Executed:2026-07-20 23:42 CST (Asia/Shanghai) by Codex Agent
- Base revision:`f2edf9d69658e38d92080617ba62c9c91cd058e1`
  (`main`, readiness restoration PR #186 merged)
- Branch:`agent/chg-017-scope-coverage-implementation`
- Environment:CPython 3.14.6,PyYAML 6.0.3
- Classification:host-only/offline guard implementation;hardware required=no
- Device/network/destructive dispatch:0 / 0 / 0

## Readiness and pre-implementation baseline

The approved r2 change and `TASK-GUARD-001` `ready` state were present at the base revision.
Before editing the guard,the r2 exact preflight reported:

```text
chg-2026-001-macos-m0a: scope=28 missing=0
chg-2026-002-macos-m1-infrastructure: scope=68 missing=0
chg-2026-005-hdc-parser-golden-registration: scope=1 missing=0
chg-2026-006-dayu200-m0b-bringup: scope=5 missing=0
```

The unmodified base guard reported:

```text
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs
```

## Implementation result

`scripts/check_sdd.py` now checks every `chg-*` directory that contains `scope.yaml`.
Each non-empty,string-valued `acceptance` entry is treated as an opaque,case-sensitive ID and
is dynamically escaped and matched only within top-level `- Requirements/AC:` bullets and their
indented continuation lines,using the approved ASCII identifier boundaries. Missing IDs emit the
approved named error at that change's `scope.yaml` and join the existing error counter.

The check remains one-directional (`scope acceptance ⊆ claimed`),skips changes without
`scope.yaml`,does not enumerate acceptance prefixes,and does not infer IDs from shorthand or
natural language. It is invoked by the normal `check_sdd.py` main flow before lock/conformance
checks.

`scripts/test_check_sdd.py` adds seven offline stdlib/PyYAML tests covering:

- exact `AC-*`/`MAC-*`/`HW-*` and future opaque-ID claims;
- backticks,Chinese/ASCII delimiters,spaces,and indented continuation lines;
- one omitted ID producing exactly one named error and producing no error after restoration;
- prefix/suffix identifier sticking and case mismatch rejection;
- tokens outside `Requirements/AC` claim surfaces being ignored;
- `…`,`*`,`01/02`,and `等` shorthand not claiming unwritten IDs;
- no-scope skip plus the exact four-change real baseline and full main-flow `0/0/111` result.

## Verification commands and results

| Command | Result |
| --- | --- |
| `<FIXED_PYTHON> scripts/test_check_sdd.py` | PASS;7 tests,0 failures;includes enhanced real-repository main flow |
| `<FIXED_PYTHON> scripts/test_check_sdd.py ScopeCoverageTests.test_one_missing_id_emits_one_named_error_then_restores -v` | PASS;1 focused test,0 failures;omission produced exactly one error naming `AC-X-003-01`,then restoration produced zero errors |
| `ARKDECK_PYTHON=<FIXED_PYTHON> scripts/check-sdd.sh` | PASS;`0 error(s),0 warning(s),111 acceptance IDs` after enhancement |
| `git diff --check` | PASS |
| allowed-path audit | PASS;only guard,test,and this task's evidence path changed |

`<FIXED_PYTHON>` is
`<MAIN_CHECKOUT>/.venv-sdd/bin/python` (CPython 3.14.6,PyYAML 6.0.3).

## Acceptance conclusion

| Test ID | Candidate result | Reviewable evidence |
| --- | --- | --- |
| `GUARD-SCOPE-COVERAGE-001` | PASS | seven positive/negative tests;focused named-error/restoration run;four real scoped changes with missing=0;enhanced main guard remains 0/0/111 |

This is implementation evidence subject to maintainer review and merge. It does not itself mark
the task `done` or the change `verified`.

## Deviations and residual risk

- Deviations:none.
- No spec,contract,baseline,product,legacy change ledger,scope list,or task status was modified.
- This run used only temporary local fixture directories;it accessed no device or network and
  executed no destructive operation.
- Residual risk is limited to parser false positive/negative behavior. The approved exact-boundary,
  interference,shorthand,and current-main fixtures cover the declared r2 grammar. New claim syntax
  would require an explicit reviewed grammar revision rather than inference by this guard.
- Per the approved PR boundary,`TASK-GUARD-001` remains `ready`. After this implementation PR is
  reviewed and merged,a separate status-only PR may propose `ready→done` with this run reference.

## Rollback

The clean pre-implementation rollback point is
`f2edf9d69658e38d92080617ba62c9c91cd058e1`. Reverting the eventual single implementation merge
removes the guard,test,and this run record without changing any spec,contract,product,scope,or
legacy task data.
