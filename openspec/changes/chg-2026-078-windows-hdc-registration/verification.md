# Verification Plan

> Change:CHG-2026-078-windows-hdc-registration@r1
> Status:planned # planned | passed | failed;结论经维护者在 PR 中确认

## Environment

- Core baseline: CORE-3.0.0. Platform profile: `openspec/platforms/windows/profile.md`.
- Host: the Windows 11 x64 reference host, where the maintainer takes the samples. Processing
  and contract tests run on any Windows host.
- Tools: hdc candidates c1 (`f6d6c475…d9b`) and c2 (`c7951849…01e`), captured by the
  maintainer. The agent and CI never run `hdc`.
- Device: DAYU200, sampled by the maintainer only.
- Fixtures: `rust/tests/fixtures/hdc-windows/**` (TASK-WHR-001).

## Acceptance matrix

| AC ID | Verification method | Expected result | Evidence |
| --- | --- | --- | --- |
| WHR-IDENTITY-001 | registry and fixture contract tests (TASK-WHR-002) | every registered fixture classifies as its family; the hash closure holds | TASK-WHR-002 run record |
| WHR-SEPARATION-001 | macOS registry byte identity and a cross-platform substitution matrix | byte-identical macOS registries; no crossing, no fallback | `git diff --stat` and the TASK-WHR-002 tests |
| WHR-PRIVACY-001 | leak scan of every sanitized output (`windows_sample_process.py`) and a reviewer's own search for the board serial | no identifier, path, name or hash of key-bearing bytes | TASK-WHR-001 run record |

### WHR-IDENTITY-001

Each Windows entry is keyed by an executable SHA-256 and the `-v` bytes observed with it, plus
the observed endpoint. Its fixtures are the redacted capture, hash-pinned.

### WHR-SEPARATION-001

The macOS registries and resources are byte-identical, and there is no cross-platform match or
fallback.

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
- a port-derived USB instance suffix gives no identity.

## Deviations

None yet. Every Windows difference from macOS found in the samples is recorded as found in the
TASK-WHR-001 run records; none is smoothed.

## Result gate

- [ ] 所有适用 AC passed 且 evidence 可复查
- [ ] Simulation/fake 未计入硬件支持
- [ ] Traceability updated
