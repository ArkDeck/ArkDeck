# r12 Design — Invariant-bounded candidate debugging

## Product defect

r10 made one debug invocation durable, but its candidate boundary was a list of known repair
choices: published alternatives, named observations and four timing parameters. That list encoded
the failures already seen during DAYU200 bring-up. A new pre-effect failure had no legal candidate
representation, so Runtime returned `repairSurfaceInsufficient` and forced another merge before the
Agent could continue. The PR therefore remained a per-problem synchronization primitive.

The mistake was the boundary itself. ArkDeck must constrain external effects, not predict future
bug categories.

## Selected boundary

r12 separates the loop into two planes:

```text
arbitrary isolated candidate revision
  -> observePinnedRequest | executePinnedRequest | stop
  -> protected-main typed-effect broker
  -> Catalog lookup + full plan materialization
  -> fresh target/binding/tool/Artifact facts
  -> RuntimeCapability + reservation + intent-before-effect
  -> typed Provider dispatch + durable outcome/recovery proof
```

The candidate action grammar is intentionally stable and problem-independent:

- `observePinnedRequest` returns a fresh, dispatch-free plan observation;
- `executePinnedRequest` asks protected Runtime to re-materialize and execute the exact seed;
- `stop` ends the invocation with one bounded diagnostic reason.

The action cannot carry an operation, version, target, binding, inputs, Artifact, plan, Step,
effect, timing, alternative, executable, argv, capability, trusted fact, outcome or recovery proof.
Candidate source/build digests are durable provenance only and satisfy no admission predicate.

The seed may name any operation already published in the protected-main Catalog. Runtime first
performs its normal plan-only materialization and pins operation, target, binding, inputs and
outputs for the invocation. A device-effect seed must be binding-pinned. A candidate cannot change
the seed; changing operation/provider/profile or destructive policy remains a normal reviewed
Repo-plane change.

## Continuation is derived from effects

Continuation never depends on a failure name:

1. Refusal before Job admission has no Job and consumes no effect epoch.
2. A failed Job whose durable journal contains no `deviceMutation` or `destructive` intent is
   `safeToReflash`: typed-only execution plus intent-before-effect prove device dispatch was zero.
3. A Job with device-effect intent may continue ordinarily only from RuntimeCapability lineage
   `safeToReflash`.
4. `outcomeUnknown` is never replayed. A later `executePinnedRequest` reaches only protected
   Runtime, which may create a distinct complete-overwrite recovery Job solely after the existing
   exact coverage proof. Missing proof produces zero new device dispatch.
5. Known post-effect failure, cancellation, expiry, the sixteenth epoch, identity/fact drift or an
   unmaterializable seed stops the invocation without an override.

Fresh observations cannot hide an earlier destructive predecessor: the controller always checks
the latest effect epoch, not simply the latest evaluation row.

## Protected kernel

The protected kernel is defined by responsibility, not by a catalog of bugs. It owns Catalog
resolution, plan materialization, Provider lowering, device transport, target/binding facts,
Artifact leases, RuntimeCapability, reservation, journal, outcome classification and
complete-overwrite proof. Candidate code never replaces or administers those responsibilities.

Everything outside that kernel may evolve between candidate source/build revisions without an
intermediate PR. The final successful revision is promoted once. If a repair truly changes a
protected responsibility, adds a published operation/provider/profile, or changes destructive
admission policy, that final change still requires maintainer review before hardware use.

## Compatibility

r10 invocation and attempt documents selected repair tuning and cannot be reinterpreted as r12
effect actions. r12 writes invocation schema `2.0.0` and attempt-permit schema `2.0.0`; an old
active invocation fails closed and must be restarted from its original unprivileged typed seed.
Existing Jobs, capabilities, journals and outcomes are not rewritten.

## Verification

- Decode only the three effect-level actions and reject duplicate/unknown/authority-bearing keys.
- Start invocations for multiple already-published typed operations without an operation-specific
  debug allowlist.
- Run two candidate source/build revisions through one pinned request after `safeToReflash` and
  reach success without a Task/PR/merge field.
- Prove a novel known failure with no device-effect intent is retryable because of journal facts,
  not its diagnostic string.
- Keep exact request pins, four-hour/sixteen-epoch/concurrency-one budgets and all unknown-outcome
  recovery rules unchanged.
