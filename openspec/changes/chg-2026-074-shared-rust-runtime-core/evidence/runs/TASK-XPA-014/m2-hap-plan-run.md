# Rust HAP planning checkpoint

Status: implementation and test code written; compilation, test execution and
unified validation are pending the shared host validation window. This is not
an execution, capability, signing or Golden Journey acceptance result.

Base: Import lifecycle checkpoint `23b402bd`, which contains publication
`590d09f2` (#1983). #1983 subsequently merged as `510b4650`; this branch has not
refreshed the shared main ref while another validation is running. Import
lifecycle remains an explicit unmerged dependency.

`job.plan` alone accepts `debug.hap@1`. The separate admission descriptor
continues to refuse HAP before any capability issuance or reservation. The new
planner resolves entry and additional Artifact leases against the exact Target,
binding revision and identity, retains the existing Import materialization hold,
and lowers the existing typed HAP Provider into the complete plan, including
failure compensations. It neither dispatches nor introduces recovery behavior.

Tests written (not run):

- Exact comparison of all 13 native Swift `DebugHapOracleContractTests` plan
  exchanges already recorded in `rust/tests/fixtures/debug-hap`, including eight
  successful plans and five refusals. This reuses committed native recordings;
  no response frames or expected plan digests were manufactured.
- Submit each valid HAP plan request with an available authority and require the
  existing refusal, unchanged Job/capability storage and zero dispatch.
- Additional package duplicate, upper bound, malformed and missing-lease cases.
- Commit two isolated structural HAP Imports through the actual host owner;
  pause after acquisition of the complete input hold. Inspect both entry and
  additional references and require release to fail. After successful planning
  or duplicate-package Provider preflight refusal, require both holds to clear
  and both releases to succeed. Channel timeouts and a resume-on-drop guard
  prevent assertion failures or failure before acquisition from hanging joins.

Static checks: `cargo fmt --manifest-path rust/Cargo.toml --all` and
`git diff --check` passed. No build, Swift producer, test or device execution was
run for this checkpoint. Further native sampling and the repository's complete
unified entry remain required before delivery. No dashboard counts changed.

Implementation reference: the current Swift RuntimeJobEngine materialization
and `RuntimeDebugHAPFailureFinalization`, plus the already ported HAP Provider.
Historical unpublished `cfffc029` was consulted for equivalent journal argument
shapes; its admission and capability changes were not imported.

## Additional unrun boundary tests

The native Swift producer now contains two additional plan-only cases: all
optional defaults omitted, and a package set with `cleanupPolicy=retain` plus
`postRunAbilityState=running`. The latter still binds failure-only stop/staging
compensations while its successful path omits stop and uninstall. The Rust replay
expects all 15 native exchanges (10 positive); the committed 13-case fixture is
intentionally unchanged until actual recording. This intermediate checkpoint
therefore requires recording before its oracle replay can pass. No expected
digest has been authored manually.

The Import hold test now also independently varies the additional package's
Target, binding revision and stable identity. Each is a valid isolated Import
for its own fixture binding, then refused against the requested HAP Target.
The tests require the additional-lease binding error, both holds present while
paused, release conflicts for both, and both holds cleared/releasable afterward.
Existing bounded channels and unwind release protection cover all five cases.

Minimal pending native sampling command, from the repository root (destination
must not exist):

```sh
ARKDECK_RUST_DEBUG_HAP_RECORD=/private/tmp/arkdeck-hap-plan-native-20260919 \
  sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --jobs 2 \
  --filter DebugHapOracleContractTests/testSwiftDebugsAHapOnTheSharedFakeDevice
```

This command has not been run. It uses the existing isolated fake-device oracle,
never a device, and produces no GJ evidence. Copying verified native outputs and
checking their producer provenance, then targeted tests and full gate, remain
pending. Static `cargo fmt` and `git diff --check` passed for this addition.
