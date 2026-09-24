# TASK-XPA-015 — `arkdeck-agentd --analyze-crash-ledger`, and the cutover's analyzer gate opened by it

An M5 prerequisite, done in the A lane (G5 queue). The coordinator's ruling 2
of 2026-09-24 asked for two things. First, port Swift's one-shot crash-ledger
analyzer mode to the Rust daemon. Second, until that is done, refuse by name
any `runtime service update` that would point the LaunchAgent at the Rust
daemon: the plist's `ARKDECK_ANALYZER_PATH` names the installed daemon, and in
S13's production composition that is the Rust daemon, which had no such mode.
#2143 wrote that refusal as a gate, `ServiceHost::rust_daemon_analyzes_crash_ledgers`,
which was always false in production. This slice delivers the mode and
replaces that constant with a fact: the new helper's daemon either answers a
probe the way the Runtime runs its analyzer, or the update is refused.

The base is protected `main` `527459240` (#2143). The slice was developed on
#2143's head `8ff039cb9`, which has the same tree.

## What a caller sees

- `arkdeck-agentd --analyze-crash-ledger <absolute path>` reads the one file it
  is named and writes the canonical `HarnessCrashLedgerAnalysis` of that
  Faultlogger listing to stdout, then exits 0.
  - The answer lists the entries. If the bytes are not a readable listing, it
    is `unreadable` with Swift's reason: `invalidEncoding`,
    `ledgerHeaderAbsent`, `ledgerFenceAbsent` or `entryNameUnparseable`. It is
    never an empty ledger.
  - Any other arguments get Swift's line on stderr and exit 64, before
    anything is read.
  - A file that cannot be read, or an answer that cannot be written, exits 1
    with one stderr line that names the error.
  - The mode is answered before anything a daemon does, under any executable
    name. No environment is read, and no store, socket or device is touched.
- With `ARKDECK_ANALYZER_PATH` naming the Rust daemon, the Runtime runs the
  daemon as its own analyzer. The Runtime's runner, profile, verification and
  publication are unchanged. An `analyzer.extract-crash-signature@1` Job
  publishes `crash-signature.json` with Swift's analysis, beside the source's
  identity.
- `runtime service update` to a Rust helper:
  - It asks the helper's daemon to analyze a probe listing, the way the Runtime
    runs its analyzer. That means the Runtime's own `VerifiedTool::run_analyzer`,
    the pinned executable, an empty environment, the listing's `/.vol` alias
    and the Runtime's 30 s budget.
  - It goes on only if the daemon prints Swift's recorded answer byte for byte,
    which is the oracle's `runtime-service-probe` case.
  - A daemon without the mode, or one that answers differently, is refused by
    name (exit 69) before anything changes. The message names
    `ARKDECK_ANALYZER_PATH`, `--analyze-crash-ledger` and what the daemon did.
  - Past the gate, the cutover runs as #2143 wrote it. The plist's
    `ARKDECK_ANALYZER_PATH` names the installed daemon, which is the same file
    that was probed.

## Swift, the oracle

- **Who calls the mode, and how.**
  - Only the Runtime does. `ArkDeckAgentDaemonMain` composes the
    `crash-signature@1` profile (version `arkdeck-fault-log-ledger@1`) from
    `ARKDECK_ANALYZER_PATH`, pinned by SHA-256. It uses the fixed argument
    `--analyze-crash-ledger` and a 30 s timeout.
  - Its descriptor-bound dispatcher appends the source Artifact's `/.vol`
    alias as the one path.
  - `LaunchAgentService` writes the installed daemon's own path into the plist.
  - Neither the App nor the CLI runs the mode.
- **What the mode does** (`main.swift` top-level code, before daemon startup):
  - `CommandLine.arguments.dropFirst().first == "--analyze-crash-ledger"`.
  - Exactly one more argument, whose first Character is `/`. Otherwise it
    prints `--analyze-crash-ledger requires one absolute artifact path` and
    exits 64.
  - `Data(contentsOf: URL(filePath:))`. On failure it prints
    `crash-ledger analysis failed: <error>` and exits 1.
  - `FileHandle.standardOutput.write(HarnessCrashLedgerDerivedAnalyzer.analyze(bytes))`,
    then exit 0.
- **What the Runtime does with the answer.** This is unchanged, and it is
  `analyzer_output::verify` in Rust.
  - Exit 0 with a document in the versioned schema is verified. That includes
    `unreadable`.
  - Any other exit is `analyzer.failed`, which fails the Job and never
    replays it.
  - A signal or a timeout is an unknown outcome. The Job is parked and never
    redispatched.
- **`ARKDECK_ANALYZER_PATH` names more than this mode in Swift.**
  - The `hilog-summary@1` profile is composed only when the analyzer is the
    running daemon itself.
  - The workspace symbolizer runs `--symbolize-crash`.
  - The Rust daemon composes neither operation, so nothing runs those modes
    yet (see Declared differences).

### The recording

`CrashLedgerAnalyzerOracleContractTests` (Swift) runs the built Swift
`arkdeck-agentd` the way the Runtime runs it: an empty environment, no stdin, a
private file per case. It records every case's arguments (with placeholders for
the file's path, its `/.vol` alias, its directory and a missing path), input,
exit status, stdout and stderr in `rust/tests/fixtures/crash-ledger-analyzer/oracle.json`.
A read failure's stderr is recorded only as Swift's fixed prefix, because the
rest is Foundation's error text, which carries paths and object addresses. For
every exit-0 case, the test also checks that the stdout equals the in-process
`HarnessCrashLedgerDerivedAnalyzer.analyze` of the input.

Beside the 78 cases, the oracle holds four Character properties, each as
closed scalar ranges over every scalar: `Character.isNumber`, `isLetter`,
`isNewline` and `CharacterSet.whitespaces`. Without the recording variable the
test replays everything and must match the checked-in oracle.

The cases cover:

- usage: no path, two paths, relative, empty, a mark joined to the `/`;
- reads that fail: missing, a directory, `/`, mode 000, `file/.`;
- path spellings that read the file: the `/.vol` alias, trailing solidi,
  `/./` and `//`;
- the listing's frame: header or not, fences, the empty marker, text around
  the listing, a fence between entries, near-fences;
- entry names: field counts, 13- and 15-character timestamps, empty uid, kind
  or bundle, a bundle of hyphens, a NUL line, and JSON escapes (`"`, `\`, `/`,
  NUL, `\b`, ESC, U+001F, DEL, tab);
- 100 entries;
- encodings: invalid UTF-8, an encoded surrogate, one or two byte-order marks;
- Unicode: Arabic-Indic, fullwidth and Han numerals, fractions, katakana,
  private-use and Indic-conjunct kinds, combining marks on letters, digits and
  hyphens, a prepended mark or letter before a hyphen, emoji and
  regional-indicator bundles;
- the probe the update sends.

Facts the recording pinned, each of which a plain byte-level port gets wrong:

- **Encoding.** `String(data:encoding: .utf8)` drops exactly one leading
  byte-order mark. A second one stays, so that listing's first fence no longer
  matches.
- **Paths.** `URL(filePath:)` drops trailing solidi, so `file/` and `file///`
  read the file. `file/.` does not.
- **Characters, not bytes.** `hasPrefix("/")`, `contains` of the header and
  marker, `split(separator: "-")` and the 14-character timestamp are all
  Character operations. A mark joined to a `/`, a `:` or a hyphen changes the
  answer, as does a prepended character before one. The prepended characters
  are U+0600 and the Malayalam dot reph U+0D4E.
- **Trimming.** `trimmingCharacters(in: .whitespaces)` trims per scalar. On
  this host `.whitespaces` includes U+200B, which CoreFoundation still counts
  as whitespace.
- **`isNumber` and `isLetter`** judge a Character by its first scalar.
  - `isNumber` is `Numeric_Type` other than none. That includes 99 Han,
    compatibility-ideograph and cuneiform scalars outside `Nd`/`Nl`/`No`, so
    `一二三` is a uid.
  - `isLetter` is `Alphabetic`, plus 35 Apple private-use scalars.
  - Rust's standard library holds none of those 134 and holds nothing Swift
    lacks.
- **JSON escapes.** The canonical encoder writes backspace as `\b`, ESC as
  `\u001b` and DEL raw, as serde does.

## The port

- `arkdeck_hoststore::analyze_crash_ledger` (`crash_ledger.rs`) is
  `readIndex` and `parse(entryName:)` over the hoststore's Swift-pinned
  grapheme segmentation (`session_graphemes`). It uses the first-scalar
  property rules, with the two tables of scalars that Swift holds beyond the
  standard library.
  - The header and marker are found by a streaming Knuth–Morris–Pratt match
    over Characters, one pass, however long the listing is.
  - The document is encoded by `session_json::encode`. The analyzer
    constants are shared with `analyzer_output`, the Runtime's verifier of the
    same answer.
- `arkdeck_hoststore::crash_ledger_source` applies Swift's argument rules. It
  decodes a non-UTF-8 argument by replacement, as Swift's `CommandLine` does,
  and drops trailing solidi as `URL(filePath:)` does.
- `arkdeck-agentd`'s `crash_ledger_analyzer.rs` is dispatched first in
  `main()`, before the cutover preflight and any composition.
  - It writes the answer through its own handle on stdout. Through the
    standard library's handle, a stdout that is not open for writing would be
    taken as a stream to discard, and the mode would report success without
    delivering anything.
- The CLI's `analyzes_crash_ledgers` is the gate (`runtime_service_install.rs`).
  Its probe listing and answer are constants, and a test ties them to the
  oracle's `runtime-service-probe` case.
  - The listing is written to a private directory of the per-user temporary
    directory. It is opened as a `VerifiedSource`, the daemon is opened as a
    `VerifiedTool`, and the directory is removed afterwards.
  - The `ServiceHost` field is gone.
  - The signing-preset refusal still comes first. The typed `install` and a
    pinned `uninstall` refuse as before.

## Declared differences

- **A read failure's stderr.** Rust names only the OS error, where Swift's
  Foundation text also names the path and an object address. The prefix is
  the same, and the Runtime reads only the exit status and stdout.
- **An answer that cannot be written** (a stdout not open for writing, or a
  pipe nobody reads) exits 1 with the failure line. Swift's
  `FileHandle.write` raises instead, and the process aborts on a signal, which
  the Runtime would park as an unknown outcome.
  - The Runtime never closes its pipe early, so only a manual invocation can
    see this.
  - A stdout that is closed outright is reopened on `/dev/null` by the Rust
    runtime at start. The answer is then discarded with exit 0, and the
    Runtime refuses an empty answer anyway.
- **The update runs the new helper's daemon a second time** before it changes
  anything: the analyzer probe, after the lock-free preflight. Its listing
  lives only in a private temporary directory, which is removed.
- **Not ported yet: `--summarize-hilog` and `--symbolize-crash`.** The Rust
  daemon refuses them like any other argument, with exit 69. No Rust
  composition serves `analyzer.summarize-hilog@1` or
  `workspace.symbolize-crash@1`, so nothing runs them. They belong to the
  analyzers of this task's r11 order and to the M3 workspace operations. Once
  one of them is composed over a plist whose analyzer is the Rust daemon, that
  mode has to be ported first.
- **macOS builds only.** The mode is answered on macOS builds only, as Swift's
  daemon is macOS-only. The hoststore is linked into the daemon on macOS only.

## Tests

- `arkdeck-hoststore` `crash_ledger::tests` (4):
  - every exit-0 case's input is analyzed to the recorded stdout, byte for
    byte;
  - the four properties match the recording for every scalar;
  - Swift's argument rules, including trailing solidi as spelled and
    replacement decoding;
  - a refusal is never an empty ledger.
- `arkdeck-agentd` `tests/crash_ledger_analyzer.rs` (4):
  - Every case replayed through the built daemon with an empty environment:
    exit status, stdout and stderr byte for byte. A read failure's line is
    checked by Swift's prefix, as one line that carries no path.
  - The mode is answered first whatever the environment asks for: production
    together with a relative development root, a relocated home and a paired
    Swift daemon. It is answered under the facade's name too, and nothing is
    created. Arguments that only resemble the mode are the daemon's 69, and
    nothing is read.
  - A read-only stdout and an unread pipe exit 1 with one line.
  - The isolated Runtime runs the daemon as its own analyzer. It uses
    `ARKDECK_ANALYZER_PATH` set to the daemon and the reconcile oracle's
    source, through `job.submit`, `job.run`, `artifact.list` and
    `artifact.read`.
    - The published envelope is Swift's analysis of those bytes, with the
      source's ID, SHA-256 and size and the analysis's own digest and size.
    - The raw source is unchanged, still 0400.
    - The recorded retention deadlines have passed, so the seeded copy's are
      moved forward at their recorded length, as `fixture-deadlines.py` does.
- `arkdeck-cli` `tests/runtime_service.rs` (34, of which 3 are new and 3
  rewritten). The fake Rust helper's daemon now answers the probe only for the
  exact listing, and logs its arguments and environment.
  - The probe constants are the oracle's case.
  - A daemon without the mode (as before this slice: 69) and one that answers
    otherwise are refused by name. Only the lock-free pass and the probe ran,
    nothing changed, and launchd was only asked `print`.
  - A signing preset refuses before the helper runs at all.
  - The cutover passes the gate on the fact alone. Its runs are the lock-free
    pass, the probe (with the `/.vol` alias and an empty environment), then
    the held passes, and its plist still names the installed daemon as the
    analyzer.
  - When the first pass refuses, only the lock-free pass and the probe ran.
- 18 mutations were run through `scratchpad/s19/mutate.py`, each restored by
  checksum. 17 were caught by a test failure (not a build error):
  - the byte-order mark kept, or every one dropped;
  - U+200B not trimmed;
  - standard-library numerals or letters only;
  - hyphens split per scalar;
  - the header found by bytes;
  - the timestamp counted in scalars;
  - every scalar judged instead of the first;
  - `/` judged per scalar;
  - trailing solidi kept;
  - stdout through the standard handle;
  - usage exit 1;
  - the gate always open;
  - any exit-0 answer accepted;
  - the probe given the plain path;
  - a changed probe answer.

  The survivor trims lines before dropping empty ones. It is equivalent:
  Swift keeps whitespace-only lines as empty strings, and they are skipped
  between the fences and are never a fence.

## Local targeted checks

The checks used `CARGO_BUILD_JOBS=2` and the target
`/private/tmp/arkdeck-1330-rust-target`. Logs are in
`/private/tmp/arkdeck-s19-*.log`. The changed crates are `arkdeck-hoststore`,
`arkdeck-agentd` and `arkdeck-cli`. Adding `arkdeck-soak`, the hoststore's
other direct dependent, gives the four crates checked.

| Command | Exit | Log |
| --- | --- | --- |
| `run-swiftpm.sh test --filter CrashLedgerAnalyzerOracleContractTests` with `ARKDECK_RUST_CRASH_LEDGER_RECORD` (the recording) | 0: 1 test, 0 failures | `arkdeck-s19-swift-record-3.log` |
| `run-swiftpm.sh test --filter CrashLedgerAnalyzerOracleContractTests` (replay against the checked-in oracle) | 0: 1 test, 0 failures | `arkdeck-s19-swift-check.log` |
| `cargo fmt --all --check` | 0 | `arkdeck-s19-fmt.log` |
| `cargo clippy --all-targets -- -D warnings` for the four crates | 0 | `arkdeck-s19-clippy.log` |
| `cargo build -p arkdeck-cli -p arkdeck-agentd`, then `cargo test --no-fail-fast` for the four crates | 0: 114 result lines, 890 passed, 0 failed, 14 existing ignored; `crash_ledger` 4, `crash_ledger_analyzer` 4, `runtime_service` 34 (re-run alone after the last edit, to the probe's failure wording: 34 passed, `arkdeck-s19-quick2.log`) | `arkdeck-s19-tests.log` |
| 18 mutations | 17 caught, 1 equivalent | `arkdeck-s19-mutations.log` |
| `sh scripts/check-sdd.sh` | 0 (0 errors, 0 warnings) | `arkdeck-s19-sdd.log` |

Afterwards no scratch directory (`/private/tmp/arkdeck-crash-ledger-*`), probe
directory or test process was left. The installed agentd (PID 10694) and HDC
server (PID 10798) were the same processes as before the session. No
launchctl was run.

Not run:

- `generate-contract.py` and `check-contracts.py`: no contract input, argv
  corpus or crate edge changed.
- App build: no App file changed.
- The full local gate.
- A signed helper, an installed service, or a device.

## Remaining for the cutover (not in this slice)

- A Rust signing-credential owner (Q8), which would re-record the daemon
  identity instead of refusing the update.
- An owner for the bootstrap registries' installation references, for the
  typed `install` and for `uninstall`'s release.
- `--summarize-hilog` and `--symbolize-crash`, before either operation is
  composed over a plist whose analyzer is the Rust daemon.
- The installed cutover itself (§G.4), on the reference host with a signed
  helper.

## CI

Pending.
