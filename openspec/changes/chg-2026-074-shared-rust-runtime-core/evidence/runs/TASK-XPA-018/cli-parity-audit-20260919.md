# TASK-XPA-018 — the Rust CLI against the feature coverage ledger (macOS, 2026-09-19)

TASK-XPA-018 remains in progress. First recorded on protected main `674c2ed7` with `arkdeck
commands` and the argv replay (#2065, `cli-commands-run.md`); updated 2026-09-20 on `5205b3ec` with the
parse-staging slice (`cli-parse-staging-run.md`), which answers the nine leaves that are not
executable. Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001).

Every one of the 256 entries of `openspec/contracts/cli-feature-coverage.json` is put in one of four
categories, against the Rust CLI's own `arkdeck commands --output json` and the isolated Rust
daemon's routes:

| Category | Entries | Meaning |
| --- | --- | --- |
| 1 implemented | 138 | the leaf the entry targets is one the Rust CLI serves — including the retired and refused leaves it answers by name — or the entry names no leaf (13 presentation-only App surfaces) |
| 2 leaf missing, daemon routed | 61 | the Rust CLI lacks the leaf, and nothing else is missing: every method its Swift handler sends is routed by the isolated daemon, or the leaf needs no Runtime |
| 3 daemon or host owner missing | 42 | a method the leaf sends is not routed, or the leaf runs a host subsystem in the Swift CLI's process that has no Rust port |
| 4 tombstone per §12 | 15 | a deprecated or legacy spelling CLI spec §12 moves to a tombstone in the next CLI major |

Across the registry's 209 leaves (entries also reach leaves through `equivalentCommands`, and aliases
have no entry of their own), the Rust CLI serves 98; of the 111 others, 53 are category 2, 39
category 3 and 19 category 4. The isolated daemon routes 89 of the 105 control methods.

The dashboard's CLI cell (`evidence/macos-remaining.md`) keeps its own definition — parser names that
are also feature names — and reads **96 / 256** after these two slices (99 parser names; the three
unmatched are `artifact.import.hap`, `artifact.import.native-library` and `device.candidates`, as
before): 79, plus the seven workspace leaves of #2056, `commands`, and the nine retired and refused
leaves. The audit counts differently on purpose: an App or Catalog entry is implemented through the
leaf that covers it, and `help`, a parser name, is not a leaf the Rust CLI serves (below).

## How an entry is classified

1. **Target leaf.** The command path of the entry's `targetCommand`; each resolves to a registry leaf.
   `equivalentCommands` are alternatives and are not required.
2. **Served.** The leaf is in the Rust CLI's `arkdeck commands --output json`, which lists a registry
   leaf exactly when the Rust parser serves its path. Every served leaf's Swift argv fixture now
   replays through the Rust parser (`argv_fixtures.rs`: 99 fixtures, 595 cases, `help` included);
   two served leaves answer four of those cases otherwise and are counted implemented with the
   deviation named (next section).
3. **Not served**, by the leaf's registry entry:
   - a deprecated or legacy spelling §12 moves to a tombstone: category 4 (Swift's own tombstones
     and refused stubs are served: this CLI answers them by name, as Swift does);
   - a leaf with no Runtime connection: category 2 when it needs nothing but the CLI (the refused
     `capability` stubs, `completion`, `debug template list`, `help`), category 3 when Swift runs it
     over a host subsystem in its own process that has no Rust port (the LaunchAgent service, signing
     credentials, the updater, the support bundle, update-feed signing and the contract export);
   - a Runtime leaf: category 2 when every method its Swift handler sends is in `arkdeck-control`'s
     method match (the dashboard's routed-method definition), otherwise category 3.
4. **Domain leaves** — a registry `catalogOperation` — all reach the daemon through Swift's
   `runDomainOperation`, whose one-shot executor sends `health`, `operation.describe`, `target.list`,
   `device.observations`, `target.adopt`, `job.submit`, `job.run`, `job.cancel` and `job.evidence`, all
   routed. They are category 2; whether the isolated daemon then executes the operation is noted per
   row: `analyzer.extract-crash-signature@1`, `observe.device@1` and `capture.diagnostics@1` run on it;
   the pointer, port-rule, `debug.hap@1`, `deploy.native-library.app-owned@1` and
   `capture.screen-sequence@1` operations run only against the account-fixed default root; the rest
   have no Rust runner (the dashboard's operation measure).

The methods of each non-domain Runtime leaf come from its Swift handler (`ArkDeckRuntimeCommands`,
`CLIDeviceWait`, `CLIJobEvents`, `CLIDiagnosticsResources`, `CLIWorkspaceContinuation` and their
neighbours); the table is in `cli-parity-audit.py`, which produces every table below.

## Served leaves that answer an argv case otherwise

Before the audit, 41 served leaves had no copy of their Swift argv fixture under
`rust/tests/fixtures/current-cli-argv`, and the Rust tests replayed only three of those from Swift's
own directory (`doctor`, `operation list`, `device candidates`). Replaying every fixture whole found
fourteen cases in six leaves. Swift's parser checks only its registry grammar — unknown, repeated or
missing required options, and value grammar — and leaves what a value *means* to the handler that
sends the request; five of those leaves checked it at parse and therefore answered a different code.
`cli-parse-staging-run.md` moved each check to where Swift makes it, and two cases remain:

| Leaf | Cases | Swift | This CLI |
| --- | --- | --- | --- |
| `help` | `valid`, `leafHelp` | serves `arkdeck help [path…]`, and help for the `help` leaf | serves help only as `--help`; the leaf follows with `completion` |
| `runtime tool register` | `macosCompatibilityOption`, `hdcSocketRefused` (macOS only) | refuses `--socket` unless `--kind deveco`: its HDC registration runs in Swift's own process | takes `--socket` for every kind: this CLI registers through the Runtime that owns the Bootstrap store, so the endpoint is exactly what the leaf needs. A deliberate divergence of the port, not a defect of it |

`argv_fixtures.rs` pins exactly these cases (the `--socket` ones only where `--socket` is accepted at
all, macOS), so closing one removes it from the list and a new one fails.

## Category 2: what the next slices add

53 registry leaves, grouped by what they need:

- **No Runtime:** `completion`, `help` (with the deviation above) and `debug template list`.
- **Reads over routed methods:** `runtime health`, `operation validate`, `device wait`, `job wait`,
  `job watch`, `recovery cleanup list` (with its §12 alias `cleanup-debt list`, which §12 keeps),
  `trace export`, `diagnostics inspect|preview|export`, `ui-dump inspect|hit-test`.
- **Workspace continuation:** `workspace continuation inspect|submit|run`.
- **Domain leaves**, one request builder for all 34: `target observe`, `trace capture`,
  `screen capture|record`, `input tap|long-press|swipe`, `diagnostics capture`,
  `analyze trace|trace-summary|hilog-summary|crash-signature`, `port-forward create|remove`,
  `ui-dump capture|component-detail`, `debug hap|logs|native deploy|template run`, `flash run` and the
  thirteen `workspace <operation>` leaves. Their argv and request shape can match Swift's now; what
  the daemon does with the Job is the operation's own state above.

## Category 3: the owners that are missing

- **Daemon methods not routed** (16 of 105): `cleanupDebt.continue`, `debug.evaluate`, `debug.probe`,
  `debug.start`, `debug.status`, `debug.template.run` (reached by no leaf: `debug template run` is a
  domain leaf), `flash.bind-current-loader`, `flash.bootloader-status`, `flash.device-access`,
  `flash.lanePlanPreview`, `flash.prerequisites`, `flash.reconcile-alias`, `job.reconcile`,
  `recovery.flash-invocation.list`, `trace.inspect` and `trace.probe`. They block `recovery cleanup
  continue` (and its alias), the four `recovery flash-invocation` leaves, `debug probe`, the six
  `flash` observations and bindings, `job reconcile`, `trace inspect` and `trace probe`.
- **Host subsystems without a Rust port:** the LaunchAgent service (`runtime service *`), signing
  credentials and Keychain (`runtime signing *`, XPA-015 after SPK-10), the updater
  (`runtime update *`, now in ClientKit, #2054), the support bundle (`runtime support-bundle *`,
  #2057), update-feed signing (`maintainer update-feed *`) and the contract bundle
  (`maintainer contracts export|check`, whose Rust export is an XPA-018 acceptance item).

## Category 4: tombstones

- **Already removed in Swift** (6): `agent chat` and `flash plan|preview|execute|continue|postflight`.
  Swift answers each before any connection with `commandRemoved`, exit 64,
  `details.lifecycleStatus: "removed"`, the replacement pattern (or null) and the removal version.
  This CLI answers them the same way, from the registry copy (`cli-parse-staging-run.md`), so they
  are category 1 above; the three refused `capability` stubs with them.
- **Deprecated or legacy spellings §12 moves to a tombstone in the next CLI major** (19 leaves):
  `agentd *` (6), `signing *` (5), `update-feed *` (2), `device list|show`,
  `debug start|evaluate|status`, and `flash install-binding` (once the current Loader binding path
  closes). Whether the Rust CLI tombstones them at once or keeps the alias until M5 follows design
  §L.1 item 7 (r11: the Swift CLI is deleted with M5; compatibility leaves are tombstoned per §12).
  `cleanup-debt *` is not here: §12 keeps that alias.

## Recorded only: `runtime service status|verify|restart` and `doctor`

These are maintainer gates; nothing here changes them.

- **`runtime service status|verify|restart`** describe the installed LaunchAgent. Swift runs them in
  its own process (`runAgentDaemon`): `status` reads the plist, the install receipt, `launchctl
  print` and the socket, and sends only `health`; `restart` needs `launchctl bootout`/`bootstrap`,
  the plist and `Agentd/instance.json`, pages `job.list` for current Jobs before and after, and relies
  on Swift's start-up recovery; `verify --job` is read-only (`health`, `job.status`, `job.evidence`,
  `artifact.list`) behind the service readiness gate, and `verify` without `--job` runs a new
  `observe.device@1`. None takes `--socket`, `--endpoint` or `--control-request-id`. The isolated
  Rust daemon writes no `instance.json` and has no installed service, so only `daemonHealth` and the
  `verify --job` comparison carry over; what a development-mode `status` answers is a contract
  decision, and the rest belongs to the M5 cutover.
- **`doctor`** on the Rust daemon (#2008) is Swift's `doctorReport` finding by finding, except the
  two start-up recovery findings it does not emit, `runtime.jobRecordUnreadable` and
  `runtime.durableRecordsUnreadable` (design §L.1 item 13); seven of Swift's eight recorded reports
  reproduce byte for byte, and the eighth is the one that names undecodable Job records. On the
  isolated daemon over a fixture HDC the deep report's one blocker is the fixture's unproven identity.

## Why the coverage file is not edited

`cli-feature-coverage.json`, with `cli-command-registry.yaml`, is written by Swift's `arkdeck
maintainer contracts export`, and `CLIMachineContractTests.testPublishedBundleMatchesThisBuild` fails
on any difference from the build. Its `implementationStatusByPlatform.macos` is computed, not
declared: `implemented` for every entry that is not `blocked`, meaning the entry's contract, registry
mapping and fixture are closed (CLI spec §14) — which all 256 already are. It says nothing about the
Rust CLI, so this audit and the dashboard carry Rust parity; a Rust column in the ledger would be a
change to the exporter and to §14.

## Reproduce

From the repository root, on this slice's head:

```bash
(cd rust && cargo build -p arkdeck-cli)
python3 openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-018/cli-parity-audit.py rust/target/debug/arkdeck
```

Read-only; it reads the ledger, `rust/crates/arkdeck-cli/src/command_registry.json`, the Rust CLI's
`commands` answer, the pinned argv deviations and `arkdeck-control`'s method match.

## Every entry, and every leaf not served

| Feature | Classification | Lifecycle | Target leaf | Category | Note |
| --- | --- | --- | --- | --- | --- |
| agent.abandon | direct | current | `agent.abandon` | 1 implemented |  |
| agent.chat | refused | removed | `agent.chat` | 1 implemented |  |
| agent.list | direct | current | `agent.list` | 1 implemented |  |
| agent.resume | direct | current | `agent.resume` | 1 implemented |  |
| agent.run | direct | current | `agent.run` | 1 implemented |  |
| agent.status | direct | current | `agent.status` | 1 implemented |  |
| agentd.install | local | deprecated | `agentd.install` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| agentd.restart | local | deprecated | `agentd.restart` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| agentd.status | local | deprecated | `agentd.status` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| agentd.uninstall | local | deprecated | `agentd.uninstall` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| agentd.update | local | deprecated | `agentd.update` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| agentd.verify | local | deprecated | `agentd.verify` | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| analyzer.analyze-trace@1 | direct | current | `analyze.trace` | 2 leaf missing, daemon routed | domain leaf; `analyzer.analyze-trace@1` has no Rust runner, so the isolated daemon does not execute it |
| analyzer.extract-crash-signature@1 | direct | current | `analyze.crash-signature` | 2 leaf missing, daemon routed | domain leaf; `analyzer.extract-crash-signature@1` runs on the isolated daemon |
| analyzer.summarize-hilog@1 | direct | current | `analyze.hilog-summary` | 2 leaf missing, daemon routed | domain leaf; `analyzer.summarize-hilog@1` has no Rust runner, so the isolated daemon does not execute it |
| analyzer.summarize-trace@1 | direct | current | `analyze.trace-summary` | 2 leaf missing, daemon routed | domain leaf; `analyzer.summarize-trace@1` has no Rust runner, so the isolated daemon does not execute it |
| app.automation.retired | refused | current | `agent.run` | 1 implemented |  |
| app.debug.apps | direct | current | `artifact.import.hap` | 1 implemented |  |
| app.debug.artifacts | direct | current | `artifact.import.native-library` | 1 implemented |  |
| app.debug.browser | platformService | current | `artifact.import.native-library` | 1 implemented |  |
| app.debug.commands | direct | current | `debug.template.list` | 2 leaf missing, daemon routed | local: needs no Runtime |
| app.debug.logConfirm | presentation | current | `debug.logs` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.debug.logs | direct | current | `debug.logs` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.debug.network | direct | current | `port-forward.create` | 2 leaf missing, daemon routed | domain leaf; `port-forward.create@1` runs only against the default root; the isolated daemon reports it unavailable |
| app.debug.plan | direct | current | `job.plan` | 1 implemented |  |
| app.design.components | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.device.control | direct | current | `input.tap` | 2 leaf missing, daemon routed | domain leaf; `input.tap@1` runs only against the default root; the isolated daemon reports it unavailable |
| app.device.details | direct | current | `device.candidates` | 1 implemented |  |
| app.device.events | presentation | current | `job.events` | 1 implemented |  |
| app.device.recording | direct | current | `screen.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.device.rename | local | current | `device.display-name.set` | 1 implemented |  |
| app.device.trust | direct | current | `device.wait` | 2 leaf missing, daemon routed | methods: `device.observations` |
| app.diagnostics.capture | direct | current | `diagnostics.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.diagnostics.concept | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.diagnostics.hilogSummary | direct | current | `analyze.hilog-summary` | 2 leaf missing, daemon routed | domain leaf; `analyzer.summarize-hilog@1` has no Rust runner, so the isolated daemon does not execute it |
| app.diagnostics.reader | local | current | `diagnostics.inspect` | 2 leaf missing, daemon routed | methods: `job.show`, `artifact.list`, `artifact.read` |
| app.flash.main | direct | current | `flash.prerequisites` | 3 daemon or host owner missing | not routed: `flash.prerequisites` |
| app.flash.plan | direct | current | `flash.lane-preview` | 3 daemon or host owner missing | not routed: `flash.lanePlanPreview` |
| app.flash.runtime | direct | current | `flash.run` | 2 leaf missing, daemon routed | domain leaf; `flash.full-restore@1` has no Rust runner, so the isolated daemon does not execute it |
| app.history.context | direct | current | `workspace.continuation.inspect` | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show` |
| app.history.detail | direct | current | `job.show` | 1 implemented |  |
| app.history.export | direct | current | `artifact.export` | 1 implemented |  |
| app.history.filters | local | current | `history.filter.list` | 1 implemented |  |
| app.history.list | direct | current | `job.list` | 1 implemented |  |
| app.menu.help.traceShortcuts | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.menu.trace.capture | direct | current | `trace.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.menu.trace.filterProcesses | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.menu.trace.open | presentation | current | `trace.inspect` | 3 daemon or host owner missing | not routed: `trace.inspect` |
| app.menu.trace.reload | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.menu.trace.searchEvents | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.overview.environment | direct | current | `runtime.health` | 2 leaf missing, daemon routed | methods: `health` |
| app.overview.hdcImpact | direct | current | `runtime.hdc.impact-preview` | 1 implemented |  |
| app.overview.main | direct | current | `doctor` | 1 implemented |  |
| app.overview.resume | direct | current | `agent.resume` | 1 implemented |  |
| app.settings.diagnostics | local | current | `runtime.support-bundle.preview` | 3 daemon or host owner missing | local; support bundle (ClientKit, #2057) has no Rust port |
| app.settings.general | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.settings.serverDelete | platformService | current | `artifact.import.native-library` | 1 implemented |  |
| app.settings.serverEditor | platformService | current | `artifact.import.native-library` | 1 implemented |  |
| app.settings.servers | platformService | current | `artifact.import.native-library` | 1 implemented |  |
| app.settings.storage | local | current | `runtime.storage.status` | 1 implemented |  |
| app.settings.toolchains | direct | current | `runtime.tool.list` | 1 implemented |  |
| app.settings.traceCache | local | current | `trace.cache.status` | 1 implemented |  |
| app.settings.traceLicenses | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.settings.updates | local | current | `runtime.update.check` | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| app.shell.inspector | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.shell.navigation | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.shell.recovery | direct | current | `human-action.list` | 1 implemented |  |
| app.system.panels | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.trace.artifact | direct | current | `trace.export` | 2 leaf missing, daemon routed | methods: `artifact.inspect`, `artifact.export` |
| app.trace.capture | direct | current | `trace.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.trace.runtime | direct | current | `trace.probe` | 3 daemon or host owner missing | not routed: `trace.probe` |
| app.traceViewer.annotation | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.traceViewer.event | presentation | current | `trace.inspect` | 3 daemon or host owner missing | not routed: `trace.inspect` |
| app.traceViewer.loading | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.traceViewer.range | presentation | current | `trace.inspect` | 3 daemon or host owner missing | not routed: `trace.inspect` |
| app.traceViewer.recent | presentation | current | `job.list` | 1 implemented |  |
| app.traceViewer.shortcuts | presentation | current | — | 1 implemented | presentation only: no CLI leaf |
| app.traceViewer.timeline | presentation | current | `trace.inspect` | 3 daemon or host owner missing | not routed: `trace.inspect` |
| app.viewer.accessibility | local | current | `ui-dump.inspect` | 2 leaf missing, daemon routed | methods: `artifact.list`, `artifact.read` |
| app.viewer.advanced | direct | current | `ui-dump.component-detail` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.viewer.layout | local | current | `ui-dump.inspect` | 2 leaf missing, daemon routed | methods: `artifact.list`, `artifact.read` |
| app.viewer.main | direct | current | `ui-dump.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| app.viewer.properties | local | current | `ui-dump.inspect` | 2 leaf missing, daemon routed | methods: `artifact.list`, `artifact.read` |
| app.viewer.raw | direct | current | `artifact.read` | 1 implemented |  |
| artifact.export | local | current | `artifact.export` | 1 implemented |  |
| artifact.import.abort | direct | current | `artifact.import.abort` | 1 implemented |  |
| artifact.import.append | internal | current | `artifact.import.hap` | 1 implemented |  |
| artifact.import.begin | internal | current | `artifact.import.hap` | 1 implemented |  |
| artifact.import.commit | internal | current | `artifact.import.hap` | 1 implemented |  |
| artifact.import.flash-bundle | direct | current | `artifact.import.flash-bundle` | 1 implemented |  |
| artifact.import.inspect | direct | current | `artifact.import.inspect` | 1 implemented |  |
| artifact.import.inspection | internal | current | `artifact.import.hap` | 1 implemented |  |
| artifact.import.list | direct | current | `artifact.import.list` | 1 implemented |  |
| artifact.import.release | direct | current | `artifact.import.release` | 1 implemented |  |
| artifact.import.workspace-patch | direct | current | `artifact.import.workspace-patch` | 1 implemented |  |
| artifact.inspect | local | current | `artifact.inspect` | 1 implemented |  |
| artifact.list | local | current | `artifact.list` | 1 implemented |  |
| artifact.quota | local | current | `artifact.quota` | 1 implemented |  |
| artifact.read | local | current | `artifact.read` | 1 implemented |  |
| capability.draft | refused | current | `capability.draft` | 1 implemented |  |
| capability.inspect | direct | current | `capability.inspect` | 1 implemented |  |
| capability.install | refused | current | `capability.install` | 1 implemented |  |
| capability.list | direct | current | `capability.list` | 1 implemented |  |
| capability.revoke | refused | current | `capability.revoke` | 1 implemented |  |
| capture.diagnostics@1 | direct | current | `trace.capture` | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| capture.screen-sequence@1 | direct | current | `screen.record` | 2 leaf missing, daemon routed | domain leaf; `capture.screen-sequence@1` runs only against the default root; the isolated daemon reports it unavailable |
| cleanupDebt.continue | direct | current | `recovery.cleanup.continue` | 3 daemon or host owner missing | not routed: `cleanupDebt.continue` |
| cleanupDebt.list | direct | current | `recovery.cleanup.list` | 2 leaf missing, daemon routed | methods: `cleanupDebt.list` |
| commands | local | current | `commands` | 1 implemented |  |
| completion | local | current | `completion` | 2 leaf missing, daemon routed | local: needs no Runtime |
| control-action.list | direct | current | `control-action.list` | 1 implemented |  |
| control-action.reconcile | direct | current | `control-action.reconcile` | 1 implemented |  |
| control-action.show | direct | current | `control-action.show` | 1 implemented |  |
| debug.evaluate | direct | current | `recovery.flash-invocation.evaluate` | 3 daemon or host owner missing | not routed: `debug.evaluate` |
| debug.hap@1 | direct | current | `debug.hap` | 2 leaf missing, daemon routed | domain leaf; `debug.hap@1` runs only against the default root; the isolated daemon reports it unavailable |
| debug.probe | direct | current | `debug.probe` | 3 daemon or host owner missing | not routed: `debug.probe` |
| debug.start | direct | current | `recovery.flash-invocation.start` | 3 daemon or host owner missing | not routed: `debug.start` |
| debug.status | direct | current | `recovery.flash-invocation.status` | 3 daemon or host owner missing | not routed: `debug.status` |
| debug.template.run | direct | deprecated | `debug.template.run` | 2 leaf missing, daemon routed | domain leaf; `debug.template@1` has no Rust runner, so the isolated daemon does not execute it |
| debug.template@1 | direct | current | `debug.template.run` | 2 leaf missing, daemon routed | domain leaf; `debug.template@1` has no Rust runner, so the isolated daemon does not execute it |
| deploy.native-library.app-owned@1 | direct | current | `debug.native.deploy` | 2 leaf missing, daemon routed | domain leaf; `deploy.native-library.app-owned@1` runs only against the default root; the isolated daemon reports it unavailable |
| device.display-name.clear | local | current | `device.display-name.clear` | 1 implemented |  |
| device.display-name.set | local | current | `device.display-name.set` | 1 implemented |  |
| device.observations | direct | current | `device.wait` | 2 leaf missing, daemon routed | methods: `device.observations` |
| device.show | direct | legacy | `device.show` | 4 tombstone per §12 | legacy: next major: `commandRemoved`, replacement `target show --target <id>` |
| diagnostics.export | local | current | `diagnostics.export` | 2 leaf missing, daemon routed | methods: `job.show`, `artifact.list`, `artifact.read` |
| doctor | direct | current | `doctor` | 1 implemented |  |
| flash.bind-current-loader | direct | current | `flash.bind-loader` | 3 daemon or host owner missing | not routed: `flash.bind-current-loader` |
| flash.bootloader-status | direct | current | `flash.bootloader-status` | 3 daemon or host owner missing | not routed: `flash.bootloader-status` |
| flash.continue | refused | removed | `flash.continue` | 1 implemented |  |
| flash.dayu200 | generic | current | `job.submit` | 1 implemented |  |
| flash.device-access | direct | current | `flash.device-access` | 3 daemon or host owner missing | not routed: `flash.device-access` |
| flash.execute | refused | removed | `flash.execute` | 1 implemented |  |
| flash.full-restore@1 | direct | current | `flash.run` | 2 leaf missing, daemon routed | domain leaf; `flash.full-restore@1` has no Rust runner, so the isolated daemon does not execute it |
| flash.install-binding | local | legacy | `flash.install-binding` | 4 tombstone per §12 | legacy: tombstone once the current Loader binding path closes |
| flash.lanePlanPreview | direct | current | `flash.lane-preview` | 3 daemon or host owner missing | not routed: `flash.lanePlanPreview` |
| flash.plan | refused | removed | `flash.plan` | 1 implemented |  |
| flash.postflight | refused | removed | `flash.postflight` | 1 implemented |  |
| flash.prerequisites | direct | current | `flash.prerequisites` | 3 daemon or host owner missing | not routed: `flash.prerequisites` |
| flash.preview | refused | removed | `flash.preview` | 1 implemented |  |
| flash.reconcile-alias | direct | current | `flash.reconcile-alias` | 3 daemon or host owner missing | not routed: `flash.reconcile-alias` |
| health | direct | current | `runtime.health` | 2 leaf missing, daemon routed | methods: `health` |
| help | local | current | `help` | 2 leaf missing, daemon routed | local: needs no Runtime |
| history.filter.delete | local | current | `history.filter.delete` | 1 implemented |  |
| history.filter.list | local | current | `history.filter.list` | 1 implemented |  |
| history.filter.save | local | current | `history.filter.save` | 1 implemented |  |
| human-action.list | direct | current | `human-action.list` | 1 implemented |  |
| human-action.resume | direct | current | `human-action.resume` | 1 implemented |  |
| human-action.show | direct | current | `human-action.show` | 1 implemented |  |
| input.long-press@1 | direct | current | `input.long-press` | 2 leaf missing, daemon routed | domain leaf; `input.long-press@1` runs only against the default root; the isolated daemon reports it unavailable |
| input.swipe@1 | direct | current | `input.swipe` | 2 leaf missing, daemon routed | domain leaf; `input.swipe@1` runs only against the default root; the isolated daemon reports it unavailable |
| input.tap@1 | direct | current | `input.tap` | 2 leaf missing, daemon routed | domain leaf; `input.tap@1` runs only against the default root; the isolated daemon reports it unavailable |
| job.cancel | direct | current | `job.cancel` | 1 implemented |  |
| job.events | direct | current | `job.events` | 1 implemented |  |
| job.evidence | direct | current | `job.evidence` | 1 implemented |  |
| job.list | direct | current | `job.list` | 1 implemented |  |
| job.plan | direct | current | `job.plan` | 1 implemented |  |
| job.reconcile | direct | current | `job.reconcile` | 3 daemon or host owner missing | not routed: `job.reconcile` |
| job.result | direct | current | `job.result` | 1 implemented |  |
| job.run | direct | current | `job.run` | 1 implemented |  |
| job.show | direct | current | `job.show` | 1 implemented |  |
| job.status | direct | current | `job.status` | 1 implemented |  |
| job.submit | direct | current | `job.submit` | 1 implemented |  |
| job.timeline | direct | current | `job.timeline` | 1 implemented |  |
| job.wait | direct | current | `job.wait` | 2 leaf missing, daemon routed | methods: `job.status` |
| maintainer.contracts.check | local | current | `maintainer.contracts.check` | 3 daemon or host owner missing | local; contract bundle export (XPA-018 acceptance) has no Rust port |
| maintainer.contracts.export | local | current | `maintainer.contracts.export` | 3 daemon or host owner missing | local; contract bundle export (XPA-018 acceptance) has no Rust port |
| maintainer.update-feed.assemble | local | current | `maintainer.update-feed.assemble` | 3 daemon or host owner missing | local; update-feed signing (maintainer tooling) has no Rust port |
| maintainer.update-feed.prepare | local | current | `maintainer.update-feed.prepare` | 3 daemon or host owner missing | local; update-feed signing (maintainer tooling) has no Rust port |
| observe.device@1 | direct | current | `target.observe` | 2 leaf missing, daemon routed | domain leaf; `observe.device@1` runs on the isolated daemon |
| operation.describe | direct | current | `operation.describe` | 1 implemented |  |
| operation.example | direct | current | `operation.example` | 1 implemented |  |
| operation.list | direct | current | `operation.list` | 1 implemented |  |
| operation.validate | direct | current | `operation.validate` | 2 leaf missing, daemon routed | methods: `health`, `operation.describe` |
| port-forward.create@1 | direct | current | `port-forward.create` | 2 leaf missing, daemon routed | domain leaf; `port-forward.create@1` runs only against the default root; the isolated daemon reports it unavailable |
| port-forward.remove@1 | direct | current | `port-forward.remove` | 2 leaf missing, daemon routed | domain leaf; `port-forward.remove@1` runs only against the default root; the isolated daemon reports it unavailable |
| recovery.flash-invocation.list | direct | current | `recovery.flash-invocation.list` | 3 daemon or host owner missing | not routed: `recovery.flash-invocation.list` |
| runtime.bundle.inspect | local | current | `runtime.bundle.inspect` | 1 implemented |  |
| runtime.bundle.list | local | current | `runtime.bundle.list` | 1 implemented |  |
| runtime.bundle.register | local | current | `runtime.bundle.register` | 1 implemented |  |
| runtime.bundle.remove | local | current | `runtime.bundle.remove` | 1 implemented |  |
| runtime.hdc.impact-preview | direct | current | `runtime.hdc.impact-preview` | 1 implemented |  |
| runtime.hdc.restart | direct | current | `runtime.hdc.restart` | 1 implemented |  |
| runtime.hdc.status | direct | current | `runtime.hdc.status` | 1 implemented |  |
| runtime.service.install | local | current | `runtime.service.install` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| runtime.service.restart | local | current | `runtime.service.restart` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| runtime.service.status | local | current | `runtime.service.status` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| runtime.service.uninstall | local | current | `runtime.service.uninstall` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| runtime.service.update | local | current | `runtime.service.update` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| runtime.service.verify | local | current | `runtime.service.verify` | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| runtime.signing.install | local | current | `runtime.signing.install` | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| runtime.signing.install-sdk-release | local | current | `runtime.signing.install-sdk-release` | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| runtime.signing.migrate-deveco | local | current | `runtime.signing.migrate-deveco` | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| runtime.signing.remove | local | current | `runtime.signing.remove` | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| runtime.storage.policy | local | current | `runtime.storage.policy` | 1 implemented |  |
| runtime.storage.root | local | current | `runtime.storage.root` | 1 implemented |  |
| runtime.storage.status | local | current | `runtime.storage.status` | 1 implemented |  |
| runtime.tool.inspect | local | current | `runtime.tool.inspect` | 1 implemented |  |
| runtime.tool.list | local | current | `runtime.tool.list` | 1 implemented |  |
| runtime.tool.register | local | current | `runtime.tool.register` | 1 implemented | argv deviates: hdcSocketRefused, macosCompatibilityOption |
| runtime.tool.remove | local | current | `runtime.tool.remove` | 1 implemented |  |
| runtime.tool.select | direct | current | `runtime.tool.select` | 1 implemented |  |
| runtime.update.cancel | local | current | `runtime.update.cancel` | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| runtime.update.cleanup | local | current | `runtime.update.cleanup` | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| runtime.update.download | local | current | `runtime.update.download` | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| runtime.update.handoff | local | current | `runtime.update.handoff` | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| session.cleanup.apply | local | current | `session.cleanup.apply` | 1 implemented |  |
| session.cleanup.preview | local | current | `session.cleanup.preview` | 1 implemented |  |
| session.export.apply | local | current | `session.export.apply` | 1 implemented |  |
| session.export.preview | local | current | `session.export.preview` | 1 implemented |  |
| session.list | local | current | `session.list` | 1 implemented |  |
| session.pin | local | current | `session.pin` | 1 implemented |  |
| session.show | local | current | `session.show` | 1 implemented |  |
| session.unpin | local | current | `session.unpin` | 1 implemented |  |
| signing.install | local | deprecated | `signing.install` | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| signing.install-sdk-release | local | deprecated | `signing.install-sdk-release` | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| signing.migrate-deveco | local | deprecated | `signing.migrate-deveco` | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| signing.remove | local | deprecated | `signing.remove` | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| signing.status | local | deprecated | `signing.status` | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| target.adopt | direct | current | `target.adopt` | 1 implemented |  |
| target.availability | direct | current | `target.availability` | 1 implemented |  |
| target.display-name.clear | local | current | `target.display-name.clear` | 1 implemented |  |
| target.display-name.set | local | current | `target.display-name.set` | 1 implemented |  |
| target.list | direct | current | `target.list` | 1 implemented |  |
| target.show | direct | current | `target.show` | 1 implemented |  |
| trace.cache.purge | local | current | `trace.cache.purge` | 1 implemented |  |
| trace.cache.status | local | current | `trace.cache.status` | 1 implemented |  |
| trace.inspect | local | current | `trace.inspect` | 3 daemon or host owner missing | not routed: `trace.inspect` |
| trace.probe | direct | current | `trace.probe` | 3 daemon or host owner missing | not routed: `trace.probe` |
| update-feed.assemble | local | deprecated | `update-feed.assemble` | 4 tombstone per §12 | deprecated: next major: `maintainer update-feed ...` |
| update-feed.prepare | local | deprecated | `update-feed.prepare` | 4 tombstone per §12 | deprecated: next major: `maintainer update-feed ...` |
| workspace.apply-patch@1 | direct | current | `workspace.patch` | 2 leaf missing, daemon routed | domain leaf; `workspace.apply-patch@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.build-openharmony@1 | direct | current | `workspace.build` | 2 leaf missing, daemon routed | domain leaf; `workspace.build-openharmony@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.continuation.run | direct | current | `workspace.continuation.run` | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show`, `job.submit`, `job.run` |
| workspace.continuation.submit | direct | current | `workspace.continuation.submit` | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show`, `job.submit` |
| workspace.create-checkpoint@1 | direct | current | `workspace.checkpoint` | 2 leaf missing, daemon routed | domain leaf; `workspace.create-checkpoint@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.inspect-diff@1 | direct | current | `workspace.diff` | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-diff@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.inspect-git-status@1 | direct | current | `workspace.status` | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-git-status@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.inspect-source@1 | direct | current | `workspace.inspect` | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-source@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.prepare-isolated-copy@1 | direct | current | `workspace.isolate` | 2 leaf missing, daemon routed | domain leaf; `workspace.prepare-isolated-copy@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.preset.list | local | current | `workspace.preset.list` | 1 implemented |  |
| workspace.preset.register | local | current | `workspace.preset.register` | 1 implemented |  |
| workspace.preset.remove | local | current | `workspace.preset.remove` | 1 implemented |  |
| workspace.preset.show | local | current | `workspace.preset.show` | 1 implemented |  |
| workspace.preset.update | local | current | `workspace.preset.update` | 1 implemented |  |
| workspace.project.list | local | current | `workspace.project.list` | 1 implemented |  |
| workspace.project.register | local | current | `workspace.project.register` | 1 implemented |  |
| workspace.project.remove | local | current | `workspace.project.remove` | 1 implemented |  |
| workspace.project.show | local | current | `workspace.project.show` | 1 implemented |  |
| workspace.project.update | local | current | `workspace.project.update` | 1 implemented |  |
| workspace.read-source-range@1 | direct | current | `workspace.read` | 2 leaf missing, daemon routed | domain leaf; `workspace.read-source-range@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.revert-patch@1 | direct | current | `workspace.revert` | 2 leaf missing, daemon routed | domain leaf; `workspace.revert-patch@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.run-tests@1 | direct | current | `workspace.test` | 2 leaf missing, daemon routed | domain leaf; `workspace.run-tests@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.sign-openharmony-hap@1 | direct | current | `workspace.sign` | 2 leaf missing, daemon routed | domain leaf; `workspace.sign-openharmony-hap@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.sweep-isolated-copies@1 | direct | current | `workspace.sweep` | 2 leaf missing, daemon routed | domain leaf; `workspace.sweep-isolated-copies@1` has no Rust runner, so the isolated daemon does not execute it |
| workspace.symbolize-crash@1 | direct | current | `workspace.symbolize` | 2 leaf missing, daemon routed | domain leaf; `workspace.symbolize-crash@1` has no Rust runner, so the isolated daemon does not execute it |

| Registry leaf not served (111 of 209) | Kind, lifecycle | Category | Note |
| --- | --- | --- | --- |
| `help` | executable, current | 2 leaf missing, daemon routed | local: needs no Runtime |
| `completion` | executable, current | 2 leaf missing, daemon routed | local: needs no Runtime |
| `runtime.health` | executable, current | 2 leaf missing, daemon routed | methods: `health` |
| `runtime.service.install` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| `runtime.service.update` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| `runtime.service.restart` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| `runtime.service.status` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| `runtime.service.verify` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate; record only) has no Rust port |
| `runtime.service.uninstall` | executable, current | 3 daemon or host owner missing | local; LaunchAgent service (maintainer gate) has no Rust port |
| `runtime.signing.install-sdk-release` | executable, current | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| `runtime.signing.install` | executable, current | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| `runtime.signing.migrate-deveco` | executable, current | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| `runtime.signing.status` | executable, current | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| `runtime.signing.remove` | executable, current | 3 daemon or host owner missing | local; signing credentials and Keychain (XPA-015, SPK-10) has no Rust port |
| `runtime.support-bundle.preview` | executable, current | 3 daemon or host owner missing | local; support bundle (ClientKit, #2057) has no Rust port |
| `runtime.support-bundle.export` | executable, current | 3 daemon or host owner missing | local; support bundle (ClientKit, #2057) has no Rust port |
| `runtime.update.check` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `runtime.update.download` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `runtime.update.handoff` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `runtime.update.status` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `runtime.update.cancel` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `runtime.update.cleanup` | executable, current | 3 daemon or host owner missing | local; updater (ClientKit, #2054) has no Rust port |
| `operation.validate` | executable, current | 2 leaf missing, daemon routed | methods: `health`, `operation.describe` |
| `device.wait` | executable, current | 2 leaf missing, daemon routed | methods: `device.observations` |
| `device.list` | executable, legacy | 4 tombstone per §12 | legacy: next major: `commandRemoved`, replacement `target list` |
| `device.show` | executable, legacy | 4 tombstone per §12 | legacy: next major: `commandRemoved`, replacement `target show --target <id>` |
| `target.observe` | executable, current | 2 leaf missing, daemon routed | domain leaf; `observe.device@1` runs on the isolated daemon |
| `trace.probe` | executable, current | 3 daemon or host owner missing | not routed: `trace.probe` |
| `trace.capture` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `trace.inspect` | executable, current | 3 daemon or host owner missing | not routed: `trace.inspect` |
| `trace.export` | executable, current | 2 leaf missing, daemon routed | methods: `artifact.inspect`, `artifact.export` |
| `job.wait` | executable, current | 2 leaf missing, daemon routed | methods: `job.status` |
| `job.watch` | executable, current | 2 leaf missing, daemon routed | methods: `job.events`, `job.status` |
| `job.reconcile` | executable, current | 3 daemon or host owner missing | not routed: `job.reconcile` |
| `recovery.cleanup.list` | executable, current | 2 leaf missing, daemon routed | methods: `cleanupDebt.list` |
| `recovery.cleanup.continue` | executable, current | 3 daemon or host owner missing | not routed: `cleanupDebt.continue` |
| `recovery.flash-invocation.list` | executable, current | 3 daemon or host owner missing | not routed: `recovery.flash-invocation.list` |
| `recovery.flash-invocation.start` | executable, current | 3 daemon or host owner missing | not routed: `debug.start` |
| `recovery.flash-invocation.evaluate` | executable, current | 3 daemon or host owner missing | not routed: `debug.evaluate` |
| `recovery.flash-invocation.status` | executable, current | 3 daemon or host owner missing | not routed: `debug.status` |
| `screen.capture` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `screen.record` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.screen-sequence@1` runs only against the default root; the isolated daemon reports it unavailable |
| `input.tap` | executable, current | 2 leaf missing, daemon routed | domain leaf; `input.tap@1` runs only against the default root; the isolated daemon reports it unavailable |
| `input.long-press` | executable, current | 2 leaf missing, daemon routed | domain leaf; `input.long-press@1` runs only against the default root; the isolated daemon reports it unavailable |
| `input.swipe` | executable, current | 2 leaf missing, daemon routed | domain leaf; `input.swipe@1` runs only against the default root; the isolated daemon reports it unavailable |
| `diagnostics.capture` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `diagnostics.inspect` | executable, current | 2 leaf missing, daemon routed | methods: `job.show`, `artifact.list`, `artifact.read` |
| `diagnostics.preview` | executable, current | 2 leaf missing, daemon routed | methods: `job.show`, `artifact.list`, `artifact.read` |
| `diagnostics.export` | executable, current | 2 leaf missing, daemon routed | methods: `job.show`, `artifact.list`, `artifact.read` |
| `analyze.trace` | executable, current | 2 leaf missing, daemon routed | domain leaf; `analyzer.analyze-trace@1` has no Rust runner, so the isolated daemon does not execute it |
| `analyze.trace-summary` | executable, current | 2 leaf missing, daemon routed | domain leaf; `analyzer.summarize-trace@1` has no Rust runner, so the isolated daemon does not execute it |
| `analyze.hilog-summary` | executable, current | 2 leaf missing, daemon routed | domain leaf; `analyzer.summarize-hilog@1` has no Rust runner, so the isolated daemon does not execute it |
| `analyze.crash-signature` | executable, current | 2 leaf missing, daemon routed | domain leaf; `analyzer.extract-crash-signature@1` runs on the isolated daemon |
| `port-forward.create` | executable, current | 2 leaf missing, daemon routed | domain leaf; `port-forward.create@1` runs only against the default root; the isolated daemon reports it unavailable |
| `port-forward.remove` | executable, current | 2 leaf missing, daemon routed | domain leaf; `port-forward.remove@1` runs only against the default root; the isolated daemon reports it unavailable |
| `workspace.status` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-git-status@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.diff` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-diff@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.inspect` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.inspect-source@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.read` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.read-source-range@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.isolate` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.prepare-isolated-copy@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.checkpoint` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.create-checkpoint@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.patch` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.apply-patch@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.revert` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.revert-patch@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.build` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.build-openharmony@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.test` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.run-tests@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.sign` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.sign-openharmony-hap@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.symbolize` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.symbolize-crash@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.sweep` | executable, current | 2 leaf missing, daemon routed | domain leaf; `workspace.sweep-isolated-copies@1` has no Rust runner, so the isolated daemon does not execute it |
| `workspace.continuation.inspect` | executable, current | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show` |
| `workspace.continuation.submit` | executable, current | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show`, `job.submit` |
| `workspace.continuation.run` | executable, current | 2 leaf missing, daemon routed | methods: `health`, `job.show`, `target.show`, `job.submit`, `job.run` |
| `cleanup-debt.list` | executable, deprecated | 2 leaf missing, daemon routed | methods: `cleanupDebt.list` |
| `cleanup-debt.continue` | executable, deprecated | 3 daemon or host owner missing | not routed: `cleanupDebt.continue` |
| `debug.probe` | executable, current | 3 daemon or host owner missing | not routed: `debug.probe` |
| `debug.hap` | executable, current | 2 leaf missing, daemon routed | domain leaf; `debug.hap@1` runs only against the default root; the isolated daemon reports it unavailable |
| `debug.logs` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `debug.start` | executable, legacy | 4 tombstone per §12 | legacy: next major: named tombstone, replacement `recovery flash-invocation start` |
| `debug.evaluate` | executable, legacy | 4 tombstone per §12 | legacy: next major: named tombstone, replacement `recovery flash-invocation evaluate` |
| `debug.status` | executable, legacy | 4 tombstone per §12 | legacy: next major: named tombstone, replacement `recovery flash-invocation status` |
| `debug.template.list` | executable, current | 2 leaf missing, daemon routed | local: needs no Runtime |
| `debug.template.run` | executable, current | 2 leaf missing, daemon routed | domain leaf; `debug.template@1` has no Rust runner, so the isolated daemon does not execute it |
| `debug.native.deploy` | executable, current | 2 leaf missing, daemon routed | domain leaf; `deploy.native-library.app-owned@1` runs only against the default root; the isolated daemon reports it unavailable |
| `flash.install-binding` | executable, legacy | 4 tombstone per §12 | legacy: tombstone once the current Loader binding path closes |
| `flash.run` | executable, current | 2 leaf missing, daemon routed | domain leaf; `flash.full-restore@1` has no Rust runner, so the isolated daemon does not execute it |
| `flash.device-access` | executable, current | 3 daemon or host owner missing | not routed: `flash.device-access` |
| `flash.bootloader-status` | executable, current | 3 daemon or host owner missing | not routed: `flash.bootloader-status` |
| `flash.prerequisites` | executable, current | 3 daemon or host owner missing | not routed: `flash.prerequisites` |
| `flash.lane-preview` | executable, current | 3 daemon or host owner missing | not routed: `flash.lanePlanPreview` |
| `flash.reconcile-alias` | executable, current | 3 daemon or host owner missing | not routed: `flash.reconcile-alias` |
| `flash.bind-loader` | executable, current | 3 daemon or host owner missing | not routed: `flash.bind-current-loader` |
| `maintainer.update-feed.prepare` | executable, current | 3 daemon or host owner missing | local; update-feed signing (maintainer tooling) has no Rust port |
| `maintainer.update-feed.assemble` | executable, current | 3 daemon or host owner missing | local; update-feed signing (maintainer tooling) has no Rust port |
| `maintainer.contracts.export` | executable, current | 3 daemon or host owner missing | local; contract bundle export (XPA-018 acceptance) has no Rust port |
| `maintainer.contracts.check` | executable, current | 3 daemon or host owner missing | local; contract bundle export (XPA-018 acceptance) has no Rust port |
| `ui-dump.capture` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `ui-dump.component-detail` | executable, current | 2 leaf missing, daemon routed | domain leaf; `capture.diagnostics@1` runs on the isolated daemon |
| `ui-dump.inspect` | executable, current | 2 leaf missing, daemon routed | methods: `artifact.list`, `artifact.read` |
| `ui-dump.hit-test` | executable, current | 2 leaf missing, daemon routed | methods: `artifact.list`, `artifact.read` |
| `agentd.install` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `agentd.update` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `agentd.restart` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `agentd.status` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `agentd.verify` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `agentd.uninstall` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime service ...` (alias warns until then) |
| `signing.install-sdk-release` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| `signing.install` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| `signing.migrate-deveco` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| `signing.status` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| `signing.remove` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `runtime signing ...` |
| `update-feed.prepare` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `maintainer update-feed ...` |
| `update-feed.assemble` | executable, deprecated | 4 tombstone per §12 | deprecated: next major: `maintainer update-feed ...` |

| Registry leaves not served, by category | Leaves |
| --- | --- |
| 2 leaf missing, daemon routed | 53 |
| 3 daemon or host owner missing | 39 |
| 4 tombstone per §12 | 19 |
