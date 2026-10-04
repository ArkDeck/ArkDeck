# TASK-XPA-005 — HDC parity, part 4: the HDC control-action owner on the Windows daemon

Change: CHG-2026-074-shared-rust-runtime-core. This record covers part 4 (H4) of the Windows HDC
parity slice, on top of part 3 (the managed HDC owner behind the tuple gate,
`windows-managed-hdc-owner-run.md`). Part 2's chain is in `windows-hdc-control-actions-run.md`.

Branch `agent/xpa-005-windows-hdc-control-actions-20261004`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Why

Both macOS compositions compose Swift's union control-action owner in `control-action-snapshots`,
over the HDC control-action owner (`hdc-control-actions`) beside their managed HDC server:
`runtime.hdc.impact-preview` requests an impact approval, `human-action.show|list` read it, and a
foreground-console `human-action.resume` consumes it and runs the confirmed restart through the
managed server's lifecycle driver. On Windows those methods kept the read-only foundation's
refusal. The hoststore owners and the lifecycle chain already build on Windows (#2439); part 3
composed the managed server behind the tuple gate.

## What

| Where | What |
| --- | --- |
| `arkdeck-agentd` `windows_lifecycle.rs` | `Authority::control_actions`: the union owner in `control-action-snapshots` on every root (a development root and the account's daemon, the name both macOS compositions give it), over the HDC control-action owner in `hdc-control-actions` only when the tuple gate admitted an HDC. Both directories are created before the managed server is launched. A development root's Session isolation then also covers `hdc-control-actions`, as on macOS. |
| `arkdeck-agentd` `host.rs` | `with_control_actions`, `with_hdc_impact` (the managed server's impact source), `control_action` and `interactive_human_action_resume` are the macOS code on Windows. The Windows `agent_execution` first resolves a control action's impact approval through the combined human-action owner, as the macOS one does. The Windows census names `controlActions` at its macOS position. |
| `arkdeck-agentd` `managed_hdc.rs` | `ManagedHdc::process_verifier`: the kernel argv read on macOS, the launch's provenance on Windows; `runtime.hdc.status` and the impact source both use it. |

On Windows a confirmed restart is consumed with the HDC lifecycle driver alone: no tool-selection
owner is composed (the Bootstrap selection is macOS-only).

Behaviour on Windows while no tuple is registered:

- `runtime.hdc.impact-preview` and `runtime.hdc.restart` answer `operationUnavailable` ("the
  Runtime HDC control-action owner is unavailable", zero dispatch) instead of the foundation's
  `rejected`.
- `control-action.list` pages an empty snapshot; `.show` and `.reconcile` answer
  `resourceNotFound`.
- `runtime.tool.select` is unchanged (`operationUnavailable`).
- Every daemon's owner census names `controlActions`.
- The rootless private-endpoint daemon composes no control-action owner and answers as the macOS
  standalone daemon does (`operationUnavailable`; `invalidInput` for `.show` and `.reconcile`
  without an identity); `rust/scripts/check-readonly.py` now expects that on Windows too.

macOS behaviour is unchanged.

## Proof

- `arkdeck-agentd/tests/windows_lifecycle_process.rs`,
  `a_development_root_answers_control_actions_without_a_managed_hdc_server`: the macOS
  `control_action_process.rs` no-host case on the real Windows daemon. The impact preview and the
  restart are refused with zero dispatch, an unknown action does not exist, the empty listing is a
  stored snapshot page that a restarted daemon reads back through its token, and no
  `hdc-control-actions` exists.
- The owner census of every Windows process test now includes `controlActions`.

## Left out

- A confirmed restart end to end on Windows (impact preview, approval, console challenge, restart,
  proved replacement). It needs a managed server, which only a registered Windows HDC tuple admits.
  The provider reads the commandless identity family from the same (empty) registry, so even an
  injected-tuple stand-in is never observed as managed, and its impact preview fails closed. It
  waits for CHG-2026-078's samples.
- Tool selection's restart (macOS-only owner).

## Delegated minor decisions, pending the next rulings batch

1. **Union owner on every Windows root.** As both macOS compositions do, the account's daemon and a
   development root compose the union control-action owner even without an HDC, so the
   control-action methods answer as Swift's daemon answers without an HDC host rather than with the
   foundation's refusal.

## Gates

The PR description gives this commit's gate output.
