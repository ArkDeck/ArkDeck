# Windows SDK signer canonical-path ConPTY repair

Date: 2026-10-06. Base: protected main
`cfef5f7ec914c4cb5d493348f7c85a11925b78eb`.

The live acceptance coordinator reported the SDK release-profile signer failing
before its password exchange; the previous unavailable credential owner remained
unchanged and no replacement was published. The SDK toolchain itself was already
installed. A separate SHA-pinned host-only Java probe then compared the original ConPTY
launch with path-only and console-flag-only controls. The original Java version,
signer JAR help and fixed no-secret ConsoleProbe all exited 1. Lowering only the
eligible image and cwd to their ordinary Win32 spellings made all three exit 0;
version/help markers were seen and Java's console was available. Console flags
alone still exited 1. The combined control's harmless public output escaped to
the parent and reported console absence, so its capture is incomplete and its
flags are not used. No signing or hardware pass is claimed by those probes.

ConPTY now reuses the existing tool-runner spelling conversion for its child
image and requested cwd. A caller still supplies an existing canonical cwd; the
conversion preserves the exact canonical object. Ineligible spellings retain
the verbatim path. Executable retention/revalidation, suspended child-image
canonical/native identity proof, no handle inheritance, original console flags,
clean environment, kill-on-close Job and secret/echo/prompt bounds are unchanged.
The shared attached launch also serves persistent shell clients.

The Windows PTY regression starts a real fixture child with canonical inputs,
checks its actual argv[0] and current-directory ordinary spellings before both
password prompts, verifies the parent cwd did not change, and refuses an ordinary
caller cwd before a marker child can run. Its password values are fixed fixture
constants; it uses no Java signer, credential or device. The external helper's
separate canonical caller-cwd repair is frozen as utility `411acfa2…bef54`, built
against the old platform; it must be rebuilt after this fix is protected main
before any actual signing.

## Local targeted checks

Checks run from the isolated `rc-smoke-path` source using `rust/scripts/run-cargo.py`,
stable owner `signing-readiness`, fixed cache `D:/cargo-target/rc-smoke-path`,
runner locking and jobs 2. Heavy checks use `tools/gate_slot.py`; the actual
Runtime remains stopped. Logs are local under
`D:/src/ArkDeck-wt/tools/windows-sdk-canonical-pty/checks/`.

The clippy selection is `arkdeck-platform` and its ten direct consumers:
`arkdeck-provider-workspace`, `arkdeck-provider-hdc`, `arkdeck-soak`,
`arkdeck-rockchip-binding`, `arkdeck-hoststore`, `arkdeck-provider-arkforge`,
`arkdeck-bootstrap`, `arkdeck-agentd`, `arkdeck-client`, `arkdeck-cli`. Each is a
separate `-p` argument; the consumer test selection is the same without platform.

| Command | Result | Log |
| --- | --- | --- |
| `python rust/scripts/run-cargo.py fmt --all` | exit 1; Windows native argument-length error 206 before formatting | `fmt.log` |
| `python rust/scripts/run-cargo.py fmt -p arkdeck-platform` | exit 0 | `fmt-platform.log` |
| `python rust/scripts/run-cargo.py fmt --all --check` | exit 1; same error 206 | `fmt-all-check.log` |
| `python rust/scripts/run-cargo.py fmt -p arkdeck-platform --check` | exit 0 | `fmt-platform-check.log` |
| `python rust/scripts/run-cargo.py clippy --offline -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-provider-hdc -p arkdeck-soak -p arkdeck-rockchip-binding -p arkdeck-hoststore -p arkdeck-provider-arkforge -p arkdeck-bootstrap -p arkdeck-agentd -p arkdeck-client -p arkdeck-cli --all-targets -- -D warnings` | exit 0 | `clippy-platform-consumers.log` |
| `python rust/scripts/run-cargo.py build --offline -p arkdeck-cli` | exit 0; built before process tests | `build-cli.log` |
| `python rust/scripts/run-cargo.py test --offline -p arkdeck-platform -- --test-threads=2` | exit 0; includes all 10 PTY and 8 shell-channel cases | `test-platform.log` |
| `python rust/scripts/run-cargo.py test --offline -p arkdeck-provider-workspace -p arkdeck-provider-hdc -p arkdeck-soak -p arkdeck-rockchip-binding -p arkdeck-hoststore -p arkdeck-provider-arkforge -p arkdeck-bootstrap -p arkdeck-agentd -p arkdeck-client -p arkdeck-cli -- --test-threads=2` | exit 0 | `test-direct-consumers.log` |
| `python rust/scripts/run-cargo.py exec -- python D:/src/ArkDeck-wt/tools/windows-sdk-canonical-pty/check_workspace_format.py` | exit 0; `cargo fmt -p <member> --check` for all 13 workspace members | `fmt-workspace-distributed.log` |
| Git Bash `sh scripts/check-sdd.sh` | exit 0; 0 errors/warnings | `sdd-check.log` |
| `git diff --check` | exit 0 | `diff-check.log` |

The original full-format failures remain saved. The per-crate check supplies
the same workspace-member formatting coverage without one overlong rustfmt argv;
no formatter policy or source assertion was waived. Only explanatory comments
changed after the semantic tests, then the complete distributed format check
passed. The fresh cache and full direct-consumer compile/tests took longer than
the ten-minute target; that cache/owner is retained for subsequent tasks.

All inherited `ARKDECK_` and `OHOS_HDC_` inputs were removed before adding only
the runner controls. Live HDC/DevEco/signing opt-ins and the development signer
thumbprint were absent; tests gated on those prerequisites were disabled. These
checks use task-owned fixtures and supply no official SDK signing or real-device
evidence. No contract input or generated file changed, so generator checks are
not needed. Swift/App checks remain normal selected CI lanes for this Windows
Rust implementation increment.

## CI

[PR #2605](https://github.com/ArkDeck/ArkDeck/pull/2605), exact head
`c73cf6d1588b0ba067a306ce602540e356c97be7`: Swift CI run
[37415892010](https://github.com/ArkDeck/ArkDeck/actions/runs/37415892010)
failed. Windows workspace job `112114599087` was cancelled at its 30-minute
whole-job deadline; required `swift` aggregate job `112122264526` reported
failure. The full log is local at
`D:/src/ArkDeck-wt/tools/logs/ci-2605-windows-workspace-37415892010.log`.
All 150 completed suites reported zero failures. Cancellation was 0.47 seconds
after `windows_agent_human_action_resume` began, before the changed platform
PTY/shell test targets were reached; no assertion failure was observed.

The pre-platform baseline, Swift CI run `37407371986`, Windows workspace job
`112088199872`, passed in 22m59s at
`d7180f8c9bbb71e76b979863311f751c0c78fa2e`. Its Rust and `rust-ci.yml` bytes match
the protected-main base above. Both runs used runner image `20260925.250.1`,
one workspace worker and the development signer. Current/baseline durations
were 397.83/221.88 seconds for spawning, 249.01/144.77 for hoststore units,
152.66/134.61 for Job-store corpus, 114.96/58.51 for debug-HAP,
97.09/53.62 for Journal corpus and 70.64/37.08 for flash. The baseline HAR
suite passed 7 cases with 1 ignored in 5.57 seconds. The signer-free local
checks above are lighter than the signed CI fixture path; the two durable
corpus suites have no signer-dependent branch. These facts establish broad
slowdown and whole-job exhaustion, but provide no measured CPU/load or port
contention. All four invalid-run criteria are not proven, and this run is not
declared invalid or green.

The same PR now raises only Windows workspace's whole-job CI allowance from
30 to 40 minutes, matching the existing Windows contract-parity allowance.
macOS remains 50 minutes and Linux 30; worker count, exact test selection,
assertions, signer fixture and required checks are unchanged. Individual
test, Runtime and operation deadlines are unchanged. The cancelled run is
retained; the next ordinary commit/push will receive normal selected CI.
Targeted follow-up checks: Python YAML/static consistency exit 0, verifying
that the workspace timeout is the only semantic YAML change and all three
platform allowances match the expression; Git Bash `sh scripts/check-sdd.sh`
exit 0 with 0 errors/warnings; `git diff --check` exit 0. Results are recorded
in `D:/src/ArkDeck-wt/tools/logs/windows-sdk-ci-capacity-checks.log`. The initial
wrapper stopped at Git's sandbox ownership guard before checks ran; the
successful invocation trusts only this exact worktree in its child environment,
without changing global Git configuration.
The ordinary capacity-update push, exact head
`5644d25d243e4b98999e34b74f566a0ce8bedcde`, received Swift CI run
[37419870433](https://github.com/ArkDeck/ArkDeck/actions/runs/37419870433).
Its plan job `112126610413` failed: the 18 workflow-contract cases reported one
error because `validate_rust_ci_contract` still required the old workspace
macOS-50/Linux-and-Windows-30 expression. Native Rust lanes were skipped;
required `swift` aggregate job `112126666288` failed. This is a workflow-contract
consistency failure, not a newly observed product-test assertion failure.

The follow-up synchronizes only that expected timeout token with the actual
macOS-50/Windows-40/Linux-30 configuration. Because both native matrix jobs now
share it, the existing native-token assertion requires exactly one occurrence
in each job and exactly two overall; every other drift assertion is unchanged.
Negative cases reject independently removing the Windows allowance from
workspace or contracts and changing workspace's allowance to 41 minutes.
Local targeted check `python -X utf8 scripts/test_agent_pr_workflow.py` passed
all 18 cases, exit 0, recorded in
`D:/src/ArkDeck-wt/tools/logs/windows-sdk-ci-contract-sync-checks.log`.
Final Git Bash `sh scripts/check-sdd.sh` passed with 0 errors/warnings and
121 acceptance IDs; `git diff --check` passed, both exit 0 in the same log.

No Rust tests or builds are repeated for these workflow/documentation changes.
The validator follow-up has not received CI yet. Local checks and the host-only
probe do not constitute current-head CI success, maintainer approval or hardware
acceptance.
Protected-main RC rebuild and official SDK/signing verification remain
coordinator work after publication.
