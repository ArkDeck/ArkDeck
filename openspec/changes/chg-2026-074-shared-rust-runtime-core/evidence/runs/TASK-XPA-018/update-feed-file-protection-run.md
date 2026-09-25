# TASK-XPA-018 — update-feed material written without a protection class (macOS, 2026-09-26)

TASK-XPA-018 remains in progress. This change is the Swift CLI's
`maintainer update-feed prepare` and `assemble` only, as the coordinator
dispatched it after #2221. The local checks below ran on `main` `a9d840f0d`.
The branch was then rebased onto `9f1fdcce3` (#2220, #2222), which changes
none of these files and no Swift source.

Nothing here is device evidence (POL-VERIFY-001, POL-MODE-001). No contract
input, Catalog, schema, `openspec/contracts`, `openspec/specs`, constitution
or `tasks.md` change, and no signing or verification code changes.

## What failed

`ArkDeckCLIMain.swift` wrote the three files of update-feed material with
`[.atomic, .completeFileProtection]`:

- lines 503 and 504, in `prepare`: the canonical payload and the signature
  input;
- line 598, in `assemble`: the assembled feed.

On this host, macOS 27.0 (26A428), a write with the complete Data Protection
class is refused with `NSCocoaErrorDomain` 513 (`NSPOSIXErrorDomain` 1,
EPERM). A standalone check reproduced it with and without `.atomic`; `.atomic`
alone writes. The hub reproduced it under both `/private/tmp` and
`~/Library/Caches`. So the success path of both leaves always answered
`ioFailure` and exited 74, and a maintainer could not prepare a release on
this host. These were the repository's only uses of a file protection class.

## What changes

- The three writes go through one function,
  `ArkDeckCommandLine.writeUpdateFeedFile(_:to:)`, which writes atomically
  with no protection class. The output directory stays `0o700`, and nothing
  else in either leaf changes.
- Why this is not a weakened safeguard: the three files are public
  update-feed material. What vouches for them is the Ed25519 signature
  under the production key, which `assemble` verifies before it writes, and
  the protection class carried no confidentiality.

## Tests

`CLIUpdateFeedWriteContractTests`:

| Test | What it holds |
| --- | --- |
| `testPrepareWritesThePayloadAndTheSignatureInput` | `prepare` end to end in a temporary directory: the payload carries the sequence, version and the artifact's length and SHA-256; the signature input is `UpdateFeedCodec.signatureInput` of that payload under the production key ID; the output directory is `0o700` |
| `testUpdateFeedFilesAreWrittenAtomicallyWithNoProtectionClass` | The one write function, which `assemble`'s feed goes through, writes and atomically replaces a file on the host |
| `testEveryUpdateFeedWriteGoesThroughTheOneFunction` | A check of the source: `prepare` and `assemble` write only through `writeUpdateFeedFile`, never with `.write(to:` of their own, and neither they nor the function name a protection class |

**`assemble` has no end-to-end test.** It verifies the feed it assembles
against the hard-coded production public key (`UpdateFeedTrust.production`),
and by design no trust can be substituted for a test. A feed signed with a
fixture key therefore never reaches the write. The coordinator ruled that
opening a trust seam in verification for a test would be worse than the
defect. The write is held by the function test and by the source check
instead.

**Mutation.** With `.completeFileProtection` put back into
`writeUpdateFeedFile`, all three tests fail on this host.
- `prepare` answers `ioFailure` ("preparing the payload failed": no
  permission to save the payload).
- The function itself throws `NSCocoaErrorDomain` 513 ("Creating a temporary
  file via mktemp failed … errno 1").
- The source check fails on its protection-class assertion.

The mutation ran only on this host. Whether GitHub's macOS runners refuse the
class has not been checked. The source check fails on any host, so a
reintroduced class is caught either way.

## Left open

- **`assemble`'s real success path on this host.** It can only be exercised
  with a feed signed by the production key, which a test does not have. The
  maintainer's next release run is its first real verification.
- **#2221's residual risk.** A tool shim is told by its signing identifier's
  prefix, `com.apple.dt.xcode_select.tool-shim`. If Apple gave the shims
  another identifier, the identification would miss them and the defect
  would come back. Two host tests are its sentinels. They run on CI's
  `macos-26` runners whenever the Rust or Swift lane runs. Each asserts that
  `/usr/bin/git` is still identified as a shim, so they are the first to fail
  after such a macOS change:
  - Rust `tool_shim::tests::the_host_tools_are_told_by_their_signature_not_their_links`;
  - Swift `XcodeToolShimContractTests.testTheHostToolsAreToldByTheirSignatureNotTheirLinks`.

## Local targeted checks

| Check | Command | Result |
| --- | --- | --- |
| Swift | `sh Packages/ArkDeckKit/Scripts/run-swiftpm.sh test --filter 'CLIUpdateFeedWriteContractTests\|CLIArgumentParserContractTests\|CLIProcessGoldenContractTests\|AutoUpdateContractTests'`, in a SwiftPM window the hub granted | 101 contract tests and 23 ClientKit tests, 0 failures; the mutation above fails all three new tests |
| Records | `ARKDECK_PYTHON=<validation venv> sh scripts/check-sdd.sh` | 0 errors, 0 warnings; exit 0 |

## CI

- This PR: pending.
