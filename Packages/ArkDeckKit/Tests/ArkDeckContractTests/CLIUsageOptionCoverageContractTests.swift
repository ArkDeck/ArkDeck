import Foundation
import XCTest

@testable import ArkDeckCLI

/// The options the CLI accepts and the options it tells anyone about must be
/// one set.
///
/// They were two, by eleven flags. `--execution-id` was accepted by both
/// `agentd verify` and `agent run` and named in neither usage block, so the
/// only way to find it was to read the source — which a caller talking to an
/// installed binary cannot do. `--page-size`, `--cursor`, `--session`,
/// `--rebind` and `--arkforge-campaign` were in the same state.
///
/// This is the same shape `AgentdOptionCoverageContractTests` guards one layer
/// down: there, options that were read but not allowed; here, options that are
/// allowed but not published. Both are two hand-maintained lists with nothing
/// comparing them.
///
/// Source-level for the same reason that one is: the alternative is running
/// the binary once per flag and asserting on a message, which tests the
/// message rather than the agreement.
final class CLIUsageOptionCoverageContractTests: XCTestCase {

  /// Flags accepted only so they can be refused by name.
  ///
  /// CHG-2026-064 removed the in-process decision plane; its configuration
  /// flags stay in the accepted set so an operator's muscle memory gets a real
  /// answer instead of "unsupported option". Publishing them in usage would
  /// advertise configuration that no longer exists, so they are carved out
  /// here — by name, in a list a reviewer can see, rather than by a pattern
  /// that would also swallow a genuinely forgotten flag.
  private static let refusedByName: Set<String> = [
    "--sensitive-evidence", "--harness-model-provider", "--harness-model-name",
    "--harness-cli", "--harness-cli-timeout-seconds",
  ]

  private func source(_ relativePath: String) throws -> String {
    // From this file: Tests/ArkDeckContractTests → Packages/ArkDeckKit
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
  }

  private func optionTokens(in text: String) -> Set<String> {
    var found: Set<String> = []
    var search = Substring(text)
    while let start = search.range(of: "--", options: .literal) {
      let rest = search[start.lowerBound...]
      let token = rest.prefix { $0 == "-" || $0.isLowercase || $0.isNumber }
      if token.count > 2, !token.hasSuffix("-") { found.insert(String(token)) }
      search = search[start.upperBound...]
    }
    return found
  }

  func testEveryOptionTheCLIAcceptsIsNamedInUsage() throws {
    let commands = try source("Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift")
    let main = try source("Sources/ArkDeckCLI/ArkDeckCLIMain.swift")

    guard let usageStart = main.range(of: "let usage =") else {
      return XCTFail("the usage block has been renamed; this guard no longer applies")
    }
    let usage = String(main[usageStart.upperBound...])
    let code = String(main[main.startIndex..<usageStart.lowerBound]) + commands

    // Only string literals: an option the CLI accepts is always spelled as one
    // somewhere in the parsing code, and matching prose would let a comment
    // stand in for a flag. A literal may be a diagnostic that opens with the
    // flag it is about ("--cursor requires a value"), so take the leading flag
    // token rather than the whole literal.
    var accepted: Set<String> = []
    for line in code.split(separator: "\n") {
      var rest = Substring(line)
      while let open = rest.range(of: "\"--", options: .literal) {
        let body = rest[open.lowerBound...].dropFirst()
        let token = body.prefix { $0 == "-" || $0.isLowercase || $0.isNumber }
        if token.count > 2, !token.hasSuffix("-") { accepted.insert(String(token)) }
        rest = body
      }
    }
    XCTAssertFalse(accepted.isEmpty, "the scan found no options; it has stopped testing anything")

    let documented = optionTokens(in: usage)
    let undocumented = accepted.subtracting(documented)
      .subtracting(Self.refusedByName)
      .sorted()
    XCTAssertEqual(
      undocumented, [],
      """
      these options are accepted but appear in no usage line, so the only way \
      to discover them is to read the source: \(undocumented.joined(separator: ", "))
      """)
  }

  /// The carve-out has to stay a carve-out. If one of these ever becomes a
  /// working flag again it must be documented like any other, and the way that
  /// gets noticed is this list failing rather than quietly widening.
  func testTheRefusedFlagsAreStillRefusedRatherThanQuietlyAccepted() throws {
    let commands = try source("Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift")
    guard let refusalStart = commands.range(of: "for removed in [") else {
      return XCTFail("the removed-flag refusal loop is gone; the carve-out is now unexplained")
    }
    let refusalEnd = commands.range(of: "]", range: refusalStart.upperBound..<commands.endIndex)
    let block = commands[refusalStart.upperBound..<(refusalEnd?.lowerBound ?? commands.endIndex)]
    for flag in Self.refusedByName.sorted() {
      XCTAssertTrue(
        block.contains("\"\(flag)\""),
        "\(flag) is carved out of the usage requirement but is no longer refused by name; "
          + "either restore the refusal or document the flag")
    }
  }

  func testUsageMakesHeadlessRealDeviceValidationTheDefault() throws {
    let main = try source("Sources/ArkDeckCLI/ArkDeckCLIMain.swift")

    XCTAssertTrue(main.contains("Real-device validation defaults to `arkdeck agent run`"))
    XCTAssertTrue(main.contains("use the App only when the acceptance"))
    XCTAssertTrue(main.contains("UI acknowledgement is never a"))
    XCTAssertTrue(main.contains("prerequisite or authority for headless execution"))
    XCTAssertTrue(
      main.contains("for headless real-device validation use ")
        && main.contains("`arkdeck agent run --operation flash.full-restore@1`"),
      "the retired flash executor must direct operators to the headless product path first")
  }
}
