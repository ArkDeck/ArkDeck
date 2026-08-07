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
    XCTAssertFalse(operation.supportsCaptureLogArtifact)
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
        try response([
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
        try response([
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

  func testFacadeExposesOneReadAndNoMutationTransport() throws {
    let facade = try source(
      "Packages/ArkDeckKit/Sources/ArkDeckWorkflows/TraceApplicationFacade.swift")
    let protocolBody = try XCTUnwrap(
      facade.split(separator: "public protocol TraceApplicationProviding", maxSplits: 1)
        .last?.split(separator: "public enum TraceApplicationFacade", maxSplits: 1).first)

    XCTAssertTrue(protocolBody.contains("refreshWorkspace"))
    XCTAssertFalse(protocolBody.contains("submit"))
    XCTAssertFalse(protocolBody.contains("cancel"))
    XCTAssertFalse(protocolBody.contains("write"))
    XCTAssertTrue(facade.contains("method: \"operation.list\""))
    XCTAssertTrue(facade.contains("method: \"target.list\""))
    XCTAssertTrue(facade.contains("method: \"job.list\""))
    for forbidden in [
      "method: \"job.submit\"", "method: \"job.cancel\"",
      "method: \"artifact.import\"", "method: \"artifact.export\"",
    ] {
      XCTAssertFalse(facade.contains(forbidden), forbidden)
    }
  }

  func testAppRoutesTraceWorkspaceAndKeepsStartLocked() throws {
    let app = try source("ArkDeckApp/App/ArkDeckApp.swift")
    let workspace = try source("ArkDeckApp/Features/Trace/TraceWorkspaceView.swift")
    let configuration = try source(
      "ArkDeckApp/Features/Trace/TraceConfigurationView.swift")

    XCTAssertTrue(app.contains("case .trace:\n      TraceWorkspaceView"))
    XCTAssertTrue(
      workspace.contains(
        "String.LocalizationValue(key), table: \"TraceLocalizable\""))
    // The start button names its configuration and duration, and admits a
    // parameter-mutating run applies parameters first; the action closure
    // stays empty and the control stays disabled.
    XCTAssertTrue(workspace.contains("Button(startActionTitle) {}"))
    XCTAssertTrue(workspace.contains("trace.action.startNamed"))
    XCTAssertTrue(workspace.contains("trace.action.applyAndStartNamed"))
    XCTAssertTrue(workspace.contains(".disabled(true)"))
    XCTAssertTrue(configuration.contains("TracePresetCatalog.definitions"))
    XCTAssertTrue(configuration.contains("TraceDebugParameterCatalog.definitions"))
    XCTAssertFalse(workspace.contains("job.submit"))
    XCTAssertFalse(configuration.contains("shell"))
  }

  func testTraceLocalizationCoversClosedPresetsModesAndStagesInBothLanguages() throws {
    let data = try Data(
      contentsOf: repository.appending(
        path: "ArkDeckApp/Resources/TraceLocalizable.xcstrings"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try XCTUnwrap(object["strings"] as? [String: Any])
    let requiredKeys =
      TracePresetCatalog.definitions.filter { $0.id != .custom }.map {
        "trace.preset.\($0.id.rawValue)"
      }
      + [
        "trace.parameters.mode.unchanged",
        "trace.parameters.mode.temporaryRestore",
        "trace.parameters.mode.persistentChange",
      ]
      + TraceWorkflowStage.allCases.map { "trace.stage.\($0.rawValue)" }

    for key in requiredKeys {
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

  private func source(_ relativePath: String) throws -> String {
    try String(contentsOf: repository.appending(path: relativePath), encoding: .utf8)
  }

  private var repository: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
