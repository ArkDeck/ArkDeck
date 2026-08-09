# r11 Design — Exact same-revision reactivation for a displaced DAYU200 binding

## Product defect

DAYU200 uses one owner-only `rockchip-binding.json` as the active cross-mode binding. Selecting a
second adopted board correctly replaces that singleton, but the previous advanced target remains
in `RuntimeTargetStore` with revision greater than one and cannot become active again. The only
existing cross-target switch accepts revision one; the ordinary rebind path accepts only the
currently active target or one adjacent HDC-to-Loader advance.

The result is a pre-admission dead end: a fresh Loader can exactly match the displaced target's
current stable identity and revision, while Runtime reports `targetBindingUnprepared` and rejects
the UI request. No Job or device write occurs, but the user cannot Flash that already-adopted board.

## Selected proof

r11 does not restore overwritten binding bytes and does not infer lineage from a target ID or Job
success. Protected-main Runtime may create a distinct same-revision reactivation binding only when
all of the following are true:

1. IOKit freshly reports exactly one registered DAYU200 and it is Loader mode.
2. Its serial digest equals the selected target's current stable identity; the target ID, revision
   and stable identity select exactly one Runtime target record.
3. An owner-only typed `wait-for-hdc` intent exists for that exact target, current revision and
   current stable Loader identity. Its action hash is recomputed and its HDC connect key equals the
   target record's retained connect key.
4. A correlated owner-only `rockchip.observeHDCNormalUSB` intent and semantic receipt exist at the
   directly previous revision for the same target and connect key. The reconnect intent and route
   receipt name the same provider executable; intent/action/receipt correlation is exact, and the
   receipt confirms `hdc-normal`, the connect-key digest and a numeric USB topology.
5. Every qualifying route receipt agrees on one topology. A second topology is ambiguity, not a
   candidate to rank or choose.

The resulting binding has a separate closed evidence shape: exact reactivated target ID, current
typed-intent digest, confirmed-route receipt digest, HDC alias/topology, displaced active identity,
and the current App-selection digest. It deliberately contains no `previous-serial`,
`previous-revision` or `previous-topology` fields and therefore produces no
`RuntimeTargetBindingLineageAdvance`.

## Runtime behavior

The binding store compare-and-swaps the exact active revision/identity to the reviewed
reactivation candidate. The target store is not written. A lost XPC response can retry
idempotently from the newly active evidence, but the reactivation evidence is not eligible for the
adjacent-binding crash-recovery helper.

The restored HDC alias is available to the existing bound post-flash reconnect action. After a
later genuine HDC-to-Loader transition, the ordinary adjacent lineage path may create the next
revision as before.

## Fail-closed and compatibility rules

- Missing record roots, no current-revision intent, no confirmed route, wrong target/revision/
  identity/connect key, non-adjacent revision, provider drift, malformed owner/mode/size,
  action-hash drift, receipt mismatch, truncated output or multiple topologies produce no
  reactivation proof.
- The old rev2/chat-attestation same-revision migration remains removed. Presenting that historical
  binding still leaves it byte-for-byte unprepared and cannot authorize Flash.
- Runtime does not read terminal success strings, legacy authority/campaign records, Artifact
  evidence or caller-provided proof for reactivation.
- The path adds no operation, Provider, profile, Step, partition, executable/argv input or effect
  downgrade. Candidate and App surfaces still cannot supply trusted facts.
- Candidate/unmerged code never runs against hardware. Only a protected-main merge may make this
  binding rule available, after which a fresh zero-submit review precedes any new destructive UI
  click.

## Rejected alternatives

- Recreate the overwritten binding from target ID/revision and current Loader alone: incomplete
  because it cannot safely identify the post-flash HDC personality.
- Treat a prior Flash write/readback or Job success as binding authority: those facts do not encode
  the missing HDC route/topology and would conflate outcome with identity.
- Accept the only HDC device after reboot: wrong-device risk when multiple boards share firmware.
- Reset the target to revision one or rewrite historical records: destroys binding truth and can
  make old intents appear current.
- Require text confirmation: confirmation cannot supply missing identity proof and is not Runtime
  authority.
