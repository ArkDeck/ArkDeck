# TASK-AIN-010P readiness r3 — the r2 production-selection blocker was not real (2026-08-07)

r2 named the stale HDC path preference as the gate's cause. That is wrong, and an already-merged
contract test says so. This corrects it, and states what the gate actually is.

Host-only. HDC command dispatch: 0. Device command dispatch: 0. Nothing started, nothing written
outside this document and the task's own status line.

## What r2 claimed, and why it is wrong

r2: *"A UI test wrote into the product's real persisted preferences domain and left a dangling
pointer there; every run since has inherited it … production discovery cannot select the real
candidate."*

Three measurements, each contradicting it:

1. **The persisted path string is not authority.** `discoveryRequest` builds
   `userConfiguredPaths` from resolved security-scoped **bookmarks**, not from the persisted path
   array. The source says so where it is built — persisted path strings are "display/migration
   metadata only; after relaunch they cannot substitute for a sandbox capability".
2. **This is already pinned by a merged test.**
   `HDCSupervisorContractTests.swift` seeds only the path preference and asserts
   `userConfiguredPaths.isEmpty`, with the comment *"a persisted pathname alone must not be
   treated as sandbox authority after relaunch"*. r2 asserted the opposite of a test that was
   green the whole time.
3. **A dead bookmark is dropped, not honoured.** `restoreUserConfiguredBookmarks` skips any
   bookmark that fails to resolve and writes the pruned list back. Residue from a deleted fixture
   cannot poison discovery; it is removed on the next read.

So the dangling value is inert. It was a red herring, and r1's "old fake fixture" phrasing
invited reading it as a cause.

## What the gate actually is

`HDCExternalFirstDiscovery` is **explicit-only**: it considers `userConfiguredPaths`,
`devecoSDKPaths` and `openHarmonySDKPaths`, in that order, and nothing else. There is no PATH
search and no system-location fallback — by design.

On this host none of the three is populated for a non-App process: the bookmark is gone (dropped,
correctly), and neither SDK-path preference is set. Discovery therefore has nothing to consider.
That is the whole of the gate. It is a configuration absence, not residue and not a defect.

## And it is clearable without a picker or a code change

The product ships an explicit override for exactly this, alongside the App's file importer:

- launch argument `--arkdeck-hdc-user-configured-path <absolute path>`, and
- environment key `ARKDECK_HDC_USER_CONFIGURED_PATH`

Both feed `explicitOverrides` and are placed **ahead** of any restored bookmark. The
launch-argument leg is pinned by the same contract test (*"an explicit launch override must win
over a bookmark left by an earlier App run"*); the environment leg goes through the identical
concatenation and is pinned by this change window's added row.

A bookmark is not required for a process that is not sandboxed:
`HDCSecurityScopedExecutableAccess.init(path:bookmark:)` returns immediately when the bookmark is
`nil`, and discovery then only requires the path to be absolute, executable and hashable. The
registrar this task builds is a package executable, not the sandboxed App.

The candidate that override selects is the DevEco toolchain HDC whose bytes still hash to
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83` — the registered `3.2.0f`
tuple, verified again in r2.

## Gate status after this correction

| Gate | r2 said | r3 measures |
| --- | --- | --- |
| Approval / dependency / collision | satisfied | satisfied |
| Exact tool bytes | satisfied | satisfied |
| Production selection | **blocked** | **not blocked** — an absent explicit configuration with a supported, tested override |
| Server / tool environment | satisfied | satisfied |
| Durable target / build | partly | partly — target yes, build confirmation still needs a window |

One gate remains, and it is the one that was always going to need a readiness window: a fresh
`3.2.0f` machine confirmation of device presence, serial digest, binding revision and build,
which requires a registered `list targets -v` that a blocked task must not run.

## The process failure worth recording

r2 named a blocker from a preference value without reading how that value is consumed, and the
answer was one file away and already covered by a green test. This repository has a standing rule
for exactly this — verify every gate before naming a blocker — and r2 broke it while re-measuring
r1's gates for precisely that reason. The correction is cheap here because nothing was built on
it; the same mistake on the readback premise cost a device window.
