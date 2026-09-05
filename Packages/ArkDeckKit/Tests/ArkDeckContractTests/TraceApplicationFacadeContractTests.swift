import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class TraceApplicationFacadeContractTests: XCTestCase {
  func testPublishedOperationFactsAreProjectedWithoutInventingProbeOrArtifacts() {
    let operation = TraceApplicationFacade.operationPresentation(availability: .available)

    XCTAssertEqual(operation.reference, "capture.diagnostics@1")
    XCTAssertEqual(operation.durationSecondsRange, 1...600)
    XCTAssertEqual(operation.traceBufferKBRange, 1_024...65_536)
    XCTAssertEqual(operation.maximumTraceTagCount, 24)
    XCTAssertEqual(operation.traceStepCancellation, "atSafeBoundary")
    XCTAssertTrue(operation.supportsTypedTraceCategories)
    XCTAssertTrue(operation.supportsRawTraceArtifact)
    XCTAssertFalse(operation.supportsFilteredTraceArtifact)
    XCTAssertTrue(operation.supportsCaptureLogArtifact)
    XCTAssertFalse(operation.exposesAdapterCapabilityFacts)
    XCTAssertFalse(operation.exposesParameterSnapshotFacts)
  }

  func testNumericValidatorAcceptsOnlyBoundedDecimalInput() {
    XCTAssertEqual(
      TraceNumericInputValidator.validate("1", range: 1...600),
      .valid(1))
    XCTAssertEqual(
      TraceNumericInputValidator.validate("600", range: 1...600),
      .valid(600))
    XCTAssertEqual(
      TraceNumericInputValidator.validate("", range: 1...600),
      .invalid(.missing))
    XCTAssertEqual(
      TraceNumericInputValidator.validate("10.5", range: 1...600),
      .invalid(.notDecimal))
    XCTAssertEqual(
      TraceNumericInputValidator.validate("10;id", range: 1...600),
      .invalid(.notDecimal))
    XCTAssertEqual(
      TraceNumericInputValidator.validate("601", range: 1...600),
      .invalid(.outsideRange(1...600)))
  }

  func testDurationUnitsKeepRuntimeRequestsInCanonicalSeconds() {
    XCTAssertEqual(TraceDurationInputUnit.seconds.quickValues, [5, 10, 15, 30])
    XCTAssertEqual(TraceDurationInputUnit.minutes.quickValues, [1, 2, 3])
    XCTAssertEqual(
      TraceDurationInputUnit.seconds.inputRange(forDurationSecondsRange: 1...600),
      1...600)
    XCTAssertEqual(
      TraceDurationInputUnit.minutes.inputRange(forDurationSecondsRange: 1...600),
      1...10)
    XCTAssertNil(
      TraceDurationInputUnit.minutes.inputRange(forDurationSecondsRange: 1...30))
    XCTAssertEqual(
      TraceDurationInputUnit.seconds.durationSeconds(for: 45, allowedRange: 1...600),
      45)
    XCTAssertEqual(
      TraceDurationInputUnit.minutes.durationSeconds(for: 3, allowedRange: 1...600),
      180)
    XCTAssertNil(
      TraceDurationInputUnit.minutes.durationSeconds(for: 11, allowedRange: 1...600))
    XCTAssertEqual(
      TraceDurationInputUnit.minutes.inputValue(
        forDurationSeconds: 61,
        allowedRange: 1...600),
      2)
    XCTAssertNil(
      TraceDurationInputUnit.minutes.inputValue(
        forDurationSeconds: 100,
        allowedRange: 1...100),
      "unit changes must not round beyond the published maximum or shorten silently")
  }

  func testViewerArtifactPolicyRequiresOneExactPublishedRawTrace() {
    let valid = artifact()
    XCTAssertEqual(
      TracePublishedArtifactPolicy.selectRawTrace(from: [valid]),
      valid)
    XCTAssertNil(
      TracePublishedArtifactPolicy.selectRawTrace(from: [valid, valid]),
      "two plausible rows are ambiguous and must fail closed")

    let invalid: [RuntimeArtifactPresentation] = [
      artifact(name: "trace-filtered.htrace"),
      artifact(role: "derived"),
      artifact(mediaType: "application/json"),
      artifact(byteCount: 0),
      artifact(sha256: String(repeating: "A", count: 64)),
      artifact(privacy: "public"),
      artifact(status: "pending"),
      artifact(sourceOperation: "capture.diagnostics@2"),
    ]
    for candidate in invalid {
      XCTAssertNil(
        TracePublishedArtifactPolicy.selectRawTrace(from: [candidate]),
        "invalid field set must never enter the parser: \(candidate)")
    }
  }

  func testWorkspaceDecoderPreservesBindingAndLabelsDiagnosticsJobsHonestly() throws {
    let presentation = TraceWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          [
            "reference": "capture.diagnostics@1",
            "availability": "available",
            "reasons": [],
          ]
        ])),
      targetResponse: .success(
        try response([
          [
            "targetId": "target-a",
            "bindingRevision": 9,
            "toolVersion": "3.2.0f",
            "adoptedAtUtc": "2026-08-06T08:00:00Z",
          ]
        ])),
      jobResponse: .success(
        try currentJobPageResponse([
          [
            "jobId": "diagnostics-job",
            "operation": "capture.diagnostics@1",
            "targetId": "target-a",
            "state": "running",
            "waitingForHuman": false,
            "outcomeUnknown": false,
            "outstandingResidueCount": 0,
          ],
          [
            "jobId": "other-job",
            "operation": "observe.device@1",
            "targetId": "target-a",
            "state": "succeeded",
            "waitingForHuman": false,
            "outcomeUnknown": false,
            "outstandingResidueCount": 0,
          ],
        ])))

    XCTAssertEqual(presentation.operation.availability, .available)
    XCTAssertEqual(
      presentation.targets,
      [
        TraceTargetPresentation(
          id: "target-a",
          bindingRevision: 9,
          toolVersion: "3.2.0f",
          adoptedAtUTC: "2026-08-06T08:00:00Z")
      ])
    XCTAssertEqual(presentation.relatedDiagnosticsJobs.count, 1)
    XCTAssertEqual(presentation.relatedDiagnosticsJobs.first?.id, "diagnostics-job")
    XCTAssertEqual(presentation.relatedDiagnosticsJobs.first?.traceLegSelectionKnown, false)
  }

  func testTraceTargetsJoinSharedDeviceIdentityFacts() {
    let target = TraceTargetPresentation(
      id: "target-a",
      bindingRevision: 9,
      toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let observation = DeviceListPresentation(
      availability: .available,
      candidates: [
        DeviceCandidatePresentation(
          connectKey: "5SM0125725000252",
          state: "Connected",
          adoptedTargetID: "target-a",
          bindingRevision: 9,
          deviceInformation: DeviceInformationPresentation(
            name: "OpenHarmony Reference Device",
            systemVersion: "OpenHarmony-7.0.0.39",
            transport: "USB",
            observedAtUTC: "2026-08-24T03:01:00Z"),
          observedFacts: DeviceObservedFactsPresentation(
            model: "stale model",
            firmware: "stale version",
            transport: "network",
            confirmedAtUTC: "2026-08-24T03:00:00Z"))
      ])

    let joined = TraceApplicationFacade.rejoin(targets: [target], with: observation)

    XCTAssertEqual(joined.first?.deviceName, "OpenHarmony Reference Device")
    XCTAssertEqual(joined.first?.systemVersion, "OpenHarmony-7.0.0.39")
    XCTAssertEqual(joined.first?.connectKey, "5SM0125725000252")
    XCTAssertEqual(joined.first?.transport, "USB")
    XCTAssertEqual(
      joined.first?.connectionSummary,
      "OpenHarmony-7.0.0.39 · 5SM0…00252 · USB")
    XCTAssertEqual(
      joined.first?.accessibleConnectionSummary,
      "OpenHarmony-7.0.0.39, 5SM0125725000252, USB")
  }

  func testTraceDeviceJoinRequiresTheCurrentBindingAndOneRoute() {
    let target = TraceTargetPresentation(
      id: "target-a", bindingRevision: 9, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let candidates = [
      DeviceCandidatePresentation(
        connectKey: "old-route", state: "Connected",
        adoptedTargetID: "target-a", bindingRevision: 8),
      DeviceCandidatePresentation(
        connectKey: "new-route-a", state: "Connected",
        adoptedTargetID: "target-a", bindingRevision: 9),
      DeviceCandidatePresentation(
        connectKey: "new-route-b", state: "Connected",
        adoptedTargetID: "target-a", bindingRevision: 9),
    ]

    XCTAssertEqual(
      TraceApplicationFacade.rejoin(
        targets: [target],
        with: DeviceListPresentation(availability: .available, candidates: candidates)),
      [target],
      "ambiguous current routes must not be presented as one physical device")
  }

  func testMalformedMatchingFactsFailClosed() throws {
    let presentation = TraceWorkspaceResponseDecoding.presentation(
      operationResponse: .success(
        try response([
          ["reference": "capture.diagnostics@1", "availability": "available"]
        ])),
      targetResponse: .success(
        try response([
          ["targetId": "unbound"]
        ])),
      jobResponse: .success(
        try currentJobPageResponse([
          ["jobId": "incomplete", "operation": "capture.diagnostics@1"]
        ])))

    XCTAssertEqual(
      presentation.operation.availability,
      .unavailable(reasons: ["capture.diagnostics@1 is missing complete availability facts"]))
    XCTAssertTrue(presentation.targets.isEmpty)
    XCTAssertTrue(presentation.relatedDiagnosticsJobs.isEmpty)
    XCTAssertEqual(
      presentation.targetLoadFailure,
      "Runtime returned a target without complete binding facts")
    XCTAssertEqual(
      presentation.jobLoadFailure,
      "Runtime returned an incomplete diagnostics job")
  }

  func testFacadeExposesClosedTypedTraceSubmitRunAndCancel() throws {
    let facade = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceApplicationFacade.swift")
    let protocolBody = try XCTUnwrap(
      facade.split(separator: "public protocol TraceApplicationProviding", maxSplits: 1)
        .last?.split(separator: "public enum TraceApplicationFacade", maxSplits: 1).first)

    XCTAssertTrue(protocolBody.contains("refreshWorkspace"))
    XCTAssertTrue(protocolBody.contains("submitCapture"))
    XCTAssertTrue(protocolBody.contains("run(jobID:"))
    XCTAssertTrue(protocolBody.contains("cancel(jobID:"))
    XCTAssertFalse(protocolBody.contains("write"))
    XCTAssertTrue(facade.contains("method: \"operation.list\""))
    XCTAssertTrue(facade.contains("method: \"target.list\""))
    XCTAssertTrue(facade.contains("method: \"job.list\""))
    XCTAssertTrue(facade.contains("method: \"job.submit\""))
    XCTAssertTrue(facade.contains("method: \"job.run\""))
    XCTAssertTrue(facade.contains("method: \"job.cancel\""))
    XCTAssertTrue(facade.contains("ArkDeckAgentClientName.traceWorkspace"))
    for forbidden in ["method: \"artifact.import\"", "method: \"artifact.export\""] {
      XCTAssertFalse(facade.contains(forbidden), forbidden)
    }
  }

  func testAppRoutesTraceWorkspaceAndStartsOnlyThroughTheFacade() throws {
    let app = try source("ArkDeckApp/App/ArkDeckApp.swift")
    let workspace = try source("ArkDeckApp/Features/Trace/TraceWorkspaceView.swift")
    let configuration = try source(
      "ArkDeckApp/Features/Trace/TraceConfigurationView.swift")

    XCTAssertTrue(app.contains("case .trace:\n      TraceWorkspaceView"))
    XCTAssertTrue(
      workspace.contains(
        "String.LocalizationValue(key), table: \"TraceLocalizable\""))
    XCTAssertTrue(workspace.contains("model.submit()"))
    XCTAssertTrue(workspace.contains("traceString(\"trace.action.start\")"))
    XCTAssertTrue(workspace.contains("model.cancel()"))
    XCTAssertTrue(workspace.contains(#"private(set) var durationText = "10""#))
    XCTAssertTrue(
      workspace.contains(
        "min(durationRange.upperBound, max(durationRange.lowerBound, 10))"))
    XCTAssertTrue(configuration.contains("model.capturePresets"))
    XCTAssertTrue(configuration.contains("TextField(traceString(\"trace.bounds.duration\")"))
    XCTAssertTrue(configuration.contains("selection: durationUnitBinding"))
    XCTAssertTrue(configuration.contains("ForEach(model.durationUnit.quickValues"))
    XCTAssertTrue(configuration.contains(".toggleStyle(.button)"))
    XCTAssertFalse(configuration.contains("configurationMode"))
    XCTAssertFalse(configuration.contains("customTags"))
    XCTAssertFalse(configuration.contains("TraceDebugParameterCatalog.definitions"))
    XCTAssertFalse(configuration.contains("trace.buffer"))
    XCTAssertFalse(configuration.contains("trace.parameters"))
    XCTAssertFalse(configuration.contains("trace.filter"))
    XCTAssertTrue(app.contains("models.traceWorkspace.applyDeviceObservation("))
    XCTAssertTrue(workspace.contains("TraceApplicationFacade.rejoin("))
    XCTAssertTrue(configuration.contains("model.deviceTitle(target)"))
    XCTAssertTrue(configuration.contains("target.connectionSummary"))
    XCTAssertTrue(workspace.contains("trace.blocker.adapterUnsupported"))
    XCTAssertTrue(workspace.contains(".disabled(model.isSubmitting)"))
    XCTAssertTrue(workspace.contains("submissionFailure = captureBlockers.first"))
    XCTAssertTrue(workspace.contains("selectionChangedDuringRefresh"))
    XCTAssertTrue(workspace.contains("next.runtimeProbe?.targetID != resolvedTargetID"))
    XCTAssertTrue(workspace.contains("preferredConnectedTargetID"))
    XCTAssertTrue(workspace.contains("candidate.isAuthorized"))
    XCTAssertFalse(workspace.contains("job.submit"))
    XCTAssertFalse(configuration.contains("shell"))
    XCTAssertTrue(
      workspace.contains(
        "if terminal.state == \"succeeded\", !terminal.outcomeUnknown"))
    XCTAssertTrue(workspace.contains("TracePublishedArtifactPolicy.selectRawTrace("))
    XCTAssertTrue(workspace.contains("allowSensitive: true"))
    XCTAssertTrue(workspace.contains("case .completed(let url):"))
    XCTAssertTrue(workspace.contains("documentController.open(url)"))
  }

  func testRuntimeProbeDecoderPinsTargetBindingAdapterTagsAndAllParameters() throws {
    let target = TraceTargetPresentation(
      id: "target-a", bindingRevision: 9, toolVersion: "3.2.0f",
      adoptedAtUTC: "2026-08-06T08:00:00Z")
    let rows: [[String: Any]] = TraceDebugParameterCatalog.definitions.map {
      ["name": $0.name, "state": "value", "value": "0", "detail": NSNull()]
    }
    let result: [String: Any] = [
      "targetId": "target-a", "bindingRevision": 9,
      "adapterDisposition": "captureEligible", "tool": "hitrace",
      "family": "hitrace.dayu200-oh7.text", "supportedTags": ["ace"],
      "rawHelp": "registered", "rawHelpSha256": String(repeating: "a", count: 64),
      "tools": [
        [
          "tool": "hitrace", "disposition": "captureEligible",
          "family": "hitrace.dayu200-oh7.text",
          "rawHelpSha256": String(repeating: "a", count: 64),
          "detail": NSNull(),
        ],
        [
          "tool": "bytrace", "disposition": "unrecognized",
          "family": NSNull(),
          "rawHelpSha256": String(repeating: "b", count: 64),
          "detail": NSNull(),
        ],
      ],
      "parameters": rows,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: ["id": "probe", "ok": true, "result": result])
    let decoded = TraceRuntimeProbeResponseDecoding.snapshot(.success(data), target: target)
    guard case .success(let snapshot) = decoded else {
      return XCTFail("complete target-bound probe should decode")
    }
    XCTAssertEqual(snapshot.targetID, target.id)
    XCTAssertEqual(snapshot.bindingRevision, target.bindingRevision)
    XCTAssertEqual(snapshot.supportedTags, ["ace"])
    XCTAssertEqual(snapshot.tools.map(\.tool), ["hitrace", "bytrace"])
    XCTAssertEqual(snapshot.parameters.count, TraceDebugParameterCatalog.definitions.count)

    var drifted = result
    drifted["bindingRevision"] = 10
    let driftedData = try JSONSerialization.data(
      withJSONObject: ["id": "probe", "ok": true, "result": drifted])
    guard
      case .failure = TraceRuntimeProbeResponseDecoding.snapshot(
        .success(driftedData), target: target)
    else { return XCTFail("binding drift must fail closed") }
  }

  func testTraceLocalizationCoversRuntimeKeysAndContainsNoOrphans() throws {
    let data = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/TraceLocalizable.xcstrings"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(object["strings"] as? [String: Any])
    let requiredKeys = TracePresetCatalog.definitions.filter { $0.id != .custom }.map {
      "trace.preset.\($0.id.rawValue)"
    }

    let featureRoot = repository.appending(path: "ArkDeckApp/Features/Trace")
    let sources = try FileManager.default.contentsOfDirectory(
      at: featureRoot, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined(separator: "\n")
    let localizationSources = sources.split(separator: "\n").filter {
      !$0.contains(".accessibilityIdentifier") && !$0.contains("identifier:")
    }.joined(separator: "\n")
    let literalExpression = try NSRegularExpression(
      pattern: #"\"(trace\.[A-Za-z0-9_.-]+)\""#)
    let sourceRange = NSRange(localizationSources.startIndex..., in: localizationSources)
    var referencedKeys = Set(
      literalExpression.matches(in: localizationSources, range: sourceRange).compactMap { match in
        Range(match.range(at: 1), in: localizationSources).map {
          String(localizationSources[$0])
        }
      })
    referencedKeys.formUnion(requiredKeys)
    let generatedSymbolConsumers = [
      "trace.validation.range": "traceValidationRange(",
    ]
    referencedKeys.formUnion(
      generatedSymbolConsumers.compactMap { key, symbol in
        sources.contains(symbol) ? key : nil
      })

    let orphanedKeys = Set(strings.keys).subtracting(referencedKeys).sorted()
    XCTAssertTrue(
      orphanedKeys.isEmpty,
      "TraceLocalizable contains keys with no Trace source consumer: \(orphanedKeys)")

    for key in strings.keys.sorted() {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any], key)
      XCTAssertNotNil(localizations["en"], key)
      XCTAssertNotNil(localizations["zh-Hans"], key)
    }
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["id": "test", "ok": true, "result": result])
  }

  private func artifact(
    name: String = "trace.htrace",
    role: String? = "raw",
    mediaType: String = "application/octet-stream",
    byteCount: Int64 = 4_096,
    sha256: String = String(repeating: "a", count: 64),
    privacy: String = "sensitive",
    status: String = "published",
    sourceOperation: String = "capture.diagnostics@1"
  ) -> RuntimeArtifactPresentation {
    RuntimeArtifactPresentation(
      id: "artifact-1", name: name, role: role, mediaType: mediaType,
      byteCount: byteCount, sha256: sha256, privacy: privacy,
      status: status, statusDetail: nil, sourceOperation: sourceOperation,
      createdAtUTC: "2026-08-24T00:00:00Z", redactionApplied: false)
  }

  private func source(_ relativePath: String) throws -> String {
    try String(contentsOf: repository.appending(path: relativePath), encoding: .utf8)
  }

  private var repository: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
