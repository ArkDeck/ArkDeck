# Workspace tests and crash symbolization on the Rust daemon (TASK-XPA-015, M3)

The Rust daemon now plans, admits, runs, reconciles and publishes the last two
workspace operations as Swift does:

- `workspace.run-tests@1`: a registered Hvigor test preset — a pinned DevEco
  toolchain's Node running its pinned `hvigorw.js` with the preset's closed
  argv — in a Runtime-owned copy, under the standing capability the Runtime
  issues for its own copies;
- `workspace.symbolize-crash@1`: a device's crash log resolved against a
  registered project's source map by the symbol preset, whose executable is
  the daemon itself in its one-shot `--symbolize-crash` mode.

`arkdeck-agentd --symbolize-crash <map> <dump>` is that mode, over a port of
Swift's `JSCrashSymbolizer`; the production composition now composes symbol
presets from `ARKDECK_ANALYZER_PATH`, as Swift's daemon does. Two new Swift
oracles replay byte for byte: the symbolizer's reports over 77 maps and dumps,
and 37 frames of the two operations with the capability store, the products
and the durable records of the two Jobs whose receipt was lost.

Base: protected `main` `f07a5f471` (#2193), which carries the four reads
(#2190) and the checkpoint and sweep (#2192).

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The four reads (#2190); `create-checkpoint`, `sweep-isolated-copies` (#2192); `prepare-isolated-copy`, patches, build, signing | The two Swift oracles; plan, admission, run, reconcile and result of both operations; the symbolizer port and its one-shot mode; symbol presets composed from `ARKDECK_ANALYZER_PATH` | the `operation.list`, project and preset availability projections (PR-D, and the `workspace.project.show` schema widening, PR-D0); GJ-5 |

## The oracles

`CrashSymbolizerOracleContractTests` records what
`JSCrashSymbolizer.symbolize(sourceMapData:dumpText:)` writes, or throws, for
77 source maps and crash dumps, in
`rust/tests/fixtures/crash-symbolizer-oracle/cases.json` (the inputs' exact
bytes, Base64): the device's own case (the obfuscated WaterFlow build's
`sourceMaps.map` entry and the jscrash stack `JSCrashSymbolizerContractTests`
already pins); a hand-written case per rule — column and line placement, a
unit the map does not name, an unparsed frame, a line with no segment, signs
and continuations, digits outside the alphabet, a trailing continuation, short
and long segments, source indexes out of range, entries that are not objects
or carry no strings, maps that are not objects or not JSON, several stack
blocks, blank and tab-indented lines, CR LF line ends, bytes that are not
UTF-8, signed and malformed positions, a repeated key, a decomposed unit name,
a unit with colons; and 60 generated cases from a fixed seed, small enough
never to reach Swift's integer traps.

`WorkspaceTestSymbolizeOracleContractTests` composes Swift's daemon
composition over a fabricated project under
`/private/tmp/arkdeck-workspace-test-symbolize-oracle` — two test presets
(`entry`, which passes, and `broken`, which Hvigor refuses) over `node.sh` and
`hvigorw.js`, stand-ins for a registered DevEco toolchain, and two symbol
presets over `symbolizer.sh`, a stand-in for the daemon's one-shot mode (one
whose map exists, one whose map does not) — with the crash logs a device
capture published laid into the Artifact store first: `crash-log.txt` and
`crash-index.txt` from `capture.diagnostics@1` through `hdc`, bound to a device
target, and a `crash-log.txt` bound to the host target the requests name. It
records 37 frames in order: the tests planned for the person's primary tree
and refused at submit without a capability a person issued; an undeclared test
preset refused; a Runtime-owned copy; its tests passing under the Runtime's
capability for the copy, and failing (the Job fails, the output still
published); a stale revision refused at plan and submit; a test receipt lost
after the child ran (parked, reconciled without a readback, never run again);
the device's crash symbolized (published as sensitive text); a symbolization
without its map (no output: the Job fails); a crash index, a crash from the
request's own target and an undeclared symbol preset refused by name; and a
symbolization receipt lost after the child ran (parked, reconciled as still
unknown, never run again). Two recordings of both classes were identical, and
the checked-in fixtures were then verified. Every answer the Rust replay gives
is admitted by the published method schemas, which the replay asserts, so no
contract input changes.

## Swift, as ported

**Tests.** The preamble (the profile the request names, every pinned tool of
it re-measured, a stated revision enforced), then the test preset the request
names (`workspace.testPresetUnavailable:<preset>` otherwise), its own closed
argv in the root. The plan is one process; admission is a standing
capability: the Runtime's own for its isolated copies, and — as for patches
and builds — none for a person's primary tree, where a request naming none is
refused as Swift refuses it and one naming a grant as a capability the store
does not hold. The run takes the host target's mutation lane, consumes the use
before the write-ahead intent, and runs the child in the root with the home
and temporary directory a Hvigor build reads and the `DEVECO_SDK_HOME` the
composition names for the launcher. A zero exit verifies; anything else fails
`workspace.testsFailed`. `test-output.log` is stdout then stderr, published
whatever the verdict, as Swift keeps a failure's diagnostics. A lost receipt
has no dedicated readback and stays unknown.

**Symbolization.** The crash dump's lease is resolved and checked as Swift
checks it: exactly the device-bound `crash-log.txt` that `capture.diagnostics@1`
published through `hdc`, with a positive binding revision and a lowercase
identity, from a target other than the one the request names, and no binding
pinned by the request (otherwise the invalid-input refusal Swift interpolates).
Then the preamble and the symbol preset (`workspace.symbolPresetUnavailable:
<preset>` otherwise), its fixed argv followed by the dump's path, in the root;
the journal names the dump by its Artifact identity and digest. Host-only,
under the default read-only policy. At run the lease is resolved and checked
again before anything starts. A zero exit with a report verifies; anything
else fails `workspace.symbolizationFailed`. `symbolized-crash.txt` is the
report, published as sensitive text. A lost receipt is reconciled as Swift's
provider answers it: "read/build process completion is not inferable after
receipt loss"; the Job stays `waitingForRecovery`.

**The symbolizer** (`crash_symbolizer.rs`) is Swift's decode: the
`Stacktrace:` blocks (a block ends at the first line that is not an indented
frame; blank lines inside it are skipped), each frame's parenthesised
`<unit>:<line>:<column>` after the last `(`, the unit's `mappings` and
`sources` looked up in the map, Base64 VLQ with every row decoded (the fields
are deltas against the whole document), the segment that starts at or before
the column or — when none does — the line's first, "placed by line". Swift's
text semantics are kept where they decide the answer: the dump is split at line
feeds that are whole characters (a CR LF pair is one character, so it is no
line end); prefixes, parentheses, colons and Base64 digits are whole
characters; a unit is looked up by canonical equivalence, as a Swift
dictionary compares its keys; a key the map repeats keeps its first value, as
`JSONSerialization` keeps it; invalid UTF-8 in the dump is replaced as Swift
decodes it.

**The one-shot mode** (`arkdeck-agentd --symbolize-crash <map> <dump>`) is
answered before anything a daemon does: exactly two absolute paths (Swift's
usage line and exit 64 otherwise, before anything is read), the map read and
then the dump, the report on stdout and exit 0; a file that cannot be read, or
a map that is not a JSON object, is exit 1 and a line naming the error — never
the path.

**The composition.** A symbol preset registered against an OpenHarmony
project (`openharmony.arkts-symbol@1`, `relativeSourceMap`) now composes, when
`ARKDECK_ANALYZER_PATH` names a symbolizer, into a preset that runs it as
`--symbolize-crash <root>/<map>`: both compositions read the variable (the
production one already required it absolute). A symbolizer that no longer
resolves declines the symbol presets and nothing else, so `symbolize-crash`
alone reports `workspace.symbolPresetUnavailable`; a symbol preset without a
map is skipped — Swift's `waterFlowDemo`.

## Choices and differences

- **Child environment**: a test run's child gets the home and temporary
  directory a build's gets, and the composition's overlay; a symbolization's
  child gets the clean base and the overlay (the mode reads no environment).
  Swift's children inherit the daemon's whole environment (declared, as for
  the other workspace children).
- **Where Swift traps, the symbolizer fails**: an arithmetic overflow in a
  hostile map (deltas or a position summing past 64 bits) crashes Swift's
  mode; here it is exit 1 and `arithmeticOverflow`. The oracle holds no such
  case (a unit test does). A single VLQ value cannot overflow in either: its
  digits occupy disjoint bits.
- **Map parsing**: `JSONSerialization` failures are Foundation's text; here
  they are the JSON parser's (exit 1 either way). A map `JSONSerialization`
  reads and a UTF-8 JSON parser does not (UTF-16, a byte-order mark, a number
  past a double) fails here; the build writes UTF-8 JSON.
- **A provider refusal at run time fails the Job** before any intent, as for
  every workspace operation on this Runtime.

## `operation.list` and project answers

Not changed by this PR. (A registered symbol preset now composes into its
project's profile when a symbolizer is configured, so `symbolize-crash` is
available in that profile — the answer the projection slice will publish.)

## Tests

- `crash_symbolizer_oracle` (hoststore, 1): the 77 recorded reports byte for
  byte, and each recorded error by its kind (and by Swift's own detail where
  the symbolizer wrote one).
- `workspace_test_symbolize_oracle` (hoststore, 3):
  - the 37 frames replayed in order over the same fixed root, profile,
    stand-ins, seeded crash logs and clock, every answer Swift's (the plan's
    additive review digest aside) and admitted by the published method
    schemas; the capability store, the products and the two parked records
    byte for byte; six children in all;
  - a test launcher or a symbolizer changed after its pin refuses the fresh
    action before any intent, with nothing started, and plans name the drift;
  - a person's primary tree is never tested — not under no capability, not
    under a grant the store holds for exactly that tree — and nothing is
    admitted.
- `crash_symbolizer_mode` (agentd, 2): the built daemon, environment cleared,
  answers every oracle case as Swift's report (exit 0, stdout exact) or error
  (exit 1, Swift's line); the usage refusals are Swift's line and exit 64 with
  nothing read; an unreadable map is exit 1 and never names its path.
- `workspace_symbolize_process` (agentd, 1): the production daemon over a
  temporary home, an OpenHarmony project with the obfuscated WaterFlow build's
  source map, its symbol preset registered, the device's crash log laid into
  the store: without `ARKDECK_ANALYZER_PATH` the operation names its preset
  unavailable; with the daemon itself as the symbolizer it plans host-only,
  runs, and publishes as sensitive text exactly the mode's report, which
  resolves the frame to `CrashProbe.ets` line 30.
- Unit tests: frame parsing, VLQ signs and continuations, deltas summing
  past 64 bits, line ends and whole-character prefixes; the tests' and
  symbolizations' verdicts and persisted actions; the dump check.

Mutations (`scratchpad/s28/mutate_c.py`), each caught by a failing test and
restored by checksum:

| Mutation | Caught by |
|---|---|
| a CR LF pair ends a line | `a_crlf_pair_is_not_a_line_end` |
| a repeated map key keeps its last value | the symbolizer oracle |
| a unit is looked up by its bytes | `a_unit_is_looked_up_by_canonical_equivalence` |
| a decomposed map key is not canonicalized | `a_unit_is_looked_up_by_canonical_equivalence` |
| a Base64 digit outside the alphabet is skipped | `vlq_decodes_sign_and_continuation` |
| a column before every segment stays unresolved | the symbolizer oracle |
| the dump's path left out of the symbolizer's argv | the operations oracle |
| a dump from the request's own target is admitted | `only_a_device_bound_crash_log_is_a_dump` |
| a crash index is admitted as a dump | `only_a_device_bound_crash_log_is_a_dump` |
| an empty symbolization verifies | `the_verdicts_are_swifts` |
| a failed test run publishes nothing | the operations oracle |
| the report published as standard | the operations oracle |
| a person's primary tree issued a standing capability | `only_a_runtime_owned_copy_is_issued_a_workspace_capability` |
| a lost symbolization reconciled as not executed | the operations oracle |
| the one-shot mode takes a relative path | `a_usage_the_mode_does_not_take_is_refused_before_anything_is_read` |

15/15 caught (`/private/tmp/arkdeck-s28-c-mutations.log`).

## Local targeted checks

With `CARGO_BUILD_JOBS=2` and this tree's own target; logs are
`/private/tmp/arkdeck-s28-c-*.log`.

- `cargo fmt --all --check`: exit 0.
- `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --all-targets -- -D warnings`: exit 0; the same with `--target
  x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc`: exit 0, 0.
- `cargo test -p arkdeck-hoststore -p arkdeck-agentd -p arkdeck-soak
  --no-fail-fast`: exit 0; 107 targets, 812 passed, 0 failed, 14 ignored
  (existing).
- Swift: `ARKDECK_RUST_CRASH_SYMBOLIZER_RECORD=<dir>
  ARKDECK_RUST_WORKSPACE_TEST_SYMBOLIZE_RECORD=<dir> sh
  Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter
  'CrashSymbolizerOracleContractTests|WorkspaceTestSymbolizeOracleContractTests'`
  twice (identical), then in verify mode over the checked-in fixtures: exit
  0, 0, 0 (`/private/tmp/arkdeck-s28-c-rec1.log`, `-rec2.log`,
  `-verify.log`).
- `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `check-readonly.py
  --bin-dir <target>/debug` (validation venv): exit 0, PASS.
- Mutations: 15/15 caught.
- `sh scripts/check-sdd.sh`: exit 0.
- Not run: `generate-contract.py --check` and `check-contracts.py` (no
  contract input changed), the App, signing, the installed service, devices.

## CI

PR #2195, merged as `f7a3b73f7`: at `e9f400e14` Agent PR 36149034640
(`open-pr`), SDD Guard 36149034470 (`guard`, `ds-tokens`) and Swift CI
36149034615 (`plan`, `swift-tests`, `ds-interactions`, the Rust
host-independent checks, the Rust workspace on ubuntu-latest, macos-26 and
windows-latest, and the `swift` aggregate; `app-build` skipped by the plan)
all succeeded.
