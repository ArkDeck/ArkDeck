"""Golden Journey record generator (CHG-2026-074, phase A gap G9).

`capture` runs one published `arkdeck` command and keeps its stdout, exit code
and order in a local journal. `assemble` reads that journal back, applies each
Journey's criteria from `docs/design/cli-golden-journey-headless-runbook.md`
and writes the redacted `arkdeck.gj-headless-rerun/1` record. No person writes
or judges `REAL_DEVICE_PASS`: a Journey passes only when every criterion holds
on the Runtime's own outputs. See README.md.
"""
