# CLI workspace preset and DevEco toolchain lifecycle

Task: TASK-AIN-021

This slice completes CLI-REQ-022 without introducing a second workspace
executor. A fresh macOS host can register an existing DevEco installation and
path-free signing credential, pin them from typed workspace presets, restart
the Runtime, and use the existing build, test, or signing Job paths. No
caller-provided executable, argument array, SDK path or shell command crosses
the preset boundary.

## Registered DevEco toolchains

The pre-daemon tool owner now accepts the closed `deveco` root shape in
addition to copied HDC candidates:

```text
arkdeck runtime tool register --kind deveco \
  --root /Applications/DevEco-Studio.app/Contents
arkdeck runtime tool list --page-size 100
arkdeck runtime tool inspect --tool toolchain:sha256:<digest>
arkdeck runtime tool remove \
  --tool toolchain:sha256:<digest> --expected-generation 1
```

`--file` is valid only for `hdc`; `--root` is valid only for `deveco`. The
registration owner opens every root and child component with no-follow
semantics, pins the root device/inode/change identity, and accepts only the
versioned DevEco product and OpenHarmony SDK manifests plus these closed child
roles: the bundled Node executable, the Hvigor entry script, and the signed
resource envelope. Public `arkdeck.runtime-tool/1` values contain hashes,
versions, trust and references, never any of those paths.

DevEco's SDK manager can update resources after the app is signed, so a full
app-resource validation can fail even when the selected child roles are still
publisher-owned. Registration therefore validates the app's native code pages,
CMS signature, identifier `com.huawei.devecostudio.ds` and Huawei team
`TZEA3TN37Q` while excluding mutable bundle resources from that one check. It
then requires the exact SHA-256 of every allowlisted child role to match the
SHA-256 table in the code-directory-sealed `_CodeSignature/CodeResources`.
The Node executable also passes its own strict native-code validation. An
invalid publisher signature, an unsealed/mismatched role, a missing manifest,
unsafe ancestry or any later identity drift fails closed.

The DevEco registry and copied HDC registry share one cross-process owner and
one atomic inventory snapshot. A content-derived toolchain reference remains
generation 1 while available and becomes a generation-2 tombstone on removal.
Each workspace preset acquires an exact `workspacePreset` pin before its record
is published. A pinned toolchain cannot be removed. Toolchain resolution is
private, requires that exact pin, and remeasures the root and all allowlisted
children before returning paths to Runtime composition.

## Typed workspace presets

The target current v1 surface now provides:

```text
arkdeck workspace preset list --project <project-ref> [--kind build|test|signing|symbol]
arkdeck workspace preset show --project <project-ref> --preset <preset-ref>
arkdeck workspace preset register \
  --registration-request-id <id> --project <project-ref> \
  --kind build --template openharmony.hvigor-build@1 \
  --toolchain toolchain:sha256:<digest> --toolchain-generation 1 \
  --timeout-seconds 1800 --module entry --product default --build-mode debug
arkdeck workspace preset update \
  --mutation-request-id <id> --project <project-ref> --preset <preset-ref> \
  --expected-generation <n> <complete-typed-definition>
arkdeck workspace preset remove \
  --mutation-request-id <id> --project <project-ref> --preset <preset-ref> \
  --expected-generation <n>
```

The owner recognizes only these exact kind/template pairs:

| kind | template | definition |
|---|---|---|
| `build` | `openharmony.hvigor-build@1` | toolchain generation, module, product, build mode |
| `test` | `openharmony.hvigor-test@1` | toolchain generation, module, product, build mode |
| `signing` | `openharmony.local-sign@1` | toolchain generation and credential reference |
| `symbol` | `openharmony.arkts-symbol@1` | bounded project-relative source-map path |

Registration IDs and mutation IDs are caller-stable. Same-ID/same-intent retry
returns the original result; a different intent is an idempotency conflict.
Update/remove use exact-generation CAS. Project removal and kind changes reject
active presets. Preset/project Job acquisition, mutation and the durable Job
reference scan run under the same owner serialization, so no mutation can
publish a dangling reference or race an admitted Job.

External dependency acquire/release is a recoverable cross-store transaction:
the project document first records the pending action, acquires the complete
new toolchain/credential set, publishes the preset state, releases the old
set, and clears the pending action. All operations are idempotent. Startup and
every store read finish an interrupted transaction before serving data. The
public projection remains path-free and reports `runtimeRestartRequired` until
the daemon observes that exact generation.

At startup, build/test presets resolve only through their retained toolchain
pin. Runtime derives the fixed Hvigor operation and argument array from the
typed module/product/build-mode fields, scopes `DEVECO_SDK_HOME` to the exact
Node executable, and binds the Hvigor script, signed resource envelope and
version manifests as Process-layer verified resources. The dispatcher opens
and revalidates those resources together with the Node executable immediately
before spawn. A registered OpenHarmony project with no active build/test preset
stays read-only; it does not fall back to daemon environment paths.

A DevEco auto-signing keystore is unlocked by machine-generated ciphertext a
person never sees, so `runtime signing install` also accepts
`--build-profile <DevEco build-profile.json5>`: the encrypted `storePassword`
and `keyPassword` are read from the profile that names the same `storeFile`
as `--keystore` and decoded at the same boundary the terminal prompt uses. A
headless host can therefore install the profile a device already trusts (the
debug profile listing its UDID) without a TTY; `migrate-deveco` stays the
re-keying path for a preset that is already installed with that keystore.

`runtime signing install-sdk-release|install` now wraps the existing measured
receipt and Keychain envelope in `arkdeck.signing-credential/1`. Its
content-derived `credential:sha256-*` reference contains no host path,
Keychain account, or secret. The cross-process owner refuses replacement and
removal while any workspace preset pins the reference; daemon identity refresh
must preserve it, while `migrate-deveco` is treated as a replacement because it
may change the key alias. Status, maintenance, and
removal projections remain path-free.

At startup, a signing preset must resolve both its exact toolchain pin and its
exact credential pin. The provider accepts the workspace preset reference from
the Job, resolves the credential only for that owner, and records the workspace
preset reference in the materialized plan, signing result, and recovery
readback. The lower-level fixed receipt ID is never a fallback for a registered
profile. Real-device build, test, and signing evidence is collected only after
the relevant code reaches protected `main` and the current Catalog digest is
pinned.
