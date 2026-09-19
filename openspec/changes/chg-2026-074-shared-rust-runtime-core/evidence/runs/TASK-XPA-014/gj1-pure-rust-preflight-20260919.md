# TASK-XPA-014 — GJ-1 on the pure Rust daemon: preflight, blocked (macOS, 2026-09-19)

Base: protected main `81957589`. Goal for the day's device window: run the headless runbook's
§2 (GJ-1, without the §2.1 restart carry-over that waits for design §L.1 item 13) first on the
isolated Rust daemon against the fake HDC, then on the connected DAYU200 with the pure Rust
daemon, to move "Golden Journeys on Rust" from 0/5. The DAYU200 was enumerated
(`ioreg -r -c IOUSBHostDevice`: Rockchip "HDC Device", vendor 0x2207) at 14:11 CST. No device
command, HDC command, installed-state change or Runtime authority write was made; this record is
a source preflight, not a run.

**Result: the real-device run was not attempted.** Reaching the device through the Rust daemon
today requires bypassing a published guard, which the runbook's preamble classifies as
`BLOCKED_BY_PRODUCT_DEFECT` (stop and record). The blocking facts, each read in source:

1. **The isolated owner refuses a registered HDC.** `rust/crates/arkdeck-agentd/src/main.rs`
   `development_hdc()` pins `ARKDECK_DEVELOPMENT_HDC_PATH` and refuses it when
   `HdcReadOnlyProvider::new` accepts it: "the isolated Rust development owner runs a fixture HDC
   only; a registered HDC needs the existing-server identity proof". An isolated root also refuses
   `ARKDECK_HDC_PATH`/`ARKDECK_HDC_SHA256`. A wrapper with an unregistered digest around the real
   `hdc` would pass mechanically and address the real server without that proof — exactly the
   bypass the guard exists for. Owner: TASK-XPA-016 (the managed `-m` server and its existing-server
   identity proof, "R2" in the HDC lifecycle map) with TASK-XPA-014 composing it.
2. **No trusted USB relation source.** Every composition on main uses `NoUsbRelations`, so
   `target adopt` is refused with `admissionDenied`; the production reader belongs to the ArkForge
   lane (TASK-XPA-017 / design §L.1 item 13 dependencies). PR #1988's
   `ARKDECK_DEVELOPMENT_USB_RELATIONS` is a caller-written file allowed only beside the fixture
   HDC; it is development evidence, not a physical relation proof, and cannot stand in for it.
   Seeding `targets-state/targets.json` for a real device would be a trusted-fact write.
3. **Which daemon setup may count before M5 is undecided.** Isolated-root results are not
   acceptance (hard rule A4); the standalone mode composes no Target, Job or agent owner
   (`agent.run` answers `operationUnavailable`); the installed LaunchAgent still runs the façade
   pair, and installed activation happens once, at M5. A maintainer decision is needed on the
   daemon setup for M1's real-device pass (for example a standalone composition with owners over
   the account's default root, which is also the only root with mutation authority —
   `mutation_state_continuity::require_mutation_state`).

Neither GJ-1 operation needs mutation authority: `observe.device@1` is readOnly, and
`capture.diagnostics@1` with `{ "durationSeconds": 5 }` stays readOnly (its file-capture legs,
the only deviceMutation ones, are unselected and not implemented in Rust).

## §1/§2 commands against the Rust CLI and the isolated daemon (main `81957589`)

| Runbook command | Rust CLI leaf | Isolated daemon | State |
| --- | --- | --- | --- |
| `doctor --deep --require-healthy` | yes | routed, but the report is fixed (`provider.noneRegistered`, store/HDC not configured), so `--require-healthy` exits 69 | code gap (XPA-014/018) |
| `runtime service status` / `verify --job` / `restart` | no | `health`, `job.status`, `job.evidence`, `artifact.list` are served; the service leaves bind to the installed LaunchAgent | CLI gap (XPA-018); restart carry-over waits for §L.1 item 13 |
| `runtime hdc status` | no on main; PR #1992 adds it | answers `unavailable` / `hdc.notConfigured` (no managed server) | CLI in review; live status needs item 1 |
| `runtime tool list`, `operation list`, `runtime bundle list` | yes | served | OK |
| `device candidates` | yes | served | OK |
| `target adopt` | yes | refused: `NoUsbRelations` | item 2 (development path: #1988) |
| `target show`, `target availability` | yes | served; presence `unresolved`, tool `absent` without a managed server | OK / item 1 |
| `agent run` (observe; capture with `durationSeconds`), `agent status` | yes | served (capture: default legs) | OK |
| `job result`, `job evidence`, `job show`, `artifact list`, `artifact read` | yes | served | OK |

Against the fake HDC, the observe and capture legs of GJ-1 already run end to end through real
processes: `rust/scripts/check-corpus-replay.py --fixture rust/tests/fixtures/agent-execution`
(isolated root, fixture HDC, seeded adopted Target) replays the `agent run` executions for
`observe.device@1` and `capture.diagnostics@1` and their Job reads (PASS again on 2026-09-19 in
#1988's checks). What §2 still lacks on the isolated daemon is listed in the table: the `doctor`
report, the `runtime service` leaves, adoption without a seeded Target (development relations,
#1988), and a live HDC status.

## What would unblock the real-device GJ-1 on Rust

In order: (1) the managed HDC server with the existing-server identity proof composed into the
Rust daemon (TASK-XPA-016 → XPA-014), which also makes `runtime.hdc.status` and Target
availability live; (2) a trusted USB relation reader (ArkForge lane); (3) the maintainer's choice of
the daemon setup that counts before M5; then the `runtime service` and `doctor` leaves for the
record's identity fields (`gj-headless-rerun` schema `arkdeck.gj-headless-rerun/1`). The §2.1
restart carry-over stays behind §L.1 item 13.

Not run: any device, HDC or installed-Runtime command; this preflight produced no GJ record.
