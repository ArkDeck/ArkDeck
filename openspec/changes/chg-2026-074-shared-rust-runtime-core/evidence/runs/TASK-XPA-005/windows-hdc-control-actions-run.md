# TASK-XPA-005 — HDC parity, part 2: the HDC control-action chain on Windows

Change: CHG-2026-074-shared-rust-runtime-core. This record covers part 2 (H2) of the Windows HDC
parity slice, which sits beneath the tuple gate (part 1, #2426). This part builds the HDC lifecycle
control-action chain on Windows and proves it in process against the recorded Swift oracles.
Nothing here composes an owner in the daemon: that is part 3, which also sits behind the gate.

Branch `agent/xpa-005-windows-hdc-control-actions-20260930`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS.

- No device was contacted, no HDC or board was used, and no `hdc` was run.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## What

| Where | What |
| --- | --- |
| `arkdeck-platform` `process.rs`, `windows/identity.rs` | `ToolLaunchIdentity` and `VerifiedTool::launch_identity` on Windows. This is Swift's `ProcessExecutableIdentityReceipt`, which a `launchWindowEntered` audit records. The fields are filled as follows: device = the 64-bit volume serial (`FileIdInfo`); inode = the NTFS file id (refused when it is wider than 64 bits, as on ReFS); mode = the file attributes; launch path = the authorized path. Windows has no launch by file id: the child is created from that path, and its image is proved to be the retained file while it is suspended. A unit test shows that the file id is the 64-bit file index the older query answers. |
| `arkdeck-provider-hdc` `lifecycle.rs`, `status.rs`, `dispatch.rs` | The lifecycle executor (`kill -r` / `kill`, one launch per preparation, then post-dispatch re-observation) and `runtime.hdc.status`'s observer now build on Windows. On Windows the identity family is the registered tuple (CHG-2026-078), observed only at the tuple's own endpoint; no macOS digest is a family there. A receipt's path is compared in its plain `X:\…` spelling. `SystemManagedProcess`, the kernel argv predicate, stays macOS-only: Windows has no supported read of another process's argv, so there `ManagedServer::verifies` proves the managed process by provenance and Job membership. `ProcessDispatch::tool_identity_current` builds on both platforms. `mutation_identity_current` is still never granted on Windows (part 4). |
| `arkdeck-hoststore` | These are now built on Windows: the union control-action owner, its approval, store and values; the HDC control-action owner with its lifecycle audit; the managed server's impact source; and the Job owner's HDC lifecycle interlock and current-Job census. They replace `absent_control_action.rs`. Tool selection's durable records build on Windows, but its owner stays macOS-only, because it reads the Bootstrap tool registry (`arkdeck_bootstrap::ToolRegistryStore`), which is not built on Windows. `absent_tool_selection_owner.rs` stands in for it, so `runtime.tool.select` is refused as macOS refuses it without an owner. |
| `hdc_control_lifecycle.rs` | A record's launch path is checked per platform (`launch_path`). macOS keeps `/.vol/<device>/<inode>` byte for byte. On Windows the launch path must be the authorized executable. |

## Proof (in process, against the recorded oracles)

- `arkdeck-provider-hdc/tests/windows_hdc_status.rs`: the Swift `HDCStatusOracleContractTests`
  oracle (`rust/tests/fixtures/hdc-status`, 22 cases) is answered byte for byte. The oracle's root
  path is read as a fresh Windows root, as a label in both the cases and the recorded answers. The
  tool is the same driver bytes. Swift's `chmod` disturbance becomes a last-write-time move
  through an attributes-only handle, and cases 16 and 17 answer as Swift's did. The driver is a
  POSIX script that Authenticode cannot read, so the replay's signature member comes from a seam
  that answers the oracle's unsigned object. The production `NativeSignature` answers that exact
  object for an unsigned Windows image (the test binary). No macOS digest has a Windows family,
  and the production observation is `Unsupported` before any scan.
- `arkdeck-hoststore/tests/control_action_approval.rs` now runs on Windows too, over the owner-only
  store and the agent-human-action oracle's execution.
- The hoststore unit suites now also run on Windows: `hdc_control_action_tests` (Swift
  `HDCControlActionContractTests`' owner cases, including the lifecycle audit chain with the
  Windows launch path and its tampered-path refusal), `hdc_impact_source_tests`,
  `tool_selection_tests` (including `rust_written_records_are_the_checked_in_ones`, the checked-in
  tool-selection store) and the `status.rs` unit tests.

## Left out, and why

- **Restart through the runner on Windows (H2b)**. The tool runner puts the client in a
  kill-on-close Job with no breakaway, so a server the `kill -r` client starts is ended with the
  client's Job. A Windows restart would therefore end `outcomeUnknown` (no strictly newer
  generation), which fails closed. How Windows `hdc.exe` starts its server is `TBD(sample)` in
  CHG-2026-078. The lead is asked whether to add a lifecycle-only Job that allows silent
  breakaway.
- **Tool selection's owner on Windows**: it needs the Bootstrap tool registry on Windows.
- **Composition in the daemon**: part 3.

## Delegated minor decisions, pending the next rulings batch

1. On Windows the lifecycle audit's `inodeLaunchPath` is the authorized executable path, and the
   record validator checks exactly that. macOS keeps its `/.vol` rule and bytes.
2. On Windows the launch identity's device is the 64-bit volume serial from `FileIdInfo`, not the
   older 32-bit one. Its inode is the 64-bit NTFS file id, and a wider id refuses the launch
   identity. Its mode is the file attributes.
3. On Windows the Swift status oracle's `chmod` disturbance is a last-write-time move, the metadata
   change Windows' retained-tool check reads.

## Gates

See the PR description for this commit's gate output.
