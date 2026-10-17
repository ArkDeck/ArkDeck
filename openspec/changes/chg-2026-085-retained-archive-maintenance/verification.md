# Verification

> Change:CHG-2026-085-retained-archive-maintenance@r1

Tests use synthetic Jobs and isolated stores. No test result is hardware evidence.
The historical 147-row restart oracle remains unchanged. New cases cover complete
archive proof, each missing field, mismatched identity, unavailable/partial archive,
publication failure, retained hazards, active rows and review-digest drift. Owner
tests exercise real Runtime archive responses and retained Flash blockers. A signed
Windows CLI/daemon process test starts over a synthetic unknown archived by the
real owner, restarts and stops the Runtime, then verifies original record/journal
bytes and the current-Job census.

## Local targeted checks

Run on Windows, 2026-10-17, using this chat's fixed Cargo owner/cache and two build
jobs. Logs below are relative to `D:/src/ArkDeck-wt/tools/`.

- `python rust/scripts/run-cargo.py clippy -p arkdeck-agentd -p arkdeck-bootstrap
  -p arkdeck-cli -p arkdeck-client -p arkdeck-contract -p arkdeck-control
  -p arkdeck-hoststore -p arkdeck-provider-arkforge -p arkdeck-provider-hdc
  -p arkdeck-rockchip-binding -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `unknown-archive-clippy-3.log`. Includes the changed crates and all direct consumers.
- `python rust/scripts/run-cargo.py test -p arkdeck-contract -p arkdeck-cli`:
  exit 0; `unknown-archive-contract-cli-tests-1.log`; 359 libtest cases plus
  the signed Windows custom harness passed. The historical 147-row oracle is unchanged.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib`: exit 0;
  396 passed, 4 existing ignored; `unknown-archive-hoststore-tests-1.log`.
  Includes the real retained-archive preview feeding the shared restart predicate,
  both outstanding-intent and explicit-unknown histories, and unchanged admission blockers.
- `python rust/scripts/run-cargo.py build -p arkdeck-cli --bin arkdeck`: exit 0;
  `unknown-archive-cli-build-1.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-agentd --test
  windows_service_uninstall_process
  archived_unknown_survives_real_service_restart_and_stop_with_all_bytes_preserved
  -- --exact`: exit 0; `unknown-archive-service-process-tests-2.log`; 1 passed.
  The two pre-existing cases also passed in the initial full-target run.
- `python rust/scripts/run-cargo.py test -p arkdeck-bootstrap -p arkdeck-client
  -p arkdeck-control -p arkdeck-provider-arkforge -p arkdeck-provider-hdc
  -p arkdeck-rockchip-binding -p arkdeck-soak`: exit 0;
  `unknown-archive-consumer-tests-1.log`; 390 reported cases passed, 1 existing ignored.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 because Windows
  rejected the workspace argument list with OS error 206;
  `unknown-archive-fmt-1.log`. Direct `rustfmt --check --edition 2024 --config
  skip_children=true,newline_style=Unix` on all 9 changed Rust files: exit 0;
  `unknown-archive-format-files-1.log`. The same log records byte-identical shared
  preflight tables, the complete source/fixture/target inventory and `git diff --check`.
- `ARKDECK_PYTHON=<installed Python> bash scripts/check-sdd.sh`: exit 0;
  0 errors and 0 warnings; `unknown-archive-sdd-2.log`. The initial restricted
  Git Bash launch failed before checking files; the same check passed with host access.

Initial failed attempts remain in `unknown-archive-cli-preflight-tests-1.log`,
`unknown-archive-clippy-1.log`, `unknown-archive-clippy-2.log` and
`unknown-archive-service-process-tests-1.log`. Compile/lint issues were fixed.
The process fixture initially attempted to start an unarchived historical unknown
without its original capability ledger and correctly failed startup. The corrected
setup completes the archive with the real owner before starting the daemon, without
inventing a ledger or weakening admission. The process assertions still require
byte-identical record/journal, retained unknown and current census membership.

No local full unified gate, App UI assertion or device operation was run. macOS
execution is delegated to selected PR CI on this Windows host. Public wire inputs
and generated protocol pins are unchanged, so their generators are not rerun.

## CI

At initial push, PR creation and selected checks are pending. Exact-head run IDs
and conclusions will be recorded in the PR delivery record, without amending an
already green head. No approval, verification or hardware pass is inferred from
local tests.
