# GJ-3 Native Debug — REAL_DEVICE_PASS on the current catalog digest (2026-08-05)

## Scope and target

- Baseline: `main@a672df83`
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
  (read back from every job record and from both published reports)
- Target: `TGT-958780b2ffb7`, binding revision `2`,
  materialized stable identity `958780b2ffb7…23dc7a7e`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Executor: Device Runtime Agent over `arkdeck-agentd`. Every device mutation
  went through a typed product operation; manual HDC use was read-only
  inspection (`ls`, `sha256sum`, `bm dump`, `hilog -x`) for independent
  confirmation of what the product reported.

## The packaging blocker from `gj3-current-digest-attempt-2026-08-05.md` is cleared

That record left GJ-3 one artifact short: a signed HAP for an application that
ships an `armeabi-v7a` app-owned native library, installed so the library lands
at `/data/app/el1/bundle/public/<bundle>/libs/arm/<name>.so`. Its four measured
constraints all still hold; what was missing was a build configuration that
satisfies them at once. The official OpenHarmony CLI wrapper
(`@deveco/deveco-cli` 1.2.1, `openharmony-sig/deveco-cli`) produces it:

1. `devecocli create` scaffolds the project; a NAPI module (`libarkdeck_gj.so`)
   is added under `entry/src/main/cpp` and imported by the entry page, so the
   application actually loads it at launch — which is what makes a loader
   readback meaningful rather than a file check.
2. `abiFilters: ["armeabi-v7a"]` is refused for a `runtimeOS: HarmonyOS`
   product (`00303114`). Switching the product to `runtimeOS: OpenHarmony`
   moves the refusal to `00303115`: `armeabi-v7a` is rejected **as the only
   option**, and the error names the fix — add `arm64-v8a`. With both ABIs
   declared, `compileSdkVersion` set, and the module's `deviceTypes` set to the
   OpenHarmony `default` type, `devecocli build` succeeds.
3. `compressNativeLibs: false` in `module.json5` is what makes the installer
   extract the libraries instead of leaving them inside `entry.hap`.

Device confirmation after installing through `debug.hap@1`
(job `job-b5e71713e2d859a2dc8dfc4a50b7dcfe`, `succeeded`):

```text
/data/app/el1/bundle/public/com.example.scrollablecomponentstatic/libs/arm/
  libarkdeck_gj.so    4392
  libc++_shared.so    1110592
hilog: A00000/ArkDeckGJ3: marker=arkdeck-gj3-baseline-v1
```

The candidate library is signed with `hap-sign-tool sign-app -inForm elf`.
Two host-side facts cost a full diagnosis each and are worth recording:
the app certificate file must be a **three**-certificate chain — `keytool
-gencert` emits the issuing certificate alongside the leaf, so a naive
`cat leaf ca root` yields four and the tool refuses with `verify certificate
chain failed! Signature does not match.` — and the provision profile must
carry `bundle-info.app-identifier`, without which code signing fails as the
unhelpful `The block head data made failed.`

## Forward chain — `job-338cf635f9bf8b012ff96cca37a53a79`, `succeeded`

`deploy.native-library.app-owned@1`, inputs `expectedABI: armeabi-v7a`,
`restartProfile: restartAbility`, `verificationProfile: hashProcessAndMaps`,
`rollbackPolicy: autoRollback`. Authority
`CAP-RT-POLICY-EA5F8B5477E969839CEBC3A5B1F9C789815D6FD6-G1`
(automatic standing policy envelope), effect `deviceMutation`, consumed
before the first mutation.

Every leg of the PRODUCT-LOOP GJ-3 chain, each `verified` against a readback:

```text
verify-elf-locally    abi=armeabi-v7a buildId=ba7d5110d13be1f3c0348e9bd6f2d613ca32169f
hash-library          sha256=c20fcd9b29b46ae06a312aa2db6f053672fef82d80f7b482f0f90d154c80f2d3
send-to-staging       → verify-remote-staging [buildId, remoteByteCount, remoteSha256]
backup-current-version                        [backupPath, backupSha256]
atomic-publish                                [buildId, fsVerityDigest, gid, mode,
                                               publishedSha256, targetPath, uid]
restart-target → start-target                 [stopped] / [processIds, started]
verify-loaded-library                         [abi, buildId, fsVerityDigest,
                                               loaderVerified, processIds, publishedSha256]
cleanup-staging-and-backup                    [backupRetained, cleaned]
```

`verification-report.json` (`ART-9c70c86ab9a9b5d571dedd3ac2a1ce75`):

```text
loaderVerified    true
processIds        11045
publishedSha256   c20fcd9b29b46ae06a312aa2db6f053672fef82d80f7b482f0f90d154c80f2d3
fsVerityDigest    bc426f1e4f3e552ac531d6188793845e420100a1e6321e2dc702a2095b652fdd
catalogDigest     e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa
```

`publish-report.json` (`ART-c8d104ed3457dd9823a6e061f273f623`) records the exact
target path `/data/app/el1/bundle/public/com.example.scrollablecomponentstatic/
libs/arm/libarkdeck_gj.so`, mode `-rw-r--r--`, uid/gid `3060`.

Independent device confirmation that the newly published code is the code that
runs — the candidate returns a different marker string from the baseline:

```text
hilog: 11045 I A00000/ArkDeckGJ3: marker=arkdeck-gj3-candidate-v2
```

`outcomeUnknown=false`, `outstandingResidueCount=0`.

## Diagnostics against the deployed library — `job-8ed816b7095ed77b7a4d903713d167b8`

The chain's "collect crash / HiLog / dump / trace" leg is expressed by
`capture.diagnostics@1` scoped to the application now running the published
library, so it is recorded separately rather than claimed from the deployment
job:

```text
application-liveness.json  state HEALTHY, processState RUNNING, pidObserved true,
                           reasonCode targetProcessRunning, targetBindingRevision 2
hilog.txt                  856,146 bytes of real device log
ui-dump.json               live WindowManagerService window inventory
crash-index.txt            honestly `missing` — not selected by the request inputs
```

## Failure and rollback chain — `job-ad7b0bca8c005bfc63ac51380c1cb8a0`, `failed`

The last two legs of the GJ-3 chain (automatic rollback on failure, then
verify again) need a candidate that passes every host-side check and still
cannot be loaded by the device. One was built for exactly that: the same NAPI
source, linked `-Wl,--no-as-needed` against a stub `libarkdeck_ghost.so` that
is never shipped, so the ELF carries a `DT_NEEDED` entry that cannot resolve.
It is a valid `armeabi-v7a` ELF32 with a GNU build ID and a valid OpenHarmony
code sign block, so import and local verification accept it truthfully.

```text
verify-elf-locally / hash-library            (host, verified)
send-to-staging → verify-remote-staging      (verified)
backup-current-version                       (verified)
atomic-publish                               (verified)
restart-target                               (verified: stopped)
start-target      FAILED  nativeTargetNotRunning: com.example.scrollablecomponentstatic
                          did not start
rollback-native-library   verified [processIds, restored, restoredSha256]
                          "native deployment failure restored previous library"
cleanup-native-library-compensation  verified [backupRetained, cleaned]
terminal: failed — nativeTargetNotRunning …   outstandingResidueCount = 0
```

Independent device confirmation that the rollback restored the exact previous
library and the application recovered:

```text
sha256 /…/libs/arm/libarkdeck_gj.so
  = c20fcd9b29b46ae06a312aa2db6f053672fef82d80f7b482f0f90d154c80f2d3   (the v2 candidate)
hilog: 11561 I A00000/ArkDeckGJ3: marker=arkdeck-gj3-candidate-v2
staging residue: none
```

## Golden Journey conclusion

**GJ-3 is `REAL_DEVICE_PASS` on the current catalog digest**, full scope: the
forward chain (verify → hash → staging → remote hash → backup → atomic publish
→ restart → loader verification in the live process maps → diagnostics against
the deployed library → cleanup) and the failure chain (publish → start refused
→ automatic rollback → compensation cleanup → re-verified restored state), each
with zero residue and no unknown outcome. The 2026-07-30 record on digest `1ee1c1a6…` remains history; this one
stands on `e2f8eb65…`.
