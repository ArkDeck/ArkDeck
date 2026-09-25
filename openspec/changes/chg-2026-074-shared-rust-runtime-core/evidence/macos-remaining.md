# Remaining macOS Rust implementation

Updated 2026-09-26 against protected main `4eb8c677` (#2230), revision 11. This list tracks
implementation, installed activation and macOS real-device acceptance separately. The current
goal includes pure-Rust macOS GJ-1–5 acceptance; Windows and Linux product work are outside scope.

## Dashboard (update on every merge)

| Routed methods on the standalone Rust daemon | Operations executable in Rust | Golden Journeys on Rust | App facades on ClientKit | Registered CLI feature names on Rust | Swift targets deleted |
| --- | --- | --- | --- | --- | --- |
| 105 / 105 (installed facade serves 3 locally) | 17 / 30 (57%; by operation below) | 0 / 5 | 16 extracted; 0 matching source files remain | 131 / 256 (187 parser command names total) | 0 / 6 |

Two of the six no longer move (every method is routed, no facade file is left in Workflows) and
the CLI one joins names by spelling, so this refresh adds the numbers below. They sit beside the
six and replace none of them; the notes further down say how each one relates to its measure.

| Supplement | At the pinned main |
| --- | --- |
| Routed methods that reach an owner the daemon composes | 104 / 105 (`trace.inspect` answers the owner-absent default, as Swift's daemon without a Trace inspector does) |
| Operations run end to end on either standalone composition | 25 / 30: the 17, and eight `workspace.*` run only by the production composition under a temporary home |
| Operations the Rust planner materializes | 28 / 30 (not the two Flash operations) |
| Registry leaves the Rust CLI answers | 197 / 209: 187 ported, 10 answered by name as `blockedByProductDefect` |
| CLI ledger entries the parity audit classifies implemented | 244 / 256 (2 leaf missing with the daemon routed, 5 owner missing, 5 tombstones) |
| App sources importing `ArkDeckWorkflows`; `project.pbxproj` lines naming it | 0; 0 (11; 8 at the previous pin, `b958ff44`) |

These are separate coverage measures, not a weighted completion percentage. A routed method or
CLI entry is not proof of complete behavior, installed activation or hardware acceptance. At the
pinned main:

- **Installed product.** What a user runs is still the Swift daemon behind the Rust facade, which
  serves the three History filter methods itself. The standalone Rust daemon's production
  composition over the account's own state is composed and tested under temporary homes but not
  activated (#2136), with the host's trusted USB relations beside its managed HDC (#2137). The
  §G.4 cutover preflight is a one-shot daemon mode (#2142); the Rust `runtime service` leaves
  install, verify, restart, update and uninstall the service (#2141, #2143, #2217); and the release
  script builds the Rust helper pair only behind `ARKDECK_HELPER_RUNTIME=rust`, the Swift pair
  staying the default (#2218).
- **Golden Journeys.** Each Journey has a rehearsal or a development-root run, and none has a
  `REAL_DEVICE_PASS` on a pure Rust daemon. GJ-1 ran against the real DAYU200 on the isolated root
  (#2024), which is development evidence. GJ-2 (#2081), GJ-3 (#2090) and GJ-5 (recorded with #2153)
  were rehearsed against a fake HDC; GJ-5's build and sign legs cannot run on an isolated root.
  GJ-4's Flash is planned, and then refused before the Runtime capability it needs would be issued
  (#2162, #2223).
- **App.** No App source imports `ArkDeckWorkflows`, and the App project links none of the six
  retirement targets (#2139); all sixteen facade files are in ClientKit. The harness for the signed
  App against the standalone Rust Mach service exists (#2114, #2117), but SPK-8's signed acceptance
  has not run.
- **CLI.** 197 of the registry's 209 leaves are answered: 187 are ported, and 10
  (`runtime update *`, `maintainer update-feed *` and its deprecated spelling) are answered by
  name as `blockedByProductDefect` until their subsystems are ported (#2211). The twelve not answered are
  `runtime signing install|install-sdk-release|migrate-deveco|remove` with their deprecated
  `signing` spellings, `runtime support-bundle preview|export`, `flash run` and the legacy
  `flash install-binding`.

How each number is measured at the pinned main (both passes of every count, and the scripts the
static one below does not cover, are in `runs/TASK-XPA-017/dashboard-refresh-20260926-run.md`):

- **Methods:** unique literal method names in the top-level `handle_frame` request-method match
  in `rust/crates/arkdeck-control/src/lib.rs`, excluding its default rejection arm. This counts
  explicit routes even when an owner refuses an unsupported branch. It does not count every
  quoted string elsewhere in the handler. The denominator is the 105 published method schemas.
  The name pattern matches camelCase names (`cleanupDebt.list`, `flash.lanePlanPreview`). Every
  published method has been routed since #2170, so this measure can no longer move. Its
  supplement counts the routes whose `HostServices` method the daemon's `Host` implements
  (`rust/crates/arkdeck-agentd/src/host.rs`): 104, every route but `trace.inspect`, which answers
  the trait's default, `operationUnavailable` from `traceInspectionOwner`. That is also Swift's
  daemon's answer without a Trace inspector (#2163), kept after the reviewed ArkTrace CLI was
  measured (#2176). The number that still moves before M5 is the installed one: the facade serves
  3 methods itself (`facade_owners.rs`) and forwards the rest to Swift's daemon.
- **Operations:** an operation counts when the isolated Rust daemon (an
  `ARKDECK_DEVELOPMENT_STATE_ROOT` composition) plans, admits and runs it end to end through
  its control socket, each against a fake HDC. Under #2078's opt-in — an isolated development
  root, a managed HDC server and `ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY=acknowledged` all
  present — that daemon admits device mutations, and on 2026-09-20 the maintainer ruled that a
  fake-HDC rehearsal on such a root counts (`debug.hap@1`, #2081). The count applies the
  definition as the previous refresh did: a host-only operation reaches no HDC, so the fake-HDC clause binds
  device operations only, and a recorded rehearsal or host acceptance run counts as a committed
  test does. Since #2136 the production composition also runs under a temporary
  `CFFIXED_USER_HOME` in committed process tests, and eight `workspace.*` operations have run end
  to end only there. The definition names the isolated root, so those eight are not counted.
  Whether a production-composition run under a temporary home satisfies this measure is the
  maintainer's call, as #2081's rehearsal was; meanwhile the supplement counts either composition
  (25). `MATERIALIZED` in `rust/crates/arkdeck-hoststore/src/job_plan.rs` bounds both (28), so
  17 ⊆ 25 ⊆ 28. By operation:

  | Operation | Effect | Counted | Evidence at the pinned main |
  | --- | --- | --- | --- |
  | `analyzer.extract-crash-signature@1` | hostOnly | yes (already) | `crash_ledger_analyzer::the_runtime_runs_the_daemon_as_its_own_crash_ledger_analyzer`, `job.submit` and `job.run` on the isolated root (#2144); the GJ-5 rehearsal |
  | `analyzer.summarize-hilog@1` | hostOnly | yes | `hilog_summary_analyzer::the_runtime_runs_the_daemon_as_its_own_hilog_summary_analyzer`, a Job and an agent execution (#2160) |
  | `analyzer.summarize-trace@1` | hostOnly | yes | host acceptance over the reviewed ArkTrace distribution, `trace_summary_analyzer::a_reviewed_distribution_summarizes_the_fixture_trace_on_the_daemon_as_swift_did` (#2167), recorded in `runs/TASK-XPA-015/analyzers-trace-inspect-run.md`; it runs only where a distribution is named, so not in CI |
  | `analyzer.analyze-trace@1` | hostOnly | yes | the same host acceptance, `…_analyzes_the_fixture_trace_on_the_daemon_as_swift_did` (#2169) |
  | `observe.device@1` | readOnly | yes (already) | `rust/scripts/check-corpus-replay.py` over `observe-device` against the isolated daemon (`runs/TASK-XPA-014/observe-device-run.md`); its last recorded pass is 2026-09-24 (`capture-diagnostics-legs-run.md`), and it runs in no CI workflow |
  | `capture.diagnostics@1` | readOnly, deviceMutation | yes (already) | the same harness over its read legs; the GJ-5 rehearsal's crash-log and liveness legs. Its file and Trace legs run on the Rust owner in-process only (#2134) |
  | `debug.template@1` | readOnly | yes | the GJ-5 rehearsal: `agent run` of all four templates (#2122) |
  | `debug.hap@1` | deviceMutation | yes (2026-09-20 ruling) | the GJ-2 rehearsal (#2081); the GJ-5 rehearsal |
  | `deploy.native-library.app-owned@1` | deviceMutation | yes | the GJ-3 rehearsal, deployment and rollback (#2090) |
  | `port-forward.create@1`, `port-forward.remove@1` | deviceMutation | yes | the rehearsal of the oracle's nine submissions and eight runs (#2093) |
  | `capture.screen-sequence@1` | deviceMutation | yes | the rehearsal of the oracle's eight submissions and seven runs (#2093) |
  | `input.tap@1`, `input.long-press@1`, `input.swipe@1` | deviceMutation | yes | `agent_run_cli_process::agent_run_answers_a_workspace_copy_and_every_gesture_through_the_cli`: the real CLI, the isolated root under #2078's opt-in and a managed fake HDC (#2220); the GJ-5 rehearsal |
  | `workspace.prepare-isolated-copy@1` | hostOnly | yes | `workspace_isolation_process::the_isolated_daemon_copies_a_registered_project_and_adopts_the_copy_after_restart` (#2145); `agent_run_cli_process` |
  | `workspace.apply-patch@1` | deviceMutation | yes | the GJ-5 rehearsal, the copy patched through `job submit` and `job run` (#2146); on the production composition also `workspace_patch_process` |
  | `workspace.revert-patch@1` | deviceMutation | no | production composition only: `workspace_patch_process::the_production_daemon_patches_a_copy_and_reverts_it_with_the_real_patch` (#2146) |
  | `workspace.inspect-source@1`, `workspace.read-source-range@1`, `workspace.inspect-git-status@1`, `workspace.inspect-diff@1` | hostOnly | no | production composition only: `workspace_read_process::the_production_daemon_serves_the_workspace_reads_with_the_host_tools` (#2190) |
  | `workspace.create-checkpoint@1`, `workspace.sweep-isolated-copies@1` | deviceMutation, hostOnly | no | production composition only: `workspace_checkpoint_process::the_production_daemon_checkpoints_and_sweeps_with_the_host_tools` (#2192) |
  | `workspace.symbolize-crash@1` | hostOnly | no | production composition only: `workspace_symbolize_process::the_production_daemon_symbolizes_a_devices_crash_with_its_own_one_shot_mode` (#2195) |
  | `workspace.run-tests@1` | deviceMutation | no | materialized, and replayed in-process only (`workspace_test_symbolize_oracle`, #2195); no daemon has run it |
  | `workspace.build-openharmony@1`, `workspace.sign-openharmony-hap@1` | deviceMutation, hostOnly | no | replayed in-process only (#2153). An isolated root can register no DevEco and composes no signing credential owner; the development seams that would let it (P1 and P2 in `runs/TASK-XPA-015/gj5-fake-rehearsal-2026-09-25.md`) await the maintainer |
  | `flash.full-restore@1`, `flash.dayu200` (its alias) | destructive | no | planned by the Flash planner (#2162). `job.submit` answers as Swift's up to capability issuance and then refuses, because the Rust Runtime does not issue the Runtime capability (#2223). There is no run path on `main`, and DEC-016's two recovery stories await their contract |

- **Golden Journeys:** `REAL_DEVICE_PASS` records on the pure Rust daemon. Fake-HDC/oracle
  replay and the earlier paired-facade acceptance do not increase this count, nor does the
  development-root GJ-1 run on the isolated daemon (#2024), which the maintainer's option-A
  ruling classifies as development evidence. No acceptance record has been added under
  `docs/design/references` since the previous pin (`b958ff44`). Of the lines added since then to this change's
  records or those references, 22 mention `REAL_DEVICE_PASS`, and each says that a piece of
  evidence is not one. No installed pure Rust daemon exists yet for a pass to run on.
- **App / retirement:** `*ApplicationFacade.swift` files under `Packages/ArkDeckKit/Sources`, by
  target. Sixteen reside in ClientKit. Nine were there at the previous pin: History filter (#1976),
  History readers and JobControl (#1982), Device list (#1991), Trace cache (#1997), Overview
  capability (#2007), Settings (#2036), remote build source (#2044) and the updater (#2054). Seven
  followed: Trace (#2089), Debug (#2095), UI dump (#2109), HDC client diagnostics (#2112, a new
  facade), Flash and Rockchip device access (#2124) and the runtime support bundle (#2139). None
  remains in Workflows, so the file inventory is saturated. The dependency it stood for is gone
  too: no file under `ArkDeckApp` imports `ArkDeckWorkflows`, and `project.pbxproj` names it
  nowhere (#2139); the App's package products are ArkDeckClientKit, ArkDeckCore and
  ArkDeckTraceAdapter. Signed standalone Rust App acceptance (SPK-8) is incomplete. The six
  retirement targets are the ones TASK-XPA-017 deletes (its production reachability in
  `tasks.md`): `ArkDeckAgentDaemon`, `ArkDeckAgentDaemonMain`, `ArkDeckWorkflows`, `ArkDeckStorage`,
  `ArkDeckProcess` and `ArkDeckOpenHarmony`. All six are still declared in
  `Packages/ArkDeckKit/Package.swift`, and the Swift CLI and the Swift daemon still link them.
- **CLI:** unique canonical names returned by the positional-command match in
  `rust/crates/arkdeck-cli/src/lib.rs`, intersected with `feature` in
  `openspec/contracts/cli-feature-coverage.json`. There are 187 parser names, of which 131 match
  the 256 registered feature names. The ledger spells most features as a daemon method, a Catalog
  operation or an App feature. So 56 served names never match one (`workspace status` serves
  `workspace.inspect-git-status@1`, `device wait` serves `device.observations`), and the
  intersection undercounts. The supplements join on each leaf instead. The Rust CLI's own
  `arkdeck commands --output json`, checked against its copy of Swift's registry
  (`rust/crates/arkdeck-cli/src/command_registry.json`, 209 leaves), answers 197 leaves. Take away
  the ten that `blocked_leaves.rs` answers by name and the rest are exactly the 187 parser names.
  Nine of those 187 are the non-executable leaves that Swift itself answers by name
  (`agent chat`, `capability draft|install|revoke`, `flash plan|preview|execute|continue|postflight`,
  #2079). The parity audit (`runs/TASK-XPA-018/cli-parity-audit.py`) classifies the 256 ledger
  entries as 244 implemented, 2 leaf missing with the daemon routed, 5 owner missing and 5
  tombstones; 9 of the 244 resolve to a leaf answered `blockedByProductDefect`.

Reproduce the static counts from the repository root (read-only; no build or device use):

```bash
python3 - <<'PYCOUNT'
import json
import re
import subprocess

ref = "4eb8c677886e92b4438ba3d03ff80897644c5019"
def read(path):
    return subprocess.check_output(["git", "show", f"{ref}:{path}"], text=True)
def names(path):
    return subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", ref, path], text=True).splitlines()

control = read("rust/crates/arkdeck-control/src/lib.rs")
match = control.split("let response = match request.method.as_str() {", 1)[1]
match = match.split("\n            _ => Response::failure", 1)[0]
methods = set()
for line in match.splitlines():
    if re.match(r'^ {12}("|\| ")', line):
        methods.update(re.findall(r'"([a-zA-Z][a-zA-Z.-]+)"', line.split("=>")[0]))
published = {path.rsplit("/", 1)[1][:-len(".json")] for path in names("spec/control/methods")}
trait = control.split("pub trait HostServices: Send + Sync {", 1)[1].split("\n}\n", 1)[0]
host = read("rust/crates/arkdeck-agentd/src/host.rs")
host = host.split("impl HostServices for Host {", 1)[1].split("\n}\n", 1)[0]
defaults = set(re.findall(r"\n    fn ([a-z_]+)\(", trait)) - set(
    re.findall(r"\n    fn ([a-z_]+)\(", host))
cli = read("rust/crates/arkdeck-cli/src/lib.rs")
match = cli.split("let command = match positional.as_slice() {", 1)[1]
match = match.split("\n    };", 1)[0]
commands = set(re.findall(r'=> "([^"]+)"', match))
coverage = json.loads(read("openspec/contracts/cli-feature-coverage.json"))
features = {entry["feature"] for entry in coverage["entries"]}
print("Routed methods:", len(methods), "/", len(published), "unrouted:", sorted(published - methods))
print("HostServices methods the daemon's Host leaves at the default:", sorted(defaults))
print("CLI parser names:", len(commands))
print("Registered CLI feature names:", len(commands & features), "/", len(features))
files = names("Packages/ArkDeckKit/Sources")
for target in ("ArkDeckClientKit", "ArkDeckWorkflows"):
    facades = sorted(path for path in files
                     if f"/{target}/" in path and path.endswith("ApplicationFacade.swift"))
    print(target, "facade files:", len(facades))
imports = subprocess.run(["git", "grep", "-l", "^import ArkDeckWorkflows", ref, "--",
                          "ArkDeckApp"], capture_output=True, text=True).stdout.split()
print("ArkDeckApp files importing ArkDeckWorkflows:", len(imports))
print("project.pbxproj lines naming ArkDeckWorkflows:", sum(
    "ArkDeckWorkflows" in line for line in read("ArkDeck.xcodeproj/project.pbxproj").splitlines()))
package = read("Packages/ArkDeckKit/Package.swift")
retiring = ["ArkDeckAgentDaemon", "ArkDeckAgentDaemonMain", "ArkDeckWorkflows",
            "ArkDeckStorage", "ArkDeckProcess", "ArkDeckOpenHarmony"]
print("Swift targets deleted:", sum(f'name: "{name}"' not in package for name in retiring),
      "/", len(retiring))
plan = read("rust/crates/arkdeck-hoststore/src/job_plan.rs")
print("MATERIALIZED:", plan.split("const MATERIALIZED: [&str; ", 1)[1].split("]", 1)[0],
      "/", len(names("Catalog/operations")))
PYCOUNT
```

The operations evidence (`count_operations.py`, which checks every citation in the table above at
a ref) and the CLI's answered leaves (`count_cli.py`, after a debug build of the CLI) are in the
run record, with the two commands behind the Golden Journeys count.

## Milestones (design §G.1 r11)

| Milestone | Golden Journey | Delivers | Lane | State |
| --- | --- | --- | --- | --- |
| M1 | GJ-1 | `observe.device@1`, `capture.diagnostics@1`, `agent.*` with HAR, `human-action.*`, `target.adopt/availability`, `runtime.hdc.*`, restart carry-over | A (+ B for the executor) | in progress. Delivered by the previous pin (listed in its row): observe/capture, agent run/status/list/abandon and resume, HAR and human-action reads, the Target owner, adoption and availability, live operation availability, HDC status, the managed HDC server with Swift's stop, `doctor` from the owners, the control actions and the restart impact approval, development USB relations, `job.reconcile`. Since: the console-approved HDC restart end to end — its frames (#2101), the Job interlock (#2102), durable approval and boundary recovery (#2104), the confirmed restart transferring the owned server identity (#2105), the foreground crash boundary (#2107), the replacement ended on stop (#2131), a proved server exit (#2174) and the CLI's foreground approval (#2106); trusted USB relations read from the host I/O Registry as Swift's daemon reads them (#2135), composed beside the production composition's managed HDC (#2137); every `capture.diagnostics@1` leg (#2134); `trace.probe` (#2133); Debug read controls (#2108) and `debug.template@1` as Jobs (#2122); restart carry-over of parked device Jobs by fresh facts and dedicated readbacks, with resume (#2086, #2138, #2140), the runner killed at each crash window (#2092) and unreadable recovery named in `doctor` (#2096); development inputs judged before the managed server launches (#2214). Remaining: GJ-1 `REAL_DEVICE_PASS` on the installed pure Rust daemon, which needs the M5 activation; the isolated-root run against the real DAYU200 (#2024) stays development evidence by the option-A ruling |
| M2 | GJ-2/3 | Artifact publication and import commit, capability mint/reserve/consume, `debug.*`, `deploy.native-library.app-owned@1`, `capability.*`, `cleanupDebt.*` | A (+ B) | in progress. Delivered by the previous pin (listed in its row): the HAP, native-library, pointer and port-rule providers, the capability store, pointer planning and admission, the durable runner, Artifact publication and the Import lease lifecycle, `debug.hap@1` and the native library planned, admitted and run, the screen-sequence run, capability-ledger unknown outcomes, `cleanupDebt.list`, and #2078's development mutation authority with GJ-2's fake rehearsal (#2081). Since: `cleanupDebt.continue` (#2085); the bundled arm64 code-sign helper composed and verified (#2088); fake-HDC rehearsals on the isolated daemon of GJ-3's deployment and rollback (#2090), the port rules and the screen sequence (#2093); the gestures through the real CLI (#2220); App uploads through the Rust ingress (#2132); one device mutation Job per Target at a time in its mutation lane (#2149), Target transactions waiting for each other's locks (#2147), admission waiting while a Session is published (#2207) and a Session published aside and renamed whole under the storage lock, so no mutation is refused over an unfinished one (#2230). Remaining: GJ-2/3 `REAL_DEVICE_PASS` on the installed pure Rust daemon (M5); a real-device leg on a development root still needs the installed daemon booted out of the USB interface for its window |
| M3 | GJ-5 | 13 `workspace.*` operations, `workspace.preset/project.*`, registered toolchain, hap-sign-tool, Keychain | D | in progress. Delivered by the previous pin: `workspace.project.*` and `workspace.preset.*` on the Rust owner with the DevEco pins, and SPK-10's HAP signing (#2031). Since: all 13 `workspace.*` operations materialize and run on the Rust daemon — the Swift oracle of an isolated copy (#2094), copies adopted after restart (#2145), patches applied and reverted (#2146), build and sign (#2153), the four reads (#2190), checkpoint and sweep (#2192), tests and crash symbolization (#2195) — with the operation, project and preset projections Swift's daemon publishes (#2197, #2199, #2215), the tombstone fix (#2204), the dispatcher check at admission (#2206) and the pinned-tool-shim fix in Swift and Rust (#2221); the HiLog summary (#2160), trace summary (#2164, #2165, #2167) and trace analysis (#2169) analyzers, the crash-ledger mode (#2144, #2157) and the answer to a completed host-only agent execution (#2161); `trace.inspect` answered as Swift's daemon without an inspector (#2163, #2176). GJ-5's fake rehearsal on the isolated daemon (recorded with #2153) ran the repro, isolate, patch and verify legs. Remaining: the build and sign legs on a development root (P1 and P2 await the maintainer), the `runtime signing` CLI leaves other than `status`, and GJ-5 `REAL_DEVICE_PASS` (M5) |
| M4 | GJ-4 | ArkForge lane through `arkforge-client`, `flash.*`, Rockchip probes, DEC-016 recovery epoch | A + D | in progress. Delivered by the previous pin: the Rockchip live-mode probe, post-flash observation, Loader transition and alias store (#1934–#1941). Since: ArkForge's crates at the Swift pin, with `flash.device-access` through its public socket (#2151); `arkforged` owned and paired by the daemon, which reads the Loader through it (#2152); `flash.reconcile-alias`, `debug.status` and the Flash invocation list (#2148), `flash.bootloader-status` and `flash.prerequisites` (#2150), the current Loader bound (#2154), the Rockchip state reconciled at start (#2155); DAYU200 flash bundles validated at Import commit (#2158) and uploaded by the App (#2159); both Flash operations planned (#2162); the recovery invocations started and evaluated (#2166); `flash.lanePlanPreview` (#2170, CLI #2168); Swift's Flash admission, run, reconcile and recovery recorded as an oracle, with `job.submit` answered up to capability issuance (#2223). Remaining: the Runtime capability for a Flash, its run and reconcile on the Rust Runtime, DEC-016's complete-overwrite recovery (its two recovery stories await a contract) and GJ-4 on a device with the maintainer's go |
| M5 | cutover | G.4 preflight, LaunchAgent to the standalone Rust binary, deletions, DMG, lock and traceability flip (TASK-XPA-017) | all | not activated. Delivered: the production composition over the account's own state (#2136, #2137), the §G.4 cutover preflight (#2142), the `runtime service` leaves (#2141, #2143) with the typed install's Bootstrap pins (#2216, #2217), the analyzer gate opened by the Rust crash-ledger mode (#2144), the Rust helper pair packaged behind `ARKDECK_HELPER_RUNTIME=rust` (#2218) and the App off `ArkDeckWorkflows` (#2139). Remaining: the LaunchAgent switch with its Developer ID signing (and notarization if G5 requires it), SPK-8, the Swift targets' deletion (0/6) once the Swift CLI and daemon no longer link them, the Rust performance baseline, and the lock and traceability flip |

## Tasks

Status is each task's status line in `tasks.md` at the pinned main. The previous refresh showed
XPA-015 as `ready (r11)` and XPA-019 and XPA-025 as `in-progress`, where `tasks.md` said
`in-progress`, `ready` and `ready` at both pins; the column now shows `tasks.md`'s words. Several of those lines
still carry their 2026-09-11/14 text. Restating or flipping one belongs to the PR that implements
it, not to this dashboard.

| Task | Status | Submitted/current result | Necessary remaining capability |
| --- | --- | --- | --- |
| XPA-012 | in-progress | Isolated Rust owners for History, Session, Trace cache, Bootstrap, DevEco/HDC registration, the tool and bundle registry and Target queries; the facade History filter owner (#1888, #1903); `runtime.tool.select`, its control-action store and the HDC selection ledger in `tools.json` (#2032, #2038, #2046, #2055, #2060); host-check run-directory cleanup (#2013). Since `b958ff44`: Session storage, resource and export requests wait for a held lock, as Swift's owner does (#2222) | a tool-selection owner to settle a pending HDC selection (the production composition refuses to start over one, #2136); trace database preparation; activation only at M5 |
| XPA-013 | in-progress | Artifact read/inspect/export, durable Import upload (#1881), quota (#1911), the Import binding identity fix (#1969), durable HAP/native-library/workspace-patch publication and CLI readback (#1983), Import leases in Job inputs (#1987), startup Artifact GC (#2039), the canonical post-Flash alias route (#2045), the publish crash-window matrix (#2049) and publication off the Trace census (#2059). Since `b958ff44` the Import owner also validates DAYU200 flash bundles at commit (#2158, filed under XPA-017) | GJ-2/3 acceptance inside M2 and activation at M5. The previous refresh still listed quota/retention/GC, the alias route and the crash-window matrix here, all three merged before it (#2039, #2045, #2049) |
| XPA-014 | in-progress | The previous refresh's list: the Job store and analyzer lifecycle, observe/capture and agent executions, Target routes, HDC status, the capability store and admission, the pointer runner, `debug.hap@1`, port rules, the screen sequence and native library, the control actions, the recovery port, `job.reconcile`, development USB relations and mutation authority. Since: `cleanupDebt.continue` (#2085); parked device Jobs reconciled and resumed by readback (#2086, #2138, #2140); the crash-window replay (#2092); unreadable recovery in `doctor` (#2096); the Debug probe and template oracle (#2097) and `debug.template@1` Jobs (#2122); the HDC restart lifecycle (#2101, #2102, #2104, #2105, #2107, #2131); every capture leg (#2134); per-Target mutation lanes and lock waits (#2147, #2149, #2207), with Session publication renamed whole under the storage lock (#2230); the code-sign helper (#2088); the GJ-3, port-rule and screen-sequence rehearsals (#2090, #2093); Swift's quoting of error payloads (#2175); development inputs judged before a launch (#2214) | GJ-1/2/3 acceptance on the installed pure Rust daemon (M5); Flash's capability, run and DEC-016 recovery belong to M4 (filed under XPA-017) |
| XPA-015 | in-progress | HDC observation/parsers and process foundation; the workspace project and preset methods (#1989, #2063, #2064, #2073, #2076); SPK-10 HAP signing (#2031). Since `b958ff44`: all 13 `workspace.*` operations (#2094, #2145, #2146, #2153, #2190, #2192, #2195) with their projections and fixes (#2197, #2199, #2204, #2206, #2215, #2221); the analyzers (#2144, #2157, #2160, #2161, #2164, #2165, #2167, #2169) and `trace.inspect` (#2163, #2176); completed gesture and resumed agent executions answered as Swift does (#2220); GJ-5's fake rehearsal (recorded with #2153) | the build and sign legs on a development root (P1 and P2 await the maintainer); GJ-5 acceptance |
| XPA-016 | in-progress | SPK-6 executor foundation; Rockchip probes, transition and alias store (#1934–#1941); HDC status (#1947); capture providers (#1949); the physical relation proof (#1952); the HAP, native-library, pointer and port-rule providers (#1951, #1955, #1961); the managed HDC server with the daemon's stop semantics (#2004); `sha2` in dev builds (#2022); the loopback-port and lease test fixes (#2042, #2051, #2082). Since `b958ff44`: Debug read controls (#2108), the fake servers a restart leaves reaped (#2128), `trace.probe` (#2133), trusted USB relations from the host I/O Registry (#2135), spawning tests in a binary of their own (#2156), a proved server exit (#2174) | GJ-1/2/3 acceptance on the installed pure Rust daemon (M5). Since #2152 (XPA-017) the Loader observation also reads the daemon's own `arkforged` beside the USB census |
| XPA-018 | in-progress | 187 parser command names, 131 matching registered features; 197 of 209 registry leaves answered, 187 ported and 10 answered by name as `blockedByProductDefect`. Since `b958ff44`: `runtime health`, `operation validate`, `device wait`, `job watch` and `job wait` (#2091, #2098, #2100, #2171); the foreground impact approval (#2106); `debug probe`, `debug template list` and `trace probe|inspect|export` (#2120, #2125, #2172, #2180, #2182); `runtime service` and the cutover preflight (#2141, #2142, #2143, #2216, #2217); parse refusals, read parity, the legacy `--json` and client failure mapping as Swift's (#2173, #2179, #2181, #2187); workspace continuation over the shared Catalog model (#2177, #2178); the domain executor and every domain leaf (#2183, #2184, #2208, #2212, #2228, #2229); the machine-contract bundle export (#2186, #2188, #2189, #2191, #2194, #2196); the aliases, recovery cleanup, diagnostics and ui-dump leaves (#2205, #2209, #2210, #2224, #2225); `runtime signing status` (#2226); the update leaves answered by name (#2211), with the update-feed writes fixed in Swift (#2227); CI and test upkeep (#2193, #2198, #2200, #2202, #2203, #2213) | the twelve leaves not answered (above) and the subsystems behind the ten answered by name; Swift CLI retirement with M5 |
| XPA-019 | ready | ClientKit transport and models; the History filter, History readers and JobControl, Device list, Trace cache, Overview, Settings, remote build and updater facades (#1976, #1982, #1991, #1997, #2007, #2036, #2044, #2054); the isolated App ingress serving the History reads (#1980, #1985). Since `b958ff44`: the Trace (#2089), Debug (#2095), UI dump (#2109), HDC client diagnostics (#2112), Flash and Rockchip device access (#2124) and support bundle (#2139) facades; the App off `ArkDeckWorkflows` (#2139); the Rust App ingress admitting discovery reads, UI dump Jobs, continuations, storage settings, uploads, quota, the Trace cache, the Debug probe and `trace.probe` (#2110, #2113, #2118, #2126, #2132, #2133); offline Flash review from Rust planning, with its facts kept accessible (#2121, #2123); the signed App ↔ standalone Rust Mach harness (#2114, #2117); App-side upkeep (#2103, #2111, #2115, #2127, #2130) | SPK-8's signed acceptance; the UI suites against the installed Rust daemon; hard prerequisite of M5 |
| XPA-025 | ready | Rust benchmark launcher/probe (#1972), Rust performance lane (#1979), the isolated Rust owner soak (#1977), the Swift performance baseline, merge-lane micro-benchmarks retired (#1902), SPK-11 on the isolated daemon (#2070, #2075). Since `b958ff44`: the soak's resident set printed every cycle (#2099); Job payloads released during inventory projection (#2116); calendar autoreleases drained (#2129); stored snapshot pages read in bounded memory (#2185), after which the hosted 4-hour Rust soak passed (run 36130214960, `runs/TASK-XPA-025/snapshot-pager-bounded-run.md`) | SPK-11's repeated measurements and a committed Rust performance baseline, both on a quiet host |
| XPA-017 | blocked | Filed under it since `b958ff44`, its status line unchanged: the production composition (#2136, #2137), the ArkForge lane and Flash work of M4 (#2148, #2150, #2151, #2152, #2154, #2155, #2158, #2159, #2162, #2166, #2168, #2170, #2223) and the Rust helper packaging (#2218) | M5 |

Spikes SPK-6..11 are defined in `tasks.md` and design §J.3; their records land under
`runs/<task>/spk-N-run.md`. The decision package for design §L.1 item 13 is
`adr-0009-decision-package-20260914.md` in this directory; its Ruling section records the
maintainer's 2026-09-19 ruling to port the carriers it names unchanged.

## History

2026-09-26 (`4eb8c677`): 145 merges since `b958ff44`, #2085–#2230 (#2087 among them is the
previous refresh itself): 47 under XPA-018, 24 under XPA-015, 24 under XPA-014, 20 under XPA-019,
16 under XPA-017, 6 under XPA-016, 4 under XPA-025, one under XPA-012 and three untasked (#2087,
#2119, #2201). Every number was recounted at the pin with the commands in
`runs/TASK-XPA-017/dashboard-refresh-20260926-run.md`, each twice, and the same script at `b958ff44`
reprints the previous row. Routes 90 → 105, every published method (#2085, #2108, #2133, #2148,
#2150, #2151, #2154, #2163, #2166, #2170). Operations 4 → 17/30 by the unchanged definition: the
HiLog, trace summary and trace analysis analyzers, `debug.template@1`, the native library, both
port rules, the screen sequence, the three gestures, and the isolated copy and its patch now count,
on committed isolated-root tests or recorded rehearsals. Eight more `workspace.*` operations run end
to end only on the production composition under a temporary home; they count only in the new
supplement (25/30) until the maintainer rules on that composition. GJ on Rust stays 0/5. ClientKit
facade files 9 → 16 with none left in Workflows, and the App no longer links `ArkDeckWorkflows`.
CLI parser names 101 → 187 and registered names 98 → 131 of 256; the new registry count answers
197 of 209 leaves, 187 ported and 10 by name. Swift retirement stays 0/6. By milestone:

- M1: the console-approved HDC restart end to end (#2101, #2102, #2104–#2107, #2131, #2174),
  trusted USB relations from the I/O Registry (#2135, #2137), every capture leg, `trace.probe` and
  the Debug reads (#2108, #2122, #2133, #2134), and parked device Jobs carried over a restart
  (#2086, #2092, #2096, #2138, #2140).
- M2: `cleanupDebt.continue` (#2085), the code-sign helper (#2088), the GJ-3, port-rule and
  screen-sequence rehearsals (#2090, #2093), and per-Target mutation lanes with the Session
  publication they wait on (#2147, #2149, #2207, #2230).
- M3: all 13 workspace operations with their projections (#2094, #2145, #2146, #2153, #2190,
  #2192, #2195, #2197, #2199, #2204, #2206, #2215, #2221), and the HiLog and ArkTrace analyzers
  with `trace.inspect` (#2144, #2157, #2160, #2161, #2163–#2165, #2167, #2169, #2176).
- M4: the ArkForge lane, every `flash.*` read and the recovery invocations (#2148, #2150–#2152,
  #2154, #2155, #2166, #2168, #2170), flash bundle Import (#2158, #2159), and Flash planning and
  admission up to capability issuance (#2162, #2223).
- M5 (none of it activated): the production composition, the cutover preflight, `runtime service`
  and the Rust helper packaging (#2136, #2141–#2143, #2216–#2218); the rest of the CLI port under
  XPA-018; the App's facades and ingress under XPA-019 (#2139 removes its last `ArkDeckWorkflows`
  link).
- Performance: the hosted 4-hour Rust soak passed after #2185 (#2099, #2116, #2129, #2185).

The Status column now shows `tasks.md`'s words: the previous refresh had XPA-015 `ready (r11)` and
XPA-019 and XPA-025 `in-progress`, where `tasks.md` said `in-progress`, `ready` and `ready`. XPA-013's
remaining column no longer lists three items merged before the previous pin (#2039, #2045, #2049).
The header keeps "revision 11": it is the change's revision (`proposal.md` `revision: 11`, since
#1910), which a dashboard refresh does not change. Nothing here is installed activation or
hardware acceptance.

2026-09-20 (`b958ff44`): #2083 and #2084 merged. `completion` joins the parser (101 names, 98
registered), and the operations numerator becomes 4/30: the maintainer ruled that #2081's
fake-HDC `debug.hap@1` rehearsal on the acknowledged development root counts, because the three
operations already counted are fake-HDC runs through the same control socket. Routes stay 90,
GJ on Rust 0/5, facades 9/6, Swift retirement 0/6. Port rules, `deploy.native-library.app-owned@1`
and `capture.screen-sequence@1` stay out: they run on the durable runner in fixed-root host
fixtures, not through an isolated daemon's control socket.

2026-09-20 (`3f033e83`): #2067–#2082 merged. Recounted 90 routes (+1: `job.reconcile`, #2071),
100 parser and 97 registered CLI names (+10: that leaf, #2072, and the nine non-executable
leaves #2079 answers by name), and the same nine ClientKit facade files with six left in
Workflows — #2067, #2077 and #2080 moved subsystems that are not facade files. Executable
operations stay 3/30, GJ on Rust 0/5 and Swift retirement 0/6. #2078 gives an acknowledged
isolated owner development mutation authority under a three-condition opt-in and #2081 records
GJ-2's fake-HDC `debug.hap@1` rehearsal on that daemon; whether such a rehearsal satisfies the
operations measure is put to the maintainer, so the numerator is unchanged here. The daemon
requests a restart's impact approval (#2074) while the restart execution path stays unported;
SPK-11 is recorded on the isolated daemon (#2070, #2075); and the host tests' third macOS 26
race is closed by the lease tests taking their turn and their listeners proving themselves
listening (#2082).

2026-09-20 (`28d2016c`): #2037–#2067 merged. Recounted 89 routes (+8: `cleanupDebt.list`, #2047,
and the seven remaining `workspace.preset.*`/`workspace.project.*` methods, #2063), 90 parser and
87 registered CLI names (+8: the same seven plus `arkdeck commands`, #2065), and nine ClientKit
facade files with six left in Workflows (remote build source #2044, the updater #2054; the
Overview run record and action projections #2048 and the support bundle contract #2058/#2057
moved with them). Executable operations stay 3/30 and GJ on Rust 0/5 by the same rules; Swift
retirement 0/6. The recovery port (§L.1 item 13) advanced through its oracles and
`cleanupDebt.list`; the control actions gained their team-signed, unknown-gate and restart frames
(#2037, #2052) while the Rust restart path stays unported; the host tests' loopback ports moved
below the ephemeral range after two macOS 26 port races red-lighted other PRs (#2042, #2051), and
`sha2` is optimized in dev builds so a debug daemon observes its HDC server within Swift's 1000 ms
budget (#2022). Verification switched to targeted local checks plus the PR's CI (#2015).

2026-09-19 (`cb246207`): #2009–#2036 merged. Recounted 81 routes (+1: `runtime.tool.select`,
#2032), 82 parser and 79 registered CLI names (+1: `runtime tool select`), and seven ClientKit
facade files with eight left in Workflows (Settings, #2036). The route pattern now also matches
camelCase names; none is routed yet, so no count changes. Executable operations stay 3/30:
`deploy.native-library.app-owned@1` (#2011, #2027) and `capture.screen-sequence@1` (#2020) run on
the durable runner only in fixed-root host fixtures, since an isolated root has no mutation
owner. GJ acceptance stays 0/5: GJ-1 on the isolated daemon against the real DAYU200 (#2024) is
development-root evidence by the maintainer's option-A ruling. The §L.1 item 13 recovery port
(#2016 ruling; #2018–#2034) and SPK-10 (#2031) are recorded in the milestone and task rows.
Swift retirement 0/6. Nothing here is installed activation or hardware acceptance.

2026-09-19 (20:30, maintainer): verification policy — before pushing, agents run only targeted
local checks (fmt, clippy/tests of the changed crates, contract/SDD checks when their inputs
change, affected Swift test classes); the unified gate is the PR's GitHub CI (`guard` + `swift`),
and a full local gate is run only to reproduce a red CI lane, one at a time on the host. Run
records carry "Local targeted checks" and "CI" sections. `AGENTS.md` and the chain prompt carry
the rule; the dashboard counts are unchanged.

2026-09-19 (`2b88705f`): #2000–#2008 merged. Recounted 80 routes (+5: `runtime.hdc.impact-preview`,
`runtime.hdc.restart` and `control-action.list/show/reconcile`, answered as Swift's daemon
without a managed server, #2003), 81 parser and 78 registered CLI names (unchanged), and six
ClientKit facade files with nine left in Workflows (Overview capability, #2007, an ownership
move). Executable operations stay 3/30: `debug.hap@1` is admitted (#2000) and runs with its
compensations and cleanup-debt ledger (#2005), but like the pointer and port-rule operations
only in fixed-root host fixtures, since an isolated root has no mutation owner. #2004 lifts the
first of #1994's GJ-1 blockers for the isolated owner's opt-in; GJ acceptance stays 0/5 and
Swift retirement 0/6. #2008 makes `doctor` report the composed owners rather than a fixed
report. Nothing here is installed activation or hardware evidence.

2026-09-19 (`23afca91`): #1986–#1999 merged. Recounted 75 routes (+3: the workspace project
methods, #1989), 81 parser and 78 registered CLI names (+10: Import release, workspace project,
`runtime hdc status/impact-preview/restart`, `control-action list/show/reconcile`), and five
ClientKit facade files with ten left in Workflows (Device list #1991, Trace cache #1997).
Executable operations stay 3/30: port rules (#1998) run on the durable mutation runner in
fixed-root host fixtures, but an isolated root has no mutation owner; `debug.hap@1` is planned
(#1993), not admitted or run. The Import lease lifecycle (#1987) and development USB relations
(#1988) add no counted route. GJ acceptance stays 0/5: the real-device GJ-1 on the pure Rust
daemon is blocked as recorded in #1994. Swift retirement 0/6.

2026-09-19 (`81957589`): #1984 merges the Rust pointer execution runner (capability use
consumed before the step intent, fixed-root mutation continuity, fresh plan/facts checks,
durable outcomes; host-fixture evidence) and #1985 serves the six History reads through the
isolated authenticated App ingress. The script recounts 72 routes, 71 parser names and 68
registered CLI names, and three ClientKit facade files with twelve remaining in Workflows —
all unchanged, because the App ingress is not a `handle_frame` route and neither PR adds a
CLI leaf or moves a facade. Executable operations stay 3/30 by the rule above: the pointer
operations are refused on the isolated root as `runtime.mutationOwnerUnavailable`. Pure-Rust
GJ acceptance 0/5 and Swift retirement 0/6 are unchanged. Nothing here is installed
activation or hardware evidence.

2026-09-19 (`510b4650`): #1983 merges immutable publication for HAP,
application-owned native libraries and workspace patches, durable retry receipts
and CLI-to-daemon restart readback. Recounted 72 routes and 68 registered CLI
names (71 parser names); the other measures remain unchanged. Import reference
inspection/release and end-to-end device mutation remain outstanding. This is
host implementation and validation evidence, not real-device GJ acceptance.

2026-09-19 (`94b28966`): #1978 merges live Target availability, #1981 merges
HAR/agent resume, and #1980/#1982 add the isolated authenticated App ingress and
ClientKit History read/JobControl extraction. Recounted 71 routes and 67 registered
CLI names (70 parser names). Three facade source files are in ClientKit; twelve
matching files remain in Workflows. Executable operations stay 3/30, pure-Rust
GJ acceptance 0/5 and Swift retirement 0/6. The six additional App History read
methods in this candidate are not counted as merged or signed App acceptance.

2026-09-19 (`187321ea`): #1968 merges pointer capability admission, retaining
unknown-outcome and competing-session refusals. Consumption and pointer
execution are not delivered, so executable operations remain 3/30. #1979 merges
the Rust performance lane plumbing; qualified measurements and installed-daemon
acceptance remain outstanding.

2026-09-19 (`98cb3b96`): #1976 merges the ClientKit transport and History filter
extraction (1/13 facades; zero Swift targets retired). #1977 merges the isolated
Rust owner soak workload with local smoke evidence; full installed-daemon IPC,
performance/soak acceptance and SPK-11 remain incomplete. Neither change adds
real-device Golden Journey evidence or installed activation.

2026-09-19 (`bef94236`): #1975 delivers proved Target adoption inside agent.run
and commit-gap restart coverage. This extends an existing execution path and
does not add a route, executable operation or real-device Golden Journey. The
six coverage counts remain unchanged.

2026-09-19 (`1ee1d73d`): #1972 delivers the Rust benchmark launcher/probe, #1973
live operation discovery, and #1974 bounded Target availability plus HAR list/show
CLI. Recounted 69 routes, 68 parser names and 65 registered CLI names independently;
executable operations, GJ evidence, ClientKit and Swift-retirement counts remain
unchanged. The current goal includes macOS real-device acceptance.

2026-09-18 (`d761372b`): refreshed from protected main #1970, after 38 merges since
`b0806334` (#1929). Recounted source routes and canonical CLI names, corrected the earlier
ambiguous counting description, and reconciled M1/M2/M4 and task rows with merged work.
The old dashboard's 60 methods and 63 CLI leaves were not a reproducible same-definition
baseline: the script above reports 62 routes and 59 registered CLI names (62 parser names)
on its `7cebb912` snapshot. Do not infer throughput from the old numbers.
Required `guard` and `swift` checks on `d761372b` were observed successful on 2026-09-18;
this read-back does not claim new tests or hardware acceptance. App, retirement and pure-Rust
Golden Journey completion remain zero.

Evidence for the principal updates: [HAR raise/read and remaining adoption/resume](runs/TASK-XPA-014/agent-human-action-raise-run.md),
[Target CLI and unavailable daemon route](runs/TASK-XPA-014/target-cli-run.md),
[Target daemon composition](runs/TASK-XPA-014/target-observation-routes-run.md),
[capability store writes](runs/TASK-XPA-014/m2-capability-store-writes-run.md),
[pointer planning](runs/TASK-XPA-014/m2-pointer-input-plan-run.md),
[Artifact quota](runs/TASK-XPA-013/artifact-quota-run.md), and
[ArkForge prerequisites](runs/TASK-XPA-017/spk-9-run.md).

2026-09-14 (`7cebb912`): 29 commits since the r11 dashboard (`5e63eb19`): lane A's #1918, #1920,
#1925, #1929, #1932, #1933, #1935, #1938; lane B's #1914–#1931 (SPK-6) and #1921, #1924 (oracles),
#1934, #1936, #1937 (M4); CI trims #1902, #1904, #1905, #1907, #1912. The dashboard row above is
remeasured on this head: methods by the `handle_frame` literals, operations by the three
Catalog operations the isolated Rust daemon runs end to end, CLI leaves by the Rust CLI's
canonical names against the coverage file.

2026-09-12 (`f92acd36`): Bundle PR #1862 merged. Job/Artifact PR
[#1863](https://github.com/ArkDeck/ArkDeck/pull/1863) merged after its full local gate, actual
Swift-fixture process checks and required latest-head CI passed. Cleanup apply, target display
names, Artifact export and upload, and Job events were prepared in isolated worktrees. The original
signed Library Bundle capture validation was previously refused by automatic approval review; its
exact native positive tests remain unexecuted, and unsigned fixtures do not replace them.
