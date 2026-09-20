# TASK-XPA-014 — the Swift runtime's DecodingError rendering read as a label (macOS, 2026-09-20)

TASK-XPA-014 remains in progress. Base: protected main `28d2016c` (#2050). Host-only change to two
manual harnesses and one helper beside them under `rust/scripts`: no Rust or Swift source, fixture,
control schema, corpus, Catalog, entitlement, `openspec/specs` or constitution change. No device,
real HDC or installed state was used, and nothing here is device evidence (POL-VERIFY-001,
POL-MODE-001).

## Already on main / this slice / still remaining

| Already on main | This slice | Still remaining (TASK-XPA-014) |
| --- | --- | --- |
| The four harnesses seed their recorded Artifact stores with the deadlines moved past the startup sweep (#2063) | `check-job-plan.py` and `check-artifact-quota.py` read a refusal's `DecodingError` rendering as a label, as r11 section 3 asks | debug.hap slice F; M5 activation; GJ-1/2/3 re-pass |

## Why

A Swift owner interpolates Swift's `DecodingError` into some refusal messages: the daemon's
`undecodable current request: \(error)` and the Artifact store's `indexCorrupted("undecodable
artifact index: …")`. That sentence is written by the Swift runtime, which belongs to the host's
OS. This machine moved to macOS 27.0 on 2026-09-15 (its install history), after the analyzer and
quota oracles were recorded on 2026-09-14, and its runtime spells two of those renderings
differently:

| Case | Recorded on macOS 26.6.2 | Written by macOS 27.0 |
| --- | --- | --- |
| `typeMismatch` | `expected value of type X.` | `Expected value of type X.` |
| `valueNotFound` | `Expected value of type X but found null instead.` | `Expected value of type X.` |

The Rust owners reproduce the recorded spelling, so on this host `check-job-plan.py` stopped at
`identical.notAnObject` and `check-artifact-quota.py` at `swift.oracle.wrongMemberType`, with or
without any change of ours, and so did their versions on main. This was found while #2063 was
verified and is recorded in `fixture-deadlines-run.md`.

## The judgment

Under CHG-2026-074 r11 section 3 a `message` text and a Swift debug rendering are T2 and not
compared at all. So the drift is not a parity defect, and nothing in the Rust owners or the
recorded oracles needs to change. It is these two older harnesses that were stricter than the
policy: they compared every message byte for byte, including a sentence neither runtime owns. They
now read that sentence as a label and keep comparing everything around it.

## What changes

- `rust/scripts/decoding-error-wording.py`, new: `masked(value)` replaces, in every string of an
  answer, the Swift runtime's rendering after `DecodingError.<case>: ` with
  `<Swift runtime rendering>`, keeping the ArkDeck wording before it and the Swift error case that
  wraps it (`indexCorrupted("…")`). `--self-test` checks it against both oracles. The harnesses
  load it by file name, as they load `fixture-deadlines.py` and `run-directory.py`.
- `check-job-plan.py`: the `identical.*` and `oracle.*` comparisons mask both sides.
- `check-artifact-quota.py`: the `swift.oracle.*` and `identical.*` comparisons mask both sides.
  Its CLI comparison never carried a message.
- `evidence/runs/TASK-XPA-014/fixture-deadlines-run.md`: the CI of #2063, the previous slice.

## What stays compared

The error code; the answer's shape, its members and their order; the zero-dispatch proof
(`details.phase`, `details.newDispatchCount`); every result, index row, file and mode the harnesses
already compare; the ArkDeck wording around the rendering, including the `indexCorrupted` spelling
of the Swift error case and the `undecodable current request: ` prefix; and the `DecodingError`
case the runtime names, which is the shape of the decoding failure rather than its wording. Only
the runtime's own sentence after that case goes.

## Checks

| Check | Result |
| --- | --- |
| `python3 rust/scripts/decoding-error-wording.py --self-test` | PASS. The 25 renderings the two oracles record, over all four cases (`typeMismatch`, `valueNotFound`, `keyNotFound`, `dataCorrupted`), each keep their prefix, their case and their wrapper and lose their debug description. The three macOS 27 spellings observed on this host compare equal to their recorded counterparts, which differ before masking. A different code, a different `DecodingError` case, different ArkDeck wording, a different Swift error wrapper and a message without a rendering are all still told apart. Over both `cases.json` documents exactly those 25 strings change |
| Each harness loaded as a module | `masked` is bound in both; a recorded answer and its macOS 27 counterpart compare equal, while the same answer under another code still differs |
| `python3 -m py_compile` on the three scripts | exit 0 |
| `ARKDECK_PYTHON=<repo>/.venv-sdd/bin/python sh scripts/check-sdd.sh` | 0 errors, 0 warnings |

## Not run

The two harnesses themselves: each needs a Swift daemon and a Rust daemon, and the coordinator
scoped this slice's verification to `check-sdd` and the self-tests. They last ran in full for
#2063, where both stopped exactly at the drift this slice reads as a label, and where masking it in
scratch copies took them to PASS (141 and 108 checks). No device, real HDC or installed Runtime.
