import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckWorkflows

final class RuntimeOperationContractTests: XCTestCase {
  private func minimalJSON(extra: String = "") -> Data {
    Data(
      """
      {
        "documentType": "runtime-operation-request",
        "schemaVersion": "1.0.0",
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

  func testCodecDirectDecoderAndDurableJobUseTheSameCurrentContract() throws {
    let request = try RuntimeOperationCodec.decodeRequest(minimalJSON())
    let record = RuntimeJobRecord(
      jobID: "job-strict-request", request: request, operationReference: "observe.device@1",
      catalogDigest: RuntimeOperationCatalog.catalogDigest, providerID: "hdc",
      createdAtUTC: "2026-09-05T00:00:00Z", actualEffect: "readOnly",
      materializedPlanDigest: nil, materializedStableTargetIdentitySHA256: nil,
      materializedBindingRevision: nil)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try record.persist(into: directory)
    XCTAssertEqual(try RuntimeJobRecord.load(from: directory).request, request)
    XCTAssertEqual(try JSONDecoder().decode(RuntimeOperationRequest.self, from: minimalJSON()), request)

    let valid = try JSONDecoder().decode([String: JSONValue].self, from: minimalJSON())
    var negatives: [[String: JSONValue]] = []
    for version in [JSONValue.null, .integer(1), .string("1.7.3"), .string("2.0.0")] {
      var fields = valid
      fields["schemaVersion"] = version
      negatives.append(fields)
    }
    var missing = valid
    missing.removeValue(forKey: "schemaVersion")
    negatives.append(missing)
    for key in ["campaignReservation", "standingAuthorization", "evolutionCampaignConfirmation",
                "chatConfirmation", "campaign_reservation", "futureMinorField", "changeId"] {
      var fields = valid
      fields[key] = .null // Presence, even null, must never fall through to default admission.
      negatives.append(fields)
    }
    for key in ["target", "operation", "authorization", "clientContext"] {
      var fields = valid
      var nested: [String: JSONValue] = [:]
      if case .object(let existing)? = fields[key] { nested = existing }
      nested["standingAuthorization"] = .object([:])
      fields[key] = .object(nested)
      negatives.append(fields)
    }
    for fields in negatives {
      let bytes = try CanonicalJSONEncoders.canonical().encode(fields)
      XCTAssertThrowsError(try RuntimeOperationCodec.decodeRequest(bytes))
      XCTAssertThrowsError(try JSONDecoder().decode(RuntimeOperationRequest.self, from: bytes))
      for field in ["request", "originalSubmissionRequest"] {
        var job = try JSONDecoder().decode([String: JSONValue].self, from: record.durableData())
        job[field] = .object(fields)
        try CanonicalJSONEncoders.canonical().encode(job).write(
          to: directory.appending(path: "job-record.json"))
        XCTAssertThrowsError(try RuntimeJobRecord.load(from: directory), field)
      }
    }
  }

  func testReviewedPlanPreconditionRemainsExplicitAndDoesNotAlterOperationFingerprint() throws {
    let fields = ",\n  \"reviewedPlanDigest\": \"\(String(repeating: "a", count: 64))\""
    XCTAssertEqual(
      try RuntimeOperationCodec.decodeRequest(minimalJSON(extra: fields)),
      try RuntimeOperationCodec.decodeRequest(minimalJSON()))
    assertRejected(minimalJSON(extra: ",\n  \"reviewedPlanDigest\": null"), code: .invalidRequest)
    assertRejected(minimalJSON(extra: ",\n  \"reviewedPlanDigest\": \"bad\""), code: .invalidRequest)
  }

  func testOperationFailureRoundTripUsesClosedMachineReadableFacts() throws {
    let failure = RuntimeOperationFailure(
      code: .outcomeUnknown,
      category: .unknownOutcome,
      retryability: .runtimeDecisionRequired,
      recovery: .awaitRuntimeReconciliation)
    let data = try JSONEncoder().encode(failure)
    let decoded = try JSONDecoder().decode(RuntimeOperationFailure.self, from: data)

    XCTAssertEqual(decoded, failure)
    XCTAssertEqual(decoded.schemaVersion, "1.0.0")
    XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("summary") == true)
    XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("diagnostic") == true)
  }

  func testDAYU200SingletonRequestOmitsVersionOnTheWire() throws {
    let request = try RuntimeOperationRequest(
      requestID: "req-flash-singleton",
      idempotencyKey: "idem-flash-singleton",
      target: DurableTargetReference(targetID: "TGT-DAYU200-01"),
      operation: RuntimeOperationReference(id: "flash.dayu200"))
    let encoded = try RuntimeOperationCodec.encodeRequest(request)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let operation = try XCTUnwrap(object["operation"] as? [String: Any])
    XCTAssertEqual(operation["id"] as? String, "flash.dayu200")
    XCTAssertNil(operation["version"])
    XCTAssertEqual(
      try RuntimeOperationCodec.decodeRequest(encoded).operation.reference,
      "flash.dayu200")
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

  func testOnlyExactCurrentVersionIsAccepted() {
    for version in ["1.7.3", "2.0.0", "3.0.0", "10.2.1", "x.0.0", "1", "1.0", ""] {
      let data = Data(
        String(decoding: minimalJSON(), as: UTF8.self)
          .replacingOccurrences(of: "\"1.0.0\"", with: "\"\(version)\"").utf8)
      assertRejected(data, code: .unsupportedVersion)
    }
  }

  func testUnknownTopLevelKeyIsRejected() {
    assertRejected(minimalJSON(extra: ",\n  \"futureMinorField\": {\"x\": 1}"), code: .invalidRequest)
  }

  func testDuplicateJSONKeysAreRejected() {
    let data = Data(
      """
      {
        "schemaVersion": "1.0.0",
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
        .replacingOccurrences(of: "\"schemaVersion\": \"1.0.0\",", with: "").utf8)
    assertRejected(data, code: .unsupportedVersion)
  }

  // MARK: - A rejection has to say what to fix

  /// The negatives above assert only `code`, which an answer of `path: "$"`
  /// carrying a reflected Swift `DecodingError` satisfies just as well. These
  /// assert the two halves a caller actually reads.
  ///
  /// The version half is deliberately not "the message contains 1.0.0" and not
  /// "the message contains the constant the code read" — both pass while the
  /// advertised value is one admission rejects. It takes the version out of
  /// the refusal, builds a request with it, and requires that request to
  /// decode.
  func testAVersionRefusalNamesAVersionThatThenWorks() throws {
    let withoutVersion = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(of: "\"schemaVersion\": \"1.0.0\",", with: "").utf8)
    let wrongMajor = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(of: "\"1.0.0\"", with: "\"2.0.0\"").utf8)
    let malformed = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(of: "\"1.0.0\"", with: "\"not-a-version\"").utf8)

    for (label, data) in [
      ("missing", withoutVersion), ("wrong major", wrongMajor), ("malformed", malformed),
    ] {
      var reported: String?
      XCTAssertThrowsError(try RuntimeOperationCodec.decodeRequest(data), label) { error in
        guard let rejection = error as? RuntimeOperationRequestRejection else {
          return XCTFail("\(label): expected a typed rejection, got \(error)")
        }
        XCTAssertEqual(rejection.code, .unsupportedVersion, label)
        XCTAssertEqual(rejection.path, "$.schemaVersion", label)
        reported = Self.firstQuotedVersion(in: rejection.message)
      }
      let suggested = try XCTUnwrap(
        reported, "\(label): the refusal names no version the caller could use")
      let repaired = Data(
        String(decoding: minimalJSON(), as: UTF8.self)
          .replacingOccurrences(of: "\"1.0.0\"", with: "\"\(suggested)\"").utf8)
      XCTAssertNoThrow(
        try RuntimeOperationCodec.decodeRequest(repaired),
        "\(label): the version the refusal named is itself refused")
    }
  }

  func testEachRequiredKeyIsRefusedAtItsOwnPathWithoutLeakingDecodingError() {
    let required: [(line: String, path: String)] = [
      ("\"requestId\": \"req-001\",", "$.requestId"),
      ("\"idempotencyKey\": \"idem-0001\",", "$.idempotencyKey"),
      ("\"target\": { \"targetId\": \"TGT-DAYU200-01\" },", "$.target"),
      ("\"operation\": { \"id\": \"observe.device\", \"version\": 1 }", "$.operation"),
    ]
    for (line, path) in required {
      var text = String(decoding: minimalJSON(), as: UTF8.self)
      XCTAssertTrue(text.contains(line), "fixture drifted; \(line) is no longer present")
      text = text.replacingOccurrences(of: line, with: "")
      // Removing the last entry leaves a dangling comma before the closing
      // brace. Left in place the document is malformed, and `path: "$"` would
      // then be the correct answer — the assertion below would be measuring
      // the fixture rather than the contract.
      text = text.replacingOccurrences(
        of: ",\\s*\\n\\s*\\}", with: "\n}", options: .regularExpression)
      XCTAssertNotNil(
        try? JSONSerialization.jsonObject(with: Data(text.utf8)),
        "\(path): the fixture must stay well-formed JSON so the refusal is about the key")
      XCTAssertThrowsError(
        try RuntimeOperationCodec.decodeRequest(Data(text.utf8)), path
      ) { error in
        guard let rejection = error as? RuntimeOperationRequestRejection else {
          return XCTFail("\(path): expected a typed rejection, got \(error)")
        }
        XCTAssertEqual(rejection.code, .invalidRequest, path)
        XCTAssertEqual(
          rejection.path, path,
          "a caller that reads `path` to know what to fix must be told this key")
        for leak in ["DecodingError", "CodingKeys", "Swift."] {
          XCTAssertFalse(
            rejection.message.contains(leak),
            "\(path): the refusal leaks Swift's internal spelling (\(leak)): "
              + rejection.message)
        }
      }
    }
  }

  /// Naming the key must not cost the precision the nested models already
  /// had: a present-but-invalid `target` still answers for the exact field.
  func testANestedModelStillReportsItsOwnFieldRatherThanTheKeyAboveIt() {
    let data = Data(
      String(decoding: minimalJSON(), as: UTF8.self)
        .replacingOccurrences(
          of: "\"target\": { \"targetId\": \"TGT-DAYU200-01\" },",
          with: "\"target\": { \"targetId\": \"\" },").utf8)
    XCTAssertThrowsError(try RuntimeOperationCodec.decodeRequest(data)) { error in
      XCTAssertEqual(
        (error as? RuntimeOperationRequestRejection)?.path, "$.target.targetId")
    }
  }

  private static func firstQuotedVersion(in message: String) -> String? {
    var rest = Substring(message)
    while let open = rest.firstIndex(of: "\"") {
      let body = rest[rest.index(after: open)...]
      guard let close = body.firstIndex(of: "\"") else { return nil }
      let candidate = body[body.startIndex..<close]
      if candidate.contains("."), candidate.allSatisfy({ $0.isNumber || $0 == "." }) {
        return String(candidate)
      }
      rest = body[body.index(after: close)...]
    }
    return nil
  }

  func testOversizedRequestIsRejected() {
    var text = String(decoding: minimalJSON(extra: ",\n  \"pad\": \"@\""), as: UTF8.self)
    text = text.replacingOccurrences(
      of: "\"@\"",
      with: "\"\(String(repeating: "x", count: RuntimeOperationCodec.maximumRequestBytes))\"")
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

  // MARK: - The envelope is not the caller's problem

  /// The flag form used to express only target and operation, so any
  /// operation with typed inputs — nearly all of them — forced the caller to
  /// hand-write the whole current document. The envelope around those inputs then
  /// cost one refusal per field to learn.
  ///
  /// Asserted as byte equality against the hand-written document rather than
  /// by inspecting fields: the point is that the two produce the *same*
  /// request, so a caller gains nothing by writing it themselves.
  func testTheFlagFormWithInputsProducesTheSameDocumentAsWritingItByHand() throws {
    let byHand = try RuntimeOperationCodec.decodeRequest(
      Data(
        """
        {
          "documentType": "runtime-operation-request",
          "schemaVersion": "1.0.0",
          "requestId": "req-envelope",
          "idempotencyKey": "idem-envelope-01",
          "target": { "targetId": "TGT-DAYU200-01", "expectedBindingRevision": 7 },
          "operation": { "id": "capture.diagnostics", "version": 1 },
          "inputs": { "durationSeconds": 30, "hilogFilters": ["ArkUI:Info"] }
        }
        """.utf8))
    let fromFlags = try RuntimeOperationRequest.operatorFlagForm(
      targetID: "TGT-DAYU200-01",
      expectedBindingRevision: 7,
      operationID: "capture.diagnostics",
      version: 1,
      inputs: [
        "durationSeconds": .integer(30),
        "hilogFilters": .array([.string("ArkUI:Info")]),
      ],
      requestID: "req-envelope",
      idempotencyKey: "idem-envelope-01")

    XCTAssertEqual(
      try RuntimeOperationCodec.encodeRequest(fromFlags),
      try RuntimeOperationCodec.encodeRequest(byHand),
      "the CLI-built envelope must be the document a caller would have written")
  }

  /// The rules a caller keeps getting wrong stay owned by the request model,
  /// so the flag form refuses in its words rather than inventing a second
  /// message that could drift from it.
  func testTheFlagFormKeepsTheBindingRulesAndTheirWording() {
    XCTAssertThrowsError(
      try RuntimeOperationRequest.operatorFlagForm(
        targetID: "TGT-DAYU200-01",
        expectedBindingRevision: nil,
        operationID: "capture.diagnostics",
        version: 1,
        inputs: ["durationSeconds": .integer(30)],
        requestID: "req-unpinned",
        idempotencyKey: "idem-unpinned-01")
    ) { error in
      let rejection = error as? RuntimeOperationRequestRejection
      XCTAssertEqual(rejection?.path, "$.target.expectedBindingRevision")
      XCTAssertTrue(
        rejection?.message.contains("--expected-binding-revision") == true,
        "the refusal must name the flag that fixes it: \(rejection?.message ?? "-")")
    }

    XCTAssertThrowsError(
      try RuntimeOperationRequest.operatorFlagForm(
        targetID: "TGT-1",
        expectedBindingRevision: 7,
        operationID: "workspace.inspect-source",
        version: 1,
        requestID: "req-host-only",
        idempotencyKey: "idem-host-only-01")
    ) { error in
      XCTAssertTrue(
        (error as? RuntimeOperationRequestRejection)?.message.contains("host-only") == true)
    }
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
