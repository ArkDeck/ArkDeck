# CHG-2026-015 design — closed read-only probe registry

> Change:CHG-2026-015-hdc-readonly-probe-registration@r1
> Status:candidate;only maintainer approval makes this design executable

## Decision 1:registry entries are capabilities, not suggestions

The integration artifact is a structured allowlist. Every entry is versioned and contains:

- stable family/entry ID and probe kind (`hdcCommand`, `platformProcessObservation`, or
  `platformFileAccess`);
- exact tool/profile version and executable trust policy;
- exact argument array when the probe is a command; no shell string or caller-provided suffix;
- endpoint/environment and existing-server preconditions;
- declared effect and an exhaustive forbidden-effect set;
- stdout/stderr/exit/raw fixture or platform-receipt family and semantic mapping;
- timeout, cancellation and owned-resource cleanup contract;
- authority limit:what the observation may establish and what it can never establish;
- authoritative source/capture lineage and immutable hashes.

An adapter may consume an entry only as a whole. It cannot borrow argv from one version, output
markers from another, or relax preconditions locally. Missing/unknown fields make the entry
unsupported.

## Decision 2:four distinct observation models

| Family | Permitted observation | Explicit non-authority |
| --- | --- | --- |
| `serverIdentityGeneration` | Existing server process identity/start identity, validated executable receipt and exact endpoint listener binding; optional registered `checkserver` health is correlated but not identity | No caller-supplied generation, PID-shape ownership, endpoint-reuse identity or implicit server start |
| `selectedDeviceAuthorizationBinding` | Exact registered selected-device observation family, matched to the already durable device identity and binding revision | Cannot create/revise a binding, choose a default device, infer channel protection or continue after identity mismatch |
| `keyAccessDiagnostics` | Configured/user-approved locator metadata and bounded public-key access result; public fingerprint only | No default hard-coded path authority, private-key read/hash/copy/delete/chmod/upload or path logging |
| `subserverCapability` | Registered client-local help/capability raw family proven to have zero lifecycle/device-migration effects | No `spawn-sub`, `killall-sub`, migration, server-start or capability inference from version alone |

The registry may explicitly record a family as `unsupported` for a tool version. That is a valid,
safer integration result when no effect-free observation exists.

## Decision 3:command probes require a no-start precondition

HDC client invocations may implicitly start a host server. A candidate command is not read-only
merely because its user intent is diagnostic. For every command entry, controlled evidence must
show:

1. whether a server-absent invocation starts or mutates server state;
2. the exact existing-server precondition required before invocation;
3. server process/start identity, endpoint and generation-equivalent observation before/after;
4. lifecycle, subserver and device-migration counters all remain zero;
5. timeout/cancellation terminates owned resources without killing an external/unknown server.

If (1) is unsafe or unknown, the adapter may run the command only after the independent existing-
server precondition is proven. It must return unavailable instead of invoking the command when
that precondition is absent.

## Decision 4:provenance and fixtures

- HDC raw output families require authoritative documentation or controlled-human capture for the
  exact tool version/command/stream/exit tuple.
- Platform process/file observations use a versioned, redacted receipt schema plus synthetic
  adversarial vectors. Sensitive raw paths/device identifiers remain outside the repository;
  evidence records their immutable source hash and controlled provenance.
- Agent-authored fake output is permitted only as negative/control input and is labelled `fake`.
  It never promotes a production family to supported.
- Fixture/resource registry, profile entry and Integration lock must agree on version, path and
  SHA-256. Partial registration fails the whole task.

## Decision 5:adoption remains separate

TASK-I15-001 only publishes verified integration inputs. It does not modify ArkDeck production
source. M1-006 adoption requires a later approved task revision that pins the new profile version,
maps the registry through its closed adapters, reruns headless contracts, and separately completes
signed Sandbox platform evidence. Registration is necessary but not sufficient for any HDC AC.

## Failure, cancellation and recovery

- unknown output, mismatched executable/endpoint/identity, stale device binding, missing key
  authority, unproven effect, timeout or cancellation => typed unavailable/unknown result;
- no failure path may retry with a broader argv, default device or fallback key path;
- registration artifacts are immutable/versioned. A bad entry is superseded by a new approved
  integration version, never edited in place after dependent evidence exists;
- registration implementation is one revertable PR. Revert leaves consumers on 0.2.0 and M1-006
  blocked.

## Rejected alternatives

- Treating `checkserver` as identity/generation:it reports health/version, not process identity.
- Treating `list targets -v` as inherently read-only:server-start/effect and raw family must first
  be proven for the pinned version.
- Reading a conventional private-key path:violates configuration, privacy and Sandbox boundaries.
- Inferring subserver support from version/API level:capability must be observed by a registered
  zero-mutation family.
- Registering only fake fixtures:proves parser/orchestration, not a production integration family.
