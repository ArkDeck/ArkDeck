# TASK-XPA-010 — the Flash recovery broker and the post-flash alias reconciler on Windows

Change: CHG-2026-074-shared-rust-runtime-core. Windows phase, slice G2, GJ-4 leftovers, part 1.
Stacked on #2504 (`windows-flash-job-run.md`, branch `agent/xpa-010-windows-flash-lane-20261004`).
Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device was contacted, no `hdc`
and no `arkforged` ran, and nothing was flashed. Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `arkdeck-agentd` `Host` | The Flash invocation owner (`with_flash_invocations`) and the post-flash alias reconciler (`with_flash_alias_reconciler`) build on Windows, with `debug.status`, `debug.start`, `debug.evaluate`, `recovery.flash-invocation.list` and `flash.reconcile-alias` answered through them, and the broker's attempt driver (`debug_attempt`): admitted through the Flash admission over the Windows Job planner, run as `job.run` runs it, classified by the Job. |
| `windows_lifecycle::Authority::compose` | Composes the Flash invocation owner over the state directory the Windows planner plans in (the root), creating its directories at the start, as both macOS compositions do; it is opened by the state directory's canonical plain spelling (`StateRoot::private_child`), since its private-directory check refuses a short (8.3) spelling of the root, which the account-locations process test's short-name profile gives; and, beside the lane, the post-flash alias reconciler over the Application Support root (the development root, or the account root's parent) and the Windows USB census, as the Flash facts read it. |
| The census | `flashAliasReconciler` and `flashInvocations` at their macOS positions (after `codeSignHelper`, before `flashHostFacts`); every Windows process test's census line updated. |
| `src/flash_host_reads_control.rs` | Builds on Windows: the Swift flash-host-reads oracle's 61 exchanges replay through the Windows Host and Control, byte for byte, with every file the reconciler leaves. Owner-only modes are the private DACL; a shared mode (0644, 0755) is a read entry for the local Users group, removed again when the oracle restores 0700; the oracle's link to `/etc/hosts` is a file symbolic link to the Windows hosts file. Each entry's kind and size are compared, not its mode. |
| `tests/spawning/flash_broker_control.rs` | Builds on Windows: `debug.start` pins the oracle's canonical full restore and `debug.evaluate` executes it through the Flash admission and runner, to `succeeded`, and an unknown outcome is settled without replay. |
| `tests/spawning/flash_socket_control.rs` | A recovery case on both hosts, through the real CLI against the signed test daemon: `recovery flash-invocation start`, `evaluate` (the pinned execute action), `status` and `list` (the unknown case uses the `debug start|evaluate|status` spellings), the Job succeeded or left unknown and never replayed; then `flash reconcile-alias`, which reaches the composed reconciler and is refused as Swift's is for an alias that is no reissued lineage of the attached board. |

## Coverage

`recovery.flash-invocation.start|evaluate|status|list` and `debug.start|evaluate|status` join
`WINDOWS_MEASURED_LEAVES`; `cli-feature-coverage.json` regenerated with `arkdeck maintainer
contracts export`: against #2504, Windows implemented 98 -> 102 (`debug.start`, `debug.evaluate`,
`debug.status`, `recovery.flash-invocation.list`), partial 59 -> 55. The maintainer-contracts
`oracle.json` is left as it is (the lead's decision of 2026-10-04: a historical recording whose
coverage pins the replay never checks). `flash.reconcile-alias` is not counted: the CLI reaches the composed reconciler but no
fake lineage exercises a repair there; its repairs replay through the Windows Host
(`flash_host_reads_control.rs`).

## Left out

- `flash.device-access` and `flash.lanePlanPreview` through the CLI: the next layer (a test-only
  fake of ArkForge's public pipe and of the plan previewer on the signed test daemon).
- `flash bind-loader` through the CLI: it replays through the Windows Host
  (`loader_binding_control.rs`).

## Local checks

See the commit message.
