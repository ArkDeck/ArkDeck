# Record the final CI of #2307–#2314 and refresh the macOS dashboard

TASK-XPA-017, docs-only, base `d247f62a6` (#2314), 2026-09-29.

## What changed

- The pending "CI" sections of the run records for #2307
  (`flash-recovery-broker-execute-run.md`), #2308 (`TASK-XPA-019/spk8-negatives-run.md`),
  #2309 (`retire-facade-mode-run.md`), #2310 (`rc-readiness-run.md`), #2311
  (`TASK-XPA-018/retire-swift-cli-run.md`), #2312 (`retire-swift-runtime-run.md`) and
  #2314 (`facade-leftovers-run.md`) now name the final head, the Swift CI and SDD Guard
  runs (all `success`) and the merge commit, read with `gh pr view` and
  `gh run list --commit <head>`. #2313 (contract parity as its own CI job) has no run
  record; its merge `0cfea204a` is in the dashboard History.
- `macos-remaining.md` is refreshed to `d247f62a6`: Swift targets deleted 0/6 → 6/6, the
  M5 row and the XPA-017/XPA-018 rows, and a History entry. The other counts are
  unchanged.

| PR | Head | Swift CI | SDD Guard | Merge |
| --- | --- | --- | --- | --- |
| #2307 | `12cd6e6e2` | 36427055435 | 36427054721 | `6edb4e479` |
| #2308 | `289fcb0f7` | 36430301497 | 36430301088 | `f574ad984` |
| #2309 | `1ba6df618` | 36435219467 | 36435218789 | `0359580e3` |
| #2310 | `2a57e18bb` | 36438602989 | 36438602042 | `2f75ae8e5` |
| #2311 | `e57377491` | 36440456252 | 36440455385 | `32db20b10` |
| #2312 | `9cfd2fe0d` | 36449252325 | 36449252163 | `57ba8e36f` |
| #2313 | `a95d4b54b` | 36450323715 | 36450322937 | `0cfea204a` |
| #2314 | `60974c7f2` | 36453518871 | 36453518475 | `d247f62a6` |

## Local targeted checks

| Command | Exit |
| --- | --- |
| The dashboard's PYCOUNT with `ref = d247f62a6…`, run twice | 0, identical output: routes 105 / 105, parser names 199, registered 140 / 256, ClientKit facades 16, Workflows facades 0, App and pbxproj `ArkDeckWorkflows` 0 / 0, Swift targets deleted 6 / 6, `MATERIALIZED` 28 / 30 |
| `sh scripts/check-sdd.sh` | 0 |

## CI

To be recorded by the next slice (PR number, run id, conclusion).
