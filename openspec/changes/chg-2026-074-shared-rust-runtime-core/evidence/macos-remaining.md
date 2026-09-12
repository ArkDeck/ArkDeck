# Remaining macOS Rust implementation

Updated 2026-09-12 against protected main `a3b384d3`. This list tracks implementation
and review, not published activation or hardware acceptance. Windows product work
and real-device acceptance are outside this goal.

| Task | Submitted/current result | Necessary remaining capability |
| --- | --- | --- |
| XPA-012 | Main #1860 HDC registration, #1861 tool inventory/removal and #1862 Bundle registration | cleanup apply, display-name and selection writers, trace purge, installed host-store composition |
| XPA-013 | Artifact library reads on main; Job-backed RPC/CLI reads passed final local gate; export prepared on an isolated dependent branch | publication, upload/import completion, leases, quota, active-use/release and GC integration |
| XPA-014 | SQLite Job discovery and Artifact owner routing passed final local gate | complete record support, admission, plan, journal/SQLite writes, capability/recovery, execution coordination and handoff |
| XPA-015/016 | Current HDC observation/parsers and process foundation on main | complete analyzer/workspace/HDC providers, supervisor observation and process execution |
| XPA-018 | Several Rust CLI leaves on main; Artifact read leaves in current phase | remaining Runtime commands, contract export, complete CLI migration then Swift CLI removal |
| XPA-019 | Existing ClientKit facade foundation | App adoption and removal of ArkDeckWorkflows dependency |
| XPA-025 | Existing Swift performance baseline | real Rust daemon measurement, Rust soak fixture and benchmark lane migration |
| XPA-017 | Not ready for retirement | ArkForge, final signed packaging/installation, detach actual clients/measurement then retire replaced Swift targets |

Bundle PR #1862 is merged. Job/Artifact PR [#1863](https://github.com/ArkDeck/ArkDeck/pull/1863)
is rebased onto `a3b384d3`; the full local gate and actual Swift-fixture process
checks passed. Remote checks for the rebased head are pending. Cleanup apply, target display names, Artifact export
and upload, and Job events are prepared in isolated worktrees. The original signed Library Bundle capture
validation was previously refused by automatic approval review; its exact native
positive tests remain unexecuted, and unsigned fixtures do not replace them.
