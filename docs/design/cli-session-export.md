# Runtime Session export

Task: TASK-AIN-021 (delivered with `CHG-2026-072-session-export-control`)

`arkdeck session export preview` and `arkdeck session export apply` publish a
bounded, derived copy of one finalized Session through the daemon-owned Session
storage resource. Neither command accepts a Session path, Artifact path,
executable, device command, overwrite flag or caller-supplied privacy fact.

Preview takes exactly one Session identity, one absolute destination path and
the `--allow-sensitive` choice. The destination is the directory the export
will create; it must be absent, its parent must already exist as an owner-held
directory without symbolic-link components, and it may not lie inside Runtime
or Session storage. Preview persists an immutable Runtime-private record for
ten minutes. Its canonical digest binds the catalog and storage-policy
generations, the source Session, every Artifact identity, digest, role, byte
count, privacy classification and disposition, the device-identifier redaction
policy, the expiry, and the destination parent device, inode and volume. Raw
and partial Artifacts are sensitive and excluded unless the preview opted in;
other roles remain `unknown` rather than being promoted to standard. The
response reports estimated bytes and zero device dispatches and contains no
Session-private path.

Apply requires exactly the lowercase preview UUID and SHA-256 digest returned
by preview. That tuple is the explicit confirmation; there is no separate
`confirm` command, and apply names no destination or privacy choice of its own.
Before writing, Runtime re-reads the durable preview and recomputes every fact
under the catalog lock. An expired preview, a changed catalog or policy
generation, a changed Artifact inventory, a moved parent, or an occupied
destination returns `resourceConflict` with zero output. Runtime durably marks
the preview as applying before staging, then writes through the anchored
`SessionDiagnosticExporter` with device-identifier redaction, a bounded
heavy-writer claim measured against the destination volume, per-file checksum
validation and one exclusive rename. A successful apply stores an immutable
receipt that names the exported directory, the included and excluded Artifact
identities and the `derivedExport` evidence class; retries return that receipt
without publishing again. If execution stops after the applying mark and the
outcome cannot be proven, apply returns `outcomeUnknown` forever for that
preview and never replays it.

The source Session and its Artifacts are never modified, and the exported
manifest records transformed lineage where redaction changed bytes. The
contract fixtures cover parsing, protocol and XPC admission, preview digest
validation, default exclusion and explicit opt-in, destination and generation
drift, expiry, injected publication faults, durable retry, refused inputs and a
real `arkdeck` subprocess. Export is host-owned and makes no device dispatch,
so these tests do not claim real-device acceptance.
