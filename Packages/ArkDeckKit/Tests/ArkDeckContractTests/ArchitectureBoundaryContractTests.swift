// Architecture boundary contract (docs/ArchitectureRules.md).
//
// These tests are structural fitness functions: they read Package.swift and
// the source tree and fail when a dependency edge, an import, a filename or
// a token crosses a layer boundary that the compiler alone cannot see (for
// example a carved-out target directory silently merging back into its
// parent target, or a shell-shaped public API appearing anywhere).
//
// The intended shape they defend:
//
//   AI decides -> Harness controls -> Runtime executes -> Provider operates
//   -> Artifact proves -> Evaluation judges
//
// Concretely:
//   - ArkDeckHarness (task control plane) cannot import ArkDeckProcess or
//     any provider module: the harness produces typed decisions, never
//     processes, shell, hdc or git.
//   - ArkDeckWorkflows (runtime control plane + providers) cannot import
//     ArkDeckHarness: the engine and providers must not understand the
//     plane that drives them.
//   - Only ArkDeckAgentComposition (harness<->runtime glue) and the
//     executable composition roots may see both planes at once.
//   - Storage and the artifact store know nothing about harness tasks.
//
// When one of these tests fails, the fix is almost never to edit the test:
// move the code to the layer that owns the concern, or descend the shared
// contract into ArkDeckCore/ArkDeckRuntime. Widening a matrix entry is an
// architecture decision and belongs in the same review as the code that
// needs it (see docs/ArchitectureRules.md).

import XCTest

final class ArchitectureBoundaryContractTests: XCTestCase {

  // MARK: - Layer matrix (single source of truth for these tests)

  /// Allowed `import` edges between ArkDeck modules, keyed by target name.
  /// A target may import strictly fewer modules than listed, never more.
  /// Executable composition roots are deliberately wide; library layers are
  /// deliberately narrow.
  private static let allowedImports: [String: Set<String>] = [
    "ArkDeckCore": [],
    "ArkDeckProcess": ["ArkDeckCore"],
    "ArkDeckRuntime": ["ArkDeckCore"],
    "ArkDeckOpenHarmony": ["ArkDeckCore", "ArkDeckProcess"],
    "ArkDeckStorage": ["ArkDeckCore"],
    "ArkDeckHarness": ["ArkDeckCore", "ArkDeckRuntime"],
    "ArkDeckWorkflows": [
      "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckOpenHarmony", "ArkDeckStorage",
    ],
    "ArkDeckAgentComposition": [
      "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckStorage", "ArkDeckHarness",
      "ArkDeckWorkflows", "ArkDeckAgentClient",
    ],
    "ArkDeckAgentClient": ["ArkDeckCore"],
    "ArkDeckLaunchAgent": [],
    "ArkDeckAgentDaemon": ["ArkDeckCore", "ArkDeckHarness", "ArkDeckStorage", "ArkDeckWorkflows"],
    "ArkDeckCLI": [
      "ArkDeckCore", "ArkDeckRuntime", "ArkDeckWorkflows", "ArkDeckAgentComposition",
      "ArkDeckAgentClient", "ArkDeckLaunchAgent",
    ],
    "ArkDeckAgentDaemonMain": [
      "ArkDeckAgentDaemon", "ArkDeckAgentComposition", "ArkDeckCore", "ArkDeckHarness",
      "ArkDeckRuntime", "ArkDeckStorage", "ArkDeckWorkflows",
    ],
    "ArkDeckEvolutionCandidate": [],
  ]

  /// Where each target's sources live, relative to the package root, plus
  /// subdirectories that belong to a different (carved-out) target and must
  /// be scanned under that target's name instead.
  private static let targetRoots: [(target: String, path: String, carveOuts: [String])] = [
    ("ArkDeckCore", "Sources/ArkDeckCore", []),
    ("ArkDeckProcess", "Sources/ArkDeckProcess", []),
    ("ArkDeckRuntime", "Sources/ArkDeckRuntime", []),
    ("ArkDeckOpenHarmony", "Sources/ArkDeckOpenHarmony", []),
    ("ArkDeckStorage", "Sources/ArkDeckStorage", []),
    ("ArkDeckHarness", "Sources/ArkDeckHarness", ["Candidate"]),
    ("ArkDeckEvolutionCandidate", "Sources/ArkDeckHarness/Candidate", []),
    ("ArkDeckWorkflows", "Sources/ArkDeckWorkflows", ["AgentComposition"]),
    ("ArkDeckAgentComposition", "Sources/ArkDeckWorkflows/AgentComposition", []),
    ("ArkDeckAgentClient", "Sources/ArkDeckAgentClient", []),
    ("ArkDeckLaunchAgent", "LaunchAgents", []),
    ("ArkDeckAgentDaemon", "Sources/ArkDeckAgentDaemon", []),
    ("ArkDeckCLI", "Sources/ArkDeckCLI", []),
    ("ArkDeckAgentDaemonMain", "Sources/ArkDeckAgentDaemonMain", []),
  ]

  // MARK: - 1. Package manifest edges

  /// Package.swift may only declare dependency edges the matrix allows. This
  /// is the compiler-facing half of the rule: removing an edge here is what
  /// makes a forbidden import a build error, so this test guards against the
  /// edge quietly returning in a later manifest edit.
  func testPackageManifestDependencyMatrix() throws {
    let manifest = try String(contentsOf: packageRoot().appendingPathComponent("Package.swift"))
    let targets = Self.parseTargets(manifest: manifest)
    XCTAssertFalse(targets.isEmpty, "no targets parsed from Package.swift")
    for (name, dependencies) in targets {
      guard let allowed = Self.allowedImports[name] else { continue }
      let arkdeckDependencies = dependencies.filter { $0.hasPrefix("ArkDeck") }
      let violations = arkdeckDependencies.subtracting(allowed)
      XCTAssertTrue(
        violations.isEmpty,
        "Package.swift target \(name) declares forbidden dependencies \(violations.sorted()); "
          + "allowed: \(allowed.sorted()) (docs/ArchitectureRules.md)")
    }
    // The two load-bearing absences, asserted directly so a failure names
    // the rule rather than a set difference.
    XCTAssertFalse(
      targets["ArkDeckWorkflows", default: []].contains("ArkDeckHarness"),
      "the runtime plane must not depend on the harness plane")
    XCTAssertFalse(
      targets["ArkDeckHarness", default: []].contains("ArkDeckProcess"),
      "the harness plane must not be able to spawn processes")
  }

  /// The carved-out target directories must stay excluded from their parent
  /// targets. If an `exclude:` entry disappears, SwiftPM folds the directory
  /// back into the parent target and the parent silently regains the very
  /// imports the split removed.
  func testCompositionCarveOutsStayExcluded() throws {
    let manifest = try String(contentsOf: packageRoot().appendingPathComponent("Package.swift"))
    XCTAssertTrue(
      manifest.contains("exclude: [\"AgentComposition\"]"),
      "ArkDeckWorkflows must exclude AgentComposition/ (it is the ArkDeckAgentComposition target)")
    XCTAssertTrue(
      manifest.contains("exclude: [\"Candidate\"]"),
      "ArkDeckHarness must exclude Candidate/ (it is the ArkDeckEvolutionCandidate target)")
  }

  // MARK: - 2. Source-level import matrix

  /// Every source file's ArkDeck imports must respect the layer matrix.
  /// Redundant with the manifest for straightforward cases, but this is the
  /// half that understands carved-out directories, and it names the exact
  /// file when it fails.
  func testSourceImportsRespectLayerMatrix() throws {
    var checkedFiles = 0
    for (target, path, carveOuts) in Self.targetRoots {
      let allowed = Self.allowedImports[target] ?? []
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        checkedFiles += 1
        let imports = try arkdeckImports(of: file)
        let violations = imports.subtracting(allowed).subtracting([target])
        XCTAssertTrue(
          violations.isEmpty,
          "\(relative(file)) imports \(violations.sorted()) but target \(target) may only "
            + "import \(allowed.sorted()) (docs/ArchitectureRules.md)")
      }
    }
    XCTAssertGreaterThan(checkedFiles, 100, "layout drifted: too few files scanned")
  }

  // MARK: - 3. Harness purity: no process, no shell, no device tooling

  /// The harness plane produces typed decisions. It must contain no process
  /// spawning, no shell strings, and no file whose name suggests an
  /// executor. The guard denylist in HarnessGuard.swift legitimately spells
  /// shell fragments, so this scans tokens, not words in comments.
  func testHarnessPlaneCannotReachProcessOrShell() throws {
    let forbiddenTokens = [
      "Process(", "posix_spawn", "NSTask", "popen(", "system(", "/bin/sh", "/bin/bash",
    ]
    // HarnessGuard.swift is the anti-injection denylist: it names shell
    // fragments in string literals precisely to refuse them.
    let denylistFiles: Set<String> = ["HarnessGuard.swift"]
    for file in try swiftFiles(under: "Sources/ArkDeckHarness", skippingSubdirectories: []) {
      let name = file.lastPathComponent
      for fragment in ["ProcessExecutor", "ShellRunner", "Shell", "HDC"] {
        XCTAssertFalse(
          name.contains(fragment),
          "\(relative(file)): file name suggests an executor; execution lives in providers")
      }
      guard !denylistFiles.contains(name) else { continue }
      let code = try codeWithoutComments(of: file)
      for token in forbiddenTokens {
        if token == "Process(" {
          // Word-boundary variant: `HarnessLocalAgentCLIRequest(` is a typed
          // request name, `Process(` is a spawn.
          let pattern = "(^|[^A-Za-z0-9_])Process\\("
          XCTAssertNil(
            code.range(of: pattern, options: .regularExpression),
            "\(relative(file)): Foundation.Process construction inside the harness plane")
        } else {
          XCTAssertFalse(
            code.contains(token),
            "\(relative(file)): forbidden token \(token) inside the harness plane")
        }
      }
    }
  }

  // MARK: - 4. No raw-command public API anywhere

  /// The typed-operation rule at the API level: no public function or
  /// initializer in any module takes a raw command string. Argv arrays exist
  /// only as typed provider/process inputs, never as `command: String`.
  func testNoPublicRawCommandStringParameters() throws {
    let pattern =
      "public\\s+(func|init)[^{]*\\b(command|shellCommand|shellScript|commandLine|rawCommand)"
      + "\\s*:\\s*String"
    for (_, path, carveOuts) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        let code = try codeWithoutComments(of: file)
        XCTAssertNil(
          code.range(of: pattern, options: .regularExpression),
          "\(relative(file)): public API accepts a raw command string")
      }
    }
  }

  // MARK: - 5. LLM surface isolation

  /// Model gateways, prompts and the local agent CLI transport belong to the
  /// harness plane and the composition target only. The runtime engine,
  /// providers, storage and clients must not name them.
  func testLLMSurfaceStaysInHarnessAndComposition() throws {
    let llmTokens = [
      "HarnessDecisionGateway", "HarnessLocalAgentCLITransport", "HarnessModelTransport",
      "HarnessVendorConfiguration", "LocalAgentCLI",
    ]
    let allowedPrefixes = [
      "Sources/ArkDeckHarness/",
      "Sources/ArkDeckWorkflows/AgentComposition/",
      "Sources/ArkDeckAgentDaemonMain/",
    ]
    for (_, path, carveOuts) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        let rel = relative(file)
        guard !allowedPrefixes.contains(where: { rel.hasPrefix($0) }) else { continue }
        let code = try codeWithoutComments(of: file)
        for token in llmTokens {
          XCTAssertFalse(
            code.contains(token),
            "\(rel): LLM surface token \(token) outside the harness/composition planes")
        }
      }
    }
  }

  // MARK: - 6. Git execution stays read-only and confined

  /// Exactly two files may reference the git executable, and neither may
  /// spell a history-mutating subcommand as a string literal. Evolution
  /// promotion produces a PR candidate document; nothing in the package can
  /// push, merge, commit or move a ref.
  func testGitExecutionConfinedAndReadOnly() throws {
    let allowedGitFiles: Set<String> = [
      "Sources/ArkDeckWorkflows/WorkspaceProvider/WorkspaceOperationsProvider.swift",
      "Sources/ArkDeckWorkflows/EvolutionCandidatePipeline.swift",
    ]
    let writeVerbs = [
      "push", "merge", "commit", "checkout", "clone", "rebase", "reset", "fetch", "pull",
      "cherry-pick", "switch", "restore", "worktree", "update-ref", "symbolic-ref",
      "filter-branch", "gc",
    ]
    for (_, path, carveOuts) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        let rel = relative(file)
        let code = try codeWithoutComments(of: file)
        if !allowedGitFiles.contains(rel) {
          XCTAssertFalse(
            code.contains("/usr/bin/git"),
            "\(rel): git executable referenced outside the two declared sites")
        } else {
          for verb in writeVerbs {
            XCTAssertNil(
              code.range(of: "\"\(verb)\"", options: .literal),
              "\(rel): git write verb \"\(verb)\" as a string literal; the git surface is "
                + "read-only (status/diff/stash create + read-only plumbing)")
          }
        }
      }
    }
  }

  // MARK: - 7. Storage and the artifact store are task-ignorant

  /// A single source of truth per fact: runtime storage and the artifact
  /// store never see harness task identity. The harness references jobs and
  /// artifacts by ID through its ports; nothing below stores an HTASK.
  func testStorageAndArtifactStoreAreTaskIgnorant() throws {
    var files = try swiftFiles(under: "Sources/ArkDeckStorage", skippingSubdirectories: [])
    files.append(
      packageRoot().appendingPathComponent("Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift"))
    for file in files {
      let code = try codeWithoutComments(of: file)
      for token in ["import ArkDeckHarness", "HarnessTask", "HTASK-"] {
        XCTAssertFalse(
          code.contains(token),
          "\(relative(file)): \(token) below the harness boundary — job and artifact stores "
            + "must stay task-ignorant")
      }
    }
  }

  // MARK: - Helpers

  /// Extracts `(name, declared dependency names)` for every target in the
  /// manifest. A balanced-parenthesis scan over `.target(`/`.executableTarget(`
  /// blocks, then quoted strings out of the `dependencies: [...]` array. The
  /// manifest is first-party and formatted by swift-format, so a text scan is
  /// dependable here; if parsing breaks, the emptiness assertion above fails
  /// loudly rather than passing vacuously.
  private static func parseTargets(manifest: String) -> [String: Set<String>] {
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
        guard let name = Self.quotedStrings(after: "name:", in: block, single: true).first else {
          continue
        }
        if let dependenciesRange = block.range(of: "dependencies:") {
          let tail = String(block[dependenciesRange.upperBound...])
          if let open = tail.firstIndex(of: "["), let close = tail.firstIndex(of: "]"),
            open < close
          {
            let list = String(tail[open...close])
            result[name] = Set(Self.quotedStrings(after: nil, in: list, single: false))
          } else {
            result[name] = []
          }
        } else {
          result[name] = []
        }
      }
    }
    return result
  }

  private static func quotedStrings(after label: String?, in text: String, single: Bool)
    -> [String]
  {
    var scope = text
    if let label {
      guard let range = scope.range(of: label) else { return [] }
      scope = String(scope[range.upperBound...])
    }
    var results: [String] = []
    var remainder = Substring(scope)
    while let open = remainder.firstIndex(of: "\"") {
      let afterOpen = remainder.index(after: open)
      guard let close = remainder[afterOpen...].firstIndex(of: "\"") else { break }
      results.append(String(remainder[afterOpen..<close]))
      if single { return results }
      remainder = remainder[remainder.index(after: close)...]
    }
    return results
  }

  private func packageRoot() -> URL {
    // …/Tests/ArkDeckContractTests/ArchitectureBoundaryContractTests.swift -> package root
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func relative(_ url: URL) -> String {
    let root = packageRoot().standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
  }

  private func swiftFiles(
    under relativePath: String, skippingSubdirectories: [String]
  ) throws -> [URL] {
    let root = packageRoot().appendingPathComponent(relativePath)
    let skipped = Set(skippingSubdirectories.map { root.appendingPathComponent($0).standardizedFileURL.path })
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil)
    else {
      XCTFail("cannot enumerate \(relativePath)")
      return []
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      let standardized = url.standardizedFileURL
      if skipped.contains(where: { standardized.path.hasPrefix($0 + "/") || standardized.path == $0 }) {
        continue
      }
      if standardized.pathExtension == "swift" {
        files.append(standardized)
      }
    }
    XCTAssertFalse(files.isEmpty, "no Swift sources under \(relativePath) — layout drifted")
    return files.sorted { $0.path < $1.path }
  }

  /// Every execution context the engine builds around a resolved input
  /// artifact must also carry the build version derived from it.
  ///
  /// This is a source-shape test on purpose. The fact was threaded into one of
  /// nine `ProviderExecutionContext` constructions by hand, and the eight that
  /// were missed did not surface in 1325 contract tests — they surfaced when a
  /// real flash plan was materialized through the engine and post-flash
  /// verification had nothing to compare against. Threading a fact into N call
  /// sites by hand fails at N > 1; what catches it is asking the source
  /// whether any site was left behind.
  /// The campaign lane must not resolve a firmware build by recognising its
  /// digest among the ones compiled into the product.
  ///
  /// This was the eleventh and last such pin, and the only one no test could
  /// have caught: the admitter takes a real `RockchipProductionAdmissionPort`
  /// with no seam to substitute, so nothing exercises it below a live
  /// campaign. It was found by running one — the flash was refused with
  /// `execute plan has no exact published profile` after preview, plan and
  /// engine admission had all gone green.
  ///
  /// A source-shape test is the honest guard here. It cannot prove the lane
  /// admits a new build; it can prove the lookup that refused one has not come
  /// back, which is what a future change would most plausibly reintroduce.
  func testTheCampaignLaneDoesNotSelectAProfileByArchiveDigest() throws {
    let admitter = packageRoot()
      .appendingPathComponent("Sources/ArkDeckWorkflows/EvolutionCampaignEngineLaneAdmitter.swift")
    let code = try String(contentsOf: admitter)
    XCTAssertFalse(
      code.contains("$0.archiveSHA256 == admission.plan.archiveSHA256"),
      "the campaign lane is matching the plan's archive against compiled-in builds again")
    XCTAssertFalse(
      code.contains("RockchipFlashProfile.profile(archiveSHA256:"),
      "the campaign lane is resolving a profile by archive digest again")
    // The archive the attempt carries is the confirmed plan's, and the
    // partition set is the board's. Both are what the operator confirmed.
    XCTAssertTrue(code.contains("archiveSHA256: admission.plan.archiveSHA256"), code)
    XCTAssertTrue(code.contains("partitionPlan: board.mappedPartitions"), code)
  }

  func testEveryArtifactResolvingExecutionContextCarriesTheDerivedBuildVersion() throws {
    let engine = packageRoot()
      .appendingPathComponent("Sources/ArkDeckWorkflows/RuntimeJobEngine.swift")
    let code = try String(contentsOf: engine)
    // Each construction runs to its closing paren before the next statement;
    // splitting on the constructor name is enough to isolate them.
    let constructions = code.components(separatedBy: "ProviderExecutionContext(").dropFirst()
    var checked = 0
    for construction in constructions {
      guard let end = construction.range(of: ")\n") else { continue }
      let body = String(construction[construction.startIndex..<end.upperBound])
      guard body.contains("resolvedInputArtifact:"),
        !body.contains("resolvedInputArtifact: nil")
      else { continue }
      checked += 1
      XCTAssertTrue(
        body.contains("expectedRuntimeBuildVersion:"),
        "an execution context resolves an input artifact but does not carry the build "
          + "version derived from it:\n\(body)")
    }
    XCTAssertGreaterThan(checked, 1, "no artifact-resolving contexts found — layout drifted")
  }

  private func arkdeckImports(of file: URL) throws -> Set<String> {
    let code = try String(contentsOf: file)
    var result: Set<String> = []
    let pattern = "^\\s*(?:@testable\\s+|@_exported\\s+)?import\\s+([A-Za-z_][A-Za-z0-9_]*)"
    let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    let range = NSRange(code.startIndex..., in: code)
    regex.enumerateMatches(in: code, range: range) { match, _, _ in
      guard let match, let moduleRange = Range(match.range(at: 1), in: code) else { return }
      let module = String(code[moduleRange])
      if module.hasPrefix("ArkDeck") {
        result.insert(module)
      }
    }
    return result
  }

  /// Strips line comments (and, coarsely, block comments) so that the token
  /// scans above judge code, not prose. String literals are left in place on
  /// purpose: a forbidden fragment inside a literal is exactly what several
  /// tests exist to catch.
  private func codeWithoutComments(of file: URL) throws -> String {
    let raw = try String(contentsOf: file)
    var lines: [String] = []
    var inBlockComment = false
    for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      var text = String(line)
      if inBlockComment {
        if let end = text.range(of: "*/") {
          text = String(text[end.upperBound...])
          inBlockComment = false
        } else {
          continue
        }
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
