import Foundation
import XCTest

@testable import ArkDeckCLI

/// The options the CLI accepts and the options it describes must be one set.
///
/// They were two, by eleven flags, when the surface existed as a `switch` that
/// scanned argv, a usage literal, and nothing comparing them. The registry
/// removes that gap by construction: help, completion and the machine
/// projection are all rendered from the same description the parser enforces.
///
/// What can still drift is the other direction — a handler that reads a flag
/// the registry never declares (so the parser refuses it before the handler
/// runs, leaving dead code and a caller who cannot use a documented feature),
/// or a registry entry no handler consumes (a published option that does
/// nothing). Both are invisible to the compiler, so they are checked here.
///
/// Source-level for the same reason the previous guard was: the alternative is
/// running the binary once per flag and asserting on a message, which tests the
/// message rather than the agreement.
final class CLICommandRegistryCoverageContractTests: XCTestCase {

  /// Handled entirely by the parser, so no handler mentions it.
  private static let parserOwnedOptions: Set<String> = ["--output"]

  private func source(_ relativePath: String) throws -> String {
    // From this file: Tests/ArkDeckContractTests → Packages/ArkDeckKit
    let root = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
  }

  private func handlerSources() throws -> String {
    try source("Sources/ArkDeckCLI/ArkDeckCLIMain.swift")
      + source("Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift")
  }

  /// Option tokens that appear as string literals in code.
  ///
  /// A literal may be a diagnostic that opens with the flag it is about
  /// ("--cursor requires a value"), so take the leading flag token rather than
  /// the whole literal.
  private func literalOptionTokens(in code: String) -> Set<String> {
    var found: Set<String> = []
    for line in code.split(separator: "\n") {
      var rest = Substring(line)
      while let open = rest.range(of: "\"--", options: .literal) {
        let body = rest[open.lowerBound...].dropFirst()
        let token = body.prefix { $0 == "-" || $0.isLowercase || $0.isNumber }
        if token.count > 2, !token.hasSuffix("-") { found.insert(String(token)) }
        rest = body
      }
    }
    return found
  }

  private var registryOptionNames: Set<String> {
    var names: Set<String> = []
    for (_, leaf) in CLICommandRegistry.allLeaves() {
      for option in leaf.options { names.insert(option.name) }
    }
    return names
  }

  func testEveryOptionAHandlerReadsIsDeclaredInTheRegistry() throws {
    let read = literalOptionTokens(in: try handlerSources())
    XCTAssertFalse(read.isEmpty, "the scan found no options; it has stopped testing anything")

    let undeclared = read.subtracting(registryOptionNames).sorted()
    XCTAssertEqual(
      undeclared, [],
      """
      these options are read by a handler but declared on no registry leaf, so \
      the parser refuses them before the handler ever runs: \
      \(undeclared.joined(separator: ", "))
      """)
  }

  func testEveryOptionTheRegistryDeclaresIsReadBySomeHandler() throws {
    let read = literalOptionTokens(in: try handlerSources())
    let unread = registryOptionNames
      .subtracting(read)
      .subtracting(Self.parserOwnedOptions)
      .sorted()
    XCTAssertEqual(
      unread, [],
      """
      these options are published by the registry but no handler reads them, so \
      passing one has no effect: \(unread.joined(separator: ", "))
      """)
  }

  /// The carve-out has to stay a carve-out. If one of these ever becomes a
  /// working flag again it must be published like any other, and the way that
  /// gets noticed is this list failing rather than quietly widening.
  func testTheRefusedFlagsAreStillRefusedRatherThanQuietlyAccepted() throws {
    var refusedByName: Set<String> = []
    for (_, leaf) in CLICommandRegistry.allLeaves() {
      for option in leaf.options where option.stability == .refusedByName {
        refusedByName.insert(option.name)
      }
    }
    XCTAssertFalse(
      refusedByName.isEmpty,
      "no option is marked refusedByName; either the carve-out is gone or the mark was lost")

    for name in refusedByName {
      XCTAssertFalse(
        CLICommandRegistry.allLeaves().contains { _, leaf in
          leaf.options.contains { $0.name == name && $0.isPublished }
        },
        "\(name) is refused by name on one leaf and published on another")
    }

    let commands = try source("Sources/ArkDeckCLI/ArkDeckRuntimeCommands.swift")
    for flag in refusedByName.sorted() {
      XCTAssertTrue(
        commands.contains("\"\(flag)\""),
        "\(flag) is marked refusedByName but no handler answers it; "
          + "either restore the refusal or drop the declaration")
    }
  }

  func testRootHelpMakesHeadlessRealDeviceValidationTheDefault() {
    let help = CLIHelpRenderer.root()
    XCTAssertTrue(help.contains("Real-device validation defaults to `arkdeck agent run`"))
    XCTAssertTrue(help.contains("use the App only when"))
    XCTAssertTrue(help.contains("never a prerequisite or authority for headless execution"))
    XCTAssertTrue(
      help.contains("the CLI holds no HDC, executor or capability writer"),
      "root help must still say the CLI cannot build a device command itself")
  }

  /// The retired executor has to keep naming the headless replacement rather
  /// than the App: the App is the fallback for UI acceptance, not for running
  /// an operation.
  func testTheRetiredFlashExecutorNamesTheHeadlessReplacement() throws {
    let leaf = try XCTUnwrap(
      CLICommandRegistry.node("flash")?.leaves.first { $0.token == "execute" })
    guard case .tombstone(let tombstone) = leaf.kind else {
      return XCTFail("flash execute must stay a tombstone with an exact replacement")
    }
    XCTAssertEqual(
      tombstone.replacementArgvPattern,
      "arkdeck agent run --operation flash.full-restore@1 ...")
  }

  // MARK: Registry hygiene

  func testCanonicalCommandsAndPathsAreUnique() {
    let leaves = CLICommandRegistry.allLeaves()
    let commands = leaves.map(\.leaf.canonicalCommand)
    XCTAssertEqual(
      Set(commands).count, commands.count,
      "two leaves share a canonical command, so machine output cannot name one of them")
    let paths = leaves.map { $0.path.joined(separator: " ") }
    XCTAssertEqual(Set(paths).count, paths.count, "two leaves share a command path")
  }

  func testEveryLeafDeclaresAtLeastOneOutputModeAndNoDuplicateOptions() {
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      let name = path.joined(separator: " ")
      if case .executable = leaf.kind {
        XCTAssertFalse(leaf.outputModes.isEmpty, "\(name) declares no output mode")
      }
      let names = leaf.options.map(\.name)
      XCTAssertEqual(
        Set(names).count, names.count, "\(name) declares the same option twice")
    }
  }

  /// §5.2 scopes the local-endpoint alias to leaves that actually connect. A
  /// leaf that takes `--socket` without connecting would accept a value it
  /// then drops, which is the silent-ignore shape the registry exists to end.
  func testOnlyRuntimeClientLeavesTakeTheLocalEndpointAlias() {
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      let takesSocket = leaf.options.contains { $0.name == "--socket" }
      XCTAssertEqual(
        takesSocket, leaf.connectsToRuntime,
        "\(path.joined(separator: " ")) disagrees with itself about connecting to the Runtime")
      if takesSocket {
        let option = leaf.options.first { $0.name == "--socket" }
        XCTAssertEqual(
          option?.stability, .macosCompatibilityOnly,
          "--socket must stay marked so a native port inherits the refusal")
      }
    }
  }

  /// §12: a removed token's replacement is an argv pattern a caller can run.
  /// Naming a command this build does not publish would send an agent from a
  /// `commandRemoved` straight into an `invalidCommand`, so a pattern is only
  /// allowed once its leaf exists — otherwise the tombstone says there is no
  /// replacement yet and names the target in prose.
  func testANamedReplacementResolvesToALeafThatExists() {
    let executablePaths = Set(
      CLICommandRegistry.allLeaves()
        .filter { if case .executable = $0.leaf.kind { return true } else { return false } }
        .map { $0.path.joined(separator: " ") })

    for (path, leaf) in CLICommandRegistry.allLeaves() {
      guard case .tombstone(let tombstone) = leaf.kind,
        let pattern = tombstone.replacementArgvPattern
      else { continue }
      let name = path.joined(separator: " ")
      XCTAssertTrue(
        pattern.hasPrefix("arkdeck "),
        "\(name): a replacement must be a runnable argv pattern, got `\(pattern)`")
      let tokens = pattern.dropFirst("arkdeck ".count)
        .split(separator: " ").map(String.init)
        .prefix { !$0.hasPrefix("-") && !$0.hasPrefix("<") }
      let target = tokens.joined(separator: " ")
      XCTAssertTrue(
        executablePaths.contains(target),
        "\(name) names `\(target)`, which is not an executable leaf in this build")
    }
  }

  func testATombstoneWithoutAReplacementSaysWhy() {
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      guard case .tombstone(let tombstone) = leaf.kind,
        tombstone.replacementArgvPattern == nil
      else { continue }
      XCTAssertNotNil(
        tombstone.reason,
        "\(path.joined(separator: " ")) has no replacement and no reason, which leaves an "
          + "agent with nothing to act on")
    }
  }

  /// Tombstones name a replacement or say there is none; §5.1 forbids them
  /// from holding an executor, and a tombstone with options would suggest it
  /// still parses them.
  func testTombstonesCarryAReplacementContractAndNoOptions() {
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      switch leaf.kind {
      case .executable:
        continue
      case .tombstone, .refused:
        XCTAssertTrue(
          leaf.options.isEmpty && leaf.positionals.isEmpty,
          "\(path.joined(separator: " ")) is not executable but declares arguments")
        XCTAssertFalse(
          leaf.connectsToRuntime,
          "\(path.joined(separator: " ")) is not executable but claims a Runtime connection")
      }
    }
  }
}
