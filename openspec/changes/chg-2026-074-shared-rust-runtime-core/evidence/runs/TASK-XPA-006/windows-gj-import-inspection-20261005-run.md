# Windows GJ import inspection reader — 2026-10-05

The current CLI returns `arkdeck.import-inspection/1` with the Import under
`result.import`. GJ-3's rollback fixture judge read the former bare Import shape,
so an applicable fixture captured by the current CLI was reported as missing.
The reader now selects the captured request and reads the published nested
projection and schema versions. It checks receipt identity/content consistency
and retains the pinned digest, target/binding, build ID, loaded ABI, consumed
lease, atomic publication and restore criteria. Bare or malformed projections
remain refused. No operation, schema, fixture pin or hardware record changes.

## Local targeted checks

- Old reader reproduction: `python D:\src\ArkDeck-wt\tools\gj3\reproduce_old_inspection_judge.py`
  ran the updated positive synthetic case against unchanged main `91d3446d9`;
  exit 1 at `fixture import` (`IMPLEMENTING` instead of the expected pass).
  Log: `D:\src\ArkDeck-wt\tools\logs\gj-judge-published-reproduction.log`.
- `python -m unittest discover -s gj_record -t .` from `scripts`: 43 tests passed,
  exit 0 in 58.8 seconds, including identity, digest, ABI, target/binding, lease,
  malformed/bare projection, missing build ID, publication and released-state
  cases. Log: `D:\src\ArkDeck-wt\tools\logs\gj-judge-tests-final.log`.
- The synthetic inspection is derived from the committed producer corpus;
  `check_inspection_schema.py` validates it against the unchanged published
  `artifact.import.inspection` result schema, exit 0.
  Log: `D:\src\ArkDeck-wt\tools\logs\gj-judge-schema.log`.
- `git diff --check`: exit 0.
- `C:\Program Files\Git\usr\bin\sh.exe scripts/check-sdd.sh`: exit 0,
  0 errors and 0 warnings. Log: `D:\src\ArkDeck-wt\tools\logs\gj-judge-sdd-explicit.log`.
  The initial bare `sh` launch did not start (`WinError 2`); using the existing
  explicit Git-for-Windows interpreter completed the same check.

All journals here are synthetic test inputs. No production CLI, Runtime, HDC,
Harmony tool, device, capability store, trusted facts or secret was accessed.
These results are not real-device acceptance.

## CI

Not run: this owned increment has not been pushed. Root reviews and publishes
it; the SDD Guard's existing Golden Journey recorder step runs the same suite.
No CI or hardware-pass claim is made in this record.
