# Import upload Target integration seam — 2026-09-12

This is an integration proposal, not a configured owner or acceptance result.
The Import upload candidate is based on Artifact export candidate `cfbb2598`,
whose protected-main base is `0dad7599`. The separately validated Target candidate
`2f849a24` has not been treated as published input or modified by this slice.

The daemon currently passes an `operationUnavailable` resolver to
`ImportUploadStore::handle_resource`. It can inspect/resume a pre-existing upload,
append exact bounded chunks and abort it. A new request does not create a record,
identity or staging file without the actual Runtime Target owner. RPC fields
cannot supply `ImportBinding`, `appOwned`, HDC observations or trusted facts.

## Proposed existing-owner API

After the Target candidate is integrated, add this method to that existing owner:

```rust
impl TargetStore {
    pub fn resolve_import_binding(
        &self,
        intent: &arkdeck_contract::ImportIntent,
    ) -> Result<crate::ImportBinding, arkdeck_contract::WireError>;
}
```

Use the existing TargetStore read/locking and strict TargetDocument decoder. Do
not introduce another Target reader, owner, wire endpoint or binding writer. The
method must resolve the exact `target_id` and compare the actual durable binding
revision to `intent.binding_revision` before returning any kind's snapshot.
Missing or mismatched bindings return `resourceConflict`; unreadable durable proof
returns `recordUnreadable`. An unavailable required owner returns
`operationUnavailable`. The Import store normalizes the refusal to `importOwner`.

Preserve `RuntimeImportControlHandler.binding`'s existing kind semantics:

| Kind | Snapshot after actual Target/revision validation |
| --- | --- |
| `workspace-patch` | Exact Target ID; omitted revision and stable identity. Its intent still retains the checked revision. |
| `flash-bundle` | Exact Target ID/revision and the durable Target's physical identity digest. |
| `hap`, `native-library` | Exact Target ID/revision and SHA-256 of the actual proven HDC route's connect key. |

For HAP/native-library the Target owner must provide the equivalent of Swift
`RuntimeTargetStore.hdcExecutionRoute`, including validated alias history, exact
route revision, route ambiguity refusal and the existing handling of a fresh
Runtime-observed candidate snapshot. A presentation projection's physical digest
cannot substitute for the HDC route digest. If that actual route API has not
joined the Runtime, those kinds must remain unavailable. No caller-provided JSON,
connect key, observation or capability can fill the gap.

The composition root can then replace its unavailable closure with the existing
owner call, without exposing the snapshot to RPC inputs:

```rust
.handle_resource(method, params, &utc_now(), false, |intent| {
    self.targets.as_ref().ok_or_else(unavailable)?
        .resolve_import_binding(intent)
})
```

The upload owner invokes this closure only for a new request. An existing exact
request preserves its original snapshot, offset, generation and identity. The
new-begin writer requires the kind's exact nullable/non-nullable snapshot shape;
its frozen decoder continues accepting the existing optional-field format.

Integration tests must use actual Target-owned durable fixtures and cover each
kind, missing/stale revision, malformed alias proof, absent/ambiguous HDC route,
and an RPC attempt to inject binding/app provenance. The current process test
intentionally asserts new-begin `operationUnavailable`; update only that assertion
when an actual Target owner is composed, and retain a missing-owner case.

This API does not validate or publish import bytes. Commit, lease/reference
inspection, release and installed-owner activation remain unavailable until their
complete owners are implemented. A later publication phase must perform its own
current binding, content, quota and lease/reference checks. The proposal creates
no device dispatch, trusted fact, capability or hardware evidence.
