# GJ-3 Native Debug — DAYU200 XPM pass (2026-07-30)

## Scope and target

- Baseline: `main@756421ae`
- Catalog digest:
  `1ee1c1a68486f45f8406fd362770655eb9d5dc983e1da27a87235d95eeb01a94`
- Target: `TGT-958780b2ffb7`, binding revision `1`
- Stable identity SHA-256:
  `958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e`
- Device: DAYU200, OpenHarmony `7.0.0.36`, HDC `3.2.0f`
- Executor: Device Runtime Agent. Manual HDC commands: `0`.

## Product correction

ArkDeck now ships an auditable static arm64 helper that consumes only an
already-signed OpenHarmony V1 ELF sign block. The Provider sends the helper and
library to the same stable job-owned directory, pins both identities in the
persisted typed action, copies the candidate beside the live target, enables
and measures code signing, and atomically renames only after successful
readback. Import, submit, recovery, rollback and cleanup fail closed on missing
or drifted library/helper facts.

The successful candidate was `armeabi-v7a`; the earlier AArch64 candidate was
truthfully rejected by the 32-bit application loader with `Exec format error`
and automatically rolled back. No failed or unknown mutation was resent.

## Real-device result

The Runtime Agent imported the signed ELF as
`ART-a7889d01623721c8e041a4fb344d6f79` and completed
`deploy.native-library.app-owned@1` in
`job-7af1bb156ae0a83468985674bfc157a5`.

- Job state: `succeeded`
- Actual effect: `E1`
- Authority:
  `CAP-RT-POLICY-68AE4AC1EDA9544928CAEBCE6A87BF01A0015080-G1`
  (automatic standing policy envelope)
- Human actions: none
- Candidate ABI / Build ID:
  `armeabi-v7a` /
  `c6c00c3691955f80d8d174344270d7b8fae6c1ea`
- Candidate SHA-256:
  `0566a7b675292dfc9e078a000d8bb9e1c6e211f728bda8f8ef7041e08acf383a`
- fs-verity digest:
  `d5290d828430f9886f93906b41249db0efef2b8b7d43efc1876568f4caa1bf9f`
- Publish Artifact:
  `ART-f370f54bc05e4a499d642f1951207ef9`
- Verification Artifact:
  `ART-0c05f2cfd8e766dc618c44b4b00055a9`
- Loader readback: `loaderVerified=true`, process `8826`, exact target path
  present in process maps
- Cleanup readback: staging library, helper, job directory, rollback staging
  and backup all absent
- `outcomeUnknown=false`

Only ArkDeck CLI/daemon typed APIs touched the device. The host-side build and
signing tools produced the input Artifact; no operator or Agent issued an HDC
command directly.

## Verification

```text
CI=true swift test --package-path Packages/ArkDeckKit \
  --filter NativeLibraryDeploymentContractTests
```

Result: `9` tests passed.

```text
CI=true swift test --package-path Packages/ArkDeckKit
bash scripts/check-sdd.sh
```

Result: `760` tests executed, `1` skipped, `0` failures; SDD guard reported
`0 error(s), 0 warning(s), 114 acceptance IDs`. The helper rebuilt from the
documented OpenHarmony SDK command was byte-identical to the bundled resource
(`dac8c629b329a83ffcd6df766c4893780ff34a5db14f9d607b70c8801373e8dd`).

## Golden Journey conclusion

GJ-3 is `REAL_DEVICE_PASS`. This record supersedes only the product-blocker
conclusion in `gj3-native-debug-xpm-stop-2026-07-30.md`; the earlier failed
attempts and rollback evidence remain unchanged and truthful.
