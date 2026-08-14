# ArkTrace summary analyzer profile

ArkDeck exposes the existing `analyzer.summarize-trace@1` operation only when the daemon owner
selects a reviewed ArkTrace CLI distribution descriptor. Requests cannot provide this descriptor,
an executable, arguments, or a search path.

## Install and select

1. Install one exact, versioned `ArkTraceCLI.app` distribution together with its
   `distribution-manifest.json` and notarization receipt. Do not edit an installed version in
   place.
2. Create a small descriptor owned by the daemon operator:

   ```json
   {
     "distributionRoot": "/absolute/physical/path/to/ArkTraceCLI-0.1.0",
     "formatVersion": 1,
     "manifestSHA256": "<lowercase SHA-256 of distribution-manifest.json>"
   }
   ```

3. Start `arkdeck-agentd` with `ARKDECK_ARKTRACE_DESCRIPTOR` set to the descriptor's absolute
   physical path. The descriptor and every distribution component must be regular, non-symlinked
   bytes under the selected root.

At daemon start, ArkDeck validates the descriptor and closed manifest contract, remeasures the
tool and bundled parser identities, and runs the identity-bound, bounded
`doctor --self-test --json --no-cache` check. Before doctor or Job admission, the complete
validated distribution is copied through retained directory/file descriptors into a daemon-owned
mode-0700 generation keyed by the full distribution tree SHA-256. The successful profile points
only into that private immutable generation; removing or replacing the external install cannot
rebind the App namespace used by a running daemon. Each later availability decision remeasures
all pinned generation files, so in-place byte, mode, owner, or tree drift immediately makes the
operation unavailable.

## Failure and recovery

Availability failures are stable machine reasons: `analyzer.arktraceNotFound`,
`analyzer.arktraceDescriptorInvalid`, `analyzer.arktraceManifestDrift`,
`analyzer.arktraceContractMismatch`, `analyzer.arktraceToolDrift`,
`analyzer.arktraceParserDrift`, or `analyzer.arktraceSelfTestFailed`. An unavailable profile does
not admit a Job or consume Runtime capability.

For an upgrade, install and verify a new versioned directory, write a new exact descriptor, then
restart the daemon with that descriptor. For rollback, select a retained prior descriptor and
restart; ArkDeck revalidates the retained bytes and materializes/reuses the matching private tree
generation rather than trusting prior availability. Never repair or replace either the selected
external install or a daemon-private generation in place.

The summary invocation remains host-only and binding-free. ArkDeck owns the complete argument
array and appends the resolved immutable Artifact path as one argument token. No shell, `PATH`,
HDC, GUI, device binding, or caller-provided argument participates in executable selection or
lowering.

The signed App's CLI is launched through the private generation's canonical bundle path in a
suspended state. Before the child executes, ArkDeck compares the kernel's first executable mapping
device/inode with the already-open, hashed descriptor receipt and revalidates every pinned
resource; mismatch is killed and reaped without resuming. Ordinary standalone analyzers retain
the stable device/inode launch path. The source Artifact is likewise opened once, hashed and
passed as its stable `/.vol/<device>/<inode>` alias while the descriptor remains held through
child drain.

On success, ArkDeck accepts only the closed ArkTrace JSON 1.0 summary envelope. Tool, fixed
request and limits, source Artifact SHA/byte count, parser identity/build recipe, adapter/index
provenance, typed data-quality evidence, truncation evidence and summary range/counts are all
validated together. Captured or over-budget stdout and any stderr are refused. The derived
`trace-summary.json` is the exact validated stdout byte sequence; Runtime does not wrap or
re-encode it. Durable action and Artifact evidence retain source, tool, parser, request and derived
hash/byte-count lineage without publishing host paths.
