import Foundation
import XCTest

@testable import ArkDeckCLI

/// The options `agentd install` reads and the options it accepts must be one
/// set.
///
/// They were two. `validateAllowed` listed ten flags; the command then read
/// five more — the whole ArkForge lane configuration — which meant the lane
/// could never be installed:
///
/// ```
/// $ arkdeck agentd update --arkforge-profile …
/// arkdeck agentd: unsupported option --arkforge-profile
/// ```
///
/// from a build whose next twenty lines were written to parse exactly that.
/// Every part existed; the two lists had drifted, and nothing compared them.
/// That is the third time this shape has appeared in this lane — a reader with
/// no writer, a lane with no assembly, a flag with no permission — so this
/// compares them.
///
/// Source-level because the alternative is invoking the CLI once per flag and
/// asserting on a message, which tests the message rather than the agreement.
final class AgentdOptionCoverageContractTests: XCTestCase {

  private func runtimeCommandsSource() throws -> String {
    // From this file: Tests/ArkDeckContractTests → Packages/ArkDeckKit
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appending(path: "Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift"),
      encoding: .utf8)
  }

  func testEveryOptionTheInstallCommandReadsIsAlsoAllowed() throws {
    let source = try runtimeCommandsSource()

    // Only the install/update branch. Other subcommands in this file gate
    // their own options against their own lists, and folding theirs in would
    // make this assert something it does not mean.
    guard let branchStart = source.range(of: "case \"install\", \"update\":") else {
      return XCTFail("the install/update branch has been renamed; this guard no longer applies")
    }
    let afterStart = source[branchStart.upperBound...]
    let branchEnd = afterStart.range(of: "\n    case \"")?.lowerBound ?? afterStart.endIndex
    let branch = afterStart[afterStart.startIndex..<branchEnd]

    var read: Set<String> = []
    var search = branch
    while let start = search.range(of: "options.value(\"") {
      let rest = search[start.upperBound...]
      guard let end = rest.firstIndex(of: "\"") else { break }
      read.insert(String(rest[rest.startIndex..<end]))
      search = rest[end...]
    }

    XCTAssertFalse(read.isEmpty, "the scan found no options; it has stopped testing anything")

    let unlisted = read.subtracting(RuntimeCLI.agentdInstallOptions).sorted()
    XCTAssertEqual(
      unlisted, [],
      """
      these options are read by agentd install/update but rejected by \
      validateAllowed, so a caller cannot reach the code that parses them: \
      \(unlisted.joined(separator: ", "))
      """)
  }

  func testTheLaneFlagsAreAllPresent() throws {
    // Named individually as well, because the scan above would also pass if
    // both lists were emptied. These five are what install a lane and
    // authorize a campaign; a build that accepts none of them cannot flash.
    for flag in [
      "--arkforged", "--arkforged-sha256", "--arkforge-profile",
      "--arkforge-campaign",
    ] {
      XCTAssertTrue(
        RuntimeCLI.agentdInstallOptions.contains(flag),
        "\(flag) is not accepted; the ArkForge lane cannot be configured without it")
    }
  }
}
