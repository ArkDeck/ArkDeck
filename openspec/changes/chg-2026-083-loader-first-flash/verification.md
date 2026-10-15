# Verification — CHG-2026-083

> Change:CHG-2026-083-loader-first-flash@r1

Tests use synthetic USB/HDC/ArkForge ports. They are not REAL_DEVICE_PASS.

- First Loader adoption creates one Target and binding, with no fabricated HDC
  identity; retries and restart after Target publication preserve the same owner.
- Missing, ambiguous, unsupported or changed hardware refuses before publication.
  Existing Normal targets cannot be relabeled as initial Loader targets.
- An unresolved Flash under any Target, including a terminal unknown, blocks a
  first adoption before USB observation; original Target, binding and Job bytes stay.
- Materialization pins Loader hardware and connector digests in typed read-only
  postflight actions. A missing connector or an unproved Normal route is rejected.
- ArkForge control callbacks select the hardware-bound reconnect and build checks;
  a disappeared initial Loader never falls back to an HDC mode-changing command.
- Returning HDC identity may differ, but the fixed kernel read must match the
  admitted Loader on the same connector. Missing, duplicate, wrong or incomplete
  serial reads, another connector and a different artifact build all refuse.
- Reconnect alone publishes no alias. Exact build and hardware proof establish a
  schema-2 alias without a previous HDC field. Repeated callbacks preserve its
  bytes; diagnostics require this Job's route and repeat hardware verification.
- CLI and Control accept the exclusive targetless adoption mode. Existing selected
  Target/revision calls and historical action/alias encodings remain compatible.

## Local targeted checks

Run on Windows, 2026-10-16 local date. Log names below are relative to
`D:/src/ArkDeck-wt/tools/`. Cargo used the existing session owner and cache,
with `CARGO_BUILD_JOBS=2`. No local unified gate or device mutation was used.

- `python rust/scripts/run-cargo.py clippy` with `-p` for agentd, bootstrap,
  cli, client, contract, control, hoststore, provider-arkforge, provider-hdc,
  rockchip-binding and soak (each prefixed `arkdeck-`), then
  `--all-targets -- -D warnings`: exit 0; `loader-first-clippy-final.log`.
- `python rust/scripts/run-cargo.py test` with the same packages except agentd,
  then `--lib`: exit 0; 760 passed, 4 existing ignored;
  `loader-first-library-tests-final.log`. Agentd `--lib --bin arkdeck-agentd`:
  exit 0, 44 passed; `loader-first-agentd-units-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --test
  loader_binding_jobs --test post_flash_alias`: exit 0, 9 passed;
  `loader-first-binding-alias-tests-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --test flash_plan
  loader_first_full_restore_materializes_without_a_prior_hdc_alias`: exit 0,
  1 passed; `loader-first-plan-test-final.log`. The fixture imports and commits
  its image through the Import owner for the Loader identity before planning.
  The final test also passed `clippy -p arkdeck-hoststore --test flash_plan
  -- -D warnings` (exit 0; `loader-first-plan-clippy-final.log`).
- `python rust/scripts/run-cargo.py test -p arkdeck-cli --test machine_contracts
  --test argv_fixtures`: exit 0, 15 passed;
  `loader-first-cli-contract-tests-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-cli --test maintainer_contracts`:
  exit 0, 7 Windows cases passed; `loader-first-maintainer-contracts-windows.log`.
  Its targeted Clippy invocation passed with warnings denied;
  `loader-first-maintainer-clippy.log`. The Unix historical export replay stays
  in CI; only the declared regenerated Loader argv file joins its existing
  compatibility mapping, while the retained recording remains byte-identical.
- `python rust/scripts/run-cargo.py fmt --all --check`: exit 1 because Windows
  rejected the workspace command length (OS error 206); `loader-first-fmt-all.log`.
  Every changed Rust file passed `rustfmt --edition 2024 --config skip_children=true
  --check` (exit 0; `loader-first-rustfmt-changed.log`). `git diff --check` passed.
- `python rust/scripts/generate-contract.py --check`, command-registry copy check
  and contract digest check: exit 0. The new Control sample was recorded by the
  real Control handler over isolated synthetic host ports; original samples stay.
- `python windows/scripts/generate-clientkit.py --check`: exit 0 after regenerating
  the Windows client's hash for the extended Loader binding schema;
  `loader-first-windows-clientkit-check.log`.
- Catalog routing's 31 Python tests passed; `loader-first-test-routing.log`.
  Source inventory and the complete routing manifest validate against Cargo
  metadata; `loader-first-manifest-final.log`.
- `sh scripts/check-sdd.sh` through Git Bash and the repository Python environment:
  exit 0; `loader-first-sdd.log` (0 errors, 0 warnings).

The earlier broad local Cargo invocation stopped at two existing account-daemon
process tests because the installed production Runtime owns its singleton. Its
97 passed / 2 failed / 3 ignored result is retained in
`loader-first-targeted-tests.log`; the real Runtime and unknown Job were preserved.
An unfiltered historical Flash oracle also requires its routed historical Catalog,
not the current-Catalog local binary. Full routed process/oracle suites belong to
PR CI. Swift and App checks require macOS and were not run on this Windows host.

## CI

PR #2653: the initial `b038d5cd` run `38823975495` identified one stale generated
Windows ClientKit schema pin. The generator now supplies that pin; no assertion
or contract was relaxed. The selected lanes remain pending for the corrected head.
SDD runs `38823975514` and `38824054453` passed on the initial head.
Run `38824361055` on `4d11c405` passed Windows ClientKit and the full Swift suite.
Linux workspace and all three contract-parity views identified the same historical
export hash mismatch for `fixtures/argv/flash.bind-loader.json`; no other exported
file differed. The explicit compatibility mapping now includes that regenerated
input, whose current bytes are independently pinned and replayed by CLI tests.
The corrected head must complete all selected lanes before merge.
CI success is not hardware acceptance and does not replace maintainer review.
