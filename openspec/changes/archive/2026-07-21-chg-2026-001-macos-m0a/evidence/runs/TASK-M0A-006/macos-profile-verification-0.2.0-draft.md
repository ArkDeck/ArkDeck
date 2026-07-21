# Non-authorizing draft — PLATFORM-MACOS 0.2.0 profile and verification

> Evidence artifact for TASK-M0A-006 only.
>
> This file does not modify `openspec/platforms/macos/**`, the platform lock,
> a conformance status, Requirement, or AC. Adoption requires a separate
> maintainer-approved platform change and fresh validation of its exact diff.

## Draft scope

This draft carries ADR-0001's distribution choice and the honest M0A blockers
into a possible next macOS profile/verification revision. It does not turn a
blocked M0A row into a pass and does not change Core behavior.

## Proposed profile changes

### Header and distribution status

Propose `PLATFORM-MACOS@0.2.0`, still against `CORE-1.0.0`, with profile status
`draft` until the selected release tuple has conformance evidence. The platform
lock must remain `conformance_status: notStarted` until a separately approved
verification run passes every applicable release gate.

### Single v1 distribution path

Replace the candidate distribution wording with:

> ArkDeck v1 for the declared `macOS 14 / arm64` support cell uses one
> distribution path: a non-Sandboxed, Developer ID Application-signed app with
> Hardened Runtime in a notarized DMG. HDC remains external-first and is not
> bundled. No ZIP, Store, ad-hoc, unsigned, dual-distribution, or automatic
> update path is part of v1.

The exact app entitlement dictionary is empty. Explicitly forbid App Sandbox,
USB/serial/network/file/bookmark entitlements, `get-task-allow`, and all
Hardened Runtime exceptions named in profile 0.1.0 unless a later approved
change updates ADR-0001 and supplies full revalidation evidence.

Non-Sandbox distribution does not weaken Core. Device mutation still requires
durable binding, HDC lifecycle still respects external/unknown ownership,
external operations remain typed argv-based steps with intent/outcome audit,
and export/privacy rules remain unchanged.

### External tool and file-access boundary

Retain standard user file selection for image, key, and output paths, but do
not claim that selection authorizes arbitrary execution. The selected
non-Sandbox build must still validate the exact external child-process behavior
for each path and must keep inputs read-only except for an explicitly selected
output root.

The profile should distinguish:

- app distribution trust (Developer ID, Hardened Runtime, notarization,
  Gatekeeper);
- external HDC trust (path, hash, signature, quarantine, version);
- HDC server ownership/generation; and
- device authorization versus transport/channel protection.

Success in one category must not be inferred from another.

### Sandbox research status

Record the M0A Sandbox build as a rejected-for-v1 research prototype, not as a
failed platform capability. Reconsideration requires every Sandbox-specific
file/key/output and USB/UART/TCP cell to run through a supervised app
integration on the exact signed artifact, plus a new ADR/platform change.

### Revalidation section

Add ADR-0001's triggers: app/DMG bytes, package format, signing/Team identity,
notarization, runtime flags, entitlements, OS/architecture/deployment target,
toolchain, HDC identity/behavior, helper/update architecture, transport/file
access, Core baseline, platform cases, and integration profile.

## Proposed verification changes

### Separate M0A research closure from release conformance

The next verification profile should preserve both facts:

1. M0A produced useful local prototypes and explicit blockers; accepting a
   blocker closes research accounting but is not a pass.
2. v1 release conformance cannot pass until the selected non-Sandbox
   Developer ID/notarized DMG and all required real-platform/tool/hardware
   matrices have evidence.

Proposed M0A rollup at source revision
`0abbbaa1a6af080a94b7222ba67f4e7a3f325ab0`:

| Status | Evidence IDs |
| --- | --- |
| passed | `MAC-M0A-SHELL-001`, `MAC-M0A-PROC-001`, `MAC-M0A-RUNTIME-001`, `MAC-M0A-JOURNAL-001`, `MAC-M0A-POWER-001` |
| failed | none |
| blocked | `MAC-M0A-HDC-001`, `MAC-M0A-HDC-002`, `MAC-M0A-TRUST-001…004`, `MAC-M0A-SANDBOX-001`, `MAC-M0A-DIST-001` |

No blocked row should become `notApplicable`. The exact reasoning and evidence
hashes live beside this draft in the TASK-M0A-006 rollup and index.

### Proposed v1 distribution verification case

Keep the ID `MAC-M0A-DIST-001` and require one independently reviewed record
that proves all of the following for the exact release tuple:

- exactly one non-Sandbox Developer ID + Hardened Runtime + notarized DMG path;
- source commit, exact OS/build/architecture/toolchain, app executable and
  bundle manifest hashes, DMG hash, Developer ID identity/Team ID/timestamp,
  notarization result, and stapled-ticket validation;
- `codesign --verify --deep --strict`, Hardened Runtime flags, and an actual
  empty entitlement dictionary with every forbidden exception absent;
- restored clean-VM DMG download/install/first-launch/Gatekeeper assessment;
- zero ArkDeck quarantine/xattr mutation and non-bypass guidance for blocked
  external tools;
- exact external HDC path/hash/version/signature/quarantine, server ownership
  and generation, key/image/output, and USB/UART/TCP matrix results; and
  zero automatic external/unknown lifecycle mutation and zero destructive
  dispatch during read-only runs; and
- residual risks and every ADR-0001 revalidation trigger.

The case fails closed when a hash, identity, ownership, generation, outcome, or
required cell is unknown. A blocked prerequisite yields `blocked`, not pass.

### Proposed support-cell identifier

For separate approval, revise the support cell from the ambiguous
`macos-14-arm64-developer-id` to a distribution-specific identifier such as:

```yaml
- id: macos-14-arm64-developer-id-nonsandbox-notarized-dmg
  os_version_family: "14"
  architecture: arm64
  package_format: notarized-dmg-developer-id-nonsandbox
```

This is a draft schema value only. The platform lock and conformance cases must
not change until the owning platform change validates allowed values and
compatibility.

### Evidence migration and expiry

Existing passed M0A prototype rows may be cited only for their recorded scope.
They do not automatically apply to different source bytes, a Developer ID
artifact, a DMG, or a release support tuple. The next verification revision
should record an evidence validity period and must return the platform to
`needsReverification` after release bytes or any declared trigger changes.

## Separate approval checklist

A future platform-change proposal should:

1. name the exact profile, verification, case-manifest, and platform-lock
   changes;
2. show that no Core Requirement/AC is removed, weakened, renumbered, or made
   not applicable;
3. provide migration wording from M0A blockers to the owning M1/release tasks;
4. validate case IDs and package-format values with `scripts/check-sdd.sh`;
5. obtain maintainer review before any draft text becomes authoritative.
