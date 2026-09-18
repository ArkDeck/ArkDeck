# Rust performance lane migration

Date: 2026-09-19. Base: protected main `98cb3b96` (#1977).

The scheduled macOS measurement and soak jobs build `arkdeck-agentd` and
`arkdeck-soak` with locked release Cargo builds. SwiftPM products and private
ArkForge package credentials are no longer needed by this workflow. Existing
schedules, resource gates, advisory shared-host capture and comparison policy
remain in place. The Swift reference baseline remains unchanged.

`bench capture --runtime-kind rust` selects the isolated Rust composition for
all cold starts, seeded Job reads and the idle resource window. Captures record
`toolchain.runtimeKind` beside executable hashes. The compatibility default is
Swift for callers intentionally retaining historical measurements. The existing launcher keeps temporary
roots canonicalized before serving as endpoint and owner paths.

Validation so far: all 127 Python harness tests pass, including both runtime
compositions across the full sampling orchestration. An empty or incompatible seed fails before IPC measurement instead of yielding
an artificially cheap empty-store result. Workflow YAML parses and
both measurement jobs use Cargo. The initial sandbox attempt could not run `ps`;
the complete suite passed with host process inspection permission. The unified repository gate also passed (exit 0; only common checks selected
for this diff), using the pinned validation venv and no filter/skip. Log:
`/private/tmp/arkdeck-performance-lanes-gate.log`. Actual release binary capture is recorded below; CI remains pending.

No device or installed service is touched. A shared-host capture is advisory;
this slice does not claim a qualified Rust reference baseline, a 24-hour soak
result, SPK-11 completion or GJ hardware evidence. Real-device metrics and the
existing unmeasured budget rows remain explicit gaps.

## Actual release capture integration

Both Rust release executables built successfully at `67d56089` with
`cargo build --offline --locked --release --jobs 2 -p arkdeck-agentd -p arkdeck-soak`.
The first full capture found that the existing long-lived client exceeded the
Rust daemon's 128-frame connection budget and received a broken pipe. No server
limit was raised: the harness now renews and verifies its connection between
every 32 iterations (three measured requests per iteration), outside the
measured send/receive intervals. The scale records this batch size. Failed
requests are never replayed; transport failures become explicit ControlError.

The 127-test suite verifies both runtime selections, the exact number of
measured requests and re-authenticated connection renewals. The unified gate
passed again after this correction. The actual three-run capture completed with the default sample counts and
120-second resource window, explicitly `--allow-loaded-host`. Each run measured
50 cold starts and 1,000 samples each of health, Job list and Job status, against
20 readable seeded Jobs. Ten metrics were measured and ten existing gaps
remained. The result is **UNSTABLE**, `baselineEligible=false`: six metrics had
p95 spread above 30%. Exit 0 means advisory capture completed, not budget or
SPK-11 acceptance.

Local output (not committed as a baseline):
`/private/tmp/arkdeck-rust-performance-capture-20260919/perf-baseline-2026-09-18.json`,
SHA-256 `c8d56b93262a5e62de66ee5ad5cd9a2377a88d93a68e8cb78c9f2b74a7140630`.
The unchanged comparison command against the archived Swift baseline fails as
required: that baseline has 30 Jobs, while these Rust runs have 20. No comparison
standard or budget was relaxed and no performance improvement is claimed.

The actual host is Apple M3 / 8 cores / 16 GiB, macOS 27.0 (26A428), Xcode 27.0
(27A266a); only `/Applications/Xcode.app` is installed. Design section I.2 pins
macOS 26.6 / Xcode 26.6, so even a quieter run here would not alone prove the
specified reference environment. A matching reference host, or an explicit
maintainer decision updating that environment, remains necessary. A qualified
Rust baseline must be added alongside the preserved Swift baseline before
performance acceptance. Hosted nightly retains its existing explicit host
mismatch skip policy; a green archival run does not prove regression gating.
