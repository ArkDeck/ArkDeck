# CHG-2026-015 Spec impact

- Core behavior:none.
- Core baseline:unchanged (`CORE-2.0.0`).
- Current specs/contracts/schemas:unchanged.
- Existing Acceptance Scenario:unchanged; this change adds seven change-local registration gates
  and does not claim any `AC-HDC-*` passed.
- Integration profile:future TASK-I15-001 bumps `OPENHARMONY-TOOLS` and Integration lock and adds a
  structured probe registry/resource pack. The proposal PR itself changes none of those inputs.
- Platform profiles/conformance:unchanged. macOS mapping and signed XCUITest remain M1-006 work;
  Windows/Linux are deferred.
- Production implementation:unchanged. Adoption requires a separate approved M1-006 task revision.
- Hardware/support/release:none.
- Rollback:revert the future registration PR and retain the existing 0.2.0 fail-closed behavior;
  old evidence remains immutable.
