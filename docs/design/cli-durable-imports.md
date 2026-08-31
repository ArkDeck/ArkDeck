# Durable CLI input Imports

This slice of `arkdeck-cli-product-spec.md` §7.6 makes registered input uploads
resumable and discoverable for GJ-1–GJ-5. It changes no Catalog operation,
provider, device admission policy or Runtime authority. These commands always
negotiate control protocol 2 and never fall back to legacy upload coordinators:

```sh
arkdeck artifact import hap --import-request-id build-123 --target TARGET_ID --file app.hap --output json
arkdeck artifact import workspace-patch --import-request-id patch-123 --target TARGET_ID --file fix.patch --output json
arkdeck artifact import native-library --import-request-id native-123 --target TARGET_ID --file libexample.so --output json
arkdeck artifact import flash-bundle --import-request-id flash-123 --target TARGET_ID --file images.tar.gz --device-profile dayu200 --output json
arkdeck artifact import inspect --import-request-id build-123 --output json
arkdeck artifact import inspect --import IMPORT_ID --output json
arkdeck artifact import list --target TARGET_ID --state inProgress --page-size 20 --output json
arkdeck artifact import abort --import-request-id build-123 --expected-generation 1 --output json
```

The internal `artifact.import.begin/append/commit` RPCs are not public CLI
leaves. The older `artifact import-*` leaves and their protocol-1 responses are
unchanged during the staged migration.

Before upload the client hashes one stable regular-file descriptor in bounded
chunks. Metadata binds the caller request identity, registered kind/schema,
target/binding revision, profile, logical name, size and SHA-256, never a host
path. Native Artifact export prefixes are normalized to the registered library
name; flash archives use `images.tar.gz` as their logical name. Source symlinks,
nonregular files and changed identity/content fail before continuing an upload.

The Runtime persists request-to-Import identity before accepting bytes. One
Artifact store actor owns append, commit and abort. Upload generation stays 1
while `nextOffset` advances; each chunk binds exact offset, length and digest.
Exact chunk retries return the existing checkpoint, while changed overlap or
gaps fail. Bytes are fully synchronized before the checkpoint is atomically
published. On restart an uncommitted suffix is truncated before state is exposed;
a missing or corrupt committed prefix is `recordUnreadable`, never overwritten.

The CLI rehashes the source on retry, finds the Import by request identity and
continues at the durable offset. Lost begin/append/commit replies are reconciled
through inspect under the same total deadline. Client timeout or interruption
never aborts staging. Changed source content is `artifactIntegrityFailed`;
reusing the identity for different metadata is `idempotencyConflict`.

Commit first validates the exact source digest and current target binding using
the existing HAP ZIP, workspace patch, signed OpenHarmony ELF or DAYU200 archive
validator. Flash profile selection participates in that validation. The validated
commit intent is durable before immutable publication, so recovery can finish the
same publication even if the target later changes; input consumers still enforce
the recorded binding. A published file without its committed Import receipt is
not an executable input lease. The receipt contains the tagged Import owner,
Artifact identity/digest, target, lease and generation 2. It survives lost output
and daemon restart without another Artifact or pin. Imports create no Job records
and do not appear in Job history or evidence.

Workspace patches retain their exact validated source bytes and are marked
`sensitive`; they are not diagnostic text to redact. Existing public binary
publication restrictions and sensitive read/export policy remain intact.

Abort wins only before the commit intent: it records a generation-2 tombstone
before removing staging, and repeated original-generation aborts retry cleanup.
An aborted request cannot be resurrected. Once commit owns the Import, abort
returns `resourceConflict`.

Import storage allows 4,096 retained owners, 16,384 chunk checkpoints per upload,
2 MiB chunks and 8 GiB of declared active staging. Capacity exhaustion does not
delete another owner. Private records, staging and identity indexes reject unsafe
file identities. List uses fixed `arkdeck.cli.page/1` snapshots ordered by parsed
creation time descending then ASCII Import ID ascending; cursors bind filters,
page size and snapshot revision, and survive restart. Shared Runtime/CLI projection
validation rejects malformed counts, state/receipt disagreement and foreign
owners.

Host fixtures cover actual SIGKILL during partial append, synchronized append,
durable commit intent and publication-before-receipt; source/prefix corruption;
symlinks; tombstones; snapshot restart; all registered validators; and actual CLI
recovery after dropping all three mutation replies. These are not hardware passes.

Remaining full-CLI work includes generation-bound Import release with atomic
Job/plan acquire, tagged Import selectors on Artifact list/inspect/read/export,
the remaining resource/control surfaces, default protocol migration and the full
machine-contract manifest. GJ-1–GJ-5 real-device acceptance must use the reviewed
protected-main Runtime and current Catalog digest through Agent/CLI.
