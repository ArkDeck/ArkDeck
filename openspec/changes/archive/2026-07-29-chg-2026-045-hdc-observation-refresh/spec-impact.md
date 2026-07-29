# CHG-2026-045 Spec Impact

> Change:CHG-2026-045-hdc-observation-refresh@r1
> Core baseline:CORE-2.1.0

## No-op Core delta

- `openspec/specs/**`:no modification.
- `openspec/contracts/**`:no schema, required-field or semantic change.
- canonical acceptance index/cases:no ID added, removed or modified.
- Core baseline:remains `CORE-2.1.0`.

The four `HOR-*` IDs are change-local acceptance only. This change does not
reinterpret CHG-2026-006 `HW-M0B-DAYU200-SUPERVISOR-001`; it supplies a
macOS production route needed before that hardware test can undergo another
readiness decision.

## Compatible implementation impact

- `REQ-UX-002`:the existing HDC diagnostics presentation gains an explicit
  macOS user refresh action; required diagnostic field semantics are
  unchanged.
- `REQ-HDC-002`/`REQ-HDC-003`:the same host-wide supervisor and ownership
  protections remain authoritative; no lifecycle operation is added.
- `REQ-HDC-004`:the same selected endpoint is reused and no global
  environment is modified.
- `REQ-I18N-001`:the one new ArkDeck-owned control is supplied in English and
  Simplified Chinese.

No canonical Requirement or AC is claimed as passed by the change-local
contract/fixture evidence.

## Integration and platform impact

- OpenHarmony registries/resources, integration profile/lock and macOS
  platform profile remain byte-identical.
- The existing exact 3.2.0f `list targets -v` registration is consumed with
  unchanged argv, timeout, identity bracket, parser and event semantics.
- macOS gains a SwiftUI entry to the existing provider; Windows/Linux remain
  deferred and gain no support claim or exemption.
- No platform conformance transition occurs. CHG-2026-006 remains blocked
  until this change is done/verified and a later fresh hardware readiness is
  approved.
