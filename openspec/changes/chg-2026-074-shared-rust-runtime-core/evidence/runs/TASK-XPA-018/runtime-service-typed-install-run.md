# TASK-XPA-018 — the typed `runtime service install` and `uninstall` hold and release the Bootstrap registry's installation reference

Cutover blocker ③, second of two PRs. The first
(`bootstrap-registry-crate-run.md`) moved the Bootstrap registry's bundle and
HDC tool owners into `arkdeck-bootstrap`; this one gives the bundle owner
Swift's references and wires the CLI's typed install and uninstall to them, as
Swift's `RuntimeCLI.runAgentDaemon` does (`ArkDeckRuntimeCommands.swift`
`install` and `uninstall`; `BootstrapBundleRegistry.acquire/retainOnly/
releaseAll`; `BootstrapToolRegistry.initializeServiceSelection`). Of S18's
three refusals by name (#2143) only the installation reference's goes; the
signing receipt's (ruling 3) and the analyzer probe's (ruling 2) stay.

Branch `agent/xpa-018-runtime-service-typed-install`, on the first PR's
branch `agent/xpa-018-bootstrap-registry-crate`.

## What a caller sees

- `arkdeck runtime service install --bundle <bundle:sha256:…>
  --bundle-generation <n> --tool <tool:sha256:…> --tool-generation <n>`, in
  Swift's order:
  1. the service's status is read; an installed, loaded or listening service is
     refused `resourceConflict` ("runtime service install is only the
     zero-Runtime bootstrap path; use the reviewed service update lifecycle
     for an existing installation"), the registry untouched;
  2. an installed OpenHarmony signing preset is refused 69 before the registry
     is read (ruling 3);
  3. the exact bundle generation is pinned for `installation/
     runtime-service-installation` (the index published only for a new pin);
  4. the first HDC selection is published from the exact tool generation (a
     retry of the same selection is idempotent);
  5. the retained bundle is installed with the retained HDC exactly as
     `update` installs a helper, the analyzer probe of a Rust daemon included;
  6. only that bundle keeps the installation's pin (every other bundle's pin
     for it released);
  7. the answer is Swift's `{"schemaVersion":
     "arkdeck.runtime-service-installation/1", "installed": true, "bundleRef",
     "bundleGeneration", "activeToolRef", "activeToolSelectionGeneration"}`.

  A failure after step 3 leaves the pin (and after step 4 the selection) for
  a retry, never dangling; a refusal before the service changes says so
  ("the service was not changed, and the bundle and HDC selection stay pinned
  for a retry"). A step-6 failure after launchd started the service is
  Swift's "service started, but its durable bundle reference could not be
  finalized: …".
- `arkdeck runtime service uninstall` removes the service as before, then
  releases every pin of the installation; a release that fails is reported
  after the removal ("service was removed, but its durable bundle references
  could not be released: …"), which stands. With no registry, Swift's owner
  creates it (an empty index) and releases nothing.
- The registry's refusals are Swift's session failures (`session.fail`): the
  code of the error registry (else `recordUnreadable`), the owner's words and
  `details: {"newDispatchCount": 0}`; in machine output the failure envelope
  (with `controlProtocolVersion`), in `--json` the legacy failure document, in
  the human rendering `arkdeck: <message>` on stderr; the code's exit status.

## What changed

- `arkdeck-bootstrap`:
  - `bundle_references.rs` (new): `ReferenceOwner` (Swift's closed kinds and
    bounded identifiers; `service_installation()`), and
    `BundleRegistryReadStore::acquire`, `retain_only`, `release_all` under
    the store's lock with Swift's order, verification, refusal codes and words,
    publication rule (acquire only for a new pin, the other two always) and
    canonical bytes;
  - `store.rs` (new): the store's one lock protocol — `create_store` (Swift's
    `openDirectory(create:privateLeaf:)`), the lock taken without waiting and
    bound, each index read or initialized — now shared by the references and
    the HDC selection ledger (the ledger's helpers moved here unchanged), so
    the CLI's two writes and the Runtime initialize `bundles.json` alike;
  - `BundleValidator` (`with_bundle_validator`): the store's helper policy,
    the production one unless a caller supplies its own; registration and
    verification use it.
- `arkdeck-cli` (new edge `arkdeck-cli → arkdeck-bootstrap`, registered in
  `check-readonly.py`; no `arkdeck-hoststore` edge):
  - `runtime_service_install.rs`: the typed install and the uninstall above;
    the signing refusal shared with `update`; the path installs' refusals
    unchanged;
  - `runtime_service.rs`: `LaunchAgentPaths::bootstrap_registry`,
    `ServiceHost::bundle_trust` (production: `validate_production_daemon_bundle`)
    and `hdc_identities` (production: the Runtime's published identities),
    `CodedFailure` and `ServiceAnswer::refusal`;
  - `main.rs`: a coded refusal rendered as Swift's session renders it.
- `rust/README.md`: the typed install and uninstall paragraph.

## Declared differences from Swift

1. **Trust adapter (a Swift defect).** Swift's CLI constructs
   `BootstrapBundleRegistry()` with no `validateBundle`, whose default refuses
   every bundle ("daemon bundle registration requires its production trust
   adapter"). So Swift's shipped typed install is refused `admissionDenied` at
   `acquire` for every registered bundle, and its uninstall fails the same way
   in `releaseAll` — after removing the service — whenever any bundle is
   registered. Only its contract test, which injects `{ _ in }`, runs the
   designed flow. The Rust CLI holds retained bundles to the production helper
   policy (`validate_production_daemon_bundle`, the check the Runtime's bundle
   owner and Swift's daemon adapters apply); a refusal is `admissionDenied`
   "registered bundle failed the production helper trust policy", the Swift
   daemon adapters' words.
2. The registry is the relocated home's when `CFFIXED_USER_HOME` is set
   (Swift's registry always uses the account's `getpwuid` home), as before.
3. Content verification failures other than the trust policy are one
   `recordUnreadable` "registered bundle content failed integrity validation"
   (Swift distinguishes a missing or symbolic content directory, a changed
   version and a change during trust validation).
4. The store's directory and lock binding refusals are the ledger's words
   ("bootstrap store directory changed", "bootstrap lock was replaced"); a
   failed first publication of an empty index is the ledger's "cannot publish
   tool index"; creating the store checks its leaf (owner, private, no link)
   rather than walking every ancestor.
5. The signing receipt refuses before the pin (ruling 3; Swift re-records the
   identity before `bootstrap`), and the retained daemon is run once for the
   cutover preflight before the service changes (as `update`, #2143).
6. When the retained daemon is the Rust daemon, the answer also carries the
   cutover summary (`cutover`), as `update`'s does.

## Tests

- `crates/arkdeck-bootstrap/src/bundle_references_tests.rs` (9): Swift's
  owner kinds and identifiers; `acquire` refusals publish nothing (malformed,
  unknown, every non-matching generation), the pin sorted beside another
  owner's, the retained content's path, canonical bytes, and no republication
  for a held pin; a removed bundle, one the policy refuses and one whose
  content changed are never pinned; `retain_only` refuses an unpinned bundle,
  releases only the owner's other pins and always publishes; `retain_only` and
  `release_all` verify every record first and publish nothing on a failure;
  `release_all` releases every pin of the owner and always publishes; a fresh
  store is initialized, state without an index and an off-schema index are
  refused; the lock is never waited for; creating the store makes its missing
  directories owner-only and refuses a relative, linked or non-private path.
- `crates/arkdeck-cli/tests/runtime_service.rs`: the typed install end to
  end over a registry the test fills through the same owners (a helper
  bundle under the stand-in trust, `/usr/bin/true` as a published HDC); every
  refusal before the pin (existing service, signing preset, malformed and
  unknown references, bundle generation, trust, a held lock) and the tool
  generation after it; a failure after the pin (a Rust daemon without the
  analyzer mode, launchd refusing `bootstrap`, the pin not finalized after
  launchd started the service); the uninstall's release (another owner's
  pin kept, a registry created when absent) and its failures after the
  removal; the binary's session-failure envelope and human line, and its
  production policy refusing the unsigned helper at the pin.
- The test registries hold bundles as registration leaves them (the bytes
  copied owner-only under `bundle-<digest>.app`, measured by the owner's
  `inspect_bundle_content_with` under a stand-in trust, the record available
  at generation 1): registration itself captures only a production-signed
  helper (`BootstrapBundleCapture` checks the signature natively), which no
  test bundle is. The HDC is registered through the tool owner itself.
- Seven mutations, each caught by a test failure (not a build error) and
  restored by checksum (`/private/tmp/arkdeck-s31-mutants.log`, baseline run
  first): `retain_only` keeping the owner's other pins; `acquire` never
  publishing its pin; `release_all` skipping verification; `acquire` ignoring
  the generation; the typed install skipping `retain_only`; the uninstall
  releasing nothing; a coded refusal rendered as a plain one.

## Local targeted checks

`CARGO_BUILD_JOBS=2`, target `/private/tmp/arkdeck-1330-rust-target`, logs
`/private/tmp/arkdeck-s31-p2-*.log`, on the first PR's head `a10410a0a` (main
`da76e3e8e`). Changed crates: `arkdeck-bootstrap`, `arkdeck-cli`; direct
dependents of the bootstrap crate: `arkdeck-hoststore`, `arkdeck-cli`.

| Command | Exit | Log |
| --- | --- | --- |
| `cargo fmt --all --check` | 0 | `arkdeck-s31-p2-fmt.log` |
| `cargo clippy --all-targets -- -D warnings`, `-p arkdeck-bootstrap -p arkdeck-cli -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak` | 0 | `arkdeck-s31-p2-clippy.log` |
| the same for `arkdeck-bootstrap`, `arkdeck-cli` and `arkdeck-hoststore` with `--target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` | 0, 0 | `arkdeck-s31-p2-clippy-x86_64-*.log` |
| `cargo test -p arkdeck-cli -p arkdeck-bootstrap --no-fail-fast` | 0: 58 result lines, 408 passed, 0 failed, 1 existing ignored; `runtime_service` 41 | `arkdeck-s31-p2-test-cli-all.log` |
| after the last edits (the store refusing a linked path, its unit test, a doc comment): `cargo test -p arkdeck-bootstrap`, then fmt, the same clippy (native and both cross targets) and `cargo test -p arkdeck-cli --test runtime_service` again | 0: 34 passed, 1 existing ignored; 0; 0, 0, 0; 0: 41 passed | `arkdeck-s31-p2-test-bootstrap2.log`, `arkdeck-s31-p2-test-cli-final.log` |
| `cargo test -p arkdeck-hoststore --no-fail-fast` | 0: 85 result lines, 625 passed, 0 failed, 13 existing ignored | `arkdeck-s31-p2-test-hoststore.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test -p arkdeck-agentd --test production_composition --test cutover_preflight` (the ledger's and the pending selection's Runtime callers) | 0: 21 passed, 0 failed | `arkdeck-s31-p2-test-agentd.log` |
| seven mutations through `scratchpad/s31/mutate.py`, baseline first | caught ×7 | `arkdeck-s31-mutants.log` |
| `python rust/scripts/check-readonly.py --bin-dir <target>/debug` (validation venv; the CLI's new edge in `assert_boundaries()`) | 0, `PASS` | `arkdeck-s31-p2-readonly.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s31-p2-sdd.log` |

No test ran `/bin/launchctl`, touched the account's `gui/<uid>` domain, its
LaunchAgent plist or `~/Library/Application Support/ArkDeck`, the installed
agentd or its HDC server, or a device: the library tests use a recording
launchd and a temporary home, the process tests a relocated home. The
readonly check's recording directory was removed afterwards.

Not run: `generate-contract.py --check` (no contract input changed), Swift or
App tests (no Swift or App file changed), the full `arkdeck-agentd` and
`arkdeck-soak` suites (not direct dependents of a changed crate; the two
Runtime callers of the refactored ledger ran). No Swift oracle was recorded
for the bundle references: that needs a Swift build window (see below).

## Not recorded, and what would record it

The bundle index bytes the references publish come from the same canonical
encoder the tool ledger's Swift oracle and the registration and retirement
replays already hold to Swift's bytes, and the tests assert Swift's rules
(order, publication, words). A Swift oracle for this family would be a
contract test beside `ToolSelectionRegistryOracleContractTests` that records
`acquire`/`retainOnly`/`releaseAll` timelines — each step's answer or
refusal (code and words), the index bytes after it and whether it published —
with a stand-in `validateBundle`, for the Rust owner to replay step by step.

## CI

Pending; recorded by the next slice.
