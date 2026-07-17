# CHG-2026-005 Pre-Task Review Gate

> Status：pending r2 maintainer review
> Approval semantics：only merge to protected `main` after CODEOWNER review approves this change;
> this draft records no approval, fixture provenance acceptance or readiness result.

- [x] Change class is integration and Core change level is none.
- [x] `scope.yaml` revision 2 is the single exact impacted Requirement/AC/Policy/Profile set.
- [x] Failure fixture lineage is limited to the existing M0A candidate bytes.
- [x] Standalone success、healthy/checkserver、version inputs require maintainer-recognized
  authoritative or controlled-human provenance; Agent-authored strings and Agent-run installed HDC
  are rejected.
- [x] I5-001 owns the Golden raw files, exact OpenHarmony profile mapping, Integration lock/Core
  conformance pins, SwiftPM `.copy` resource-tree declaration and `Bundle.module` hash test.
- [x] I5-001 and I5-002 may update only their own status/completion evidence in this `tasks.md`.
- [x] M1-006 remains blocked until complete supported-family closure, M1-005 durable seams and
  CHG-002 r3 design/UI/audit paths are approved and evidenced.
- [ ] Maintainer has approved CHG-005 r2 scope and the exact SwiftPM resource access mode.
- [ ] Maintainer has accepted provenance/raw inputs for standalone success、healthy/checkserver and
  version families.
- [ ] TASK-I5-001 implementation and its independent TASK-I5-002 readiness restoration have each
  been reviewed and merged.

PR packaging decision remains with the maintainer: CHG-002 r3 and CHG-005 r2 may be reviewed in one
PR if its title/description truthfully covers both change amendments, or in two ordered PRs. This
record does not select or approve either option.
