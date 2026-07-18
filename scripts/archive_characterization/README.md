# DAYU200 archive characterization scanner

CHG-2026-003 / TASK-DAYU200-CHAR-001 (executed and archived 2026-07-18).
Offline, read-only research tooling; Python 3 stdlib only (repository-pinned
CPython, see `.python-version`).

- `scan.py` — production scanner/CLI. Fixed identity gate (732948803 bytes,
  SHA-256 `fc7637f34a8394847b1b6c7e7ff2750863d18c6dc05e184abaf5aed70ec75280`),
  strict streaming tar inventory with the fixed `ARC001..ARC009` hazard codes,
  the closed six-condition `imagePackageFamily` rule, and the five allowed
  evidence outputs. No shell, no subprocess, no network, no extraction to disk,
  no member execution; the archive locator is never written to evidence.
- `schemas/` — the four closed evidence schemas (validated before writing).
- `fixtures.py` — deterministic in-memory synthetic fixtures (hazard and
  classification vectors). Test input only; never real vendor bytes.
- `test_scan.py` — branch-complete unit tests plus a static import/AST audit.

Usage (the caller supplies the external archive locator at execution time):

```
python3 scripts/archive_characterization/scan.py \
  --archive /path/to/vendor-archive.tar.gz \
  --out-dir /path/to/evidence-out-dir
```

The executed CHG-2026-003 run's evidence lives (immutable) under
`openspec/changes/archive/2026-07-18-chg-2026-003-dayu200-image-characterization/evidence/`;
do not write new output there. A rerun only produces governed evidence inside
the `evidence/` directory of whatever open change sanctions it.

Run tests:

```
python3 scripts/archive_characterization/test_scan.py
```

The result is fixed-archive-only and non-authoritative: `unknown` is a valid
output, Provider/target compatibility stay unknown, and nothing here creates a
DEC-002, M0B or hardware-support claim.
