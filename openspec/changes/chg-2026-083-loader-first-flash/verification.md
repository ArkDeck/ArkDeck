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
- The macOS CI fixes also passed the Windows agentd library and binary units:
  exit 0, 44 passed; `loader-first-ingress-agentd-units.log`. The additional
  macOS App ingress cases exercise exclusive first adoption, selected-Target
  compatibility and rejection of mixed parameters, caller identities and
  untrusted peers; they require the macOS CI lane.
  `clippy -p arkdeck-agentd -p arkdeck-bootstrap --all-targets -- -D warnings`
  also passed (exit 0; `loader-first-ingress-clippy.log`).
  The published-schema expectation fix repeated these 44 Windows unit cases
  and Clippy successfully (exit 0; `loader-first-published-ingress-units.log`
  and `loader-first-published-ingress-clippy.log`). Its macOS-only assertion
  is verified in CI; direct rustfmt and the complete routing manifest passed
  locally (`loader-first-published-ingress-manifest.log`).
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
  The final ingress source pins validate with the complete manifest too;
  `loader-first-ingress-manifest.log`. All three Rust files in that fix passed
  the direct rustfmt check.
- `sh scripts/check-sdd.sh` through Git Bash and the repository Python environment:
  exit 0; `loader-first-sdd.log` (0 errors, 0 warnings).
  The ingress fix passed again: exit 0, 0 errors and 0 warnings;
  `loader-first-ingress-sdd.log`.
  The published-schema test correction also passed with 0 errors and warnings;
  `loader-first-published-ingress-sdd.log`.
- The Windows CI deadline edit passed YAML parsing and checks that the three-OS
  matrix, failure aggregation and non-Windows deadlines are unchanged.
  Configuration check: exit 0; `loader-first-ci-budget-config.log`. SDD passed
  with 0 errors and warnings (exit 0; `loader-first-ci-budget-sdd.log`).
  The aggregate-status regression passed with Git Bash on PATH (exit 0;
  `loader-first-ci-aggregate-targeted.log`). The initial full planner run could
  not find `sh`; its other cases passed. The existing CI workspace tests had
  one Windows CRLF fixture failure and two skips (29 cases total);
  `loader-first-ci-plan-tests-owned-temp.log` and
  `loader-first-ci-execution-tests-owned-temp.log`. Neither test source changed.

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
Run `38825448370` on `146a1f16` passed Swift, Windows ClientKit, Rust host checks,
Linux workspace and Linux contract parity. Its macOS workspace found two defects:
App ingress required both exclusive Loader request shapes at once, and the new
JobStore test used macOS's noncanonical `/tmp` spelling. The ingress now admits
either complete shape, with new negative coverage; the test opens its canonical
private directory without relaxing production storage validation.
Run `38827489809` on `c4d1fe81` passed all three workspace lanes, Swift,
Windows ClientKit and Linux contract parity. The macOS published-contract view
correctly rejected `adoptCurrentLoader` under the merge base's older closed
schema, but the new App test incorrectly expected success in that view too.
That test now verifies the exact refusal and zero owner dispatch only when the
embedded inputs identify a published baseline whose schema lacks the field.
The current schema must still complete adoption; its success and the other
three Loader regression cases executed successfully in the macOS workspace.
Raw CI logs: `loader-first-macos-parity-failure.log` and
`loader-first-macos-workspace-success.log`.
Run `38831173671` on `a1f0da46` passed Swift, Windows ClientKit, all workspace
lanes, and Linux/macOS contract parity. The macOS parity log confirms the Loader
test passed in all three views (`loader-first-macos-parity-success.log`).
Windows completed its published and candidate views but the 50-minute job limit
cancelled the historical view while process tests were still passing. The log
contains no failed assertion, panic or failed test summary;
`loader-first-windows-parity-failure.log`. Only that CI job's Windows deadline
is raised to 75 minutes so all three views and finalization can finish. Test,
Runtime and operation deadlines, selected cases and failure aggregation stay.
The corrected head must complete all selected lanes before merge.
CI success is not hardware acceptance and does not replace maintainer review.
