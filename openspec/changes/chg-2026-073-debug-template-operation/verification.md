# Verification — CHG-2026-073

> Change:CHG-2026-073-debug-template-operation@r1
> Status:planned; host verification does not approve the change or prove a
> real-device run.

| AC ID | Method | Expected result |
| --- | --- | --- |
| DTO-AC-1 closed vocabulary | catalog generator, registry and parser contract tests | the descriptor validates with zero drift, the enum equals the template table, the CLI publishes exactly `list` and `run`, and `run` carries no hand-copied flag |
| DTO-AC-2 admitted execution | scripted engine run | the Job succeeds read-only after binding identity confirmation, the template step lowers to the fixed tokens behind the bound connect key with the template's budget, and the typed action persists exactly |
| DTO-AC-3 products and privacy | scripted engine run | `template-output.txt` is published sensitive and unreadable without opt-in, `template-report.json` is standard and names the template, command, exit status and Catalog digest, and neither carries the connect key |
| DTO-AC-4 refusal | scripted engine run and admission | an identity outside the enum is refused before dispatch, and a non-zero exit fails the Job without publishing output |
| DTO-AC-5 logs preset | preset, registry and parser contract tests | `debug logs` projects exactly the App's HiLog-only `capture.diagnostics@1` inputs from the shared owner, accepts only `durationSeconds` and `hilogFilters`, and refuses out-of-range windows, unsafe filters and any other diagnostics leg before connecting |

Required local gates are `scripts/check-sdd.sh`, catalog generator unittest and
zero drift, the relevant Swift contract set, PR path preflight, and the
repository unified local gate. Evidence is recorded under
`evidence/runs/TASK-DTO-001/` without device output bytes.
