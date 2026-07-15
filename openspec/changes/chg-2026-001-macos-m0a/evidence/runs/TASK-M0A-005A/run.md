# TASK-M0A-005A run record — 2026-07-15

- Evidence class: `platform` + `plan`; no hardware, no HDC invocation
- Core baseline: `CORE-1.0.0`
- Integration profile: `OPENHARMONY-TOOLS@0.1.0`
- Prototype: Release Sandboxed app, built locally with an ad-hoc signature

## Ready check

- `CHG-2026-001-macos-m0a` is approved on protected `main`.
- Dependencies `TASK-M0A-001`, `TASK-M0A-002`, and `TASK-M0A-003` are `done`.
- Xcode `26.6` (build `17F113`) and Swift `6.3.3` are locally available.
- `security find-identity -v -p codesigning` still reports `0 valid identities
  found`; this is acceptable for 005A's explicitly allowed ad-hoc prototype,
  but not for the blocked 005B Developer ID prototype.

## Deliverables

- Added `ArkDeckApp/ArkDeckApp.entitlements`, selected by both Xcode target
  configurations. The Sandboxed prototype requests only App Sandbox, USB,
  serial, app-scoped bookmarks, user-selected read-write file access, and
  network-client access.
- Release disables `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`, so Xcode does not add
  `com.apple.security.get-task-allow` to the distribution-like prototype.
- Frozen the human-only, read-only USB/UART/TCP and user-selected file-access
  protocol in `read-only-hardware-test-plan.md` for TASK-M0A-007.

## Commands and results

| Command | Result |
| --- | --- |
| `plutil -lint ArkDeckApp/ArkDeckApp.entitlements` | Passed. |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Debug -derivedDataPath /private/tmp/arkdeck-m0a-005a-derived build` | Passed with the app-scoped bookmark entitlement. Debug evidence only: Xcode injected `com.apple.security.get-task-allow`, so this artifact is not the plan's distribution-like artifact. |
| `xcodebuild -project ArkDeck.xcodeproj -scheme ArkDeck -configuration Release -derivedDataPath /private/tmp/arkdeck-m0a-005a-derived build` | Passed after the Release base-entitlement correction and app-scoped bookmark addition. |
| `codesign --verify --deep --strict <Release ArkDeck.app>` | Passed. |
| `codesign -dvv --entitlements :- <Release ArkDeck.app>` | Captured below. |
| `open -n -g <Release ArkDeck.app>` followed by `ps` | Passed: the locally built app started as PID 453 from the recorded artifact path, then was terminated after observation and confirmed exited. |
| `swift test` in `Packages/ArkDeckKit` | Passed: 36 executed, 1 expected manual-observation skip, 0 failures. |
| `xcrun stapler validate <Debug ArkDeck.app>` | Not validated: the local ad-hoc artifact has no notarization ticket. This is not a Gatekeeper or clean-VM result. |

## Release signing and entitlement evidence

The ephemeral local artifact was
`/private/tmp/arkdeck-m0a-005a-derived/Build/Products/Release/ArkDeck.app`.
Its executable SHA-256 was
`f9478493480c715b7610fa4aafd58e280798e6ebdc82d4d10491ddcdafb8242a`.
It is a universal `x86_64` + `arm64` Mach-O.

`codesign -dvv` reported `Signature=adhoc`, `TeamIdentifier=not set`, and no
timestamp. This is a local signing-level prototype only: it is not Developer
ID signed, Hardened Runtime validated, notarized, assessed by Gatekeeper, or
distribution evidence.

The actual Release entitlement dump was:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.device.serial</key><true/>
  <key>com.apple.security.device.usb</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
```

`com.apple.security.get-task-allow` is absent from this Release dump. The
first Release build exposed that Xcode had injected it despite its absence from
the source file; adding `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` and rebuilding
produced the dump above. No additional entitlement was added to resolve it.

## Launch and enforcement observation

No ArkDeck process was present before the observation. `open -n -g` launched
the exact Release artifact above; the process table then reported PID 453 with
the executable path
`/private/tmp/arkdeck-m0a-005a-derived/Build/Products/Release/ArkDeck.app/Contents/MacOS/ArkDeck`.
That temporary instance was terminated after the observation, and a subsequent
PID lookup returned no process.

The enforced configuration observable in this environment is the signed
entitlement dump above: it includes both
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.files.bookmarks.app-scope`. Starting the app only proves
that this local signed artifact launched; it is not an allowed/blocked
file-access, USB/UART/TCP, Gatekeeper, or hardware result. Those decisions
remain in the human TASK-M0A-007 matrix.

## AC conclusion and residual risk

- The 005A Sandboxed-prototype portion is complete: a locally signed,
  entitlement-bearing app was built and its actual entitlement dump is
  preserved above. This does **not** satisfy `MAC-M0A-SANDBOX-001`, which stays
  pending until a human executes TASK-M0A-007 on real hardware.
- The frozen TASK-M0A-007 plan requires a supervised read-only integration.
  The current App shell has no such device/tool surface; a direct Terminal
  `hdc` invocation is explicitly not a substitute. Until an eligible probe is
  available, affected real-hardware cells must be reported `blocked`.
- TASK-M0A-005B and `MAC-M0A-TRUST-001…004` remain blocked: no Developer ID
  identity, Hardened Runtime prototype, clean VM, Gatekeeper, quarantine, or
  notarization evidence was created here.
- No real device, USB/UART/TCP endpoint, HDC, server lifecycle operation,
  destructive step, browser download, or quarantine/xattr mutation was used.

The task is recorded as `done` for its scoped deliverables only. Change-level
verification and all hardware/distribution conclusions remain for maintainer
review and their required evidence.
