// Architecture boundary contract (docs/ArchitectureRules.md).
//
// These tests are structural fitness functions: they read Package.swift and
// the source tree and fail when a dependency edge, an import, a filename or
// a token crosses a layer boundary that the compiler alone cannot see (for
// example a carved-out target directory silently merging back into its
// parent target, or a shell-shaped public API appearing anywhere).
//
// The intended shape they defend (CHG-2026-064):
//
//   External agent decides -> Runtime admits and executes -> Provider
//   operates -> Artifact proves
//
// Concretely:
//   - There is no in-process decision plane. No target named ArkDeckHarness
//     exists, nothing imports one, and the only way any caller — human, App
//     or external agent — reaches execution is a published operation
//     reference with typed inputs through admission.
//   - The chat composition may hold a model gateway for its conversational
//     front-end, but every side effect it produces still enters through the
//     same admission gate as everyone else's.
//   - Storage and the artifact store know nothing about task identity.
//
// When one of these tests fails, the fix is almost never to edit the test:
// move the code to the layer that owns the concern, or descend the shared
// contract into ArkDeckCore/ArkDeckRuntime. Widening a matrix entry is an
// architecture decision and belongs in the same review as the code that
// needs it (see docs/ArchitectureRules.md).

import Foundation
import XCTest

@testable import ArkDeckWorkflows

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
    "ArkDeckTraceAdapter": [],
    // ArkForgeProtocol and ArkForgeClient are external SDK products owned by
    // ArkForge. This matrix lists only ArkDeck-to-ArkDeck edges.
    "ArkDeckWorkflows": [
      "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckOpenHarmony", "ArkDeckStorage",
    ],
    "ArkDeckAgentComposition": [
      "ArkDeckCore", "ArkDeckProcess", "ArkDeckRuntime", "ArkDeckStorage",
      "ArkDeckWorkflows", "ArkDeckAgentClient",
    ],
    "ArkDeckAgentClient": ["ArkDeckCore"],
    "ArkDeckLaunchAgent": ["ArkDeckCore"],
    "ArkDeckAgentDaemon": ["ArkDeckCore", "ArkDeckStorage", "ArkDeckWorkflows"],
    "ArkDeckCLI": [
      "ArkDeckCore", "ArkDeckRuntime", "ArkDeckWorkflows", "ArkDeckAgentComposition",
      "ArkDeckAgentClient", "ArkDeckLaunchAgent",
    ],
    "ArkDeckAgentDaemonMain": [
      "ArkDeckAgentDaemon", "ArkDeckAgentComposition", "ArkDeckCore",
      "ArkDeckRuntime", "ArkDeckStorage", "ArkDeckWorkflows",
    ],
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
    ("ArkDeckTraceAdapter", "Sources/ArkDeckTraceAdapter", []),
    ("ArkDeckWorkflows", "Sources/ArkDeckWorkflows", ["AgentComposition"]),
    ("ArkDeckAgentComposition", "Sources/ArkDeckWorkflows/AgentComposition", []),
    ("ArkDeckAgentClient", "Sources/ArkDeckAgentClient", []),
    ("ArkDeckLaunchAgent", "LaunchAgents", ["ArkDeckCore"]),
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
    let manifest = try String(
      contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
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
    // The load-bearing absence, asserted directly so a failure names the
    // rule rather than a set difference: the in-process decision plane was
    // removed by CHG-2026-064 and no manifest edit may bring it back.
    XCTAssertNil(
      targets["ArkDeckHarness"],
      "no target named ArkDeckHarness may exist; the decision plane is external agents")
    for (name, dependencies) in targets {
      XCTAssertFalse(
        dependencies.contains("ArkDeckHarness"),
        "\(name) depends on ArkDeckHarness; the in-process decision plane does not exist")
    }
  }

  func testArkForgeCodecIsOwnedByThePinnedSDK() throws {
    let manifest = try String(
      contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("ArkForgeProtocol"))
    XCTAssertTrue(manifest.contains("ArkForgeClient"))
    XCTAssertTrue(manifest.contains("3f5b48cd7247f7e4304bb4f9d8a158f4feda5a92"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: packageRoot().appending(path: "Sources/ArkForgeIPC").path),
      "ArkDeck must not keep a second copy of ArkForge's wire codec")
  }

  func testArkTraceEngineIsPinnedAndNeverCopiedIntoArkDeckKit() throws {
    let revision = "91a21d1d419c5fec8c56c8b7b742002325045861"
    let manifest = try String(
      contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
    XCTAssertTrue(manifest.contains("https://github.com/ArkDeck/ArkTrace.git"))
    XCTAssertTrue(manifest.contains("revision: \"\(revision)\""))

    let forbiddenCopies = [
      "ArkDeckTraceCore", "ArkDeckTraceParser", "ArkDeckTraceStore",
      "ArkDeckTraceRuntime", "ArkDeckTraceAnalysis", "ArkDeckTraceRendering",
      "ArkDeckTraceAppSupport", "ArkDeckTraceCLI", "ArkDeckTraceCLIExecutable",
      "ArkDeckTraceCLIResourceFixtures", "ArkDeckTraceSignalShim",
    ]
    for directory in forbiddenCopies {
      let copyRoot = packageRoot().appending(path: "Sources/\(directory)")
      let firstEntry = FileManager.default.enumerator(
        at: copyRoot,
        includingPropertiesForKeys: nil
      )?.nextObject()
      XCTAssertNil(
        firstEntry,
        "\(directory) is a forbidden ArkTrace source copy; use the pinned package")
    }

    let repoRoot = packageRoot().deletingLastPathComponent().deletingLastPathComponent()
    let project = try String(
      contentsOf: repoRoot.appending(path: "ArkDeck.xcodeproj/project.pbxproj"),
      encoding: .utf8)
    XCTAssertTrue(project.contains("XCRemoteSwiftPackageReference \"ArkTrace\""))
    XCTAssertTrue(project.contains("revision = \(revision);"))

    let resolved = try String(
      contentsOf: packageRoot().appending(path: "Package.resolved"), encoding: .utf8)
    XCTAssertTrue(resolved.contains("\"identity\" : \"arktrace\""))
    XCTAssertTrue(resolved.contains("\"revision\" : \"\(revision)\""))

    let xcodeResolved = try String(
      contentsOf: repoRoot.appending(
        path: "ArkDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
      encoding: .utf8)
    XCTAssertTrue(xcodeResolved.contains("\"identity\" : \"arktrace\""))
    XCTAssertTrue(xcodeResolved.contains("\"revision\" : \"\(revision)\""))

    let recipe = "a2e47752e1353d627b442e607eed513564aa66a94c54f2660042383a0f6f3b20"
    let parserManifest = try String(
      contentsOf: packageRoot().appending(
        path: "ThirdParty/TraceStreamer/macx/manifest.json"),
      encoding: .utf8)
    XCTAssertTrue(parserManifest.contains("\"buildRecipeVersion\": \"\(recipe)\""))
    for removedPath in [
      "Scripts/build_trace_streamer.sh",
      "Scripts/verify_trace_streamer_lock.sh",
      "ThirdParty/TraceStreamer/source-lock.json",
      "ThirdParty/TraceStreamer/patches",
    ] {
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: packageRoot().appending(path: removedPath).path),
        "ArkTrace build source belongs only in the pinned dependency: \(removedPath)")
    }
  }

  /// The exact set of targets that claim strict memory safety.
  ///
  /// This setting is a claim that a target's unsafe surface has been read and
  /// annotated, and it is invisible when it goes missing: dropping it produces
  /// no diagnostic — that is the whole point of the diagnostic it was emitting.
  /// The compiler cannot tell anyone the setting used to be there, so the
  /// manifest is the only place the intent can be pinned.
  ///
  /// `ArkDeckProcess` owns every `posix_spawn`, raw file descriptor and PTY
  /// site in the package, which is why it is on the list. `ArkDeckCore` is
  /// value types and state machines with no unsafe constructs at all, so its
  /// entry costs nothing and guards nothing — it stays only because removing a
  /// safety setting is not this change's call to make.
  ///
  /// Adding a target here is not a formality: it will not compile until every
  /// unsafe expression in that target carries `unsafe`.
  func testStrictMemorySafetyCoversExactlyTheAuditedTargets() throws {
    let manifest = try String(
      contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
    var declaring: Set<String> = []
    // Each `.target(` block runs to the start of the next one.
    let blocks = manifest.components(separatedBy: ".target(").dropFirst()
    for block in blocks {
      guard let nameRange = block.range(of: #"name: ""#),
        let closing = block[nameRange.upperBound...].firstIndex(of: "\"")
      else { continue }
      let name = String(block[nameRange.upperBound..<closing])
      if block.contains(".strictMemorySafety()") || block.contains("traceSwiftSettings") {
        declaring.insert(name)
      }
    }
    XCTAssertEqual(
      declaring,
      [
        "ArkDeckCore", "ArkDeckProcess",
      ],
      "the set of targets declaring .strictMemorySafety() changed; a target that "
        + "drops it stops being checked with no diagnostic of any kind")
  }

  /// The carved-out target directories must stay excluded from their parent
  /// targets. If an `exclude:` entry disappears, SwiftPM folds the directory
  /// back into the parent target and the parent silently regains the very
  /// imports the split removed.
  func testCompositionCarveOutsStayExcluded() throws {
    let manifest = try String(
      contentsOf: packageRoot().appending(path: "Package.swift"), encoding: .utf8)
    XCTAssertTrue(
      manifest.contains("exclude: [\"AgentComposition\"]"),
      "ArkDeckWorkflows must exclude AgentComposition/ (it is the ArkDeckAgentComposition target)")
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

  // MARK: - 3. The in-process decision plane stays removed

  /// CHG-2026-064 removed the harness plane. Its directory must not exist,
  /// and no production source may import a module by its name — a returning
  /// plane should fail here by name, not as a matrix set difference.
  func testTheInProcessDecisionPlaneStaysRemoved() throws {
    var isDirectory: ObjCBool = false
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: packageRoot().appending(path: "Sources/ArkDeckHarness").path,
        isDirectory: &isDirectory),
      "Sources/ArkDeckHarness returned; the decision plane is external agents (CHG-2026-064)")
    for (_, path, _) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: []) {
        let code = try codeWithoutComments(of: file)
        XCTAssertFalse(
          code.contains("import ArkDeckHarness"),
          "\(relative(file)): imports the removed in-process decision plane")
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

  // MARK: - 5. No model surface anywhere

  /// ArkDeck holds no model. Not a confined one — none.
  ///
  /// This used to permit a model gateway inside the chat composition and the
  /// CLI, and assert only that it stayed there. `arkdeck agent chat` was the
  /// thing behind that carve-out, and deleting it lets the rule say what the
  /// architecture actually claims: decisions come from external agents, so no
  /// target names a model surface, reads a model credential, or addresses a
  /// vendor endpoint.
  ///
  /// The empty allowlist is the load-bearing part. While it had entries, "no
  /// in-process model" was a convention two directories were exempt from; with
  /// none, it is a property of the tree.
  func testNoModelSurfaceExistsAnywhere() throws {
    let modelTokens = [
      "HarnessAgentModelGateway", "HarnessAgentOpenAIGateway", "HarnessAgentLoop",
      "ARKDECK_HARNESS_MODEL_",
      // A gateway that returned under another name would still need these.
      "api.openai.com", "Authorization: Bearer", "chat/completions",
    ]
    let allowedPrefixes: [String] = []
    XCTAssertTrue(
      allowedPrefixes.isEmpty,
      "a carve-out here turns the absence of an in-process model back into a convention")
    var scanned = 0
    for (_, path, carveOuts) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        let rel = relative(file)
        guard !allowedPrefixes.contains(where: { rel.hasPrefix($0) }) else { continue }
        scanned += 1
        let code = try codeWithoutComments(of: file)
        for token in modelTokens {
          XCTAssertFalse(
            code.contains(token),
            "\(rel): names a model surface (\(token)); decisions come from external agents")
        }
      }
    }
    XCTAssertGreaterThan(scanned, 100, "the scan covered almost nothing")
  }

  /// The chat composition is gone by name, so a file cannot quietly return
  /// under it.
  func testTheChatCompositionStaysDeleted() throws {
    for name in [
      "AgentChatApplication.swift", "AgentChatCLI.swift", "HarnessAgentLoop.swift",
      "HarnessAgentOpenAIGateway.swift", "NativeAgentChatRuntimeTools.swift",
    ] {
      for directory in ["Sources/ArkDeckWorkflows/AgentComposition", "Sources/ArkDeckCLI"] {
        XCTAssertFalse(
          FileManager.default.fileExists(
            atPath: packageRoot().appending(path: "\(directory)/\(name)").path),
          "\(directory)/\(name) returned; ArkDeck runs no conversation of its own")
      }
    }
  }

  // MARK: - 6. Git execution stays read-only and confined

  /// One file may reference the git executable, and it may not spell a
  /// history-mutating subcommand as a string literal. Evolution promotion
  /// produces a PR candidate document; nothing in the package can push, merge,
  /// commit or move a ref.
  ///
  /// The allowlist is checked as an exact set, not as an upper bound. Written
  /// as a one-way "nothing outside this list" rule it silently widened when
  /// `EvolutionCandidatePipeline.swift` was deleted with the retired campaign
  /// stack: the entry stayed, so any future file recreated at that exact path
  /// would have inherited a reviewed git grant without review. A grant nothing
  /// uses has to fail here so it gets revoked rather than lying in wait.
  func testGitExecutionConfinedAndReadOnly() throws {
    let allowedGitFiles: Set<String> = [
      "Sources/ArkDeckWorkflows/WorkspaceProvider/WorkspaceOperationsProvider.swift"
    ]
    let writeVerbs = [
      "push", "merge", "commit", "checkout", "clone", "rebase", "reset", "fetch", "pull",
      "cherry-pick", "switch", "restore", "worktree", "update-ref", "symbolic-ref",
      "filter-branch", "gc",
    ]
    // A declared path outside every scanned root would never be observed
    // below, so the set comparison alone could not tell "revoked" from
    // "unscanned".
    for declared in allowedGitFiles.sorted() {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: packageRoot().appending(path: declared).path),
        "\(declared): declared as a git execution site but no such file exists; "
          + "remove the entry (docs/ArchitectureRules.md §4)")
    }

    var observedGitFiles: Set<String> = []
    for (_, path, carveOuts) in Self.targetRoots {
      for file in try swiftFiles(under: path, skippingSubdirectories: carveOuts) {
        let rel = relative(file)
        let code = try codeWithoutComments(of: file)
        guard code.contains("/usr/bin/git") else { continue }
        observedGitFiles.insert(rel)
        for verb in writeVerbs {
          XCTAssertNil(
            code.range(of: "\"\(verb)\"", options: .literal),
            "\(rel): git write verb \"\(verb)\" as a string literal; the git surface is "
              + "read-only (status/diff/stash create + read-only plumbing)")
        }
      }
    }
    XCTAssertEqual(
      observedGitFiles, allowedGitFiles,
      "the git execution sites and the declared allowlist must match exactly: "
        + "unlisted \(observedGitFiles.subtracting(allowedGitFiles).sorted()) reference the "
        + "git executable without a reviewed grant, and listed "
        + "\(allowedGitFiles.subtracting(observedGitFiles).sorted()) no longer use it and must "
        + "be removed rather than left standing")
  }

  // MARK: - 7. Storage and the artifact store are task-ignorant

  /// A single source of truth per fact: runtime storage and the artifact
  /// store never see harness task identity. The harness references jobs and
  /// artifacts by ID through its ports; nothing below stores an HTASK.
  func testStorageAndArtifactStoreAreTaskIgnorant() throws {
    var files = try swiftFiles(under: "Sources/ArkDeckStorage", skippingSubdirectories: [])
    files.append(
      packageRoot().appending(path: "Sources/ArkDeckWorkflows/Artifacts/RuntimeArtifactStore.swift")
    )
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
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testArkForgeFullRestoreConsumersUseTheCanonicalIdentityPolicy() throws {
    let sourceRoot = packageRoot().appending(path: "Sources")
    let allowedAliasFiles: Set<String> = [
      "ArkDeckCore/ArkForgeFlashOperation.swift",
      "ArkDeckCore/RuntimeOperationCatalogGenerated.swift",
      "ArkDeckWorkflows/RuntimeHistoryApplicationFacade.swift",
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceRoot, includingPropertiesForKeys: nil)
    else { return XCTFail("cannot enumerate ArkDeckKit sources") }
    var aliasFiles: Set<String> = []
    var obsoleteAdapterFiles: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      let relative = String(url.path.dropFirst(sourceRoot.path.count + 1))
      if source.contains("flash.dayu200") { aliasFiles.insert(relative) }
      if source.contains("RockchipFlashProviderAdapter") {
        obsoleteAdapterFiles.append(relative)
      }
    }
    XCTAssertEqual(aliasFiles, allowedAliasFiles)
    XCTAssertEqual(obsoleteAdapterFiles, [])

    let flashFacade = try String(
      contentsOf: sourceRoot.appending(
        path: "ArkDeckWorkflows/FlashApplicationFacade.swift"),
      encoding: .utf8)
    XCTAssertTrue(flashFacade.contains("ArkForgeFlashOperation.canonicalReference"))
    XCTAssertFalse(flashFacade.contains("flash.dayu200"))
    let progressStart = try XCTUnwrap(
      flashFacade.range(of: "public enum FlashLiveProgressProjector"))
    let progressTail = flashFacade[progressStart.lowerBound...]
    let progressEnd = try XCTUnwrap(
      progressTail.range(of: "enum FlashJobStatusResponseDecoding"))
    let progressSource = String(progressTail[..<progressEnd.lowerBound])
    for legacyStepID in [
      "flash-partitions", "verify-flash-readback", "rebind-and-verify-build",
    ] {
      XCTAssertFalse(
        progressSource.contains(legacyStepID),
        "typed Flash progress must derive phases from catalog step kinds")
    }

    let repoRoot = packageRoot().deletingLastPathComponent().deletingLastPathComponent()
    for name in ["FlashWorkspaceView.swift", "FlashRuntimeActivityView.swift"] {
      let source = try String(
        contentsOf: repoRoot.appending(path: "ArkDeckApp/Features/Flash/\(name)"),
        encoding: .utf8)
      XCTAssertTrue(source.contains("ArkForgeFlashOperation.containsDurableRecordReference"))
      XCTAssertFalse(source.contains("flash.dayu200"), "\(name) must not select only the old alias")
    }
    let manualDriver = try String(
      contentsOf: repoRoot.appending(path: "scripts/manual_ui_flash/manual_ui_flash.swift"),
      encoding: .utf8)
    XCTAssertTrue(manualDriver.contains("flash.full-restore"))
    XCTAssertFalse(manualDriver.contains("flash.dayu200"))
    XCTAssertTrue(manualDriver.contains("\"job.list-page\", \"job.plan\", \"job.status\""))
    XCTAssertTrue(manualDriver.contains("params.count == 1"))
    XCTAssertFalse(manualDriver.contains("waitForPresence(\"open-panel\""))
    XCTAssertFalse(manualDriver.contains("waitForAbsence(\"open-panel\""))
    XCTAssertTrue(manualDriver.contains("try openGoToFolder(timeout: timeout)"))
    XCTAssertTrue(
      manualDriver.contains("com.apple.appkit.xpc.openAndSavePanelService"))
    XCTAssertTrue(
      manualDriver.contains("try keyForExactApplicationOwnedFilePanel("))
    XCTAssertTrue(
      manualDriver.contains(
        "try pressExactApplicationOwnedFilePanel(\"OKButton\", timeout: timeout)"))
    XCTAssertTrue(manualDriver.contains("guard !runningApplication.isTerminated"))
    XCTAssertTrue(
      manualDriver.contains(
        "let panel = elementAttribute(okButton, kAXWindowAttribute as CFString)"))
    XCTAssertTrue(manualDriver.contains("isSameExactApplicationWindow(panel, requiredWindow)"))
    XCTAssertTrue(
      manualDriver.contains(
        "let raised = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)"))
    XCTAssertTrue(
      manualDriver.contains(
        "runningApplication.activate(options: [.activateAllWindows])"))
    XCTAssertTrue(
      manualDriver.contains(
        "elementAttribute(application, kAXFocusedWindowAttribute as CFString)"))
    XCTAssertTrue(manualDriver.contains("isSameExactApplicationWindow(panel, focusedWindow)"))
    XCTAssertTrue(
      manualDriver.contains(
        "lhsPID == runningApplication.processIdentifier"))
    XCTAssertTrue(
      manualDriver.contains(
        "an unrelated application remained frontmost; no file-panel input was dispatched"))
    XCTAssertTrue(
      manualDriver.contains(
        "url.lastPathComponent, identifier: \"flash.image.value\", timeout: max(timeout, 30)"))
    XCTAssertTrue(
      manualDriver.contains(
        "element(displayingNavigationFallback: fallbackStrings)"))
    XCTAssertTrue(manualDriver.contains("kAXRowRole as String"))
    XCTAssertTrue(
      manualDriver.contains(
        "expected.contains(where: { value == $0 || value.contains($0) })"))
  }

  private func relative(_ url: URL) -> String {
    let root = packageRoot().standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
  }

  private func swiftFiles(
    under relativePath: String, skippingSubdirectories: [String]
  ) throws -> [URL] {
    let root = packageRoot().appending(path: relativePath)
    let skipped = Set(
      skippingSubdirectories.map { root.appending(path: $0).standardizedFileURL.path })
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
      if skipped.contains(where: {
        standardized.path.hasPrefix($0 + "/") || standardized.path == $0
      }) {
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
  func testEveryArtifactResolvingExecutionContextCarriesTheDerivedBuildVersion() throws {
    let engine = packageRoot()
      .appending(path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift")
    let code = try String(contentsOf: engine, encoding: .utf8)
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
    let code = try String(contentsOf: file, encoding: .utf8)
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
    let raw = try String(contentsOf: file, encoding: .utf8)
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
  // MARK: - 8. The runtime engine gains no new per-operation knowledge

  /// The engine names fourteen specific published operations, and each naming
  /// is catalog or provider knowledge that migrated into the generic kernel:
  /// mutation/readback pairings, evidence eligibility, per-operation
  /// compensation, per-operation input handling. That is why publishing a new
  /// operation currently costs an edit to the execution kernel.
  ///
  /// Refactoring it out is frozen — PRODUCT-LOOP §12 and §20 bar large module
  /// restructuring and this meets none of §12's exceptions — so this stops the
  /// bleeding rather than draining it. The set may shrink as each fact moves
  /// to the Catalog or a provider; it may not grow.
  ///
  /// Compared as an exact set in both directions. An upper-bound-only rule is
  /// precisely how the git execution allowlist quietly widened: one of its two
  /// declared files was deleted, the entry stayed, and nothing failed.
  ///
  /// Scope is this one file on purpose. A provider naming the operations it
  /// implements is doing its job; the kernel doing it is the layering problem,
  /// and the kernel is here.
  private static let engineDeclaredOperations: Set<String> = [
    "analyzer.analyze-trace@1",
    "analyzer.extract-crash-signature@1",
    "analyzer.summarize-hilog@1",
    "analyzer.summarize-trace@1",
    "capture.diagnostics@1",
    "debug.hap@1",
    "deploy.native-library.app-owned@1",
    "observe.device@1",
    "port-forward.create@1",
    "port-forward.remove@1",
    "workspace.apply-patch@1",
    "workspace.create-checkpoint@1",
    "workspace.symbolize-crash@1",
  ]

  func testTheRuntimeEngineNamesNoNewPublishedOperation() throws {
    let engine = packageRoot().appending(
      path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift")
    let code = try codeWithoutComments(of: engine)
    let pattern =
      #""(?:analyzer|workspace|debug|capture|observe|flash|deploy|port-forward)"#
      + #"\.[a-z0-9.\-]+(?:@[0-9]+)?""#
    let expression = try NSRegularExpression(pattern: pattern)
    var observed: Set<String> = []
    for match in expression.matches(
      in: code, range: NSRange(code.startIndex..., in: code))
    {
      guard let range = Range(match.range, in: code) else { continue }
      observed.insert(String(code[range].dropFirst().dropLast()))
    }
    XCTAssertFalse(
      observed.isEmpty, "the scan found no operation references; it tests nothing now")

    let added = observed.subtracting(Self.engineDeclaredOperations).sorted()
    XCTAssertEqual(
      added, [],
      """
      the execution kernel gained per-operation knowledge for \(added.joined(separator: ", ")); \
      that belongs to the Catalog descriptor or the provider that implements it, and adding it \
      here makes publishing an operation an edit to the engine
      """)
    let stale = Self.engineDeclaredOperations.subtracting(observed).sorted()
    XCTAssertEqual(
      stale, [],
      """
      \(stale.joined(separator: ", ")) is declared here but the engine no longer names it — \
      the point of this list is that it shrinks, so record the win by removing the entry
      """)
  }

}

/// `AFA-AC-1`: the Rockchip lowering is gone from product code.
///
/// A grep test, deliberately. The dependency and type checks above cannot see
/// this one: a string literal `"wlx"` handed to a process is not a type
/// boundary, and the whole point of CHG-2026-059 is that ArkDeck stops knowing
/// how to phrase a Rockchip write.
final class RockchipLoweringRemovalContractTests: XCTestCase {

  private func productSwiftFiles() throws -> [(path: String, source: String)] {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources", directoryHint: .isDirectory)
    var out: [(String, String)] = []
    let walker = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil)
    while let url = walker?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      out.append((url.path, try String(contentsOf: url, encoding: .utf8)))
    }
    return out
  }

  /// Strips comments, so *discussing* the removal is not confused with doing it.
  private func codeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        let trimmed = line.drop(while: { $0 == " " })
        if trimmed.hasPrefix("//") { return "" }
        if let comment = line.range(of: "//") { return line[line.startIndex..<comment.lowerBound] }
        return line
      }
      .joined(separator: "\n")
  }

  func testProductCodeNeverPhrasesARockchipWriteOrSectorRead() throws {
    // ArkForge owns the complete RockUSB vocabulary. Product Swift may model
    // typed actions, but it cannot reconstruct vendor argv.
    let delegated = [
      "\"ld\"", "\"rd\"", "\"wlx\"", "\"wl\"", "\"rl\"", "\"ppt\"",
      "\"db\"", "\"gpt\"", "\"ul\"", "\"ef\"",
    ]
    for (path, source) in try productSwiftFiles() {
      let code = codeOnly(source)
      for verb in delegated {
        XCTAssertFalse(
          code.contains(verb),
          "\(path) phrases \(verb) as an argv element; that lowering is arkforged's "
            + "(CHG-2026-059)")
      }
    }
  }

  func testTheReadDomainLessonSurvivedItsCode() throws {
    // `characterizeMediumReadDomain` carried a lesson that cost a full
    // campaign: past the read window every sector reads as uniform 0xCC, so a
    // readback there cannot tell "not written" from "cannot be read". Deleting
    // the code must not delete that.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let index = repoRoot.appending(path: "docs/design/rockchip-read-domain.md")
    let text = try String(contentsOf: index, encoding: .utf8)
    XCTAssertTrue(text.contains("AD-006"), "the read-domain index must cite AD-006")
    XCTAssertTrue(text.contains("AD-019"), "and its independent reproduction, AD-019")
    XCTAssertTrue(text.contains("0xCC"), "and name what the window returns")
    XCTAssertTrue(text.contains("65536"), "and where the window ends")
  }
}
