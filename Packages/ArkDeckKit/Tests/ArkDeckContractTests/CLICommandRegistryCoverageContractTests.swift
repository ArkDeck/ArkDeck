import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

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
      + source("Sources/ArkDeckCLI/CLIDeviceWait.swift")
      + source("Sources/ArkDeckCLI/CLIAgentExecutions.swift")
      + source("Sources/ArkDeckCLI/CLIJobEvents.swift")
      + source("Sources/ArkDeckCLI/CLIJobResources.swift")
      + source("Sources/ArkDeckCLI/CLIImports.swift")
      + source("Sources/ArkDeckCLI/CLIBootstrapBundles.swift")
      + source("Sources/ArkDeckCLI/CLIHDCControlActions.swift")
      + source("Sources/ArkDeckCLI/CLIBootstrapTools.swift")
      + source("Sources/ArkDeckCLI/CLIWorkspaceContinuation.swift")
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

  // MARK: Domain commands (§6.2)

  /// §6.2 requires a domain command to declare its exact Catalog mapping. A
  /// reference that does not resolve would be a command that looks published
  /// and submits nothing, and the compiler cannot see the difference because
  /// it is a string.
  func testEveryDeclaredCatalogMappingResolvesToAPublishedOperation() {
    var checked = 0
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      guard let reference = leaf.catalogOperation else { continue }
      checked += 1
      XCTAssertNotNil(
        RuntimeOperationCatalog.descriptor(reference: reference),
        "\(path.joined(separator: " ")) maps to `\(reference)`, which the Catalog does not "
          + "publish")
    }
    XCTAssertGreaterThan(checked, 20, "the scan found too few mappings to be trusted")
  }

  /// Which operations have a first-class name, pinned so that adding an
  /// operation is a decision rather than an oversight.
  ///
  /// §6.2 does not require every operation to have one — §18 is explicit that a
  /// generically reachable operation is complete without an alias — so this
  /// does not demand coverage. It demands that the *gap* stay deliberate: a new
  /// operation fails here until someone either names it or records why not.
  ///
  /// `flash.dayu200` is the standing exclusion, and not an oversight: §6.2 says
  /// the convenience layer must never generate it, because it is a legacy alias
  /// whose input schema differs from `flash.full-restore@1`. A caller that
  /// really wants it submits it explicitly through the generic surface and the
  /// published Runtime alias contract handles it — the CLI must not guess the
  /// field mapping on their behalf.
  func testTheSetOfOperationsWithoutAConvenienceNameIsDeliberate() {
    let declared = Set(
      CLICommandRegistry.allLeaves().compactMap { $0.leaf.catalogOperation })
    let published = Set(RuntimeOperationCatalog.operations.map(\.reference))
    XCTAssertEqual(
      declared.subtracting(published), [], "a mapping points at nothing published")
    XCTAssertEqual(
      published.subtracting(declared), ["flash.dayu200"],
      "an operation gained or lost a convenience name; name it or record why it has none")
  }

  /// §10: the operation's typed inputs come from `operation describe`, and a
  /// domain command must not carry a second copy of them. A hand-written
  /// `--x`/`--y` on `input tap` would be the copy that drifts the next time the
  /// descriptor changes, and nothing would notice.
  func testDomainCommandsCarryNoHandCopiedInputSchema() {
    let allowed: Set<String> = [
      "--target", "--inputs-file", "--capability", "--execution-id",
      "--output", "--json", "--control-request-id", "--socket",
    ]
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      guard leaf.catalogOperation != nil else { continue }
      let extra = leaf.options.map(\.name).filter { !allowed.contains($0) }.sorted()
      XCTAssertEqual(
        extra, [],
        "\(path.joined(separator: " ")) restates operation inputs as flags: "
          + extra.joined(separator: ", "))
    }
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

  /// The same rule as tombstones, extended to leaves that are merely
  /// superseded: a deprecation notice that names a command the build does not
  /// publish sends a caller from the warning straight into an
  /// `invalidCommand`. This is what makes it safe to add a replacement the
  /// moment its leaf lands, rather than from memory.
  func testEveryPublishedReplacementResolvesToALeaf() {
    let executablePaths = Set(
      CLICommandRegistry.allLeaves()
        .filter { if case .executable = $0.leaf.kind { return true } else { return false } }
        .map { $0.path.joined(separator: " ") })

    var checked = 0
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      guard let pattern = leaf.replacementArgvPattern else { continue }
      checked += 1
      let name = path.joined(separator: " ")
      XCTAssertTrue(pattern.hasPrefix("arkdeck "), "\(name): `\(pattern)` is not runnable")
      let target = pattern.dropFirst("arkdeck ".count)
        .split(separator: " ").map(String.init)
        .prefix { !$0.hasPrefix("-") && !$0.hasPrefix("<") }
        .joined(separator: " ")
      XCTAssertTrue(
        executablePaths.contains(target),
        "\(name) points at `\(target)`, which is not an executable leaf in this build")
    }
    XCTAssertGreaterThan(checked, 0, "no replacement was checked; the scan found nothing")
  }

  /// A superseded leaf has to say so, and a current one must not: a warning on
  /// a command that is the published spelling would train a caller to ignore
  /// warnings.
  func testOnlySupersededLeavesCarryALifecycleAndAReplacement() {
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      let name = path.joined(separator: " ")
      if leaf.replacementArgvPattern != nil {
        XCTAssertNotEqual(
          leaf.lifecycle, .current, "\(name) has a replacement but claims to be current")
      }
    }
    // The new spellings are the destination, so they carry neither.
    for path in [["recovery", "cleanup", "list"], ["recovery", "flash-invocation", "status"]] {
      let leaf = CLICommandRegistry.allLeaves().first { $0.path == path }?.leaf
      XCTAssertEqual(leaf?.lifecycle, .current, path.joined(separator: " "))
      XCTAssertNil(leaf?.replacementArgvPattern, path.joined(separator: " "))
    }
    // And the old ones point at them.
    let debugStatus = CLICommandRegistry.allLeaves().first { $0.path == ["debug", "status"] }
    XCTAssertEqual(
      debugStatus?.leaf.replacementArgvPattern,
      "arkdeck recovery flash-invocation status --invocation <id>")
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
