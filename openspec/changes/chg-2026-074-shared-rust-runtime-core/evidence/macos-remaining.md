# Remaining macOS Rust implementation

Updated 2026-09-19 against protected main `abcb9984` (#1972, merged 2026-09-18 UTC), revision 11. This list tracks
implementation and review, not published activation or hardware acceptance. Windows product work
and real-device acceptance are outside this goal.

## Dashboard (update on every merge)

| Routed methods on the standalone Rust daemon | Operations executable in Rust | Golden Journeys on Rust | App facades on ClientKit | Registered CLI feature names on Rust | Swift targets deleted |
| --- | --- | --- | --- | --- | --- |
| 68 / 105 (64.8%; installed facade serves 3 locally) | 3 / 30 (10%; analyzer, observe, default diagnostic capture) | 0 / 5 | 0 / 13 | 63 / 256 (24.6%; 66 parser command names total) | 0 / 6 |

These are separate coverage measures, not a weighted completion percentage. A routed method or
CLI entry is not proof of complete behavior, installed activation or hardware acceptance. In
particular, Import commit/release/inspection still refuse, and the CLI's `target.availability`
has no corresponding native daemon route yet.

How each number is measured at the pinned main:

- **Methods:** unique literal method names in the top-level `handle_frame` request-method match
  in `rust/crates/arkdeck-control/src/lib.rs`, excluding its default rejection arm. This counts
  explicit routes even when an owner refuses an unsupported branch. It does not count every
  quoted string elsewhere in the handler. The denominator is the 105 published method schemas.
- **Operations:** the isolated daemon plans, admits and runs
  `analyzer.extract-crash-signature@1`, `observe.device@1` and the default legs of
  `capture.diagnostics@1`. `job_plan.rs` also materializes `input.tap@1`, `input.long-press@1`
  and `input.swipe@1`, but planning and provider implementations alone do not qualify them as
  executable operations. `device_steps.rs` still admits only observe and capture to its device
  operation set; pointer admission PR #1968 is not merged into this baseline.
- **Golden Journeys:** `REAL_DEVICE_PASS` records on the pure Rust daemon. Fake-HDC/oracle
  replay and the earlier paired-facade acceptance do not increase this count.
- **App / retirement:** the 13 App-facing facades switched to `ArkDeckClientKit`, and the six
  Swift targets removed by XPA-017. The ClientKit target is still absent and all six Swift
  targets remain in `Packages/ArkDeckKit/Package.swift`.
- **CLI:** unique canonical names returned by the positional-command match in
  `rust/crates/arkdeck-cli/src/lib.rs`, intersected with `feature` in
  `openspec/contracts/cli-feature-coverage.json`. There are 66 parser names, of which 63 match
  the 256 registered feature names. `artifact.import.hap`, `artifact.import.native-library`
  and `device.candidates` are the three unmatched names; they are not added to this numerator.
  Internal RPC strings such as `artifact.import.append` are not CLI command leaves.

Reproduce the two source counts from the repository root (read-only; no build or device use):

```bash
python3 - <<'PYCOUNT'
import json
import re
import subprocess

ref = "abcb9984ffe3312db7ceb300396f9e8bcb80dcb9"
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
PYCOUNT
```

## Milestones (design §G.1 r11)

| Milestone | Golden Journey | Delivers | Lane | State |
| --- | --- | --- | --- | --- |
| M1 | GJ-1 | `observe.device@1`, `capture.diagnostics@1`, `agent.*` with HAR, `human-action.*`, `target.adopt/availability`, `runtime.hdc.*`, restart carry-over | A (+ B for the executor) | in progress: observe/capture and agent run/status (#1920, #1932, #1938), agent list/abandon (#1945, CLI #1946), waiting-execution records (#1953), Target owner/routes (#1959, #1966; CLI #1967), HDC status (#1956), physical-assistance raise and human-action list/show (#1970). Remaining: adoption within agent run/resume, resume routes and subsequent Job, development USB relation source and real-daemon replay, daemon target availability, HAR CLI, remaining HDC lifecycle routes and GJ-1 acceptance |
| M2 | GJ-2/3 | Artifact publication and import commit, capability mint/reserve/consume, `debug.*`, `deploy.native-library.app-owned@1`, `capability.*`, `cleanupDebt.*` | A (+ B) | foundations delivered: HAP provider (#1951), native-library provider (#1955), pointer/port-rule providers (#1961), capability store install/consume/outcome writes (#1963), pointer planning (#1964). These are not complete operation admission/run paths; Artifact import completion, authority integration and GJ-2/3 acceptance remain |
| M3 | GJ-5 | 13 `workspace.*` operations, `workspace.preset/project.*`, registered toolchain, hap-sign-tool, Keychain | D | after SPK-10 |
| M4 | GJ-4 | ArkForge lane through `arkforge-client`, `flash.*`, Rockchip probes, DEC-016 recovery epoch | A + D | Rockchip live-mode probe (#1934), post-flash observation (#1936), Loader transition (#1937) and alias-store primitives/oracle/store (#1939–#1941) are merged. ArkForge lane and flash methods still wait for SPK-9 prerequisites and the §L.1 item 13 ruling |
| M5 | cutover | G.4 preflight, LaunchAgent to the standalone Rust binary, deletions, DMG, lock and traceability flip (TASK-XPA-017) | all | after 018, 019, 025 |

## Tasks

| Task | Status | Submitted/current result | Necessary remaining capability |
| --- | --- | --- | --- |
| XPA-012 | in-progress | Isolated Rust owners for History, Session, Trace cache, Bootstrap, DevEco/HDC registration, tool/bundle registry, Target queries; facade History filter owner (#1888); owner locks unlock on drop (#1903) | tool selection writes, trace database preparation; installed per-store composition withdrawn (r11) — activation only at M5 |
| XPA-013 | in-progress | Artifact read/inspect/export, durable Import upload (#1881), quota query (#1911), device Import binding identity fix (#1969) | Import commit/publication, release and reference inspection; leases, active-use/release and GC integration — inside M2 |
| XPA-014 | in-progress | Job journal/index/records and analyzer lifecycle; observe/capture and agent run/status/list/abandon; Target observation/adoption routes; HDC status; physical-assistance raise and human-action reads; capability store writes and pointer planning (#1963, #1964) | M1 HAR resume/adoption and remaining routes; M2 integrated authority and device operation execution; M3/M4; recovery after the §L.1 item 13 ruling |
| XPA-015 | ready (r11) | HDC observation/parsers and process foundation | SPK-10, then M3; the three ArkTrace/hilog analyzers after M4 |
| XPA-016 | in-progress | SPK-6 executor foundation; Rockchip probes/transition/alias store (#1934–#1941); HDC status (#1947); capture providers (#1949); physical relation proof port (#1952); HAP (#1951), native-library (#1955), pointer/port-rule (#1961) providers | daemon composition and M1/M2 end-to-end acceptance; M4 ArkForge-served ports after SPK-9 |
| XPA-018 | in-progress | 66 parser command names, 63 matching registered features; agent list/abandon (#1946) and target adopt/availability (#1967) added | remaining commands including HAR, daemon support for target availability, full parity/export; Swift CLI retirement with M5 |
| XPA-019 | ready (r11) | no ClientKit target; 13 App-facing facades | SPK-8, then the facades one by one; hard prerequisite of M5 |
| XPA-025 | in-progress | Swift baseline retained; isolated Rust performance launcher merged (#1972), with advisory launch/IPC/restart probes | faithful Rust seeded soak workload, full measurement and lane migration; SPK-11 remains incomplete |
| XPA-017 | blocked | — | M5 |

Spikes SPK-6..11 are defined in `tasks.md` and design §J.3; their records land under
`runs/<task>/spk-N-run.md`. The decision package for design §L.1 item 13 is
`adr-0009-decision-package-20260914.md` in this directory.

## History

2026-09-19 (`abcb9984`): #1972 merged the isolated Rust benchmark launcher.
The six coverage counts above are unchanged: this is measurement integration,
not another executable operation, App facade, retired target or hardware journey.
Three empty-store probes are advisory only; full seeded soak and SPK-11 remain open.


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
