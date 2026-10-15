# Verification — CHG-2026-082

> Change:CHG-2026-082-normal-loader-hardware-proof@r1

Local checks use synthetic USB/HDC/ArkForge ports. No REAL_DEVICE_PASS is claimed.

- Exact target-scoped argv, bounded output and timeout; one canonical hardware
  serial, with missing, duplicate, placeholder, malformed and unclean reads refused.
- Normal USB and connector are unchanged across capture; the durable record is
  written and read before the first mode-changing command.
- Missing/mismatched proof, persistence failure, stale observation, changed
  connector or changed tool dispatch zero reboot commands.
- Records retain target/revision/job/step and provider/source digests, reject an
  invalid context or unusable private root, and preserve previous observations.
  No raw CPU information, hardware serial or Normal connect key is recorded.
- Planning and readiness reject absent, malformed or mismatched Normal proof.
  Exact already-Loader dual observation keeps its existing no-command path.
- A successful transition still requires matching Loader and physical connector;
  existing confirmed-not-executed and outcome-unknown distinctions stay intact.
- Historical fixture requests remain unchanged; synthetic trusted-fact ports
  explicitly satisfy the new prerequisite for unrelated legacy plan comparisons.

## Local targeted checks

- `python rust/scripts/run-cargo.py clippy -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings`: exit 0. Log: `normal-loader-clippy-final.log`. The final `clippy -p arkdeck-agentd --all-targets -- -D warnings` also exited 0; log: `normal-loader-agentd-clippy-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-provider-hdc -p arkdeck-soak`: exit 0, 217 passed; one pre-existing opt-in soak case ignored. Log: `normal-loader-provider-soak-final.log`.
- Hoststore library: 381 tests passed and four pre-existing cases were ignored, including admission, persistence and executor guards. The broader `test -p arkdeck-provider-hdc -p arkdeck-hoststore -p arkdeck-soak` command exited 101 at the unrelated historical HAP plan oracle: it expects the c6 Catalog while an unqualified local run uses e4. That case remains mandatory in CI's declared historical view. Log: `normal-loader-crates-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-agentd --test spawning flash_`: 20 passed and three child fixtures ignored; its one initial failure expected no new observation directory. The corrected assertion checks every new record's digest, private mode and schema while retaining byte-exact old binding/alias/target assertions. Its exact rerun exited 0. Logs: `normal-loader-flash-final.log`, `normal-loader-facts-final.log`.
- `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --test flash_plan every_dispatcher_reason_is_swifts -- --exact`: exit 0. Log: `normal-loader-dispatcher-final.log`.
- The initial affected-crate run also passed 43 agentd unit tests and 37 spawning cases. Two unchanged account-daemon cases could not acquire the single-instance guard held by the installed Runtime. That Runtime and its parked unknown Job were preserved; isolated CI must execute those cases. Log: `normal-loader-tests.log`.
- `python -m unittest discover -s rust/scripts -p test_catalog_test_views.py`: exit 0, 31 tests. The complete source/fixture/target manifest also validates; the new Host/Control refusal case runs in both Catalog views on both supported hosts. Log: `normal-loader-test-routing.log`.
- Changed Rust files: `rustfmt --edition 2024 --config skip_children=true --check`, exit 0. `git diff --check`, exit 0. The required `python rust/scripts/run-cargo.py fmt --all --check` cannot launch rustfmt on this Windows host (OS error 206, argument list too long); CI retains the full workspace check. Log: `normal-loader-fmt.log`.
- `sh scripts/check-sdd.sh`: exit 0, no errors or warnings. Log: `normal-loader-sdd-final.log`.

Logs stay in the local task's tools directory. No local unified gate ran. macOS
subprocess tests and the complete historical/current matrix run in GitHub CI.
No Swift/App source or generated control-contract input changed, so no local
Swift/App or contract regeneration check was required. Earlier fixture failures
are recorded above rather than presented as green runs.

## CI

Pending the PR head's selected GitHub lanes. CI success does not assert hardware
acceptance or independently approve the safety proposal. Do not amend a green
head solely to copy its CI result into this document; the delivery report and PR
retain the exact run result.
