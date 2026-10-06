# Windows App coverage integration — 2026-10-07

The coverage exporter previously left the 68 App targets macOS-only and attached CLI-leaf
measurements to GUI claims. This increment applies accepted Windows ruling 10 and joins those
targets to a closed Windows App evidence registry. GUI status, an exact named fixture and a
reviewable run record remain distinct from the argv-conformance fixture for the CLI equivalent.
Missing, duplicate, unknown or orphan registry entries fail rather than silently widening scope.

The official export contains 263 targets: 230 Windows-required and 33 non-App macOS-only.
The 162 CLI targets remain 149 implemented, 11 partial and two not implemented. The 68 App
targets are 59 implemented, one partial and eight deferred. The installed-MSIX update remains
partial; an unpackaged refusal does not prove a signed higher-version same-publisher update.
The eight rich Trace-viewer targets retain the adopted TASK-XPA-021/ruling-66 deferral and no
passing GUI fixture. No existing non-App status, scope, owner, classification or argv fixture is
promoted: all 195 complete non-App JSON rows are identical to the direct parent's export.
The existing three-column serialization digest remains
`0146aaeedba0d30f00d550e79b431178b9929d78b7b7e81d5715497e55df4469`.

Actual lower-layer native Save/Folder and host-focus checks establish the native-panel entry.
The component entry is limited to accepted H.1/H.3 native semantic/source projection: 59
controlled JS exports and 32 independently built previews have closed source and named-fixture
references. It does not add or prove 32 native preview widgets, a production gallery route,
pixel equivalence, human Narrator behavior or real-device acceptance. The component mapping's
17 negative/closure checks and actual DS build are recorded separately in
`windows-component-mapping-20261007-run.md`. The narrow Windows DS test repair normalizes
`path.relative` separators in two observed path lists, preserving the exact census assertion.

The C# coverage check verifies all 68 required targets and the existence of their exact named
test methods/evidence records. The Rust tests deliberately do not read the Windows/docs tree,
so isolated Rust source views remain valid. Source-reference closure establishes reviewability,
not a new execution of each referenced GUI test. Independent source review resolved all 34
distinct named methods and 26 evidence paths and confirmed equality of all 195 non-App rows.

## Local targeted checks

Integration parent: `763c227bf50119dea6708ae376ba89ee6cc2e927` (PR #2621). The four component
packet files were unchanged after synchronizing from their original tested parent. All commands
ran sequentially; Cargo reused owner `tool-select`, its fixed mirror/target and two build jobs.
The helper clears inherited live Runtime/HDC/signer opt-ins. Logs are under
`D:/src/ArkDeck-wt/tools/logs/windows-app-coverage-20261007/`.

| Command | Actual result | Log |
| --- | --- | --- |
| `python rust/scripts/run-cargo.py fmt --all --check` | Exit 1, 40.230 s: Windows OS error 206 command-line length; retained, not a source-format pass | `fmt-all-first.log` |
| `python rust/scripts/run-cargo.py fmt -p arkdeck-cli` | Exit 0, 7.766 s; formats the two changed Rust source files | `fmt-cli-apply.log` |
| `python rust/scripts/run-cargo.py clippy -p arkdeck-cli --all-targets -- -D warnings` | Exit 0, 15.410 s | `clippy-cli.log` |
| `python rust/scripts/run-cargo.py clippy -p arkdeck-agentd --all-targets -- -D warnings` | Exit 0, 14.219 s; direct consumer | `clippy-agentd.log` |
| `python rust/scripts/run-cargo.py fmt -p <each workspace package> --check` | All 13 serial package checks exit 0, 83.981 s | `fmt-packages-final.log` |
| `python rust/scripts/run-cargo.py build -p arkdeck-cli` | Exit 0, 13.278 s; current official exporter | `build-cli.log` |
| Current CLI `maintainer contracts export` to a new isolated directory | Exit 0, 0.557 s; 242 products; every one of the 241 non-coverage products byte-matches current inputs; all 255 input-file hashes unchanged | `official-export-current-path.log`, its `before.json` |
| Current CLI `maintainer contracts check` against current contracts/CLI fixtures | Exit 0, 0.508 s; 242 checked, clean, no missing/unexpected/drifted products | `official-check-current-path.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-cli` | Exit 0, 45.208 s; 277 library cases passed, none failed/ignored | `cli-tests.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-agentd` | Exit 0, 121.596 s; 185 library cases passed, three existing ignored | `agentd-tests.log` |
| `dotnet test App.Tests/ArkDeck.App.Tests.csproj -c Debug --no-restore -m:2 -p:UseSharedCompilation=false --filter FullyQualifiedName~WindowsAppCoverageTests\|FullyQualifiedName~WindowsComponentMappingTests --logger trx` from `windows` | Exit 0, 13.173 s; actual fresh TRX: 18 passed, zero failed/skipped | `windows-metadata-final.log`, `windows-metadata-final.log.trx` |
| `sh scripts/check-sdd.sh` with the supported compatible Python input | Exit 0, 2.756 s; 121 acceptance IDs, zero errors/warnings | `sdd-final.log` |
| `git diff --check` | Exit 0, 0.194 s | `diff-final.log` |

The standalone Windows signed-runtime harness was skipped locally because no host-trusted
test signer was configured. Several native/signer-gated daemon cases return without executing
that optional native path when its opt-in is absent. The numbers above are library-suite results,
not new actual signed-daemon execution or hardware evidence. Configured native and contract
parity lanes run in PR CI. No complete unified gate ran locally.

The first export helper mistakenly selected the obsolete `ArkDeckKitTests/Fixtures/CLI` path.
Its exporter exited zero but the wrapper's product audit failed, so `official-export.log` and
the same-path `official-check.log` are not the final verification. It created 232 untracked
copies outside the actual fixture directory. Each copy was checked against its task-owned
export manifest before guarded removal; the real `ArkDeckContractTests/Fixtures/CLI` inputs
were untouched. The corrected isolated export validates the current path, copies only the
official coverage product if needed, and confirms every other product/input hash. No frozen
oracle is repinned and no LF/CRLF normalization of fixture inputs occurred.

## CI

Direct parent PR #2621 has current-head Swift CI run `37516547250` and SDD Guard run
`37516546337` successful. The six earlier layers also have successful current-head CI.
This uncommitted increment has no PR/run yet; its CI is pending publication. Maintainer review
and protected-main merge are still required before adoption. The coverage census does not
upgrade an installed Runtime or any Golden Journey record.

The CRLF fix is already published through reviewed PR #2608. Preserved real CRLF samples
pass that implementation while tampering, truncation and mixed newlines are refused. The
current fresh Windows GJ-2 first failure remains Runtime startup exit 69 at the HDC ownership
gate, before input staging or a capture Job. No new `artifactIntegrityFailed`, device dispatch,
paired macOS acceptance, GJ-3 rollback or formal GJ-5 pass is claimed by this software increment.
