# Preset binding precondition and pending-acquire rollback — 2026-09-09

An implementation record for `TASK-OHS-001`. It follows #1802 and repairs a
defect that change reached.

## What #1802 got right, and what it broke

#1802 made registration refuse a signing preset whose credential is bound to a
different project. Verified on the published Runtime (protected `main`
`0483acf2`, daemon `a20a631b…`): the host's existing preset now reports
`unresolved` instead of `runtimeRestartRequired`, its three healthy siblings stay
`active`, and registering the mismatched binding is refused, exit 65:

```
resourceConflict: signing credential credential:sha256-562430f169… is bound to
project demo-app, not project-fd677365f7bdefabda66a3c1
```

That refusal was raised in the wrong place. `registerPreset` persists a pending
dependency mutation and then performs it, and `withDocument` reconciles whatever
it finds pending on **every** access — reads included. A refusal raised inside
that transaction therefore does not refuse one registration; it refuses every
later read of the store.

Observed immediately after that refusal on the host: `workspace project list` and
`workspace preset list` both answered `resourceConflict` with the registration's
message, `newDispatchCount: 0`, phase `workspacePresetOwner`. `operation list`
still answered 27 of 30 available because operation availability was composed at
start-up, before the wedge; `doctor` answered `overall: degraded`, `ready: true`.

## What changed

- `RuntimeWorkspaceCredentialPinning` gains `validateBinding(credentialRef,
  projectRef)`. `registerPreset` and `updatePreset` call it through a new
  `requirePresetDependencies` **before** writing the pending mutation, so a
  binding that can never match costs the caller an error and leaves the document
  untouched. The daemon's owner performs the same comparison start-up makes, so
  the two cannot disagree, and `acquire` still repeats it at the moment it pins.
- A pending `acquire` that cannot complete is now abandoned: the intent is
  cleared and saved, then the failure propagates. The preset is only added after
  both pins succeed, so dropping the intent restores exactly the pre-registration
  state. The two-phase write still covers the crash window it exists for; what it
  no longer does is replay an impossible acquire on every read.

## Checks

- A refused registration leaves the store readable: `listPresets` and `list`
  answer on the same handle and on a freshly opened one, and nothing was pinned
  (`acquireCount == 0`), because the binding is a precondition.
- An acquire that fails *after* the intent is durable — the window the two-phase
  write exists for — is attempted exactly once, the store stays readable, and a
  later read does not attempt it again.
- Negative control: with the rollback reverted, the second test fails and
  reproduces the host symptom exactly — the registration throws, and the
  following `listPresets` and the reopened store throw as well.
- 267 tests across the workspace store, daemon, workspace and signing suites
  pass.

## Verified on the published Runtime

Built from clean protected `main` `f5594bbc5e2c851103b2abfcc4c5aeb444422eb2`
(#1803), CLI `98ce528869f65bb1209545b1f4085bd004990d267155a70d2d6f097a123814ad`,
daemon `18b3dd7a664b814dc369730235bb1707e690a3fa5aebb948cbc681a65eb96db5`,
installed `2026-09-09T03:23:51Z` with `runtime service update --daemon`, exit 0.

**The wedge cleared on its own.** The store had been refusing every read since the
2026-09-09 refused registration. On the first access after this daemon started,
`workspace project list` and `workspace preset list` both answer, exit 0:

| Preset | Status |
| --- | --- |
| signing `preset-23114ce6017f4fbdd8930bcc` | `unresolved` |
| build `preset-9cc94c378346e500cb0a0b4a` | `active` |
| test `preset-a5cc1aa79368c99ea5e9a590` | `active` |
| symbol `preset-cbeb3954de5b7119e638ddbc` | `active` |

No file was hand-edited to achieve this; the abandoned intent was dropped by the
product on first access, which is the repair this change makes.

**The refusal no longer wedges.** Registering the same mismatched binding again
is refused, exit 65:

```
resourceConflict: signing credential credential:sha256-562430f169… is bound to
project demo-app, not project-fd677365f7bdefabda66a3c1
```

and `workspace project list` and `workspace preset list` both answer immediately
afterwards, exit 0, with the four presets unchanged. That is the whole defect,
closed on the real product: the operator gets the diagnosis and keeps the store.

**Nothing else moved.** `job list` returns the same 21 Jobs with the same
outcomes as before the first install of this window, across all five daemon
installs; `operation list` is 27 of 30 available with the same three
(`flash.dayu200`, `flash.full-restore@1`, `workspace.sign-openharmony-hap@1`);
and `session export apply` still completes with the same exported manifest
`cac181bfea901bf7045e981ccbcbb23f331afdd2174b25ed73c40526fc46f037` and the same
`projectRef = redacted-device-aa46c4f072672f57dee812c2`.

No credential was installed, removed, migrated or entered, and the mismatched
credential binding itself is untouched. `workspace.sign-openharmony-hap@1` stays
`unavailable`: the preset is now honestly `unresolved`, and rebinding the
credential remains a maintainer action.
