# TASK-XPA-005 — HDC parity, part 3: the managed HDC owner on the Windows daemon, behind the tuple gate

Change: CHG-2026-074-shared-rust-runtime-core. This record covers part 3 (H3) of the Windows HDC
parity slice, after parts 2 (#2439) and 2b (the lifecycle-only breakaway).

Branch `agent/xpa-005-windows-managed-hdc-owner-20261004`, one commit on `origin/main`.

Host: the Windows 11 x64 reference host, non-elevated, NTFS. The limits of this run:

- No device was contacted, no HDC or board was used, and no `hdc` was run. The only HDC-shaped
  process is a stand-in compiled from Rust at test time.
- Nothing installed was read or written.
- No system setting was changed.
- Host tests are not Windows acceptance.

## Why

The macOS isolated owner starts its development HDC as its own managed server
(`managed_hdc::ManagedHdc`, Swift `HeadlessHDCServerHost`): the server's dispatch registers the HDC
provider, its status answers `runtime.hdc.status`, its startup facts the tool leg of
`target.availability`, and the daemon stops it after its drain. On Windows the owner did not build,
and a development root refused an admitted HDC outright ("its managed server is not composed").

The Windows HDC tuple (CHG-2026-078) is still a draft with `TBD(sample)`, so
`WINDOWS_HDC_TUPLES` is empty. This part builds everything up to that gate and leaves the gate as it
is: no bypass, no macOS authority reused for identity or trust.

## What

| Where | What |
| --- | --- |
| `arkdeck-agentd` `managed_hdc.rs`, `managed_hdc_lifecycle.rs` | Built on Windows. The tool-selection restart (`ToolSelectionDriver`) stays macOS-only, as the Bootstrap tool-selection owner does. `runtime.hdc.status`'s process verification is the macOS kernel argv read there, and provenance on Windows: the receipt must name the very child the running server launched (`ManagedHdcServer::verifies`, over `ManagedServer::verifies`). A replacement a confirmed restart proved is no child of it, so the Windows status never calls it managed. |
| `arkdeck-provider-hdc` `managed_server.rs` | `ManagedHdcServer::verifies` (Windows only). |
| `arkdeck-agentd` `windows_hdc_gate.rs` | The admitted HDC now carries its endpoint selection: Swift's selector over the inherited `OHOS_HDC_SERVER_PORT`, which must pick the tuple's endpoint. A tuple off the default endpoint needs the port named. |
| `arkdeck-agentd` `windows_lifecycle.rs` | The gate's admitted HDC is kept in the root's authority instead of refused. `Authority::compose` starts it as the managed server after every store is open (`launch_managed`: both tools pinned to the admitted digest first; the dispatch names the managed server's port), watches its foreground exit, registers it (`with_managed_development_hdc`), reads the Runtime's own USB census beside it (`relation_source(true, true, false)`), and passes its digest to the ArkForge lane as the managed-control HDC, as macOS does. Without one, it reports `composes no HDC` as before. |
| `arkdeck-agentd` `main.rs` | The Windows daemon stops the managed server after its drain and the ArkForge lane, and before releasing the root, so a successor never meets it on the endpoint; it exits 70 when the owner must be recomposed, as on macOS. |
| `arkdeck-agentd` `host.rs` | The `hdc` member, `with_managed_development_hdc`, `managed_hdc`, `runtime_hdc_status`, `managed_hdc_tool`, the doctor's managed branch, `hdc_dispatch`, `flash_hdc` and `rockchip_hdc_resolver` are the macOS code on Windows (their Windows stand-ins returned what the macOS code returns without an HDC). The Windows owner census names `hdc` and `managedHdc` at their macOS positions. |

Behaviour change on Windows: `runtime.hdc.status` used to be refused as the read-only foundation's
(`rejected`); it now answers as Swift's daemon answers without an HDC host
(`unconfigured_status`, `hdc.notConfigured`), on a development root, the account's daemon and the
private-endpoint foundation alike, as on macOS. The contract-parity read-only check
(`rust/scripts/check-readonly.py`) now expects that answer on Windows as it does on macOS. Every other answer is unchanged while no tuple is
registered. macOS behaviour is unchanged: `cfg` attributes, comments, and the status verifier
bound to a local.

## Proof

- `arkdeck-agentd/tests/windows_hdc_gate_process.rs` (existing): a development root naming a
  stand-in as its managed server is refused before the root is opened, naming the digest the
  registry would have to hold; nothing is created or launched.
- `arkdeck-agentd/tests/windows_lifecycle_process.rs`,
  `a_development_root_without_a_registered_hdc_composes_no_managed_server`: the real daemon over a
  development root reports `composes no HDC`, its owner census names no `hdc` or `managedHdc`,
  `runtime.hdc.status` answers exactly `unconfigured_status(None)`, and its stop exits 0.
- `windows_lifecycle::tests::an_admitted_hdc_is_composed_as_the_managed_server_and_stopped`: the
  composed path, with a tuple table naming a stand-in's digest injected as the gate's own tests
  inject one (the real registry refuses the same stand-in first). The stand-in is started on the
  tuple's endpoint, proved to be this launch, registered with its tool facts
  (`3.2.0d`/`inheritedEnvironment`), named by the census, and ended by the daemon's stop, after
  which the endpoint is free. Its `runtime.hdc.status` fails closed: the commandless identity family
  is the provider's own registry's, which the injected table does not reach, so the listener is not
  observed and the server is not called managed (`hdc.identityFamilyUnavailable`).
- `windows_hdc_gate::tests`: the endpoint selection (default, inherited, a mismatched or invalid
  port, a tuple off the default endpoint).

## Left out

- The HDC control-action owner (`runtime.hdc.impact-preview`, `runtime.hdc.restart`) on the Windows
  daemon: its composition beside the managed server and the union control-action owner. It is the
  next part.
- Tool selection's restart: the Bootstrap tool-selection owner is macOS-only.
- The Job planner, admitter and runner over this HDC (`job.plan`, `job.submit`, `job.run`, agent
  executions, operation availability) keep their Windows stand-ins without an HDC provider. They
  answer as before while no tuple is registered.
- The account's daemon composes no HDC: on macOS its HDC is the Bootstrap tool registry's selection,
  which is macOS-only.
- `runtime hdc status` is not added to `WINDOWS_MEASURED_LEAVES`: without a registered tuple its
  only answer is the unconfigured status, and nothing of an HDC is measured end to end.

## Delegated minor decisions, pending the next rulings batch

1. **Provenance verification.** On Windows `runtime.hdc.status` verifies the observed process as
   the running server's own child (`ManagedServer::verifies`), where macOS reads the process's argv.
   A restart's replacement is therefore never called managed there.
2. **Endpoint.** The managed server starts on Swift's selection, which must be the registered
   tuple's endpoint; otherwise the start is refused before the root is opened.

## Gates

The PR description gives this commit's gate output.
