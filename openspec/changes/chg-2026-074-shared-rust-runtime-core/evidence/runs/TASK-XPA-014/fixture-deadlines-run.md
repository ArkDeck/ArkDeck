# TASK-XPA-014 — harness seeding past the recorded Artifact deadlines (macOS, 2026-09-19)

TASK-XPA-014 remains in progress. Base: protected main `c3870c3d` (#2059); written on `17b428d2`
(#2055), where every run below took place, and rebased without conflict. The three commits between
(#2056, #2058, #2059) touch none of these harnesses. Host-only change to four manual harnesses under
`rust/scripts`: no Rust or Swift source, fixture, control schema, corpus, Catalog, entitlement,
`openspec/specs` or constitution change. No device, real HDC or installed state was used, and
nothing here is device evidence (POL-VERIFY-001, POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| The plan, submit and run harnesses over the analyzer oracles; the quota harness (TASK-XPA-013); the Rust startup retention sweep (#2039) | The harnesses seed recorded Artifact stores whose deadlines have passed, so they keep working after 2026-09-21 | debug.hap slice F; M5 activation; GJ-1/2/3 re-pass |

## Why

The Swift-recorded Artifact stores keep the deadlines their recording gave them. Every row of the
analyzer oracles and of the quota oracle lapses at `2026-09-21T00:00:00Z`. Four harnesses copy those
stores into fresh roots and start real daemons over them, and both daemons sweep expired Artifacts
once at startup with the real clock: Swift's `collectGarbage` in `ArkDeckAgentDaemonMain`, and the
Rust `collect_expired_artifacts` since #2039. From 2026-09-21 the sweep reclaims the recorded
sources before the first request. Plans then refuse their leases, admissions and runs change, the
quota counts fewer bytes, and each harness fails its oracle checks. CI does not run these
harnesses, so nothing would show it until the next manual run.

## What changes

- `rust/scripts/fixture-deadlines.py`, new. Once per run, over every index a harness seeds, it
  computes the whole number of days that moves the earliest recorded deadline at least a week past
  the run's start, as a fresh publication's default deadline would be, or none when it already is.
  It then copies each index with every `deadlineUTC` moved by that many days. Only the deadline
  text changes, at its recorded length, so rows keep their order and a store keeps its recorded
  file sizes. A deadline in any other spelling stops the run rather than being left behind. The
  harnesses load it by file name, as the check scripts load `run-directory.py`.
- `check-job-plan.py`, `check-job-submit.py` and `check-job-run.py`: `seed()` copies each index
  through it. Each summary records `recordedDeadlinesMovedDays`.
- `check-artifact-quota.py`: `build()` does the same for every scenario store. This is
  TASK-XPA-013's harness, included because it seeds 95 rows with the same deadline into both
  daemons and would fail the same way.
- The recorded fixtures are unchanged, and no Swift oracle is re-recorded.
- `evidence/runs/TASK-XPA-013/publication-census-bound-run.md`: the CI of #2059, the previous slice.

## Why no answer changes

No answer reads a deadline. Swift's `resolveLease` and the Rust lease resolution check the row's
status, digest and binding. The plan digest covers the source's path, arguments and byte count. The
quota counts published bytes. The recorded answers contain no deadline: no `2026-09-2x` appears in
any `cases.json` or `reads.json` of the three analyzer oracles. The run harness reads every time in
an index as `<time>`. The quota harness compares file sizes, and a moved deadline keeps its length.

## Harnesses left alone

- `check-import-upload-owner.py` seeds upload records and Target documents; committed Imports are
  pinned and carry no deadline.
- `check-corpus-replay.py` seeds a Target document and the fake HDC, never an Artifact store.
- `check-session-export.py` builds its own Session.
- The other fixtures with the same deadline serve in-process Rust tests, whose clocks are fixed.

## Runs

Every run used the Rust daemon and CLI built from `17b428d2` (`arkdeck-agentd` `abec0b9a…`,
`arkdeck` `4fac0368…`) and the Swift daemon and CLI built from the same tree through
`Packages/ArkDeckKit/Scripts/run-swiftpm.sh` (`arkdeck-agentd` `72cc6df7…`, `arkdeck`
`300ee028…`), on 2026-09-19, when the recorded deadlines were still two days ahead. Summaries and
logs are under this session's scratchpad `harness/`.

To show what 2026-09-21 does, the plan and quota oracles were also copied with every recorded
deadline set to `2026-09-01T00:00:00Z`, already past, and each harness was pointed at the copy.
"Main's harness" is the file at `17b428d2`. Nothing of these copies is committed.

| Harness | Store | Result | SHA-256 |
| --- | --- | --- | --- |
| `check-job-submit.py` | recorded | PASS, 43 checks; deadlines moved 6 days | summary `1a951aca…` |
| `check-job-run.py` | recorded | PASS, 156 checks, 18 Sessions on each owner; moved 6 days | summary `15f90834…` |
| `check-job-plan.py` | recorded | stops at `identical.notAnObject`: the wording drift below | log `5604e8c0…` |
| `check-artifact-quota.py` | recorded | stops at `swift.oracle.wrongMemberType`: the same drift | log `40074853…` |
| main's `check-job-plan.py` | recorded | stops at the same check | log `ea3d7cf6…` |
| main's `check-artifact-quota.py` | recorded | stops at the same check | log `28241d3a…` |
| main's `check-job-plan.py` | lapsed | fails first: the Swift CLI's `job plan` exits 65 with `analyzer source artifact Artifact lease is not resolvable: artifactNotFound("ART-cf645cc2f23c16cf9965b179bcb35b5e")`, the source reclaimed at startup | log `8ccb2e8d…` |
| `check-job-plan.py` | lapsed | passes that point on both owners; stops at `identical.notAnObject`, as over the recorded store | log `3626767b…` |
| main's `check-artifact-quota.py` | lapsed | fails at `swift.oracle.published`: Swift counts 0 bytes where the oracle counted 111 | log `01c1b8e8…` |
| `check-artifact-quota.py` | lapsed | passes that point; stops at `swift.oracle.wrongMemberType`, as over the recorded store | log `a517acac…` |

Two diagnostic runs set the drift aside to see the rest. In scratch copies only, the quota
harness read Swift's `typeMismatch: Expected` as the recorded `expected`, and the plan harness read
every `DecodingError` refusal message as a label, on both sides and in the oracle, keeping each
code and its details.

| Harness, diagnostic | Store | Result | SHA-256 |
| --- | --- | --- | --- |
| `check-artifact-quota.py` | recorded | PASS, 27 scenarios, 108 checks; moved 6 days | summary `02ae7d3b…` |
| `check-artifact-quota.py` | lapsed | PASS, 108 checks; moved 26 days | summary `68b6aa9b…` |
| `check-job-plan.py` | recorded | PASS, 67 identical answers, 141 checks; moved 6 days | summary `c98993cb…` |
| `check-job-plan.py` | lapsed | PASS, 141 checks; moved 26 days | summary `92712754…` |
| main's `check-job-plan.py` | lapsed | fails first, as without the label: `job plan` exits 65, `artifactNotFound` | log `b2298263…` |

`python3 -m py_compile` passes for all five scripts, and
`ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh` reports 0 errors and 0
warnings.

## A wording drift found on the way, not fixed here

This host moved to macOS 27.0 on 2026-09-15 (its install history), after the analyzer and quota
oracles were recorded on 2026-09-14. The Swift daemon interpolates Swift's `DecodingError` into
some refusal messages, and the macOS 27 Swift runtime spells it differently:

- `typeMismatch: Expected value of type …` where the oracles recorded `expected`;
- `valueNotFound: Expected value of type X.` where they recorded `… X but found null instead.`.

The Rust owners reproduce the recorded spelling. So on this host `check-job-plan.py` and
`check-artifact-quota.py` stop at the first such refusal, with or without this change. Under r11
§3 a `message` text and a Swift debug rendering are T2 and not compared, so this is not a parity
defect. These two older harnesses compare every message byte for byte, which is stricter than r11.
Masking the T2 wording there is left to its own slice.

## Not run

Any device, real HDC or installed Runtime. CI does not run these harnesses; the PR's CI (`guard` +
`swift`) is the unified gate for the change itself.
