import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore

final class ManualUIFlashDriverContractTests: XCTestCase {
  private func repositoryRoot() -> URL {
    var repositoryRoot = URL(filePath: #filePath)
    for _ in 0..<5 {
      repositoryRoot.deleteLastPathComponent()
    }
    return repositoryRoot
  }

  private func repositorySource(_ path: String) throws -> String {
    return try String(
      contentsOf: repositoryRoot().appending(path: path),
      encoding: .utf8)
  }

  private func driverSource() throws -> String {
    try repositorySource("scripts/manual_ui_flash/manual_ui_flash.swift")
  }

  private func runCandidateValidator(_ candidateURL: URL) throws -> (
    status: Int32, stdout: String, stderr: String
  ) {
    try runValidator(["--validate-candidate", candidateURL.path])
  }

  private func runValidator(_ arguments: [String]) throws -> (
    status: Int32, stdout: String, stderr: String
  ) {
    // The validator script is interpreted from current source each time;
    // only the imported SDK modules are cached, in the directory every
    // interpreting test process shares (see ManualUIFlashFixtures).
    let cache = try ManualUIFlashFixtures.sharedModuleCache()
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = [
      "swift", "-module-cache-path", cache.path,
      repositoryRoot().appending(
        path:
          "scripts/manual_ui_flash/manual_ui_flash.swift"
      ).path,
    ] + arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: stdout, as: UTF8.self),
      String(decoding: stderr, as: UTF8.self)
    )
  }

  func testBridgeAcceptsCurrentFlashFramesAndRefusesRetiredOrUnboundedUploads() throws {
    let bytes = Data([0x1f, 0x8b, 0x08])
    let begin: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.import-intent/1"), "importRequestId": .string("app-import-test"),
      "kind": .string("flash-bundle"), "targetId": .string("target-test"), "bindingRevision": .string("1"),
      "deviceProfile": .string("dayu200"), "name": .string("images.tar.gz"), "byteCount": .string("3"),
      "sha256": .string(SHA256Hex.string(of: bytes)),
    ]
    let append: [String: JSONValue] = [
      "importId": .string("imp-test"), "generation": .string("1"), "offset": .string("0"),
      "byteCount": .string("3"), "sha256": .string(SHA256Hex.string(of: bytes)),
      "base64": .string(bytes.base64EncodedString()),
    ]
    var cases: [(String, [String: JSONValue], Bool)] = [
      ("health", [:], true), ("job.show", ["jobId": .string("job-test")], true),
      ("job.timeline", ["jobId": .string("job-test")], true),
      ("artifact.import.begin", begin, true), ("artifact.import.append", append, true),
      ("artifact.import.commit", ["importId": .string("imp-test"), "generation": .string("1")], true),
      ("artifact.import.abort", ["importRequestId": .string("app-import-test"), "generation": .string("1")], true),
      ("health", ["unexpected": .bool(true)], false),
      ("job.list-page", [:], false), ("job.status", [:], false),
      ("artifact.importFlashBundle.begin", begin, false),
      ("artifact.import.release", ["importId": .string("imp-test"), "generation": .string("2")], false),
    ]
    var foreign = begin; foreign["kind"] = .string("hap")
    cases.append(("artifact.import.begin", foreign, false))
    var unbounded = begin; unbounded["byteCount"] = .string("8589934593")
    cases.append(("artifact.import.begin", unbounded, false))
    var injected = begin; injected["path"] = .string("/tmp/foreign")
    cases.append(("artifact.import.begin", injected, false))
    var corrupt = append; corrupt["sha256"] = .string(String(repeating: "0", count: 64))
    cases.append(("artifact.import.append", corrupt, false))
    let frames = try cases.map { method, params, _ in
      try JSONDecoder().decode([String: JSONValue].self, from: ArkDeckAgentXPC.requestFrame(method: method, params: params))
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "frames.json")
    try CanonicalJSONEncoders.canonical().encode(frames).write(to: path)
    let result = try runValidator(["--validate-xpc-frames", path.path])
    XCTAssertEqual(result.status, 0, result.stderr)
    XCTAssertEqual(try JSONDecoder().decode([Bool].self, from: Data(result.stdout.utf8)), cases.map(\.2))
  }

  func testDriverUsesThePublishedOneClickFlashSurface() throws {
    let source = try driverSource()
    let legacyControls = [
      "flash.execute.review",
      "flash.confirm.destructivePhrase",
      "flash.confirm.userdataPhrase",
      "flash.confirm.accept",
      "flash.execute.mutationDispatchCount",
    ]
    for control in legacyControls {
      XCTAssertFalse(source.contains(control), "legacy UI control remains: \(control)")
    }

    XCTAssertTrue(
      source.contains(
        "try driver.waitForEnabled(\"flash.execute.submit\", timeout: controlTimeout)"))
    XCTAssertTrue(
      source.contains(
        "try driver.waitForPresence(\"flash.impact.userdata\", timeout: controlTimeout)"))
    XCTAssertFalse(source.contains("\"ERASE-USERDATA\","))
    XCTAssertTrue(source.contains("try driver.assertNoFlashSubmission()"))
    XCTAssertTrue(source.contains("try driver.submit(\"flash.execute.submit\")"))
  }

  func testApplicationExposesLocalizedUserdataImpactWithStableAccessibilityIdentity() throws {
    let source = try repositorySource("ArkDeckApp/Features/Flash/FlashWorkspaceView.swift")
    XCTAssertTrue(
      source.contains(".accessibilityIdentifier(dataImpactIdentifier(impact))"))
    XCTAssertTrue(source.contains("return \"flash.impact.userdata\""))
  }

  func testApplicationCanActivateAnExactSelectedTargetFromEitherRegisteredMode() throws {
    let source = try repositorySource("ArkDeckApp/Features/Flash/FlashWorkspaceView.swift")
    XCTAssertTrue(source.contains("willActivateCurrentTargetOnSubmit"))
    XCTAssertTrue(
      source.contains("status.mode == \"loader\" || status.mode == \"hdcNormal\""))
    XCTAssertTrue(source.contains("disposition: .exactBoundTarget"))
    XCTAssertTrue(source.contains("mode: observedMode"))
  }

  func testNavigationHasNativeActionFallbackWhenAXOmitsTheFrame() throws {
    let source = try driverSource()
    let startMarker =
      "  private func click(_ element: AXUIElement, identifier: String) throws {"
    let endMarker = "\n  func setValue("
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
    let implementation = source[start..<end]
    XCTAssertTrue(implementation.contains("kAXPressAction"))
    XCTAssertTrue(implementation.contains("kAXSelectedAttribute"))
  }

  func testDriverRaisesTheExactAppBeforeDeliveringPointerOrKeyboardInput() throws {
    let source = try driverSource()
    XCTAssertTrue(
      source.contains(
        "runningApplication.activate(options: [.activateAllWindows])"))
    XCTAssertTrue(source.contains("kAXFocusedWindowAttribute"))
    XCTAssertTrue(source.contains("kAXFrontmostAttribute"))
    XCTAssertTrue(source.contains("kAXRaiseAction"))
    XCTAssertTrue(source.contains("runningApplication.isActive"))
    XCTAssertTrue(source.contains("observedFrontmost == true"))
    XCTAssertFalse(source.contains("guard raised == .success"))
    XCTAssertTrue(source.contains("try activateApplication()"))
  }

  func testDriverObservesWorkspaceSelectionAndUsesPointerForTheSwiftUIFileButton() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("case .waitForSelected:"))
    XCTAssertTrue(source.contains("try driver.waitForSelected(action.identifier!"))
    XCTAssertTrue(source.contains("try driver.chooseFileIfNeeded("))
    XCTAssertTrue(source.contains("options.archiveURL, delivery: action.delivery!"))
    XCTAssertTrue(source.contains("element(identifier: \"flash.image.value\")"))
    XCTAssertTrue(source.contains("== url.lastPathComponent"))
    XCTAssertTrue(source.contains("try perform(\"flash.image.choose\""))
    XCTAssertFalse(source.contains("try press(\"flash.image.choose\")"))
  }

  func testExternalCandidateUsesAComposablePreSubmitProgramWithoutPRInput() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("--candidate-file"))
    XCTAssertTrue(source.contains("--debug-session-file"))
    XCTAssertTrue(
      source.contains(
        "Set(dynamic.allKeys.map(\\.stringValue)) == Set(CodingKeys.allCases.map(\\.stringValue))"))
    XCTAssertTrue(source.contains("for action in candidate.program.actions"))
    XCTAssertTrue(source.contains("stable effect grammar rather than an enumeration"))
    XCTAssertFalse(source.contains("published UI repair envelope"))
    XCTAssertFalse(source.contains("git commit"))
    XCTAssertFalse(source.contains("gh pr"))
  }

  func testDefaultCandidateTracksTheCurrentWorkspaceFlow() throws {
    let candidateURL = repositoryRoot().appending(
      path: "scripts/manual_ui_flash/manual_ui_flash_candidate.json")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: candidateURL)) as? [String: Any])
    let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
    let identifiers = actions.compactMap { $0["identifier"] as? String }

    XCTAssertEqual(
      identifiers,
      [
        "app.navigation.flash",
        "flash.workspace.imageAction",
        "flash.workspace.details",
      ])
    XCTAssertFalse(identifiers.contains("flash.mode"))
    XCTAssertFalse(identifiers.contains("flash.mode.execute"))
    XCTAssertFalse(identifiers.contains("flash.plan.prepare"))
    XCTAssertEqual(
      actions.first(where: { $0["identifier"] as? String == "flash.workspace.details" })?["delivery"]
        as? String,
      "accessibilityPress")
  }

  func testStandaloneValidatorAcceptsNovelCompositionAndRejectsAuthorityField() throws {
    let candidateURL = repositoryRoot().appending(
      path:
        "scripts/manual_ui_flash/manual_ui_flash_candidate.json")
    let accepted = try runCandidateValidator(candidateURL)
    XCTAssertEqual(accepted.status, 0, accepted.stderr)
    XCTAssertTrue(accepted.stdout.contains("CANDIDATE_VALID:"))

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: candidateURL)) as? [String: Any])
    var actions = try XCTUnwrap(object["actions"] as? [[String: Any]])
    actions.insert(
      ["kind": "waitForPresence", "identifier": "flash.novel.debug.control"], at: 0)
    object["actions"] = actions
    let novelURL = FileManager.default.temporaryDirectory
      .appending(path: "manual-ui-novel-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      .write(to: novelURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: novelURL) }
    let novel = try runCandidateValidator(novelURL)
    XCTAssertEqual(novel.status, 0, novel.stderr)

    object["capability"] = "candidate-must-not-supply"
    let invalidURL = FileManager.default.temporaryDirectory
      .appending(path: "manual-ui-invalid-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      .write(to: invalidURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    let rejected = try runCandidateValidator(invalidURL)
    XCTAssertEqual(rejected.status, 2)
    XCTAssertTrue(
      rejected.stderr.contains("candidate UI program must have the exact published shape"))
  }

  // testRockchipSourceManifestPinsCurrentRepoBuildInputsBeforePush was
  // removed with CHG-2026-065: its subject — the bundled component's
  // source-distribution-manifest.json — left the repository along with the
  // component build pipeline it kept honest.

  func testCandidateProgramCannotNameTargetArchivePlanValueOrSubmit() throws {
    let data = try Data(
      contentsOf: repositoryRoot()
        .appending(path: "scripts/manual_ui_flash/manual_ui_flash_candidate.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      Set([
        "documentType", "schemaVersion", "applicationActivation",
        "activationSettleMilliseconds", "controlTimeoutSeconds", "planTimeoutSeconds", "actions",
      ]))
    let forbidden = [
      "app", "target", "archive", "plan", "operation", "argv",
      "executable", "capability", "reservation", "submit", "job", "runtimeSocket",
    ]
    for key in forbidden { XCTAssertNil(object[key], "candidate exposed forbidden key \(key)") }

    var forbiddenAction = object
    forbiddenAction["actions"] = [
      [
        "kind": "perform",
        "identifier": "flash.execute.submit",
        "delivery": "pointerClick",
        "fallbackStrings": [],
      ]
    ]
    let invalidURL = FileManager.default.temporaryDirectory
      .appending(path: "manual-ui-submit-\(UUID().uuidString).json")
    try JSONSerialization.data(withJSONObject: forbiddenAction, options: [.sortedKeys])
      .write(to: invalidURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: invalidURL) }
    let rejected = try runCandidateValidator(invalidURL)
    XCTAssertEqual(rejected.status, 2)
    XCTAssertTrue(rejected.stderr.contains("escaped the exact Flash pre-submit surface"))

    let source = try driverSource()
    XCTAssertTrue(source.contains("try driver.assertNoFlashSubmission()"))
    XCTAssertTrue(source.contains("try session?.markSubmissionRequested()"))
    XCTAssertTrue(source.contains("try driver.submit(\"flash.execute.submit\")"))
  }

  func testPreAdmissionLoopRetriesSafeRefusalsAndBlocksUnknownSubmission() throws {
    let source = try driverSource()
    XCTAssertFalse(source.contains("candidate is not materially distinct from a prior attempt"))
    XCTAssertTrue(source.contains("document.attempts.count < Self.maximumAttempts"))
    XCTAssertTrue(source.contains("candidateProgramSHA256"))
    XCTAssertTrue(source.contains("candidateAppExecutableSHA256"))
    XCTAssertTrue(source.contains("applicationExecutableSHA256(options.appURL)"))
    XCTAssertTrue(source.contains("prior UI submission outcome is not terminal"))
    XCTAssertTrue(source.contains("submissionOutcomeUnknown"))
    XCTAssertTrue(source.contains("runtimeContinuationRequired"))
    XCTAssertTrue(source.contains("externalDispatch=0"))
    XCTAssertTrue(source.contains("continue through the captured Runtime debug seed"))
  }

  func testRuntimeSuccessStillRequiresProductPostflightBeforeSessionSuccess() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("static let maximumDestructiveEpochs = 16"))
    XCTAssertTrue(source.contains("var destructiveEpochsUsed: Int"))
    XCTAssertTrue(source.contains("document.destructiveEpochsUsed += 1"))
    XCTAssertTrue(source.contains("func waitForProductPostflight"))
    XCTAssertTrue(source.contains("flash.postflight.build.match"))
    XCTAssertTrue(source.contains("flash.postflight.binding.match"))
    XCTAssertTrue(source.contains("productVerificationFailed"))
    XCTAssertTrue(source.contains("try session?.markProductVerified()"))

    let appSource = try repositorySource("ArkDeckApp/Features/Flash/FlashWorkspaceView.swift")
    XCTAssertTrue(
      appSource.contains(#".accessibilityIdentifier("flash.execute.jobId")"#))
    XCTAssertTrue(
      appSource.contains(
        #".accessibilityIdentifier("\(identifier).\(matches ? "match" : "mismatch")")"#))
  }

  func testOnlyProtectedMainActuatorCanReachUIOrRuntime() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("process.executableURL = URL(fileURLWithPath: \"/usr/bin/git\")"))
    XCTAssertTrue(source.contains("\"rev-parse\", \"origin/main^{commit}\""))
    XCTAssertTrue(
      source.contains(
        "\"origin/main:scripts/manual_ui_flash/manual_ui_flash.swift\""))
    XCTAssertTrue(source.contains("guard reviewed == current"))
    XCTAssertTrue(source.contains("let protectedMainCommitOID = try protectedMainActuatorCommit()"))
    XCTAssertTrue(
      source.contains(
        "use candidate JSON or an isolated App build instead of running an unmerged driver"))
  }

  func testNextCandidateRelaunchesExactAppAndPinsItsExecutableBytes() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("requiresFreshCandidateApp"))
    XCTAssertTrue(source.contains("guard running.terminate()"))
    XCTAssertTrue(source.contains("guard running.isTerminated"))
    XCTAssertFalse(source.contains("forceTerminate()"))
    XCTAssertTrue(
      source.contains(
        "applicationExecutableSHA256(options.appURL) == appExecutableSHA256"))
    XCTAssertTrue(source.contains("candidate App executable changed before UI activation"))
    XCTAssertTrue(source.contains("candidate App executable changed before submit barrier"))
  }

  func testBridgeCapturesAcceptedRequestAsUnprivilegedRuntimeDebugSeed() throws {
    let source = try driverSource()
    XCTAssertTrue(source.contains("--capture-debug-seed"))
    XCTAssertTrue(source.contains("debugSeed.removeValue(forKey: \"clientContext\")"))
    XCTAssertTrue(source.contains("typed[\"authorization\"] == nil"))
    XCTAssertTrue(source.contains("typed[\"campaignReservation\"] == nil"))
    XCTAssertTrue(source.contains("O_WRONLY | O_CREAT | O_EXCL"))
    XCTAssertTrue(source.contains("S_IRUSR | S_IWUSR"))
    XCTAssertTrue(source.contains("RUNTIME_DEBUG_SEED:"))
  }

  func testTargetPickerRequiresTheRequestedValueToBecomeObservable() throws {
    let source = try driverSource()
    let startMarker =
      "  func selectPickerValue(_ value: String, identifier: String) throws {"
    let endMarker = "\n  func waitForFacts("
    let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
    let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
    let implementation = source[start..<end]

    XCTAssertTrue(implementation.contains("kAXPopUpButtonRole"))
    XCTAssertTrue(implementation.contains("observesPickerValue"))
    XCTAssertTrue(implementation.contains("did not select"))
    XCTAssertFalse(implementation.contains("if direct == .success { return }"))
  }
}
