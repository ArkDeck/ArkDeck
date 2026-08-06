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

  func testApprovedTemplatesAreDiscoveryOnlyAndRootStaysDistinct() throws {
    XCTAssertFalse(DebugApplicationFacade.approvedCommandTemplates.isEmpty)
    XCTAssertTrue(
      DebugApplicationFacade.approvedCommandTemplates.allSatisfy {
        !$0.isPublishedByRuntimeOperation
      })
    XCTAssertEqual(
      DebugApplicationFacade.approvedCommandTemplates.first { $0.id == "requestRootMode" }?.effect,
      "deviceMutation")
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
      protocolBody.split(separator: "\n").filter { $0.contains("func ") }.count, 1)
    XCTAssertTrue(protocolBody.contains("func refreshWorkspace()"))

    for mutating in [
      "job.submit", "job.run", "job.cancel", "artifact.import", "target.adopt",
      "forward.create", "forward.delete", "buffer.clear", "command.run",
    ] {
      XCTAssertFalse(source.contains("\"\(mutating)\""))
    }
    for readOnly in ["operation.list", "target.list", "job.list"] {
      XCTAssertTrue(source.contains("\"\(readOnly)\""))
    }
  }

  private func response(_ result: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: ["ok": true, "id": "debug-contract", "result": result])
  }
}
