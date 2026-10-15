# Windows ArkForge composition and Flash discovery

The installed protected-main Runtime at `fea0d78222b88b8bbc5efe385f76759637c786a2`
successfully composed the published ArkForge bundle at
`eedaa3e3bae641374e453cad302eb214d55d6b08`. Runtime health, service ownership,
initial normal-mode binding, imported image validation and the full fourteen-step
plan succeeded. However, operation discovery still reported `provider_not_registered`
because its host implementation did not handle the `arkforge` provider.

Discovery now reads the same Flash planning configuration as admission and requires
the composed executor, target/facts ports, mutation owner, Job owner and Artifact
store. It retains provider qualification and current dispatcher identity failures.
Only `flash.full-restore@1` and its existing `flash.dayu200` alias are recognized.
Discovery does not resolve a target, materialize an image, issue a capability or
dispatch a device action. Tests cover the configured and absent provider, all missing
owners, an unsupported operation, hardware qualification and dispatcher drift.

The first installed Runtime execution reached image prewarm and validation, then
stopped after the HDC-to-Loader transition with `outcomeUnknown`: the exact admitted
identity was not observed in Loader mode. A subsequent read-only census observed one
unbound Loader. Passive `job reconcile` retained `waitingForRecovery` with
`flash.recoveryProofMissing: no correlated complete-plan receipt`. No replay,
binding advance, new destructive request, Runtime restart or manual record edit was
performed. Raw responses and the original image remain local. This is an unresolved
hardware acceptance result, not `REAL_DEVICE_PASS`.

Compatibility note: this repairs discovery and the runbook under the existing
Catalog and POL-AGENT-002; it changes no authority, identity, recovery policy or
hardware qualification. Loader onboarding and coverage of unknown records across
binding changes still require a separate verified product path.

Local targeted checks: the official Cargo runner's `fmt --all --check` reached
Windows' argv limit; the equivalent batched check passed all 356 target roots.
`clippy -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings`
and the direct dependent `arkdeck-soak` clippy/test exited 0 (five substantive
soak tests). `test -p arkdeck-hoststore` passed 378 unit tests, including both
new discovery tests, then exited 101 at the unchanged historical `debug_hap_plan`
Catalog oracle (old `c6` fixture versus current `e4`; CI owns its declared historical
view). `test -p arkdeck-agentd` passed its 43 unit tests and 51 spawning tests,
including Flash execution, binding and unknown-preservation cases, but exited 101
on two account-daemon tests: the installed Runtime's account single-instance guard
correctly refused their alternate roots. The installed unknown Job was not stopped
to free that guard. Remaining targets after those failures were not executed locally.
No fixture or assertion was weakened. Logs are retained under
`arkdeck-flash-availability-checks-20261015/{fmt,clippy,hoststore-test}.log` and
`arkdeck-flash-availability-followup-checks-20261015/{soak-clippy,soak-test,agentd-test}.log`.
`sh scripts/check-sdd.sh` exited 0 with no errors or warnings
(`arkdeck-flash-availability-sdd-20261015.log`); `git diff --check` exited 0.

CI: predecessor PRs #2644, #2645 and #2647 passed runs `38718774710`,
`38718846712` and `38718893727`, respectively, before native stack merge.
This follow-up's CI is pending publication.
