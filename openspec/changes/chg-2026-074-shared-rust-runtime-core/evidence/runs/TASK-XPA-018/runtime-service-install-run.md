# TASK-XPA-018 — `runtime service update|install|uninstall` and `verify` without `--job` on the Rust CLI

G5 queue slice 7 (M5 prerequisite, lane A), second PR, part b — the last of the
slice. Part a (#2142) added `arkdeck-agentd --cutover-preflight`; this part is
the CLI that runs it, with the rest of the coordinator's rulings
(协调会话受托裁定 2026-09-24, delegated by the maintainer):

1. The CLI runs the one-shot preflight twice — lock-free before `bootout` (a
   refusal changes nothing) and holding the instance lock after it (a refusal
   bootstraps the old plist back unchanged) — and does not link
   `arkdeck-hoststore`.
2. `ARKDECK_ANALYZER_PATH`: until `--analyze-crash-ledger` is ported to the
   Rust daemon, an `install`/`update` that would render a plist for the Rust
   daemon is refused fail-closed with a named blocker; the analyzer is never
   pointed at the Swift daemon and never dropped.
3. `update` is refused while a signing receipt exists, until the Rust signing
   owner (Q8).
4. The snapshot summary is written to `LaunchAgent/cutover-snapshots/`; the
   replaced helper bundle is kept one generation in `Helpers/.rollback/`.
5. `runtime service verify` without `--job` is an agent run through the daemon
   plus the reopen check, declared against Swift's client-side executor, its
   output kept close to Swift's.

Development base: `a83d930ec` (part a's head); final base: protected main
`d41cc1fb1` (#2142, part a squashed; its tree equals part a's head, so the
rebase dropped that commit and changed nothing else). Branch:
`agent/xpa-018-runtime-service-install`.

## What a caller sees

- `arkdeck runtime service update [--daemon <ArkDeckAgent.app>] [--hdc <path>]
  [--workspace-project <p> --deveco-sdk <s>] [--arktrace-descriptor <path>|none]
  [--arkforge-bundle <path>|none [--arkforge-campaign <id>]]` installs a helper
  bundle and answers Swift's install receipt (`arkdeck-launchagent-install/v1`).
  Its refusals are Swift's plain CLI errors (64 for its options, 1 for a failed
  validation or launchd step) and three new ones, each before anything
  changes: 69 while `~/Library/Application Support/ArkDeck/Signing/OpenHarmony/
  preset-v1.json` exists; 69 when the new helper's daemon is the Rust daemon
  (the analyzer blocker); 69 when that daemon neither answers the cutover
  preflight nor refuses it as Swift's daemon does.
- Past the analyzer gate (closed in production, open only in tests) an update
  to the Rust daemon is the cutover: 75 naming every block when either
  preflight pass is not clear, the old service started again after a held-pass
  refusal; on success the receipt plus a `cutover` member (`snapshotPath`,
  `snapshotRootSha256`, `carriedOver`, `rollbackBundlePath`).
- `arkdeck runtime service uninstall` answers Swift's `{removedPlist,
  removedDaemon, removedReceipt, preservedStateDirectory,
  preservedLogDirectory}`; 69 before anything changes while
  `Bootstrap/v1/bundles.json` pins a bundle for `installation/
  runtime-service-installation` or cannot be read.
- `arkdeck runtime service install --bundle … --bundle-generation … --tool …
  --tool-generation …` parses as Swift's (all four required, the generations
  canonical positive integers) and is refused by name (69).
- `arkdeck runtime service verify [--target <id>] [--maximum-wait-seconds
  1…300] [--execution-id <id>]` answers `{launchAgent, agentExecution, runtime,
  runtimeVerified}` (exit 0 verified, 1 not); while a person is needed
  `{humanAction, launchAgent, runtimeReceipt, runtimeVerified: false}` with
  exit 75 and the `agent resume --resume-reference` line; an unready service
  `{launchAgent, runtime: null, runtimeVerified: false}` with 69, as `verify
  --job` answers.
- `arkdeck commands` lists all six LaunchAgent leaves.

## Swift semantics and the port

Oracle: `Packages/ArkDeckKit/LaunchAgents/LaunchAgentService.swift`
(`install`, `uninstall`, `transportExecutable`, `renderTemplate`,
`arkTraceDescriptorForPreservingUpdate`, `arkForgeLaneForPreservingUpdate`,
`createOwnedDirectory`, `replaceItem`, `removeIfPresent`, `bootstrap`), its
template `com.arkdeck.agentd.plist`, `Sources/ArkDeckCLI/ArkDeckRuntimeCommands.
swift` (`runAgentDaemon` `install`/`update`/`uninstall`, `agentdInstallOptions`,
`defaultAgentDaemonBundlePath`, `refreshSigningAccessIfInstalled`), the argv
fixtures of the three leaves, and `HeadlessRuntimeVerifier.verifyObserveDevice`.

- **Options, in Swift's order** (the `runtime.service` spelling): the daemon
  bundle (`--daemon`, else the helper inside the app holding the CLI, else the
  one beside it); `--hdc`, else the previous status's; both absolute; the
  workspace pair together and absolute, never preserved; the five decision-plane
  flags refused by name (CHG-2026-064); `--arktrace-descriptor` `none`, an
  absolute path, or the live descriptor kept only while it matches the receipt;
  the three retired lane flags refused by name; `--arkforge-bundle` `none` (no
  campaign), measured, or the live plist's lane kept; a campaign only with a
  bundle.
- **install**: the production bundle validation, the HDC executable, the
  workspace and descriptor validations, the transport executable (the signed
  sibling facade when present), both digests; the four owner-only directories;
  `bootout` when loaded; the bundle copied (`copyfile` clone, recursive,
  `arkdeck_platform::clone_tree`) to `.arkdeck-agentd-<UUID>.app` and exchanged
  into place (`renamex_np(RENAME_SWAP)`, `exchange_paths`) or moved when nothing
  was installed; the installed bundle revalidated and its daemon `0700`; the
  plist rendered from the template's keys — the three placeholders replaced,
  `ARKDECK_ANALYZER_PATH` the installed daemon, `ARKDECK_SWIFT_SHA256` when the
  facade launches, `ARKDECK_WORKSPACE_INSPECTOR` `/usr/bin/grep`, the demo-app
  workspace trio, the descriptor, the ArkForge bundle and a non-empty campaign —
  and serialized by CoreFoundation's XML writer, the bytes Swift's
  `PropertyListSerialization` writes (`write_property_list_xml`, checked against
  `plutil` and against the rendering `status` reads); the receipt encoded as
  `JSONEncoder([.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])` encodes
  it, both written atomically and `0600`; `bootstrap` with Swift's EIO retry.
- **uninstall**: `bootout` when loaded, then the plist, the installed bundle and
  the receipt removed when present.
- **verify without `--job`**: Swift's intent (`observe.device@1`, `inputs {}`,
  the target, `maximumWaitMilliseconds` from `--maximum-wait-seconds`, default
  90, and the execution id, default a new lowercase UUID) sent as `agent.run`,
  then `agent.status` from the poll interval up to 2 s until the execution
  settles (`settle_execution`), for its budget and 30 s more; a completed
  execution's Job is reopened with `verify_persisted_job`.

## The cutover (rulings 1, 2 and 4)

The new helper's `Contents/MacOS/arkdeck-agentd` is run with
`--cutover-preflight` and an environment of only `HOME`,
`ARKDECK_RUNTIME_COMPOSITION=production` and, for a relocated home,
`CFFIXED_USER_HOME`, its output bounded and its run timed out (600 s in
production). Swift's daemon rejects any argument it does not take with
`unknown argument …` and exit 64 before it does anything, and an older Rust
daemon rejects every argument with exit 69 before it composes anything; the
Rust daemon answers a canonical `arkdeck.cutover-preflight/1` document, whose
`stateDirectory` must be this home's. So an update installs Swift's daemon as
Swift does, and an update to the Rust daemon is the cutover:

1. The analyzer gate (ruling 2): refused by name, nothing changed.
2. The first, lock-free pass must be clear; else 75, nothing changed.
3. The four directories, then `bootout` when loaded.
4. The held pass (`--hold-instance-lock`), asked again one poll interval apart
   up to 50 times while its only block is `runtimeRunning` (`bootout` can answer
   before the old daemon has let its lock go). Not clear, or not a snapshot
   taken under the lock, and the old plist is bootstrapped back unchanged
   (when the service was loaded) and 75 or 69 answered.
5. The snapshot summary written owner-only to `LaunchAgent/cutover-snapshots/
   cutover-<takenAtUtc>-<rootSha256 prefix>.json` (the held pass's snapshot,
   canonical JSON).
6. The bundle replaced (the old one kept in `.rollback`), and the plist rendered
   with `ARKDECK_RUNTIME_COMPOSITION=production`; a Rust helper carrying a facade
   is refused.

## Declared differences

- The replaced helper is kept one generation in
  `Helpers/.rollback/ArkDeckAgent.app` (ruling 4); Swift discards it.
- A signing receipt refuses `update` up front (ruling 3); Swift re-records the
  daemon identity after the replacement and before `bootstrap`.
- `update` runs the new helper's daemon once with `--cutover-preflight` before
  it changes anything, to tell Swift's daemon from the Rust daemon; Swift runs
  nothing before `bootstrap`.
- An update to the Rust daemon is refused by name until `--analyze-crash-ledger`
  is ported; the cutover behind that gate is exercised only by tests until then.
  Every update that installs the Rust daemon runs the preflight, a later Rust
  to Rust update included.
- The typed `install` is refused by name, and `uninstall` is refused while the
  bundle registry pins the installation: the registries' installation
  references (`acquire`/`retainOnly`/`releaseAll`) have no Rust owner and the
  CLI does not link the store. `update` covers a first install, as in Swift.
  That index is read below the relocated home, as the Rust daemon's layout
  reads it; Swift's registry always uses the account's `getpwuid` home.
- `verify` without `--job` is run by the daemon's agent executions (ruling 5):
  `runtime` is the reopen report (`arkdeck-headless-runtime-reopen/v1`) rather
  than Swift's fresh report, `agentExecution` is added, a paused run names the
  execution's `--resume-reference` instead of Swift's executor token, and a
  request the daemon refuses ends with exit 1 and no document.
- The `agentd …` compatibility spelling of these leaves is not served.

## Tests

- `crates/arkdeck-cli/tests/runtime_service.rs` (32: twelve new, the
  refused-by-name `verify` test replaced, two process tests extended):
  update of a Swift helper (launchd calls, installed and kept bundles, the plist
  equal byte for byte to the CoreFoundation rendering of Swift's template, the
  receipt equal to Foundation's encoding, modes, status consistent afterwards,
  the probe's cleared environment, nothing left staged); every option refusal
  and the signing refusal with the home unchanged; a daemon that is neither
  runtime; the analyzer blocker with only the lock-free pass run; the cutover
  with both passes (the held one asked again while the old lock is held), the
  snapshot file, the `cutover` member, the kept bundle and the production plist;
  a first-pass refusal changing nothing; a held-pass refusal starting the old
  service again after 50 asks; uninstall (pinned, unreadable index, removal,
  nothing to remove); the typed install; fresh verify verified (the exact
  intent, `agent.status` polled, the reopen), paused for a person, refused, and
  of an unready service; the real `arkdeck` over a relocated home (the
  production validation refusing an unsigned helper before anything, the
  signing refusal, the typed install, uninstall asking only the recording
  launchd `print`, the six leaves listed) and the new parse refusals. The fake
  helper daemons are `/bin/sh` scripts that record their arguments and
  environment and answer as Swift's or the Rust daemon would.
- `crates/arkdeck-platform`: `write_property_list_xml` against `plutil`'s output
  and round-tripped, escaping, `false` and dates; `clone_tree` (a link kept, an
  existing destination refused) and `exchange_paths`.
- The three Swift argv fixtures `runtime.service.{install,update,uninstall}.json`
  are copied byte for byte and replay with no new known deviation.
- Twelve mutations, each caught by a test failure (not a build error) and
  restored by checksum (`/private/tmp/arkdeck-s18-mutants-2b.log`): the analyzer
  gate ignored, the signing receipt ignored, any exit 64 read as Swift's daemon,
  the first pass unchecked, a held refusal not restarting the old service, the
  held pass not asked again, the production composition not asked for, the
  replaced helper not kept, the probe's environment inherited, the uninstall
  pins ignored, the fresh verify skipping the reopen, a plist key dropped.

No test ran `/bin/launchctl`, touched the account's `gui/<uid>` domain, its
LaunchAgent plist or `~/Library/Application Support/ArkDeck`, the installed
agentd or its HDC server, or a device.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s18-2b-*.log`. The changed crates are `arkdeck-platform`
and `arkdeck-cli`; with the platform's direct dependents the checked set is
`arkdeck-platform`, `arkdeck-client`, `arkdeck-cli`, `arkdeck-hoststore`,
`arkdeck-provider-hdc`, `arkdeck-provider-workspace`, `arkdeck-agentd` and
`arkdeck-soak`.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s18-2b-fmt.log` |
| `cargo clippy --all-targets -- -D warnings` for the eight crates | 0 | `arkdeck-s18-2b-clippy.log` |
| the same for `arkdeck-platform` and `arkdeck-cli` with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` (the new modules are macOS-only) | 0, 0 | `arkdeck-s18-2b-clippy-{linux,windows}.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test --no-fail-fast` for the eight crates | 0: 157 result lines, 1,276 passed, 0 failed, 18 existing ignored; `runtime_service` 32, `argv_fixtures` 5, `current_surface` 11, `cutover_preflight` 9 | `arkdeck-s18-2b-tests.log` |
| twelve mutations through `scratchpad/s18/mutate.py`, each caught by a test failure (not a build error) and restored by checksum | caught ×12 | `arkdeck-s18-mutants-2b.log` |
| `generate-contract.py --check` (validation venv) | 0 | `arkdeck-s18-2b-contract.log` |
| `rust/scripts/check-contracts.py` (validation venv): the six Swift argv copies byte-equal, published and candidate views, the candidate view's 17 commands including `check-readonly.py` (crate edges unchanged) | 0 | `arkdeck-s18-2b-check-contracts.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s18-2b-sdd.log` |

Afterwards no temporary home (`/private/tmp/ads-*`) or test process was left,
and the installed agentd (PID 10694) and HDC server (PID 10798) were the same
processes as before the session.

Not run: Swift or App tests (no Swift or App file changed), the full local gate,
a signed helper, an installed service or a device.

## Remaining for the cutover (not in this slice)

- Port `--analyze-crash-ledger` to the Rust daemon, then open the gate
  (`rust_daemon_analyzes_crash_ledgers`).
- A Rust signing-credential owner (Q8), to re-record the daemon identity instead
  of refusing.
- An owner for the bootstrap registries' installation references, for the typed
  `install` and `uninstall`'s release.

## CI

Pending.
