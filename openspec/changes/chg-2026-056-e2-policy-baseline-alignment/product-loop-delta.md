# PRODUCT-LOOP.md Delta

> Change: `CHG-2026-056-e2-policy-baseline-alignment@r7`
> Target: `PRODUCT-LOOP.md` §15
> Applies only after this Core/Safety revision is approved and merged.

## MODIFIED Unknown-effect recovery rule

Recovery SHALL still begin from the original durable intent and a Provider-specific readback.
`COMPLETED` and `NOT_EXECUTED` retain their existing meanings. A destructive intent with an
unresolved outcome SHALL NOT be resent, assigned a guessed result or hidden as ordinary failure.

When readback yields `STILL_UNKNOWN` or `PARTIALLY_COMPLETED`, protected-main Runtime SHALL
automatically test whether the published operation/profile Provider contract can conservatively
bound every possible effect and prove a distinct complete-overwrite recovery covers the union. If
all fresh identity/binding/topology, immutable Artifact, coverage, verification and budget facts
hold, Runtime MAY classify `safeToSupersedeByCompleteOverwrite` and run that recovery without a
human-decision prompt. Success records a durable `SupersedingRecoveryEpoch`; the original outcome
remains unknown while the current target lane becomes known.

If the proof is unavailable, dispatch remains zero and the product reports the exact
non-overridable safety blocker. It SHALL NOT ask the user to approve absent proof. `outcomeUnknown`
therefore never automatically resends its original side effect, but it also does not permanently
block a target that the Runtime can restore and verify through a reviewed complete-overwrite plan.
