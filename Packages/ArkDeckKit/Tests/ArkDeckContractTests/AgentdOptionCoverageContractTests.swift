import Foundation
import XCTest

@testable import ArkDeckCLI

/// The service installer has two deliberately different option sets: the
/// target spelling consumes typed registry references, while `agentd` keeps
/// the bounded path-based compatibility reader.
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

  func testEveryOptionTheInstallCommandReadsBelongsToOnePublishedSurface() throws {
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

    let accepted = RuntimeCLI.agentdInstallOptions
      .union(RuntimeCLI.runtimeServiceInstallOptions)
    let unlisted = read.subtracting(accepted).sorted()
    XCTAssertEqual(
      unlisted, [],
      """
      these options are read by service install/update but absent from every \
      accepted surface, so a caller cannot reach the code that parses them: \
      \(unlisted.joined(separator: ", "))
      """)
  }

  func testTargetServiceUsesTypedResourcesAndLegacySpellingKeepsPaths() {
    for flag in ["--daemon", "--hdc"] {
      XCTAssertTrue(RuntimeCLI.agentdInstallOptions.contains(flag))
      XCTAssertFalse(RuntimeCLI.runtimeServiceInstallOptions.contains(flag))
    }
    for flag in ["--bundle", "--bundle-generation", "--tool", "--tool-generation"] {
      XCTAssertFalse(RuntimeCLI.agentdInstallOptions.contains(flag))
      XCTAssertTrue(RuntimeCLI.runtimeServiceInstallOptions.contains(flag))
    }

    let digest = String(repeating: "a", count: 64)
    let targetInstall = [
      "runtime", "service", "install",
      "--bundle", "bundle:sha256:\(digest)", "--bundle-generation", "1",
      "--tool", "tool:sha256:\(digest)", "--tool-generation", "1",
    ]
    let legacy = [
      "agentd", "install", "--daemon", "/tmp/ArkDeckAgent.app", "--hdc", "/tmp/hdc",
    ]
    if case .failure(let error) = CLIArgumentParser.parse(targetInstall) {
      XCTFail("typed target install was rejected: \(error)")
    }
    if case .failure(let error) = CLIArgumentParser.parse(legacy) {
      XCTFail("legacy path compatibility was rejected: \(error)")
    }
    for invalid in [
      targetInstall + ["--hdc", "/tmp/other"],
      targetInstall + ["--workspace-project", "/tmp/project"],
      legacy + ["--bundle", "bundle:sha256:\(digest)"],
    ] {
      if case .success = CLIArgumentParser.parse(invalid) {
        XCTFail("service surface accepted an option from the other lifecycle: \(invalid)")
      }
    }
  }

  func testTheLaneFlagsAreAllPresent() throws {
    // Named individually as well, because the scan above would also pass if
    // both lists were emptied. The bundle installs one release unit and the
    // campaign separately authorizes it. Legacy names remain recognized only
    // so callers receive the migration error rather than "unsupported".
    for flag in [
      "--arkforge-bundle", "--arkforge-campaign",
      "--arkforged", "--arkforged-sha256", "--arkforge-profile",
    ] {
      XCTAssertTrue(
        RuntimeCLI.agentdInstallOptions.contains(flag),
        "\(flag) is not accepted; the ArkForge lane cannot be configured without it")
    }
  }
}
