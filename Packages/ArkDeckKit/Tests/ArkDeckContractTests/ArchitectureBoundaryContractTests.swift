// Architecture boundary contract (docs/ArchitectureRules.md).
//
// These tests are structural fitness functions: they read Package.swift, the
// Xcode project and the source tree and fail when a dependency edge, an
// import, a target or a token crosses a boundary that the compiler alone
// cannot see.
//
// The shape they defend (CHG-2026-064, CHG-2026-074):
//
//   External agent decides -> Rust Runtime admits and executes -> Provider
//   operates -> Artifact proves
//
// Concretely:
//   - The Runtime is Rust. Swift carries no Runtime semantics: the Swift CLI
//     (TASK-XPA-018) and the Swift daemon, engine, storage, process, provider
//     and composition targets (TASK-XPA-017) are deleted, the manifest holds
//     exactly the targets listed below, and none may return under its name.
//   - What stays in ArkDeckKit is the App's side: ClientKit (the App's typed
//     client of the Rust daemon), Core (shared value contracts), and the
//     small libraries those tests and the App still link.
//   - There is no in-process decision plane and no model surface.
//
// When one of these tests fails, the fix is almost never to edit the test.
// Widening a matrix entry is an architecture decision and belongs in the same
// review as the code that needs it.

import Foundation
import XCTest

final class ArchitectureBoundaryContractTests: XCTestCase {

  // MARK: - Layer matrix (single source of truth for these tests)

  /// The ArkDeckKit library targets that remain, and the ArkDeck modules each
  /// may import. A target may import strictly fewer modules than listed.
  private static let allowedImports: [String: Set<String>] = [
    "ArkDeckCore": [],
    "ArkDeckClientKit": ["ArkDeckCore"],
    "ArkDeckRuntime": ["ArkDeckCore"],
    "ArkDeckTraceAdapter": [],
    "ArkDeckAgentClient": ["ArkDeckCore"],
    "ArkDeckBootstrap": ["ArkDeckCore"],
  ]

  /// Test-only executables the remaining tests and the App UI tests run.
  private static let fixtureTargets: Set<String> = ["ArkDeckFakeHDCFixture"]

  /// The package's test targets and the ArkDeckKit modules each may link.
  private static let testTargets: [String: Set<String>] = [
    "ArkDeckClientKitTests": ["ArkDeckClientKit", "ArkDeckCore"],
    "ArkDeckCoreTests": ["ArkDeckCore"],
    "ArkDeckTraceAdapterTests": ["ArkDeckTraceAdapter"],
    "ArkDeckContractTests": [
      "ArkDeckClientKit", "ArkDeckCore", "ArkDeckRuntime", "ArkDeckAgentClient",
      "ArkDeckBootstrap", "ArkDeckFakeHDCFixture",
    ],
  ]

  /// Deleted targets whose names and source directories must never return:
  /// the Swift CLI (TASK-XPA-018), the Swift daemon, engine, storage,
  /// process, provider, composition and launchd targets with their crash and
  /// soak fixtures (TASK-XPA-017), and the in-process decision plane
  /// (CHG-2026-064). Their recorded oracles live on as Rust replays.
  private static let deletedTargets: [(target: String, path: String)] = [
    ("ArkDeckCLI", "Sources/ArkDeckCLI"),
    ("ArkDeckAgentDaemon", "Sources/ArkDeckAgentDaemon"),
    ("ArkDeckAgentDaemonMain", "Sources/ArkDeckAgentDaemonMain"),
    ("ArkDeckWorkflows", "Sources/ArkDeckWorkflows"),
    ("ArkDeckAgentComposition", "Sources/ArkDeckWorkflows/AgentComposition"),
    ("ArkDeckStorage", "Sources/ArkDeckStorage"),
    ("ArkDeckProcess", "Sources/ArkDeckProcess"),
    ("ArkDeckOpenHarmony", "Sources/ArkDeckOpenHarmony"),
    ("ArkDeckLaunchAgent", "LaunchAgents/LaunchAgentService.swift"),
    ("ArkDeckJournalCrashFixture", "Tests/ArkDeckJournalCrashFixture"),
    ("ArkDeckEngineCrashFixture", "Tests/ArkDeckEngineCrashFixture"),
    ("ArkDeckRuntimeSoakFixture", "Tests/ArkDeckRuntimeSoakFixture"),
    ("ArkDeckRuntimePortFixture", "Tests/ArkDeckRuntimePortFixture"),
    ("ArkDeckFakeHapSignerFixture", "Tests/ArkDeckFakeHapSignerFixture"),
    ("ArkDeckHarness", "Sources/ArkDeckHarness"),
  ]

  /// Where each remaining library target's sources live.
  private static let targetRoots: [(target: String, path: String)] = [
    ("ArkDeckCore", "Sources/ArkDeckCore"),
    ("ArkDeckClientKit", "Sources/ArkDeckClientKit"),
    ("ArkDeckRuntime", "Sources/ArkDeckRuntime"),
    ("ArkDeckTraceAdapter", "Sources/ArkDeckTraceAdapter"),
    ("ArkDeckAgentClient", "Sources/ArkDeckAgentClient"),
    ("ArkDeckBootstrap", "Sources/ArkDeckBootstrap"),
  ]

  // MARK: - 1. The package holds no Swift Runtime

  /// The manifest declares exactly the remaining libraries, the one fixture
  /// and the test targets.
  func testThePackageDeclaresOnlyTheRemainingTargets() throws {
    let targets = try Self.parseTargets(manifest: manifestText())
    XCTAssertFalse(targets.isEmpty, "no targets parsed from Package.swift")
    let known = Set(Self.allowedImports.keys).union(Self.fixtureTargets)
      .union(Self.testTargets.keys)
    XCTAssertEqual(
      Set(targets.keys), known,
      "Package.swift's targets drifted; Swift carries no Runtime semantics (CHG-2026-074)")
    for (name, path) in Self.deletedTargets {
      XCTAssertNil(targets[name], "\(name) returned to Package.swift")
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: packageRoot().appending(path: path).path),
        "\(path) returned; it was deleted")
    }
    let manifest = try manifestText()
    XCTAssertFalse(
      manifest.contains(#".executable(name: "arkdeck","#),
      "the Rust arkdeck is the only CLI (TASK-XPA-018)")
    XCTAssertFalse(
      manifest.contains(#".executable(name: "arkdeck-agentd","#),
      "the Rust arkdeck-agentd is the only daemon (TASK-XPA-017)")
    XCTAssertFalse(
      manifest.contains("ArkDeck/ArkForge"),
      "ArkDeck consumes ArkForge through its Rust crates only (rust/Cargo.toml)")
  }

  /// The remaining libraries and tests keep their layer edges.
  func testRemainingTargetsLinkOnlyTheLayerMatrix() throws {
    let targets = try Self.parseTargets(manifest: manifestText())
    for (name, allowed) in Self.allowedImports {
      let dependencies = try XCTUnwrap(targets[name], "\(name) is missing from Package.swift")
      let arkdeck = dependencies.filter { $0.hasPrefix("ArkDeck") }
      XCTAssertEqual(
        arkdeck.subtracting(allowed), [],
        "\(name) declares forbidden dependencies; allowed: \(allowed.sorted())")
    }
    for (name, allowed) in Self.testTargets {
      let dependencies = try XCTUnwrap(targets[name], "\(name) is missing from Package.swift")
      let arkdeck = dependencies.filter { $0.hasPrefix("ArkDeck") }
      XCTAssertEqual(
        arkdeck.subtracting(allowed), [],
        "test target \(name) links \(arkdeck.subtracting(allowed).sorted()); tests of the "
          + "deleted Swift Runtime live on as Rust replays of their recorded fixtures")
    }
    for name in Self.fixtureTargets {
      let dependencies = try XCTUnwrap(targets[name], "\(name) is missing from Package.swift")
      XCTAssertEqual(dependencies.filter { $0.hasPrefix("ArkDeck") }, [])
    }
  }

  /// Every remaining source file's ArkDeck imports respect the matrix.
  func testSourceImportsRespectLayerMatrix() throws {
    var checkedFiles = 0
    for (target, path) in Self.targetRoots {
      let allowed = Self.allowedImports[target] ?? []
      for file in try swiftFiles(under: path) {
        checkedFiles += 1
        let violations = try arkdeckImports(of: file).subtracting(allowed).subtracting([target])
        XCTAssertTrue(
          violations.isEmpty,
          "\(relative(file)) imports \(violations.sorted()) but target \(target) may only "
            + "import \(allowed.sorted()) (docs/ArchitectureRules.md)")
      }
    }
    XCTAssertGreaterThan(checkedFiles, 100, "layout drifted: too few files scanned")
  }

  func testArkTraceEngineIsPinnedAndNeverCopiedIntoArkDeckKit() throws {
    let revision = "9172c9525f954ec397e0555d7d03cd4367f3efcf"
    let manifest = try manifestText()
    XCTAssertTrue(manifest.contains("https://github.com/ArkDeck/ArkTrace.git"))
    XCTAssertTrue(manifest.contains("revision: \"\(revision)\""))
    for directory in [
      "ArkDeckTraceCore", "ArkDeckTraceParser", "ArkDeckTraceStore",
      "ArkDeckTraceRuntime", "ArkDeckTraceAnalysis", "ArkDeckTraceRendering",
      "ArkDeckTraceAppSupport", "ArkDeckTraceCLI", "ArkDeckTraceCLIExecutable",
      "ArkDeckTraceCLIResourceFixtures", "ArkDeckTraceSignalShim", "ArkForgeIPC",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: packageRoot().appending(path: "Sources/\(directory)").path),
        "\(directory) is a forbidden copy of a pinned dependency")
    }
    let project = try String(
      contentsOf: repositoryRoot().appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertTrue(project.contains("XCRemoteSwiftPackageReference \"ArkTrace\""))
    XCTAssertTrue(project.contains("revision = \(revision);"))
    for resolvedPath in [
      "Packages/ArkDeckKit/Package.resolved",
      "ArkDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ] {
      let resolved = try String(
        contentsOf: repositoryRoot().appending(path: resolvedPath), encoding: .utf8)
      XCTAssertTrue(resolved.contains("\"identity\" : \"arktrace\""), resolvedPath)
      XCTAssertTrue(resolved.contains("\"revision\" : \"\(revision)\""), resolvedPath)
    }
  }

  // MARK: - 2. No decision plane, no model, no raw command

  func testNoModelSurfaceOrRawCommandAPIExists() throws {
    let modelTokens = [
      "HarnessAgentModelGateway", "HarnessAgentOpenAIGateway", "HarnessAgentLoop",
      "ARKDECK_HARNESS_MODEL_", "api.openai.com", "Authorization: Bearer", "chat/completions",
      "import ArkDeckHarness",
    ]
    let rawCommand =
      "public\\s+(func|init)[^{]*\\b(command|shellCommand|shellScript|commandLine|rawCommand)"
      + "\\s*:\\s*String"
    var scanned = 0
    for (_, path) in Self.targetRoots {
      for file in try swiftFiles(under: path) {
        scanned += 1
        let code = try codeWithoutComments(of: file)
        for token in modelTokens {
          XCTAssertFalse(
            code.contains(token),
            "\(relative(file)): names \(token); decisions come from external agents")
        }
        XCTAssertNil(
          code.range(of: rawCommand, options: .regularExpression),
          "\(relative(file)): public API accepts a raw command string")
      }
    }
    XCTAssertGreaterThan(scanned, 100, "the scan covered almost nothing")
  }

  /// The App admits only the standalone Rust daemon's identity; the retired
  /// façade's identifier may not return to its code requirement.
  func testTheAppAdmitsOnlyTheStandaloneDaemonIdentity() throws {
    let code = try codeWithoutComments(
      of: packageRoot().appending(path: "Sources/ArkDeckCore/AgentXPCContract.swift"))
    XCTAssertTrue(code.contains(#"identifier \"com.arkdeck.agentd\"""#))
    XCTAssertFalse(code.contains("com.arkdeck.agentd.facade"))
  }

  // MARK: - 3. The App stands on ClientKit

  /// The ArkDeckKit products each target of `ArkDeck.xcodeproj` may link, and
  /// so import. The App reaches the Rust Runtime through ClientKit alone
  /// (CHG-2026-074, TASK-XPA-019).
  private static let xcodeTargetProducts: [String: Set<String>] = [
    "ArkDeck": ["ArkDeckClientKit", "ArkDeckCore", "ArkDeckTraceAdapter"],
    "ArkDeckHDCUITests": ["ArkDeckClientKit", "ArkDeckCore"],
  ]

  private static let xcodeTargetSources: [String: String] = [
    "ArkDeck": "ArkDeckApp",
    "ArkDeckHDCUITests": "ArkDeckAppUITests",
  ]

  func testTheAppLinksAndImportsOnlyClientKitCoreAndTheTraceAdapter() throws {
    let project = try String(
      contentsOf: repositoryRoot().appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    let linked = try Self.arkDeckKitProductsByXcodeTarget(project: project)
    XCTAssertEqual(
      Set(linked.keys), Set(Self.xcodeTargetProducts.keys),
      "ArkDeck.xcodeproj's targets drifted from xcodeTargetProducts")
    for (target, products) in linked.sorted(by: { $0.key < $1.key }) {
      let allowed = Self.xcodeTargetProducts[target] ?? []
      XCTAssertTrue(
        products.isSubset(of: allowed),
        "Xcode target \(target) links \(products.subtracting(allowed).sorted()) but may link "
          + "only \(allowed.sorted()) from ArkDeckKit")
    }
    var checkedFiles = 0
    for (target, directory) in Self.xcodeTargetSources.sorted(by: { $0.key < $1.key }) {
      let allowed = Self.xcodeTargetProducts[target] ?? []
      for file in try repositorySwiftFiles(under: directory) {
        checkedFiles += 1
        let imports = try arkdeckImports(of: file)
        XCTAssertTrue(
          imports.isSubset(of: allowed),
          "\(file.lastPathComponent) imports \(imports.subtracting(allowed).sorted()), which "
            + "Xcode target \(target) does not link")
      }
    }
    XCTAssertGreaterThan(checkedFiles, 30, "App layout drifted: too few files scanned")
  }

  // MARK: - Helpers

  private func manifestText() throws -> String {
    try String(contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
  }

  /// `(name, declared dependency names)` for every target in the manifest: a
  /// balanced-parenthesis scan over the target blocks, then the quoted strings
  /// of their `dependencies: [...]` arrays.
  private static func parseTargets(manifest: String) throws -> [String: Set<String>] {
    var result: [String: Set<String>] = [:]
    for opener in [".target(", ".executableTarget(", ".testTarget("] {
      var search = manifest.startIndex
      while let start = manifest.range(of: opener, range: search..<manifest.endIndex) {
        var depth = 1
        var index = start.upperBound
        while index < manifest.endIndex, depth > 0 {
          switch manifest[index] {
          case "(": depth += 1
          case ")": depth -= 1
          default: break
          }
          index = manifest.index(after: index)
        }
        let block = String(manifest[start.upperBound..<index])
        search = index
        guard let name = quotedStrings(after: "name:", in: block, single: true).first else {
          continue
        }
        var dependencies: Set<String> = []
        if let range = block.range(of: "dependencies:") {
          let tail = String(block[range.upperBound...])
          if let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]"),
            open < close
          {
            dependencies = Set(quotedStrings(after: nil, in: String(tail[open...close]), single: false))
          }
        }
        result[name] = dependencies
      }
    }
    return result
  }

  private static func quotedStrings(after label: String?, in text: String, single: Bool)
    -> [String]
  {
    var scope = Substring(text)
    if let label {
      guard let range = scope.range(of: label) else { return [] }
      scope = scope[range.upperBound...]
    }
    var results: [String] = []
    while let open = scope.firstIndex(of: "\"") {
      let afterOpen = scope.index(after: open)
      guard let close = scope[afterOpen...].firstIndex(of: "\"") else { break }
      results.append(String(scope[afterOpen..<close]))
      if single { return results }
      scope = scope[scope.index(after: close)...]
    }
    return results
  }

  /// Each native target's ArkDeckKit package products, read from its
  /// `packageProductDependencies` and the project's product declarations.
  private static func arkDeckKitProductsByXcodeTarget(
    project: String
  ) throws -> [String: Set<String>] {
    let identifier = "[0-9A-Za-z]+"
    let localPackage = try NSRegularExpression(
      pattern: "(\(identifier)) /\\* XCLocalSwiftPackageReference \"Packages/ArkDeckKit\" \\*/ = \\{")
    let fullRange = NSRange(project.startIndex..., in: project)
    guard let packageMatch = localPackage.firstMatch(in: project, range: fullRange),
      let packageRange = Range(packageMatch.range(at: 1), in: project)
    else {
      XCTFail("ArkDeck.xcodeproj no longer references Packages/ArkDeckKit")
      return [:]
    }
    let packageID = String(project[packageRange])
    var productsByID: [String: String] = [:]
    let productDeclaration = try NSRegularExpression(
      pattern: "(\(identifier)) /\\*[^*]*\\*/ = \\{\\s*isa = XCSwiftPackageProductDependency;"
        + "\\s*package = (\(identifier)) /\\*[^*]*\\*/;\\s*productName = ([A-Za-z0-9_]+);")
    for match in productDeclaration.matches(in: project, range: fullRange) {
      guard let id = Range(match.range(at: 1), in: project),
        let package = Range(match.range(at: 2), in: project),
        let name = Range(match.range(at: 3), in: project),
        String(project[package]) == packageID
      else { continue }
      productsByID[String(project[id])] = String(project[name])
    }
    var result: [String: Set<String>] = [:]
    let nativeTarget = try NSRegularExpression(
      pattern: "= \\{\\s*isa = PBXNativeTarget;(.*?)\\n\\t\\t\\};",
      options: [.dotMatchesLineSeparators])
    let targetName = try NSRegularExpression(pattern: "\\n\\t\\t\\tname = ([^;]+);")
    let dependencies = try NSRegularExpression(
      pattern: "packageProductDependencies = \\((.*?)\\);", options: [.dotMatchesLineSeparators])
    let reference = try NSRegularExpression(pattern: "(\(identifier)) /\\*")
    for match in nativeTarget.matches(in: project, range: fullRange) {
      guard let bodyRange = Range(match.range(at: 1), in: project) else { continue }
      let body = String(project[bodyRange])
      let bodyRangeNS = NSRange(body.startIndex..., in: body)
      guard let nameMatch = targetName.firstMatch(in: body, range: bodyRangeNS),
        let nameRange = Range(nameMatch.range(at: 1), in: body)
      else {
        XCTFail("a PBXNativeTarget has no name")
        continue
      }
      var products: Set<String> = []
      if let list = dependencies.firstMatch(in: body, range: bodyRangeNS),
        let listRange = Range(list.range(at: 1), in: body)
      {
        let entries = String(body[listRange])
        for entry in reference.matches(
          in: entries, range: NSRange(entries.startIndex..., in: entries))
        {
          guard let idRange = Range(entry.range(at: 1), in: entries),
            let product = productsByID[String(entries[idRange])]
          else { continue }
          products.insert(product)
        }
      }
      result[String(body[nameRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))] =
        products
    }
    return result
  }

  private func packageRoot() -> URL {
    // …/Tests/ArkDeckContractTests/ArchitectureBoundaryContractTests.swift -> package root
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func repositoryRoot() -> URL {
    packageRoot().deletingLastPathComponent().deletingLastPathComponent()
  }

  private func relative(_ url: URL) -> String {
    let root = packageRoot().standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
  }

  private func swiftFiles(under relativePath: String) throws -> [URL] {
    try swiftFiles(in: packageRoot().appending(path: relativePath), named: relativePath)
  }

  private func repositorySwiftFiles(under directory: String) throws -> [URL] {
    try swiftFiles(
      in: repositoryRoot().appending(path: directory, directoryHint: .isDirectory),
      named: directory)
  }

  private func swiftFiles(in root: URL, named name: String) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else {
      XCTFail("cannot enumerate \(name)")
      return []
    }
    let files = enumerator.compactMap { entry -> URL? in
      guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
      return url.standardizedFileURL
    }
    XCTAssertFalse(files.isEmpty, "no Swift sources under \(name) — layout drifted")
    return files.sorted { $0.path < $1.path }
  }

  private func arkdeckImports(of file: URL) throws -> Set<String> {
    let code = try String(contentsOf: file, encoding: .utf8)
    let regex = try NSRegularExpression(
      pattern: "^\\s*(?:@testable\\s+|@_exported\\s+)?import\\s+([A-Za-z_][A-Za-z0-9_]*)",
      options: [.anchorsMatchLines])
    var result: Set<String> = []
    regex.enumerateMatches(in: code, range: NSRange(code.startIndex..., in: code)) { match, _, _ in
      guard let match, let range = Range(match.range(at: 1), in: code) else { return }
      let module = String(code[range])
      if module.hasPrefix("ArkDeck") { result.insert(module) }
    }
    return result
  }

  /// Strips line and block comments so the token scans judge code, not prose.
  /// String literals stay: a forbidden fragment inside one is what they catch.
  private func codeWithoutComments(of file: URL) throws -> String {
    let raw = try String(contentsOf: file, encoding: .utf8)
    var lines: [String] = []
    var inBlockComment = false
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      var text = String(line)
      if inBlockComment {
        guard let end = text.range(of: "*/") else { continue }
        text = String(text[end.upperBound...])
        inBlockComment = false
      }
      while let start = text.range(of: "/*") {
        if let end = text.range(of: "*/", range: start.upperBound..<text.endIndex) {
          text.removeSubrange(start.lowerBound..<end.upperBound)
        } else {
          text = String(text[..<start.lowerBound])
          inBlockComment = true
          break
        }
      }
      if let comment = text.range(of: "//") {
        text = String(text[..<comment.lowerBound])
      }
      lines.append(text)
    }
    return lines.joined(separator: "\n")
  }
}
