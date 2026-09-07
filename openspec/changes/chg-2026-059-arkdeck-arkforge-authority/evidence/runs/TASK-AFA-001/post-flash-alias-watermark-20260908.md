# What actually blocks GJ-4, and two defects found on the way — 2026-09-08

Design record only. No product code changes in this PR; `openspec/**`-only PRs
carry no Task declaration. The code changes it recommends are staged at the end
and each names the Task it will be filed under.

## The GJ-4 blocker is not a defect in the flash path

The 2026-09-07 real-flash attempt ended with:

```
lane postflight did not verify: verified post-flash HDC binding could not be persisted:
  productionConfigurationUnavailable("post-flash binding changed before verified alias publication")
```

That message comes from `RockchipPostFlashHDCBinding.swift:141`. Measured on
this host:

| document | mtime | value |
| --- | --- | --- |
| `ArkDeck/rockchip-post-flash-hdc-binding.json` | 2026-09-02 | `bindingRevision: 4`, `jobID: job-8fb446e7…`, `establishedAtUTC: 2026-09-02T07:00:39Z` |
| `ArkDeck/rockchip-binding.json` | 2026-09-07 | `revision: 2`, Loader serial `1160102311220451` |
| failed Job's journal `stepIntent` | 2026-09-07 | `bindingRevision: 2` |

So `existing.bindingRevision = 4`, `candidate.bindingRevision = 2`. `4 < 2` is
false, so control skips the supersede branch at :122 and falls into the
else-branch, where `4 == 2` is false, and it throws. **The candidate is older
than the store's high-water mark.** The guard is doing its job: an older Job
must not rotate a newer route.

The revision went backwards because of an operator action the product itself
offers. On 2026-09-07 the daemon state directory was retired by renaming
`Agentd/` aside and letting a fresh one be created. Both Rockchip binding
stores live one level **up**, directly in `ArkDeck/` — see
`ArkDeckAgentDaemonMain/main.swift:492`,
`let rockchipRoot = resolvedStateDirectory.deletingLastPathComponent()`. The
target store that issues binding revisions lives *inside* `Agentd/`, so it
restarted at 1 and reached 2, while the post-flash store kept its watermark of
4. Independently confirmed: `Agentd/targets/targets.json` holds
`TGT-958780b2ffb7` at revision 2 (adopted 2026-09-07T02:20:01Z), and
`Agentd.retired-20260907T021356Z/targets/targets.json` holds the same target at
revision 4.

Until the live revision climbs above 4 or the two stores are reconciled, this
host cannot complete a flash.

**Updated after rebasing onto #1766.** This record originally said the failure
arrives only *after* the destructive writes, because admission did not check the
stored alias revision. That is no longer true. #1766 (TASK-AIN-021, landed
2026-09-08) added the check to the admission/facts path in
`DeviceProviders/RockchipRuntimeComposition.swift:118-122`:

```swift
guard routed.bindingRevision <= target.bindingRevision else {
  throw DeviceProviderError.factsUnavailable(
    "flash.postFlashHDCBindingConflict: stored alias revision "
      + "\(routed.bindingRevision) is newer than target revision \(target.bindingRevision)")
}
```

Its comment states the reasoning this record reached independently: a route that
cannot cover the target "must not silently fall back to the older binding alias:
that would admit every partition write before predictably failing at the final
alias publication." On this host the refusal now reads *stored alias revision 4
is newer than target revision 2* — the two values named, before anything is
written.

That corroborates the diagnosis below and removes the destructive-write cost,
but it does not unblock GJ-4: the host now fails earlier, not less. Reconciling
the two stores remains the only route, and remains a maintainer decision.

**Nothing may be deleted to fix it.** POL-RECOVERY-001 / POL-SAFETY-001 and
design.md §4 forbid erasing undecided durable state and forbid removing pending
state by swapping directories or falling back to defaults.

## Defect 1 — the refusal describes a race that did not happen

One sentence covers four unrelated disagreements: a different target, a
candidate whose revision is *below* the store, a Loader-identity mismatch, and
the genuine mid-flight alias change. Only the last is a change "before verified
alias publication". The measured failure is the second, and the message sent
this investigation looking for a concurrency window that does not exist.

This is the family already fixed on the evidence surfaces in #1760–#1764: a
refusal that cannot say which invariant failed leaves the real reason reachable
only by reading durable files by hand.

## Defect 2 — `archiveSuperseded` silently archives nothing on a name collision

`RockchipPostFlashHDCBinding.swift:184-205` derives the archive name from the
existing record's `establishedAtUTC` alone:

```swift
let name = "post-flash-superseded-\(stamp.isEmpty ? "unknown" : stamp).json"
let descriptor = Darwin.openat(rootDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | …)
if descriptor < 0 {
  if errno == EEXIST { return }        // ← returns success, having written nothing
  throw failure("superseded post-flash binding archive cannot be created")
}
```

On `EEXIST` it returns success without writing, and the caller then overwrites
the live record. If the name is already occupied by a *different* record, the
superseded record is gone. The comment at :123-134 promises the entry is
"archived beside the store, never silently discarded"; on that path it is
discarded. This host already carries a `post-flash-superseded-20260814T080951Z.json`
(revision 3, a different Loader identity), so the collision space is not
hypothetical — it is one timestamp collision wide.

## Defect 3 — the chain guard is tautological at its only production call site

`RockchipPostFlashHDCBinding.swift:96-98`:

```swift
guard Self.isSHA256(expectedPreviousHDCIdentitySHA256),
  candidate.previousHDCIdentitySHA256 == expectedPreviousHDCIdentitySHA256
else { throw failure("post-flash binding previous alias is invalid") }
```

There is exactly one production caller,
`DeviceProviders/RockchipRuntimeActionHost.swift:718-731`, and it passes
**`expectation.previousIdentitySHA256` to both operands** — once as the
candidate's `previousHDCIdentitySHA256` field, once as the
`expectedPreviousHDCIdentitySHA256` argument. The comparison can only ever be
true in production; it verifies nothing beyond well-formedness.

The doc comment at :90 says this is what stops "a stale Job [rotating] a newer
route". It is not. What actually delivers that property is the **fourth**
conjunct of the else-branch, `existing.hdcIdentitySHA256 == expectedPreviousHDCIdentitySHA256`,
which compares the store's own value against the caller's. The guard at :96-98
should not be read as a second line of defence, because it is not one.

## Design decision

Three approaches were designed independently and judged on safety, operator
recovery, and blast radius. All three were rejected as proposed:

- **Re-key the alias ordering off `bindingRevision`** (the most attractive on
  footprint — zero new published surfaces) is **disqualified on safety**. It
  replaces the monotonic comparator with a `covers`-against-the-live-target
  test, and cannot distinguish "different lineage" from "same lineage, rolled
  back". Because `advanceBindingLineage` (`DeviceBootstrap.swift:774-782`)
  keeps the live revision strictly monotonic within one store, its
  archive-and-publish arm fires precisely in the state this host is in — and
  would auto-archive the newer record in favour of the older Job. That is the
  one property that must not be surrendered.
- **Tie the two stores' lineage together** is right about the underlying
  invariant but needs two durable schema changes and a write to an existing
  durable record at daemon startup, landing on top of the in-flight single-v1
  work, and it cannot fit one Task.
- **Add a CLI reconciliation leaf** cannot land as scoped: a new leaf forces
  edits to `openspec/contracts/cli-command-registry.yaml` and
  `cli-feature-coverage.json`, and `openspec/contracts/**` is in TASK-AIN-021's
  Forbidden paths.

What survives judging from all three is the half that changes no behaviour.

## Staged plan

1. **Name the disagreement at the postflight surface too** (TASK-AFA-001 —
   declares `Packages/ArkDeckKit/Sources/ArkDeckWorkflows/Rockchip*.swift`).
   #1766 did this for *admission*; the *publisher* is untouched. Replace the
   single string at :141 with one that walks the same four conjuncts in the
   same order and reports the one that failed, with both values. No conjunct,
   no ordering, and no thrown case changes; the original wording survives on
   the branch where it is true. This still matters after #1766: admission
   compares the stored alias against the live target, while the publisher
   compares it against the Job's own candidate, so a disagreement that opens
   mid-flight still lands on :141 and still reports a race as its only
   explanation.
2. **Make the archive actually archive** (same Task). A collision must not
   resolve to silent success: either include a discriminator beyond the
   timestamp, or verify the existing archive is byte-identical before treating
   `EEXIST` as done, and refuse otherwise.
3. **Retire the tautological guard or give it a real second operand** (same
   Task), and correct the doc comment that credits it with a property it does
   not provide.
4. **Then, and only then**, decide the reconciliation route with the maintainer.
   It is the only step that can change what the guard accepts, and the only one
   that touches the operator's durable state. It should not ride along with the
   three above.

All three defects were re-verified verbatim against the tree after rebasing onto
#1766: `:141`, `:197`, and `:96-98` are unchanged, and
`RockchipRuntimeActionHost.swift:723,731` still pass
`expectation.previousIdentitySHA256` to both operands.
`RockchipPostFlashHDCBinding.swift` was last modified by #1379.

Steps 1–3 are behaviour-preserving on the accept/refuse decision and each is
independently testable with a negative control. Step 4 is a maintainer
decision, not an implementation detail: this host cannot run GJ-4 until it is
made, and the honest options are to reconcile the two stores deliberately or to
advance the live binding lineage past the stored watermark.
