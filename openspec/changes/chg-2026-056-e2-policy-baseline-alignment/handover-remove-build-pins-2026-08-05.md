# Handover — removing the per-build flash pins (2026-08-05)

Unfinished work. The code is `handover-remove-build-pins.patch`, next to this
file — 8 files, +258/-93, applies to `main@af19ac97`:

```
git checkout -b flash-remove-build-pins af19ac97
git am openspec/changes/chg-2026-056-e2-policy-baseline-alignment/handover-remove-build-pins.patch
```

It is carried as a patch rather than a branch on purpose. It changes an E2
admission boundary and five contract tests still fail; a half-finished
destructive-operation boundary should not sit on a branch where it could be
merged. The patch is inert until someone deliberately applies it.

Read this before touching `RockchipFlashProfile` — the design question is
settled and the remaining work is mechanical except for one real defect,
described in §2.

## 0. What this was for

A published DAYU200 device profile enumerated one firmware build: the archive's
size and SHA-256, and the name, size and SHA-256 of all seventeen members.
OpenHarmony publishes a daily. So every new build needed a profile constant, a
`deviceProfile` enum value, and therefore a new catalog digest — and a moved
catalog digest drops all five Golden Journeys out of `REAL_DEVICE_PASS`.

That bought recognition, not integrity. Byte integrity rests on the Artifact
lease and the exact-plan authority, both of which are untouched here. What is
removed is the requirement that somebody had already met the build.

Measured on 2026-08-05 with the `7.0.0.37` daily (`20260805_180512`), published
after the code was written and enumerated nowhere: it derived completely and
fitted the board with **no structural violation**, and was refused by
**nineteen digest and size mismatches** against a build eight days older. See
`evidence/derived-build-facts-2026-08-05.md`.

## 1. What already works with the patch applied

Verified by hand on this host, against the vendor's original filename, with no
code change per build:

```
arkdeck artifact import-flash-bundle --target TGT-… \
  --file version-Daily_Version-OpenHarmony_7.0.0.37-20260805_180512-dayu200_img.tar.gz \
  --device-profile dayu200@2
→ lease-v1:input-flash-…-8aad39a0c35c4513:ART-b11f2b7f8a6d…

arkdeck flash plan --images <same file> --device-profile dayu200@2 --mode planOnly
→ build: OpenHarmony-7.0.0.37
  archive: sha256 8aad39a0… (730766386 bytes)
  plan digest: afcf9e569d8fcde7…  step-set digest: 6026ee66894ff94d…
  13 steps, all 9 mapped partitions
```

Seven sites now take their expected values from the archive in hand instead of
a compiled-in constant:

| Site | Was | Is |
|---|---|---|
| `ArkDeckRuntimeCommands.swift` basename gate | must be exactly `images.tar.gz` | gone; it was never a safety check |
| same, size gate | `== profile.archiveSizeBytes` | the file's own size |
| same, upload completion | `== profile.archiveSizeBytes/SHA256` | what this upload declared |
| `FlashBundleArtifactImport.production` | candidate matched by digest before reading | one candidate that reads and judges |
| `RuntimeJobEngine` admission | `profile.validate(observation)` | derive + `forBuild` conformance |
| `RockchipAuthorizationFacts` | select profile by archive digest | build the profile for this archive |
| `ArkDeckCLIMain` plan/plan-document | select/lookup by archive digest | board reference + derived build |

The mechanism is `RockchipFlashProfile.forBuild(_:)` / `forArchive(at:)`: the
struct keeps its shape, so every downstream site that records a plan digest,
stages an archive or verifies a device reads the same fields as before. Only
their *source* changed. `RockchipFlashProfile.board(reference:)` replaces
`profile(reference:)` where a board is what was wanted.

The catalog is untouched: `dayu200@1` and `dayu200@2` both remain published
input values, so the digest does not move and no Golden Journey loses its pass.

## 2. The one real defect to fix first

**Post-flash verification now reads the archive while materializing a step.**

`DeviceProviderAdapters.swift`, the `("rebind-and-verify-build", .probeDevice)`
branch, calls `forArchive(at: bundle.fileURL)` to learn the version the device
must report. Materializing a step should be pure; making it depend on a 730 MB
read is worse than the pin it replaced. `DeviceProviderContractTests.`
`testRockchipMaterializesEveryPublishedRuntimeStepWithoutLegacyAuthorization`
fails on exactly this, with `unreadableFile("/private/tmp/images.tar.gz")`, and
it is right to.

The fix is to move the comparison from materialization to execution. The
execution host has already staged and validated every image, including
`system.img`; it can read the declared version from the staged copy and compare
it to what the device answers. Sketch:

- `RockchipFlashExecutionStager.stage(...)` already returns `StagedRockchipImage`
  per member. Have it also return the version scanned from the system image —
  `RockchipImageArchiveIntrospection.StreamingValueScanner` over the staged
  bytes, which are already being read for revalidation.
- The verify step then compares the device's `const.ohos.fullname` against that,
  and the step's materialization goes back to naming a comparison rather than
  performing one.

Do not solve this by adding a field to `RockchipFlashPlan`: that changes
`planDigestSHA256`, which several tests and the campaign confirmation pin.

## 3. The five failing tests, and what each should say instead

None of these should be deleted. Each pinned a real invariant; the invariant
changed, so the statement changes with it.

1. `AgentDaemonContractTests.testProductionFlashImportPolicyPinsBothPublishedDAYU200Archives`
   — asserted the production policy holds exactly two candidates with the two
   published archives' digests. **Restate:** the policy holds one candidate that
   pins nothing, and an archive is admitted or refused by being read. Keep an
   assertion that a *non-archive* is refused.

2. `AgentDaemonContractTests.testProductionFlashBundleImportRejectsUnpinnedFactsBeforeUpload`
   — asserted a declaration not matching a pinned build is refused before the
   upload starts. **Restate:** a malformed declaration (non-positive byte count,
   oversized, malformed digest) is still refused before the upload; a
   well-formed declaration for an unrecognised build is accepted and judged on
   commit. This is the test that documents where the judgement moved to.

3. `Dayu20070035RuntimePlanOnlyContractTests.testAuthorizedExecutePlanFactsSelectV2FromExactArchiveAndRejectDrift`
   — asserted the fact port selects the v2 profile from an exact archive.
   **Restate:** the fact port builds a plan for whatever archive it is given and
   refuses one that does not fit the board. "Drift" now means structural
   mismatch, not an unrecognised digest.

4. `Dayu20070035RuntimePlanOnlyContractTests.testProviderSelectsV2PinsAndRejectsPartitionOrArchiveCrossVersionDrift`
   — currently fails as `XCTAssertThrowsError failed: did not throw an error`,
   because a cross-version archive is now legitimately plannable. **Restate:**
   the partition-order half of this test still holds and must stay; the
   archive-version half becomes "a different build plans successfully, and its
   plan records that build's digest and version".

5. `DeviceProviderContractTests.testRockchipMaterializesEveryPublishedRuntimeStepWithoutLegacyAuthorization`
   — see §2. This one is not a restatement: it is correct as written and the
   product must stop failing it.

## 4. Order of work

1. §2 first. It is the only design decision left, and §3.5 passes when it lands.
2. Restate §3.1–§3.4.
3. Add the spec delta for what admission now means — `specs/flashing/spec-r4.md`
   states REQ-FLASH-016/017/018; check whether the wording still matches what
   was built, and extend rather than rewrite.
4. Full `swift test`, `sh scripts/check-sdd.sh`, PR path preflight.
5. Then the GJ-4 device window: this is a `deviceProfile`/E2 change, and
   PRODUCT-LOOP's four-category rule requires it to ship with the Golden
   Journey delivery. The `7.0.0.37` archive on this host is a usable subject —
   it is a genuinely newer build than what the device runs.

## 5. Things worth not rediscovering

- `sh scripts/check-sdd.sh` needs PyYAML **exactly** 6.0.3. Run
  `sh scripts/bootstrap-sdd.sh` once; the system Pythons on this host have
  either none or 6.0.
- A change package's revision must match in three places or `guard` fails:
  `proposal.md` frontmatter, `acceptance-cases.yaml` `change_revision`, and
  `verification.md`'s `@rN`.
- A task created by the PR under review is not authority for that PR's paths.
  This work is covered by `TASK-E2B-001`, whose allowed paths already include
  `Sources/ArkDeckWorkflows/**` and `Tests/ArkDeckContractTests/**`.
- The runtime build version cannot be taken from the archive's name or its
  `daily_build.log`; both state the daily's label. The 2026-07-28 daily is named
  `7.0.0.35`, its log says `7.0.0.35`, and the device answers `7.0.0.36`. Only
  `system.img` tells the truth.
