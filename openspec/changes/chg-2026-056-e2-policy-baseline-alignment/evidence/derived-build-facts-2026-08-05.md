# Deriving a firmware build's facts from the archive — equivalence run (2026-08-05)

## What was run

`testTheRealArchiveDerivesExactlyWhatThePinnedProfileStates`, opt-in via
`ARKDECK_DAYU200_ARCHIVE`, against the archive the `dayu200@2` profile was hand-written from:

```
ARKDECK_DAYU200_ARCHIVE=<dayu200_img.tar.gz> \
  swift test --filter RockchipImageArchiveIntrospectionContractTests
```

- Archive: the 2026-07-28 OpenHarmony daily, 730,769,584 bytes
- Baseline: `main@19358dd2` plus this change
- Result: **10 tests, 0 failures, 11.2 s** — the whole 730 MB archive streams once

## What it proved

Streaming the archive once derives exactly what a person typed into
`RockchipFlashProfile.dayu200OpenHarmony70035`:

| Fact | Derived vs pinned |
|---|---|
| Archive byte count and SHA-256 | equal |
| Member set | equal, all 17 names |
| Each member's byte count | equal |
| Each member's SHA-256 | equal |
| Each member's classification | equal, by rule rather than by table |
| `runtimeBuildVersion` | equal — `OpenHarmony-7.0.0.36` |
| Structural conformance | no violations |

The version is the one that matters most and the one that cannot be guessed. The archive is
*named* `7.0.0.35` and its `daily_build.log` says `OpenHarmony_7.0.0.35`; the value baked into
`system.img` is `OpenHarmony-7.0.0.36`, and that is what the device answered after it was flashed
on 2026-08-04. Derivation reads the image, so it gets the answer the device will give.

## Nothing is extracted

The derivation happens on the pass the reader already makes. `GzipTarArchiveReader` decompresses
and hashes in-process; it now also captures the partition table's bytes and scans the system
image for the property as those members go past. That is the rule the reader was written under —
an unvalidated archive is never handed to an external tool — extended to cover the obvious second
version of the same mistake, writing it out to read it again.

The scanner is streaming rather than window-at-a-time because the decompressor owes nobody a
chunk boundary: the property can land astride any two chunks. A scanner that only searched inside
one chunk would report "no version", and post-flash verification comparing against nothing reads
as a passing flash. `testAVersionSplitAcrossEveryChunkBoundaryIsStillFound` splits the property at
every one of its byte positions.

## Still not cut over

`dayu200@1` and `dayu200@2` keep their member lists and the import path still matches against
them. This change makes the derivation available and proves it equivalent; removing the pinned
lists changes what a real flash admits, and PRODUCT-LOOP's four-category rule requires that to
ship with the GJ-4 delivery — a device window with an operator confirming a destructive plan.

The catalog is untouched, so the digest is unchanged and every Golden Journey keeps its
`REAL_DEVICE_PASS`.
