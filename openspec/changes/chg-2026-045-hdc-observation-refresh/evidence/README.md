# CHG-2026-045 evidence

- `runs/TASK-HOR-001/readiness-r1.md`:D1 readiness inputs and closed matrix;
  not implementation or AC evidence.
- `runs/TASK-HOR-001/implementation-r1.md`:same-revision `contract` plus
  signed macOS fixture `platform` evidence for all four `HOR-*` AC.
- `runs/TASK-HOR-001/verification-r1.md`:protected-main closure replay,
  source/blob drift audit and verification boundary.
- `runs/TASK-HOR-001/verification-r2.md`:post-merge replay on the #777 HDC
  source split and #778 verification merge; this is the archive precondition
  repair for the concurrency gate declared by r1.

None of these records is installed-HDC or `realHardware` evidence. They may
not close CHG-2026-006 `HW-M0B-DAYU200-SUPERVISOR-001`.
