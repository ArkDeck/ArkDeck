# The measurement the last document could not make (2026-08-07)

## Why this exists

`bare-json-answer-measured-2026-08-07.md` opened by saying what it was not: "It is not a
measurement of `main` — `main` does not have the change." Both changes are now in `main`
(#1149, #1165), so this is that measurement.

- Baseline: `main@a31cfe27`, release build, daemon restarted onto it
- Device: DAYU200, `OpenHarmony-7.0.0.34`, target `TGT-958780b2ffb7`
- Run: `HTASK-319F7B40C75D`, terminal `succeeded`, 21 rounds, 6 E1 mutations, 0 human actions

## The three signals, stated before the run and answered after

| | expected | measured |
|---|---|---|
| `malformedJson` | 0 | **0** |
| `operationNotExpected` (the misnaming wording) | 0 | **0** |
| `decisionNotYoursDuringOrchestratedStep` | present if the path is hit | **0** |

Every one of this run's eight rejections was `operationNotOffered:…:offered=…`.

The first two lines are the result. The third needs saying plainly rather than being read as
success: **zero means the path was not exercised, not that it works in production.** #1165 is
covered by contract tests, including three counter-tests that go red when the wording is
reverted, and it has still never been reached on hardware — no producer diverted an
orchestrated step in this run. Reading an absence as a confirmation is the exact mistake this
change window has spent its time removing from the product; it would be poor form to make it
in the document about that work.

## Tally

Six samples, five passes, two firmware builds:

| run | firmware | baseline | terminal |
|---|---|---|---|
| `HTASK-2717D3B89C57` | 7.0.0.37 | before | succeeded |
| `HTASK-7C12960C4B6E` | 7.0.0.34 | before | **humanRequired — `malformedJson`** |
| `HTASK-E854F29E73A6` | 7.0.0.34 | before | succeeded |
| `HTASK-FDAA3BFEBEF7` | 7.0.0.34 | before | succeeded |
| `HTASK-0C535C0E0B87` | 7.0.0.34 | pending branch | succeeded |
| `HTASK-319F7B40C75D` | 7.0.0.34 | **main** | succeeded |

**Still not a claim that the success rate moved.** Six samples with one failure cannot separate
a fix from producer variance, and that over-reading was made once in this window and withdrawn
(`refusal-alternatives-measured-2026-08-06.md`). What is supported: the one failure had a named
cause; that cause has not recurred in the two runs since, one of them on `main`.

## What is still unexercised, carried forward

- **#1165's refusal path**, above.
- **The reconciliation readback.** Three windows now. Reaching it needs an interrupt *after* the
  first partition write, which risks an unbootable board, and that has not been attempted
  without a decision to accept the risk.
