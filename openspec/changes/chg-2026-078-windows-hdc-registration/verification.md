# Verification Plan

> Change:CHG-2026-078-windows-hdc-registration@r2
> Status:planned # planned | passed | failed;结论经维护者在 PR 中确认

## Environment

- Core baseline: CORE-3.0.0. Platform profile: `openspec/platforms/windows/profile.md`.
- Host: the Windows 11 x64 reference host, where the maintainer takes the samples. Processing
  and contract tests run on any Windows host.
- Tools: hdc candidate c2 (`c7951849…01e`, `Ver: 3.2.0g`) is the only registered tuple
  (maintainer ruling 2026-10-04). c1 (`f6d6c475…d9b`, `Ver: 3.2.0b`) was sampled and is used only as a
  negative vector. Both were captured on 2026-10-04 (#2456); CI never runs `hdc`.
- Device: DAYU200, sampled on 2026-10-04; the maintainer did the plugging.
- Fixtures: `rust/tests/fixtures/hdc-windows/**` (TASK-WHR-001).

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| WHR-IDENTITY-001 | registry and fixture contract tests (TASK-WHR-002) | every registered fixture classifies as its family; the hash closure holds | TASK-WHR-002 run record |
| WHR-SEPARATION-001 | macOS registry byte identity and a cross-platform substitution matrix | byte-identical macOS registries; no crossing, no fallback | `git diff --stat` and the TASK-WHR-002 tests |
| WHR-OBSERVATION-001 | c2 fixture classification and negative row vectors (TASK-WHR-002) | USB rows only; sampled UART rows excluded; everything else `unknown`; `checkserver` never dispatched | TASK-WHR-002 run record |
| WHR-CENSUS-001 | TASK-XPA-004 Windows census tests (CHG-2026-074) | ASCII-lowercase serial fold, present-only, attachment = (instance ID, arrival), topology per attachment only | TASK-XPA-004 run record |
| WHR-PRIVACY-001 | leak scan of every sanitized output (`windows_sample_process.py`) and a reviewer's own search for the board serial | no identifier, path, name or hash of key-bearing bytes | TASK-WHR-001 run record |

### WHR-IDENTITY-001

Each Windows entry is keyed by an executable SHA-256 and the `-v` bytes observed with it, plus
the observed endpoint. Its fixtures are the redacted capture, hash-pinned.

### WHR-SEPARATION-001

The macOS registries and resources are byte-identical, and there is no cross-platform match or
fallback.

### WHR-OBSERVATION-001

The registered `deviceObservationSnapshot` reads only `USB` rows as devices and excludes the
sampled UART row form (maintainer ruling 2026-10-04, item 2). Every other form is `unknown`.

### WHR-CENSUS-001

The Windows census folds the instance-ID serial to ASCII lower case before relating it to the
connect key, counts present nodes only, names an attachment by (instance ID,
`LastArrivalDate`) and keeps topology inside one attachment (maintainer ruling 2026-10-04,
items 4 and 5).

### WHR-PRIVACY-001

The sanitized outputs and the run records hold no identifier. Keys and serials are same-length
placeholders.

## Negative and recovery tests

These are synthetic vectors. They prove fail-closed behaviour only and are never provenance:

- another executable SHA-256 gives `unsupported`;
- another endpoint gives `unsupported`, and a missing server `unavailable`;
- two listeners or a foreign listener owner give `unknown`;
- zero-byte stdout gives `unknown`;
- a CR inside a field, an unknown state, transport or hostTag literal, a wrong column count or a
  duplicate connect key give `unknown`;
- non-empty stderr, a non-zero exit, a timeout or cancellation give `unknown`/typed;
- a macOS tuple offered to the Windows registry, and a Windows tuple offered to a macOS
  registry, give `unsupported`;
- a port-derived USB instance suffix gives no identity;
- candidate 1's hash gives `unsupported`;
- the `[Empty]` marker, a 5-column row, a sixth column other than `hdc` and a UART row outside the
  sampled form give `unknown`;
- a phantom (non-present) USB node gives no entry, and a serial differing from the connect key
  after the fold gives no relation.

## Deviations

Every Windows difference from macOS found in the 2026-10-04 samples is recorded as found in the
CHG-2026-074 run records (#2456); none is smoothed. Where a difference needed a decision (6
columns, UART rows, `checkserver` starting a server, serial letter case, topology across a
replug), the decision is maintainer ruling 2026-10-04 (`proposal.md` "Revision r2").

## Result gate

- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] Traceability updated
