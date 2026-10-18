# Windows ArkTrace CLI integration — 2026-10-18

Base: protected main `3d3435cab1781c05eeae3daab0e293f20cc8f146`. This increment
connects the Windows offline Trace hop to the recipe-built ArkTrace Rust CLI:
reviewed distribution → doctor → exact raw Artifact inspection → summary/CPU
analysis Jobs → explicit sensitive export. All source Trace bytes in this run
are ArkTrace's checked-in `zlib.htrace`; no HDC or device operation ran. These
are native host software checks, not hardware evidence or `REAL_DEVICE_PASS`.

## Distribution and behavior

The producer is ArkTrace clean source
`6f2a510bc6da306d786531a4949738609f8d82c7`, with Windows parser recipe
`ffb9f0c0fd3478f8d9bb4b962cea795469748c69460f396dce949998d0fe7075`.
The local package's manifest SHA-256 is
`d9098ec016da96093633e4b0fd5a6e0838cc350832d62001f56a3c4c1cd6d42f`,
tree SHA-256
`4cf67778626212ee4ae4f65a33c904cee5475166087cc813c5dfdc8f51eb90d9`,
and signed CLI SHA-256
`978f3a222fb1a11056e1396ef6b14e1a3fcffb6a93f85351a2b361b252eaf085`.
All three images passed Authenticode verification against the existing
`ArkDeck Development Daemon (host-trusted only)` publisher. No timestamp or
production-signing claim is made.

The Windows manifest has its own closed schema and NTFS tree-digest vocabulary.
ArkDeck validates the x64 PE images, publisher, whole hashes, exact parser
recipe, runtime/index contract and all 110 files. Attribution includes the
common 18 texts, 6 Windows texts, and the byte-identical frozen inventory of 37
Cargo dependencies and 75 Rust texts. The Rust inventory is vendored as metadata;
the distribution supplies and pins its actual license files. The runtime
generation adds the exact distribution manifest as its 111th pinned file.

The loader captures the verified installation into a private versioned Runtime
directory. Source, installed resources and ancestors stay held across launch;
the existing verified-tool runner supplies the minimal environment, NUL stdin,
suspended identity check, Job Object and bounded cleanup. Runtime invocation
storage is private and separate from the standalone CLI cache. No existing ACL
is repaired: unsafe installation/storage ancestry is refused.

The version directory uses the full manifest digest, which already includes
the tree digest. A redundant second digest had pushed a daemon's executable
path beyond the native trust-provider caller limit: the same signed CLI worked
in the shorter library-test path and failed natively in the daemon path. The
compact exact-manifest name fixes that composition. ArkTrace now rejects an
installed CLI filename of 260 or more UTF-16 code units before native trust,
using its existing path-free stderr failure when executable identity is absent.
ArkDeck applies the same limit before its own distribution publisher check;
overlong ASCII and non-BMP filenames receive a controlled refusal before file
or native trust access.

`trace.inspect` follows the existing owner order and raw diagnostics Artifact
rules, including `capture.diagnostic-session@1`. It maps the CLI's closed,
path-free `inspect --json --no-cache` envelope to `arkdeck.trace-inspection/1`.
`engine.sourceRevision` is the reviewed distribution's source revision, as the
post-G5 follow-up in TASK-XPA-015 §9–10 requested. Quality messages are discarded
by ArkTrace's machine boundary; category/scope/count survive. The two actual
missing Job/Artifact refusals are added to the ControlFrames corpus and
`resourceNotFound` is added to the generated method vocabulary. Existing
`invalidInput` and `artifactIntegrityFailed` codes remain published when the
minimal corpus is re-derived.

Without a selected valid distribution, the existing structured unavailable
answers remain. macOS loader behavior and its owner-absent Rust inspection
answer are unchanged. No Catalog operation, device authority, capability,
hardware acceptance or rich Viewer scope changes.

## Local targeted checks

Logs are retained under
`D:/src/ArkDeck-wt/tools/arktrace-cli-handoff-20261018/`.

| Check | Exit/result | Log |
| --- | --- | --- |
| Producer CLI/engine/FFI native tests | 0; 20 + 38 + 6 pass | `rust-closure-crate-tests.log` |
| Producer native clippy for CLI/engine and FFI | 0 | `rust-closure-clippy.log`, `rust-closure-ffi-clippy.log` |
| Producer closed distribution contract | 0; 16 pass | `rust-closure-distribution-contract.log` |
| Frozen Cargo workspace/license inventory | 0; 8 crates, 37 dependencies | `rust-closure-workspace-contract.log` |
| Producer CI planner regression | 0 | `rust-closure-ci-plan-final.log` |
| Signed package + archive verification | 0; all three signatures valid | `signed-final-package.log` |
| Installed CLI native smoke | 0; 27/27 pass | `signed-final-smoke-final.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-platform -p arkdeck-contract -p arkdeck-hoststore -p arkdeck-agentd --lib` | 0; 619 pass, 6 existing/explicit external-input cases ignored | `arkdeck-final-library-tests.log` |
| Native clippy for changed crates and their direct consumers, `--all-targets -- -D warnings` | 0 | `arkdeck-final-clippy-pass.log` |
| Final native trust-path regression, `test -p arkdeck-platform --lib windows::arktrace::tests::overlong_publisher_paths_are_refused_before_native_trust` | 0; 1 pass | `arkdeck-final-native-trust-path-regression.log` |
| Native clippy after the final path guard, same 13 crates and flags | 0 | `arkdeck-final-native-trust-path-clippy.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-hoststore --lib arktrace_windows::tests:: -- --include-ignored --nocapture` | 0; 6/6 pass against the final package | `arkdeck-final-signed-qualification.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-cli --test trace_inspect` | 0; 4/4 pass | `arkdeck-final-cli-trace-tests.log` |
| `python rust/scripts/run-cargo.py test -p arkdeck-agentd --test windows_trace_offline_process --test windows_trace_export_process -- --include-ignored --nocapture` | 0; 8/8 pass, including real distribution and development signer inputs | `arkdeck-final-daemon-trace-tests.log` |
| Real current CLI → signer-verified named pipe → fixture inspection and export; scoped stop of its own daemon | 0; both results pass, source/Job/index unchanged, owned daemon stopped | `arkdeck-final-signed-cli-pass.log` |
| `python Packages/ArkDeckKit/Scripts/generate-control-contract.py --check`; `python rust/scripts/generate-contract.py --check` | 0; 110 methods, 1085 frames | Terminal check; generated baseline committed with the two native refusal frames |
| `python -m unittest discover -s rust/scripts -p test_catalog_test_views.py -v` | 0; 35/35 pass | `arkdeck-final-catalog-views-tests.log` |
| Snapshot copy/concurrent-edit regressions plus the actual Windows `include_bytes!` dependency closure | 0; 2 + 1 pass | `arkdeck-ci-fix-contract-input-regressions.log`, `arkdeck-ci-fix-embedded-input-closure.log` |
| Exact native SQLite replay diagnostic, `test -p arkdeck-hoststore --lib job_index_tests::recorded_swift_indexes_replay_on_the_linked_sqlite -- --exact --nocapture` | 0; 1 pass in 8.50 s, 156 indexes and 408 rows | `arkdeck-ci-sqlite-replay-native.log` |
| `python rust/scripts/test_contract_checks.py`, native broad attempt before the final closure-only test was added | 1; 75 pass, 1 POSIX-mode failure, 1 skip | `arkdeck-ci-fix-contract-isolation-tests.log` |
| Closed routing manifest against native `run-cargo.py metadata --format-version 1 --no-deps` | 0; 960 sources, 6502 fixtures, 335 targets | `arkdeck-final-inventory-validation-pass.log` |
| `sh scripts/check-sdd.sh` (`PYTHONUTF8=1`, native Git Bash) | 0; 0 errors/warnings, 121 acceptance IDs | `arkdeck-final-sdd.log` |
| `python rust/scripts/run-cargo.py fmt --all --check` | 1; native Windows command length, OS error 206, before formatting | `arkdeck-final-fmt-all-check.log` |
| `rustup run 1.99.0 rustfmt --edition 2024 --check` over all 18 affected Rust files | 0 | `arkdeck-final-fmt-targeted.log` |

The native clippy command selected `arkdeck-agentd`, `arkdeck-bootstrap`,
`arkdeck-cli`, `arkdeck-client`, `arkdeck-contract`, `arkdeck-control`,
`arkdeck-hoststore`, `arkdeck-platform`, `arkdeck-provider-arkforge`,
`arkdeck-provider-hdc`, `arkdeck-provider-workspace`, `arkdeck-rockchip-binding`
and `arkdeck-soak`, using one `-p` argument per crate. The session reused its
fixed external Cargo mirror/target and `CARGO_BUILD_JOBS=2`. No complete local
unified gate, macOS Swift/App build, or performance acceptance ran.

The broad isolation-test attempt's existing `RunDirectoryTests` expects POSIX
mode `0700`; native Windows reports `0777`. That assertion is unchanged. The
three new snapshot regressions pass directly; the complete script also runs in
the host-independent Linux CI lane.

The smoke covers extensionless htrace Artifact IDs for inspect/summary/analysis,
an extensionless systrace summary, a still-refused explicit unsupported suffix,
directory relocation, all attribution, complete-error output budgets, and
resource/parser tamper refusals. The Runtime qualification checks actual
host-only Job admission/run/publication for both analyzer operations, exact
Artifact hash/metadata and explicit sensitive export, unchanged capture Job and
Artifact index during inspection, and negative publisher/timestamp/pin/tree/
license/manifest cases. The live distribution tests are explicitly ignored in
ordinary CI unless real external inputs are supplied; the checked-in manifest
and inspect vectors are metadata, never executable stand-ins.

The signed-CLI process check consumes the same host fixture through the actual
Windows daemon, not a mocked transport. Startup recovery first settles the
deliberately unrun fixture capture; its Job row/files and Artifact index are
compared immediately around inspection. Exported bytes are the same 67,837-byte
fixture with SHA-256
`eb196eeb30c6b959c23d5e18d159ec946ba664ee8d9bc6f1acc32947b4ff5cfe`.
The helper stops only its own development scope through that process's stop
event. No installed Runtime or HDC server is stopped.

The explicit private root qualified on this host. Its default AppData ancestry
did not meet ArkTrace's privacy requirements and remains refused. Production
publisher/timestamp signing and a clean host without development runtimes have
not been qualified. Installed capture/inspect/export acceptance must use a
reviewed published Runtime and fresh device results; this fixture run cannot
replace it. TASK-XPA-021 and platform conformance are not self-approved here.

## CI

[ArkDeck #2671](https://github.com/ArkDeck/ArkDeck/pull/2671) is the consumer of
[ArkTrace #37](https://github.com/ArkDeck/ArkTrace/pull/37); the producer merges
first. Initial ArkDeck run `39126998068` passed Swift tests and host-independent
Rust checks, but the Windows ClientKit check found the generated fingerprint
for `trace.inspect` stale. `python windows/scripts/generate-clientkit.py --write`
regenerated its single changed method fingerprint; `--check` then passed (exit
0). No wire fields or error assertions changed in that correction. The current
CI outcome is recorded on the PR without amending a green head.

Producer full PR CI `39127507036` and push CI `39127502829` passed at
`207f21a89b8eab98530f0cd7cba3ec25d10c5794`. ArkTrace #37 merged on 2026-10-18
as `c6138a9d6725313fe40866b32c6031151831eba7`.

Consumer run `39127518840` then passed ClientKit, Swift and Linux Rust checks,
but Windows contract parity could not compile its isolated views: their copy
omitted the four package-side ArkTrace metadata files embedded by the current
implementation. Each view now receives the same frozen bytes at the original
repository paths, with their hashes recorded and concurrent edits refused.
Regression tests verify the actual embedded dependency closure, exact copying,
and identical bytes across all four views despite a concurrent source edit.

The same run records `a_cold_server_becomes_ready_and_is_bound_to_its_launch`
refusing an already occupied fixture endpoint on macOS. That HDC test and its
implementation are unchanged by this increment; the failure remains in the
retained CI log. The unchanged test and complete macOS workspace passed on the
final head.

Final consumer [Swift CI 39129290717](https://github.com/ArkDeck/ArkDeck/actions/runs/39129290717)
passed at `05472650ce818eef3bc504ab355eb4f8f3ff977e`: Swift tests, Windows
ClientKit, host-independent checks, all three Rust workspaces, all three
contract-parity lanes and the required `swift` aggregate. The Linux isolation
suite passed 78/78. The Windows parity log contains successful execution
receipts for published, candidate, historical and observed views; its index
replay test completed normally in every view. The earlier in-progress log
download was a delayed snapshot, not evidence of a hung test. App build was
skipped by the diff planner.

[SDD Guard 39129290687](https://github.com/ArkDeck/ArkDeck/actions/runs/39129290687)
and the final PR-description guard
[39135757326](https://github.com/ArkDeck/ArkDeck/actions/runs/39135757326) passed.
After rechecking the exact head and protected main's required `guard`/`swift`
contexts, ArkDeck #2671 merged on 2026-10-18 as
`7ca8b97b76f2b3120c6457ecd40727a9f6db55f3`. This follow-up records final results
without changing the validated functional head. Production signing, clean-host
and device acceptance remain unqualified.
