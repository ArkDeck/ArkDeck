# Rust isolated performance launcher — 2026-09-18

TASK-XPA-025, SPK-11 foundation on protected main `aeffacf8`.
The benchmark launcher now starts the standalone Rust development owner with
its actual environment interface, canonical root and private endpoint. It
clears inherited ArkDeck configuration, including pairing and device providers.
Swift capture remains the default while its seeded workload is ported.
Failed health verification now closes the measurement connection.

Validation:
- Repository unified local check (`scripts/ci/plan.py`, origin/main merge base,
  worktree included): passed.
- Release `cargo build -p arkdeck-agentd` passed.
- Python benchmark suite: 125 tests passed with local process observation
  permission (sandbox initially refused the existing `ps` resource test).
- Three independent isolated Rust starts, 100 health round trips per run,
  local resource samples and restart/empty Job readback passed. The attached
  JSON is advisory: loaded host, empty stores, no steady-state window or soak.
  It is not a baseline, budget approval, SPK-11 pass or hardware evidence.
- The initial Rust launch refused a noncanonical macOS temporary path;
  resolving the harness-created path fixed it without weakening the owner.
  Job page snapshot identities intentionally change across reads/restarts;
  the probe compares items rather than those identities.

Remaining: Rust seeded successful/cancelled/recovered workload, full metric
coverage, separate resource plateau/steady windows, three stable release
captures, long soak and scheduled-lane migration. No installation or device use.
