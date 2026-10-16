# Verification

> Change:CHG-2026-084-vendor-sn-retained-archive@r1

All new tests use synthetic identities and isolated stores. They are not hardware
evidence and do not mark this change or a platform approved/verified.

- Distinct CPU and factory identities remain distinct; the already bound Loader
  digest must agree with both boot and current vendor SN before persisted proof
  permits a mode transition. Invalid metadata, changed observations and refused
  persistence dispatch no transition. Existing CPU-serial tests remain valid.
- Both an explicit unknown outcome and a missing outcome publish as unknown.
  Original journal bytes remain a prefix; protected record fields, recovery clock,
  resource holds and capability lineage remain unchanged. Repeated decisions and
  each interrupted append recover without provider execution or budget renewal.
- Active budgets, malformed clocks/lineage, resident or locked Jobs, torn journals
  and stale reviews refuse. Archived unknowns continue to block Loader adoption,
  rebinding and conflicting Flash. Invalid Session claims of success, a fresh
  route/tool, released resources or automatic recovery are rejected.
- App tests cover all three retained-risk review modes, original confirmation
  preservation, and refusal of replies that clear unknown or drop hazards. The
  archive sheet and receipt explain that uncertainty and blocking remain.

## Local targeted checks

Run on Windows, 2026-10-16. Log names below are relative to
`D:/src/ArkDeck-wt/tools/`. Cargo reuses this chat's fixed owner/cache with two
jobs. No local unified gate or real device operation was run.

- `python rust/scripts/run-cargo.py clippy -p arkdeck-provider-hdc
  -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings`: exit 0;
  `vendor-sn-clippy-final.log`.
- `python rust/scripts/run-cargo.py clippy -p arkdeck-soak --all-targets --
  -D warnings`: exit 0; `vendor-sn-consumer-clippy-final.log`. This covers the
  remaining direct consumer of the modified crates.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 because Windows
  rejected rustfmt's workspace argument list with OS error 206;
  `vendor-sn-fmt-initial.log`. Direct `rustfmt --check --edition 2024 --config
  skip_children=true,newline_style=Unix` on all 19 changed Rust files: exit 0;
  `vendor-sn-contracts-final.log`.
- `python rust/scripts/generate-contract.py --check`,
  `python windows/scripts/generate-clientkit.py --check`,
  `python windows/scripts/generate-ui-strings.py --check` and `git diff --check`:
  each exit 0; `vendor-sn-contracts-final.log`. The same log records the complete
  source/fixture/target routing inventory and local JSON Schema validation of both
  actual synthetic archive Manifests, including rejection of false success and
  certainty claims.
- `ARKDECK_PYTHON=<installed Python> bash scripts/check-sdd.sh`: exit 0;
  0 errors and 0 warnings; `vendor-sn-sdd-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-provider-hdc
  -p arkdeck-hoststore -p arkdeck-soak --lib`: exit 0; 554 passed, 4 existing
  ignored; `vendor-sn-library-tests-final.log`.
- The initial package test command (`test -p arkdeck-provider-hdc
  -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak`) passed agentd's 44 unit
  cases, 2 symbolizer cases and 53 spawning cases, but exited 101 at its archive
  CLI case: the harness found an older prebuilt `arkdeck.exe` beside the current
  daemon and its response schema rejected the new fields. The harness documents
  `build -p arkdeck-cli` as a prerequisite when testing agentd alone.
  `vendor-sn-targeted-tests-final.log` retains this failed attempt.
- `python rust/scripts/run-cargo.py build -p arkdeck-cli --bin arkdeck`: exit 0;
  `vendor-sn-cli-build.log`. Then `test -p arkdeck-agentd --test spawning
  job_archive_cli::a_quiescent_job_is_archived_over_the_signed_test_daemon
  -- --exact`: exit 0, 1 passed; `vendor-sn-cli-archive-retest.log`. No code or
  assertion changed to resolve the stale executable. The remaining library and
  affected integration targets run separately rather than repeating passed tests.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore` with `--test` for
  `job_recovery`, `job_journal_restart`, `job_journal_process_death`,
  `job_journal_corpus`, `loader_binding_jobs` and `post_flash_alias`: exit 0,
  19 passed; `vendor-sn-host-integrations-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --test flash_plan
  loader_first_full_restore_materializes_without_a_prior_hdc_alias -- --exact`:
  exit 0, 1 passed; `vendor-sn-flash-plan-final.log`. The historical-only plan
  oracle runs in CI's declared Catalog view, not against the current Catalog here.
- Swift's `RuntimeJobArchiveApplicationFacadeTests` and App build-for-testing
  could not run on this Windows host (no Swift/Xcode). They require the selected
  macOS PR CI; no local native App acceptance is claimed.

## CI

Pending PR creation and selected CI. No result is claimed before the run completes.
Final run IDs and conclusions are recorded on the PR and in the delivery report;
an already-green head is not amended solely to copy CI results into this file.
