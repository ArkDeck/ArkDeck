# r7 Design — autonomous complete-overwrite recovery for uncertain Flash outcomes

## Decision shape

r5 removed per-run human authority but retained a permanent stop after any destructive
`outcomeUnknown`. That stop is safe, but it turns one lost tool outcome into a permanent target-lane
blocker and sends the Agent back to a human even when the Runtime can mechanically restore the
entire device state. r7 adds one narrowly typed alternative:

```text
durable destructive intent has no confirmed outcome
  -> never replay that intent
  -> protected-main Runtime computes the conservative uncertain-effect set
  -> fresh same-physical-target and loader/topology readback
  -> published Provider proves a complete-overwrite recovery plan covers that entire set
  -> Runtime classifies safeToSupersedeByCompleteOverwrite
  -> distinct recovery capability + reservation + intent
  -> complete overwrite + semantic verification + reboot/rebind/postflight
  -> durable SupersedingRecoveryEpoch linked to every covered uncertain intent
  -> old outcome stays unknown; current target lane becomes known
```

This is not a retry of the missing-outcome Step. The original intent is immutable and is never
given a fabricated outcome. The recovery dispatch is a new typed effect whose safety comes from
covering every state the old intent could have changed, not from guessing whether it ran.

## Conservative uncertain-effect set

For every outstanding destructive intent on the same target lane, Runtime SHALL derive a closed
`uncertainEffectSet` from durable operation/version, profile version, materialized Step and Provider
contract facts. The set includes every partition, boot metadata item, userdata effect, mode change
or other device state that the intent may have mutated. Optional or conditional effects are included
unless a durable outcome proves they did not occur.

An intent whose possible effects cannot be bounded is not eligible for automatic supersession.
Caller text, UI state, archive filename, current partition contents or an exit code without its
durable semantic outcome cannot narrow the set.

## Complete-overwrite proof

A Provider MAY publish `completeOverwriteSupersessionSafe` only for an exact operation/profile
pair. Its contract SHALL provide:

- a finite recovery-coverage domain and a mapping from every covered effect to a typed overwrite,
  reset or semantic closure action;
- prerequisites for a stable physical identity, binding, loader/transport topology, power and tool;
- rules proving the recovery plan covers the union of all outstanding uncertain effects;
- immutable archive/Artifact and ordered plan/Step-set correlation;
- per-effect semantic verification plus reboot, rebind and runtime-build postflight;
- explicit non-coverable effects and stop conditions.

Runtime may classify `safeToSupersedeByCompleteOverwrite` only when the published proof covers the
entire conservative set and all prerequisites are freshly satisfied. A partition that is omitted,
write-forbidden, only partially written or not semantically verifiable makes the classification
unavailable. `safeToReflash` remains the ordinary retry classification; the new classification is
used only for a distinct complete-overwrite recovery.

## Recovery epoch and journal honesty

Each superseding recovery is a distinct lineage node with its own RuntimeCapability, reservation,
intent and outcomes. The journal SHALL record:

- all uncertain intent IDs and their conservative effect-set digest;
- exact recovery operation/profile/plan/archive/Artifact/tool facts;
- fresh target/binding/topology proof and capability use;
- the coverage proof version and covered-effect digest;
- every actual typed recovery Step and semantic outcome;
- reboot/rebind/postflight facts and the resulting current-state epoch.

Only complete success writes a `SupersedingRecoveryEpoch` edge. That edge releases the target lane
for later admission and may give the original Job a truthful terminal disposition such as
`supersededByConfirmedRecovery`; it SHALL NOT change the original Step's `outcomeUnknown`, claim the
original operation succeeded or publish real-hardware success for that original Job.

If a recovery attempt itself becomes uncertain, Runtime recomputes the union of all old and new
uncertain effects. It may start another distinct recovery only if the same complete-coverage proof
still holds. Normal and recovery attempts share one hard budget: at most sixteen serial destructive
epochs in four hours with concurrency one.

## Existing durable history

A later real Flash already present in immutable Job/journal history MAY be recognized as a
SupersedingRecoveryEpoch without a new device dispatch only when the current implementation can
validate the same identity, ordering, full coverage, per-effect outcomes and postflight facts from
durable trusted records. Recognition appends a new audit relation; it does not rewrite either Job.
Missing facts, a different physical target, an incomplete partition universe or mere terminal
`succeeded` text is insufficient.

This rule permits deterministic repair of target lanes stranded by older Runtime versions while
preventing a generic “some later Flash succeeded” shortcut.

## No-question behavior

Normal Agent Flash, `safeToReflash` continuation and eligible complete-overwrite recovery SHALL
proceed without standing/campaign authority, chat confirmation, UI acknowledgement or an
`outcomeUnknown` human-decision prompt. The Runtime owns the classification and MUST NOT ask a user
to approve missing proof.

If physical identity is unknown, the uncertain-effect set is unbounded, coverage is incomplete,
the Provider has no approved recovery declaration, a trusted fact drifts, cancellation is pending
or the hard budget expires, dispatch remains zero. The product reports a non-overridable safety
blocker with the missing proof; a click or chat response cannot convert it into admission. Thus
human interaction is removed from every mechanically decidable path without converting human
approval into a substitute for device-state proof.

## Candidate and broker boundary

Recovery uses an already published operation/profile and Runtime-owned immutable Artifact facts.
Candidate and repairer still cannot access device transport, Runtime, capability administration or
change executable/argv, partitions, target, plan or recovery coverage. A new recovery operation,
Provider or profile, or any expansion of a published recovery domain, requires its own reviewed
Repo-plane change before Runtime can use it.

## Rejected interpretations

- **Replay the original unknown Step:** rejected; its outcome remains unknown forever.
- **Treat any later successful Job as supersession:** rejected; exact identity, ordering, coverage
  and postflight proof are mandatory.
- **Use a user confirmation as recovery proof:** rejected; a human cannot prove device bytes.
- **Ignore omitted partitions or userdata because the new archive boots:** rejected; boot success
  is not complete effect coverage.
- **Let callers declare `safeToSupersedeByCompleteOverwrite`:** rejected; only protected-main
  Runtime evaluates a reviewed Provider contract against fresh facts.
- **Remove all fail-closed stops:** rejected; truly unbounded or wrong-target uncertainty remains a
  hard zero-dispatch blocker.

## Risk accepted by approval

After r7 implementation, Runtime may intentionally issue a new destructive full-overwrite Flash
while the outcome of an earlier destructive write is unknown. The safety claim changes from “never
dispatch after unknown” to “never replay unknown; dispatch only a distinct, fully covering recovery
whose target, possible effects and final state are mechanically proven.” Maintainer approval of r7
explicitly accepts that additional destructive action in exchange for an autonomous, no-question
GJ-4 recovery loop.
