# Tagged CLI Artifact resources

The current v1 Artifact surface completes the GJ-1/GJ-2 path from a Job or
imported input to bounded inspection and explicit host export. It changes no
Catalog operation, provider, device admission policy or capability authority.

```sh
arkdeck artifact list --job JOB_ID --page-size 20 --output json
arkdeck artifact inspect --import IMPORT_ID --artifact ARTIFACT_ID --output json
arkdeck artifact read --import IMPORT_ID --artifact ARTIFACT_ID --offset 0 --max-bytes 1048576 --output json
arkdeck artifact read --job JOB_ID --artifact ARTIFACT_ID --raw
arkdeck artifact export --job JOB_ID --artifact ARTIFACT_ID --destination /absolute/existing/directory
```

Select exactly one `--job` or `--import`. The daemon validates the tagged owner
against its durable resource; an Import namespace is never a Job or hardware
evidence. Released Imports remain readable while retention keeps their content,
but their metadata exposes no executable input lease. Each command has a bounded
`--timeout`. All renderings use the same current tagged-owner contract.

List returns a fixed `arkdeck.cli.page/1` snapshot ordered by parsed creation time
descending and Artifact ID ascending. Its cursor binds the owner, page size and
snapshot revision and survives restart. Index reads and captured snapshots are
bounded at 16 MiB. Inspect returns validated `arkdeck.artifact/1` metadata with
owner, digest, privacy, publication state, retention, binding and provenance.
Metadata queries neither require nor accept sensitive-content permission.

Read accepts offset zero through the exact byte count, with a safe-integer
ceiling, and a maximum of 1 through 4,194,304 bytes (default 1,048,576). Invalid
bounds are refused, not clamped. The fixed range projection carries Artifact ID,
full-content digest, offset, next offset, total bytes, EOF, byte count and strict
padded Base64. A full 4 MiB range fits the 8 MiB response frame even for bytes
whose Base64 consists almost entirely of slashes. JSON and raw output validate
the same response against inspected metadata; raw writes only decoded bytes,
with no newline. Stable file descriptors, content hashes and identity checks
reject content changes during access.

Sensitive read and export each require `--allow-sensitive`. Export defaults to
refusing an existing file; `--overwrite` authorizes only the exact generated
filename and does not grant sensitive access. The destination must be an existing
physical directory outside Artifact storage. Symbolic-link components and
nonregular or multiply linked destination files are refused. Standard macOS
`/tmp`, `/var` and `/etc` aliases map only to their `/private` equivalents.

Export writes a private staging file, synchronizes and hashes it, rechecks the
source and destination identities, then atomically publishes the complete file.
No-overwrite publication uses an exclusive rename, including when the destination
appears concurrently. Post-publication durability or identity uncertainty returns
`outcomeUnknown`; it never deletes the published result or claims that zero
device dispatch means no host write occurred. Inspect the exact destination
before retrying after a lost response. A process killed before publication may
leave its private staging file; no cleanup guesses ownership from a filename
prefix or removes another file.

Host contract tests exercise actual CLI and daemon responses, owner separation,
released Import reads, 4 MiB JSON/raw parity, strict bounds, snapshot restart,
sensitive access, overwrite, source mutation, unsafe destination identities,
directory substitution and publication races. Separate processes are actually
killed before and after publication to verify original-or-complete destination
content and unchanged Artifact inputs. These fixtures are not real-device passes.
GJ-1–GJ-5 acceptance still requires the reviewed protected-main Runtime and current
Catalog digest through Agent/CLI.
