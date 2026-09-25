# Workspace build and sign on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now executes `workspace.build-openharmony@1` and
`workspace.sign-openharmony-hap@1`, the build and sign legs of the GJ-5 repair
loop. A build runs a registered Hvigor preset on a Runtime-owned isolated copy
under the capability the Runtime issues for that copy, lands the unsigned HAP
and publishes it with the build log; a build of a person's primary tree is
refused before admission. A signing Job signs an unsigned HAP with a signing
preset registered for the project, answers the signer's two password prompts
on a pseudo-terminal, reads the product back with `verify-app` and publishes
the signed HAP and its report. An outcome that cannot be read back parks the
Job; a parked build is reconciled without a readback and never resent, a
parked signing Job is reconciled by reading its own attempt back and is never
signed again. Two new Swift oracles, 22 and 19 frames, replay byte for byte
with the published products, the capability store, the credential owner's
ledger and every parked record.

Base: protected `main` `c588ccd7` (#2152).

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The workspace project and preset owner and the DevEco pins (#1989, #2056, #2073, #2076); `workspace.prepare-isolated-copy@1`, copy adoption and the workspace-subject issuance rule (#2094, #2145); `workspace.apply-patch@1` and `workspace.revert-patch@1` (#2146); SPK-10's signing crate (#2031) | The two Swift oracles; plan, admission, run, reconcile and result of build and sign; registered Hvigor presets resolved through their exact DevEco pin; the landing of a copy's product; the signing credential owner, its ledger and the preset store's credential pins; registered signing presets composed at start-up; the production composition of signing | The other eight `workspace.*` operations (slice 13); the preset `configurationStatus` and `operation.list` availability projections; the development seams a fake GJ-5 rehearsal of build and sign needs (proposed in `gj5-fake-rehearsal-2026-09-25.md`, pending a maintainer ruling); GJ-5 on a device |

## The oracles

Both drive Swift's production control plane (`RuntimeControlPlaneHandler`
over a `RuntimeJobEngine` whose only provider is `WorkspaceOperationsProvider`,
in the daemon's composition order) over a fixed root and clock, and record
into `rust/tests/fixtures/`.

`WorkspaceBuildOracleContractTests` (`workspace-build-oracle/`), 22 frames:
the copy made; a preset the profile does not declare and a stale
`expectedWorkspaceRevision`, both refused by name with zero dispatch; a build
of the copy under a Runtime-issued capability (`build.log` and `unsigned.hap`
published); a module the project does not declare (the Job fails and still
publishes its log); the primary tree planned but refused at submit, without a
capability and naming one the Runtime never issued (`admissionDenied`); a
receipt lost after the child ran (parked, reconciled without a readback, run
again refused, `resultNotReady`, the same build refused while its use is
unsettled). Kept: the published products, the capability store's checkpoint
and ledger, the parked Job's record. `node.sh` stands in for the Node launcher
a registered DevEco toolchain pins and `hvigorw.js` for its Hvigor script,
pinned as the preset's verified resource; the stand-in never builds anything,
it writes a ZIP-headed product naming the module's sources and echoes
`DEVECO_SDK_HOME` into the log.

`WorkspaceSignOracleContractTests` (`workspace-sign-oracle/`), 19 frames: an
unregistered preset and an input that is not a ZIP container, both refused
before admission; a HAP signed, verified, recorded and published with its
source's binding; a signer that rejects the password (parked, reconciled as
not executed, failed); a signer that echoes a password (the same, as a
privacy failure); a verification that fails once after the signer ran
(parked, reconciled by verifying the product again, resumed to success, never
signed again). Kept: the signed HAPs and reports, the credential owner's
ledger, the two parked records. `hap-signer.sh` stands in for the Java
launcher the preset pins, follows `ArkDeckFakeHapSignerFixture`'s protocol
(both passwords asked for on the terminal and never printed) and reads its
mode from the HAP it is given; both passwords are fixed fakes held in memory.

Each recording ran once and then in verify mode, byte for byte. Every frame
validates against the published method schemas, so no contract input changes.

## Swift, as ported

**Build — plan.** The provider's preamble (the profile the request names, the
operation available for it, the stated revision enforced over the profile's
scope), then the build preset the profile declares. A registered project's
Hvigor presets are composed at start-up from the preset store: each preset's
exact DevEco pin resolved by the bootstrap registry for that preset
(`DevEcoRegistryStore::resolve`, the record re-measured, nothing written) into
Node running the pinned `hvigorw.js` with the preset's closed argv, every file
the record pins a verified resource, and `DEVECO_SDK_HOME` for that Node's
children. A preset that does not resolve is not applied, and a Job naming it
is refused until the Runtime restarts, as Swift refuses it. The plan binds the
executable's digest, the argv, the timeout and the resources.

**Build — admission and run.** `deviceMutation` on the workspace subject: a
Runtime-owned copy is issued the Runtime's own capability (the #2145 rule,
unchanged); the primary tree is refused (below). The run consumes the use
before its intent, takes the workspace composition's mutation lane, persists
the typed action, and dispatches the pinned executable with every verified
resource opened by its digest and held while the child runs (a resource that
changed or lost its execute permission refuses the dispatch). A copy's product
lands at the preset's product path: the landing is prepared (owner-only, a
stale product removed), inspected after the child whatever its exit (a
regular file, 64 MiB, ZIP magic), published as `unsigned.hap` with the log,
then removed from the copy, since the store owns the bytes. A non-zero exit
fails the Job with its log published.

**Build — reconcile.** As for a patch: the persisted typed action
materialized, then `mutation has no dedicated readback; original not resent`.
The Job stays `waitingForRecovery`, its use unknown; a second run is refused
and the same build is refused `lineageBlocked` while the use is unsettled.

**Sign — plan and admission.** `hostOnly` under the default read-only policy.
The signing preset named must be one the profile carries whose credential
resolves for this project; a registered project never falls back to the
installed receipt. The unsigned HAP's lease is resolved, bound to the request's
target and measured (a bounded ZIP container).

**Sign — run.** The preset re-validated with its secrets present, the input
staged in the Job's attempt directory, then `sign-app` with the JAR bound by
its inode and both passwords answered on a pseudo-terminal only (an echoed
password is a privacy failure); `verify-app` then reads the certificate chain
and the profile back, and `signing-result.json` records the verification. The
signed HAP and `signing-report.json` are published with the source lease's
binding, and the attempt directory is removed once the Job is terminal. Any
outcome that cannot be read back parks the Job.

**Sign — reconcile.** From the Job's own attempt directory only: nothing
written is `not executed` (the Job fails, original not resent); a result
without its output is unknown; an output is read back — the recorded
verification honoured only for this source and preset and while the product
still measures as recorded, else `verify-app` run once more and recorded — and
completes the step, the products republished; the Job resumes at its
confirmed safe boundary and finalizes without signing again.

**Credential owner.** Swift's `OpenHarmonySigningCredentialOwner` over the
preset store: the ledger `credential-owner-v1.json` (canonical compact JSON)
names the installed receipt by `credential:sha256-…` and the presets pinning
it; a root with no ledger adopts the installed receipt; an interrupted replace
or removal is settled by what landed. The workspace preset store pins through
it (Swift's `RuntimeWorkspaceCredentialPinning`): the project binding checked
before the store writes its intent, without secrets (`signing credential <ref>
is bound to project <x>, not <y>`), again at the pin with secrets, and the pin
released with the preset. At start-up a registered signing preset composes
when its toolchain pin resolves and its credential resolves pinned by it,
secrets present, bound to its project.

## Composition

- **Production** (`production.rs`): the account's preset store
  (`…/ArkDeck/Signing/OpenHarmony`, Swift's `defaultRootURL()`), secrets from
  the Data Protection Keychain bound to the installed daemon's identity
  (`…/Helpers/ArkDeckAgent.app/Contents/MacOS/arkdeck-agentd`), attempts in
  `<state>/workspace-signing-attempts`, and the credential pins no preset
  record carries released at start-up with Swift's line, as the default
  daemon does.
- **Isolated development root** (`main.rs`): no credential owner and no
  signing. Swift's private `--state-dir` daemon shares the account's signing
  material; a development root must not read, pin or release it, so a
  signing preset is refused there as Swift's store refuses one without an
  owner (`signing credential reference owner is unavailable`), and nothing is
  signed. Build presets compose as in production.

## Signing acceptance (Q9) and secrets

The acceptance is the restated SPK-10 criterion the coordinator ruled on
2026-09-24 (Q9): the argv, the prompt protocol on the terminal, the signing
identity and the verification readbacks — not the signed bytes of a real
signer. The stand-in's bytes are fixed, so the products compare as well.

Both fake passwords live only in memory. The sign oracle's test reads every
file below its root after the run — records, journals, Artifacts, the ledger,
the attempt store — and finds neither; a mutation that writes one into a
parked Job's failure is caught. No real Keychain item is read or written, no
real credential, certificate or profile is touched, and no real DevEco or
Hvigor runs: the tests use the stand-ins above and in-memory secrets, and the
production composition's Keychain source is only constructed, never read, by
the tests (their homes hold no receipt).

## Differences and choices

- **Child environment of a build.** Swift's children inherit the daemon's
  `PATH`, `HOME`, `TMPDIR` and `LANG` (SPK-10); the Rust runner's base is
  `PATH=/usr/bin:/bin LANG=C LC_ALL=C`. A build child also gets the daemon's
  `HOME` and `TMPDIR`, which Hvigor keeps its caches in, and its preset's
  `DEVECO_SDK_HOME`. Signing children get the clean base only, as SPK-10
  found sufficient.
- **The signing Job's project check** at lowering compares against the
  provider's first profile, as Swift's `lower` does; ported unchanged.
- **A primary tree is never built**: no capability is issued for it and a
  person's standing grant is not honoured (as for a patch, #2146).
- **The isolated development root signs nothing** (above).
- **Projections unchanged**: a preset's `configurationStatus` is still always
  `runtimeRestartRequired` and `operation.list` still reports every workspace
  operation `provider_not_registered`; neither gates planning or `agent run`.
  Both predate this change.

## Tests

- `workspace_build_oracle` (hoststore, 4): the 22 frames replayed in order,
  every answer Swift's (the plan's additive review digest aside), the
  products, capabilities and parked record byte for byte; a toolchain changed
  after admission never runs (the Node launcher, the Hvigor script, and a
  pinned child tool that lost its execute permission); a primary tree never
  built even under a person-issued grant; a registered Hvigor preset composed
  through its resolved toolchain, one that did not resolve and one registered
  after the start refused.
- `workspace_sign_oracle` (hoststore, 2): the 19 frames replayed, the signed
  products, the ledger and both parked records byte for byte, a parked Job's
  second run refused with nothing written, a signing file that drifted after
  admission failing the Job when its step is lowered again, before any intent
  (`workspace.presetUnavailable`), the attempt store empty, no password
  anywhere; a registered signing preset — a foreign project's pin
  refused before the store writes, the pin in the ledger, unresolved without
  the credential owner, an orphaned pin released at start-up, a HAP signed
  with it, the pin released with the preset.
- agentd: the production layout names the signing root and the installed
  daemon, and the composition creates the owner's ledger and the attempt
  root owner-only.

Mutations (`scratchpad/s23/mutate.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| A password written into the failure a parked signing Job keeps | the recorded signing sequence (the parked record) |
| A capability issued automatically for the primary tree | the recorded build sequence; the primary-tree test |
| A signed product published without the `verify-app` readback | the recorded signing sequence; the registered preset test |
| A parked build's intent reconciled as not executed | the recorded build sequence |
| A resumed signing Job signs again | the recorded signing sequence |
| `DEVECO_SDK_HOME` dropped from the build child | the recorded build sequence; the registered preset test |
| A pinned child tool's execute permission not required | the drift test |
| The pinned resources neither verified nor held at dispatch | the drift test |
| The landed product kept in the copy after publication | the recorded build sequence |
| A foreign project's preset pinning the credential | the registered preset test |
| The orphaned pins kept at start-up | the registered preset test |

## Local targeted checks

All with `CARGO_BUILD_JOBS=2`, `CARGO_INCREMENTAL=0` and this tree's own target. Logs are
`/private/tmp/arkdeck-s23-*.log`. The change was rebased three times: onto `a5902947` (#2150),
onto `cc5b5670` (#2151), and onto `c588ccd7` (#2152). The checks whose crates #2151 touched
were run again after the second rebase.

The third rebase conflicted in two places, because #2152 also gave hoststore a new crate edge:

- `check-readonly.py`: the hoststore allow-list is now the union, with both comments kept.
- `Cargo.lock`: taken from `main`, then completed by `cargo metadata`. The only change is the
  one hoststore → provider-workspace entry.

After the third rebase, `cargo fmt --check`, `assert_boundaries` and `check-sdd` passed again.
The Rust builds and tests were not run again, because this host's free disk had fallen to
11.5 GiB, under the task's 12 GiB floor. Time Machine's hourly local snapshots hold the space of
the build products this tree deleted. The PR's CI verifies the merged tree.

| Check | Command | Exit | Log |
|---|---|---|---|
| Format | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | 0 | `arkdeck-s23-fmt.log` |
| Lints | `cargo clippy -p arkdeck-platform -p arkdeck-provider-workspace -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak -p arkdeck-cli -p arkdeck-client -p arkdeck-provider-hdc --all-targets -- -D warnings` (the changed crates and their direct dependents), after the second rebase; hoststore again after the last test edit | 0, 0 | `arkdeck-s23-clippy.log`, `arkdeck-s23-clippy-hoststore-final.log` |
| Tests, the eight crates | `cargo test` of the same eight crates `--no-fail-fast`, on `a5902947`: 167 targets, 1358 passed, 0 failed, the 18 existing ignored. This includes `arkdeck-provider-workspace` (its library, `deveco_password`, `fake_hap_signer`) | 0 | `arkdeck-s23-tests.log` |
| Tests after the second rebase | `cargo test -p arkdeck-agentd -p arkdeck-cli -p arkdeck-soak --no-fail-fast`: 57 targets, 398 passed, 0 failed. The hoststore workspace oracles: build 4, sign 2, isolation 7, patch 6, mutation 1, preset transaction 7 | 0 | `arkdeck-s23-tests-rebased.log`, `arkdeck-s23-workspace-oracles.log`, `arkdeck-s23-sign-oracle4.log` |
| Crate boundary | `check-readonly.py`'s `assert_boundaries` (validation venv) | 0 | `arkdeck-s23-readonly-boundaries.log` |
| Swift recordings | `run-swiftpm.sh test --filter WorkspaceBuildOracleContractTests` (a first recording failed on the test's own assertion, fixed; then recorded) and `--filter WorkspaceSignOracleContractTests` (recorded twice), each then verified. After the second rebase, both verified again byte for byte | 0 | `arkdeck-s23-swift-{build,sign}-{record,verify}-*.log`, `arkdeck-s23-swift-verify-rebased.log` |
| Mutations | `scratchpad/s23/mutate.py` on the final tree: 11/11 caught, every source restored by checksum | 0 | `arkdeck-s23-mutations-final.log` |
| SDD | `sh scripts/check-sdd.sh` | 0 | `arkdeck-s23-check-sdd.log` |
| GJ-5 fake rehearsal | `scratchpad/s23/gj5/rehearse.py` (`gj5-fake-rehearsal-2026-09-25.md`) | — | the record |

No fake HDC, daemon or temporary root was left running or behind.

Not run:

- `generate-contract.py --check` and the full `check-contracts.py`: no contract input changed.
  The new frames live under `rust/tests/fixtures/` and validate against the published schemas.
  The `check-readonly.py` allow-list edit was checked with `assert_boundaries` alone, because
  the full script starts a standalone daemon, which is left to the PR's `check-contracts` lane.
- `check-corpus-replay`.
- The App, real devices, and a real DevEco, signer or Keychain item, which this task forbids.

## CI

PR #2153. Its first head `8f8cabe6e`: Agent PR 36055652647, SDD Guard 36055652592 and Swift
CI 36055653203 all succeeded. Rebased onto #2152 as `ed8272f01` and merged as `4b89780f3`:
Agent PR 36057643861, SDD Guard 36057643799 (`guard`, `ds-tokens`) and Swift CI 36057644390 all
succeeded (plan; swift-tests; ds-interactions; Rust host-independent checks; Rust workspace on
ubuntu-latest, windows-latest and macos-26; `swift` aggregate; app-build skipped by the plan) —
the verification of the rebased tree, which was not rebuilt locally (above).
