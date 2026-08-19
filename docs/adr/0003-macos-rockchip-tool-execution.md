# ADR-0003 — macOS bundled Rockchip component

> **Superseded product-execution boundary (NRU-004, 2026-08-18):** the
> bundled `rkdeveloptool` described below is retained only as an
> operator-invoked Maskrom rescue utility. Loader observation, partition
> reads/writes/readback/reset and `flash.dayu200` now run through native
> RockUSB in identity-bound `arkforged`; ArkDeck Runtime has no executable,
> argv, trust, bookmark or fallback route to this child. The remainder of this
> ADR is preserved as distribution and decision history, not current Runtime
> implementation guidance.

- Status: proposed; effective only when the maintainer reviews and merges this
  decision/evidence PR
- Date: 2026-07-25
- Decision carrier: `DEC-011`
- Decision owner: maintainer (`@lvye`)
- Core baseline: `CORE-2.1.0`
- Outcome: `selected:bundledRockchipComponent`
- Related: ADR-0002, DEC-002, DEC-004, DEC-007, CHG-2026-026,
  CHG-2026-035

## Decision

The macOS Rockchip execution end state is:

> `selected:bundledRockchipComponent`

ArkDeck SHALL build a source-pinned `rkdeveloptool` component, place that
component inside the signed ArkDeck App bundle, and launch only that embedded
component through the existing typed Rockchip workflow. The component is an
App-owned nested code item, not a user-selected executable, downloaded tool,
login item, LaunchAgent, LaunchDaemon, privileged helper, or generic command
broker.

This decision keeps the ADR-0002 distribution shape: Sandboxed, exact current
six App entitlements, Developer ID, Hardened Runtime, and one notarized DMG.
The component's own candidate entitlement shape is exactly App Sandbox plus
Sandbox inheritance; adopting it requires the follow-on change and evidence
gates below. This decision does not add an entitlement or sign/build/package
anything.

The decision is Rockchip-specific. DEC-007 remains deferred and HDC remains
external-first and unbundled.

## Why this end state

Apple explicitly documents an embedded command-line tool as a supported shape
for a sandboxed app, including externally built tools, Code Sign On Copy,
Hardened Runtime, architecture handling, Sandbox inheritance, and independent
Developer ID distribution. It also documents that user-selected file access
does not authorize a sandboxed app to run programs outside its bundle,
container, or App Group containers. The direct bundled shape therefore removes
the unresolved external-executable location boundary without reopening the v1
distribution decision or introducing a persistent broker.

The upstream Rockchip source is pinned, but bundling is not ready today.
Upstream labels the repository GPL-2.0; the pinned macOS build file hard-codes
libusb 1.0.22 and libiconv paths; no reviewed reproducible artifact, complete
dependency closure, SBOM, source-offer mechanism, or release signing receipt
exists. Those are mandatory pre-implementation gates, not assumptions.

The complete comparison is
`openspec/changes/archive/2026-07-25-chg-2026-035-macos-rockchip-tool-architecture/evidence/runs/TASK-RKTA-001/candidate-matrix.md`.

## Production topology and authority

The follow-on implementation change SHALL preserve one production route:

```text
ArkDeckApp composition root
  -> RockchipFlashApplicationFacade / RockchipFlashExecutionHost
  -> typed RockchipFlashPlan + confirmed CurrentDeviceBinding revision
  -> RockchipFlashAuthorizationGate mints the single execution authority
  -> product-owned bundled-component descriptor
     (bundle-relative URL + source/artifact/dependency identity)
  -> FoundationRockchipExecutionProcessPort
     (absolute bundle URL + fixed RockchipClosedCommand argv + empty environment)
  -> FoundationProcessExecutor identity-bound prepared launch
  -> RockUSB process/device effect
  -> durable step intent, semantic outcome, postflight, or waitingForRecovery
```

The App composition root owns construction. Runtime callers SHALL NOT provide
an executable URL, hash, argv, environment, component receipt, authority bytes,
or alternate process port. The bundled descriptor SHALL be derived from the
reviewed App bundle and its versioned registry. The descriptor and prepared
file identity SHALL match immediately before launch; drift blocks dispatch.

The authority issuer remains separate from the process component. The
component SHALL NOT assert caller identity, mint execution authority, or prove
its own result. The typed workflow supplies binding/plan/confirmation facts;
the process layer supplies descriptor-bound launch facts; the Provider parser
and postflight supply semantic outcome facts. An intent without a durable,
semantically confirmed outcome remains `outcomeUnknown` and enters
`waitingForRecovery`.

Plan-only and simulated routes receive no real process executor or real
binding. A fixture-positive result cannot select the production component.
Plan-only retains every typed step as `notExecuted(planned)` and cannot become
ArkDeck execution success.

## File, tool, and device boundaries

- The executable is bundle-relative nested code. There is no PATH search,
  caller path, external bookmark, copy-to-container, dynamic download,
  quarantine removal, or unknown re-signing fallback.
- Image/key/output access remains separately capability-bound. Parent access
  SHALL NOT be inferred to reach the child. The follow-on change must prove the
  exact archive members, output root, and any key material needed by each
  closed command in the signed Sandbox product shape.
- RockUSB access remains behind the current `device.usb` App capability and the
  typed DeviceAccessAdvisor/discovery gates. Sandbox inheritance does not count
  as real USB evidence.
- Only the closed `RockchipClosedCommand` lowering may produce argv. Shell,
  caller environment, PATH lookup, generic command forwarding, sudo, pkexec,
  driver/helper installation, system-rule changes, and group/ACL changes remain
  forbidden.
- The caller's working directory is not part of the tool's input either. The
  upstream tool resolves `config.ini` and `log/` next to its own executable
  through `/proc/<pid>/exe`, which does not exist on macOS, so both degrade to
  cwd-relative. Every lane that spawns it — engine, admission, preflight and
  the read-only mode probe — SHALL bind the child to a prepared product-owned
  `RockchipToolRuntime` directory, so the tool reads a reviewed empty
  configuration and writes its log into product state rather than into
  whichever directory the daemon or CLI was started from. A directory that
  cannot be prepared refuses dispatch; it never falls back to the cwd.
- The pinned discovery registry continues to describe the current
  user-selected E0 path until a separate approved change introduces a bundled
  component registry and explicitly migrates its consumers. This ADR does not
  rewrite existing evidence.

## Mandatory follow-on gates

No product implementation may begin until a separate change is proposed,
approved, and independently readied. Its readiness SHALL close all of the
following gates.

1. **Source and artifact closure**
   - pin upstream commit
     `304f073752fd25c854e1bcf05d8e7f925b1f4e14`, or return to a D1 decision
     revision before changing it;
   - define a hermetic build recipe, builder/toolchain identity, macOS minimum
     target, architecture set, deterministic inputs, produced artifact hash,
     and a clean rebuild comparison;
   - create a product-owned bundled-component registry without silently
     repurposing the user-selected discovery registry.
2. **License and distribution closure**
   - obtain maintainer/legal acceptance for GPL-2.0 distribution obligations;
   - define notices, corresponding-source delivery or valid source offer,
     modification notices, build scripts, and separation from ArkDeck-owned
     code;
   - prove the release/update/rollback path preserves those obligations.
3. **Dependency and SBOM closure**
   - replace the upstream hard-coded Homebrew paths with exact, reviewed
     dependency inputs;
   - pin source/version/hash/license/build for libusb and every non-system
     dependency, determine whether libiconv is system-provided or bundled, and
     record the result without guessing;
   - generate a reviewable SBOM and vulnerability-response ownership.
4. **Nested-code closure**
   - fix the bundle location, code-signing identifier, Code Sign On Copy,
     Hardened Runtime, minimum OS, architecture, and the exact component
     entitlements;
   - require `com.apple.security.app-sandbox=true` and
     `com.apple.security.inherit=true`, with `get-task-allow` and Hardened
     Runtime exceptions absent;
   - sign nested code inside-out with the ArkDeck Developer ID identity,
     notarize the complete App/DMG, staple the ticket, and verify signatures and
     tickets on the distributed bytes.
5. **Typed composition and file-lease closure**
   - remove caller-selected executable reachability from the App execution
     composition;
   - bind the component descriptor to the App bundle and the existing
     identity-bound prepared-launch seam;
   - prove selected image/archive, optional key, Session output, cancellation,
     timeout, partial output, crash, and reconcile behavior end to end;
   - keep authority minting in the trusted host entry point and outside the
     component.
6. **Staged evidence closure**
   - host-only contract/fake tests must cover tampered/missing component,
     wrong architecture, wrong signature/hash, wrong argv, input-lease denial,
     timeout, nonzero, semantic failure, cancellation, crash window, and
     unknown outcome;
   - a signed Sandbox, non-privileged E0 run must prove embedded `ld`, file
     access, and RockUSB access separately; a positive fixture is insufficient;
   - clean-host and clean-VM tests must use the Developer ID/notarized DMG
     shape and include update/rollback;
   - real destructive acceptance remains a later, separately authorized
     hardware task. This ADR and its implementation change mint no E1/E2
     authority.
7. **CHG-2026-026 handoff**
   - only after the bundled implementation evidence is merged may an approved
     revision decide which CHG-2026-026 blocked dependencies are replaced or
     re-readied;
   - TASK-RKFUI-001G and its blocked receipt remain historical facts and SHALL
     NOT be changed to pass.

Failure of any gate keeps Rockchip execute blocked. There is no fallback to a
different candidate inside the implementation task.

## Failure, cancellation, and recovery

- Missing, tampered, incorrectly signed, wrong-architecture, or registry-drifted
  component: block before process dispatch.
- Input lease or USB access unavailable: distinguish permission/driver/offline
  diagnostics and block before mutation.
- Launch failure, timeout, nonzero status, truncated/partial output, or missing
  semantic marker: do not infer success from exit status.
- App/component crash after durable intent but before durable outcome:
  `outcomeUnknown`; no automatic replay.
- Cancellation during a critical write: record the request and wait for the
  Provider safe boundary; do not force-kill the child.
- Postflight identity/version mismatch: not `succeeded`; retain recovery
  guidance and certainty.
- Update or rollback that changes component/source/dependency identity:
  invalidate prior release and hardware evidence until revalidated.

## Rejected alternatives

- `selectedExternal`: rejected. Current Apple documentation separates
  user-selected file authority from executable-location authority and states
  that the user-selected file entitlements do not permit running a program
  outside the App bundle/container/App Group. The 001G failure is not reused as
  proof of this platform rule and is not retried.
- `brokerOrHelper/sandboxedXPC`: rejected as a standalone end state. An XPC
  channel does not supply an executable location or tool supply chain; adding
  it to a bundled tool would be an unreviewed combination and a larger
  authority surface.
- `brokerOrHelper/embeddedInheritedHelper`: rejected when it means a separate
  intermediary. If the embedded executable is `rkdeveloptool` itself, it is
  the selected bundled-component candidate; an extra broker adds IPC and
  confused-deputy surface without closing another requirement.
- `brokerOrHelper/loginItemOrLaunchAgent`: rejected. Persistent/relaunch
  lifecycle and registration are not required for user-triggered flashing and
  add an orphan/update/IPC surface.
- `brokerOrHelper/privilegedLaunchDaemon`: rejected. No reviewed fact shows
  RockUSB needs root; administrator approval and a privileged persistent
  service violate the least-privilege choice and the current single-DMG
  lifecycle.
- `planOnlyHandoff`: rejected as the Rockchip execute end state. It is a valid
  execution mode but cannot satisfy the existing execute capability and cannot
  turn externally performed work into ArkDeck `succeeded`.
- `distributionRevisit`: rejected for now. A non-Sandbox shape could be
  evaluated only by reopening DEC-004/ADR-0002 and repeating the distribution,
  file, process, device, clean-host, update, and threat-surface evidence. The
  selected bundled path has a documented route without that reopen.

Rejected workarounds include symlink/alias fallback, copying a selected tool
into the container, dynamic download, quarantine/xattr removal, re-signing an
unknown binary, PATH lookup, shell execution, and retrying 001G.

## Residual risks

- GPL-2.0 and dependency obligations have not been accepted for an ArkDeck
  release; a legal/distribution gate can still stop the candidate.
- Reproducibility of the pinned source and the identity of the already observed
  external binary are not established.
- Sandbox inheritance is documented, but the exact bundled Rockchip
  component's image/output/USB behavior is not yet evidence.
- libusb/libiconv build, architecture, notarization, and update closure may
  expose an unsupported dependency or packaging constraint.
- A bundled native USB component increases the App bundle's attack and update
  surface; its CVE/rollback owner is not yet assigned.
- Windows/Linux packaging remains undecided and must not copy the macOS
  entitlement or bundle model.

## Revalidation triggers

Reopen this decision before implementation continues if any of these change:

- upstream commit, license, dependency graph, build recipe, component
  architecture, or produced artifact identity;
- Apple Sandbox inheritance, embedded-tool, Developer ID, notarization, launch
  constraint, or nested-code requirements;
- ADR-0002/DEC-004 distribution shape or the App's exact six entitlements;
- a requirement for XPC, login item, LaunchAgent, LaunchDaemon, privilege,
  installer, generic command broker, or dynamic download;
- Core typed-step/effect/authority/recovery semantics or the Rockchip Provider
  command surface;
- clean-host, signed E0, file-lease, or USB evidence that blocks the direct
  bundled route.

## Rollback

Before implementation, rollback is one revert of ADR-0003, DEC-011, the macOS
profile note, and CHG-2026-035 decision evidence. It does not rewrite 001G or
CHG-2026-026.

After implementation, rollback is an App release that removes the component
and disables Rockchip execute while retaining plan-only and historical
evidence. It SHALL NOT silently fall back to an external executable, broker, or
different distribution shape. Any alternative requires a fresh D1 decision and
approved change.

## Consequences

- Positive: the executable location, signing owner, update owner, and
  production composition root become App-controlled and reviewable.
- Positive: v1 stays Sandboxed and HDC stays external-first.
- Cost: ArkDeck assumes a source-build, license, SBOM, nested-signing,
  notarization, vulnerability, and rollback obligation for Rockchip code and
  dependencies.
- Current behavior: unchanged. No component exists, Rockchip App execute
  remains blocked, and no product/process/USB/device effect is authorized by
  this ADR.
