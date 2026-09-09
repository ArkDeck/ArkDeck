# TASK-XPA-003 — execution record

Date: 2026-09-09. Base and fetched `origin/main`:
`2893280895b6d8a0520a9f9c4d274dcd52ed8f73` (#1827, r8).
Branch: `agent/xpa-003-macos-facade-20260909`.

## Scope exploration before #1828 (historical)

Implementation has not started. The requested existing helper build/install delivery
needs a packaging scope decision. The task status and its three r8 readiness pins
are unchanged. This record is not approval, verification, a completed implementation,
hardware evidence, or an implementation PR. No production service was changed.

The user explicitly requires stopping when implementation needs paths outside the
base task's Allowed paths. The existing local and release packaging entry points
are outside that list:

- `Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh`
- `Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh`

## Code facts and proposed minimal resolution

The local script, lines 86–88 and 105–120 at this base, builds only the Swift CLI
and Swift daemon, copies that daemon to `ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`,
then signs the helper and outer CLI bundle. The release script, lines 70–72 and
89–105, does the same before notarization and assessment. Neither has a Rust build,
paired daemon packaging step, or hook for one. Merely modifying LaunchAgentService
cannot supply a Rust executable absent from the artifacts those scripts produce.

`LaunchAgentService.install`, lines 398–484, consumes and validates one complete
helper bundle, copies it, and records its executable digest. A signed bundle carrying
both executables can preserve the CLI's existing single `--daemon` input for update
and the typed retained bundle input for initial install. Therefore this inspection
does **not** establish that `ArkDeckRuntimeCommands.swift` needs an Allowed-path
extension. Adding a second CLI flag is unnecessary for the proposed bundle shape.

The proposed packaging implementation is a shared builder under `rust/**`, called
by both existing helper scripts before signing. It would package the Rust facade
and same-release Swift helper together, retaining a standalone Swift rollback
artifact and the existing provisioning/notarization checks. Wiring those two
entry points requires the two paths above. A separate manual repackaging command
could produce an experimental bundle but would leave the user-specified build
command and the existing release pipeline producing Swift-only artifacts.

`LaunchAgentServiceContractTests.swift`, lines 229–272, explicitly consumes both
scripts and checks their build, resource, signature and release verification steps.
Tests for the paired packaging can remain in the already allowed contract-test
directory. No entitlement, admission, capability or storage extension is proposed.

This is a delivery-scope gap identified from the current code, not a change to the
architecture's conclusions. Requested maintainer resolution: authorize those two
packaging entry points in the protected-main TASK-XPA-003 scope before implementation.
The checker reads production authority from base; changing head's allowlist alone
does not authorize these files. The user subsequently requested a PR for this scope correction. This PR adds only
these two exact Allowed paths and this record; it does not exercise the proposed
new authority. Compatibility note: this separately requested scope decision follows
the user's explicit instruction; implementation remains one vertical delivery.

## Commands and results

- `git status --short`: exit 0, initially clean; HEAD initially detached at the base above.
- `git fetch origin main`: initial sandbox attempt exit 255 because FETCH_HEAD was
  not writable; controlled escalation exit 0. Fetched main equals the stated base.
- `git switch -c agent/xpa-003-macos-facade-20260909 origin/main`: exit 0.
- Read-only source/contract inspection: facts above; no build or device invocation.
- The following calls the actual checker on the two proposed paths without making
  a synthetic commit or changing either file. Exit 1, expected scope refusal:

```bash
python3 - <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, 'scripts')
import check_pr_paths as checker
repo = Path.cwd()
base = '2893280895b6d8a0520a9f9c4d274dcd52ed8f73'
context = checker.PullRequestContext(
    'Implement macOS facade (TASK-XPA-003)', 'Task: TASK-XPA-003',
    'agent/xpa-003-macos-facade-20260909', base, base)
paths = [
    'Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh',
    'Packages/ArkDeckKit/Distribution/macOS/build-helpers.sh',
]
try:
    checker.check_paths(repo, context, paths)
except checker.CheckError as error:
    print(error)
    sys.exit(1)
PY
```

Result: `declared task TASK-XPA-003 has paths outside Allowed paths` for both
scripts. The checker supplement permits new change/evidence namespaces, not an
extension of base-authorized production paths (`check_pr_paths.py`,
`vertical_change_supplement_patterns`). This probe is not the final committed-PR
preflight and is not an automatic approval-review rejection.

## Acceptance not executed

All items below remain pending because implementation stopped at packaging scope:

| Item | Result |
| --- | --- |
| XPA-AC-3, facade and Swift black-box subsets | Not run; no implementation build |
| XPA-AC-5, per-row IPC p95 versus SPK-1 | Not measured; no regression conclusion |
| XPA-AC-6, foreign euid, wrong XPC signature, private secret, forged origin | Not run |
| Per-frame foreground console and appXPC preservation | Not run |
| XPA-AC-7, before-forward kill window | Not run; no zero-dispatch claim |
| XPA-AC-7, after-forward/Swift interruption window | Not run; no journal/replay claim |
| XPA-AC-9, rollback, App Overview/History and CLI | Not run; no service update |
| GJ-1, GJ-2, GJ-3, GJ-4, GJ-5 | NOT_STARTED for this facade rerun; no Job IDs or new hardware result |
| SDD and unified local gate | Scope-PR validation recorded below; implementation acceptance remains pending |
| Final commit preflight and CI | Scope-PR results reported with the PR; no implementation acceptance claim |

Existing Swift/SPK-2 results are not reused as facade acceptance. No new
`gj-headless-rerun` JSON was written. GJ-4 additionally still requires the user's
explicit go before opening the destructive campaign window.

## Residual ownership and maintainer decisions

- TASK-XPA-003: packaging scope resolution, then all implementation and acceptance
  above. No TASK-XPA-012 or Windows work started.
- Design L.1 item 3: whether release signing requirements add the Developer ID
  intermediate certificate clause remains for the maintainer. The intended
  implementation uses the SPK-2 production-shaped anchor/team/identifier requirement.
- L.1 items 6 and 17: preserve App entitlements and the stated same-user boundary;
  no alternative trust model is proposed.

## Scope PR validation

- `sh scripts/check-sdd.sh`: exit 0; 0 errors, 0 warnings, 121 acceptance IDs.
  The existing primary-checkout SDD environment satisfied the dependency pins;
  no bootstrap or dependency installation was necessary.
- `python3 scripts/ci/plan.py --repo-root . --base-revision origin/main --head-revision HEAD --merge-base --include-worktree --run-local`:
  exit 0. Both documentation files were classified; public checks passed.
  Swift, App, design-system and Rust build lanes were not selected for this diff.
- The final committed scope diff is checked again before push. Its preflight and
  hosted check results are reported on the PR; the earlier expected refusal above
  concerns hypothetical script modifications, which this PR does not contain.


## Implementation run after #1828

Base: `62d5cffd00f968e410f56e8ead7f0b51454f69b7` (protected main, #1828).
Branch: `agent/xpa-003-facade-implementation-20260909`.
Status: in-progress. This section supersedes the earlier “implementation has not
started” scope exploration; it does not claim acceptance or approval.

Implemented so far:

- Rust facade forwards original request/response bytes, with single-v1 request
  validation, bounded frames, no response cache or retry and no Runtime owner.
- macOS peer euid/PID and foreground terminal checks follow the current Swift
  kernel-fact chain. Raw libxpc uses the SPK-2 anchor/team/identifier requirement.
- Swift private socket accepts an ephemeral pipe-delivered pairing secret and
  checks each origin's frame SHA-256. `appXPC` still traverses the existing
  `AgentXPCEndpoint` allowlist and shared App Job gate; handler/admission code is
  unchanged. Parent pipe EOF goes through the existing shutdown/drain path.
- Swift Mach listener and App transport both use raw libxpc. App uses persistent
  serial channels (ordinary reads and long job.run), pins server signing/release
  identity, revalidates health, and never resends an interrupted request.
- Existing helper scripts build/sign the facade sibling and keep a same-release
  standalone Swift rollback bundle. LaunchAgent selects the facade when present,
  pins Swift bytes separately in its environment, and retains Swift's credential
  and analyzer identity. No install receipt schema or Runtime record field changed.

Host checks completed (all hardware-independent):

| Command / check | Exit | Result and limits |
| --- | --- | --- |
| `cargo +1.98.0 clippy --workspace --all-targets -- -D warnings` from rust | 0 | Workspace passed at the checked source revision; final gate follows |
| `cargo +1.98.0 test -p arkdeck-platform -p arkdeck-contract -p arkdeck-client` | 0 with host permission | Initial sandbox run refused UDS bind with EPERM; rerun passed |
| `swift test --package-path Packages/ArkDeckKit -j 4 --filter 'AgentFacadeContractTests|AgentXPCTransportContractTests|LaunchAgentServiceContractTests'` | 0 | 41 tests, zero failures |
| `ARKDECK_DAEMON_UNDER_TEST=<Swift build> swift test ... --filter AgentDaemonContractTests.testExternalDaemonSingleV1Contract` | 0 | Identical external-process single-v1 subset against Swift |
| `ARKDECK_DAEMON_UNDER_TEST=<Rust build> ARKDECK_SWIFT_DAEMON=<Swift build> swift test ... --filter 'AgentDaemonContractTests.testExternalDaemonSingleV1Contract|AgentDaemonContractTests.testPrivateSocketRejectsMissingPairingAndOriginDigestMismatch'` | 0 | Two tests passed: actual facade/Swift forwarding plus actual private socket missing-secret/digest refusal |
| `ARKDECK_DAEMON_UNDER_TEST=<Rust build> python3 rust/scripts/test-macos-facade.py` | 0 | Six host fixture tests: exact bytes and digest, forged public origin refusal, kill before complete frame, kill after forward, dead socket restart, foreground versus redirected stdin |
| `bash Packages/ArkDeckKit/Distribution/macOS/build-local-helpers.sh` with the existing provision profiles and `/private/tmp/xpa003-signed-helpers-20260909` output | 0 | Both paired and rollback helpers built and signed; strict deep signature verification passed. Local development build, not notarized |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings, 121 acceptance IDs |

Observed differences from assumptions:

- Foundation resolves `/private/tmp` to `/tmp` on this host. Comparing the URL's
  resolved path text rejected a valid private socket directory; the private
  listener now checks libc `realpath`, directory type, euid and 0700 permissions.
- App XPC admission is narrower than `RuntimeControlPlaneHandler`: forwarding
  `appXPC` directly to the latter would bypass the App Job gate. The adapter
  therefore invokes the unchanged App endpoint on the Swift side.
- Native release matching uses signed CFBundleShortVersionString/CFBundleVersion,
  alongside the signing identifier/team; same-version development revisions are
  not distinguished by those version fields. The installation separately checks
  exact configured executable hashes. This limitation must be retained in review.
- Design J.4's historical absolute IPC wording differs from the tasks.md criterion;
  the implementation acceptance remains the task's per-row +20% SPK-1 limit.

Outstanding validation, owned by TASK-XPA-003:

- Signed actual Mach-service matrix (facade and same-release Swift), wrong-signature
  probes, updated App Overview/History smoke, and product-command rollback.
- SPK-1 per-row release IPC comparisons; no p95 acceptance claim yet.
- Actual Swift Job/journal post-forward crash/read-back and no duplicate Job proof.
  The six fixture tests above prove transport behavior only, not durable Runtime
  or hardware acceptance. The before-forward test kills an incomplete public
  frame; it is not the separate after-validation-before-write kill window.
- Full interactive human-action.resume challenge/reason matrix; the terminal
  test above proves kernel origin propagation only.
- Foreign-euid host proof, all final local gates, final commit preflight and CI.
- GJ-1..5 are NOT_STARTED for this facade rerun, with no new Job IDs or hardware
  result. GJ-4 still needs explicit go. No XPA-012 or Windows work was started.

## Authorized signed-service test and restoration

The user explicitly authorized temporary installation, testing and restoration
(`授权临时安装、测试和恢复`) after the earlier automatic review refusals.
No device operation was executed. Typed pre-install readbacks showed 43 Jobs
(35 succeeded, 4 failed, 1 recovered, 3 waitingForRecovery; none running).

Commands used the signed local helper CLI and `--output json`:

| Command / check | Exit | Observed result |
| --- | --- | --- |
| `runtime service update --daemon <signed pair>/ArkDeckAgent.app` | 0 | Receipt pointed to arkdeck-facade, SHA-256 `47163ce6db598bbcc432365e658f4925eb83dae88ad496bc9525a85105ea3713` |
| Signed App-identity raw XPC health probe, 1000 requested samples | 69 | Timeout, 0 samples; not a latency result |
| `runtime service status` | 0 | ready=false, socket_absent; error log repeatedly reported Swift authority failed to start |
| `runtime service update --daemon <same-release rollback>/ArkDeckAgent.app` | 0 | Swift rollback installed |
| Signed App-identity raw XPC health probe against rollback | 69 | Timeout, 0 samples; rollback communication NOT passed |
| `runtime service update --daemon <retained main-6e8c3ed5>/ArkDeckAgent.app` | 0 | Original executable restored |
| Repeated `runtime service status` after launchd retries | 0 | Original SHA-256 confirmed, but ready=false/socket_absent persisted |

Original/restored SHA-256:
`02d685a01a51c36dfc69a751aa4bdc7c38b5ab9971c032aba44cbb64f216392b`.
The latest daemon log repeatedly reports
`serverDidNotBecomeReady("managed HDC launch identity was not retained")`.
The throw site is `HeadlessHDCServerHost.startInternal`, after readiness returns
without a retained spawn identity. Its root cause is not established. This file
is outside TASK-XPA-003 Allowed paths; it was not modified. No raw HDC process
intervention, Runtime state edit, capability change or device dispatch occurred.

This is BLOCKED_BY_PRODUCT_DEFECT for the service startup path. The original
binary/configuration is restored, but service health is NOT restored. Signed
pair/rollback acceptance and all GJ runs are stopped; no implementation PR is
published as releasable. The probe is not an actual App UI smoke, and does not
prove a signing rejection or specifically diagnose libxpc. TASK-XPA-003 retains
transport/rollback validation ownership; HDC startup remediation requires a
separately scoped owning task (not assigned here).

The signed test package predates later socket bind ordering/bounds and private
directory cleanup edits; those later edits have not been signed-service tested.

## Implementation gate failure

The unified gate exited 1 in the full Swift lane. Public checks and 83 design
system tests passed. The external API consumer baseline failed because adding
a defaulted fourth initializer argument removed the exact public
`AgentDaemonServer.init(stateDirectory:handler:nowUTC:)` function reference.
The original three-argument initializer has now been restored as a convenience
overload. `sh Packages/ArkDeckKit/Scripts/run-test-lane.sh focus APIBaselineGateContractTests`
passed (exit 0, one external-consumer test, 31 seconds) after that fix. The overall
unified gate, App build lane, final commit preflight and hosted CI have not passed
for the final working tree. No tests or baselines were weakened.

Maintainer decision remains L.1 item 3: whether release adds the Developer ID
intermediate certificate requirement. It has not been added unilaterally.


## Complete scope survey and continuation after #1829

The revised task instruction requires one complete implementation PR, only after
all deliverables/acceptance and GJ-1..5 pass; no intermediate implementation PR
will be published. GJ-4 still requires explicit go immediately before its window.

`scope-probe.json` lists 41 existing/anticipated paths, including both packaging
entry points, LaunchAgent, Swift private listener, raw XPC server/client,
contract tests, App transport composition, and Rust modules/tooling. The current
design extends existing crates; it does not require a new crate. New files under
`rust/**` are covered by that glob. The base-tree checker found 39 authorized
paths and two gaps at `62d5cffd`: `HeadlessHDCServerHost.swift` and
`ArkDeckAppUITests/AppShell/FacadeRollbackUITests.swift`.

Governance PR #1829 (`Scope facade rollback smoke and bounded HDC lifecycle repair`)
changed only tasks.md (13 added lines). SDD: exit 0, 0 errors/warnings, 121 AC IDs;
unified documentation gate: exit 0; committed preflight: exit 0 (`none`). The bot
created an open, non-draft PR; title/body/files were read back, required hosted
checks passed, and the maintainer merged it as
`f887851099897f4c0fcf9a31f64b6de7a5553a02`. The implementation was saved in a local
commit, rebased onto that protected-main commit, and all 41 paths passed the
base-tree checker again. That local implementation commit has not been pushed.

The second unified implementation run passed the full Swift lanes (2527 parallel
tests, one serialized process-identity test, five Viewer scale tests) and App
build-for-testing, then failed at Rust's Python import because jsonschema was
missing. A temporary venv now has the same CI pins, PyYAML 6.0.3 and jsonschema
4.26.0; no system Python or dependency declaration changed. The third full gate
is running with that environment and the subsequent lifecycle change.

`AgentFacadeContractTests.testForwardedSubmitSurvivesFacadeDeathWithoutReplay`
now uses the actual Swift daemon and durable store in an isolated temporary
fixture directory. A transport-only barrier holds Swift's committed submit reply;
the test kills the facade, restarts the normal Swift executable on that same
store, reads job.status/job.list, and explicitly resubmits the same idempotency
key. It observed one Job and a deduplicated acceptance of the same Job. The
forwarded interruption carried no zero-dispatch proof. Focused suite: exit 0,
three tests. Seed Artifact contents are fixture data; this is host contract
validation, not hardware acceptance or a device Job run.

Further startup diagnosis found one surviving Bootstrap HDC listener at 8710:
PID 33562, parent 1, start 2026-09-09 20:22:46 local, executable SHA-256
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`, exact argv
`-s 127.0.0.1:8710 -m`. No raw HDC command or process termination was performed.
The original blanket error was refined to retain the closed exit/capture outcome;
new attempts reported foreground exit status 0. This does not grant ownership of
the surviving PID. A narrowly identified manual recovery exception was requested
because the runbook explicitly forbids manual intervention; it is not assumed.

Code inspection found SIGTERM handling was installed only after startup completed.
The pending fix installs it before owned children start, cancels and awaits the
startup task, and then uses the existing drain/child-stop path. Private pairing is
consumed before composition, so facade death can also signal cleanup during
startup. No handler, Supervisor admission, capability or identity requirement was
relaxed. The daemon build passed; a cold-start fixture cancellation test and the
full gate are being run. The surviving process's exact cause is not proven merely
by finding this signal-window defect.

## Read-performance scope proposal and current checks

Release comparison (`ipc-release-comparison.json`) failed AC-5; the standalone
Swift backend already exceeds the original SPK-1 job.status/job.list p95 by
approximately 256%/196%. Sampling identifies persisted-record decode work in
read projections. The maintainer authorized a separate minimal scope proposal.
PR #1830, `Scope bounded persisted-record decoding reuse for read projections`,
is open and non-draft at `8bfcf1eb`, based on protected main `f8878510`. It changes
only tasks.md (13 additions, one deletion); no implementation is included.
SDD (0 errors/warnings, 121 AC IDs), the documentation unified gate, committed
path preflight and all applicable hosted checks passed. Its scope exception is
not active until maintainer merge. The original SPK-1 baseline and +20% threshold
are unchanged; no performance pass is claimed.

The fourth complete implementation gate exited 0: full Swift lanes, App
build-for-testing, design-system checks, Rust published/candidate contract
checks, cargo deny and cargo vet (25 fully audited). This includes the startup
cancellation and vectored-write changes. Six transport fault fixtures and
workspace clippy also passed. The subsequently added opt-in
`FacadeRollbackUITests` is being compiled separately and has not run against
either installed backend. The final committed gate remains required.

The exact identified orphan HDC process did not exit after the separately
authorized SIGTERM. A SIGKILL exception for that same re-verified identity is
pending; it has not been assumed. Original daemon restoration therefore still
does not establish healthy service. No GJ or device dispatch has run in this
window. The implementation remains local and will not be pushed as a partial PR.

PR #1830 was subsequently merged by the maintainer as
`fc8263bdd36893383346ef170b309a4e175568ed`. The local implementation was rebased
onto that commit. All 44 anticipated paths pass the base-tree scope probe.
The approved optimization now touches only the two job.status/job.list read
projection decode call sites, with at most 128 decoded records and 2 MiB of
retained source bytes. Every lookup still reads current storage bytes, compares
exactly, and performs the existing row coherence and fresh status checks.
Mutation callers and the shared decoder remain unchanged.

JobReadResourcesContractTests passed 26 tests (exit 0); new cases cover changed
bytes, warm-cache row metadata mismatch, corrupt bytes, restoration, and reads
after a working set exceeding cache capacity. The first test run caught an
incorrect new test expectation for the existing inline timeline envelope; only
that expectation was corrected. The release IPC remeasurement is pending.

The actual App and new smoke suite compiled and signed successfully through
`run-ui-tests.sh --build-once` with Developer ID identity and manual signing
overrides (exit 0). An earlier invocation omitted the manual override and failed
Xcode's Swift-package signing configuration checks; no project or entitlement
change was needed. No live UI smoke result is claimed yet. Signed helper build
r5 also passed, but predates the read-projection optimization.

## Origin and performance follow-up

Typed private-origin decoding avoids speculative JSONValue scalar decoding while
retaining the strict duplicate validator, exact keys/types, UID/PID checks, and
frame SHA-256 equality. Rust now serializes typed origin metadata directly,
without allocating an intermediate JSON dictionary. Client bytes are unchanged.
Six release facade transport fixtures passed. With both external executable
environment variables explicitly set, AgentFacadeContractTests passed all four
tests, including both actual Swift durable-store crash/readback cases (11 s).
The earlier four-test discovery without those variables is not evidence for the
two optional external-process cases.

HDCControlActionContractTests passed 20 tests with the release facade explicitly
selected. The new test runs a real Swift private listener/handler behind facade
origin forwarding: foreground PTY gets interactiveConsole, redirected stdin
retains the HAR and its original reasonCode, and dispatchCount remains zero.
The child only transfers ephemeral test pairing, which is removed immediately;
this is an isolated host contract and never hardware evidence.

AC-5 remains FAILED. The typed Swift-origin run measured facade health/job.list/
job.status p95 at 0.137625/12.656083/0.339791 ms (+22.83%/-2.82%/-7.19%). After
typed Rust encoding the three-run medians were 0.156000/13.924334/0.423708 ms
(+39.23%/+6.92%/+15.73%); one run had a large latency spike, and host load
subsequently exceeded the quiet threshold. Both results are retained in
`ipc-release-comparison.json`; no successful latency result is substituted.
The measurement tool now reports the original baseline's p95 spread/stability
criterion as well as its unchanged +20% threshold. A stable quiet-host result
is still required. No further acceptance performance run is currently active.

The foreign-euid fixture launches an administrator-authenticated executable that
only connects to its isolated UDS and attempts one health frame, then checks zero
forwarding and continued same-uid service. Compilation succeeded, but macOS
authentication did not complete within 120 seconds (exit 1/TimeoutExpired). The
fixture was cleaned up; AC-6 foreign-euid rejection is NOT passed. This test
does not signal the installed HDC process or alter Runtime state.

## Current local checkpoint (not implementation delivery)

Protected base: `fc8263bdd36893383346ef170b309a4e175568ed`. Local source commit:
`0eb8a45c42dc8c64fb25f21e6daf09050534d5ab`. No implementation branch push or
implementation PR has occurred. The complete 46-path probe and committed
preflight pass for TASK-XPA-003.

The fifth unified gate on that commit exited 0: common/SDD checks, design-system
checks, full Swift lanes (2534 selected parallel cases plus serialized identity
and Viewer-scale lanes), App build-for-testing, Rust published/candidate
contracts, cargo deny, and cargo vet (25 fully audited). Optional external cases
are validated separately with their required environment variables. The latest
release Swift and facade each passed the identical external single-v1 subset
(exit 0, one case per backend). This final checkpoint text was added after that
gate; it does not change the tested source.

The signed App/UI-test build was refreshed at the same source commit and passed
(exit 0) through the UI wrapper's build-only mode. The r6 signed helper build
also passed, including strict signature verification, and is retained at
`/private/tmp/xpa003-signed-helpers-r6`. It has not been installed. Its executable
SHA-256 values are:

- cli: `c75ca1ceb8fbb91d1b6af581f66d41c9e4a0b2f3efc6695f9902ef13e9bf9b63`
- facade: `a46120dddaaf7ab4906ae846f99335de0471c329b8d5ed48eacf906a7ab7ace2`
- pairedSwift: `abb37651e945c5c7d294b852ac5452a7df01621b0f3b2bc568cf36189a5fa013`
- rollbackSwift: `65d8e45fb903cb2021b88124390fcf561980414b48f888e7064ee05c88989767`

A fresh service status identified the earlier diagnostic Swift rollback
(`19839d9…`) as still installed. The authorized temporary-test cleanup has now
restored the original main-6e8c3ed5 helper again via `runtime service update`
(exit 0). Readback confirms SHA-256
`02d685a01a51c36dfc69a751aa4bdc7c38b5ab9971c032aba44cbb64f216392b`,
installed=true and loaded=true, but ready=false/socketPresent=false. The same
PID 33562 (parent 1, UID 501, start 2026-09-09 20:22:46) still listens on
127.0.0.1:8710. No SIGKILL was sent; the exact-process exception remains pending.
Restoring the original binary is not a service-health pass.

Remaining TASK-XPA-003 acceptance: stable AC-5 within +20% for every facade row;
foreign-euid OS-authenticated test; live signed XPC peer-negative and release
mismatch checks; live App Overview/History rollback and headless drill; and
GJ-1..5. All five GJs remain NOT_STARTED, with zero device dispatch in this
window. GJ-4 has no go and no campaign window was opened. L.1 item 3 remains a
maintainer decision; no Developer ID intermediate-certificate clause was added.


## Maintainer decisions and resumed installed acceptance

The maintainer accepted the four proposed decisions: identity-rechecked SIGKILL
of the specific orphan HDC process, retry of the OS-authenticated foreign-euid
probe, retaining the +20% per-row performance gate, and retaining the SPK-2
anchor/team/identifier requirement without an extra Developer ID intermediate
clause. L.1 item 3 is therefore resolved for this implementation.

The exact orphan UID, birth time, executable arguments and SHA-256 were rechecked
before SIGKILL. Original helper service health then returned ready with a public
socket. The OS-authenticated foreign-euid fixture passed: root connected but was
denied, zero frames were forwarded, and the same-UID client remained served.
This is host transport evidence, not hardware evidence.

The r6 signed facade pair was installed through `runtime service update`; status
confirmed ready and facade SHA-256
`a46120dddaaf7ab4906ae846f99335de0471c329b8d5ed48eacf906a7ab7ace2`.
The fresh signed raw-XPC probe passed four live contract cases (health, forged
public origin rejection, and appXPC job.run/job.cancel denials). The wrong App
identifier and ad-hoc signature were rejected with zero completed requests;
a wrong server version was rejected as Peer Forbidden. The correctly signed
client completed all eleven health requests. Raw local outputs are
`/tmp/xpa003-r6-xpc-contract.json` and `/tmp/xpa003-r6-xpc-security.json`.

Deep doctor exited 0: ready=true, zero blockers, current Catalog digest
`508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684`,
28/30 operations available with the hardware campaign closed. Warnings concern
two gated operations and the pre-existing unpublished Session output owner.
App smoke, same-release rollback, stable IPC and GJ reruns remain in progress.


### r6 headless device progress and App startup limitation

Raw outputs are under `/private/tmp/xpa003-gj-20260909/`. GJ-1 observe
`job-57778758636d39059197893ac5ededac` and device-level diagnostics
`job-cdb2c3027f13febb2734ba41d29d3556` succeeded, with no unknown/blocker.
All nine published artifacts were read in full and SHA-256 matched. HiLog is
593170 bytes and UI Dump 1489 bytes; capture completeness is complete with no
missing required artifacts. Restart persistence and physical HAR remain pending.

GJ-2 `job-926c285a066a01f983715e1aff752c01` succeeded with no unknown/blocker
and zero residue. The current Catalog's debug.hap captures HiLog only; compatible
composition uses the existing capture.diagnostics operation for the runbook's
UI Dump/Trace legs. The retained app installation used GJ-3 preflight Job
`job-42c140aba1b99dc0aa42d429dcfccc44`. App-scoped capture
`job-b0670f13d7b68ef633cafd4e027350b8` succeeded: HiLog 645294 bytes, UI Dump
1590 bytes, Trace 10623 bytes, all read and digest checked. Capture summary is
complete, with no missing required artifact. No Catalog/Provider change was made.

GJ-3 positive `job-f9d67b75275f379bc0dc6ca80ed20d60` succeeded. The fixed signed
rollback fixture SHA-256 is
`260a533ae2b02e23810aa5ab6ea9c1a5cf4524b19484ede66cb4dc0b7bb86d3a`, matching
the earlier fixture. Negative Job `job-e03ee1e514da224c9d48a8ceba5f9b84` failed
at start-target after atomic publication. Its typed job.show timeline explicitly
verifies rollback-native-library [processIds, restored, restoredSha256], then
verifies compensation cleanup. outcomeUnknown=false, outstandingResidueCount=0.
The agent evidence projection retains artifactIntegrityFailed and CLI exits 2;
this is recorded without relabeling the failed Job or inventing an artifact.

Signed App smoke failed twice before establishing the test-runner connection;
no test assertion ran. Initial runner sample was blocked in _libsecinit_appsandbox.
The retry used the required TEST_RUNNER_ parameter prefix and the same wrapper.
Results: `/tmp/xpa003-r6-facade-ui.log`,
`/tmp/xpa003-r6-facade-ui-retry.log`; xcresults are in
`/private/tmp/xpa003-ui-derived/Logs/Test/`. Host permission information has been
requested from the maintainer; the one bootstrap retry is exhausted.


### AC-5 quiet-host pass and standalone Swift rollback

The complete six-run Release instrument exited 0. The median facade p95 rows
are health 0.132959 ms (+18.6689%), job.list 12.626667 ms (-3.0446%), and
job.status 0.337667 ms (-7.7727%). All three meet the unchanged +20% gate and
SPK-1's unchanged 30% p95-spread criterion. Each row has 1000 samples per run;
page size is 50 with exactly 30 seeded Jobs. The run and raw-sample hash are
retained as quietHostFollowUp in ipc-release-comparison.json; previous failures
remain intact. No further transport optimization was introduced for this pass.
Raw output: `/tmp/xpa003-release-ipc-quiet-r6.json`; log exit 0.

Standalone same-release Swift rollback via runtime service update exited 0,
ready=true, diagnostics empty, daemon SHA-256
`65d8e45fb903cb2021b88124390fcf561980414b48f888e7064ee05c88989767`.
The same signed real-XPC four-case contract probe passed. Updated CLI job.show
and job.result for both GJ-1 Jobs succeeded after this daemon restart, preserving
their original evidence. The App presentation portion remains unexecuted because
of the host runner startup failure described above.


### Completed device legs and GJ-5 refusal-proof gap

GJ-2 and GJ-3 now have complete composed headless results recorded in
`docs/design/references/single-v1/gj-headless-rerun-2026-09-09-xpa003.json`.
Post-rollback diagnostics Job `job-4a567048cd0c07668c00b6ac27330e51` confirms
HEALTHY/targetProcessRunning; every published artifact was read and hashed.
Final typed debug.hap Job `job-107aa51a31ba79b48c113a591a21a222` stopped and
uninstalled the retained test application and cleaned staging. This existing
operation also performs its ordinary install path; no raw cleanup command was used.

GJ-5 reproduced exactly one additional crash (index 6 -> 7), obtained an answered
signature, applied the fixed patch to an isolated workspace, built/signed/deployed
matching bytes, then observed HEALTHY with the index still 7. All positive Jobs
succeeded without unknown outcomes. The initial driver read the analyzer's status
from the wrong level; inspection found result.status=answered, and continuation
started from completed analysis without repeating deployment, capture or analysis.

The stale-revision negative exited 77/admissionDenied with the complete 62-Job
sets equal, but the error contains no phase/newDispatchCount proof and loses the
specific refusal reason. Source inspection confirms the .rejected branch in
AgentExecutionCoordinator.drive commits failed/admissionDenied and returns only
the execution projection after acceptedJobForAgent returns nil. GJ-5 remains
BLOCKED_BY_PRODUCT_DEFECT until this published headless refusal path preserves
its owner proof; ledger equality alone is not counted as acceptance.

Scope PR #1831 (single tasks.md, fb807ccc) requests only that refusal projection
repair. SDD, the unified local gate and path preflight passed before push; the
bot-created PR is open and ready for review. No production source outside the
existing Allowed paths has been changed. An allowed-path regression test
reproduces the three missing assertions (reason, phase, zero-dispatch count);
the paired post-admission interruption test passes and confirms no fabricated
proof. Full implementation completion remains pending, not a partial PR.

Restoring the UI runner's default ad-hoc signature did not resolve its startup
hang; that run also failed before assertions after 353.8 seconds. The signed App
and its entitlements were untouched. Raw log:
`/tmp/xpa003-r6-swift-ui-adhoc-runner.log`. The r6 facade pair is again installed
and healthy. GJ-1 physical HAR and GJ-4 separate GO are requested; no flash campaign
has been opened. The 730783514-byte archive matches its required SHA-256.


### Waiting checkpoint

PR #1831 exact-head CI is green (fb807ccc4d9fc13e41509b64e65c05aa5c338eeb),
with maintainer review still required. Updated acceptance records pass SDD and
diff whitespace checks. The newly added refusal-proof regression intentionally
fails before the scoped fix; the interrupted-admission receipt test passes.
No complete implementation PR has been published and TASK-XPA-003 stays in progress.

While awaiting maintainer and physical actions, the original protected-main
6e8c3ed5 helper was restored through runtime service update. Fresh status:
ready=true, loaded=true, socketPresent=true, diagnostics=[], health=ok, daemon
SHA-256 `02d685a01a51c36dfc69a751aa4bdc7c38b5ab9971c032aba44cbb64f216392b`.
The flash campaign remains closed. Local status file:
`/tmp/xpa003-original-restored-after-acceptance-status.json`.


### Refusal proof repair after scope approval (r7)

Maintainer merged PR #1831 as `d4e68f2e74b5f94f1791d2c57aaca5871f766fd6`.
The implementation branch now includes that approval. The scoped Coordinator
repair keeps the existing terminal commit and no-accepted-Job check, then forwards
the original typed refusal reason with the owner's preAdmission/zero-dispatch
proof. Admission, dispatch, retries and persistence formats are unchanged.

All 29 RuntimeAgentExecutionContractTests pass, including the regression that
failed before repair and the post-admission interruption case that must not claim
zero dispatch. Log: `/private/tmp/xpa003-refusal-proof-after-fix.log`.

The signed r7 facade/Swift pair was temporarily installed using the typed service
update. The existing GJ-5 isolated workspace was submitted once with its stale
revision under fresh execution `gj5-xpa003-20260909-patch-stale-r7`. Result: exit 77,
admissionDenied, original workspace.revisionConflict reason, phase=preAdmission,
newDispatchCount=0. Complete before/after ledgers are equal (62 Jobs), and durable
readback is failed/admissionDenied, jobId=null, outcomeUnknown=false. Local raw
outputs: `/private/tmp/xpa003-gj-20260909/gj5/refusal-r7/`. The positive GJ-5 chain
remains the r6 run; only the affected refusal path was rerun. The same published
Catalog digest applies. GJ-5 is now REAL_DEVICE_PASS; prior failure is retained in
the metadata as previousNegative/resolvedBlocker.

The original protected-main 6e8c3ed5 Runtime was restored after this test. Status is
ready=true, loaded=true, diagnostics=[]; the new terminal execution remains
readable after restoration. GJ-1 physical HAR, GJ-4 separate GO and the host UI
runner startup issue remain outstanding. No flash campaign or device dispatch was
introduced by this refusal retest.


Final local validation (2026-09-10): the complete 38-file diff passes the unified
CI planner (exit 0), including common checks, full Swift tests, App
build-for-testing, Rust tests/contracts and dependency audit. Log:
`/private/tmp/xpa003-r7-unified-gate-final.log`. Run with the existing
`/private/tmp/xpa003-ci-venv` on PATH and ARKDECK_PYTHON set to its interpreter.
Two earlier invocations reached the Rust Python checks but failed because their
interpreters lacked jsonschema; the final invocation used verified dependencies.
UI assertions remain unexecuted because of the previously recorded runner startup
failure, and are not implied by the successful App build.
