# TASK-XPA-011: canonical Catalog references in Golden Journey recording

The protected-main Catalog contains 32 descriptors, including the unversioned
`flash.dayu200` alias of `flash.full-restore@1`. Runtime `operation.list` publishes
those descriptors with their `aliasFor` metadata. The recorder's fixed-fact
comparison already excludes aliases from the returned canonical set, but its
expected set included every descriptor. This rejected the correct 31-operation
canonical list before a Journey could be judged.

The expected reference set now excludes descriptors with non-null `aliasFor`.
The SHA-256 is still recomputed over the entire canonical JSON, including every
alias. No Catalog, operation, trust, Runtime, published contract or acceptance
criterion changes. Missing or duplicate canonical operations still fail the
exact comparison. Protected-main ancestry and matching current Catalog digest
remain required.

Regressions use the committed `flash.dayu200` descriptor and the actual generated
Catalog. Synthetic end-to-end assembly accepts the alias without counting it
twice and still rejects a missing canonical operation. Editing alias bytes
without updating the full digest remains an error. These fixtures are software
checks and do not constitute hardware evidence.

## Local targeted checks

- `python -m unittest discover -s gj_record -t .` from `scripts`: exit 0,
  57 tests passed; log
  `tools/logs/gj-canonical-catalog-tests.log` (operator workspace, not committed).
- `sh scripts/check-sdd.sh` through the installed Git shell: exit 0; log
  `tools/logs/gj-canonical-catalog-sdd.log` (operator workspace, not committed).
- `git diff --check`: exit 0.

## CI

Not pushed yet. Required `guard` and `swift` must pass on the final pushed head
before merge. CI results will be recorded without amending a green head.
