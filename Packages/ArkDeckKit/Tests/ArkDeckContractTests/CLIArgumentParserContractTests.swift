import Foundation
import XCTest

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

  func testOutputIsRefusedByLeavesThatDoNotYetRenderIt() {
    XCTAssertEqual(failure(["doctor", "--output", "json"])?.code, .invalidOption)
    XCTAssertEqual(failure(["job", "list", "--output", "json"])?.code, .invalidOption)
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

  func testARetiredCommandWithNoReplacementSaysSoRatherThanNamingOne() {
    let error = failure(["flash", "preview"])
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
