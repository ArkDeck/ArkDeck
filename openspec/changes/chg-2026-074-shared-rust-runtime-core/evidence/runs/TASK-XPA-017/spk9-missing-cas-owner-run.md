# SPK-9 real-daemon missing-archive refusal subset

Date: 2026-09-27. Rust `LanePreviewHost` and Swift `ArkForgeLaneHost` returned
`bundleNotInLaneStore` from the same real, unpaired daemon. Each owner made one
SDK `InspectArtifact` request and checked the actual `ARTIFACT_NOT_FOUND` error;
a transport or decoder failure cannot satisfy this fixture. No fake daemon reply,
archive import, discovery, materialization, Job, permit or device dispatch is used.

This establishes only the missing-CAS host refusal subset. It does not complete
SPK-9's other refusal/available-plan paths, real-device execution equivalence,
installed Runtime cutover or G5. The full profile reference is an input, but the
CAS miss returns before materialization, so this run does not prove profile
lookup or observation joins. Existing synthetic SDK tests cover those separately.

## Carrier and source boundary

`scripts/ci/run-spk9-preview-missing.py` requires a clean checkout at the repository's
current SDK pin. It builds sequentially before starting the daemon, using separate
task-owned ArkForge/ArkDeck Cargo targets and the existing serialized Swift runner.
The new Rust case is ignored by default; the separate Swift class skips without
this carrier's environment. The old broad live-daemon class is never selected.

Both owners use actual pinned SDK clients inside an inspect-only test port. Every
other port method traps before a request can reach the daemon. This is an explicit
restricted test adapter, not a packet-capture claim about arbitrary clients.
The Rust SDK gets a five-second read timeout; Swift uses five seconds too. The
carrier bounds readiness at 10 seconds, Rust at 30 and Swift at 60, terminates and
reaps owned process groups, and removes the temporary runtime even on failure or
ordinary cancellation. Build commands have separate 600-second limits.

The carrier creates a fresh 0700 parent under `/private/tmp`, passes only
`--runtime-dir`, and sends no pairing secret, campaign or transcript. It compares
all private directory/socket modes and file hashes before and after both owners.

Source-level reachability was reviewed at pinned ArkForge
`c1dc0553b42627581583abfba3fec34d13343282`, tree
`cfdcb9dbe048b20d690a0f5406b14e79ef4a21b2`:

- `crates/arkforged/src/service.rs:325` registers USB transports without calling
  their enumerators; `arkforge-transport/src/usb.rs:229` only stores fields.
- `arkforged/src/main.rs:185` starts a dispatcher thread. Its loop at 237 scans
  empty Jobs/queues in this fresh store and sleeps; it is not a claim of no thread.
- `service.rs:851` returns `ARTIFACT_NOT_FOUND` immediately on absent CAS bytes.
  Explicit discovery is a separate API and would enumerate USB even unpaired;
  the test adapters therefore prohibit it before entering the SDK.

## Local targeted checks

Final command, exit 0:

```sh
python3 scripts/ci/run-spk9-preview-missing.py \
  --arkforge-source /Users/fuhanfeng/.cargo/git/checkouts/arkforge-2dee4a7784fc6b13/c1dc055 \
  --daemon-target /private/tmp/arkforge-controller-materialization-target \
  --cargo-target /private/tmp/arkdeck-takeover-d79c-target \
  --output /private/tmp/arkdeck-spk9-missing-live-20260927-2
```

The carrier records source commit/tree, its three source-file hashes, command
arrays, toolchains, Rust executable identity and daemon identity. The locked
Cargo build reused valid cached artifacts (`fresh: true`); it was not a clean
recompile. The retained Cargo artifact records identify the exact pinned source
path. The resulting daemon SHA256 was
`0c42f6e7af2080a753fde595040601c27900bbc636d62b2a5f36cabb07e9e8b1`;
Swift's real HelloAck and daemon startup log reported the same identity and
`executionReady=false` / `NO_PAIRED_AUTHORITY`.

Rust: 1 live case passed. Swift: 1 live case passed, zero skipped. The initial
Swift build intentionally skipped the one case before opt-in. Both reports use
the all-zero absent digest and `org.openharmony.dayu200@1.0.0`. Before/after state
was identical: only empty store directories and the two 0600 sockets; no Artifact,
Job or journal file. The runtime was removed after its daemon was reaped.
Machine-readable results and compact logs are retained in `spk9-missing-cas/`;
full build logs remain in the output directory above. The first successful run
is separately preserved at `/private/tmp/arkdeck-spk9-missing-live-20260927-1`.
The second run additionally verifies the final script with SIGTERM cleanup.

Other checks, all exit 0, with `CARGO_BUILD_JOBS=2` and private ArkDeck target:

- Provider all-target Clippy: `/private/tmp/arkdeck-spk9-provider-clippy.log`.
- Provider full tests: 99 passed, one explicitly opt-in live case ignored;
  `/private/tmp/arkdeck-spk9-provider-test.log`.
- `python3 scripts/ci/test_spk9_preview_missing.py`: 3 passing failure-path checks
  (state mutation/symlink, ambiguous artifact, deadline child reaping);
  `/private/tmp/arkdeck-spk9-carrier-tests.log`.
- `cargo fmt --all --check --manifest-path rust/Cargo.toml` and diff check: exit 0.
- `sh scripts/check-sdd.sh`: exit 0;
  `/private/tmp/arkdeck-spk9-sdd.log`.

No production source, operation contract, pin or App implementation changed.
No local unified gate, App build or unrelated Swift suite was run. No installation
or real-device command was performed.

## CI

Pending the dedicated bot PR. This opt-in carrier is not automatically run by
ordinary CI; CI compiles its Rust/Swift cases without launching the live daemon.
The prerequisite preview owner is PR #2284 at `face946d`; its CI is separate from
this carrier's new head. Results will be recorded in the PR body without amending
a green head.
