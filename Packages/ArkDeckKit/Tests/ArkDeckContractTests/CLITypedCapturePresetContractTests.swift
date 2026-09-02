import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

final class CLITypedCapturePresetContractTests: XCTestCase {
  private func request(
    operation: String = "capture.diagnostics",
    inputs: [String: JSONValue] = [:]
  ) -> RuntimeAgentExecutionRequest {
    RuntimeAgentExecutionRequest(
      operationID: operation,
      operationVersion: 1,
      inputs: inputs,
      capabilityReference: "CAP-RT-1",
      targetID: "T-1",
      maximumWaitSeconds: 37,
      executionID: "execution-1")
  }

  func testScreenCaptureUsesTheSharedScreenshotPreset() throws {
    let projected = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["screen", "capture"],
      request: request(inputs: ["screenshotImageType": .string("jpeg")]))

    XCTAssertEqual(projected.inputs, try DiagnosticCapturePreset.screen(imageType: "jpeg"))
    XCTAssertEqual(projected.targetID, "T-1")
    XCTAssertEqual(projected.capabilityReference, "CAP-RT-1")
    XCTAssertEqual(projected.maximumWaitSeconds, 37)
    XCTAssertEqual(projected.executionID, "execution-1")
  }

  func testViewerCaptureAndComponentDetailUseDistinctBoundedPresets() throws {
    let capture = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["ui-dump", "capture"], request: request())
    XCTAssertEqual(capture.inputs, DiagnosticCapturePreset.uiDump())

    let detail = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["ui-dump", "component-detail"],
      request: request(inputs: [
        "windowId": .string("60"),
        "componentId": .string("841"),
      ]))
    XCTAssertEqual(
      detail.inputs,
      try DiagnosticCapturePreset.componentDetail(windowID: "60", componentID: "841"))
  }

  func testTraceCaptureKeepsOnlyTheTypedTraceProjection() throws {
    let projected = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["trace", "capture"],
      request: request(inputs: [
        "durationSeconds": .integer(15),
        "traceCategories": .array([.string("sched"), .string("arkui")]),
        "traceBufferKB": .integer(8_192),
        "ringBuffered": .bool(true),
      ]))

    XCTAssertEqual(
      projected.inputs,
      try DiagnosticCapturePreset.trace(
        durationSeconds: 15,
        categories: ["sched", "arkui"],
        bufferKB: 8_192,
        ringBuffered: true))
    XCTAssertEqual(projected.inputs["uiScreenshot"], .bool(false))
    XCTAssertNil(projected.inputs["advancedDump"])
  }

  func testDebugLogsUsesTheSharedHilogPreset() throws {
    let projected = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["debug", "logs"],
      request: request(inputs: [
        "durationSeconds": .integer(30),
        "hilogFilters": .array([.string("com.example.app"), .string("ArkUI:Layout")]),
      ]))
    XCTAssertEqual(
      projected.inputs,
      try DiagnosticCapturePreset.logs(
        durationSeconds: 30, filters: ["com.example.app", "ArkUI:Layout"]))
    XCTAssertEqual(projected.inputs["uiScreenshot"], .bool(false))
    XCTAssertEqual(projected.inputs["uiComponentTree"], .bool(false))
    XCTAssertEqual(projected.inputs["crashLogs"], .bool(false))
    XCTAssertNil(projected.inputs["traceCategories"])

    let bare = try RuntimeCLI.capturePresetExecutionRequest(
      path: ["debug", "logs"], request: request(inputs: ["durationSeconds": .integer(5)]))
    XCTAssertEqual(bare.inputs["hilogFilters"], .array([]))

    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["debug", "logs"],
        request: request(inputs: [
          "durationSeconds": .integer(5), "hilogFilters": .array([.string("a b; rm")]),
        ])),
      "a filter that could read as a shell fragment never reaches the request")
    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["debug", "logs"],
        request: request(inputs: ["durationSeconds": .integer(601)])))
    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["debug", "logs"],
        request: request(inputs: ["durationSeconds": .integer(5), "uiDump": .bool(true)])),
      "the logs preset accepts no other diagnostics leg")
  }

  func testPresetRejectsFieldsFromAnotherDiagnosticsRecipe() {
    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["screen", "capture"],
        request: request(inputs: ["traceCategories": .array([.string("sched")])]))
    ) { thrown in
      XCTAssertTrue(
        (thrown as? DiagnosticCapturePresetError)?.reason.contains("does not accept") == true)
    }
  }

  func testComponentAndTraceInputsFailClosedOnMissingOrMalformedValues() {
    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["ui-dump", "component-detail"],
        request: request(inputs: ["windowId": .string("60")])))
    XCTAssertThrowsError(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["trace", "capture"],
        request: request(inputs: [
          "durationSeconds": .integer(15),
          "traceCategories": .array([.string("sched"), .string("sched")]),
          "traceBufferKB": .integer(8_192),
        ])))
  }

  func testOrdinaryDomainAliasPreservesCallerInputs() throws {
    let original = request(operation: "input.tap", inputs: ["x": .integer(10)])
    XCTAssertEqual(
      try RuntimeCLI.capturePresetExecutionRequest(
        path: ["input", "tap"], request: original),
      original)
  }
}
