# Recorder distinguishes declarations from published Artifact bytes

Date: 2026-10-05. Task: TASK-XPA-011. Source parent:
`0f98bc902a4260da98b0b79bc30c8ef79477ff23`. Software regression evidence only;
no actual Runtime journal or device evidence was read, changed or generated.

The recorder treated every `job.result.artifacts` declaration as a published
payload. A default `capture.diagnostics@1` legitimately retains 14 declarations,
including six published products and eight intentionally omitted products. Its
missing crash-index declaration has no bytes to read. The Catalog sets
`crashLogs` false by default and declares `crash-index.txt` optional
(`Catalog/operations/capture.diagnostics.v1.json:115,417`). The accepted GJ-1
runbook requires bounded HiLog and UI Dump, both nonempty and digest-read, and
a complete summary with no missing-required products
(`docs/design/cli-golden-journey-headless-runbook.md:127–143`).

This is a consumer interpretation repair. Raw Artifact immutability and truthful
publication remain required by REQ-ART-002/003/004 in
`openspec/specs/session-artifact-storage/spec.md`. The producer records omitted
declarations with zero bytes and an empty digest
(`artifact_publication.rs:229–246`), and projects every declaration into the
result (`job_result.rs:678–691`). Its inventory integrity read permits a missing
product only when the durable request intentionally omitted it
(`device_steps.rs:1142–1180`, `job_result.rs:419–460`). A selected missing or
truncated product produces an integrity blocker. Capture completeness counts
required declarations (`capture_documents.rs:58–116`), so it cannot substitute
for that integrity gate.

The recorder retains the full raw declaration inventory and its count. A missing
row skips byte reads only with exact `byteCount == "0"`, `sha256 == ""` and
`bytesVerified is False`, and no contradictory successful read. Required names
must occur among published rows. Every published product requires the producer's
verification and a whole read whose digest and length match that inventory row.
Truncated, unknown and inconsistent rows fail. Successful evidence must also
report `status == "verified"` and `inventoryAvailable is True`; existing terminal,
unknown, blockers, missing-required, residue and summary gates remain. Expected
failed rollback Jobs retain their existing terminal/blocker handling.

The Runtime source revision may remain this protected-main ancestor after a
recorder-only merge: `record.py:243–252` uses the ancestry proof in
`catalog.py:77–89` and then requires the current Catalog digest to equal the built
revision's digest. No Catalog or Runtime code changed in this increment.

## Local targeted checks

`python -B -m unittest discover -s gj_record -t .`, from `scripts`, through
`D:/src/ArkDeck-wt/tools/run_check.py`: exit 0, 54 tests passed; log
`D:/src/ArkDeck-wt/tools/logs/gj-artifact-inventory-tests-final.log`. The new tests
read the committed `rust/tests/fixtures/capture-diagnostics` producer answers and
published bytes, verify the 14/6/8 shape, and vary in-memory copies for required
missing products, producer integrity blockers, unavailable inventory, truncated
or unknown status, inconsistent placeholders, digest/length mismatches, unverified
bytes, partial reads and uncaptured reads. They never run a Runtime or HDC.

After independent review, the selected-optional-product regression was refined
to enable `crashLogs` while the crash index remains missing, retaining all six
published reads and the complete summary. All 11 final inventory regressions
passed with exit 0 in
`D:/src/ArkDeck-wt/tools/logs/gj-artifact-inventory-final-regressions.log`.

`C:/Program Files/Git/usr/bin/sh.exe scripts/check-sdd.sh`: exit 0; log
`D:/src/ArkDeck-wt/tools/logs/gj-artifact-inventory-sdd.log`. `git diff --check`:
exit 0. No Rust, Swift, App or contract input changed, so their build checks and
contract generation were not run.

## CI

Not run for this uncommitted review increment. Root owns review, commit, push and
the exact PR/head CI result. These synthetic checks make no hardware-pass or
readiness claim; root alone performs actual mechanical assembly.
