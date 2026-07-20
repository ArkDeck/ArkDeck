# CHG-017 r2 legacy traceability remediation

- Date:2026-07-20 (Asia/Shanghai)
- Base:`d568800d49775482a5cc7ac8efc098c7587a7fb4`
- Classification:host-only/offline governance remediation;not implementation or
  acceptance evidence
- Device/network/destructive dispatch:0
- Environment:`<MAIN_CHECKOUT>/.venv-sdd/bin/python`,CPython 3.14.6,
  PyYAML 6.0.3

## Scope

The r2 exact-matching preflight found that only two legacy task ledgers still relied on
shorthand or omitted complete scope identifiers:

| Change | Missing before | Missing after |
| --- | ---: | ---: |
| CHG-2026-001 | 16 | 0 |
| CHG-2026-002 | 4 | 0 |
| CHG-2026-005 | 0 | 0 |
| CHG-2026-006 | 0 | 0 |

The remediation changed only:

- `openspec/changes/chg-2026-001-macos-m0a/tasks.md`;
- `openspec/changes/chg-2026-002-macos-m1-infrastructure/tasks.md`.

Existing verification matrices determined the owning tasks. The edit expanded complete
acceptance IDs for M0A Process/HDC supervisor/Runtime/Trust ownership and M1
`AC-JOB-001-01…07`. It did not derive new ownership, alter evidence, change task/change status,
or modify a scope list.

## Verification

Commands:

```text
<FIXED_PYTHON> /private/tmp/chg017_r2_scope_preflight.py
ARKDECK_PYTHON=<FIXED_PYTHON> scripts/check-sdd.sh
git diff --check
```

Exact scope result after remediation:

```text
chg-2026-001-macos-m0a: scope=28 missing=0
chg-2026-002-macos-m1-infrastructure: scope=68 missing=0
chg-2026-005-hdc-parser-golden-registration: scope=1 missing=0
chg-2026-006-dayu200-m0b-bringup: scope=5 missing=0
```

Repository guard result:

```text
check_sdd: 0 error(s), 0 warning(s), 111 acceptance IDs
```

## Conclusion

The legacy traceability remediation gate is satisfied by the candidate diff, subject to
maintainer review and merge. `TASK-GUARD-001` remains `blocked`; this record does not restore
readiness, implement the guard, or pass `GUARD-SCOPE-COVERAGE-001`. A separate readiness PR
must re-run the same exact baseline from merged `main`.

## Deviations and residual risk

- CHG-2026-005 and CHG-2026-006 were already exact under r2 and were not modified.
- Existing abbreviated requirement identifiers such as `REQ-ART-001…006` are outside the
  acceptance-only CHG-017 check and remain unchanged.
- The preflight script is temporary and outside the repository;the approved r2 algorithm and
  complete before/after counts are recorded here.
