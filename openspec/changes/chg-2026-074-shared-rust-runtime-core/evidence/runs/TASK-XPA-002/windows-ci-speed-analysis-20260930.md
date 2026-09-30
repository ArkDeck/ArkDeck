# Why the Windows CI lanes are slow, and what may change — 2026-09-30

- Task: TASK-XPA-002 (CI slice CI1)
- Base: protected `main` `b20827ab` (#2344); rebased onto the current main before push.
- Author: Repo Agent on the maintainer's Windows 11 x64 reference host.
- Method: read-only `gh` (`run list`, `actions/runs/<id>/jobs`,
  `actions/jobs/<id>/logs`). No run was re-run, cancelled or dispatched.

## What was measured

Every Swift CI push run created on 2026-09-30 (UTC) up to 06:30 that ran the
Rust lane: **51 runs** (15 on `main`, 36 on `agent/**`; 31 successful, the rest
red for reasons of their own), and in them every job, every step, and the logs
of all 102 Windows jobs (`Rust workspace (windows-latest)` and
`Rust contract parity (windows-latest)`) plus the 50 `ubuntu-latest` and 32
successful `xcode-27` workspace jobs. `windows-clientkit` (#2355, still open)
appeared once (run 36677128808, 0.9 min, red at checkout of an unmerged lane);
it is not on `main`, so it is out of this measurement.

Cache hit or miss comes from the restore step's own output (`Cache restored
from key:` / `Cache not found for input keys:`). Step phases inside `Workspace
tests` come from log timestamps (`Finished \`test\` profile`, first
`Doc-tests`). Queue time is job `started_at - created_at`.

### Jobs (duration in minutes; all 51 runs)

| job | n | median | p90 | max | queue median / max |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rust workspace (xcode-27) | 47 | **12.2** | 15.3 | 17.4 | 0.1 / 3.6 |
| Rust workspace (windows-latest) | 51 | 3.9 | 5.5 | 7.7 | 0.1 / 0.1 |
| Rust contract parity (windows-latest) | 51 | 2.5 | 2.9 | 3.6 | 0.1 / 0.6 |
| Rust contract parity (xcode-27) | 49 | 2.0 | 2.8 | 3.3 | 0.1 / 11.0 |
| Rust workspace (ubuntu-latest) | 51 | 1.9 | 2.1 | 2.3 | 0.1 / 0.6 |
| Rust contract parity (ubuntu-latest) | 51 | 0.9 | 1.2 | 1.5 | 0.1 / 0.7 |
| Rust host-independent checks (policy) | 51 | 0.7 | 0.9 | 1.0 | 0.1 / 0.7 |
| swift-tests (when selected) | 12 | 2.0 | 2.4 | 2.7 | 0.1 / 11.1 |
| app-build (when selected) | 8 | 1.7 | 2.4 | 2.4 | 0.1 / 3.6 |

Swift CI wall clock (push to `swift` aggregate done), successful runs: median
**14.9**, p90 20.7, max 23.1 minutes.

**Critical path.** In all 31 successful runs the last job before the `swift`
aggregate was `Rust workspace (xcode-27)`. The Windows jobs finished 6 to 10
minutes before it in every run. Windows never waits in a queue (max 0.6 min);
macOS jobs did (up to 11 min). So *no Windows-only change shortens Swift CI's
wall clock today*; a Windows saving is runner time and time-to-red for a
Windows-only failure. It will matter for wall clock only if #2352 (signed
runtime tests in the Windows workspace job) or #2355 (`windows-clientkit`)
push a Windows job past the macOS one.

### Where a Windows job's time goes (median minutes, by cache outcome)

| step | workspace MISS (n=34) | workspace HIT (n=17) | parity MISS (n=36) | parity HIT (n=15) |
| --- | ---: | ---: | ---: | ---: |
| checkout (full `main` + SHA) | 0.15 | 0.15 | 0.15 | 0.15 |
| setup-python / pip | 0.00 / 0.12 | 0.00 / 0.12 | 0.00 / 0.12 | 0.00 / 0.10 |
| toolchain (rustup, cached on image) | 0.08 | 0.08 | 0.08 | 0.08 |
| cargo fetch (all host platforms) | 0.23 | 0.23 | 0.22 | 0.22 |
| cache restore (578-663 MB / 143-157 MB) | 0.0 | 0.23 | 0.0 | 0.15 |
| `ci-workspace.py prepare` | 0.13 | 0.08 | 0.12 | 0.07 |
| dev signer (parity only) | - | - | 0.0-0.1 | 0.0-0.1 |
| clippy `--all-targets` | 0.72 | 0.37 | - | - |
| workspace tests | 2.74 | 1.65 | - | - |
| contract parity (candidate view) | - | - | 1.67 | 1.02 |
| helper package / release DMG (`if: runner.os == 'macOS'`) | skipped, 0.0 | skipped, 0.0 | - | - |
| compact | 0.0 | 0.0 | 0.0 | 0.0 |
| save (main only) | 0.25 | - | 0.15 | - |
| **job total** | **4.44** | **3.03** | **2.62** | **2.02** |

Inside `Workspace tests` on a miss: the test build takes 1 m 00 s to 2 m 06 s
(67 crates compiled, then 230 test executables linked), the test binaries run
for 19-122 s, doctests 2-8 s. On a hit with an unchanged Rust tree nothing is
compiled (`Finished ... in 0.3s`), which shows `prepare`'s mtime-preserving
sync does keep Cargo fingerprints valid on NTFS; it is not a cause.

For comparison, a miss costs the macOS workspace job — the critical path — far
more: 13.7 min median on a miss (n=21) against 9.5 on a hit (n=11). Ubuntu:
1.9 against 1.4.

## Findings

### 1. The cache mostly misses, on every host

| job | runs | hits | PR runs | PR hits |
| --- | ---: | ---: | ---: | ---: |
| Rust workspace (windows) | 51 | 17 (33%) | 36 | 11 (31%) |
| Rust contract parity (windows) | 51 | 15 (29%) | 36 | 9 (25%) |
| Rust workspace (xcode-27), successful | 32 | 11 (34%) | 19 | 4 (21%) |
| Rust workspace (ubuntu), successful | 50 | 16 (32%) | 35 | 7 (20%) |

PRs do restore main's cache when the key matches (restore-only; they never
save). They rarely match, for three reasons:

- **The compatibility key hashes every `Cargo.toml` under `rust/`.** The
  Windows workspace job used **20 distinct compatibility keys in four hours**.
  Nearly every Windows slice adds a test target or a dependency, so its key is
  one no `main` run has saved; the `restore-keys` prefix is the full
  compatibility digest, so there is no fallback. Of 34 Windows workspace
  misses, 30 were keys `main` had never saved before the restore.
- **Two runner images serve at once.** `ImageVersion` is part of the key and
  both `20260922.246.2` (39 jobs, 14 hits) and `20260925.250.1` (12 jobs, 3
  hits) served Windows jobs today; each needs its own `main` entry.
- **Retention keeps one entry per host and cache format.**
  `scripts/ci/retain-rust-caches.py` groups by `(host, actions/cache version)`,
  and the version does not see the image or the manifests. After every
  successful `main` run it deletes the previous Windows entry, so the other
  image's entry, and the entry that PRs branched before the last
  `Cargo.toml`-changing merge would match, disappear. 4 of the 34 misses were
  keys `main` had saved and retention had since deleted. At 06:40 the
  repository held exactly one Windows workspace entry (663 MB) and one Windows
  parity entry (157 MB); total Actions cache use was 7.0 of 10 GB.

The once-per-UTC-day save is not the constraint: with the key changing this
often, most days' entries are fresh.

### 2. Windows writes 1.3-1.6 GB of compiler incremental state and throws it away

`compact` reports, for the Windows workspace target on a cold build,
`incrementalBytes` 1.39-1.59 GB of a 4.5-4.8 GB target (macOS: 3.98 of 8.1 GB;
Linux: 1.16 of 5.1 GB). `compact` deletes `debug/incremental` before any
save, so no job ever reads it, and within a job every target is compiled once
(clippy's check artifacts and the test build are different units; the macOS
queue re-runs are no-ops). Incremental compilation is therefore pure cost in
CI: roughly 9,750 small files on NTFS per build.

Local A/B on this host (Windows 11, 16 cores, `CARGO_BUILD_JOBS=4` to match
the 4-vCPU hosted runner, `cargo test --workspace --no-run --locked` at
`b20827ab`, fresh target each time):

| build | default (incremental) | `CARGO_INCREMENTAL=0` |
| --- | ---: | ---: |
| cold, run 1 / 2 / 3 (run 1 of each on a cold disk cache) | 125.7 / 100.8 / 113.1 s | 92.0 / 81.9 / 84.6 s |
| workspace members only (deps kept, `debug/incremental` removed, as after a restore) | 99.4 s | 81.7 s |
| `debug/incremental` written | 1.27 GB, 9,750 files | 0 |
| target size | 4.46 GB | 2.97 GB |

That is 18-27% off the Windows test build, about **0.3-0.5 min** per Windows
workspace job and about 0.1-0.2 min per parity job, with a similar share of the
macOS test build, which is on the critical path. This is the change in the PR.

### 3. Most Windows test binaries run nothing

On Windows, 169 of 230 test executables (171 of 227 on Linux) print
`running 0 tests`: 163 of 240 integration-test files are
`#![cfg(target_os = "macos")]` or `#![cfg(unix)]` at the top. Each is still
compiled (to an empty harness) and linked with MSVC `link.exe`, with a PDB.
Locally (same settings as above, `CARGO_INCREMENTAL=0`), invalidating only
the fingerprints of those 169 zero-test targets and rebuilding took **15.6 s**,
against 30.5 s for all 230 integration targets and ~82-85 s for the whole
cold test build: the empty harnesses are about half of the integration-target
compile-and-link work and roughly a fifth of a cold Windows test build (an
estimated 0.3-0.4 min on the 4-vCPU runner, not measured there).

The lead's figure of "~18 zero-test binaries" is the `arkdeck-agentd` subset;
the whole workspace has about 170.

### 4. Nothing macOS-only runs on Windows

`Rust helper package structure (unsigned)` and `Release DMG pipeline
(fixtures, unsigned)` carry `if: runner.os == 'macOS'` and cost 0.0 min on
Windows; the timing artifact upload is macOS-only too. The only Windows-only
step, `Temporary development daemon signer`, feeds the signed identity matrix
(#2330, `check-readonly.py`) and must stay.

### 5. The Windows parity job is mostly fixed overhead plus one candidate build

In all 51 runs the contract inputs equalled the published base, so the
published view was recorded as covered and only the candidate view ran:
`cargo test -p arkdeck-contract`, the `windows_spk3 process-selftest`,
`cargo build --workspace --bins` in the view's own target and
`check-readonly.py` (the signed/unsigned identity matrix). Each of those is a
Windows answer; none duplicates the workspace job (the view embeds different
contract inputs). About 0.9 min of the job is the fixed setup the workspace
job also pays (checkout, Python, toolchain, fetch, restore, prepare).

### 6. Not causes

- Queueing: Windows jobs started within 0.1 min (max 0.6).
- Toolchain install: 0.08 min (the image carries rustup; `--profile minimal`).
- Defender: GitHub's Windows images are built with real-time monitoring
  disabled and the work drives excluded (runner-images
  `Configure-WindowsDefender.ps1`); not re-verified from these logs, and
  nothing in the workflow could change it without an admin step.
- `prepare`'s mtime sync (see above).

## Options

Savings are per Windows job unless stated, from the medians above.

| # | option | expected saving | risk | changes what CI proves? | disposition |
| --- | --- | --- | --- | --- | --- |
| A | `CARGO_INCREMENTAL=0` in both native Rust jobs, all hosts; value added to the cache key | Windows workspace 0.3-0.5 min, parity 0.1-0.2; macOS workspace test build (2.5 min cold) a similar share, on the critical path; 1.3-4 GB less disk I/O per job | one cold day (new key); none to coverage | no: same sources, profile, tests, hosts and cache trust | **in the PR** |
| B | PR-only broader restore fallback: after the exact prefix, restore the newest `main` entry for the same host, toolchain and image regardless of manifests; `main` keeps exact-compatibility restores so saved archives never accumulate stale products | turns most of the 30/34 "never saved" misses into partial hits: ~1.4 min Windows workspace, ~0.6 parity, **~4 min on the macOS critical path** (13.7 to ~9.5) | stale products in the PR's (never saved) target; Cargo still invalidates them. Widens what a PR may restore, and `test_agent_pr_workflow.py` pins "fallback must retain every compatibility dimension" | no assertion changes; changes the cache restore boundary | **proposal** (maintainer) |
| C | Retention keeps the newest entry per host, format *and image* (put `ImageVersion` in clear in the key so the retention script can group by it), or the newest two per host | 4 of 34 Windows misses directly, plus the image-rotation misses (12 jobs on the second image, 3 hits); +0.8 GB per extra Windows pair, ~3 GB if applied to all hosts (10 GB limit, SwiftPM/Xcode entries 3.5 GB) | cache-size pressure evicting SwiftPM/Xcode entries | no; changes what main keeps, not who writes | **proposal** |
| D | Merge the Windows parity job into the Windows workspace job (one runner, run candidate view after the workspace tests) | ~0.9 runner-min per run; Windows lane becomes ~5.5-6.5 min sequential, still below macOS | job structure pinned by `test_agent_pr_workflow.py`; loses Windows parallelism; different per-host structure | no assertion changes | **proposal** |
| E | Stop compiling the ~170 empty test harnesses on Windows (e.g. consolidate macOS-only integration tests into one harness, or a per-host explicit test list) | ~15 s locally (a fifth of a cold test build), est. 0.3-0.4 min on the runner; also on Linux | a per-host list silently drops new targets; consolidation changes macOS queue scheduling (`run-workspace-tests.py` schedules per target) | compile coverage of the empty files only (clippy `--all-targets` still checks them) | **proposal** |
| F | `-C linker=rust-lld` (ships with the rustup toolchain, no new third-party code) on Windows CI | link-bound share of the test build, commonly 20-40% of link time; not measured | CI binaries linked differently from release (`link.exe`); RUSTFLAGS enter the key | yes: the tested executables are not the release linker's | **proposal**, only with a release-linker parity check |
| G | `debuginfo = "line-tables-only"` for CI | smaller PDBs and faster MSVC links; not measured | `crash_symbolizer_mode`, `workspace_symbolize_process` and the symbolize oracles read debug info; `compact`'s contract keeps debug info usable | yes for symbolization tests | **proposal**, not recommended |
| H | `sccache` | overlaps with the existing cache | new third-party binary and action (SHA pin, cargo-vet does not cover it), a remote/shared cache writable from PRs breaks "PRs never save what main restores" | trust boundary | **not recommended** |
| I | Windows parity: when contract inputs change, run only the identity/transport subset of the published view on Windows | 0 today (published view ran in 0 of 51 runs); ~1-1.7 min on contract-input PRs | narrows a Windows check | yes | **proposal**, not recommended now |

Items that remove or narrow a Windows check (E, I), change what a PR may
restore or what main keeps (B, C), or change the linker or debug info (F, G)
are the maintainer's decision; none is in the PR. Everything that runs on
Windows today still runs on Windows after the PR, `guard` and the `swift`
aggregate are untouched, and the planner and workflow-contract tests are
updated to pin the new variable.

## What the PR changes

- `.github/workflows/rust-ci.yml`: `CARGO_INCREMENTAL: "0"` in the `workspace`
  and `contracts` job env (all three hosts).
- `rust/scripts/ci-workspace.py`: `CARGO_INCREMENTAL` joins the flags in the
  compatibility key, so products built with and without incremental state are
  separate entries.
- `rust/scripts/test_ci_execution.py`: the key test requires that separation.
- `scripts/test_agent_pr_workflow.py`: each native Rust matrix must carry the
  variable exactly once; removing or flipping it fails the contract.
- `rust/README.md` §Build and check: the variable and why.

Expected effect on the next runs: one cold day per host (new key), then the
figures in finding 2. The measured CI effect is to be recorded from the PR's
own run and the first `main` runs after merge.
