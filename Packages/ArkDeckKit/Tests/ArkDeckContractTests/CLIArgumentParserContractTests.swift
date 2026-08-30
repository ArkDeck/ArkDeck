import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCLI
@testable import ArkDeckCore

/// Strict argv (CLI-REQ-005) and the argv-level half of the machine contract
/// (§8.1, §8.2, §9).
///
/// The behaviour being locked down is refusal. Before the registry, the
/// Runtime families read flags by scanning argv for the one they wanted, so an
/// unknown flag, a repeated flag or a flag belonging to a different command was
/// dropped without a word — and a caller who mistyped `--jobs` got the same
/// exit status as one who did not, on a command that then asked the daemon for
/// a job it had never been told about.
final class CLIArgumentParserContractTests: XCTestCase {

  private func parse(_ argv: [String]) -> Result<CLIInvocation, CLIRegistryError> {
    CLIArgumentParser.parse(argv)
  }

  private func failure(_ argv: [String], file: StaticString = #filePath, line: UInt = #line)
    -> CLIRegistryError?
  {
    switch parse(argv) {
    case .failure(let error): return error
    case .success:
      XCTFail("`\(argv.joined(separator: " "))` was accepted", file: file, line: line)
      return nil
    }
  }

  private func success(_ argv: [String], file: StaticString = #filePath, line: UInt = #line)
    -> CLIInvocation?
  {
    switch parse(argv) {
    case .success(let invocation): return invocation
    case .failure(let error):
      XCTFail(
        "`\(argv.joined(separator: " "))` was refused: \(error.message)", file: file, line: line)
      return nil
    }
  }

  // MARK: Strict argv

  func testAnUnknownOptionIsRefusedRatherThanDropped() {
    let error = failure(["job", "status", "--job", "J-1", "--jobs", "J-2"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertEqual(error?.exitCode, 64)
    XCTAssertEqual(error?.details["option"], .string("--jobs"))
  }

  func testARepeatedOptionIsRefused() {
    let error = failure(["job", "status", "--job", "J-1", "--job", "J-2"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertTrue(error?.message.contains("more than once") == true)
  }

  func testAnOptionWithoutItsValueIsRefused() {
    let error = failure(["job", "status", "--job"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertTrue(error?.message.contains("requires a value") == true)
  }

  func testAMissingRequiredOptionIsRefused() {
    let error = failure(["job", "status"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertTrue(error?.message.contains("--job") == true)
  }

  /// An option that belongs to a sibling command is exactly the case the old
  /// scanning parser could not see: `job status` never looked for `--target`,
  /// so it went to the daemon as a status request with a silently discarded
  /// argument.
  func testAnOptionFromASiblingCommandIsRefused() {
    let error = failure(["job", "status", "--job", "J-1", "--target", "T-1"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertEqual(error?.details["option"], .string("--target"))
  }

  func testMutuallyExclusiveRequestFormsAreRefusedTogether() {
    let error = failure([
      "job", "plan", "--request-file", "r.json", "--operation", "observe.device@1",
    ])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertTrue(error?.message.contains("only one of") == true)
  }

  func testExactlyOneResidueSelectorIsRequired() {
    XCTAssertEqual(failure(["cleanup-debt", "continue", "--job", "J-1"])?.code, .invalidOption)
    XCTAssertEqual(
      failure([
        "cleanup-debt", "continue", "--job", "J-1", "--remote-path", "/p", "--bundle", "b",
      ])?.code,
      .invalidOption)
    XCTAssertNotNil(success(["cleanup-debt", "continue", "--job", "J-1", "--bundle", "b"]))
  }

  func testBoundedIntegerValuesRejectRangeSignAndLeadingZero() {
    for rejected in ["0", "1001", "-1", "+7", "007", "1e3", " 5", ""] {
      XCTAssertEqual(
        failure(["job", "list", "--page-size", rejected])?.code, .invalidOption,
        "--page-size \(rejected) must be refused")
    }
    XCTAssertNotNil(success(["job", "list", "--page-size", "1000"]))
  }

  func testAnUnknownCommandAndAnIncompletePathAreUsageErrors() {
    XCTAssertEqual(failure(["bogus"])?.code, .invalidCommand)
    XCTAssertEqual(failure(["job"])?.code, .invalidCommand)
    XCTAssertEqual(failure(["job", "bogus"])?.code, .invalidCommand)
    XCTAssertEqual(failure(["bogus"])?.exitCode, 64)
  }

  /// §5.1: global options never sit between path tokens.
  func testAGlobalOptionBetweenPathTokensIsRefused() {
    let error = failure(["job", "--output", "json", "status", "--job", "J-1"])
    XCTAssertEqual(error?.code, .invalidOption)
  }

  // MARK: Applicability

  /// §5.2: a leaf refuses a global option it does not declare, rather than
  /// dropping it. `--socket` is the compatibility alias and belongs only to
  /// leaves that open the local control connection.
  func testTheLocalEndpointAliasIsRefusedByLeavesThatNeverConnect() {
    XCTAssertEqual(
      failure(["flash", "status", "--campaign-id", "E-1", "--socket", "/tmp/s"])?.code,
      .invalidOption)
    XCTAssertEqual(
      failure(["update-feed", "assemble", "--payload", "p", "--signature", "s", "--out", "o",
        "--socket", "/tmp/s"])?.code,
      .invalidOption)
    XCTAssertNotNil(success(["operation", "list", "--socket", "/tmp/s"]))
  }

  func testOutputIsAcceptedByEveryLeafThatDeclaresItAndRefusedByTheRest() {
    XCTAssertNotNil(success(["doctor", "--output", "json"]))
    XCTAssertNotNil(success(["job", "list", "--output", "json"]))
    XCTAssertNotNil(success(["agentd", "status", "--output", "json"]))

    // The legacy archive leaves gained structured results, so they answer too.
    XCTAssertNotNil(
      success(["flash", "status", "--campaign-id", "E-1", "--output", "json"]))
    XCTAssertNotNil(success(["flash", "reconcile", "--output", "json"]))

    // The maintainer feed tooling is the one family still without a structured
    // result, so it refuses the option rather than wrap a sentence in an
    // envelope and call that machine output.
    XCTAssertEqual(
      failure([
        "update-feed", "assemble", "--payload", "p", "--signature", "s", "--out", "o",
        "--output", "json",
      ])?.code,
      .invalidOption)
  }

  /// §8.1 scopes `jsonl` to the durable event stream. No leaf publishes one,
  /// so accepting the mode would promise a stream that cannot be produced.
  func testJsonlIsRefusedUntilADurableEventStreamExists() {
    for argv in [["job", "list"], ["doctor"], ["commands"]] {
      let error = failure(argv + ["--output", "jsonl"])
      XCTAssertEqual(error?.code, .invalidOption, argv.joined(separator: " "))
    }
  }

  /// §12: `--json` keeps the shape it has always had and `--output json` is the
  /// new contract, so one invocation cannot ask for both.
  func testTheTwoMachineOutputSpellingsExcludeEachOther() {
    let error = failure(["operation", "list", "--output", "json", "--json"])
    XCTAssertEqual(error?.code, .invalidOption)
    XCTAssertTrue(error?.message.contains("only one of") == true)
  }

  func testTheCorrelationIdentityIsValidatedAndEchoedOnlyWhenItIsSound() {
    XCTAssertNotNil(
      success(["job", "status", "--job", "J-1", "--control-request-id", "my.run:1-a_b"]))
    for rejected in ["", "-leading", ".dot", "has space", "emoji-🙂", String(repeating: "a", count: 129)]
    {
      XCTAssertEqual(
        failure(["job", "status", "--job", "J-1", "--control-request-id", rejected])?.code,
        .invalidOption,
        "control request id \(rejected.debugDescription) must be refused")
    }
    XCTAssertNotNil(success(["job", "status", "--job", "J-1", "--control-request-id",
      String(repeating: "a", count: 128)]))

    // §8.1: exactly one sound value is echoed; anything else gets a fresh
    // bounded identity rather than putting unvalidated bytes in machine output.
    XCTAssertEqual(
      CLIArgumentParser.bootstrapControlRequestID(["--control-request-id", "ok-1"]), "ok-1")
    for unusable in [
      ["--control-request-id"], ["--control-request-id", "bad id"],
      ["--control-request-id", "a", "--control-request-id", "b"], [],
    ] {
      let generated = CLIArgumentParser.bootstrapControlRequestID(unusable)
      XCTAssertTrue(generated.hasPrefix("ctl-"), "\(unusable)")
      XCTAssertTrue(CLIControlRequestID.isValid(generated))
    }
  }

  /// §12: an explicit legacy-compatibility leaf has to say so in machine
  /// output, because the caller cannot otherwise tell it is driving the frozen
  /// 1.x surface rather than the target one.
  func testLegacyLeavesAreMarkedInTheRegistryAndInTheEnvelope() {
    for path in [["device", "list"], ["debug", "status"], ["artifact", "import-hap"]] {
      let leaf = CLICommandRegistry.allLeaves()
        .first { $0.path == path }?.leaf
      XCTAssertEqual(leaf?.lifecycle, .legacy, path.joined(separator: " "))
    }
    XCTAssertEqual(
      CLICommandRegistry.allLeaves().first { $0.path == ["job", "status"] }?.leaf.lifecycle,
      .current)

    let envelope = CLIResultEnvelope.withLifecycle(
      CLIResultEnvelope.success(
        command: "device.list", result: .array([]), controlRequestID: "ctl-test"),
      .legacy)
    guard case .object(let fields) = envelope, case .object(let meta)? = fields["meta"],
      case .object(let lifecycle)? = meta["lifecycle"]
    else {
      return XCTFail("a legacy leaf must carry meta.lifecycle")
    }
    XCTAssertEqual(lifecycle["status"], .string("legacy"))
    XCTAssertEqual(lifecycle["replacementArgvPattern"], .null)
    XCTAssertEqual(lifecycle["removalVersion"], .null)

    // A current leaf carries no lifecycle at all rather than a "current" one.
    let current = CLIResultEnvelope.withLifecycle(
      CLIResultEnvelope.success(
        command: "job.status", result: .object([:]), controlRequestID: "ctl-test"),
      .current)
    guard case .object(let plain) = current, case .object(let plainMeta)? = plain["meta"] else {
      return XCTFail("meta is required")
    }
    XCTAssertNil(plainMeta["lifecycle"])
  }

  /// §12 lists "errors are not JSON" as a `--json` defect to fix while keeping
  /// its shape. It is not the envelope: that is what `--output json` is for.
  func testLegacyJsonAnswersFailuresAsJsonWithoutTheEnvelope() {
    let error = CLIRegistryError(
      code: .resourceNotFound, message: "unknown job J-1", command: "job.status")
    guard case .object(let fields) = CLIResultEnvelope.legacyFailure(error) else {
      return XCTFail("legacy-json failures must still be JSON")
    }
    XCTAssertNil(fields["schemaVersion"], "legacy-json is not the versioned envelope")
    XCTAssertNil(fields["meta"])
    guard case .object(let body)? = fields["error"] else { return XCTFail("error is required") }
    XCTAssertEqual(body["code"], .string("resourceNotFound"))
  }

  /// The old renderer fell back to the human layout when encoding failed,
  /// handing a machine caller prose where it expected JSON (§8.1 forbids it).
  func testLegacyJsonNeverFallsBackToProse() {
    let unencodable = JSONValue.number(.nan)
    let rendered = CLIRuntimeSession.legacyDocument(unencodable)
    XCTAssertTrue(rendered.hasPrefix("{"), "the fallback must still be JSON: \(rendered)")
    XCTAssertTrue(rendered.contains("internalError"))
    XCTAssertTrue(rendered.hasSuffix("\n"))
  }

  func testOutputIsAcceptedInEitherGlobalPositionButNotTwice() {
    guard case .commands(let leading)? = success(["--output", "json", "commands"]) else {
      return XCTFail("a leading --output must reach the meta-command")
    }
    XCTAssertEqual(leading, .json)
    guard case .commands(let trailing)? = success(["commands", "--output", "json"]) else {
      return XCTFail("a trailing --output must reach the meta-command")
    }
    XCTAssertEqual(trailing, .json)
    XCTAssertEqual(
      failure(["--output", "json", "commands", "--output", "json"])?.code, .invalidOption)
  }

  /// `update-feed prepare --version` is a leaf option, and a leaf option wins
  /// over the global spelling. Otherwise a maintainer publishing a release
  /// would get the CLI's own version instead.
  func testALeafOptionShadowsTheGlobalVersionSpelling() {
    let argv = [
      "update-feed", "prepare", "--sequence", "3", "--version", "1.2.3",
      "--minimum-system", "14.0.0", "--issued-at", "2026-08-31T00:00:00Z",
      "--expires-at", "2026-09-30T00:00:00Z", "--artifact", "ArkDeck.dmg",
      "--artifact-url", "https://example.invalid/a.dmg", "--notes", "n", "--out", "/tmp/out",
    ]
    guard case .dispatch(let path, _, _)? = success(argv) else {
      return XCTFail("the leaf must be dispatched, not answered with a version banner")
    }
    XCTAssertEqual(path, ["update-feed", "prepare"])
  }

  // MARK: Help, version and discovery

  func testEmptyArgvIsRootHelpAndNotAUsageError() {
    guard case .rootHelp? = success([]) else { return XCTFail("empty argv must be root help") }
  }

  func testHelpIsAnsweredAtEveryLevel() {
    guard case .rootHelp? = success(["--help"]) else { return XCTFail("root --help") }
    guard case .nodeHelp(let node)? = success(["job", "--help"]) else {
      return XCTFail("node --help")
    }
    XCTAssertEqual(node.token, "job")
    guard case .leafHelp(let path, _)? = success(["job", "status", "--help"]) else {
      return XCTFail("leaf --help")
    }
    XCTAssertEqual(path, ["job", "status"])
    guard case .leafHelp(let viaHelp, _)? = success(["help", "job", "status"]) else {
      return XCTFail("help <path>")
    }
    XCTAssertEqual(viaHelp, ["job", "status"])
    guard case .rootHelp? = success(["-h"]) else { return XCTFail("-h is the same request") }
  }

  /// Help is prose, so a machine mode is refused rather than answered with
  /// text the caller cannot parse. Dropping the option instead would hand an
  /// agent a human page it would then try to parse as JSON.
  func testHelpRefusesAMachineOutputModeRatherThanDroppingIt() {
    for argv in [
      ["--output", "json"],
      ["--output", "json", "--help"],
      ["--output", "json", "job", "--help"],
      ["--output", "json", "job", "status", "--help"],
      ["--output", "json", "flash", "execute", "--help"],
    ] {
      let error = failure(argv)
      XCTAssertEqual(error?.code, .invalidOption, argv.joined(separator: " "))
      XCTAssertTrue(
        error?.message.contains("commands --output json") == true,
        "the refusal must name the machine projection instead")
    }
  }

  func testHelpOnARetiredCommandExplainsItRatherThanRefusingIt() {
    guard case .leafHelp(let path, let leaf)? = success(["flash", "execute", "--help"]) else {
      return XCTFail("--help on a tombstone must render its help")
    }
    XCTAssertEqual(path, ["flash", "execute"])
    XCTAssertTrue(CLIHelpRenderer.leaf(path: path, leaf: leaf).contains("retired"))
  }

  func testVersionReportsEachIndependentlyVersionedContract() {
    guard case .version(let mode)? = success(["--version"]) else { return XCTFail("--version") }
    XCTAssertEqual(mode, .human)
    guard case .object(let fields) = CLIHelpRenderer.versionResult() else {
      return XCTFail("the version result must be an object")
    }
    for key in [
      "cliProductVersion", "commandRegistrySchemaVersion", "preferredControlProtocolVersion",
      "supportedControlProtocolExactVersions", "machineContractVersion", "resultSchemaVersion",
      "pageSchemaVersion", "eventSchemaVersion", "nextActionSchemaVersion",
      "errorRegistryVersion", "canonicalJsonVersion", "buildIdentity",
    ] {
      XCTAssertNotNil(fields[key], "§12 requires \(key) to be reported separately")
    }
    // A component this build cannot produce is `null`, never a version copied
    // out of the spec: `--version` describes this client, not the document.
    XCTAssertEqual(fields["pageSchemaVersion"], .null)
    XCTAssertEqual(fields["eventSchemaVersion"], .null)
    guard case .array(let supported)? = fields["supportedControlProtocolExactVersions"] else {
      return XCTFail("the supported set must be a list")
    }
    XCTAssertTrue(
      supported.contains(fields["preferredControlProtocolVersion"] ?? .null),
      "§12 requires the preferred version to be one of the supported ones")

    // Human mode lists the same set rather than a build banner.
    let human = CLIHelpRenderer.versionHuman()
    for name in ["command registry schema", "control protocol supported", "build identity"] {
      XCTAssertTrue(human.contains(name), "human --version must list \(name)")
    }
  }

  /// A build identity that somebody has to remember to bump is not one. This
  /// is the digest of the bytes that answered.
  func testTheBuildIdentityIsDerivedFromTheRunningBinary() throws {
    let identity = try XCTUnwrap(CLIBuildIdentity.current())
    XCTAssertTrue(identity.hasPrefix("sha256:"))
    XCTAssertEqual(identity.dropFirst("sha256:".count).count, 64)
    XCTAssertEqual(
      identity, CLIBuildIdentity.current(), "the same binary must hash the same way twice")
  }

  func testTheRegistryProjectionNamesEveryLeafAndItsKind() {
    guard case .object(let root) = CLIRegistryProjection.result(),
      case .array(let commands)? = root["commands"]
    else {
      return XCTFail("the projection must be an object with a commands array")
    }
    XCTAssertEqual(commands.count, CLICommandRegistry.allLeaves().count)
    var kinds: Set<String> = []
    for case .object(let command) in commands {
      guard case .string(let kind)? = command["kind"] else {
        return XCTFail("every projected command must declare its kind")
      }
      kinds.insert(kind)
      XCTAssertNotNil(command["command"])
      XCTAssertNotNil(command["path"])
    }
    XCTAssertEqual(kinds, ["executable", "tombstone", "refused"])
  }

  func testCompletionScriptsExistForEveryPublishedShellAndNameNoIdentity() throws {
    let leaf = try XCTUnwrap(CLICommandRegistry.rootLeaf("completion"))
    guard case .enumeration(let shells) = leaf.positionals[0].grammar else {
      return XCTFail("the shell argument must be a closed set")
    }
    for shell in shells {
      let script = try XCTUnwrap(
        CLICompletionScripts.script(for: shell), "no generator for \(shell)")
      XCTAssertTrue(script.contains("arkdeck"), "\(shell) script must complete arkdeck")
      // §10: dynamic identities are never written into a shell cache.
      for identity in ["--job ", "--target ", "--artifact ", "--resume-token "] {
        XCTAssertFalse(
          script.contains(identity + "'"),
          "\(shell) completion must not offer values for \(identity)")
      }
    }
  }

  // MARK: Tombstones and refusals

  func testARetiredCommandAnswersWithItsReplacementContract() {
    let error = failure(["flash", "execute"])
    XCTAssertEqual(error?.code, .commandRemoved)
    XCTAssertEqual(error?.exitCode, 64)
    // §12 fixes these key names: an agent branches on `lifecycleStatus` and
    // runs `replacementArgvPattern`.
    XCTAssertEqual(error?.details["lifecycleStatus"], .string("removed"))
    XCTAssertEqual(
      error?.details["replacementArgvPattern"],
      .string("arkdeck agent run --operation flash.full-restore@1 ..."))
    XCTAssertNotNil(error?.details["removalVersion"], "the field is required even when unknown")
  }

  /// The pattern form comes back the moment its leaf exists — the guard that
  /// refuses a replacement pointing at a missing command is what makes that
  /// safe to do automatically rather than from memory.
  func testTheRetiredPostflightNamesJobEvidenceNowThatItExists() {
    let error = failure(["flash", "postflight"])
    XCTAssertEqual(error?.code, .commandRemoved)
    XCTAssertEqual(
      error?.details["replacementArgvPattern"], .string("arkdeck job evidence --job <id>"))
  }

  /// `flash continue` is the example precisely because nothing replaces it:
  /// historical campaigns are decode-only, so there is no argv pattern to give
  /// and the reason has to carry the answer instead.
  func testARetiredCommandWithNoReplacementSaysSoRatherThanNamingOne() {
    let error = failure(["flash", "continue"])
    XCTAssertEqual(error?.code, .commandRemoved)
    XCTAssertEqual(error?.details["replacementArgvPattern"], .null)
    XCTAssertNotNil(error?.details["reason"])
  }

  /// A retired command keeps answering by name even when the caller still
  /// passes its retired flags: naming the flag would tell them nothing about
  /// the command being gone.
  func testARetiredCommandWithItsOldFlagsStillAnswersAsRemoved() {
    XCTAssertEqual(failure(["flash", "execute", "--request-file", "r.json"])?.code, .commandRemoved)
  }

  func testCapabilityAdministrationStaysRefusedWithZeroEffect() {
    for verb in ["draft", "install", "revoke"] {
      let error = failure(["capability", verb])
      XCTAssertEqual(error?.code, .invalidCommand, verb)
      XCTAssertTrue(error?.message.contains("Runtime-owned") == true, verb)
    }
  }

  // MARK: Machine envelope (§8.1, §8.2)

  func testTheRendererIsChosenBeforeTheParseSoArgvErrorsStayMachineReadable() {
    XCTAssertEqual(CLIArgumentParser.bootstrapOutputMode(["--output", "json", "bogus"]), .json)
    XCTAssertEqual(CLIArgumentParser.bootstrapOutputMode(["bogus", "--output", "jsonl"]), .jsonl)
    // Ambiguous or malformed: answer in human rather than emit a machine frame
    // the caller may not have asked for.
    XCTAssertEqual(CLIArgumentParser.bootstrapOutputMode(["--output"]), .human)
    XCTAssertEqual(CLIArgumentParser.bootstrapOutputMode(["--output", "toml"]), .human)
    XCTAssertEqual(
      CLIArgumentParser.bootstrapOutputMode(["--output", "json", "--output", "json"]), .human)
    XCTAssertEqual(CLIArgumentParser.bootstrapOutputMode([]), .human)
  }

  func testTheFailureEnvelopeCarriesTheRequiredFieldsAndNoResult() throws {
    let error = try XCTUnwrap(failure(["bogus"]))
    let envelope = CLIResultEnvelope.failure(
      command: error.command ?? CLIResultEnvelope.parsePhaseCommand,
      error: error, controlRequestID: "ctl-test")
    guard case .object(let fields) = envelope else { return XCTFail("envelope must be an object") }
    XCTAssertEqual(fields["schemaVersion"], .string("arkdeck.cli.result/1"))
    XCTAssertEqual(fields["command"], .string("registry.parse"))
    XCTAssertEqual(fields["ok"], .bool(false))
    XCTAssertNil(fields["result"], "a failure envelope must not carry a result")
    guard case .object(let meta)? = fields["meta"] else { return XCTFail("meta is required") }
    XCTAssertEqual(meta["controlRequestId"], .string("ctl-test"))
    guard case .object(let body)? = fields["error"] else { return XCTFail("error is required") }
    XCTAssertEqual(body["code"], .string("invalidCommand"))
    XCTAssertNotNil(body["message"])
  }

  func testTheSuccessEnvelopeCarriesNoErrorAndEndsInExactlyOneNewline() {
    let envelope = CLIResultEnvelope.success(
      command: "commands", result: .object([:]), controlRequestID: "ctl-test")
    guard case .object(let fields) = envelope else { return XCTFail("envelope must be an object") }
    XCTAssertEqual(fields["ok"], .bool(true))
    XCTAssertNil(fields["error"], "a success envelope must not carry an error")

    let rendered = CLIResultEnvelope.render(envelope)
    XCTAssertTrue(rendered.hasSuffix("}\n"))
    XCTAssertEqual(rendered.filter { $0 == "\n" }.count, 1, "machine mode emits one document")
    XCTAssertFalse(rendered.hasPrefix("\u{FEFF}"), "no BOM")
  }

  /// §9 keeps the exit status a property of the error code, not of the throw
  /// site, so the same reason cannot exit two ways.
  func testEveryErrorCodeHasOneExitStatus() {
    XCTAssertEqual(CLIErrorCode.invalidCommand.exitCode, 64)
    XCTAssertEqual(CLIErrorCode.invalidOption.exitCode, 64)
    XCTAssertEqual(CLIErrorCode.commandRemoved.exitCode, 64)
    XCTAssertEqual(CLIErrorCode.invalidInput.exitCode, 65)
    XCTAssertEqual(CLIErrorCode.internalError.exitCode, 70)
  }

  // MARK: Nested groups (§6.3)

  /// §6.3's platform surface is three tokens deep. A two-level tree would have
  /// forced `runtime hdc status` into a hyphenated leaf name that disagrees
  /// with the published command tree, so groups nest.
  func testAThreeTokenPathResolvesAndReportsItsOwnPathWhenIncomplete() {
    guard case .dispatch(let path, let leaf, _)? = success(["runtime", "hdc", "status"]) else {
      return XCTFail("a nested group must resolve to its leaf")
    }
    XCTAssertEqual(path, ["runtime", "hdc", "status"])
    XCTAssertEqual(leaf.canonicalCommand, "runtime.hdc.status")

    // An incomplete path is reported as the caller typed it, not as its last
    // token alone — `hdc needs a subcommand` names nothing a caller can find.
    let incomplete = failure(["runtime", "hdc"])
    XCTAssertEqual(incomplete?.code, .invalidCommand)
    XCTAssertTrue(incomplete?.message.contains("`runtime hdc`") == true, incomplete?.message ?? "")
    XCTAssertEqual(failure(["runtime"])?.code, .invalidCommand)
    XCTAssertEqual(failure(["runtime", "bogus"])?.code, .invalidCommand)
    XCTAssertEqual(failure(["runtime", "hdc", "bogus"])?.code, .invalidCommand)
  }

  func testHelpAndCompletionFollowTheNestedTree() throws {
    guard case .leafHelp(let path, _)? = success(["help", "runtime", "hdc", "status"]) else {
      return XCTFail("help must walk to a nested leaf")
    }
    XCTAssertEqual(path, ["runtime", "hdc", "status"])
    guard case .nodeHelp(let group)? = success(["help", "runtime", "hdc"]) else {
      return XCTFail("help must stop at a nested group")
    }
    XCTAssertEqual(group.token, "hdc")

    // The completion table is keyed by joined prefix, so it is depth-agnostic
    // by construction rather than by a hard-coded two levels.
    let keys = Set(CLICompletionScripts.table().map(\.key))
    XCTAssertTrue(keys.contains("runtime"))
    XCTAssertTrue(keys.contains("runtime hdc"))
    XCTAssertTrue(keys.contains("runtime hdc status"))
    let hdcRow = try XCTUnwrap(
      CLICompletionScripts.table().first { $0.key == "runtime hdc" })
    XCTAssertEqual(hdcRow.next, ["status"])
  }

  // MARK: Discovery and health leaves (§6.1, §13.2)

  /// These four daemon methods have existed since the control plane landed and
  /// had no caller-facing leaf, so an external Agent could not ask whether the
  /// Runtime was there, what was plugged in, or what a target was bound to.
  func testTheDaemonReadyDiscoverySurfaceIsReachable() {
    for argv in [
      ["runtime", "health"],
      ["runtime", "hdc", "status"],
      ["device", "candidates"],
      ["device", "candidates", "--use-warm-snapshot"],
      ["target", "list"],
      ["target", "show", "--target", "T-1"],
    ] {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` must dispatch")
      }
    }
    XCTAssertEqual(failure(["target", "show"])?.code, .invalidOption)
  }

  /// §7.1 separates a live observation from a durable binding, and §12 keeps
  /// the old spelling working as frozen legacy compatibility rather than
  /// silently repointing it.
  func testTheTargetSpellingIsCurrentWhileTheDeviceSpellingStaysLegacy() {
    let leaves = CLICommandRegistry.allLeaves()
    XCTAssertEqual(leaves.first { $0.path == ["target", "list"] }?.leaf.lifecycle, .current)
    XCTAssertEqual(leaves.first { $0.path == ["target", "show"] }?.leaf.lifecycle, .current)
    XCTAssertEqual(leaves.first { $0.path == ["device", "list"] }?.leaf.lifecycle, .legacy)
    XCTAssertEqual(leaves.first { $0.path == ["device", "show"] }?.leaf.lifecycle, .legacy)
    // `device candidates` is the target spelling (§6.1), so it is `current`
    // even though its 1.x response still lacks the snapshot generation the
    // target contract wants. Lifecycle answers "is there a newer spelling?";
    // whether a leaf meets the target contract is a coverage question, and
    // overloading one field with both would make `legacy` mean two things.
    XCTAssertEqual(
      leaves.first { $0.path == ["device", "candidates"] }?.leaf.lifecycle, .current)
  }

  // MARK: Evidence, result and bounded reads (§6.1, §7.6, §9)

  func testTheResultAndEvidenceSurfaceIsReachable() {
    for argv in [
      ["job", "evidence", "--job", "J-1"],
      ["job", "result", "--job", "J-1"],
      ["artifact", "quota"],
    ] {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` must dispatch")
      }
    }
    XCTAssertEqual(failure(["job", "result"])?.code, .invalidOption)
    XCTAssertEqual(failure(["job", "evidence"])?.code, .invalidOption)
  }

  /// §13.2: the daemon silently clamps `maxBytes` to 4 MiB, which rewrites the
  /// caller's intent into a short read they cannot tell from end-of-artifact.
  /// §7.6's target contract refuses, so the parser refuses and the clamp
  /// becomes unreachable from this CLI.
  func testAnOutOfRangeReadIsRefusedRatherThanSilentlyClamped() {
    XCTAssertEqual(
      failure(["artifact", "read", "--job", "J", "--artifact", "A", "--max-bytes", "4194305"])?
        .code,
      .invalidOption)
    XCTAssertEqual(
      failure(["artifact", "read", "--job", "J", "--artifact", "A", "--max-bytes", "0"])?.code,
      .invalidOption)
    XCTAssertNotNil(
      success(["artifact", "read", "--job", "J", "--artifact", "A", "--max-bytes", "4194304"]))
  }

  /// A byte offset starts at zero, so it cannot use the positive-integer
  /// grammar — that would refuse the first read of every artifact.
  func testAByteOffsetAcceptsZeroButStillRefusesPaddingAndSigns() {
    XCTAssertNotNil(
      success(["artifact", "read", "--job", "J", "--artifact", "A", "--offset", "0"]))
    for rejected in ["-1", "007", "+0", "", " 0"] {
      XCTAssertEqual(
        failure(["artifact", "read", "--job", "J", "--artifact", "A", "--offset", rejected])?
          .code,
        .invalidOption,
        "offset \(rejected.debugDescription) must be refused")
    }
    // An open-ended bound has to read as a lower bound: "must be 0" would say
    // the only accepted offset is zero.
    let message = failure(
      ["artifact", "read", "--job", "J", "--artifact", "A", "--offset", "-1"])?.message
    XCTAssertEqual(message?.contains("0 or greater"), true, message ?? "")
  }

  /// §8.1: raw is bytes and nothing else, so it cannot be combined with a mode
  /// that wraps them.
  func testRawBytesExcludeEveryMachineEnvelope() {
    for mode in [["--output", "json"], ["--json"]] {
      XCTAssertEqual(
        failure(["artifact", "read", "--job", "J", "--artifact", "A", "--raw"] + mode)?.code,
        .invalidOption)
    }
    XCTAssertNotNil(
      success(["artifact", "read", "--job", "J", "--artifact", "A", "--raw"]))
  }

  /// §9 keeps a failed verification as a result with a different exit status,
  /// not as an error that drops the evidence the caller needs to see.
  func testEvidenceIntegrityIsDetectedFromBlockersRatherThanFromAMessage() {
    XCTAssertNil(
      RuntimeCLI.evidenceIntegrityExit(.object(["blockers": .array([])])),
      "an empty blocker list is a verified projection")
    XCTAssertNil(RuntimeCLI.evidenceIntegrityExit(.object([:])))
    let blocked = RuntimeCLI.evidenceIntegrityExit(
      .object(["blockers": .array([.string("artifactVerification:digestMismatch")])]))
    XCTAssertEqual(blocked?.contains("digestMismatch"), true, blocked ?? "")
  }

  /// §8.1 allows exactly one document per machine invocation, and §8.2 makes
  /// `job result` and `operation validate` emit a result and *then* exit
  /// non-zero. The obvious way to write that emits an error envelope after the
  /// result, handing a parser two documents where it expects one — so the
  /// session tracks whether it has emitted and downgrades a later failure to
  /// its exit status and a stderr diagnostic.
  func testAFailureAfterAResultDoesNotBecomeASecondDocument() {
    let session = CLIRuntimeSession(
      client: AgentClient(socketPath: "/nonexistent"), command: "job.result",
      rendering: .envelope, controlRequestID: "ctl-test", lifecycle: .current)

    let beforeEmitting = session.fail(.outcomeUnknown, "unknown")
    XCTAssertFalse(
      beforeEmitting.suppressesMachineRendering,
      "a failure with no result before it is still a machine document")

    session.emit(.object([:]))
    let afterEmitting = session.fail(.outcomeUnknown, "unknown")
    XCTAssertTrue(afterEmitting.suppressesMachineRendering)
    // The code and the exit status survive: only the second frame is dropped.
    XCTAssertEqual(afterEmitting.code, .outcomeUnknown)
    XCTAssertEqual(afterEmitting.exitCode, 75)
  }

  /// The terminal set comes from `JobState.isTerminal`, which is the state
  /// machine's own answer. Re-deriving a list here is how `job result` would
  /// start disagreeing with the engine about whether a job is finished —
  /// `planned` is terminal for a plan-only job and reads like it is not.
  func testTerminalityComesFromTheStateMachineRatherThanALocalList() {
    XCTAssertTrue(JobState.planned.isTerminal)
    XCTAssertTrue(JobState.succeeded.isTerminal)
    XCTAssertTrue(JobState.recovered.isTerminal)
    XCTAssertTrue(JobState.failed.isTerminal)
    XCTAssertFalse(JobState.running.isTerminal)
    XCTAssertFalse(JobState.waitingForRecovery.isTerminal)
  }

  // MARK: Retryable identity and stable pages (§5.3, §7.3, CLI-REQ-008)

  /// §13.2: the flag form generated a fresh random identity per invocation, so
  /// a retried submit created a second job instead of returning the first —
  /// the one thing an unattended caller cannot afford to get wrong.
  func testTheFlagFormLetsACallerFixItsRequestIdentity() {
    guard case .dispatch? = success([
      "job", "submit", "--target", "T-1", "--operation", "observe.device@1",
      "--request-id", "run-7", "--idempotency-key", "run-7",
    ]) else {
      return XCTFail("a caller must be able to fix both identities")
    }
    guard case .dispatch? = success([
      "job", "plan", "--target", "T-1", "--operation", "observe.device@1",
      "--request-id", "run-7",
    ]) else {
      return XCTFail("plan takes the same identity flags")
    }
    // §5.3: the document form carries them itself, so the two are exclusive.
    for flag in [["--request-id", "r"], ["--idempotency-key", "k"]] {
      XCTAssertEqual(
        failure(["job", "submit", "--request-file", "r.json"] + flag)?.code, .invalidOption,
        flag.joined(separator: " "))
    }
  }

  func testTheCallerIsToldWhenAnIdentityWasGeneratedForIt() {
    XCTAssertTrue(
      RuntimeCLI.generatesItsOwnIdempotencyKey([
        "--target", "T-1", "--operation", "observe.device@1",
      ]))
    XCTAssertFalse(
      RuntimeCLI.generatesItsOwnIdempotencyKey(["--idempotency-key", "k"]))
    // A request document carries its own identity, so there is nothing to warn
    // about — warning there would tell a caller who did the right thing that
    // they did not.
    XCTAssertFalse(RuntimeCLI.generatesItsOwnIdempotencyKey(["--request-file", "r.json"]))
  }

  /// §13.2: the reply a script had to parse changed with the arguments it
  /// happened to pass — a bare array without flags, a page object with them.
  /// One parser cannot be written against two shapes.
  func testJobListPublishesOneShapeAndItsPageOptions() {
    for argv in [
      ["job", "list"],
      ["job", "list", "--page-size", "10"],
      ["job", "list", "--order", "newestFirst"],
      ["job", "list", "--include-current", "--include-timeline"],
      ["job", "list", "--cursor", "12", "--order", "oldestFirst"],
    ] {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` must dispatch")
      }
    }
    XCTAssertEqual(failure(["job", "list", "--order", "bogus"])?.code, .invalidOption)
    XCTAssertEqual(failure(["job", "list", "--order"])?.code, .invalidOption)
  }

  // MARK: Operation discovery (§6.1)

  func testTheOperationSurfaceCoversExampleAndValidate() {
    for argv in [
      ["operation", "list"],
      ["operation", "describe", "--operation", "observe.device@1"],
      ["operation", "example", "--operation", "observe.device@1"],
      ["operation", "validate", "--operation", "observe.device@1", "--inputs-file", "i.json"],
      ["operation", "validate", "--operation", "observe.device@1", "--inputs-file", "-"],
    ] {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` must dispatch")
      }
    }
    XCTAssertEqual(failure(["operation", "example"])?.code, .invalidOption)
    XCTAssertEqual(
      failure(["operation", "validate", "--operation", "observe.device@1"])?.code,
      .invalidOption)
  }

  // MARK: Flash observations (§6.2, §13.2)

  /// Five daemon methods §13.2 lists as ready with no CLI leaf. Four observe —
  /// a headless caller could previously discover that a flash was impossible
  /// only by attempting one — and `bind-loader` mutates, which is why it takes
  /// the revision it expects.
  func testTheFlashObservationSurfaceIsReachable() {
    let digest = String(repeating: "a", count: 64)
    for argv in [
      ["flash", "device-access"],
      ["flash", "bootloader-status"],
      ["flash", "prerequisites", "--target", "T-1", "--device-profile", "dayu200"],
      [
        "flash", "lane-preview", "--target", "T-1", "--device-profile", "dayu200",
        "--archive-sha256", digest,
      ],
      ["flash", "bind-loader", "--target", "T-1", "--expected-binding-revision", "3"],
    ] {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` must dispatch")
      }
    }
    // Each required option is required.
    XCTAssertEqual(failure(["flash", "prerequisites", "--target", "T-1"])?.code, .invalidOption)
    XCTAssertEqual(failure(["flash", "bind-loader", "--target", "T-1"])?.code, .invalidOption)
  }

  /// §11.3 fixes digests as lowercase hex. Accepting both cases would make one
  /// digest two tokens, and the daemon's own check is case-insensitive — so
  /// the narrower rule has to live here.
  func testAnArchiveDigestMustBeSixtyFourLowercaseHexDigits() {
    let base = ["flash", "lane-preview", "--target", "T-1", "--device-profile", "dayu200"]
    XCTAssertNotNil(success(base + ["--archive-sha256", String(repeating: "a", count: 64)]))
    for rejected in [
      String(repeating: "A", count: 64),
      String(repeating: "a", count: 63),
      String(repeating: "a", count: 65),
      String(repeating: "z", count: 64),
      "",
    ] {
      XCTAssertEqual(
        failure(base + ["--archive-sha256", rejected])?.code, .invalidOption,
        "digest \(rejected.prefix(4))… must be refused")
    }
  }

  /// §12 freezes the 1.x method tokens byte for byte. The kebab-case command
  /// name is a registry mapping, and the camelCase wire spelling must survive
  /// it — "unifying" the two is exactly what §12 forbids a port from doing.
  func testTheKebabCaseCommandDoesNotRenameTheCamelCaseWireMethod() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      source.contains("\"flash.lanePlanPreview\""),
      "the frozen 1.x wire token must still be what goes on the wire")
    let leaf = CLICommandRegistry.allLeaves().first { $0.path == ["flash", "lane-preview"] }
    XCTAssertEqual(leaf?.leaf.canonicalCommand, "flash.lane-preview")
  }

  /// The pattern form returns as soon as its leaf exists, which is what the
  /// resolve-to-a-real-leaf guard makes safe to do automatically.
  func testTheRetiredFlashPreviewNamesLanePreviewNowThatItExists() {
    let error = failure(["flash", "preview"])
    XCTAssertEqual(error?.code, .commandRemoved)
    XCTAssertEqual(
      error?.details["replacementArgvPattern"],
      .string("arkdeck flash lane-preview --target <id> ..."))
  }

  // MARK: The surface itself

  /// Every command the previous hand-written dispatcher accepted still parses.
  /// The registry replaced the parser, not the product.
  func testTheAcceptedSurfaceStillCoversEveryPreviouslyExecutableCommand() {
    let previouslyExecutable: [[String]] = [
      ["doctor"],
      ["operation", "list"], ["operation", "describe", "--operation", "observe.device@1"],
      ["device", "list"], ["device", "show"], ["device", "adopt", "--candidate", "K"],
      ["trace", "probe", "--target", "T-1"],
      ["job", "plan", "--request-file", "r.json"],
      ["job", "submit", "--target", "T-1", "--operation", "observe.device@1", "--wait"],
      ["job", "status", "--job", "J-1"], ["job", "list"],
      ["job", "run", "--job", "J-1"], ["job", "cancel", "--job", "J-1"],
      ["job", "reconcile", "--job", "J-1"],
      ["cleanup-debt", "list"],
      ["cleanup-debt", "continue", "--job", "J-1", "--remote-path", "/tmp/x"],
      ["agent", "run", "--operation", "observe.device@1"],
      ["agent", "resume", "--resume-token", "R-1"],
      ["capability", "list"], ["capability", "inspect", "--capability", "CAP-RT-1"],
      ["artifact", "list", "--job", "J-1"],
      ["artifact", "inspect", "--job", "J-1", "--artifact", "A-1"],
      ["artifact", "read", "--job", "J-1", "--artifact", "A-1", "--allow-sensitive"],
      ["artifact", "export", "--job", "J-1", "--artifact", "A-1", "--destination", "/tmp"],
      ["artifact", "import-hap", "--target", "T-1", "--file", "a.hap"],
      ["artifact", "import-workspace-patch", "--target", "T-1", "--file", "a.patch"],
      ["artifact", "import-flash-bundle", "--target", "T-1", "--file", "a.tar.gz"],
      ["artifact", "import-native-library", "--target", "T-1", "--file", "libx.so"],
      ["debug", "start", "--request-file", "r.json"],
      ["debug", "status", "--invocation", "I-1"],
      ["flash", "install-binding", "--rebind"],
      ["flash", "status", "--campaign-id", "E-1"], ["flash", "reconcile"],
      ["agentd", "status"], ["agentd", "restart", "--maximum-wait-seconds", "30"],
      ["agentd", "verify", "--job", "J-1"], ["agentd", "uninstall"],
      ["signing", "status"], ["signing", "normalize"], ["signing", "remove"],
    ]
    for argv in previouslyExecutable {
      guard case .dispatch? = success(argv) else {
        return XCTFail("`\(argv.joined(separator: " "))` no longer dispatches")
      }
    }
  }
}
