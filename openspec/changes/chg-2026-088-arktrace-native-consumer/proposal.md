---
id: CHG-2026-088-arktrace-native-consumer
revision: 1
status: proposed
class: integration
core_change_level: none
owner: fuhanfeng
core_baseline: CORE-3.0.0
platforms: [macos]
---

# ArkTrace native SDK consumer

ArkTrace's Rust engine now provides ABI 2 and index schema 4. ArkDeck still
links revision `9172c9525f954ec397e0555d7d03cd4367f3efcf`, constructs the Swift
document engine and loads a schema-3 CLI profile. A source pin alone cannot
complete this cutover.

This increment pins the published ArkTrace source from PR #68 to
`1d0e02fbe571fe5af6a99b6fe2b3c764fc488400` and exposes an explicitly staged
native SDK adapter. It constructs ArkDeck's own product profile, fixed bundled
tools and publisher identifiers, then returns ArkTrace's shared runtime owner.
Document controllers and maintenance use that same owner. Native writers use
`ArkDeck/Trace/native-v1/{traces,staging}`; the existing Swift/daemon namespace
is preserved. There is no request-selectable tool or cache policy.

The App composition now owns asynchronous startup, a shared controller
and a Quit drain barrier. The build runner resolves the exact source, stages the
normal SDK and copies verified fixed helper/parser manifests into the App.
Missing native SDK startup fails closed; no actual App acceptance is claimed
by the successful unsigned build-for-testing. The analyzer's schema-3
profile remains unchanged until a reviewed schema-4 distribution, exact
provenance vectors and daemon maintenance compatibility are ready in the same
cutover. Existing operations and device authorization remain unchanged.

Maintenance review and protected-main merge are required for publication.
This proposed change does not approve a distribution, register Windows support
or establish real Artifact/GUI acceptance. Windows and Linux consumers retain
their existing behavior; macOS needs fresh adapter/App and CLI validation.

Rollback keeps the prior source/SDK pair and existing namespace. A native
candidate must drain its owner before replacement; mixed source/header/library
generations and shared old/new writer namespaces are rejected.
