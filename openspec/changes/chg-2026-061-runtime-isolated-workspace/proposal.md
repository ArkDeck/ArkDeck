---
id: CHG-2026-061-runtime-isolated-workspace
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# Runtime-owned isolated workspace preparation

> **Vertical review boundary:** this is a new Catalog operation. The four-file
> change package, production implementation, contract tests and evidence are
> delivered in the same GJ-5 PR. This proposal is not a readiness-only change.

## Product problem

The imported WaterFlow patch is immutable and path-free, but the only published
mutation route targets a shared ProjectProfile and therefore correctly requires a
maintainer-issued standing capability. An unattended Runtime must not mint that
authority for a developer tree, and the user must not be asked to install a grant
for a scratch copy that does not exist yet.

Publish `workspace.prepare-isolated-copy@1`: a host-only operation that copies an
exact primary ProjectProfile into the daemon's existing private evolution workspace
store. It returns only an opaque `evolution-*` project reference and the copied
revision. Existing patch/build/test operations then run against that derived
profile; their standing-capability policy remains unchanged for shared trees, while
the Runtime may issue a bounded capability for a profile measured as an isolated
task copy. Promotion still happens only through a reviewed PR.

## Requirements

### RIW-REQ-001 — Exact, path-free preparation

The request SHALL name only a registered primary `projectRef`, an exact full-profile
source revision and a non-empty set of scopes that narrow that profile. Runtime SHALL
derive every host path, copy into its owner-private state root, remeasure the narrowed
copy and publish no path.

### RIW-REQ-002 — Durable identity and restart

The persisted typed action SHALL bind the full source revision, narrowed copied
revision, scope digest, creation time, owner Job and derived workspace identity.
Retry and daemon restart SHALL reopen or adopt the same manifest and bytes; mismatch
SHALL fail closed rather than rebuild under an existing reference.

### RIW-REQ-003 — Shared authority remains closed

Preparation SHALL be host-only and require no mutation capability. Existing
workspace mutation descriptors SHALL remain standing-capability operations. Runtime
automatic issuance SHALL be reachable only when provider facts prove the selected
ProjectProfile is a Runtime/Harness isolated copy.

### RIW-REQ-004 — Immutable HAP handoff

When a ProjectProfile declares a reviewed build product, the existing build operation
SHALL measure the bounded ZIP/HAP from the isolated tree and publish it as immutable
`unsigned.hap`. Signing, export, Artifact import and device deployment remain the
existing typed operations; no shell/HDC/signing shortcut is added.

## Acceptance

- **RIW-AC-1:** Catalog/generator expose one new closed operation and one registered
  step kind; no caller path, argv, executable or command field exists.
- **RIW-AC-2:** full-source drift, out-of-profile scope, copied-revision drift,
  manifest conflict and absent lifecycle manager fail before a usable reference.
- **RIW-AC-3:** the same action is idempotent and a fresh daemon adopts the persisted
  copy with the same project reference and revision.
- **RIW-AC-4:** preparation consumes no mutation capability; isolated build receives
  one Runtime-default capability, while a primary/shared build still requires a
  maintainer capability.
- **RIW-AC-5:** an isolated build publishes exact non-empty ZIP/HAP bytes as
  `unsigned.hap`, and neither source bytes nor a product in the primary tree changes.
- **RIW-AC-6:** cancellation/readback/publication errors are path-free and cannot be
  converted into success by exit status alone.

## Out of scope

- no automatic patch selection, code generation, promotion, merge or push;
- no caller host path, raw shell, raw HDC, device mutation or signing authority;
- no weakening of standing capability requirements on a shared workspace;
- no raw Trace upload, evidence publication or device-capture claim.
