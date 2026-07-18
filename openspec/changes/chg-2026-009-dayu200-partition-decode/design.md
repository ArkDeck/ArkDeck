# CHG-2026-009 r3 design — streaming, codec state and trusted input boundary

> Change:CHG-2026-009-dayu200-partition-decode@r3
> Status:candidate;only the maintainer-reviewed revision PR merge makes r3 effective

## Decision 1:bounded stream-discard

The pinned archive is one gzip/DEFLATE stream and `parameter.txt` is its eighth tar
member. A decoder cannot reach that header without decompressing preceding bytes.
r2 therefore permits only the minimum sequential consumption needed to advance the
stream. Non-target body bytes have a closed application lifecycle:read in chunks no
larger than 1 MiB, counted, and released before the next plaintext chunk is requested.
No application-owned reference, view or copy of an earlier non-target plaintext chunk
may remain. Those bytes are never parsed, hashed, returned, logged or persisted. The
decoder stops after the target.

DEFLATE is an LZ77 stream whose later blocks may refer to output up to 32 KiB earlier.
RFC 1951 and the zlib `inflateInit2` contract therefore require a decoder with a
15-bit DEFLATE base window to maintain an internal 32768-byte history window. For the
gzip wrapper, the zlib API value is `wbits=16+15=31`; the additive wrapper flag does not
enlarge the base history window. r3 treats only that standards-required, codec-owned and
application-inaccessible history as opaque codec state rather than an
application-retained body chunk. This is a closed exception:

- the codec is configured exactly for gzip-wrapped DEFLATE with base window bits 15
  (`wbits=31` in zlib) and no preset dictionary;
- the application cannot request a history/body view, clone/copy the codec state, or
  parse, hash, log, persist, return or otherwise use the history;
- application-held compressed input remainder is separate from decoded body and is
  capped at 65536 bytes;
- the codec and compressed remainder are destroyed immediately after the target body
  is obtained or on any failure/cancellation;
- evidence reports the codec, configured window, maximum history, compressed-remainder
  cap, absence of an application-visible retained plaintext reference and destruction
  point. Missing or unverifiable fields fail closed.

This exception does not allow a second decoded-output buffer, tar extraction, codec
state serialization, `inflateCopy`, preset dictionaries or allocator-forensic claims.
“Discarded” means no live application-level reference or secondary use; it does not
claim secure zeroization of memory previously owned by the codec.

This decision protects the actual goal(no extraction or secondary use of unrelated
member content) without claiming impossible random access or impossible absence of
algorithm state. If future policy requires non-target bytes never to enter the process,
or requires forensic zeroization, the input format must change to an independently
addressable member or approved sidecar; indexing the existing single DEFLATE stream
does not satisfy that stronger rule.

Normative algorithm references for this change-local boundary:

- RFC 1951, §2, limits backward distances to 32 KiB:
  `https://www.rfc-editor.org/rfc/rfc1951.html`.
- zlib 1.3.1 manual, `inflateInit2`, defines the base `windowBits` range as 8...15
  and adding 16 as gzip decoding with header/trailer checks:
  `https://www.zlib.net/manual.html`.

## Decision 2:capability-based decoder

The audited production decoder does not accept a pathname. It receives an already
open read-only descriptor/capability, performs `fstat` before its first read, accepts
only a regular file, and then applies the pinned size/SHA gate. It contains no
`open`, `openat`, `lstat` or equivalent path-resolution target.

Descriptor acquisition belongs to a separate macOS sandbox broker. The broker must:

- be a separately signed and reviewable artifact with a closed entitlement/policy
  set that excludes every character/block device-node namespace, including USB,
  serial and raw disks;
- acquire only the user-authorized archive and transfer the descriptor rather than
  a pathname;
- record the exact signing identity, entitlements/policy and descriptor-transfer
  chain as platform evidence;
- fail closed if the sandbox/policy cannot establish the device exclusion.

`ArkDeckApp` currently declares USB and serial entitlements, so its existing sandbox
status alone is not this broker evidence. A dedicated least-privilege broker or an
equivalent independently approved platform mechanism is required.

## Threat model

In scope:malicious archive bytes; symlink/FIFO/device substitution; concurrent path
replacement before capability creation; untrusted archive basename/location; and a
caller attempting to pass a non-regular descriptor. The design trusts the macOS
kernel, code-signing and sandbox enforcement. Compromised kernel/root is out of
scope and must not be hidden by an application-level claim.

The workflow-level zero-device claim requires both halves:the broker's OS policy
prevents device acquisition, and the decoder has no path open and performs zero read
on non-regular descriptors. A trusted-fd assertion without broker evidence proves
only decoder behavior and does not pass r3.

## Rejected alternatives

- `lstat → open → fstat`:the device may already be opened before `fstat` rejects it.
- fd-only with an unspecified caller:moves the risk without proving the workflow.
- opening real device nodes as a negative test:violates the zero-device gate.
- treating discarded bytes as “not read”:misstates gzip/DEFLATE execution.
- treating mandatory DEFLATE history as an application plaintext chunk:makes sequential
  decoding impossible without adding protection against secondary use.
- allowing arbitrary “internal state”:unbounded and unverifiable; r3 permits only the
  fixed 15-bit DEFLATE window and closed lifecycle above.
- a DEFLATE seek index:may reduce work but does not prove non-target bytes were never
  consumed and adds a new derived artifact/trust problem.

## Revision and readiness

r3 approval changes only the change-local design and acceptance boundary. It does not
reinterpret r1/r2 evidence, change the merged implementation, generate fresh evidence,
or make TASK-PD-001 ready/done. After r3 is approved on `main`, a separate readiness PR
must pin the minimal codec-state remediation and fresh three-AC rerun before execution
resumes. The interactive PowerBox requirement and all r2 trusted-fd/sandbox gates remain
unchanged.
