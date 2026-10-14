# Windows published ClientKit mixed-installation acceptance — 2026-10-14

## Released package and actual App results

PR #2641 merged as protected main
`c23de92d613e0280ded64e0da933c3193333b6e3`. A clean build of that exact source
includes the [ClientKit namespace and peer-token repair](windows-clientkit-peer-image-20261014-run.md).
The development-signed RC contains 365 verified files. Its ZIP SHA-256 is
`46774aaab99be290a15c59fa594c6ab34cb0c51269d5b81f2ed545e58109198e`;
the MSIX SHA-256 is
`d47a5459c7fc01d2979427b68512b713a164333de2ef9766418103179bea7e09`.
The existing development signer was reused. The producer's private CLI/App
smoke passed; the SDK symbol-tool warning did not prevent package creation.

All four actual CLI combinations passed health, default-timeout doctor,
service status, service verification and the complete unchanged 57-Job
inventory: matching xcopy, packaged CLI to xcopy Runtime, matching MSIX, and
xcopy CLI to packaged Runtime. Health precedes doctor, as in the previous
published attempt; no CLI timeout or identity check was relaxed.

| Actual installed App case | TRX result |
| --- | --- |
| Packaged App to xcopy Runtime | 1 passed, zero skips |
| Matching packaged App, English/Chinese Artifact capture readback | 5 passed, zero skips |
| Xcopy App to packaged Runtime | 1 passed, zero skips |

The previously failing reverse App now reads the real Overview doctor state.
These are actual App processes over the signed account Runtime, not an injected
test transport. They establish mixed-installation behavior for these exact
development package bytes on the existing account. They do not establish
production signing, clean-host acceptance, a higher-version MSIX update feed,
second-account/remote-host isolation, or a new device qualification.

## Expected restart refusal and retained harness failure

The xcopy caller's restart returned exit 69 with the expected replacement-image
refusal before stopping the Runtime. This service failure is plain stderr with
empty stdout. The local orchestration helper incorrectly tried to decode that
stdout as JSON, so the wrapper genuinely exited 1. Its raw output, exception,
failed wrapper result and failed `allWorkflowExitsZero` predicate are preserved.
The planned separate post-refusal doctor/status calls did not execute.

The `finally` cleanup subsequently ran the matching packaged CLI's normal
`runtime service uninstall`. Its published `stop_serving` path authenticates
the pipe, reads health, checks the live instance and Job preflight, then requests
the stop. The retained successful result names exactly the pre-refusal PID and
complete instance, including its start time, and records `stopEvent`, Job-owner
presence and a complete drain. Its journal starts after the refusal finishes.
This is an actual authenticated same-process observation after refusal, proving
that the refused replacement did not stop/restart its predecessor.

A separate read-only review checks those ordered records, all four CLI
combinations, all seven TRX results, the complete inventories and cleanup.
It verifies and retains hashes for all 49 raw inputs, unchanged before/after
review. Qualification uses these actual predicates and the immutable inputs;
it does not turn the failed wrapper into an exit-0 run or infer liveness from
an unverified instance file. No restart was replayed to repair a record.

## Restoration and trust cleanup

Registration and package removal exited 0. The original signed Runtime was
restored and all 57 complete Job items matched as full decoded records.
The user-confirmed temporary public trust was added at
`2026-10-14T00:55:45.991Z` and removed after the workflow. Both temporary
TrustedPeople locations and the test MSIX are absent; the pre-existing user
Root trust remains. No private signing key was exported.

After checking the actual qualification predicates and rechecking every input
hash, the 365-file release was staged and verified under the existing product
directory. Typed Runtime stop preceded the directory swap; the old signed App
was retained and the launcher was unchanged. The installed release's health
and service status pass, and all 57 complete Job items remain identical
(`clientkit-peer-final-install.json`).
The installed release then passed all five real App smoke/capture tests in
English and Chinese, with zero skips in 129 seconds. The complete 57-Job
inventory also remained identical after those UI reads
(`clientkit-peer-installed-readback.json`,
`uia-clientkit-peer-final/installed-clientkit-peer-final.trx`).

## Performance qualification

After App/build work finished and the user made the host idle, the fresh default
three-run capture passed a full 60.36-second admission: average busy CPUs
1.8261, threshold 4, and 30 process checks with zero build conflicts. Run 0
then stopped at the unchanged `cold-start-after` gate: `HostTooBusy`, measured
load 4.2146 against 4. The capture exited 1 after 17.81 seconds, completed no
run and is explicitly `baselineEligible: false`. Its two partial cold-start
samples do not establish a percentile or performance baseline. Private capture
state was removed and the raw observations remain retained under
`perf-capture-clientkit-peer-published` (capture
`bae3597b0c8b45bda5ad5bd90e50a543`). No threshold, default scale or deadline was
changed and no automatic capture retry was made.

A separate new full-duration soak started at `2026-10-14T01:09:47.702Z` after
another complete 60.40-second admission (busy CPUs 1.9038, threshold 4, 30
checks/zero build conflicts). It uses the released signed source above, a fresh
private state directory, 86,400 seconds, 300-second restart cycles and ten Jobs
per cycle, with unchanged request deadlines and resource limits. A passive
two-second host-load log records context only; it neither changes admission nor
excuses a timeout. The provider is simulated, so this is Runtime stability
qualification, not hardware evidence. This run is in progress under
`long-soak-clientkit-peer-released`; no full-duration pass is claimed. The
earlier #2639 deadline failure and its complete private state remain retained.

## Local targeted checks

Raw logs, TRX and derivations remain outside Git under
`D:/temp/arkdeck-windows-acceptance-20261013`.

- Released package build/sign/private smoke: exit 0
  (`package-clientkit-peer-released.log`, `rc-clientkit-peer-released`).
- Actual mixed workflow: registration 0, smoke 1 due solely to the retained
  JSON parsing failure above, removal 0 (`clientkit-peer-release-run.log`,
  `clientkit-peer-release-run.json`, `clientkit-peer-release-smoke`).
- Cleanup postflight: exit 1 only for `allWorkflowExitsZero`; all restoration,
  inventory and trust/package checks passed (`clientkit-peer-release-postflight.json`).
- Read-only retained-result review: exit 0, four CLI combinations, seven App
  passes/zero skips, actual same-instance restart refusal and all 49 input
  hashes verified (`clientkit-peer-retained-review.json`).
- Verified installation and actual installed App readback: both exit 0, all
  365 files checked, five UIA passes/zero skips, and all 57 complete Job items
  unchanged (`clientkit-peer-install-stage.log`,
  `clientkit-peer-install-promote.log`, `clientkit-peer-final-install.json`,
  `clientkit-peer-installed-readback.log`, `uia-clientkit-peer-final.log`).
- Released soak/probe tools built and signed: exit 0
  (`perf-clientkit-peer-released-tools/manifest.json`). Their Rust sources and
  executable hashes equal the preceding #2639 release; the ClientKit repair
  makes no claim to fix the previously retained control deadline.
- Default-scale performance capture: exit 1, `HostTooBusy` at the original
  phase gate; no completed run/baseline (`perf-capture-clientkit-peer-published`).
- New default 24-hour soak: admitted and running, no final exit or pass yet
  (`long-soak-clientkit-peer-released/admission.json`, `process.json`,
  `stdout.log`, `stderr.log`, `host-load.jsonl`).
- `bash scripts/check-sdd.sh` through the installed Git Bash: exit 0, zero
  errors/warnings and 121 acceptance IDs
  (`clientkit-published-acceptance-sdd.log`); `git diff --check`: exit 0.
  This increment changes documentation only, so no Rust/Swift compile tests,
  contract generation or complete local CI gate were run.

## CI

The released source #2641 passed Swift CI `38491006664`, including the selected
Windows solution build/tests and aggregate, and final SDD Guard `38491410502`.
The unaffected Rust, Swift and macOS App lanes were not selected. This
acceptance increment has its own docs-only current-head CI; source CI does not
stand in for its checks.
