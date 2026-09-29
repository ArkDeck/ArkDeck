@testable import ArkDeckClientKit
import Foundation
import Testing


struct TraceApplicationFacadeContractTests {
  @Test func publishedOperationFactsAreProjectedWithoutInventingProbeOrArtifacts() {
    let operation = TraceApplicationFacade.operationPresentation(availability: .available)

    #expect(operation.reference == "capture.diagnostics@1")
    #expect(operation.durationSecondsRange == 1...600)
    #expect(operation.traceBufferKBRange == 1_024...65_536)
    #expect(operation.maximumTraceTagCount == 24)
    #expect(operation.traceStepCancellation == "atSafeBoundary")
    #expect(operation.supportsTypedTraceCategories)
    #expect(operation.supportsRawTraceArtifact)
    #expect(!operation.supportsFilteredTraceArtifact)
    #expect(operation.supportsCaptureLogArtifact)
    #expect(!operation.exposesAdapterCapabilityFacts)
    #expect(!operation.exposesParameterSnapshotFacts)
  }

  @Test func numericValidatorAcceptsOnlyBoundedDecimalInput() {
    #expect(
      TraceNumericInputValidator.validate("1", range: 1...600)
        == .valid(1))
    #expect(
      TraceNumericInputValidator.validate("600", range: 1...600)
        == .valid(600))
    #expect(
      TraceNumericInputValidator.validate("", range: 1...600)
        == .invalid(.missing))
    #expect(
      TraceNumericInputValidator.validate("10.5", range: 1...600)
        == .invalid(.notDecimal))
    #expect(
      TraceNumericInputValidator.validate("10;id", range: 1...600)
        == .invalid(.notDecimal))
    #expect(
      TraceNumericInputValidator.validate("601", range: 1...600)
        == .invalid(.outsideRange(1...600)))
  }

  @Test func durationUnitsKeepRuntimeRequestsInCanonicalSeconds() {
    #expect(TraceDurationInputUnit.seconds.quickValues == [5, 10, 15, 30])
    #expect(TraceDurationInputUnit.minutes.quickValues == [1, 2, 3])
    #expect(
      TraceDurationInputUnit.seconds.inputRange(forDurationSecondsRange: 1...600)
        == 1...600)
    #expect(
      TraceDurationInputUnit.minutes.inputRange(forDurationSecondsRange: 1...600)
        == 1...10)
    #expect(
      TraceDurationInputUnit.minutes.inputRange(forDurationSecondsRange: 1...30) == nil)
    #expect(
      TraceDurationInputUnit.seconds.durationSeconds(for: 45, allowedRange: 1...600)
        == 45)
    #expect(
      TraceDurationInputUnit.minutes.durationSeconds(for: 3, allowedRange: 1...600)
        == 180)
    #expect(
      TraceDurationInputUnit.minutes.durationSeconds(for: 11, allowedRange: 1...600) == nil)
    #expect(
      TraceDurationInputUnit.minutes.inputValue(
        forDurationSeconds: 61,
        allowedRange: 1...600)
        == 2)
    #expect(
      TraceDurationInputUnit.minutes.inputValue(
        forDurationSeconds: 100,
        allowedRange: 1...100) == nil,
      "unit changes must not round beyond the published maximum or shorten silently")
  }

  @Test func viewerArtifactPolicyRequiresOneExactPublishedRawTrace() {
    let valid = artifact()
    #expect(
      TracePublishedArtifactPolicy.selectRawTrace(from: [valid])
        == valid)
    #expect(
      TracePublishedArtifactPolicy.selectRawTrace(from: [valid, valid]) == nil,
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
      #expect(
        TracePublishedArtifactPolicy.selectRawTrace(from: [candidate]) == nil,
        "invalid field set must never enter the parser: \(candidate)")
    }
  }

  @Test func workspaceDecoderPreservesBindingAndLabelsDiagnosticsJobsHonestly() throws {
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

    #expect(presentation.operation.availability == .available)
    #expect(
      presentation.targets
        == [
          TraceTargetPresentation(
            id: "target-a",
            bindingRevision: 9,
            toolVersion: "3.2.0f",
            adoptedAtUTC: "2026-08-06T08:00:00Z")
        ])
    #expect(presentation.relatedDiagnosticsJobs.count == 1)
    #expect(presentation.relatedDiagnosticsJobs.first?.id == "diagnostics-job")
    #expect(presentation.relatedDiagnosticsJobs.first?.traceLegSelectionKnown == false)
  }

  @Test func traceTargetsJoinSharedDeviceIdentityFacts() {
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

    #expect(joined.first?.deviceName == "OpenHarmony Reference Device")
    #expect(joined.first?.systemVersion == "OpenHarmony-7.0.0.39")
    #expect(joined.first?.connectKey == "5SM0125725000252")
    #expect(joined.first?.transport == "USB")
    #expect(
      joined.first?.connectionSummary
        == "OpenHarmony-7.0.0.39 · 5SM0…00252 · USB")
    #expect(
      joined.first?.accessibleConnectionSummary
        == "OpenHarmony-7.0.0.39, 5SM0125725000252, USB")
  }

  @Test func traceDeviceJoinRequiresTheCurrentBindingAndOneRoute() {
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

    #expect(
      TraceApplicationFacade.rejoin(
        targets: [target],
        with: DeviceListPresentation(availability: .available, candidates: candidates))
        == [target],
      "ambiguous current routes must not be presented as one physical device")
  }

  @Test func malformedMatchingFactsFailClosed() throws {
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

    #expect(
      presentation.operation.availability
        == .unavailable(reasons: ["capture.diagnostics@1 is missing complete availability facts"]))
    #expect(presentation.targets.isEmpty)
    #expect(presentation.relatedDiagnosticsJobs.isEmpty)
    #expect(
      presentation.targetLoadFailure
        == "Runtime returned a target without complete binding facts")
    #expect(
      presentation.jobLoadFailure
        == "Runtime returned an incomplete diagnostics job")
  }

  @Test func facadeExposesClosedTypedTraceSubmitRunAndCancel() throws {
    let facade = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckClientKit/TraceApplicationFacade.swift")
    let protocolBody = try #require(
      facade.split(separator: "public protocol TraceApplicationProviding", maxSplits: 1)
        .last?.split(separator: "public enum TraceApplicationFacade", maxSplits: 1).first)

    #expect(protocolBody.contains("refreshWorkspace"))
    #expect(protocolBody.contains("submitCapture"))
    #expect(protocolBody.contains("run(jobID:"))
    #expect(protocolBody.contains("cancel(jobID:"))
    #expect(!protocolBody.contains("write"))
    #expect(facade.contains("method: \"operation.list\""))
    #expect(facade.contains("method: \"target.list\""))
    #expect(facade.contains("method: \"job.list\""))
    #expect(facade.contains("method: \"job.submit\""))
    #expect(facade.contains("method: \"job.run\""))
    #expect(facade.contains("method: \"job.cancel\""))
    #expect(facade.contains("ArkDeckAgentClientName.traceWorkspace"))
    for forbidden in ["method: \"artifact.import\"", "method: \"artifact.export\""] {
      #expect(!facade.contains(forbidden), "\(forbidden)")
    }
  }

  @Test func appRoutesTraceWorkspaceAndStartsOnlyThroughTheFacade() throws {
    let app = try source("ArkDeckApp/App/ArkDeckApp.swift")
    let workspace = try source("ArkDeckApp/Features/Trace/TraceWorkspaceView.swift")
    let configuration = try source(
      "ArkDeckApp/Features/Trace/TraceConfigurationView.swift")

    #expect(app.contains("case .trace:\n      TraceWorkspaceView"))
    #expect(
      workspace.contains(
        "String.LocalizationValue(key), table: \"TraceLocalizable\""))
    #expect(workspace.contains("model.submit()"))
    #expect(workspace.contains("traceString(\"trace.action.start\")"))
    #expect(workspace.contains("model.cancel()"))
    #expect(workspace.contains(#"private(set) var durationText = "10""#))
    #expect(
      workspace.contains(
        "min(durationRange.upperBound, max(durationRange.lowerBound, 10))"))
    #expect(configuration.contains("model.capturePresets"))
    #expect(configuration.contains("TextField(traceString(\"trace.bounds.duration\")"))
    #expect(configuration.contains("selection: durationUnitBinding"))
    #expect(configuration.contains("ForEach(model.durationUnit.quickValues"))
    #expect(configuration.contains(".toggleStyle(.button)"))
    #expect(!configuration.contains("configurationMode"))
    #expect(!configuration.contains("customTags"))
    #expect(!configuration.contains("TraceDebugParameterCatalog.definitions"))
    #expect(!configuration.contains("trace.buffer"))
    #expect(!configuration.contains("trace.parameters"))
    #expect(!configuration.contains("trace.filter"))
    #expect(app.contains("models.traceWorkspace.applyDeviceObservation("))
    #expect(workspace.contains("TraceApplicationFacade.rejoin("))
    #expect(configuration.contains("model.deviceTitle(target)"))
    #expect(configuration.contains("target.connectionSummary"))
    #expect(workspace.contains("trace.blocker.adapterUnsupported"))
    #expect(workspace.contains(".disabled(model.isSubmitting)"))
    #expect(workspace.contains("submissionFailure = captureBlockers.first"))
    #expect(workspace.contains("selectionChangedDuringRefresh"))
    #expect(workspace.contains("next.runtimeProbe?.targetID != resolvedTargetID"))
    #expect(workspace.contains("preferredConnectedTargetID"))
    #expect(workspace.contains("candidate.isAuthorized"))
    #expect(!workspace.contains("job.submit"))
    #expect(!configuration.contains("shell"))
    #expect(
      workspace.contains(
        "if terminal.state == \"succeeded\", !terminal.outcomeUnknown"))
    #expect(workspace.contains("TracePublishedArtifactPolicy.selectRawTrace("))
    #expect(workspace.contains("allowSensitive: true"))
    #expect(workspace.contains("case .completed(let url):"))
    #expect(workspace.contains("documentController.open(url)"))
  }

  @Test func runtimeProbeDecoderPinsTargetBindingAdapterTagsAndAllParameters() throws {
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
      Issue.record("complete target-bound probe should decode")
      return
    }
    #expect(snapshot.targetID == target.id)
    #expect(snapshot.bindingRevision == target.bindingRevision)
    #expect(snapshot.supportedTags == ["ace"])
    #expect(snapshot.tools.map(\.tool) == ["hitrace", "bytrace"])
    #expect(snapshot.parameters.count == TraceDebugParameterCatalog.definitions.count)

    var drifted = result
    drifted["bindingRevision"] = 10
    let driftedData = try JSONSerialization.data(
      withJSONObject: ["id": "probe", "ok": true, "result": drifted])
    guard
      case .failure = TraceRuntimeProbeResponseDecoding.snapshot(
        .success(driftedData), target: target)
    else { Issue.record("binding drift must fail closed"); return }
  }

  @Test func traceLocalizationCoversRuntimeKeysAndContainsNoOrphans() throws {
    let data = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/TraceLocalizable.xcstrings"))
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(object["strings"] as? [String: Any])
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
    #expect(
      orphanedKeys.isEmpty,
      "TraceLocalizable contains keys with no Trace source consumer: \(orphanedKeys)")

    for key in strings.keys.sorted() {
      let entry = try #require(strings[key] as? [String: Any], "\(key)")
      let localizations = try #require(
        entry["localizations"] as? [String: Any], "\(key)")
      #expect(localizations["en"] != nil, "\(key)")
      #expect(localizations["zh-Hans"] != nil, "\(key)")
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
