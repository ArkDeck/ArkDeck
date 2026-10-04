# TASK-XPA-012 — the Windows daemon Bundle: a release-candidate package tree in the Bootstrap registry

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2-B, part B1, on top of the
Bootstrap registry owners (#2428, `windows-bootstrap-owners-run.md`). Host: the Windows 11 x64
reference host, non-elevated, NTFS. No device was contacted, no `hdc` ran, and nothing installed
was read or written. Host tests are not Windows acceptance.

Basis: maintainer ruling 17 (the daemon's signer or publisher identity), decision 11 (the
client-started daemon), and the maintainer's delegation of 2026-09-30 (non-major choices follow
the agent's recommendation, as rulings 18–55 record; ruling 52 refused daemon Bundle registration
until a Windows bundle form exists, which this part supplies); the delegated minor decisions below. The
lead asked for the form: the release-candidate package tree of #2380/#2404, verified against its
manifest and the signer or publisher pin, recorded content-addressed, re-measured on inspection,
and retired by removal.

## The macOS form and its Windows counterpart

| | macOS | Windows |
| --- | --- | --- |
| Source | the daemon helper `ArkDeckAgent.app` | a release-candidate package tree (`package-rc.ps1`'s xcopy form, unpacked): `arkdeck-agentd.exe`, `bin\arkdeck.exe`, the App, `rc-manifest.json` |
| Content check | the bundle tree and `Contents/Info.plist`'s version | the tree holds exactly the files `rc-manifest.json` (`arkdeck.windows-rc-package/1`) names, each with its size and SHA-256, the daemon among them; the version is the manifest's |
| Trust | Security's production helper requirement (team `8AQTYW5FKR`) | `arkdeck-agentd.exe`'s Authenticode signature verifies and is the running Runtime's signer: the same development leaf, or the same production publisher (Artifact Signing root, one `O=`, the same certificate-profile EKU; ruling 17). An unsigned Runtime admits none |
| Tree reading | descriptor-relative, no link followed, owner and mode checked | handle-relative on NTFS (`arkdeck-platform` `windows::bootstrap_tree`), no reparse point followed, each entry owned by the user or a trusted principal and changeable by nobody else; Mark-of-the-Web is provenance, not identity |
| Retained copy | `bundle-<digest>.app` | `bundle-<digest>.rc`, captured through a private `.staging-<nonce>` and published by an exclusive rename; a capture not published removes exactly what it created |
| Content digest | `arkdeck.bundle-content/1` over the entries | the same, with `"platform":"windows"`, so no Windows reference equals a macOS one |
| Record | `bundles.json` record | the same record plus `"platform":"windows"` and `"signer"`; each host reads only its own form |
| Projection | `platform: macos`, `trust.policy: arkdeck.daemon-helper/1`, `teamIdentifier` the team | `platform: windows`, `trust.policy: arkdeck.windows-daemon-package/1`, `teamIdentifier` the signer's name; the published schemas admit both unchanged |

`runtime.bundle.register` checks a captured tree against the store's own policy — the production
policy the daemon composes — rather than a fixed one, so a store that pins another signer
(`with_bundle_validator`, the tests) holds registration and inspection to the same pin. On macOS
the daemon's store uses the production policy, so nothing changes there; the macOS order of the
content comparison and the policy check is kept.

## Delegated minor decisions (pending the next rulings batch)

1. **The Windows daemon Bundle is the release-candidate package tree**, as the lead directed,
   pinned to the running Runtime's own signer or publisher. The Runtime has no other Windows pin
   of its own: the clients' configured pins are theirs, and a production leaf renews daily.
2. **The Windows record carries `platform` and `signer`**, absent from every macOS record, and
   the projection names the signer where macOS names the team; no schema widens.
3. **A tree under a directory others may change is refused** (`admissionDenied`, "the Bundle
   source is changeable by another principal"), as macOS refuses a group- or world-writable one.
   On this host `%TEMP%` grants modify to several sandbox SIDs, so a package is registered from an
   owner-private location such as `%LOCALAPPDATA%\Programs`.

## Open question for the maintainer: how `runtime service update` would consume a Bundle

On macOS `runtime service update --daemon <bundle>` installs the registered helper as the
LaunchAgent and keeps one generation for rollback. On Windows the daemon is client-started from
its installed location (decision 11), and `runtime service install|update` stay refused
(`unsupportedOnPlatform`). This slice leaves `update` refused. Options:

1. **Keep `update` refused; reinstall the release candidate.** A registered package records and
   verifies what was delivered; the MSIX's App Installer feed is the product's update path and the
   xcopy form is replaced by unpacking the next release candidate (the phase A runbook's path).
2. **`runtime service update --bundle <ref>` installs a registered package.** The CLI stops the
   daemon (`runtime service uninstall`, #2411), copies the retained tree to a new versioned
   directory under `%LOCALAPPDATA%\Programs\ArkDeck`, and the next start runs it. It needs an
   installation reference (`installation`, as macOS pins its installed Bundle), a fixed install
   location, and a way to repoint the clients' `ARKDECK_DAEMON_PATH`, which today is installation
   configuration each client reads.
3. **Update only through the MSIX feed**, and register only xcopy packages for inventory.

**Recommendation: option 1 now.** It needs no new installation state and matches how the
release candidate is delivered today. Option 2 can follow if an in-place xcopy update is wanted;
it is the natural consumer of this registry, but choosing the install location and how the
clients learn the new path is a product decision.

## Tests on Windows

- **`arkdeck-platform` `windows::bootstrap_tree`**: a tree is walked in path order with every
  file hashed, reopened by relative path against its snapshot, and changes when a file does; a
  junction or a relative path refuses it; a capture copies the tree privately, publishes once, a
  second capture meets the published copy and leaves it, a source changed after capture is
  refused, and every unpublished capture removes what it created.
- **`arkdeck-bootstrap/tests/windows_bundle_registration.rs`** (development signer): a package
  registers (`platform: windows`, the signer as `teamIdentifier`, conforming to the published
  `runtime.bundle.register|inspect` schemas); again with no write; inspect and list; a changed
  source leaves the retained copy valid; refusals with nothing written and no staging left: a tree
  that no longer matches its manifest, a file the manifest does not name, an unsigned daemon, a
  relative, `/`-spelled or `..` path; retirement once, a retry answering the same receipt; a
  tampered retained copy no longer verifies.
- **`arkdeck-bootstrap` `registry` tests**: each host reads only its own record form.
- **`arkdeck-agentd/tests/windows_bootstrap_owners_process.rs`**: over the pipe of the unsigned
  development daemon, an absent package is `fileIdentityChanged` and a package of its own image is
  `admissionDenied` (an unsigned Runtime pins nothing), writing nothing; through the signed CLI
  against the dev-signed daemon, a package whose daemon is that image registers, re-registers,
  inspects and lists, reads back after a restart, retires, reads back retired after another
  restart, and is not registered again. The test asserts `runtime bundle register|inspect|remove`
  are `implemented` in the rendered coverage.

## Coverage

`runtime.bundle.register`, `runtime.bundle.inspect` and `runtime.bundle.remove` join
`WINDOWS_MEASURED_LEAVES`; `cli-feature-coverage.json` regenerated with `arkdeck maintainer
contracts export` and its six oracle pins substituted (figures in the commit message).

## Local checks

See the commit message.
