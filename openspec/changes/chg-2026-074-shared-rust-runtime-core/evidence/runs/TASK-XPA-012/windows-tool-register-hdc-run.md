# TASK-XPA-012 — `runtime tool register --kind hdc` end to end on Windows

Change: CHG-2026-074-shared-rust-runtime-core. GJ-1. Second layer of P2's stack, on
`agent/xpa-005-windows-diag-session-20261005`. It measures `runtime tool register` through the real
signed CLI and the signed account daemon (`agentd/tests/spawning/account_tool_selection.rs`).

Host: the Windows 11 x64 reference host, non-elevated, NTFS. No device, HDC or board was used, no
`hdc` was run, nothing installed was read or written, and host tests are not Windows acceptance.

## Found and fixed (Windows)

The account daemon admitted an HDC by two different tuple tables:

- its selection, managed server and tool-selection owner read the Bootstrap registry through the
  composition's own table (`Authority::tuples`, `windows_lifecycle::tool_registry`);
- the Bootstrap registry owner behind `runtime.tool.register`, `list`, `inspect` and `remove`
  (`BootstrapReaders`) always read the provider's table (`windows_hdc_identity`).

In production both are `WINDOWS_HDC_TUPLES`, so nothing changes there. But the registration owner
was not tied to the composition, so a test build's fixture tuple could be selected yet never
registered. Now the Windows composition opens the registration owner with its own table
(`Host::with_identified_bootstrap`, `BootstrapReaders::open_existing_identified`), so
registration admits exactly the digests that selection admits. No gate is relaxed. A digest that
no tuple names is still refused before anything is retained, and macOS is unchanged.

## What

The test daemon admits two stand-in `hdc.exe` digests through fixture tuples
(`Authority::with_tuples`, test only); the stand-ins are compiled per test with distinct bytes.
After the existing drifted-selection checks:

- **Register.** `runtime tool register --kind hdc --file <second stand-in>` succeeds. The row has
  the macOS Runtime's key set, and its `trust` has the macOS key set too
  (`ControlFrames/runtime.tool.register.jsonl`). Values: `kind` `hdc`, `platform` `windows`,
  `state` `available`, `generation` `1`, `source` `registeredCopy`, the stand-in's digest,
  `contentRetained`, `registeredIdentity`, `toolVersion` `3.2.0d`, and `selected` false.
- **Idempotent.** Registering it again answers the same row.
- **Listed.** `runtime tool list` shows both tools, and the selection is unchanged.
- **Refused.** An `hdc.exe` that no tuple names is refused (`admissionDenied`), and the listing is
  unchanged.
- **Select still drifts.** `runtime tool select` of the registered candidate answers
  `previewDrifted` (`tool.selectionFactsUnavailable`) with zero dispatch.
- **Coverage.** `runtime.tool.register` joins `WINDOWS_MEASURED_LEAVES`. The DevEco kind was
  already measured by `windows_bootstrap_owners_process.rs`. The coverage was regenerated with
  `arkdeck maintainer contracts export` (one entry `partial` → `implemented` on Windows), and
  `oracle.json` is not re-pinned.

## Left out

- `runtime.tool.select` stays Windows `partial`. The selection's impact reads the managed server's
  health through the HDC lifecycle owner. No Windows composition proves that healthy yet (#2501, in
  review), so every selection drifts before approval. The `tool-selection-registry` oracle is a
  registry-ledger recording, and the owner-level Windows tests already replay it.

## Local targeted checks

See the commit message: the commands and their exits.

## CI

This is recorded by the next slice.
