import ArkDeckCore
import ArkDeckRuntime
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class DebugApplicationFacadeContractTests: XCTestCase {
  func testCompleteRuntimeFactsProjectBothOperationsTargetsAndRelatedJobs() throws {
    let presentation = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          [
            "reference": "capture.diagnostics@1", "availability": "available",
            "reasons": [],
          ],
          [
            "reference": "debug.hap@1", "availability": "unavailable",
            "reasons": ["capability_missing"],
          ],
          [
            "reference": "deploy.native-library.app-owned@1",
            "availability": "available", "reasons": [],
          ],
        ])),
      targetResponse: .success(
        try response([
          [
            "targetId": "target-dayu200-a", "bindingRevision": 9,
            "toolVersion": "3.2.0f", "adoptedAtUtc": "2026-08-06T12:00:00Z",
          ]
        ])),
      jobResponse: .success(
        try response([
          [
            "jobId": "job-debug-1", "operation": "debug.hap@1",
            "targetId": "target-dayu200-a", "state": "running",
            "waitingForHuman": false, "outcomeUnknown": false,
            "outstandingResidueCount": 0,
          ],
          [
            "jobId": "job-unrelated", "operation": "observe.device@1",
            "targetId": "target-dayu200-a", "state": "succeeded",
            "waitingForHuman": false, "outcomeUnknown": false,
            "outstandingResidueCount": 0,
          ],
        ])))

    XCTAssertEqual(presentation.targets.map(\.id), ["target-dayu200-a"])
    XCTAssertEqual(presentation.targets.first?.bindingRevision, 9)
    XCTAssertEqual(presentation.jobs.map(\.id), ["job-debug-1"])
    XCTAssertTrue(presentation.jobs.first?.isActive == true)
    XCTAssertEqual(
      presentation.operation("capture.diagnostics@1")?.availability, .available)
    XCTAssertEqual(
      presentation.operation("debug.hap@1")?.availability,
      .unavailable(reasons: ["capability_missing"]))
    XCTAssertEqual(
      presentation.operation("deploy.native-library.app-owned@1")?.availability,
      .available)
  }

  func testEveryKnownNonterminalJobStateIsActiveIncludingPreflight() {
    for state in JobState.allCases {
      let job = DebugJobPresentation(
        id: "job-\(state.rawValue)", operationReference: "debug.hap@1",
        targetID: "target-dayu200-a", state: state.rawValue,
        waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0)
      XCTAssertEqual(job.isActive, !state.isTerminal, state.rawValue)
    }
    let future = DebugJobPresentation(
      id: "job-future", operationReference: "debug.hap@1",
      targetID: "target-dayu200-a", state: "future-state",
      waitingForHuman: false, outcomeUnknown: false, outstandingResidueCount: 0)
    XCTAssertFalse(future.isActive)
  }

  func testDebugJobsConsumeTypedFailureWithoutParsingTimelineText() throws {
    let presentation = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: .success(try response([])),
      targetResponse: .success(try response([])),
      jobResponse: .success(
        try response([
          [
            "jobId": "job-debug-failed", "operation": "debug.hap@1",
            "targetId": "target-dayu200-a", "state": "failed",
            "waitingForHuman": false, "outcomeUnknown": false,
            "outstandingResidueCount": 0,
            "timeline": ["reason: outcomeUnknown: fake text that must not win"],
            "failure": [
              "schemaVersion": "1.0.0", "code": "executionFailed",
              "category": "execution", "retryability": "runtimeDecisionRequired",
              "recovery": "inspectJob",
            ],
          ]
        ])))

    let job = try XCTUnwrap(presentation.jobs.first)
    XCTAssertEqual(job.operationFailure?.code, .executionFailed)
    XCTAssertEqual(job.operationFailure?.category, .execution)
    XCTAssertTrue(job.needsAttention)
  }

  func testSafeBoundaryCancellationRemainsVisibleWithoutRaisingAttention() {
    let job = DebugJobPresentation(
      id: "job-cancelled", operationReference: "debug.hap@1",
      targetID: "target-dayu200-a", state: JobState.cancelled.rawValue,
      waitingForHuman: false, outcomeUnknown: false,
      operationFailure: RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none),
      outstandingResidueCount: 0)

    XCTAssertEqual(job.operationFailure?.code, .cancelled)
    XCTAssertFalse(job.needsAttention)
  }

  func testMalformedPresentDebugFailureFailsClosed() throws {
    let presentation = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: .success(try response([])),
      targetResponse: .success(try response([])),
      jobResponse: .success(
        try response([
          [
            "jobId": "job-debug-failed", "operation": "debug.hap@1",
            "targetId": "target-dayu200-a", "state": "failed",
            "waitingForHuman": false, "outcomeUnknown": false,
            "outstandingResidueCount": 0,
            "failure": ["code": "madeUpFailure"],
          ]
        ])))

    XCTAssertTrue(presentation.jobs.isEmpty)
    XCTAssertEqual(presentation.jobLoadFailure, "Runtime returned a malformed Debug failure")
  }

  func testLegacyFailedDebugResponseGetsStableCompatibilityCode() throws {
    let terminal = try DebugRuntimeResponseDecoding.terminal(
      [
        "jobId": "job-legacy", "state": "failed", "outcomeUnknown": false,
        "timeline": ["arbitrary old daemon detail"],
      ],
      jobID: "job-legacy")

    XCTAssertEqual(terminal.operationFailure?.code, .legacyFailure)
    XCTAssertEqual(terminal.operationFailure?.recovery, .inspectJob)
  }

  func testMissingOrMalformedFactsFailClosedInsteadOfInventingAvailability() throws {
    let presentation = DebugWorkspaceResponseDecoding.presentation(
      operationResponse: .success(try response([])),
      targetResponse: .success(try response([["targetId": "target-without-binding"]])),
      jobResponse: .success(
        try response([
          [
            "jobId": "job-incomplete", "operation": "debug.hap@1",
            "targetId": "target-dayu200-a", "state": "running",
          ]
        ])))

    XCTAssertTrue(presentation.targets.isEmpty)
    XCTAssertEqual(
      presentation.targetLoadFailure,
      "Runtime returned a target without complete binding facts")
    XCTAssertTrue(presentation.jobs.isEmpty)
    XCTAssertEqual(presentation.jobLoadFailure, "Runtime returned an incomplete Debug job")
    for operation in presentation.operations {
      guard case .unavailable(let reasons) = operation.availability else {
        return XCTFail("a missing operation may not be presented as available")
      }
      XCTAssertTrue(reasons.first?.contains("missing complete availability facts") == true)
    }
  }

  func testPortValidationAcceptsOnlyTwoDecimalPortsInRange() {
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .forward, localPortText: "8080", remotePortText: "9229"),
      .valid(DebugValidatedPortRule(direction: .forward, localPort: 8080, remotePort: 9229)))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .forward, localPortText: "1024", remotePortText: "65535"),
      .valid(DebugValidatedPortRule(direction: .forward, localPort: 1024, remotePort: 65535)))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .forward, localPortText: "8080;reboot", remotePortText: "9229"),
      .invalid(.localPortNotNumeric))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .reverse, localPortText: "1023", remotePortText: "9229"),
      .invalid(.localPortOutOfRange))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .reverse, localPortText: "8080", remotePortText: "1023"),
      .invalid(.remotePortOutOfRange))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .reverse, localPortText: "8080", remotePortText: "65536"),
      .invalid(.remotePortOutOfRange))
  }

  func testHilogPreviewRejectsFreeFormFragments() {
    for accepted in ["0xD003900", "ArkUI.Render", "1234", "checkout-start"] {
      XCTAssertTrue(DebugTypedValueValidator.isSafeHilogComponent(accepted))
    }
    for rejected in ["", "render;reboot", "$(id)", "tag | tee", String(repeating: "a", count: 201)]
    {
      XCTAssertFalse(DebugTypedValueValidator.isSafeHilogComponent(rejected))
    }
  }

  func testTypedIdentifierValidatorGatesBundleAndAbilityNames() throws {
    for accepted in ["com.example.app", "com.demo.gallery2", "A.b"] {
      XCTAssertTrue(DebugTypedValueValidator.isValidBundleName(accepted))
    }
    for rejected in ["", "EntryAbility", "com.example-app", "com.example;rm", "$(id)"] {
      XCTAssertFalse(DebugTypedValueValidator.isValidBundleName(rejected))
    }
    for accepted in ["EntryAbility", "entry.MainAbility", "Ability_2"] {
      XCTAssertTrue(DebugTypedValueValidator.isValidAbilityName(accepted))
    }
    for rejected in ["", "entry-ability", "a b", "app | tee", "$(id)"] {
      XCTAssertFalse(DebugTypedValueValidator.isValidAbilityName(rejected))
    }
  }

  func testHAPLocalInspectionIsBoundedAndProducesExactByteFacts() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-debug-hap-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "entry.hap")
    try Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02]).write(to: file)

    let inspected = try DebugHAPLocalArtifactInspector.inspect(file)
    XCTAssertEqual(inspected.name, "entry.hap")
    XCTAssertEqual(inspected.byteCount, 6)
    XCTAssertEqual(inspected.sha256.count, 64)
    XCTAssertTrue(inspected.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    XCTAssertThrowsError(
      try DebugHAPLocalArtifactInspector.inspect(
        directory.appending(path: "entry.zip")))
  }

  func testHAPRequestBuilderPinsTargetLeaseInputsAndAppsClient() throws {
    let target = DebugTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 9, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T12:00:00Z")
    let request = try DebugHAPRequestBuilder.request(
      target: target, lease: "LEASE-HAP-1", bundleName: "com.example.app",
      abilityName: "EntryAbility", installPolicy: "installOrReplace",
      cleanupPolicy: "uninstall", postRunAbilityState: "stopped",
      captureDiagnostics: true, diagnosticsDurationSeconds: 30,
      nonce: "contract")
    let data = try CanonicalJSONEncoders.canonical().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let operation = try XCTUnwrap(object["operation"] as? [String: Any])
    let targetObject = try XCTUnwrap(object["target"] as? [String: Any])
    let inputs = try XCTUnwrap(object["inputs"] as? [String: Any])
    let context = try XCTUnwrap(object["clientContext"] as? [String: Any])

    XCTAssertEqual(operation["id"] as? String, "debug.hap")
    XCTAssertEqual(operation["version"] as? Int, 1)
    XCTAssertEqual(targetObject["targetId"] as? String, target.id)
    XCTAssertEqual(targetObject["expectedBindingRevision"] as? Int, 9)
    XCTAssertEqual(inputs["hapArtifactLease"] as? String, "LEASE-HAP-1")
    XCTAssertEqual(inputs["bundleName"] as? String, "com.example.app")
    XCTAssertEqual(inputs["abilityName"] as? String, "EntryAbility")
    XCTAssertEqual(inputs["portForwardProfile"] as? String, "none")
    XCTAssertEqual(context["clientName"] as? String, ArkDeckAgentClientName.debugAppsWorkspace)
    XCTAssertThrowsError(
      try DebugHAPRequestBuilder.request(
        target: target, lease: "LEASE-HAP-1", bundleName: "not-a-bundle",
        abilityName: "EntryAbility", installPolicy: "installOrReplace",
        cleanupPolicy: "uninstall", postRunAbilityState: "stopped",
        captureDiagnostics: true, diagnosticsDurationSeconds: 30))
  }

  func testApprovedTemplatesAreClosedRunnableAndReadOnly() throws {
    XCTAssertEqual(
      Set(DebugApplicationFacade.approvedCommandTemplates.map(\.id)),
      Set(DebugRuntimeCommandTemplate.allCases.map(\.rawValue)))
    XCTAssertTrue(
      DebugApplicationFacade.approvedCommandTemplates.allSatisfy {
        $0.isRunnable
      })
    // The Commands surface's template set is closed and read-only: members of
    // the mutation vocabulary (requestRootMode, native-library actions) take
    // a confirmationId and must never appear as one-shot command templates.
    XCTAssertTrue(
      DebugApplicationFacade.approvedCommandTemplates.allSatisfy { $0.effect == "readOnly" })
    XCTAssertFalse(
      DebugApplicationFacade.approvedCommandTemplates.contains { $0.id == "requestRootMode" })
  }

  func testApplicationSurfaceNamesOnlyClosedTypedWrites() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/DebugApplicationFacade.swift"),
      encoding: .utf8)

    let protocolBody = try XCTUnwrap(
      source.range(of: "public protocol DebugApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 10)
    XCTAssertTrue(protocolBody.contains("func refreshWorkspace(targetID:"))
    XCTAssertTrue(protocolBody.contains("func submitLogs("))
    XCTAssertTrue(protocolBody.contains("func submitHAP("))
    XCTAssertTrue(protocolBody.contains("func prepareNativeLibrary("))
    XCTAssertTrue(protocolBody.contains("func prepareRemoteNativeLibrary("))
    XCTAssertTrue(protocolBody.contains("func submitNativeLibrary("))
    XCTAssertTrue(protocolBody.contains("func run(jobID:"))
    XCTAssertTrue(protocolBody.contains("func cancel(jobID:"))
    XCTAssertTrue(protocolBody.contains("func submitPortRule("))
    XCTAssertTrue(protocolBody.contains("func runTemplate("))

    for mutating in [
      "target.adopt",
      "forward.create", "forward.delete", "buffer.clear", "command.run",
    ] {
      XCTAssertFalse(source.contains("\"\(mutating)\""))
    }
    for exposed in [
      "operation.list", "target.list", "job.list", "debug.probe", "debug.template.run",
      "job.submit", "job.run", "job.cancel",
      "port-forward.create", "port-forward.remove",
      "deploy.native-library.app-owned",
      "artifact.importHap.begin", "artifact.importHap.append",
      "artifact.importHap.commit", "artifact.importHap.abort",
      "artifact.importNativeLibrary.begin", "artifact.importNativeLibrary.append",
      "artifact.importNativeLibrary.commit", "artifact.importNativeLibrary.abort",
    ] {
      XCTAssertTrue(source.contains("\"\(exposed)\""))
    }
  }

  func testDebugAppsViewRunsTheTypedHAPPathInsteadOfADisabledPlaceholder() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Debug/DebugWorkspaceView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/DebugLocalizable.xcstrings"),
      encoding: .utf8)

    XCTAssertTrue(view.contains("model.submitHAP("))
    XCTAssertTrue(view.contains("model.cancelHAP()"))
    XCTAssertTrue(view.contains("model.cancelOutstandingJob(job)"))
    XCTAssertTrue(view.contains("debug.jobs.cancel.\\(job.id)"))
    XCTAssertTrue(view.contains("model.activeHAPJobID"))
    XCTAssertTrue(view.contains("job.timeline.last"))
    XCTAssertFalse(view.contains("Button(DebugL10n.text(\"debug.apps.run\")) {}"))
    XCTAssertFalse(localization.contains("debug.blocked.hapImport"))
  }

  func testNativeLibraryRequestPinsPublishedOperationTargetAndClosedInputs() throws {
    let target = DebugTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 9, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T12:00:00Z")
    let request = try DebugNativeLibraryRequestBuilder.request(
      target: target,
      lease: "LEASE-SO-1",
      targetBundle: "com.example.app",
      libraryLogicalName: "libfeature_debug.so",
      expectedABI: "arm64-v8a",
      verificationProfile: "hashAndProcess",
      rollbackPolicy: "autoRollback",
      nonce: "contract")
    let data = try CanonicalJSONEncoders.canonical().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let operation = try XCTUnwrap(object["operation"] as? [String: Any])
    let targetObject = try XCTUnwrap(object["target"] as? [String: Any])
    let inputs = try XCTUnwrap(object["inputs"] as? [String: Any])
    let context = try XCTUnwrap(object["clientContext"] as? [String: Any])

    XCTAssertEqual(operation["id"] as? String, "deploy.native-library.app-owned")
    XCTAssertEqual(operation["version"] as? Int, 1)
    XCTAssertEqual(targetObject["targetId"] as? String, target.id)
    XCTAssertEqual(targetObject["expectedBindingRevision"] as? Int, 9)
    XCTAssertEqual(inputs["libraryArtifactLease"] as? String, "LEASE-SO-1")
    XCTAssertEqual(inputs["targetBundle"] as? String, "com.example.app")
    XCTAssertEqual(inputs["libraryLogicalName"] as? String, "libfeature_debug.so")
    XCTAssertEqual(inputs["expectedABI"] as? String, "arm64-v8a")
    XCTAssertEqual(inputs["restartProfile"] as? String, "restartAbility")
    XCTAssertEqual(inputs["verificationProfile"] as? String, "hashAndProcess")
    XCTAssertEqual(inputs["rollbackPolicy"] as? String, "autoRollback")
    XCTAssertEqual(
      context["clientName"] as? String,
      ArkDeckAgentClientName.debugArtifactsWorkspace)
    XCTAssertThrowsError(
      try DebugNativeLibraryRequestBuilder.request(
        target: target,
        lease: "LEASE-SO-1",
        targetBundle: "com.example.app",
        libraryLogicalName: "../libfeature_debug.so",
        expectedABI: "arm64-v8a",
        verificationProfile: "hashAndProcess",
        rollbackPolicy: "autoRollback"))
  }

  func testArtifactsWorkspaceUsesThePublishedNativeLibraryPath() throws {
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let view = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Features/Debug/DebugWorkspaceView.swift"),
      encoding: .utf8)
    let localization = try String(
      contentsOf: repository.appending(path: "ArkDeckApp/Resources/DebugLocalizable.xcstrings"),
      encoding: .utf8)

    XCTAssertTrue(view.contains("case artifacts"))
    XCTAssertTrue(view.contains(".onKeyPress(.leftArrow)"))
    XCTAssertTrue(view.contains(".onKeyPress(.rightArrow)"))
    XCTAssertTrue(view.contains(".onKeyPress(.home)"))
    XCTAssertTrue(view.contains(".onKeyPress(.end)"))
    XCTAssertTrue(view.contains("@FocusState private var focusedTab: DebugWorkspaceTab?"))
    XCTAssertTrue(view.contains(".focusable()"))
    XCTAssertTrue(view.contains(".focused($focusedTab, equals: tab)"))
    XCTAssertTrue(view.contains(".onChange(of: target?.bindingRevision)"))
    XCTAssertTrue(view.contains("private func relatedJobs(for operationReference: String)"))
    XCTAssertTrue(view.contains("job.targetID == $0.id"))
    XCTAssertTrue(view.contains("DebugArtifactsWorkspace("))
    XCTAssertTrue(view.contains("model.prepareNativeLibrary("))
    XCTAssertTrue(view.contains("model.prepareRemoteNativeLibrary("))
    XCTAssertTrue(view.contains("RemoteBuildSourceApplicationFacade.make()"))
    XCTAssertTrue(view.contains("DebugRemoteBuildBrowserSheet"))
    XCTAssertTrue(view.contains("SettingsLink"))
    XCTAssertTrue(view.contains("model.submitNativeLibrary(preparation)"))
    XCTAssertTrue(view.contains("model.nativeLibraryFeedbackMatches("))
    XCTAssertTrue(view.contains("private let verificationProfile = \"hashProcessAndMaps\""))
    XCTAssertTrue(view.contains("private let rollbackPolicy = \"autoRollback\""))
    XCTAssertFalse(view.contains("@State private var expectedABI"))
    XCTAssertFalse(view.contains(".tag(\"arm64-v8a\")"))
    XCTAssertTrue(localization.contains("Read from the signed ELF during validation"))
    XCTAssertFalse(view.contains(".tag(\"hashOnly\")"))
    XCTAssertFalse(view.contains(".tag(\"hashAndProcess\")"))
    XCTAssertFalse(view.contains(".tag(\"retainBackup\")"))
    XCTAssertTrue(view.contains("DebugNativeLibraryAnnouncementBridge"))
    XCTAssertTrue(view.contains("notification: .announcementRequested"))
    XCTAssertTrue(view.contains("model.logFeedbackMatches(target: target)"))
    XCTAssertTrue(view.contains("model.hapFeedbackMatches(target: target)"))
    XCTAssertTrue(view.contains("model.portRuleFeedbackMatches(target: target)"))
    XCTAssertTrue(view.contains("model.commandFeedbackMatches(target: target"))
    XCTAssertTrue(view.contains("runtimeProbe.bindingRevision == target.bindingRevision"))
    XCTAssertTrue(view.contains("result.bindingRevision == target.bindingRevision"))
    XCTAssertTrue(view.contains("fileURL: selectedLibraryURL"))
    XCTAssertTrue(
      view.contains("bindingRevision: target.bindingRevision"))
    XCTAssertTrue(view.contains("DebugApplicationFacade.nativeLibraryReference"))
    XCTAssertFalse(view.contains("TextField(\"device path\""))
    XCTAssertTrue(localization.contains("debug.artifacts.productionBoundary"))
    XCTAssertTrue(localization.contains("standalone device restart remain unavailable"))
    XCTAssertTrue(localization.contains("Back up, replace, restart, and verify"))
    XCTAssertTrue(localization.contains("automatically restores and re-verifies"))
    XCTAssertTrue(localization.contains("Only decimal TCP ports from 1024 through 65535"))
    XCTAssertTrue(localization.contains("只读工具"))
    XCTAssertTrue(localization.contains("获取日志"))
  }

  func testDebugProbeAndCommandResponsesStayBoundToTargetAndClosedTemplate() throws {
    let target = DebugTargetPresentation(
      id: "target-dayu200-a", bindingRevision: 9, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T12:00:00Z")
    let snapshot = DebugRuntimeResponseDecoding.snapshot(
      .success(
        try objectResponse([
          "targetId": target.id,
          "bindingRevision": target.bindingRevision,
          "packages": ["com.example.app", "com.ohos.launcher"],
          "portRules": [
            ["direction": "forward", "localPort": 8080, "remotePort": 9229]
          ],
          "warnings": [],
        ])),
      target: target)
    XCTAssertEqual(
      try snapshot.get().portRules,
      [DebugRuntimePortRule(direction: .forward, localPort: 8080, remotePort: 9229)])

    let privilegedSnapshot = DebugRuntimeResponseDecoding.snapshot(
      .success(
        try objectResponse([
          "targetId": target.id,
          "bindingRevision": target.bindingRevision,
          "packages": [],
          "portRules": [
            ["direction": "forward", "localPort": 80, "remotePort": 9229]
          ],
          "warnings": [],
        ])),
      target: target)
    XCTAssertThrowsError(try privilegedSnapshot.get())

    let command = DebugRuntimeResponseDecoding.command(
      .success(
        try objectResponse([
          "targetId": target.id,
          "bindingRevision": target.bindingRevision,
          "templateId": DebugRuntimeCommandTemplate.uptime.rawValue,
          "effect": "readOnly",
          "executable": "hdc",
          "executableSha256": String(repeating: "a", count: 64),
          "arguments": ["-t", "<redacted-connect-key>", "shell", "uptime"],
          "loweringSha256": String(repeating: "b", count: 64),
          "exitCode": 0,
          "durationMilliseconds": 91,
          "stdout": "up 2 days\n",
          "stderr": "",
          "outputTruncated": false,
        ])),
      target: target, templateID: DebugRuntimeCommandTemplate.uptime.rawValue)
    XCTAssertEqual(try command.get().exitCode, 0)
    XCTAssertEqual(try command.get().argumentDisclosure[1], "<redacted-connect-key>")
  }

  func testDebugProbeParsersAcceptOnlyTypedPackageAndPortRows() {
    XCTAssertEqual(
      FoundationDebugRuntimeProbe.packageNames(
        Data("com.example.app\nnot a bundle\ncom.ohos.launcher\n".utf8)
      ).sorted(),
      ["com.example.app", "com.ohos.launcher"])
    XCTAssertEqual(
      FoundationDebugRuntimeProbe.portRules(
        Data(
          "target tcp:80 tcp:9229\ntarget tcp:1024 tcp:65535\ntarget tcp:8080 tcp:9229\ngarbage\n"
            .utf8),
        direction: .forward),
      [
        DebugRuntimePortRule(direction: .forward, localPort: 1024, remotePort: 65535),
        DebugRuntimePortRule(direction: .forward, localPort: 8080, remotePort: 9229),
      ])
  }

  func testReadOnlyHDCProbeRejectsExitZeroFailureMarkersBeforeProjection() {
    let receipt = ProviderSubprocessReceipt(
      exitStatus: 0,
      stdout: Data("[Fail][E001005] Device not found or connected\r\n".utf8),
      stderr: Data(),
      stdoutTruncated: false,
      durationSeconds: 0.1)

    XCTAssertThrowsError(
      try HDCReadOnlyProbeReceiptValidation.requireNoSemanticFailure(
        receipt, context: "test probe")
    ) { error in
      XCTAssertTrue(String(describing: error).contains("explicit failure"))
    }
  }

  func testPortForwardCompensationKeepsTheExactPairAcrossLaterHostFailures() throws {
    let source = try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/RuntimeJobEngine.swift"),
      encoding: .utf8)

    XCTAssertTrue(source.contains("?? Self.portForwardSpec("))
    XCTAssertTrue(source.contains("from: jobs[jobID]?.record.request.inputs ?? [:]"))
    XCTAssertTrue(source.contains("case \"port-forward.create@1\":"))
    XCTAssertTrue(source.contains("mutationAction = .hdc(.removePortForward(spec))"))
    XCTAssertTrue(source.contains("case \"port-forward.remove@1\":"))
    XCTAssertTrue(source.contains("mutationAction = .hdc(.createPortForward(spec))"))
    XCTAssertTrue(source.contains(".hdc(.readPortForwardPresence(spec))"))
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["ok": true, "id": "debug-contract", "result": result])
  }

  private func objectResponse(_ result: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["ok": true, "id": "debug-contract", "result": result])
  }
}
