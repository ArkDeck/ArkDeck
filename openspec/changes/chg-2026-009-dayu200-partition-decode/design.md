# CHG-2026-009 r2 design — streaming and trusted input boundary

> Change:CHG-2026-009-dayu200-partition-decode@r2
> Status:candidate;only the maintainer-reviewed revision PR merge makes r2 effective

## Decision 1:bounded stream-discard

The pinned archive is one gzip/DEFLATE stream and `parameter.txt` is its eighth tar
member. A decoder cannot reach that header without decompressing preceding bytes.
r2 therefore permits only the minimum sequential consumption needed to advance the
stream. Non-target body bytes have a closed lifecycle:read in chunks no larger than
1 MiB, counted, and immediately discarded. They are never parsed, hashed, returned,
logged, persisted or retained across chunks. The decoder stops after the target.

This decision protects the actual goal(no extraction or secondary use of unrelated
member content) without claiming impossible random access. If future policy requires
non-target bytes never to enter the process, the input format must change to an
independently addressable member or approved sidecar; indexing the existing single
DEFLATE stream does not satisfy that stronger rule.

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
only decoder behavior and does not pass r2.

## Rejected alternatives

- `lstat → open → fstat`:the device may already be opened before `fstat` rejects it.
- fd-only with an unspecified caller:moves the risk without proving the workflow.
- opening real device nodes as a negative test:violates the zero-device gate.
- treating discarded bytes as “not read”:misstates gzip/DEFLATE execution.
- a DEFLATE seek index:may reduce work but does not prove non-target bytes were never
  consumed and adds a new derived artifact/trust problem.

## Revision and readiness

r2 approval changes only the scoped design and acceptance boundary. It does not
reinterpret r1 evidence, implement the broker/descriptor path, or make TASK-PD-001
ready/done. After r2 and the r1 failure evidence are both on `main`, a separate
task-scope/readiness PR must pin the broker deliverable, allowed paths and all three
ACs before remediation implementation begins.
