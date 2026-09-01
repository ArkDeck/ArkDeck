# Runtime update CLI

`arkdeck runtime update` exposes the existing macOS consumer update flow through the same local
owner used by the App. It does not add an installer, accept an artifact URL or path, weaken feed or
code-signing verification, or turn the CLI into a second update engine.

## Command surface

```text
arkdeck runtime update check
arkdeck runtime update download
arkdeck runtime update handoff --consent reveal-in-finder
arkdeck runtime update status
arkdeck runtime update cancel
arkdeck runtime update cleanup
```

Every leaf is local (`connectsToRuntime: false`) and supports human output, the legacy `--json`
shape, and `--output json`. It refuses `--socket`, `--endpoint`, artifact paths, URLs, install flags,
and arbitrary consent text.

- `check` sends only the existing `{appVersion, osVersion, arch}` privacy allowlist, verifies the
  signed feed, and persists either `available` or `noUpdate`. It never downloads an artifact.
- `download` is valid only from `available`. It streams into the owner-only cache, enforces the
  signed length and SHA-256, then applies the existing same-Team Developer ID validation. Success
  stops at `awaitingConsent`.
- `handoff` is valid only from `awaitingConsent` and requires the exact consent token
  `reveal-in-finder`. It rechecks bytes, file identity and code signing before revealing the DMG in
  Finder. It never mounts, opens, installs, replaces the App, or writes installed bytes.
- `status` returns `arkdeck.runtime-update-status/1`. The projection contains phase, generation,
  allowed next transitions, signed version/digest/length, and closed failure/no-update codes. Cache
  paths and Team identity are never projected.
- `cancel` records a generation-bound cancellation request without waiting for the foreground
  operation lease. The active check/download owner observes it and settles durably. A cancellation
  that arrives after Finder reveal cannot rewrite the completed handoff as cancelled.
- `cleanup` proves that no process owns the operation lease, settles a crashed transition, removes
  orphan partials and unreferenced verified files, and returns
  `arkdeck.runtime-update-cleanup/1`. Calling it while an artifact awaits consent explicitly
  discards that artifact and returns the lifecycle to `idle`.

## One process-independent owner

The state record uses schema `arkdeck.runtime-update-state/1`, canonical JSON, owner-only
permissions, atomic replace plus directory sync, and generation compare-and-swap. A short state
lock serializes record reads and writes. A separate nonblocking operation lease remains held for
the complete network, verification or Finder handoff interval, so status and cancellation do not
block behind network I/O.

The App and each fresh CLI process reopen the same Application Support record and update cache.
They do not infer liveness from a PID or timeout. If the operation lease is held, another process
may only read status or request cancellation. If the lease is free while the record says an
operation is active, recovery treats the old owner as crashed, performs zero new network or Finder
effects, removes incomplete material, and publishes a closed failure/cancelled state.

The durable record is private implementation state. Public output never contains its artifact
URL. `runtime update` accepts no raw executable, argv, shell, HDC, remote path, or caller-selected
cache location.

## Error contract

The CLI maps local lifecycle failures onto the existing machine error registry:

| Condition | `error.code` |
| --- | --- |
| live owner or generation drift | `resourceConflict` |
| noncanonical/corrupt owner record | `recordUnreadable` |
| owner directory or durable write failure | `ioFailure` |
| missing final handoff consent | `admissionDenied` |
| feed, digest, file identity, or code-signing failure | `artifactIntegrityFailed` |
| explicit cancellation observed by foreground work | `clientInterrupted` |
| bounded network request failure | `operationFailed` |

Error messages do not interpolate URL or filesystem error descriptions because those can include
private request or cache paths. After a failed mutation, `runtime update status` is the durable
recovery/readback path.

## Scope and validation

This surface reuses the approved `CHG-2026-023` minimum self-built flow: signed feed, bounded
download, same-Team validation, and Finder handoff. The archived change still excludes silent
installation, Sparkle/XPC, new entitlements, new dependencies, telemetry, and private-key access.

Contract coverage includes independent owners continuing one lifecycle, cross-process
cancellation, crashed verification recovery, cancellation after an already completed Finder
reveal, explicit cleanup of a consent-pending artifact, canonical/permission checks, path-free
projection, exact consent parsing, and stable CLI error mapping. These are offline contract tests;
they do not claim a production feed publication, Developer ID/notarized DMG release acceptance,
or App replacement.
