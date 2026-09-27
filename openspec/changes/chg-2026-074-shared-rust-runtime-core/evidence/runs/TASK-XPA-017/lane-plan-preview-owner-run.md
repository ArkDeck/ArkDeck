# Native lane plan preview owner

The Rust owner now implements the existing `flash.lanePlanPreview` beyond the
Target/facts checks. It inspects the exact archive through the pinned typed
ArkForge controller client, uses the same public/controller observation and
mechanics/authority seal checks as execution, and projects Swift's available,
bundle-not-in-store, device-not-observed, plan-not-executable and failure states.
The controller digest is normalized by the existing Control validation boundary;
the preview uses the profile loaded by its composed daemon generation.

The preview owner has only materialization connections. It retains no pairing
secret, execution client or device performer. A missing archive never triggers
an import, and a returned plan is never started or permitted. Execution still
materializes a fresh plan. The existing execution refusal text is retained while
the shared policy exposes structured reasons for the preview.

The 74-exchange Flash host-facts oracle now compares all replies to Swift,
including the eight former declared differences at the lane boundary. The App
transport test also checks forwarding and normalization of the supplied digest.
Provider tests cover the seven-call successful assessment sequence, independent
support and seal refusals, and missing archive behavior. A local Unix socket
fixture exercises the real pinned controller/public clients and their codec;
unexpected APIs fail the fixture, and its immutable file and file count remain
unchanged. These are host fixtures, not hardware evidence.

## Local targeted checks

On main `fe75fe28c54da1056982f31263449653d7f7f874`, all checks ran with
`CARGO_BUILD_JOBS=2`, one coordinated local lane, and private target
`/private/tmp/arkdeck-takeover-d79c-target`:

- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0.
- `cargo clippy --locked --manifest-path rust/Cargo.toml -p <crate> --all-targets -- -D warnings`:
  exit 0 for provider-arkforge, hoststore, control, agentd and direct dependent soak.
- `cargo test --locked --manifest-path rust/Cargo.toml -p <crate>`: provider 99,
  hoststore 732, control 34, agentd 205, soak 9 passed: 1,079 total, zero failures.
  There are 18 existing conditional ignores and one ignored child fixture
  exercised by its parent tests. Logs are
  `/private/tmp/arkdeck-preview-final-<crate>-{clippy,test}.log` and
  `/private/tmp/arkdeck-preview-final-fmt.log`.
- `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'LanePlanPreviewContractTests|FlashHostFactsOracleContractTests'`:
  5 passed, exit 0; `/private/tmp/arkdeck-preview-swift.log`.

The targeted SDK fixture, preview policy, Host projection, App forwarding and
74-exchange oracle passed before the crate regression. Logs are
`/private/tmp/arkdeck-preview-native.log` and
`/private/tmp/arkdeck-preview-targeted-{provider-unit,host-projection,app-forwarding,host-oracle}.log`.
The first Host build found a missing `Arc` qualification. The first oracle replay
found that older exchanges omit `laneCalls`; absent fields now mean no calls,
while recorded calls and every answer remain strict comparisons. Those attempts
are preserved as `arkdeck-preview-targeted-app-forwarding-first-build.log` and
`arkdeck-preview-targeted-host-oracle-first.log` under `/private/tmp/`.
An initial Host test filter selected zero cases; the corrected module filter
and full crate run both executed the two projection/facts tests successfully.

Formatting, diff and SDD checks pass; the SDD log is
`/private/tmp/arkdeck-preview-sdd.log`. The required crate integration runs
exceeded the ten-minute local target; no unified local gate was run.

No contract input or published operation changes, no App source changes and no
installed Runtime or device actions are part of this work. No local unified gate
is planned. The broker, real-device equivalence acceptance and G5 remain outside
this read-only implementation.

## CI

Pending the dedicated bot PR's exact-head checks. Results will be recorded in
the PR body without amending a green head. The prerequisite execution work and
CI fix in PR #2282 were merged as `423a27e2`; this branch also includes the
independently merged HDC owner from PR #2283.
