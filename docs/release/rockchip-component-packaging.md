# Rockchip bundled-component packaging contract

This document defines the TASK-BRC-003 release boundary for
`rkdeveloptool@1.32`. The machine-readable facts live in
`openspec/integrations/rockchip/bundled-component/1.0.0/package.json`; the
packager and its mutation tests enforce those facts without changing the
accepted source/build/distribution records.

## Atomic release shape

The only accepted product tuple is:

- App target `ArkDeck`, bundle identifier `com.arkdeck.desktop`, version
  `0.1.0` (`1`), arm64 only, minimum macOS 14.0;
- component at `ArkDeck.app/Contents/MacOS/rkdeveloptool`, signing identifier
  `com.arkdeck.desktop.rkdeveloptool`, arm64 only, minimum macOS 14.0;
- the five exact reviewed files at
  `Contents/Resources/RockchipComponent/1.0.0/`: `registry.yaml`,
  `recipe.json`, `sbom.spdx.json`, `THIRD-PARTY-NOTICES.txt`, and
  `source-distribution-manifest.json`;
- one HFS+ UDZO `ArkDeck-0.1.0-arm64.dmg` whose root contains only
  `ArkDeck.app` and `THIRD-PARTY-NOTICES.txt`;
- the accepted source/component/SBOM/notices tuple and the notarization
  submission recorded in one receipt.

The component is not an independent update/download unit. A changed App
version, component binary, source, dependency, SBOM, notice, manifest,
signature identity, or package policy creates a different tuple and invalidates
the old package evidence.

## Entitlements and signing

The App retains exactly its existing six sandbox/device/file/network
entitlements. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` remains disabled.

The child entitlement dictionary is intentionally empty. The Runtime Broker is
a standalone daemon, so an inherited App Sandbox profile would trap during
`libsecinit` before the helper can run. The child remains fixed-path,
Developer-ID-signed, Hardened-Runtime-protected, and strictly verified;
`get-task-allow`, App Sandbox inheritance, child USB/file/network capabilities,
and Hardened Runtime exceptions are forbidden. Xcode embeds the externally
built child through the named `Embed Rockchip Component` Copy Files/Executables
phase with Code Sign On Copy. A separate named phase copies the five metadata
files into the fixed resource location.

The release archive uses one approved Developer ID Application certificate for
the child and App, inside-out, with Hardened Runtime and secure timestamps.
The same Team/certificate signs the DMG. `codesign --deep` is never used to
sign; `--deep --strict` is limited to final read-only verification.

## Fail-closed order

The packaging order is fixed:

```text
exact unsigned input inspection
  -> fresh ad-hoc ingest signature
  -> Xcode Release archive / Code Sign On Copy
  -> independent child and App inspection
  -> fixed-layout DMG creation and signing
  -> outermost DMG notarization + sanitized log
  -> staple and validation
  -> DMG Gatekeeper
  -> read-only mount + contained App Gatekeeper
  -> immutable receipt
```

No stage may be skipped or reordered. A self-reported manifest field does not
replace `file`, `lipo`, `otool`/`vtool`, `codesign`, `hdiutil`, `notarytool`,
`stapler`, `spctl`, file-set, size, or digest inspection.

The packager deletes its candidate on any missing/wrong/non-regular/symlink
input; size/hash/architecture/minimum-OS/load/dependency drift; wrong nested
path/identifier; missing/extra entitlement; ad-hoc/development/mixed-Team,
expired, untrusted, untimestamped, or non-runtime signature; App version/shape
drift; missing/extra/drifted metadata or nested code; malformed/unsigned DMG;
Rejected/Invalid/Unknown or missing notarization log; staple/Gatekeeper
failure; or mixed atomic tuple.

## Evidence and privacy

The accepted evidence consists of independent command conclusions, a sanitized
notary log, and the immutable package receipt. It may contain public
certificate/Team facts, artifact/package digests, and the notarization
submission ID. It must not contain the Apple account, Keychain profile
name/path, password, token, private key, raw ticket body, or temporary/user
absolute paths.

The task does not install or launch the App/component and does not access HDC,
USB, hardware, E1/E2 authority, or a device. It does not upload a GitHub
Release, publish an update feed, or claim clean-host/runtime/device acceptance;
those remain separate successor work.
