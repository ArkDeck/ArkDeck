# TASK-DHA-006 r10 — the publish that a platform without fs-verity can actually pass (2026-08-06)

## Status: `DHA-VERITY-001`, `-002`, `-003` all PASS

`deploy.native-library.app-owned@1` now publishes on a DAYU200 running
OpenHarmony 7.0.0.37, where it previously could not publish at all.

- Baseline: `main@81e1636c` plus this change
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa` (unmoved)
- Target: `TGT-958780b2ffb7`, binding revision `2`, firmware `OpenHarmony-7.0.0.37`
- Job: `job-0ceaecb9fddb3596b564d6ff3549bc55`, terminal `succeeded`

## `DHA-VERITY-003` — real hardware

```
verified backup-current-version   ["backupPath", "backupSha256"]
verified atomic-publish           ["attestation", "buildId", "gid", "mode",
                                   "publishedSha256", "targetPath", "uid"]
verified restart-target           ["stopped"]
verified start-target             ["processIds", "started"]
verified verify-loaded-library    ["abi", "attestation", "buildId", "publishedSha256"]
verified cleanup-staging-and-backup ["backupRetained", "cleaned"]
terminal: succeeded
```

Read back from the device afterwards, not from the job record:

```
-rw-r--r-- 1 3060 3060 24232 …/com.example.scrollablecomponentstatic/libs/arm/libarkdeck_gj.so
c20fcd9b29b46ae06a312aa2db6f053672fef82d80f7b482f0f90d154c80f2d3  (== the leased hash)
```

Content is exactly the leased ELF; mode, uid and gid are the ones the replaced
file had. `publish-report.json` records what was actually achieved:

```json
{ "attestation": "matchesReplacedFile:none",
  "publishedSha256": "c20fcd9b…", "mode": "-rw-r--r--", "uid": "3060", "gid": "3060" }
```

No `fsVerityDigest` field — not an empty string, not a placeholder. A record
carrying that field reads as a file that has the property, and this one does
not. The same is visible in the timeline above: the key is absent from both
`atomic-publish` and `verify-loaded-library`.

## What changed, and what deliberately did not

The replaced file decides. Publish measures it before writing anything, and
the helper's `enable` sits inside that branch — so on a platform that attests
nothing there is no enable to fail. Three verification points asked for
fs-verity on the published library (`atomic-publish`, `targetMatchesArtifact`,
`targetLoaded`); all three now ask for "at least as attested as the file it
replaced", reading the **backup**, which is a hard link to that file and still
answers for it after the rename.

Unchanged: an attested original still demands an attested replacement, the
helper's announced digest must still agree with the device's readback, and a
refused `enable` still cannot reach the `rename` — so the live library is never
replaced by a file whose attestation was refused.

## Three things found by building it, each of which would have passed anyway

**A missing readback is not an answer.** The check "did the replaced file carry
fs-verity" originally read a parsed digest, and its absence meant "no". But an
absent digest is also what a backup that is *not there to read* produces — so a
missing backup would have licensed publishing a library with no attestation.
The two are told apart by the errno the helper records at the failing call:
`ENODATA` (and `EOPNOTSUPP`) are answers about a file that exists, anything
else is not. This is the first thing that fix has bought beyond diagnosis.

**The fixture modelled a device that does not exist.** The scripted receipt for
an unattested `verify` put the helper's diagnostic on stderr with a non-zero
exit, which is what the helper does. HDC does not: it merges a remote command's
streams onto stdout and reports its own exit status. Every contract test passed
against that fixture, and the first real run failed. Both the parser and the
fixture now match what a device returns.

**A stale daemon, again.** The first device attempt ran the new helper against
the old plan — `subprocessCount=5` when the new plan has six. `swift build -c
release --product arkdeck-agentd --product arkdeck` had relinked only
`arkdeck`. The check that settles it is not the build log but the binary:
`strings … | grep PUBLISHED_UNATTESTED`.

## `DHA-VERITY-001` / `-002` — contract

1344 tests, 0 failures. Both invariants were checked by breaking them:

- Remove the "attested original demands an attested replacement" guard →
  `testAttestedLibraryCannotBeReplacedByAnUnattestedOne` goes red.
- Rewrite the helper as "try `enable`, carry on if it fails" — the shape the
  task names as its meta-constraint →
  `testTheCodeSignHelperDecidesByMeasurementNotByAFailedEnable` goes red.
- Accept `ENOENT` as "this file has no fs-verity" →
  `testAnUnreadableBackupIsNotTakenAsProofTheOriginalHadNoAttestation` goes red.

The helper's branch is checked at the source, because nothing in the suite can
run an arm64 device binary and observe which path it took.

## Coverage, stated honestly

Not exercised: the attested branch on real hardware. No file this device will
let us attest exists — that is the whole finding — so the strict path is
covered by contract only, and the device leg proves the permissive one. If a
future firmware attests app-owned libraries, the strict branch becomes
reachable and `DHA-VERITY-001`'s first bullet is what will exercise it.
