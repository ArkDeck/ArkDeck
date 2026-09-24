# TASK-XPA-018 — `runtime service status|verify --job|restart` on the Rust CLI

G5 queue slice 7 (M5 prerequisite, lane A), first of two PRs. This one serves the
three LaunchAgent leaves the headless runbook uses (`status` in §1, `verify --job`
and `restart` in §2) and adds launchd primitives to `arkdeck-platform`. The
second PR carries `install`, `update` and `uninstall` with the design §G.4
cutover preflight, the old-state snapshot summary and the rollback retention of
the replaced helper bundle.

Development base: protected main `1267e465d` (#2139). Final base: `acddc3177`
(#2140, which changes no file of this slice; the rebase applied cleanly). Branch:
`agent/xpa-018-runtime-service-cli`.

## What a caller sees

- `arkdeck runtime service status` answers Swift's `{launchAgent, daemonHealth}`:
  the plist, installed helper, daemon and HDC digests against the install
  receipt, the ArkForge release unit and ArkTrace descriptor when configured,
  whether launchd has the service loaded, the socket, the diagnostics and
  `ready`; then the daemon's own `health`, `{"status":"unreachable","detail":…}`,
  or `{"status":"socket_absent"}`. Exit 0 whatever the state.
- `arkdeck runtime service verify --job <id>` reopens one completed, profiled
  Job (`observe.device@1` or `flash.full-restore@1`) through `health`,
  `job.status`, `job.evidence` and `artifact.list` only, and answers
  `{launchAgent, runtime: <arkdeck-headless-runtime-reopen/v1>, runtimeVerified}`.
  A failed proof keeps its report on stdout and exits 1; an unready service
  answers `runtime: null` and exits 69; an unreadable daemon fact exits 1 with an
  empty stdout.
- `arkdeck runtime service restart [--maximum-wait-seconds 1…300]` restarts the
  ready service only when every current Job is a closed unknown-outcome
  recovery lane (else 75, naming the Jobs), and proves the replacement: a new
  PID in `instance.json`, the same catalog digest, the same closed Jobs (else 69).
  It answers Swift's `{restart, restartProof, launchAgent, daemonHealth}`.
- Refusals are Swift's plain `CLIError`s: a stderr line and Swift's exit status,
  stdout empty. `--output json` wraps a document in `arkdeck.cli.result/1` with
  `meta.controlProtocolVersion`, as Swift's session does; `--json` prints the
  bare document; human output is the JSON document (this CLI's convention).
  `--socket`, `--control-request-id`, `--timeout` and `--output jsonl` are
  refused (64); `--job` excludes `--target`, `--maximum-wait-seconds` and
  `--execution-id`.
- `arkdeck doctor --deep` over the production composition (#2136) reports its
  owners as they are; with no HDC composed the HDC check is the
  `hdc.notConfigured` blocker, and `--require-healthy` exits 69.

## Swift semantics and the Rust port, leaf by leaf

Oracle: `Packages/ArkDeckKit/LaunchAgents/LaunchAgentService.swift`,
`Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift` (`runAgentDaemon`,
`agentdRestartJobPreflight`, `waitForRestart`), `Sources/ArkDeckAgentClient/
HeadlessRuntimeVerifier.swift` and `CurrentRuntimeResourceReads.swift`, and the
pinned ArkForge `ArkForgeReleaseBundleReader.load` (`eee57872`).

- **Paths** (`LaunchAgentPaths`): `~/Library/LaunchAgents/com.arkdeck.agentd.plist`,
  `…/ArkDeck/Helpers/ArkDeckAgent.app` and its `Contents/MacOS/arkdeck-agentd`,
  `…/ArkDeck/LaunchAgent/install-receipt.json`, `~/Library/Logs/ArkDeck/agentd{,.error}.log`,
  `…/ArkDeck/Agentd` and its `agentd.sock`, below the home Swift's Foundation
  resolves (`CFFIXED_USER_HOME`, else the account's).
- **status** (`LaunchAgentService.status`): the plist read by CoreFoundation
  (`arkdeck_platform::read_property_list`, any format, with Swift's `as?`
  bridging — an `NSNumber` of exactly 0/1 is a `Bool`); its lifecycle keys,
  one daemon argument, `ARKDECK_HDC_PATH`, the log paths and the Mach service;
  a daemon other than the installed one only with the paired
  `ARKDECK_SWIFT_SHA256`; the analyzer pinned to the installed daemon and the
  inspector to `/usr/bin/grep`; the legacy workspace trio only as the closed
  `demo-app` profile (Swift's `validatedWorkspace`); the ArkTrace descriptor by
  one `openat(O_NOFOLLOW)` walk with owner-controlled ancestors, a 16 KiB bound,
  an unchanged identity across the read and the closed three-member schema
  (`read_owner_controlled_file`); the ArkForge lane (retired three-key names
  refused by name; the one bundle re-measured member by member, nothing
  undeclared, the `org.openharmony.dayu200` profile, the campaign trimmed of
  Foundation whitespace). Then the helper's production validation
  (`validate_production_daemon_bundle`), the transport executable (the signed
  sibling facade when the bundle carries one, checked against
  `com.arkdeck.agentd.facade`'s requirement by `validate_facade_signature`),
  the daemon and HDC digests, the receipt drift checks, `launchctl print`, the
  socket. Every diagnostic string is Swift's, in Swift's order (including the
  facade failure that throws out of the executable checks). The document omits
  an absent optional, as `JSONEncoder` does.
- **verify --job** (`verifyPersistedJob`, `reopenReport`): the job id is a safe
  identifier; the health digest must be lowercase SHA-256; `job.status` gives
  the persisted status; `job.evidence` must be `arkdeck.job-evidence/1` with
  canonical decimal Artifact counts, decoded as `RuntimeHardwareEvidenceTrustedFacts`
  and re-encoded as Swift encodes it (members it does not model dropped, nulls
  omitted, counts as integers); the Artifact inventory pages `artifact.list`
  (1000 per page, one snapshot, order continued across pages, no repeated
  cursor, 30 s) and an unreadable inventory is a blocker. The five checks, the
  blocker texts, their de-duplicated sorted order and the observe/flash
  profiles (required and allowed Artifact names, required step kinds, effect,
  authority kind and its capability correlation fields) are Swift's.
- **restart** (`runAgentDaemon` restart, `LaunchAgentService.restart`,
  `bootstrap`): ready status; the `health` catalog digest (`status` ok, lowercase
  SHA-256); `instance.json` (positive pid, the managed socket path, nonempty
  protocol and start time); every `job.list` page with `includeCurrent`
  (`pageSize` 1000, `createdAtDescJobIdAsc`, no timeline), one snapshot revision,
  no repeated cursor, a `null` final cursor; the current Jobs classified by the
  shared preflight table's restart rule (`arkdeck_contract::classify_restart`,
  #2026). Then status again, `launchctl bootout`, `launchctl bootstrap` retried
  only on EIO for at most 20 attempts with `launchctl enable` once after three,
  then polling every 100 ms until the service is ready with a new PID and the
  same digest (another digest ends the wait at once), and the Job closure
  re-read. Never `kickstart`. Each Runtime request is its own connection with
  its own contract preflight, as Swift's `AgentClient` makes it.
- **launchd** (`arkdeck_platform::launchd`): the argument arrays
  `print|bootout|enable gui/<uid>/com.arkdeck.agentd` and
  `bootstrap gui/<uid> <plist>`, run by one fixed executable with no shell; the
  exit status (or terminating signal) and both streams are Swift's
  `LaunchAgentCommandResult`.

## Declared differences

- A home relocated with `CFFIXED_USER_HOME` never drives the account's launchd
  domain. Swift's service manager would ask (and restart) the account's real
  `gui/<uid>` service while reading a stranger's plist. Here a relocated home's
  launchd calls go only to the absolute executable
  `ARKDECK_LAUNCHCTL_FOR_RELOCATED_HOME` names (never `/bin/launchctl`), and
  without one they are refused before anything runs; the variable itself is
  refused for the account's own home. It is how the process tests reach a
  recording launchd, and cannot redirect the account's own service.
- Paths are physical. Foundation's `standardizedFileURL` and
  `resolvingSymlinksInPath` also drop a leading `/private` whose remainder
  exists; the Rust service manager keeps it, as the Rust daemon's own layout
  does, so the CLI and the daemon agree on the socket and instance paths. Only
  paths under `/private` spell differently (a relocated test home, a tool or
  bundle under `/tmp`); the account's home never does.
- `verify` without `--job` runs a fresh `observe.device@1` through Swift's
  client-side executor (`AgentRuntimeExecutor`: target adoption, pauses persisted
  by the client, its own receipt). The Rust CLI does not carry that executor; the
  leaf is refused by name (69) before anything is read, naming `agent run
  --operation observe.device@1` and `verify --job`. The runbook already verifies
  with `--job` only.
- The Rust client validates every Runtime answer against the published method
  schema, so a daemon answering a malformed `job.list` page ends `restart` with
  exit 1 where Swift's own checks would answer 69.
- `status` reads the daemon's health through the Rust client, which validates the
  health document; a daemon of another contract reads as `unreachable` with the
  reason.

## Not in this PR (the second PR), and what needs a maintainer

- `install`, `update`, `uninstall`: plist rendering (CoreFoundation's XML
  writer, so the bytes are Swift's), the receipt, bundle replacement with the
  replaced helper kept one cycle for rollback, and the typed zero-Runtime
  `install` over the Bootstrap registry.
- The §G.4 cutover preflight before `update` (the table's blocking and parked
  sets over every Job's index row, record and journal; active agent executions;
  unsettled capability uses; no pending tool selection) and the old state
  directory's snapshot summary. Deciding where the offline reader runs is the
  maintainer's: (a) the agentd binary in a one-shot preflight mode that the CLI
  runs (no new crate edge; the store formats stay with their owner), or (b) a
  new `arkdeck-cli → arkdeck-hoststore` edge (the CLI would link the Job engine).
  (a) is proposed.
- `ARKDECK_ANALYZER_PATH`: Swift's plist names the installed Swift daemon, which
  has `--analyze-crash-ledger`; the Rust daemon has no such mode (S13's finding).
- `update`'s credential refresh (Swift `refreshSigningAccessIfInstalled`) has no
  Rust owner yet (Q8).
- `verify` without `--job`: port the client-side executor, redefine the leaf as
  the Runtime-owned `agent run` plus the reopen, or tombstone it.

## Tests

- `crates/arkdeck-cli/tests/runtime_service.rs` (21): the three leaves over a
  temporary home with a recording `LaunchctlRunner` and a fake Runtime on the
  installed socket that answers the published methods with schema-valid
  documents. `verify --job` reopens the Swift-recorded `observe.device@1` Job of
  the agent-execution oracle (`rust/tests/fixtures/agent-execution/cases.json`,
  `observed.evidence` and `observed.artifacts`). Covered: every status field and
  omission; each drift diagnostic (not loaded, socket absent, stale socket
  unreachable, HDC drift, missing or foreign receipt, plist shape, analyzer,
  paired daemon, facade signature and transport, helper validation); the
  ArkForge unit (measured, member drift, undeclared member, retired names); the
  ArkTrace descriptor (pinned, schema, world-writable ancestor); the legacy
  workspace pair; the reopen report (verified, Artifact digest drift, catalog
  drift, unreadable inventory, undecodable evidence, unsafe ids, unready
  service, no `--job`); restart (proof, refusal naming blocking Jobs, paging and
  snapshot/cursor refusals, EIO retry with one `enable`, non-EIO failure, same
  PID until the deadline, another catalog, changed closure). Three process tests
  run the real `arkdeck` binary over a relocated home: the envelope is canonical
  and Swift's; with the plist installed and no named launchd executable the
  command fails before anything runs; with a recording script launchd is asked
  exactly `print gui/<uid>/com.arkdeck.agentd` (and the real, loaded service
  would have answered 0 where the script answers 113); refusals leave stdout
  empty.
- `crates/arkdeck-platform`: launchd argument arrays, the relocated-home rule and
  the runner's argument passing (`/bin/sh`, never launchctl); the property-list
  reader (XML with a comment, bridging, refusals, bound); the owner-controlled
  read (symlinked file or ancestor, group/world-writable file or ancestor, empty,
  over-bound); an unsigned facade and an Apple-signed binary refused by the
  facade requirement without running either.
- `crates/arkdeck-agentd/tests/production_composition.rs`
  `the_deep_doctor_reports_the_production_owners_as_they_are`: the real daemon
  in production mode under a temporary home and the Rust CLI over its socket.
  An HDC whose identity cannot be proved is already reported as
  `hdc.identityFamilyUnavailable` by `managed_hdc_process` (same `Host`
  deep path).
- The three Swift argv fixtures (`runtime.service.{status,verify,restart}.json`)
  are copied byte for byte and replay through the Rust parser with no new known
  deviation; `arkdeck commands` now lists the three leaves.
- Mutations, each caught by its test and restored by checksum
  (`/private/tmp/arkdeck-s18-mutations.log`): a relocated home reaching
  `/bin/launchctl` (checked by the unit test only, which fails before anything
  runs), restart ignoring the PID, restart ignoring blocking Jobs, status writing
  `null` optionals, verify skipping the Artifact digest, bootstrap retrying every
  status.

No test ran `/bin/launchctl`, touched the account's `gui/<uid>` domain, its
LaunchAgent plist, `~/Library/Application Support/ArkDeck`, the installed agentd
(PID 10694) or its HDC server (PID 10798), or a device.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s18-*.log`. The changed crates are `arkdeck-platform`,
`arkdeck-cli` and (tests only) `arkdeck-agentd`; the platform's direct dependents
are `arkdeck-client`, `arkdeck-hoststore`, `arkdeck-provider-hdc`,
`arkdeck-provider-workspace`, `arkdeck-agentd` and `arkdeck-soak`.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s18-fmt.log` |
| `cargo clippy -p arkdeck-platform -p arkdeck-client -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-provider-hdc -p arkdeck-provider-workspace -p arkdeck-agentd -p arkdeck-soak --all-targets -- -D warnings` | 0 | `arkdeck-s18-clippy.log` |
| the same for `arkdeck-platform` and `arkdeck-cli` with `--target x86_64-unknown-linux-gnu`, and `arkdeck-cli` with `--target x86_64-pc-windows-msvc` (the new modules are macOS-only; the dispatch answers `unsupportedOnPlatform` elsewhere) | 0, 0 | `arkdeck-s18-clippy-{linux,windows}.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test --no-fail-fast` for the eight crates above | 0 | `arkdeck-s18-tests.log`: 157 result lines, 1,242 passed, 0 failed, 18 existing ignored; `runtime_service` 21, `argv_fixtures` 5, `production_composition` 9, the platform library 78 |
| six mutations through `scratchpad/s18/mutate.py`, each caught by a test failure (not a build error) and restored by checksum | caught ×6 | `arkdeck-s18-mutations.log` |
| `generate-contract.py --check` (validation venv) | 0 | `arkdeck-s18-contract.log` |
| `rust/scripts/check-contracts.py` (validation venv): the Swift argv copies byte-equal, published view covered (no contract input changed), candidate view's 17 commands including `check-readonly.py` (crate edges unchanged, PASS) | 0 | `arkdeck-s18-check-contracts.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s18-sdd.log` |

Afterwards no fake HDC, test daemon or temporary home (`/private/tmp/ads-*`,
`/private/tmp/adp-*`) was left, and the installed agentd (PID 10694) and HDC server
(PID 10798) were the same processes as before the session.

After the rebase onto `acddc3177`: `cargo build -p arkdeck-cli -p arkdeck-agentd`,
`cargo test -p arkdeck-cli --test runtime_service --test argv_fixtures` (26),
`cargo test -p arkdeck-agentd --test production_composition` (9), clippy for
platform, cli and agentd, `cargo fmt --all --check`: exit 0
(`arkdeck-s18-rebase.log`); `generate-contract.py --check`: exit 0
(`arkdeck-s18-contract-rebase.log`).

Not run: Swift or App tests (no Swift or App file changed), the full local gate,
signed-helper or installed-service acceptance, any device.

## CI

Pending.
