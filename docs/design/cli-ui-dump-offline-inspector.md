# UI dump offline inspector

`UIDumpOfflineInspector` is the versioned local owner for reading a UI dump capture after the
Runtime has published its Artifacts. The App and CLI both call this owner. The service takes
immutable metadata plus bytes and has no device transport, Runtime mutation, Job submission, or
evidence-writing capability.

The required source roles are exact:

- `screenshot.png` with media type `image/png`;
- `ui-tree.json` with media type `application/json`;
- optional `ui-dump.json` with media type `application/json`.

An arbitrary PNG cannot stand in for `screenshot.png`. Duplicate or malformed Runtime inventory
rows are refused by the CLI before reading. The CLI verifies the current v1 control identity and pages the
tagged Job-owned Artifact inventory; every range stays bound to the selected owner, Artifact ID,
total byte count, and digest. Each complete byte sequence must match the published byte count and
lowercase SHA-256 digest before parsing, and the complete in-memory capture is bounded to 64 MiB.
The same owner applies these checks when the App loads a capture.

Inspection publishes `arkdeck.ui-dump-inspection/1`. Hit testing publishes
`arkdeck.ui-dump-hit-test/1` and refuses captures whose screenshot coordinate mapping was not
verified. Both documents carry `kind: offlineDerived`, parser identity and version, the original
observation window when known, and every source Artifact identity, role, byte count, media type,
and digest. These results describe an earlier capture and never become current device facts or
Runtime evidence.

The language-neutral machine contract is
[`cli-ui-dump-offline.schema.json`](../../Packages/ArkDeckKit/Contracts/cli-ui-dump-offline.schema.json).
Changing parser semantics, source roles, output fields, or bounds requires a version change and
contract fixtures for the old and new forms.

This closes the UI dump part of the broader offline-inspector product item. Diagnostics preview
and Trace inspection still need their own typed, versioned local owners before the complete item
can move from `blocked` to `local` in the CLI coverage manifest.
