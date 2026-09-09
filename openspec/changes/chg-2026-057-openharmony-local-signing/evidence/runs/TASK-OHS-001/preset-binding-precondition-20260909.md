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

## The reference host

Still wedged at the time of writing, by the refused registration this record
describes. It is a persisted pending mutation, not damaged data: installing a
daemon carrying this change abandons the intent on first access and restores the
store. No file was hand-edited, no credential was installed, removed or entered,
and the mismatched credential binding itself is untouched.
