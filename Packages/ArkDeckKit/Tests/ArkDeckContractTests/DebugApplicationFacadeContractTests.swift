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
        direction: .forward, localPortText: "8080;reboot", remotePortText: "9229"),
      .invalid(.localPortNotNumeric))
    XCTAssertEqual(
      DebugPortRuleValidator.validate(
        direction: .reverse, localPortText: "0", remotePortText: "9229"),
      .invalid(.localPortOutOfRange))
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
    for accepted in ["com.example.app", "EntryAbility", "com.demo.gallery2"] {
      XCTAssertTrue(DebugTypedValueValidator.isSafeTypedIdentifier(accepted))
    }
    for rejected in ["", "com.example; rm -rf /", "$(id)", "a b", "app | tee"] {
      XCTAssertFalse(DebugTypedValueValidator.isSafeTypedIdentifier(rejected))
    }
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

  func testApplicationSurfaceCannotNameAWriteMethod() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/ArkDeckWorkflows/DebugApplicationFacade.swift"),
      encoding: .utf8)

    let protocolBody = try XCTUnwrap(
      source.range(of: "public protocol DebugApplicationProviding: Sendable {")
        .map { source[$0.upperBound...] }
        .flatMap { rest in rest.range(of: "}").map { String(rest[..<$0.lowerBound]) } })
    XCTAssertEqual(
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 6)
    XCTAssertTrue(protocolBody.contains("func refreshWorkspace(targetID:"))
    XCTAssertTrue(protocolBody.contains("func submitLogs("))
    XCTAssertTrue(protocolBody.contains("func run(jobID:"))
    XCTAssertTrue(protocolBody.contains("func cancel(jobID:"))
    XCTAssertTrue(protocolBody.contains("func submitPortRule("))
    XCTAssertTrue(protocolBody.contains("func runTemplate("))

    for mutating in [
      "artifact.import", "target.adopt",
      "forward.create", "forward.delete", "buffer.clear", "command.run",
    ] {
      XCTAssertFalse(source.contains("\"\(mutating)\""))
    }
    for readOnly in [
      "operation.list", "target.list", "job.list", "debug.probe", "debug.template.run",
      "job.submit", "job.run", "job.cancel",
      "port-forward.create", "port-forward.remove",
    ] {
      XCTAssertTrue(source.contains("\"\(readOnly)\""))
    }
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
        Data("com.example.app\nnot a bundle\ncom.ohos.launcher\n".utf8)).sorted(),
      ["com.example.app", "com.ohos.launcher"])
    XCTAssertEqual(
      FoundationDebugRuntimeProbe.portRules(
        Data("target tcp:8080 tcp:9229\ngarbage\n".utf8), direction: .forward),
      [DebugRuntimePortRule(direction: .forward, localPort: 8080, remotePort: 9229)])
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
        receipt, context: "test probe")) { error in
          XCTAssertTrue(String(describing: error).contains("explicit failure"))
        }
  }

  func testPortForwardCompensationKeepsTheExactPairAcrossLaterHostFailures() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
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
