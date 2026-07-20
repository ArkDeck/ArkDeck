# TASK-GUARD-001 implementation preflight blocker

- Date:2026-07-20 (Asia/Shanghai)
- Base:`c250265b0d961951cd7d989844c423952bb65f58`
- Classification:host-only/offline governance preflight;read-only;not acceptance evidence
- Device/network/destructive dispatch:0
- Environment:`<MAIN_CHECKOUT>/.venv-sdd/bin/python`,CPython 3.14.6,
  PyYAML 6.0.3

## Method

Before editing `scripts/check_sdd.py`,a temporary read-only script implemented the approved
design §2 literally:

1. load every `openspec/changes/chg-*/scope.yaml`;
2. collect the complete `acceptance:` set;
3. scan each `tasks.md` claim surface beginning with `- Requirements/AC:` through its
   indented continuation lines,stopping at the next top-level `- ` bullet;
4. extract only exact tokens matching `AC-[A-Z0-9]+-\d+-\d+`;
5. report `scope acceptance - claimed` without editing repository data.

The preflight intentionally did not infer claims from `等`,wildcards,ranges,slash shorthand,
or non-`Requirements/AC:` text. Such inference is absent from the approved design and would
turn a fail-closed traceability check into a false-negative source.

Commands:

```text
<FIXED_PYTHON> /private/tmp/chg017_scope_preflight.py
ARKDECK_PYTHON=<FIXED_PYTHON> scripts/check-sdd.sh
git status -sb
```

## Results

| Change | Scope acceptance | Exact claimed `AC-*` tokens | Missing scope acceptance |
| --- | ---: | ---: | ---: |
| CHG-2026-001 | 28 | 8 | 20 |
| CHG-2026-002 | 68 | 58 | 10 |
| CHG-2026-005 | 1 | 1 | 0 |
| CHG-2026-006 | 5 | 0 | 5 |

Named missing identifiers:

- CHG-2026-001:`AC-HDC-001-02`,`AC-HDC-003-02`,`AC-HDC-004-01`,
  `AC-HDC-009-01`,`AC-HDC-010-01`,`AC-HDC-010-02`,`AC-HDC-010-03`,
  `MAC-M0A-DIST-001`,`MAC-M0A-HDC-001`,`MAC-M0A-HDC-002`,
  `MAC-M0A-JOURNAL-001`,`MAC-M0A-POWER-001`,`MAC-M0A-PROC-001`,
  `MAC-M0A-RUNTIME-001`,`MAC-M0A-SANDBOX-001`,`MAC-M0A-SHELL-001`,
  `MAC-M0A-TRUST-001`,`MAC-M0A-TRUST-002`,`MAC-M0A-TRUST-003`,
  `MAC-M0A-TRUST-004`.
- CHG-2026-002:`AC-JOB-001-03`,`AC-JOB-001-04`,`AC-JOB-001-06`,
  `AC-JOB-001-07`,`MAC-M1-DIAG-001`,`MAC-M1-HDC-001`,`MAC-M1-JOURNAL-001`,
  `MAC-M1-PORTS-001`,`MAC-M1-SIM-001`,`MAC-M1-STORE-001`.
- CHG-2026-005:none.
- CHG-2026-006:`HW-M0B-DAYU200-AUTH-001`,`HW-M0B-DAYU200-DISCOVERY-001`,
  `HW-M0B-DAYU200-RAWCAPTURE-001`,`HW-M0B-DAYU200-SUPERVISOR-001`,
  `HW-M0B-DAYU200-UIDUMP-PROBE-001`.

The unchanged pre-implementation guard remained green:

```text
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs
```

## Conclusion

`GUARD-SCOPE-COVERAGE-001` was not executed and remains pending. Implementing the approved
algorithm would add 35 errors to the current baseline,contradicting the approved zero
false-positive gate. TASK-GUARD-001 therefore fails its readiness premise and must remain
blocked until an approved grammar revision and explicit legacy traceability remediation are
merged,followed by a new readiness review.

## Deviations and residual risk

- No implementation file,test,spec,contract,baseline,legacy task,scope file,device,or network
  was changed or invoked.
- The temporary preflight script lives outside the repository and is not an implementation
  artifact;the exact algorithm and complete named output are recorded above.
- Treating shorthand or `等` as implicit coverage would hide real ownership gaps and is not an
  acceptable workaround.
