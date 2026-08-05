# GJ-3 Native Debug — current-digest re-verification attempt (2026-08-05)

## Scope and target

- Baseline: `main@bf6edbe3` (after #1071, #1072)
- Catalog digest: `e2f8eb6592aaeeec37c63a01708db2325b38c798b0f8272228ba0fccc2cfd0aa`
- Target: `TGT-958780b2ffb7`, binding revision `2`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Executor: Device Runtime Agent over `arkdeck-agentd`. Manual HDC commands:
  read-only inspection only (`ls`, `find`, `bm dump`); every mutation went
  through typed product operations.

## Status: GJ-3 stays `IMPLEMENTING` on the current digest

The 2026-07-30 record (`gj3-native-debug-xpm-pass-2026-07-30.md`) remains the
only full-chain `REAL_DEVICE_PASS`, and it was taken on catalog digest
`1ee1c1a6…`. This run did **not** reproduce the full forward chain on the
current digest. What it did establish is recorded below; nothing here is
claimed as a pass.

## What the current digest did verify on real hardware

`deploy.native-library.app-owned@1`, job
`job-620f7283af3487e620bbc7b1bf259da8` (and a second identical-shaped run):

- `verify-elf-locally` and `hash-library` verified a freshly built, freshly
  signed candidate (`abi=arm64-v8a`,
  `buildId=49e745d56f476d6cec0c4108c615a57e4412bd8c`).
- `send-to-staging` and `verify-remote-staging` verified: the library reached
  the stable job-owned staging path and its remote hash and build ID matched
  the pinned host facts.
- `backup-current-version` **refused** because the app-owned library the
  request names is absent on the device, and the refusal carried the full
  command-by-command diagnostic (directory listing, target listing, hash,
  hard-link attempt, backup listing — each with exit status and captured
  bytes).
- `cleanup-native-library-compensation` verified `cleaned`, and the job
  finalized `failed` with `outcomeUnknown=false` and
  `outstandingResidueCount=0`.

That is the safety half of the GJ-3 chain — a candidate that cannot be safely
published is refused before publication, compensated, and left with zero
residue and no unknown state — reproduced on the current digest.

## Why the forward chain did not run: the app, not the product

`deploy.native-library.app-owned@1` publishes **over an existing app-owned
library**: `backup-current-version` runs before publication and requires the
target file to be present. So the chain needs an installed application that
ships a native library under the exact logical name being deployed. Producing
one on this host turned out to be a packaging problem, not a product problem.
The constraints, each established by measurement:

1. **The DAYU200 runs 32-bit application processes.** The 2026-07-30 record
   already showed the AArch64 candidate rejected by the loader with
   `Exec format error` and the `armeabi-v7a` candidate succeeding. The product
   maps that ABI to the device path `libs/arm`.
2. **A HAP whose only native ABI is `arm64-v8a` installs with no libraries at
   all.** After installing the stock WaterFlowLayoutDemo build,
   `bm dump -n com.example.waterflowdemo` reports `cpuAbi: ""`,
   `nativeLibraryPath: ""`, and the bundle directory holds only `entry.hap` —
   no `libs/` at all.
3. **`compressNativeLibs: false` alone does not change that.** A rebuild with
   that flag reached the device (verified: the installed
   `deployedArtifactSha256` is the new
   `f1e23c7cbac67ae682f6a99a5d0a5cf8460f7c6fe829f7fe2f0e2d5c9a0ce304`), and
   `bm dump` still reported `isCompressNativeLibs: true` with an empty
   `cpuAbi` — because the package still carried no ABI this device can load.
4. **hvigor will not build the needed package shape from this host's
   configuration.** In sequence, each refusal naming the next requirement:
   `armeabi-v7a` is rejected for a `runtimeOS: HarmonyOS` product (00303114);
   switching to `runtimeOS: OpenHarmony` requires an explicit
   `compileSdkVersion`; that requires `OHOS_BASE_SDK_HOME`; then
   `armeabi-v7a` is rejected "as the only option"; then the module's declared
   device types have an empty syscap intersection under OpenHarmony
   (`SyscapTransform`). The sample app that carried the 2026-07-30 library
   (`ScrollableComponentStatic`) cannot be built here at all: it is an ArkTS
   1.2 static project whose build driver ships only in DevEco Studio's bundled
   SDK, which this hvigor rejects as an outdated SDK layout.

Two host faults were also found and cleared along the way, both of which
present as timeouts or unexplained build failures rather than as permission
errors: macOS quarantine on the OpenHarmony SDK's `clang`/`llvm` and on
`cmake/ninja` (the same fault class that blocks `hdc` on first use).

## What would close GJ-3 on the current digest

One artifact: a signed HAP for an application that ships an `armeabi-v7a`
app-owned native library, installed so that the library lands at
`/data/app/el1/bundle/public/<bundle>/libs/arm/<name>.so` — i.e. a DevEco
Studio build of the kind used on 2026-07-30. With that installed, the
already-prepared, already-imported signed candidate can be deployed straight
through the recipe; the host side of this run (cross-compiled `armeabi-v7a`
and `arm64-v8a` libraries, an OpenHarmony V1 ELF sign block produced with
`hap-sign-tool -inForm elf`, a locally minted certificate chain and provision
profile, and both artifacts imported under binding revision 2) is done and
reusable.
