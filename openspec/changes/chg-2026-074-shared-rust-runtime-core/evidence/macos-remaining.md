# Remaining macOS Rust implementation

Updated 2026-09-19 against protected main `2b88705f` (#2008), revision 11. This list tracks
implementation, installed activation and macOS real-device acceptance separately. The current
goal includes pure-Rust macOS GJ-1–5 acceptance; Windows and Linux product work are outside scope.

## Dashboard (update on every merge)

| Routed methods on the standalone Rust daemon | Operations executable in Rust | Golden Journeys on Rust | App facades on ClientKit | Registered CLI feature names on Rust | Swift targets deleted |
| --- | --- | --- | --- | --- | --- |
| 80 / 105 (installed facade serves 3 locally) | 3 / 30 (10%; analyzer, observe, default diagnostic capture) | 0 / 5 | 6 extracted; 9 matching source files remain | 78 / 256 (81 parser command names total) | 0 / 6 |

These are separate coverage measures, not a weighted completion percentage. A routed method or
CLI entry is not proof of complete behavior, installed activation or hardware acceptance. In
particular, Import commit/publication and readback (#1983) and the Import lease lifecycle —
Job-reference inspection and release (#1987) — are delivered. Target availability and HAR list/show
CLI routes are delivered (#1974); live operation discovery is delivered (#1973). At the pinned
main, the Target aggregate consumes the live operation projection (#1978); this does not
add an executable operation or target-readiness claim. HAR resume and its subsequent
Job path are merged (#1981). The isolated authenticated App ingress (#1980) and
ClientKit History readers/JobControl (#1982) do not establish signed App acceptance;
#1985 lets that ingress serve the six History reads (`job.list/show/timeline/evidence`,
`artifact.list/read`) from the Rust owners, still without a Mach listener or signed App
UI. #1984 merges the Rust pointer execution runner and #1998 the port-rule operations on it;
`debug.hap@1` is planned (#1993), admitted (#2000) and run on the same runner (#2005), and the
`capture.screen-sequence@1` Swift oracle is recorded (#2006). The operations measure below
counts none of them. #2003 answers the five HDC control-action methods as Swift's daemon does
without a managed server. #2004 composes the managed HDC server into the isolated owner as a
separate opt-in (`ARKDECK_DEVELOPMENT_HDC_SERVER=managed`), so `runtime.hdc.status` and Target
availability's tool leg answer live facts and a registered HDC is accepted with that
existing-server identity proof, and gives the Rust-serving daemon Swift's SIGTERM/SIGINT drain
and stop. #2008 computes `doctor` from the owners (a standard report on that daemon is ready;
a deep one is blocked only by a fixture HDC's unproven identity).

How each number is measured at the pinned main:

- **Methods:** unique literal method names in the top-level `handle_frame` request-method match
  in `rust/crates/arkdeck-control/src/lib.rs`, excluding its default rejection arm. This counts
  explicit routes even when an owner refuses an unsupported branch. It does not count every
  quoted string elsewhere in the handler. The denominator is the 105 published method schemas.
- **Operations:** an operation counts when the isolated Rust daemon (an
  `ARKDECK_DEVELOPMENT_STATE_ROOT` composition) plans, admits and runs it end to end through
  its control socket: today `analyzer.extract-crash-signature@1`, `observe.device@1` and the
  default legs of `capture.diagnostics@1`. Since #1984, `device_steps.rs` also admits
  `input.tap@1`, `input.long-press@1` and `input.swipe@1`, and the Rust runner consumes the
  capability use before the step intent, dispatches the pointer Provider and records durable
  outcomes — proven only in fixed-root host fixtures (`pointer_input_run`). The daemon's
  mutation authority exists only when its Job store is the account-fixed default root
  (`~/Library/Application Support/ArkDeck/Agentd`,
  `mutation_state_continuity::require_mutation_state`); an isolated development root reports
  the three pointer operations `unavailable` with `runtime.mutationOwnerUnavailable`
  (`operation_availability_control`, asserted since #1984). They are therefore not
  executable on the daemon this measure counts and stay out of the numerator: 3/30. Port
  rules (#1998) and `debug.hap@1` (#2000, #2005) follow the same rule. The
  same rule applies to every `deviceMutation`/`destructive` operation, so GJ-2/3/4 cannot
  raise this count on an isolated root; they count when the daemon that owns the default
  root admits and runs them (the M5 activation, or an earlier reviewed change to that
  authority rule).
- **Golden Journeys:** `REAL_DEVICE_PASS` records on the pure Rust daemon. Fake-HDC/oracle
  replay and the earlier paired-facade acceptance do not increase this count.
- **App / retirement:** six `*ApplicationFacade.swift` files now reside in ClientKit:
  History filter (#1976), History readers and JobControl (#1982), Device list (#1991),
  Trace cache (#1997) and Overview capability (#2007 — ownership only: its reads include
  `trace.probe` and a `debug.template@1` Job that the Rust daemon does not serve, and the App
  ingress admits only `health` and History reads). Nine matching source files remain in
  Workflows, including AutoUpdate and RemoteBuildSource.
  This explicit source inventory replaces the old unaudited 13-facade denominator;
  file movement is not complete App dependency removal. All six retirement targets
  remain, and signed standalone Rust App acceptance (SPK-8) is incomplete.
- **CLI:** unique canonical names returned by the positional-command match in
  `rust/crates/arkdeck-cli/src/lib.rs`, intersected with `feature` in
  `openspec/contracts/cli-feature-coverage.json`. There are 81 parser names, of which 78 match
  the 256 registered feature names. `artifact.import.hap`, `artifact.import.native-library`
  and `device.candidates` are the three unmatched names; they are not added to this numerator.
  Internal RPC strings such as `artifact.import.append` are not CLI command leaves.

Reproduce the source counts from the repository root (read-only; no build or device use):

```bash
python3 - <<'PYCOUNT'
import json
import re
import subprocess

ref = "2b88705f348d43ba00f44e30e2834d4f8371f798"
def read(path):
    return subprocess.check_output(["git", "show", f"{ref}:{path}"], text=True)

control = read("rust/crates/arkdeck-control/src/lib.rs")
match = control.split("let response = match request.method.as_str() {", 1)[1]
match = match.split("\n            _ => Response::failure", 1)[0]
methods = set()
for line in match.splitlines():
    if re.match(r'^ {12}("|\| ")', line):
        methods.update(re.findall(r'"([a-z][a-z.-]+)"', line.split("=>")[0]))
cli = read("rust/crates/arkdeck-cli/src/lib.rs")
match = cli.split("let command = match positional.as_slice() {", 1)[1]
match = match.split("\n    };", 1)[0]
commands = set(re.findall(r'=> "([^"]+)"', match))
coverage = json.loads(read("openspec/contracts/cli-feature-coverage.json"))
features = {entry["feature"] for entry in coverage["entries"]}
print("Routed methods:", len(methods))
print("CLI parser names:", len(commands))
print("Registered CLI feature names:", len(commands & features), "/", len(features))
print("Unmatched CLI names:", sorted(commands - features))
files = subprocess.check_output(
    ["git", "ls-tree", "-r", "--name-only", ref,
     "Packages/ArkDeckKit/Sources"], text=True).splitlines()
for target in ("ArkDeckClientKit", "ArkDeckWorkflows"):
    facades = sorted(path for path in files
                     if f"/{target}/" in path and path.endswith("ApplicationFacade.swift"))
    print(target, "facade files:", len(facades), facades)
PYCOUNT
```

## Milestones (design §G.1 r11)

| Milestone | Golden Journey | Delivers | Lane | State |
| --- | --- | --- | --- | --- |
| M1 | GJ-1 | `observe.device@1`, `capture.diagnostics@1`, `agent.*` with HAR, `human-action.*`, `target.adopt/availability`, `runtime.hdc.*`, restart carry-over | A (+ B for the executor) | in progress: observe/capture and agent run/status (#1920, #1932, #1938), agent list/abandon (#1945, CLI #1946), waiting-execution records (#1953), Target owner/routes (#1959, #1966; CLI #1967), HDC status (#1956), physical-assistance raise and human-action list/show (#1970), host operation availability (#1973), bounded Target availability and HAR CLI reads (#1974), proved Target adoption inside agent.run with commit-gap restart coverage (#1975). HAR resume, adoption and subsequent Job (#1981), live Target operation projection (#1978), development USB relations and the adoption oracle against the real daemon (#1988), CLI `runtime hdc status` (#1992), `runtime hdc impact-preview/restart` (#1995) and `control-action list/show/reconcile` (#1996), the daemon's no-host control-action answers (#2002 frames, #2003 routes), the managed HDC server in the isolated owner with live `runtime.hdc.status` and Target tool leg and Swift's daemon stop (#2004), and `doctor` computed from the owners (#2008). Remaining: trusted USB relation source, the control actions with a managed server (preview, restart, records; their frames and schemas first), and GJ-1 acceptance — the real-device run on the pure Rust daemon is still blocked by #1994's second and third items (no trusted USB relation source; which daemon setup counts before M5 is a maintainer decision); its first item is lifted by #2004's opt-in |
| M2 | GJ-2/3 | Artifact publication and import commit, capability mint/reserve/consume, `debug.*`, `deploy.native-library.app-owned@1`, `capability.*`, `cleanupDebt.*` | A (+ B) | foundations delivered: HAP provider (#1951), native-library provider (#1955), pointer/port-rule providers (#1961), capability store install/consume/outcome writes (#1963), pointer planning (#1964), pointer Runtime capability admission (#1968), pointer execution runner with durable authority (#1984; fixed-root host fixtures only — an isolated root has no mutation owner). Artifact publication and CLI restart readback (#1983), the Import lease lifecycle (#1987), `debug.hap@1` planning (#1993), admission (#2000) and run with compensations and the cleanup-debt ledger (#2005), port-rule operations on the durable runner (#1998) and the `capture.screen-sequence@1` oracle (#2006) are delivered (runs proven in fixed-root host fixtures). Native-library plan/admit/run, the screen-sequence host-store run, `cleanupDebt.*` (after §L.1 item 13), isolated-root versus default-root mutation authority for GJ-2/3, and GJ-2/3 acceptance remain |
| M3 | GJ-5 | 13 `workspace.*` operations, `workspace.preset/project.*`, registered toolchain, hap-sign-tool, Keychain | D | `workspace.project.register/list/show` on the Rust owner with CLI (#1989); the other preset/project methods, toolchain, Keychain/signing and bounded AI journey still require their actual dependencies and SPK-10 evidence |
| M4 | GJ-4 | ArkForge lane through `arkforge-client`, `flash.*`, Rockchip probes, DEC-016 recovery epoch | A + D | Rockchip live-mode probe (#1934), post-flash observation (#1936), Loader transition (#1937) and alias-store primitives/oracle/store (#1939–#1941) are merged. ArkForge lane and flash methods still wait for SPK-9 prerequisites and the §L.1 item 13 ruling |
| M5 | cutover | G.4 preflight, LaunchAgent to the standalone Rust binary, deletions, DMG, lock and traceability flip (TASK-XPA-017) | all | after 018, 019, 025 |

## Tasks

| Task | Status | Submitted/current result | Necessary remaining capability |
| --- | --- | --- | --- |
| XPA-012 | in-progress | Isolated Rust owners for History, Session, Trace cache, Bootstrap, DevEco/HDC registration, tool/bundle registry, Target queries; facade History filter owner (#1888); owner locks unlock on drop (#1903) | tool selection writes, trace database preparation; installed per-store composition withdrawn (r11) — activation only at M5 |
| XPA-013 | in-progress | Artifact read/inspect/export, durable Import upload (#1881), quota query (#1911), device Import binding identity fix (#1969), durable HAP/native-library/workspace-patch publication and CLI readback (#1983), Import leases in Job inputs with reference inspection and release (#1987) | quota/retention/GC and cleanup-debt, the canonical alias HDC route, the publish crash-window matrix — inside M2 |
| XPA-014 | in-progress | Job journal/index/records and analyzer lifecycle; observe/capture and agent run/status/list/abandon; Target observation/adoption/availability routes; live host operation availability (#1973/#1974); agent.run Target adoption (#1975); HDC status; physical-assistance raise and human-action reads; capability store writes, pointer planning and capability admission (#1963, #1964, #1968); pointer execution runner (#1984); development USB relations (#1988); `debug.hap@1` planning (#1993), admission (#2000) and run (#2005); port rules (#1998); no-host control actions (#2002, #2003); screen-sequence oracle (#2006); computed `doctor` (#2008) | M1 trusted USB relation source and remaining HDC lifecycle; M2 integrated authority and device operation execution; M3/M4; recovery after the §L.1 item 13 ruling |
| XPA-015 | ready (r11) | HDC observation/parsers and process foundation; workspace project registration owner and CLI (#1989) | SPK-10, then the rest of M3; the three ArkTrace/hilog analyzers after M4 |
| XPA-016 | in-progress | SPK-6 executor foundation; Rockchip probes/transition/alias store (#1934–#1941); HDC status (#1947); capture providers (#1949); physical relation proof port (#1952); HAP (#1951), native-library (#1955), pointer/port-rule (#1961) providers; the managed HDC server composed into the isolated daemon, with the daemon's stop semantics (#2004) | M1/M2 end-to-end acceptance; M4 ArkForge-served ports after SPK-9 |
| XPA-018 | in-progress | 81 parser command names, 78 matching registered features; target adopt/availability (#1967), HAR list/show (#1974), HAR and agent resume (#1981), workspace-patch import (#1983), Import release (#1987), workspace project (#1989), `runtime hdc status/impact-preview/restart` and `control-action list/show/reconcile` (#1992, #1995, #1996) | remaining commands, full parity/export; Swift CLI retirement with M5 |
| XPA-019 | in-progress | ClientKit transport/models and History filter (#1976), History readers/JobControl (#1982); isolated Rust App ingress (#1980) serving the six History reads (#1985); Device list (#1991), Trace cache (#1997) and Overview capability (#2007) facades | SPK-8 acceptance, remaining facades; hard prerequisite of M5 |
| XPA-025 | in-progress | Rust benchmark launcher/probe (#1972), Rust performance lane integration (#1979); isolated Rust owner soak tool merged (#1977), successful/cancelled/reopen workload; Swift performance baseline; merge-lane micro-benchmarks retired (#1902) | SPK-11 repeated measurements, Rust soak and remaining lanes on the Rust daemon |
| XPA-017 | blocked | — | M5 |

Spikes SPK-6..11 are defined in `tasks.md` and design §J.3; their records land under
`runs/<task>/spk-N-run.md`. The decision package for design §L.1 item 13 is
`adr-0009-decision-package-20260914.md` in this directory.

## History

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
