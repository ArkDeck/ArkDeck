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

## A build published the same day, run through the same code

The maintainer supplied the `7.0.0.37` daily dated `20260805_180512` — published after every
line of the derivation was written, and enumerated nowhere in the product.

```
ARKDECK_DAYU200_UNKNOWN_ARCHIVE=<7.0.0.37 dayu200_img.tar.gz> \
  swift test --filter testAnUnknownBuildDerivesCleanlyAndFitsTheBoard
```

Derived in one 11.2 s pass:

| | |
|---|---|
| Archive | 730,766,386 bytes, `8aad39a0c35c4513b28cbbf21e0c863f9670ed93c7602a59d1b44fdd0bf1da7a` |
| Members | 17, every one classified by rule |
| Partition table | 15 partitions, `uboot … userdata` |
| `runtimeBuildVersion` | **`OpenHarmony-7.0.0.37`**, read from `system.img` |
| Structural conformance | **no violations** |

And then refused — by nineteen digest and size mismatches against a build published eight days
earlier:

```
archive size mismatch: expected 730769584, observed 730766386
archive SHA-256 mismatch: expected 6a023c73…, observed 8aad39a0…
member boot_linux.img SHA-256 mismatch: …
member daily_build.log size mismatch: expected 24507809, observed 24471975
… 15 more
```

Every refusal is a digest or a size. Not one is structural. That is the whole cost of the weekly
daily stated as a measurement rather than an argument: a build that fits this board perfectly,
whose plan could be materialized completely, turned away because nobody had typed its hashes into
the product yet.

## Where the pins are still read

Nine sites across five layers, found by following the failure the maintainer's archive produced:

| Layer | Site | Pin |
|---|---|---|
| CLI import | `ArkDeckRuntimeCommands.swift:597` | basename must be exactly `images.tar.gz` — the vendor ships `version-Daily_Version-OpenHarmony_7.0.0.37-…-dayu200_img.tar.gz` |
| CLI import | `:663`, `:677`, `:732` | file size, declared byte count and final upload offset must equal `profile.archiveSizeBytes` |
| Daemon import | `FlashBundleArtifactImport.swift:91`, `:100` | expected byte count/SHA-256, then the full per-member `validate` |
| Engine admission | `RuntimeJobEngine.swift:3260` | the same `validate` again |
| Authorization facts | `RockchipAuthorizationFacts.swift:63` | the same `validate` again |
| Execution staging | `RockchipFlashExecutionStaging.swift:167`, `:171` | archive size and hash |
| Provider dispatch | `RockchipRockUSBFlashProvider.swift:536`, `:549` | archive hash and size into the plan record |
| Lease admission | `DeviceProviderAdapters.swift:2962` | leased artifact must hash to `profile.archiveSHA256` |
| Post-flash verify | `DeviceProviderAdapters.swift:2768` | device version compared to `profile.runtimeBuildVersion` |
| Profile lookup | `RockchipFlashProfile.swift:407` | `profile(archiveSHA256:byteCount:)` resolves a profile *by digest* |

The first one is worth naming separately because it is not even a safety check: the archive has to
be renamed by hand before the product will look at it.
