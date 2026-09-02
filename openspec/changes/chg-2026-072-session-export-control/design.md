# Design — CHG-2026-072

## Closed command and protocol shape

The CLI publishes:

```text
arkdeck session export preview --session <id> --destination <absolute-path> [--allow-sensitive]
arkdeck session export apply --preview-id <uuid> --preview-digest <sha256>
```

The matching protocol-2 methods are `session.export.preview` and
`session.export.apply`. Preview parameters are exactly `sessionId`,
`destinationPath`, and `allowSensitive`; apply parameters are exactly
`previewId` and `previewDigest`. There is no `confirm` leaf or caller-provided
generation, Artifact list, privacy classification, redaction policy, output
filename, overwrite flag, or device fact.

## Runtime ownership and linearization

The daemon-owned Session storage resource scans the complete finalized
catalog. A preview digest covers the catalog and storage-policy generations,
source Session, ordered Artifact identity/digest/role/bytes/privacy rows,
selection, device-identifier redaction policy, expiry, and exact destination
parent device/inode/volume facts. Unknown or unaccounted Session content fails
closed.

Apply re-reads the durable preview and all facts before writing. The exact
destination must still be absent and its symlink-free, owner-held parent must
retain the same identity. Runtime durably records `applying` before staging.
Once that state is visible, any unprovable result is permanently
`outcomeUnknown`; retry never republishes. A successful publication stores and
returns an immutable receipt.

## Privacy and storage admission

Raw and partial Artifact roles are sensitive and excluded unless the preview
request explicitly enables them. Other roles stay `unknown` rather than being
promoted to standard. All included data uses the existing
`SessionDiagnosticExporter` with `deviceIdentifierPolicy=redact`; the exported
manifest records transformed Artifact lineage where required.

The source catalog is the authority for finalized Session identity. The
external destination receives a separate bounded heavy-writer claim tied to
its measured volume and a maximum transformation budget. That claim is not
evidence that it created or owns the source Session and cannot authorize a
write inside Runtime/Session storage. The final directory is published by
descriptor-anchored exclusive rename and fully read back before success.

## Failure classification

- malformed identity/path/options: `invalidInput`;
- missing Session: `resourceNotFound`;
- expired preview, source/destination/generation/privacy drift, or existing
  destination: `resourceConflict` before publication;
- insufficient bounded destination headroom: `quotaExceeded`;
- corrupt Session/manifest/Artifact inventory: `recordUnreadable`;
- any uncertainty after durable `applying`: `outcomeUnknown` with zero replay.
