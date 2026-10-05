# TASK-XPA-008 — signed Windows CLI Debug template Jobs, 2026-10-05

- Base: protected-main commit `7133461b6`, isolated worktree
  `agent/xpa-008-windows-debug-template-20261005`; integrated as a layer in the Windows stack.
- Scope: measure the existing `debug template run` leaf, which submits `debug.template@1` as
  a Job. The deprecated direct `debug.template.run` Control method is a separate path.
- Host: Windows x64, development signer supplied by the handover. Cargo uses two jobs and
  the worktree's own `D:/cargo-target/debug-template`; heavy checks use `tools/gate_slot.py`.
- The real `arkdeck.exe` talks to the signed test daemon over the production Windows pipe
  and private development root. The daemon composes production owners, then its test-only
  HDC seam supplies the inert fixture answers and a synthetic USB census. No live device,
  installed Runtime or raw HDC command participates. These are host tests, not hardware evidence.

## Reference and behavior

The reference for Job semantics is the existing macOS Rust owner test
`rust/crates/arkdeck-hoststore/tests/debug_template_run.rs`. The four normal closed-template
commands and payloads are the existing Swift `rust/tests/fixtures/debug-probe` oracle.
The test does not equate the deprecated direct text read with a Job: direct reads reject
non-UTF-8 text, while the Job owner preserves those bytes as a sensitive raw Artifact.

The shared `OracleFake::debug_probe` now reuses the same three device observation answers
as the other Job fixtures: `list targets -v`, `const.product.name` and `const.ohos.fullname`.
They name the synthetic key and stable identity already present in the oracle's Target store.
The offline row uses the macOS owner's `[Fail] target offline` marker. The existing killed
template mode supplies `DispatchFailure::Unobservable`; no production transport or identity
rule changes, caller-created capabilities or new fixture injection mechanism were needed.

`debug_template_cli.rs` verifies:

1. Unknown, raw-command and missing template inputs are refused before any template
   dispatch. A stale binding is refused with no HDC dispatch. A valid plan has three steps,
   `readOnly` effect, and also dispatches nothing.
2. All four normal templates run once through the CLI: package inventory, debug parameter,
   window inventory and uptime. Jobs succeed with `actualEffect: readOnly`; their raw output
   equals the Swift oracle's bytes. Each has exactly the output and report Artifacts, and a
   sensitive output read requires explicit `--allow-sensitive`.
3. A parameter result containing `0xff` succeeds as the macOS Job owner does, with the
   exact raw bytes retained. Reports identify the template and byte count; their duration
   is the shared fake's fixed 1 ms, rather than the direct oracle's fixed 12 ms.
4. Offline, exit-status 7 and truncated output yield failed Jobs. Job status exposes the
   shared owner-level `executionFailed`; the typed timeline retains respectively
   `targetUnavailable`, `templateExitStatus` and `truncated`.
5. A killed template produces one `waitingForRecovery` Job with `outcomeUnknown: true`.
   Rerun is refused. Restart preserves the unknown state without a new dispatch. Typed
   reconciliation confirms the read-only intent not performed and ends in `failed` /
   `executionConfirmedNotPerformed`. Another rerun is refused; the entire HDC call log is
   unchanged through restart, reconciliation and refusal. The Target store is unchanged.
6. Template Jobs do not manufacture an observation in `job.evidence`.

The integration owner registers the Windows test module and adds only
`debug.template.run` to `WINDOWS_MEASURED_LEAVES`, then exports the shared generated coverage
and census. Generic Job leaves do not independently claim the domain operation. No Catalog,
protocol, capability/identity policy, platform declaration or task state is changed.

## Delegated minor decision, pending the next rulings batch

The user delegated future non-major decisions. The integration owner chose the already
existing macOS Rust Job owner test together with the Swift direct-template payload oracle
as this leaf's reference. This resolves the earlier run's missing Job observation fixture;
it changes no trust or safety requirement. The earlier `windows-debug-reads-run.md` remains
the historical record of why the leaf was then partial.

## Local targeted checks

Commands below use `--manifest-path rust/Cargo.toml`, `CARGO_BUILD_JOBS=2`, the isolated
target and the configured signer. Logs are below `D:/src/ArkDeck-wt/tools/`.

| Check | Exit and result | Log |
| --- | --- | --- |
| Build `arkdeck-cli --bin arkdeck` before testing | 0 | `debug-template-build-cli.log` |
| `test -p arkdeck-agentd --test spawning debug_ -- --skip gj23_replay:: --nocapture` | 0; 3 passed, 0 failed/ignored; no `SKIPPED` line | `debug-template-debug-tests.log` |
| `clippy -p arkdeck-agentd --all-targets -- -D warnings` | 0 | `debug-template-clippy.log` |
| `fmt --all --check` | 0 | `debug-template-fmt.log` |
| `check-sdd.sh` | 0; 0 errors, 0 warnings | `debug-template-sdd.log` |
| New signed CLI test with verified C: 8.3 `TEMP`/`TMP` | 0; 1 passed, 0 failed/ignored; no `SKIPPED` line | `debug-template-short-temp.log` |
| `git diff --check` | 0 | `debug-template-diff.log` |

The initial new test used the provider-level reason as the public Job status code and failed;
inspection of the unchanged owner showed its intentional `executionFailed` projection. The
test now checks that projection and the provider reason in the public timeline; the corrected
run passed. Final checks include the added offline row. This was a test expectation correction,
not a production or safety-assertion change.

The unchanged full agentd suite had just passed in the preceding integration work; it was not
repeated. No contract input changed, so the full local unified gate and contract-input checks
were not run. The shared coverage generation belongs to the integration layer.

Final integration directly above #2582 (flash alias): CLI build/export,
`cargo test -p arkdeck-cli` (264 reported passes), three signed Debug spawning
regressions with verified 8.3 `TEMP`/`TMP`, `cargo test -p arkdeck-provider-hdc`
(182 reported passes), CLI/Agentd/Provider-HDC/Hoststore all-target clippy with
warnings denied, full fmt check, SDD, diff check and contracts check (242 clean)
all exit 0. Cargo commands use `--manifest-path rust/Cargo.toml`.
Logs: `D:/src/ArkDeck-wt/tools/logs/debug-layer-{build,export,cli-tests,short-tests,provider-tests,clippy,fmt-final,sdd}.log`.
The first integration fmt check requested module sorting; formatting was applied
and the final check passed. No behavioral change followed the passing tests.

## CI

PR and run IDs are recorded by the integration layer after push. CI remains the full diff-based
verification gate, including macOS parity. No CI result or maintainer approval is claimed here.
The preceding health increment #2580 has passed `Rust contract parity (xcode-27)`,
including the Session resource check that rejected its earlier availability-based
implementation. Its Windows workspace lane is still running at preparation time.
