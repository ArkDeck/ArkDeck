import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

final class RuntimeOperationV2ContractTests: XCTestCase {
  private func minimalJSON(extra: String = "") -> Data {
    Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "2.0.0",
        "requestId": "req-001",
        "idempotencyKey": "idem-0001",
        "target": { "targetId": "TGT-DAYU200-01" },
        "operation": { "id": "observe.device", "version": 1 }\(extra)
      }
      """.utf8)
  }

  private func assertRejected(
    _ data: Data,
    code: RuntimeOperationErrorCode,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try RuntimeOperationCodec.decodeRequest(data), file: file, line: line
    ) { error in
      guard let rejection = error as? RuntimeOperationRequestRejection else {
        XCTFail("expected RuntimeOperationRequestRejection, got \(error)", file: file, line: line)
        return
      }
      XCTAssertEqual(rejection.code, code, rejection.message, file: file, line: line)
    }
  }

  // MARK: - RTC-API-001

  func testMinimalRequestNeedsOnlyTargetOperationInputs() throws {
    let request = try RuntimeOperationCodec.decodeRequest(minimalJSON())
    XCTAssertEqual(request.requestID, "req-001")
    XCTAssertEqual(request.target.targetID, "TGT-DAYU200-01")
    XCTAssertEqual(request.operation.reference, "observe.device@1")
    XCTAssertEqual(request.inputs, [:])
    XCTAssertNil(request.authorization)
  }

  func testRoundTripIsStable() throws {
    let request = try RuntimeOperationRequest(
      requestID: "req-rt-001",
      idempotencyKey: "idem-rt-001",
      target: DurableTargetReference(targetID: "TGT-1", expectedBindingRevision: 3),
      operation: RuntimeOperationReference(id: "capture.diagnostics", version: 1),
      inputs: [
        "durationSeconds": .integer(30),
        "hilogFilters": .array([.string("*:E")]),
      ],
      requestedOutputs: [.rawArtifacts, .derivedArtifacts],
      authorization: RuntimeCapabilityReference(capabilityID: "CAP-RT-X-001"),
      clientContext: RuntimeClientContext(clientName: "cli", provenance: ["k": "v"]))
    let encodedOnce = try RuntimeOperationCodec.encodeRequest(request)
    let decoded = try RuntimeOperationCodec.decodeRequest(encodedOnce)
    XCTAssertEqual(decoded, request)
    let encodedTwice = try RuntimeOperationCodec.encodeRequest(decoded)
    XCTAssertEqual(encodedOnce, encodedTwice)
  }

  func testGovernanceFieldsAreRejectedWithStableCode() {
    let variants = [
      "\"changeId\": \"CHG-2026-001\"",
      "\"taskId\": \"TASK-X-001\"",
      "\"change_id\": \"CHG-2026-001\"",
      "\"approvalPRNumber\": 42",
      "\"mainCommitOID\": \"deadbeef\"",
      "\"authorizationBlobOid\": \"deadbeef\"",
      "\"prNumber\": 7",
      "\"pullRequestNumber\": 7",
      "\"sourceTaskId\": \"TASK-X-001\"",
    ]
    for variant in variants {
      assertRejected(minimalJSON(extra: ",\n  \(variant)"), code: .governanceFieldRejected)
    }
  }

  func testUnknownMajorVersionFailsClosed() {
    for version in ["1.0.0", "3.0.0", "10.2.1", "x.0.0", ""] {
      let data = Data(
        String(decoding: minimalJSON(), as: UTF8.self)
          .replacingOccurrences(of: "\"2.0.0\"", with: "\"\(version)\"").utf8)
      assertRejected(data, code: .unsupportedVersion)
    }
  }

  func testMinorVersionUnknownTopLevelKeyIsForwardCompatible() throws {
    let data = Data(
      String(decoding: minimalJSON(extra: ",\n  \"futureMinorField\": {\"x\": 1}"), as: UTF8.self)
        .replacingOccurrences(of: "\"2.0.0\"", with: "\"2.9.0\"").utf8)
    let request = try RuntimeOperationCodec.decodeRequest(data)
    XCTAssertEqual(request.requestID, "req-001")
  }

  func testDuplicateJSONKeysAreRejected() {
    let data = Data(
      """
      {
        "schemaVersion": "2.0.0",
        "requestId": "req-001",
        "requestId": "req-002",
        "idempotencyKey": "idem-0001",
        "target": { "targetId": "TGT-1" },
        "operation": { "id": "observe.device", "version": 1 }
      }
      """.utf8)
    assertRejected(data, code: .invalidRequest)
  }

  func testMissingSchemaVersionIsRejected() {
    let data = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(of: "\"schemaVersion\": \"2.0.0\",", with: "").utf8)
    assertRejected(data, code: .unsupportedVersion)
  }

  func testOversizedRequestIsRejected() {
    var text = String(decoding: minimalJSON(extra: ",\n  \"pad\": \"@\""), as: UTF8.self)
    text = text.replacingOccurrences(
      of: "\"@\"", with: "\"\(String(repeating: "x", count: RuntimeOperationCodec.maximumRequestBytes))\"")
    assertRejected(Data(text.utf8), code: .requestTooLarge)
  }

  func testExecutableSurfaceInputKeysAreRejected() {
    for key in ["argv", "shell", "command", "runHDC", "executable"] {
      let data = minimalJSON(extra: ",\n  \"inputs\": {\"\(key)\": \"x\"}")
      assertRejected(data, code: .invalidInput)
    }
  }

  func testInvalidIdempotencyKeyIsRejected() {
    let data = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(of: "\"idem-0001\"", with: "\"short\"").utf8)
    assertRejected(data, code: .invalidRequest)
  }

  // MARK: - Bundle manifest

  func testBundleManifestSourceFieldsAreAllOptional() throws {
    let manifest = try PublishedOperationBundleManifest(
      operation: RuntimeOperationReference(id: "observe.device", version: 1),
      catalogDigest: String(repeating: "a", count: 64))
    let data = try RuntimeOperationCodec.encodeBundleManifest(manifest)
    let decoded = try RuntimeOperationCodec.decodeBundleManifest(data)
    XCTAssertEqual(decoded, manifest)
    XCTAssertNil(decoded.sourceChangeID)
    XCTAssertNil(decoded.sourceTaskID)
    XCTAssertNil(decoded.sourceRevision)

    let full = try PublishedOperationBundleManifest(
      operation: RuntimeOperationReference(id: "observe.device", version: 1),
      catalogDigest: String(repeating: "a", count: 64),
      sourceRevision: "7125cda",
      sourceChangeID: "CHG-2026-046",
      sourceTaskID: "TASK-RTC-001")
    let fullDecoded = try RuntimeOperationCodec.decodeBundleManifest(
      try RuntimeOperationCodec.encodeBundleManifest(full))
    XCTAssertEqual(fullDecoded, full)
  }

  func testBundleManifestRejectsMalformedDigest() {
    XCTAssertThrowsError(
      try PublishedOperationBundleManifest(
        operation: RuntimeOperationReference(id: "observe.device", version: 1),
        catalogDigest: "not-a-digest"))
  }

}
