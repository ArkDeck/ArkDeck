# TASK-XPA-018 — contracts export S6: `maintainer contracts export|check` (macOS, 2026-09-25)

TASK-XPA-018 remains in progress. This is contracts-export slice S6, the
last of the six the hub approved. The Rust CLI now serves
`arkdeck maintainer contracts export|check` (Swift's
`RuntimeCLI.runMaintainerContracts`) over the bundle S1–S5 render. Base:
`main` `f7a3b73f7` (S5, #2194, merged at `f97ec67b9`).

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No Runtime,
control schema, corpus, Catalog, `openspec/contracts`, `openspec/specs` or
constitution change; the bundle itself is unchanged. The fact source does
not move. Swift's export and its zero-drift test still publish the bundle,
and until M5 the Rust export must equal it (TASK-XPA-018's production
reachability).

## What changes

- `maintainer contracts export --contracts-directory <dir>
  --fixtures-directory <dir> [--output human|json]` follows Swift's
  `CLIMachineContracts.export`. It writes every contract product. In the
  fixtures directory it first removes each regular, visible file that no
  fixture names, then writes every fixture. Each file is written to a hidden
  sibling and renamed into place, as Swift's `.atomic` write does. The
  report carries `bundleVersion`, the two directories, `written` (235) and
  `removed`.
- `maintainer contracts check` follows Swift's `check`. It compares each
  product with its file; a file it cannot read counts as missing. It also
  lists, sorted, the regular, visible files in the fixtures directory that no
  product names. The report carries `clean`, `checked`, `drifted`,
  `missing`, `unexpected` and the fields above. A drifted bundle still gets
  its report, then exits `operationFailed` (1) with a stderr diagnostic in
  Swift's words, never a second document (Swift's
  `suppressesMachineRendering`).
- Directories are named as Swift's
  `URL(fileURLWithPath:).standardizedFileURL.path` names them: relative to
  the working directory, `.` and `..` resolved by name, and on macOS a
  leading `/private` dropped only where what remains exists. So a
  directory the export creates is named with `/private` the first time, and
  without it once it exists.
- Hidden files are skipped as Foundation's enumerator skips them: a leading
  dot, or on macOS the hidden flag (`host_entry_presentation`). A hidden
  directory is not entered, and a symbolic link is neither followed nor
  listed.
- A generator failure answers `internalError` in its own words, as Swift's
  `CLIMachineContracts.Failure` does; this port asserts its invariants, and
  the leaf catches the unwinding quietly. An I/O failure answers
  `ioFailure` with "the contract bundle could not be written or read: …".
  The last part is this build's error text where Swift writes Foundation's,
  a declared difference in words.
- `human_rendering` ports Swift's generic `RuntimeCLI.humanRendering(of:)`,
  which no leaf of this CLI had used before.
- The CLI serves 137 of the 209 leaves. The two new ones' argv fixtures now
  replay through the parser.

## The Swift oracle

As the hub asked, Swift's answers were recorded, in a Swift build window it
granted. `rust/scripts/record-maintainer-contracts-oracle.py` (new) runs the
built Swift `arkdeck` (SHA-256 `646f784f…`, the same before and after the
recording) on 14 cases in fresh scratch directories, and keeps each exit
status, stdout, stderr, and, for an export, the tree it leaves. The cases
are seven situations, each in `--output json` and in human mode:

- a check of a clean bundle, of a drifted one, of one with missing
  products, and of one with stray visible files, beside hidden ones;
- an export into directories holding stale files;
- an export into directories that do not exist yet;
- an export into a fixtures directory holding links to a file, to a
  directory and to nothing, all pointing into the scratch root's own
  `outside/`.

The case root is written `<root>`, and the random control-request identity
`<controlRequestId>`. The recording is
`rust/tests/fixtures/maintainer-contracts/oracle.json`.

`swifts_recorded_answers_replay` builds each case again with this CLI's own
export and compares all of it byte for byte, the tree after an export
included. All 14 match. The recording also answers the hub's question about
links: Swift's export removes none of the three and follows neither, and
`outside/file.txt` and `outside/directory/inner.json` are intact after it.
So this port's rule (delete only `lstat`-regular visible files) is Swift's,
not a declared difference.

The replay runs on Unix hosts. Windows spells the same directories with
other separators, so its CLI tests hold the leaves without it.

## The CI gate

The CI gate is `machine_contracts`, as the hub ruled. Its test compares all
235 products byte for byte in every Rust lane (S1–S5), so a CI step running
`contracts check` would repeat it, and no CI configuration changes. The two
leaves have end-to-end tests of their own:

- In a checkout, a check of the committed bundle must exit 0. A contract
  view carries only part of the bundle, so there the test leaves this to the
  checkout.
- Every export runs in a temporary directory, never in the repository.

## What an export deletes

An export removes files from a directory its caller names, so it deletes
only what `lstat` calls a regular, visible file. It never deletes a
symbolic link, a directory or a hidden file, and it never follows a link.
The walk takes each entry's own type (`DirEntry::file_type`, which does not
follow links), enters only real directories, and skips hidden entries.

The scope is Swift's. `regularFiles(under:)` recurses through the fixtures
directory's subdirectories, so a stale file in a subdirectory is removed as
well, as `fixtures/nested/stray.txt` is in the tests. A test puts links in
the fixtures directory, to a file and to a directory outside it. After an
export both links and both targets are still there, and nothing is
reported removed.

## The fact source, and regenerating the bundle

`tasks.md` (TASK-XPA-018) gives the rule. `maintainer contracts export`
produced by Rust must equal the published bundle before the fact source
flips. The bundle is the oracle until parity, and then Rust becomes the
oracle.

With this slice the Rust export writes the whole bundle, byte for byte as
published: S1–S5 hold every product, and the tests here write and check it.
So the parity half of the rule is met. The flip itself is not made here.
Swift's export and its zero-drift test (`CLIMachineContractTests`) still
hold the published bundle to Swift's own rendering. Until M5 removes them,
both builds are held to the same bytes, and neither can change the bundle
alone. The flip is complete when Swift's CLI and that test are gone.

From this slice on, the bundle can be regenerated with the Rust export
instead of Swift's build, which frees the Swift build window. That depends
on what changed:

- A contract input (the control protocol, a method schema, the Catalog).
  The products that follow it (control-plane and result schemas, command
  registry, feature coverage) are rendered from the compiled contract. Run,
  from the repository root:

  ```bash
  cargo run --manifest-path rust/Cargo.toml -p arkdeck-cli --bin arkdeck -- maintainer contracts export --contracts-directory openspec/contracts --fixtures-directory Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/CLI
  ```

  Swift's zero-drift test then checks the result in the Swift lane, as
  before.
- Swift's command registry or the App's capability table. Here Swift is
  still the source: the Rust copies (`command_registry.json`,
  `app_capability_registry.json`) are taken from the published registries.
  Swift's export comes first (the S2 record's commands), then the copy
  scripts and `refresh-contract-digests.py`.

This supersedes the S2 record's "Changing a contract input" for the first
case once this slice is in `main`.

## Tests

| Test | What it holds |
| --- | --- |
| `maintainer_contracts.rs::the_export_writes_the_bundle_this_build_renders` | An export into empty directories writes the 235 products byte for byte, with one document naming them, and a check of it is clean |
| `…::a_drifted_bundle_is_reported_then_fails_without_a_second_document` | A drifted, a missing and two stray visible files are reported, then exit 1 with Swift's diagnostic; hidden files and directories are no one's; an export removes the strays and keeps the hidden |
| `…::the_human_rendering_is_swifts` | A clean check's report, and a drifted list, as Swift's generic rendering prints them |
| `…::a_directory_is_named_as_swifts_url_standardizes_it` | Relative directories, `.` and `..`; on macOS `/private` kept while the directory does not exist and dropped once it does |
| `…::the_committed_bundle_checks_clean` | In a checkout, the committed bundle is clean; a contract view, which carries only part of it, leaves this to the checkout |
| `…::an_unwritable_bundle_is_an_io_failure_in_one_document` | `ioFailure` (74), one failure document in JSON, the diagnostic in human |
| `…::the_leaves_refuse_a_runtime_endpoint_and_correlation` | `--socket` and `--control-request-id` refused in Swift's parser's words (`--socket` off macOS as the platform's) |
| `lib.rs` `tests::the_human_rendering_is_swifts_generic_one` | Nested objects keep their inner indentation, as Swift trims only a rendering's ends |
| `maintainer_contracts::tests::a_generator_failure_is_answered_with_its_words` | A broken invariant's words become the failure |
| `…::swifts_recorded_answers_replay` (Unix) | Swift's 14 recorded answers, byte for byte, with the trees an export leaves |
| `…::an_export_never_deletes_a_link_or_through_one` (Unix) | Links to a file and to a directory outside the fixtures directory survive an export, and so do their targets |
| `argv_fixtures.rs::every_served_leafs_argv_fixture_replays` | Now over 137 leaves, the two new ones included |

## Mutations

Each mutation changed one place, then ran `tests/maintainer_contracts.rs`,
`tests/argv_fixtures.rs` and the library's unit tests after an unmutated
baseline, and restored the file by digest
(`/private/tmp/arkdeck-s6-mut.log`), with the Swift replay in place. All 10
were killed. The `/private` rule is macOS's alone, and the Swift recording
names its roots under `/tmp`, so the directory test holds that rule.

| Mutation | Killed by |
| --- | --- |
| Hidden files counted | the drift test; the Swift replay |
| An unreadable product called drifted | the drift test; the Swift replay |
| Stale fixtures kept by the export | the drift test; the Swift replay |
| `/private` kept wherever | the directory test |
| `/private` dropped whether or not the rest exists | the directory test |
| Drift failing as an internal error | the drift test; the Swift replay; the human test |
| A second document after the report | the drift test; the Swift replay |
| Human keys out of order | both human rendering tests; the Swift replay |
| Nested renderings untrimmed | both human rendering tests; the Swift replay |
| The directories not required | the argv replay (`missingRequired`) |

## Local targeted checks

Logs are under `/private/tmp/`.

| Check | Command | Result |
| --- | --- | --- |
| fmt | `cargo fmt --all --check --manifest-path rust/Cargo.toml` | exit 0 (`arkdeck-s6-fmt.log`) |
| clippy | `cargo clippy --manifest-path rust/Cargo.toml -p arkdeck-cli --all-targets -- -D warnings` | exit 0 (`arkdeck-s6-clippy.log`) |
| clippy, Windows | the same with `--target x86_64-pc-windows-msvc` | exit 0 (`arkdeck-s6-winclippy.log`) |
| clippy, Linux | the same with `--target x86_64-unknown-linux-gnu` | exit 0 (`arkdeck-s6-linuxclippy.log`) |
| CLI tests | `cargo test --no-fail-fast --manifest-path rust/Cargo.toml -p arkdeck-cli` | exit 0: 348 passed, none failed (`arkdeck-s6-test.log`) |
| Mutations | `s6_mutations.py` (scratch) | 10 of 10 killed |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 (`arkdeck-s6-sdd.log`) |

Not run: `generate-contract.py --check` and the contract views, because no
contract input changes.

## CI

- This PR: pending.
