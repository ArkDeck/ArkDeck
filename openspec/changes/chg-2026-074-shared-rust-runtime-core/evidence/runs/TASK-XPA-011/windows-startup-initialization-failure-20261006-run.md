# Windows native initialization failure regression — 2026-10-06 UTC

Protected main `f245a1d9c34c6deb56d9f50236db0a5284cc062b` includes
the same-connection typed health readiness repair from PR #2613. This increment
adds genuine signed native process regressions for backend composition failure
after pipe reservation and instance publication. It also preserves the known
native child exit when composition closes its proving connection before the
process exit signal. For readiness failure, the retained child is observed only
over the remaining original startup deadline. Identity refusal is still observed
without waiting; an unavailable, unproved or successful child exit cannot replace
the original failure. Three D0 boundary cases cover these rules. No connection
is reopened and no caller request is sent or replayed. Identity policy, startup
deadline, operation, capability and device behavior remain unchanged.

The first case calls `ensure_running` exactly once on a fresh development root
with a configured signed daemon and a nonexistent analyzer. It must refuse
readiness, retain the one launched PID and original instance, and leave the pipe
absent with the native guard and state lock released. The refusal must preserve
the actual native exit 69 within the original startup deadline, including when
health EOF precedes the process exit signal. The existing client D0 case
separately proves the early authenticated connection cannot succeed before its
one health answer.

A second, independent fresh root launches the same verified signed daemon once
with the production detached creation flags. It retains the native child handle
through actual exit 69 and inspects bounded stdout/stderr files created exclusively
inside a private state child. The diagnostic must report the unusable analyzer
and that nothing was started. No listening success or duplicate-instance message
is accepted. The client has no diagnostic-stream capture API; this separate
launch does not claim to capture the first case's stderr or replay its start.

Both cases reach composition before failure and confirm HDC control composition
was not reached. Every child environment clears inherited ArkDeck/HDC inputs,
then adds only its fresh development root and nonexistent analyzer. Only the
test's existing host development signer is enabled for signing fixture copies.
No installed Runtime, real HDC endpoint, SDK signing material, device command,
business frame or unknown-start replay is used. These are local fixture checks,
not hardware acceptance or evidence. The separately diagnosed real startup
interlock remains an expected refusal of an external HDC listener; this test
does not stop or inspect that process.

## Local targeted checks

All commands ran from `D:/src/ArkDeck-wt/rc-smoke-path` on the protected base
above. `start_readiness_check.py` invokes
`python -X utf8 rust/scripts/run-cargo.py` with fixed exclusive owner
`tool-select`, its persistent cache
`D:/src/ArkDeck-wt/tools/cargo-owners/tool-select`, and jobs 2. Each log is a
new file under `D:/src/ArkDeck-wt/tools/logs/`; live opt-ins are cleared.
The native test explicitly enabled the existing development signer and did
not silently skip the signed cases.

The first matrix records the initial broader-refusal fixture before the
exit-observation correction and strict exit-69 assertion. Its original logs
remain preserved; it does not establish the final integrated behavior.

| Arguments to `run-cargo.py` | Actual result | Log |
| --- | --- | --- |
| `fmt -p arkdeck-agentd` | 0 | `windows-startup-failure-format.log` |
| `build -p arkdeck-cli -p arkdeck-agentd` | 0; current sibling images built | `windows-startup-failure-sibling-build.log` |
| `test -p arkdeck-agentd --test windows_client_start_process` | 0; 5 passed, initial fixture accepting any refusal before the stricter exit-69 assertion | `windows-startup-failure-native.log` |
| `test -p arkdeck-client` | 0; 10 passed | `windows-startup-failure-client.log` |
| `clippy -p arkdeck-agentd --all-targets -- -D warnings` | 0 | `windows-startup-failure-clippy.log` |
| `clippy -p arkdeck-client -p arkdeck-cli -p arkdeck-soak --all-targets -- -D warnings` | 0 | `windows-startup-failure-direct-clippy.log` |
| `fmt --all --check` | 1; Windows command-length `os error 206` | `windows-startup-failure-fmt-all.log` |
| `exec python D:/src/ArkDeck-wt/tools/native_fmt_fallback.py` | 0; all 13 workspace packages checked individually | `windows-startup-failure-fmt-fallback.log` |
| `exec sh scripts/check-sdd.sh` | 0 | `windows-startup-failure-sdd.log` |

The original format-check failure is retained. The exhaustive fallback changes
no source or assertions. No sleep or production fault/identity hook was added.
The existing directory helper's bounded cleanup retry remains unchanged.
The source checkout's final `git diff --check` returned 0.

After the retained real-account diagnostic showed that health EOF could precede
the native exit signal, the product correction and stricter fixture were checked
on the same fixed owner and current source. The diagnostic's external HDC
ownership interlock is not reproduced by these missing-analyzer fixtures and
is not weakened by the correction.

| Final integrated arguments to `run-cargo.py` | Actual result | Log |
| --- | --- | --- |
| `fmt -p arkdeck-client -p arkdeck-agentd` | 0 | `windows-startup-failure-final-format.log` |
| `build -p arkdeck-cli -p arkdeck-agentd` | 0 | `windows-startup-failure-final-build.log` |
| `test -p arkdeck-agentd --test windows_client_start_process` | 0; 5 passed, strict native exit-69 assertion executed | `windows-startup-failure-final-native.log` |
| `test -p arkdeck-client` | 0; 13 passed, including the three new exit-observation boundary cases | `windows-startup-failure-final-client.log` |
| `clippy -p arkdeck-client -p arkdeck-cli -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `windows-startup-failure-final-clippy.log` |
| `fmt --all --check` | 1; Windows command-length `os error 206` | `windows-startup-failure-final-fmt-all.log` |
| `exec python D:/src/ArkDeck-wt/tools/native_fmt_fallback.py` | 0; all 13 packages checked individually | `windows-startup-failure-final-fmt-fallback.log` |
| `exec sh scripts/check-sdd.sh` | 0 | `windows-startup-failure-final-sdd.log` |

The five actual native cases were:

- `a_signed_post_reservation_initialization_failure_is_never_reported_ready`
- `a_separate_signed_initialization_failure_retains_native_exit_and_diagnostic`
- `a_signed_daemon_is_started_once_verified_restarted_and_started_once_by_concurrent_clients`
- `a_started_daemon_that_fails_its_identity_is_reported_and_not_trusted`
- `without_a_configured_identity_nothing_is_started`

The final target ran all five with the existing signer enabled: none was skipped
or ignored. The two new failure cases preserve distinct roots and one launch per
root; independent diagnostic streams belong only to their explicit launch.

The full agentd/account-touching suites and complete unified CI gate were not
run in this explicitly isolated native startup window. No contract input changed,
so no contract regeneration was needed. Native execution uses the existing
Windows owner; no ACL, owner or Git safety setting was modified.

## CI

Not yet pushed; this increment has no PR or current-head CI result. Root owns
publication and required `guard`/`swift` checks. Local native fixture success
does not constitute protected-main Runtime/device acceptance.
