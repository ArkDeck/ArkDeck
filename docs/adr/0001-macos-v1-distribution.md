# ADR-0001 — macOS v1 distribution

- Status: proposed; effective only when this branch is reviewed and merged by
  the maintainer
- Date: 2026-07-15
- Change: `CHG-2026-001-macos-m0a`
- Decision owner: maintainer (`@lvye`)
- Core baseline: `CORE-1.0.0`
- Platform input: `PLATFORM-MACOS@0.1.0`

## Decision

ArkDeck v1 will have exactly one macOS distribution path:

> A **non-Sandboxed**, Developer ID Application-signed ArkDeck app, built with
> Hardened Runtime, distributed in one notarized DMG for the declared
> `macOS 14 / arm64` support cell.

The app will not bundle HDC. It will retain the external-first tool model and
will assess each selected external HDC independently. The DMG path is the only
v1 package path; ZIP, Mac App Store, dual Sandbox/non-Sandbox builds, unsigned
builds, and ad-hoc builds are not v1 distribution paths.

This selects the target distribution architecture; it does **not** assert that
the selected artifact exists or is releasable. No Developer ID identity or
clean-VM controller was available during M0A. Release remains blocked until the
evidence gates below are satisfied.

## Exact v1 entitlement set

The selected non-Sandbox app requests no application entitlements:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

In particular, the selected app does not request:

- `com.apple.security.app-sandbox`;
- `com.apple.security.device.usb` or
  `com.apple.security.device.serial`;
- `com.apple.security.network.client` or
  `com.apple.security.network.server`;
- `com.apple.security.files.user-selected.read-write` or
  `com.apple.security.files.bookmarks.app-scope`;
- `com.apple.security.get-task-allow`; or
- any Hardened Runtime exception listed in `PLATFORM-MACOS@0.1.0`, including
  JIT, unsigned executable memory, disabled library validation, DYLD
  environment variables, or disabled executable-page protection.

Hardened Runtime and notarization are signing/distribution controls, not
entitlements. If implementation later proves that any entitlement or runtime
exception is necessary, this decision must be revisited before that setting is
added to a release build.

## Evidence considered

M0A established the following facts:

- The ProcessExecutor prototype passes shell-free argv, separated-stream,
  bounded-output, timeout, cancellation, and process-tree fixtures.
- The host-wide supervisor fixtures prove conservative ownership and lifecycle
  gates for their declared cases, but do not yet provide a real supervised HDC
  integration or the full `MAC-M0A-HDC-002` row.
- A locally ad-hoc-signed Sandboxed Release prototype launches and its actual
  entitlement dump is recorded. This is not Developer ID, Hardened Runtime,
  notarization, Gatekeeper, file-access, transport, or hardware evidence.
- The clean-VM trust rows are blocked because the VM and Developer ID
  prerequisites are absent.
- The real USB/UART/TCP and selected-file matrix is blocked because the app has
  no supervised read-only probe surface. Direct Terminal use of HDC is not a
  substitute.

The evidence and its exact SHA-256 index are recorded under
`openspec/changes/chg-2026-001-macos-m0a/evidence/runs/TASK-M0A-006/`.

## Rationale

ArkDeck's v1 scope depends on externally installed HDC tools, host-wide server
supervision, direct USB/UART/TCP diagnosis, and user-selected image/key/output
paths. The Sandboxed prototype proves only that one ad-hoc app with candidate
entitlements can build and launch. It does not prove that PowerBox access is
usable by an external child process or that all device transports work through
the app.

Choosing the non-Sandbox path avoids making the unverified Sandbox/child-file
access boundary part of the v1 release contract. It also follows the existing
platform profile's fallback direction when Sandbox feasibility is not
established. This is a risk-containment choice, not evidence that the Sandbox
prototype failed and not permission to bypass Core device binding, typed-step,
HDC ownership, privacy, or durable-journal protections.

## Rejected alternatives

### Sandboxed v1 distribution

Rejected for v1 because only an ad-hoc launch and entitlement dump exist. The
required external-HDC, file/key/output, USB/UART/TCP, Gatekeeper, and clean-VM
evidence is blocked. Sandbox may be reconsidered only through the revalidation
path below; it is not classified as technically impossible by this ADR.

### Dual Sandboxed and non-Sandboxed distributions

Rejected because it creates two security/support matrices and violates the
requirement to select exactly one v1 path.

### Mac App Store distribution

Rejected because the required Sandboxed external-tool and hardware boundaries
are unverified, and Store distribution is not an approved M0A scope.

### ZIP as a second package format

Rejected for v1 so that quarantine propagation, notarization, installation,
artifact hashes, and support claims have one package path and one evidence
tuple.

### Ad-hoc, unsigned, or non-notarized distribution

Rejected. The M0A ad-hoc artifact is a local prototype only and cannot replace
Developer ID, Hardened Runtime, notarization, Gatekeeper, or clean-host
evidence.

### Bundling, re-signing, or modifying external HDC

Rejected as out of scope and incompatible with the external-first trust model.
ArkDeck must not clear quarantine, rewrite xattrs, re-sign tools, or ask users
to disable system security.

## Release blockers and residual risks

The chosen distribution remains blocked by all of the following:

1. No Developer ID Application identity, non-Sandbox signed app, notarized
   DMG, stapled ticket, or clean-VM Gatekeeper result exists.
2. External HDC trust/quarantine matrices have not run; the exact server,
   daemon, key, image, and output-path behavior is unknown for release.
3. The app does not yet expose the supervised read-only integration required
   for real USB/UART/TCP and file-access evidence.
4. `MAC-M0A-HDC-001`, the full `MAC-M0A-HDC-002`,
   `MAC-M0A-TRUST-001…004`, `MAC-M0A-SANDBOX-001`, and independent review of
   `MAC-M0A-DIST-001` are not passed.
5. The current platform conformance state stays `notStarted`; this ADR creates
   no macOS support or release claim.

## Mandatory release evidence

Before v1 distribution, a separate approved task must record at minimum:

- source commit, app executable hash, complete app-bundle hash manifest, DMG
  hash, macOS build, architecture, Xcode/SDK/Swift versions, signing identity,
  Team ID, timestamp, and notarization/ticket results;
- `codesign --verify --deep --strict` and an actual entitlement dump exactly
  matching the empty set above, plus proof that Hardened Runtime is enabled and
  that no prohibited runtime exception is present;
- restored clean-VM download/install/first-launch/Gatekeeper evidence for the
  exact DMG, with no ArkDeck quarantine/xattr mutation;
- supervised external-HDC path/hash/version/signature/quarantine,
  server-ownership/generation, semantic-failure, key/image/output, and
  USB/UART/TCP results;
- zero automatic lifecycle mutation for external/unknown servers and zero
  destructive dispatch during read-only verification; and
- independent maintainer review against `MAC-M0A-DIST-001`.

## Revalidation triggers

The distribution decision and affected evidence must be revalidated when any
of these changes:

- app or DMG bytes, packaging format, signing identity/Team ID, notarization
  flow, Hardened Runtime flags, or entitlement set;
- target macOS family/build, architecture, deployment target, Xcode, SDK, or
  Swift toolchain;
- external HDC path, hash, signature, quarantine state, version family,
  endpoint/server behavior, bundled-tool policy, helper/XPC architecture, or
  update mechanism;
- USB/UART/TCP implementation, PersistentFileAccess behavior, selected
  image/key/output handling, or security-scoped bookmark strategy;
- Core baseline, macOS platform profile/conformance cases, OpenHarmony
  integration profile, or any applicable Requirement/AC; or
- new evidence shows a Sandboxed build satisfies the complete release matrix
  and a maintainer proposes changing the one selected distribution path.

None of these triggers authorizes an automatic distribution switch. A change
to the selected path requires a reviewed ADR/platform change and fresh
evidence for the new exact tuple.
