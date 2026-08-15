# Design

## Typed flow

```text
primary ProjectProfile + full source revision + narrowed writable scopes
                              │
                              ▼
             workspace.prepare-isolated-copy@1
                              │
          Runtime-owned host action / private evolution root
                              │
             copy all project bytes, remeasure scopes
                              │
                              ▼
        isolated-workspace.json (no host path) + evolution-* ref
                              │
             daemon restart adopts the same manifest
                              │
                              ▼
 existing apply-patch / build / test on isolated ProjectProfile
                              │
        build landing is measured and published as unsigned.hap
                              │
                              ▼
      existing sign → export → Artifact import → debug.hap route
```

## Two revision meanings

`expectedWorkspaceRevision` is the full primary-profile revision observed before
admission. `isolatedWorkspaceRevision` is independently computed over the requested
narrowed scopes. Both are persisted in `WorkspaceIsolationIntent`; the latter seeds
the deterministic workspace/project IDs and becomes the revision used by subsequent
patch/build/test requests. This prevents a full-profile digest from being confused
with a narrowed write-scope digest.

`createdAtUTC` also lives in the persisted action. A recovery dispatch cannot create
a different manifest merely because wall-clock time advanced between attempts.

## Host execution boundary

`prepareWorkspaceIsolation` lowers to `TypedProcessPlan.Kind.hostWorkspace`, not a
process. `RuntimeOwnedWorkspaceDispatcher` accepts only the matching typed action,
Job correlation, step correlation and action digest. `EvolutionWorkspaceManager`
owns the private root and ProjectProfile registry. A generic descriptor-bound process
dispatcher rejects the host-only kind.

Preparation verifies the full source revision while holding the lifecycle manager's
lock, copies into a temporary child of the private root, atomically publishes the
workspace directory, remeasures both the complete copied profile and the narrowed
revision, writes one manifest and then registers a derived profile. The copy is
bounded to 100,000 entries, 512 MiB per regular file, 4 GiB total regular-file bytes
and 4,096 UTF-8 bytes per relative path. Each regular file is copied from one
`O_NOFOLLOW` descriptor with an exact initial-size read and final identity check;
absolute or source-escaping symlinks, changing files and enumeration failures refuse
the preparation. Readback reopens the manifest and remeasures the copy.
Startup enumerates bounded manifests and re-anchors their leaf names below the
configured root so macOS `/var` ↔ `/private/var` aliases cannot change revision bytes.

## Capability boundary

The new operation is `hostOnly/defaultReadOnly` because it changes only Runtime-owned
state. Existing `workspace.apply-patch`, `workspace.build-openharmony`,
`workspace.run-tests` and `workspace.revert-patch` descriptors remain E1 standing
capability operations with default issuance disabled. Their provider facts carry
`isolatedTaskCopy`; Runtime-default issuance is allowed only when that measured bit is
true. A primary workspace continues to fail without an explicit maintainer grant.

## Build product

A ProjectProfile may map a reviewed build preset to one safe relative product path.
Only a derived isolated profile activates that landing. Before spawn the provider clears
only that isolated destination. After spawn the
dispatcher opens it with `O_NOFOLLOW`, requires a non-empty bounded regular file,
hashes exact bytes and checks the ZIP local-header prefix. `RuntimeArtifactStore`
publishes those measured bytes as file-backed `unsigned.hap` before the step outcome;
the staging product is then removed. Profiles without a declared product retain the
existing required build-log behavior and omit the optional HAP.

## Failure and privacy

All durable summaries contain opaque IDs, revisions, digests and counts only. Manager
errors are collapsed at the dispatcher boundary to a stable path-free refusal.
Cancellation before durable readback remains outcome-unknown. Manifest, source,
scope, revision or build-product disagreement is never inferred from exit zero.
