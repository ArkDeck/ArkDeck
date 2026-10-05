# Windows owner soak software port — 2026-10-05

TASK-XPA-025 requires the Rust owner workload on both hosts (`tasks.md`, lines 1512–1554).
The old Windows run's §6 deferred Job, journal, recovery and Artifact work only until the
Windows Job store (G01). Those owners now exist. TASK-XPA-024's optional Viewer FFI trigger
is unchanged; this port does not cross that boundary.

The Windows soak now uses the same simulated-provider production owners as macOS: bounded
observation Jobs, never-started cancellation, clean preflight restart, durable journals and
verified Artifact evidence. Each named-pipe generation uses the production serving/drain path
and signed-client identity checks. The 32 MiB resident-set growth and 16-handle growth limits
are unchanged. The Windows owner marker differs from the old transport-only marker, so an
old transport fixture cannot be adopted as owner-workload evidence.

The benchmark harness now seeds those owners and can exercise its existing recovery,
journal and Artifact opt-ins on Windows. Job list/status rows name the PID-checked named
pipe. Completion checks use the actual Windows endpoint, preserve their bounded timeout and
expected server PID, and durability evidence names the production `FlushFileBuffers` path.
Windows metrics reads hold a regular single-link file opened without following its final
reparse point; the size bound remains in place.

These supporting harness changes were necessary because `os.O_NOFOLLOW` is unavailable on
Windows and ordinary temporary directories may inherit principals refused by the native
private store. New harness roots are created once with a protected token-user-only DACL;
existing ACLs are never rewritten. A missing soak root can be created only through an
existing private parent's `create_private_child` (`FILE_CREATE`); an existing entry is
refused by that creation path. Benchmark callers precreate their fresh private root.

Installed-state refusal checks both logical and physical prefixes, including case aliases,
before root or owner writes. An inaccessible installed leaf is derived from its resolved
parent only when native no-follow metadata proves an ordinary directory without a reparse
attribute. An unresolved reparse/unknown leaf refuses. Sandbox execution exposed precisely
that ordinary-leaf case (directory attribute `0x10`, native open/canonicalize denied with
error 5). The same production daemon identity gate and signing certificate worked through
the controlled native executor; no installed state, ACL or trust gate was changed. Fixture
TEMP bases resolve their physical spelling before native store access, including 8.3 aliases.

## Local targeted checks

All Cargo commands used `CARGO_BUILD_JOBS=2`, target `D:/cargo-target/soak-owner`; heavy
commands ran through `D:/src/ArkDeck-wt/tools/gate_slot.py`. Logs are under
`D:/src/ArkDeck-wt/tools/logs/`.

- `cargo build --manifest-path rust/Cargo.toml -p arkdeck-soak -p arkdeck-agentd --bins`:
  exit 0; `soak-owner-build.log`. The daemon binary was built before harness process tests.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-soak`: exit 0, 5 passed and the
  explicit signed leg ignored here; `soak-owner-tests.log`.
- `cargo test --manifest-path rust/Cargo.toml -p arkdeck-soak --test windows_pipe -- --ignored`:
  exit 0, 1 signed owner test passed; `soak-owner-signed-tests.log`. It checks drain/rebind,
  continued owned state, foreign-root refusal, unknown-intent refusal with exact retained
  journal/metrics bytes, completed Jobs and verified Artifact evidence.
- With verified 8.3 `TEMP`/`TMP`, `cargo test --manifest-path rust/Cargo.toml -p arkdeck-soak
  -- --include-ignored`: exit 0, all 6 tests passed, no ignored tests;
  `soak-owner-short-temp.log`. The signer path executed, rather than being skipped.
- `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-soak --all-targets -- -D warnings`:
  exit 0; `soak-owner-clippy.log`. No workspace crate directly depends on `arkdeck-soak`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml`: exit 0;
  `soak-owner-fmt-check.log`.
- Focused Python tests: exit 0, 39 passed, no skips; `soak-owner-python-tests.log`.
  These cover Windows rules/APIs, native private DACLs, no-follow file refusal, seed evidence,
  journal completion and bounded recovery failures. With `BENCH_TEST_DAEMON` pointing to a
  signed fixture copy and `BENCH_TEST_SOAK` to the built soak, the real harness also verifies
  both 20-row recovery workloads and three-page terminal History against the production
  daemon, using the actual Windows `socket_path=None`/named-pipe shape and server PID.
- `sh scripts/check-sdd.sh`: exit 0; `soak-owner-sdd.log`.

Software checks used tiny correctness workloads. No quiet-host reference capture, durable
append timing run, Artifact performance run, long soak, 30% spread check or baseline adoption
was performed while other development builds were active. Capture-only and baseline gates,
resource thresholds, task/status/ruling records and provider coverage declarations remain
unchanged. macOS checks await CI on a macOS runner; no device execution or hardware evidence
was produced.

## Final integration targeted checks

The integration layer directly follows tool-selection PR #2584 at
`3d8c4be57fd97383c77c62f1b932539984599770`. It preserves all lower-layer source,
schema and generated coverage increments. Target: `D:/cargo-target/lead-symbolize`,
two Cargo build jobs, heavy Cargo checks through `gate_slot.py`. Logs remain
local under `D:/src/ArkDeck-wt/tools/logs/`.

| Command/check | Exit | Log |
| --- | --- | --- |
| Build soak and production daemon bins | 0 | `soak-layer-build.log` |
| Full soak crate under verified 8.3 TEMP/TMP, including the signed owner leg (six passed, zero ignored) | 0 | `soak-layer-short-tests.log` |
| The same 39 Python correctness checks with a newly signed copy of the integration daemon and integration soak binary (zero skipped) | 0 | `soak-layer-python.log` |
| All-target soak clippy, warnings denied | 0 | `soak-layer-clippy.log` |
| Workspace fmt check | 0 | `soak-layer-fmt.log` |
| Final SDD and diff checks | 0 | `soak-layer-sdd.log`; diff check returned no output |

No crate directly depends on soak. No contract input, Catalog operation, Runtime
capability or production Provider declaration changes in this layer. The census
now records the software gap as closed while keeping the existing quiet-host
reference, long-soak, performance-spread and baseline adoption requirements.
Windows CLI coverage remains 149 implemented, 11 partial and two notImplemented
of 162 required features, with 101 macOS-only features.

## CI

Pending this integration layer's push. It directly depends on
https://github.com/ArkDeck/ArkDeck/pull/2584; that layer's four predecessor PRs
are green at their recorded heads, while #2584's full parity is still running.
The later delivery slice will record this layer's actual PR/run result without
amending an already-green head. This record makes no acceptance or approval claim.
