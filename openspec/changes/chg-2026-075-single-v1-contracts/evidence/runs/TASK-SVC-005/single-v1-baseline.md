# TASK-SVC-005 — the final Swift single-v1 baseline, for CHG-2026-074 to consume

TASK-SVC-005 Deliverable 4 owes a `CHG-074可消费的最终Swift单v1基线（完整OID/contract路径）`.
This is it. It is a repository fact, not a journey result: no device leg has been executed, no
`run.md` exists, and TASK-SVC-005 stays `ready`.

It lives here rather than under `docs/design/references/single-v1/` — also an SVC-005 Allowed path
— because `scripts/check_sdd.py:601-632` validates ```` ```yaml pins ```` blocks only in Markdown
under an active `openspec/changes/chg-*` directory. Put here, the block below is checked by the
same gate that will check it after TASK-XPA-001 copies it.

## The baseline

```yaml pins
- path: main
  commit: 371cd9d2361781461960efcc87ae38d30386b88b
- path: Packages/ArkDeckKit/Contracts/control-protocol.json
  blob: f47372feb9034ba17560b59d5dbde91206cb9aae
- path: Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift
  blob: 6d3c1fb680d6a338ba59cb80af53aa46505196cb
- artifact: spec/control/methods
  sha256: f9c40e8b1d12c8297ec520ed8cb0e0728662303479086c6909fc223ebe9ad864
- artifact: Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames
  sha256: 08027d13987b89dee222e4ed9c0ac54eda905e18cfebd90b318c21376197abdb
```

Identity carried by that tree, read rather than restated:

| Fact | Value | Where |
| --- | --- | --- |
| Control protocol version | `1.0.0` | `ArkDeckCore/ControlProtocolGenerated.swift:5` |
| Contract identity | `1054d17b598ce23003ebbdec4d42eb359b63016d6421709ba53c3f21f7c6558d` | `ControlProtocolGenerated.swift:8` |
| Published methods | 96 | one `spec/control/methods/*.json` each |
| Recorded frame corpus | 96 files | one `Fixtures/ControlFrames/*.jsonl` each |

## How each line was produced

    git rev-parse main
    git rev-parse HEAD:Packages/ArkDeckKit/Contracts/control-protocol.json
    git rev-parse HEAD:Packages/ArkDeckKit/Sources/ArkDeckCore/ControlProtocolGenerated.swift
    git ls-tree -r HEAD --format='%(objectname) %(path)' -- <dir> | sort | shasum -a 256

The two directory digests are over git object ids and repository-relative paths, so they are
reproducible from any checkout. A digest computed instead by `find … | xargs shasum` is **not**:
its second-stage input contains the paths `find` printed, so the same content in two worktrees
gives two answers. An earlier record of these digests was produced that way and does not match;
the values above supersede it.

## What moved since the pin TASK-XPA-001 currently holds

`chg-2026-074-shared-rust-runtime-core/tasks.md:58-65` pins `eac476cd` — `main` after TASK-SVC-004
(#1742). Since then `main` has taken eight merges: #1743, #1744, #1745, #1746, #1747, #1748,
#1749, #1750. **Only the commit moves.** Measured:

- both control blobs are byte-identical to the ones already pinned, so the contract identity and
  the 96-method set are unchanged;
- `git diff --stat 80bc315c..371cd9d2 -- spec/control/methods Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames`
  is empty, and the two canonical digests above are identical at `80bc315c` (#1743, the last
  re-derivation) and at `371cd9d2`;
- `python3 Packages/ArkDeckKit/Scripts/generate-control-contract.py --check` exits 0.

So TASK-XPA-001 needs no re-derivation for these eight merges. Replacing the `commit:` line is
enough; the other two pins can stay as they are.

## One thing this baseline does not certify

#1748 changed what the daemon **emits** for three `doctor` findings: `runtime.jobRecordUnreadable`,
`runtime.durableRecordsUnreadable` and `hdc.identityUnavailable` no longer carry a `details`
object, because the keys they carried were outside the closed set `spec/control/methods/doctor.json`
publishes. The committed corpus predates that change and is unchanged — legitimately, because those
three findings need a store this build cannot read and the recording run had none, so no frame in
the corpus ever carried them.

The consequence for a Rust reader generated from these schemas is nil: the emitted shape moved
*inside* what was already published. The consequence for anyone treating the corpus as a complete
sample of what the daemon emits is not nil, and this is the gap the defect in #1744/#1746 lived in.
A differential test built on this baseline should treat the corpus as "every shape a contract-test
run happened to record", which is what it is, and not as "every shape the daemon can produce".
