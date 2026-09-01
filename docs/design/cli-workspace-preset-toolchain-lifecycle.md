# CLI workspace preset and DevEco toolchain lifecycle

Task: TASK-AIN-021

This slice completes the build/test half of CLI-REQ-022 without introducing a
second workspace executor. A fresh macOS host can register an existing DevEco
installation, pin it from a typed workspace preset, restart the Runtime, and
use the existing `workspace.build-openharmony@1` or
`workspace.run-tests@1` Job paths. No caller-provided executable, argument
array, SDK path or shell command crosses the preset boundary.

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

The target protocol 2 surface now provides:

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

Toolchain acquire/release is a recoverable cross-store transaction: the
project document first records the pending action, applies the toolchain pin
change, publishes the preset state, and clears the pending action. Startup and
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

The signing preset schema is durable and path-free, but production composition
keeps it unavailable with `workspace.signingCredentialOwnerUnavailable` until
the separate credential-reference owner is implemented. This change therefore
does not claim signing execution or real-device acceptance. Real-device build,
test and signing evidence must be collected only after the relevant code is on
protected `main` and the current Catalog digest is pinned.
