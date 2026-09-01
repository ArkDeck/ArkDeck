# Diagnostics offline inspector

`arkdeck diagnostics inspect|preview|export` closes the read side of a
`capture.diagnostics@1` Job without contacting a device or creating another
evidence record.

## Typed owner

`DiagnosticSessionOfflineInspector` is the single parser used by the App and
CLI. It accepts immutable Artifact metadata plus already-read bytes. Before
parsing it checks exact Job/operation correlation, unique Artifact identities
and names, byte counts, lowercase SHA-256 digests, media types, privacy and
fixed input bounds. The App adapter also preserves the Catalog-derived role
check for session documents; protocol 2 Artifact resources do not expose a
second role field for the CLI to trust.

Inspection reads only these standard-privacy JSON documents:

- `artifact-index.json`;
- `capture-summary.json`;
- `markers.json`, when published.

The index and summary must agree exactly. Requested but unpublished products
remain named as missing, and the result stays partial. No clock calibration is
invented. The machine result is
`arkdeck.diagnostics-inspection/1` and identifies the parser, parser version and
every source digest.

## Text preview

`diagnostics preview --job <id> --artifact <id>` reads one exact text or JSON
Artifact through protocol 2 range reads. The complete content is limited to
2 MiB and output to 120,000 Unicode characters by default. A sensitive
Artifact requires `--allow-sensitive`; invalid UTF-8 replacement is allowed
only for `text/plain` and is disclosed. Structured JSON text must be valid
UTF-8. The result is `arkdeck.diagnostics-preview/1` and remains
`offlineDerived`.

## Export

`diagnostics export` is a constrained spelling of `artifact export`: it accepts
only a Job-owned Artifact whose `sourceOperation` is
`capture.diagnostics@1`. Destination, overwrite and sensitive-content rules
remain owned by the existing Artifact export contract. Export does not alter
the source Job or Artifact and does not turn a host copy into device evidence.

The language-neutral result schemas are published in
`Packages/ArkDeckKit/Contracts/cli-diagnostics-offline.schema.json`.
