# Spec Impact — CHG-2026-034

## Classification

This is an `implementation-only` host tooling change. It changes how the SDD
entrypoint locates its already-declared Python dependency environment and how a
human explicitly prepares that environment. It does not change any ArkDeck
product behavior, Requirement, Acceptance Scenario, contract, schema, platform
profile or release claim.

## No-op delta conclusion

- `openspec/specs/**`: no modification.
- `openspec/contracts/**`: no modification.
- canonical acceptance registry/index: no ID change.
- `scripts/check_sdd.py`: no validation-rule or result change.
- Core baseline: remains `CORE-2.1.0`.
- macOS/Windows/Linux product conformance: no revalidation debt.

The change-local `SDR-*` cases validate only host tooling mechanics and do not
enter the canonical Core acceptance registry.
