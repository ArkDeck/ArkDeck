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
