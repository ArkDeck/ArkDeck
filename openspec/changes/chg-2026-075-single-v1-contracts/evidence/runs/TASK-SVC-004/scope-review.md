# TASK-SVC-004 scope review

Two single-v1 cleanups this Task's evidence identified are **not** in this
delivery. Both are recorded here with the reason and, where the diff is inside
the allowlist, the exact change that was considered.

## 1. `SessionSettings/**` is now production-dead but is retained

`Packages/ArkDeckKit/Sources/ArkDeckWorkflows/SessionSettings/**`
(`SessionSettings.swift`, `SessionStorageApplicationRuntime.swift`, 1,002 lines)
is inside this Task's Allowed paths, and after this delivery it has no
production constructor: `SessionSettingsStore()` was built in exactly one
production place, the deleted legacy-migration store in
`SettingsApplicationFacade`, and `SessionStorageApplicationRuntime.production`
has no callers. Deleting the directory would make "History/SessionSettings read
and write only Runtime-owned current resources" mechanically true rather than
conventional.

It is retained because the mechanism it publishes is the subject of another
change that is still open. `openspec/changes/chg-2026-031-macos-session-settings`
is not archived and all three of its Tasks are `Status:blocked`; its
`design.md` describes `SessionRootAccessLease` and the App-local Session
settings store as the mechanism those blocked Tasks implement. That change
directory is outside this Task's Allowed paths, so this Task cannot retire the
design and the code together, and retiring the code alone would leave a live
change describing a mechanism that no longer exists.

Requested decision: whether `SessionSettings/**` should be deleted under
CHG-2026-031 (which owns the design) or added to a later SVC Task's Allowed
paths together with that change directory.

## 2. `SettingsStoragePresentation`'s two optionals have unreachable arms

`runtimeArtifacts` and `sessionRoot` are `Optional`, and
`SettingsRootView.runtimeArtifactUsage` / `sessionRootUsage` each render an
"unavailable" arm for `nil`. Both arms are unreachable on the delivered path:
the exact-shape reader requires `artifactDomain` and the full `usage` object,
so a reply that lacks either is refused as `runtimeStorageResponseInvalid` and
a Runtime that did not answer produces no presentation at all. (This was
already true before this Task; the deleted in-process seam was the only
producer of a `nil` in either field.)

Making them non-optional is a two-line change in
`SettingsApplicationFacade.swift` plus the two `if let` blocks in
`SettingsRootView.swift` — all inside the Allowed paths. It was not done
because it orphans two localized strings:

```
settings.storage.runtimeUnavailable
settings.storage.measurementUnavailable
```

which live in `ArkDeckApp/Resources/SettingsLocalizable.xcstrings`, outside this
Task's Allowed paths. `SettingsStorageDomainContractTests.testProductionUsageIsReadFromRuntimeAndRenderedPerDomain:318`
asserts the view still names `settings.storage.runtimeUnavailable`, and
`ArkDeckAppUITests/SettingsStorageStateTests.swift:69` constructs a presentation
with both fields `nil`; both are inside the Allowed paths and could be updated,
but the catalog entries they exist for could not. Removing the arms without the
catalog entry would leave exactly the drift the design-side audit exists to
catch.

The change is not preferences or configuration compatibility, so it is raised
rather than taken here.
