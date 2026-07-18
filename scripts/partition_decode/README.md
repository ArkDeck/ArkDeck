# DAYU200 pinned-image partition decoder

CHG-2026-009 / TASK-PD-001. Offline, read-only, Python standard-library-only
research tooling.

`decode.py` first uses `lstat` to reject known non-regular paths, then opens with
`O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` and applies `fstat` stability checks before
reading. This rejects devices, FIFOs, directories and symlinks in the stable
case, then accepts only the archived
CHG-2026-003 archive identity. It streams to the fixed `parameter.txt` member
without extracting to disk, verifies that member's archived size/hash, parses
the closed CMDLINE/mtdparts grammar, and reconciles the decoded partition names
with every row of the archived 17-member inventory. A remainder/grow entry must
be last; every unknown or illegal grammar shape fails explicitly. The CLI has no
identity bypass.

The four create-only outputs are `partition-mapping.json`,
`member-reconciliation.json`, `process-audit.json`, and `summary.md`. They never
contain the external archive locator or original `parameter.txt` text. Results
are non-authoritative and valid only for the pinned archive; encoded offsets are
not flash-address derivations and make no protocol, compatibility, executable
profile, device, hardware-support, or release claim. The complete pinned
identity, 15-partition fact set, archived 17-member inventory and cross-document
mapping are closed-validated before output. All four target names are preflighted
before the first byte is written, preventing mixed old/new evidence directories.

Current verification status is **blocked**: because `parameter.txt` is the eighth
member of one gzip/DEFLATE tar stream, locating it consumes seven preceding member
bodies. The accepted AC says no other member content may be read. The tool records
those reads explicitly. In addition, the path-based `lstat` → `open` sequence has
a replacement race in which a device can be opened before `fstat` rejects it, so
it cannot statically prove the accepted absolute zero-device-access boundary.
The tool writes failure evidence and exits 3; it does not claim acceptance.
Treating stream-discard as permitted or defining a trusted-fd/OS-sandbox threat
model requires separately approved governance—this implementation makes neither
decision.

Run:

```text
python3 scripts/partition_decode/decode.py \
  --archive /external/pinned/archive.tar.gz \
  --out-dir openspec/changes/chg-2026-009-dayu200-partition-decode/evidence
```

Tests:

```text
python3 scripts/partition_decode/test_decode.py
```
