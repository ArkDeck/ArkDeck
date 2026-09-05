import Foundation
import XCTest
@testable import ArkDeckCore

final class ControlProtocolContractTests: XCTestCase {
  private func data(_ fields: [String: JSONValue]) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(fields)
  }

  func testOnlyCurrentExactVersionAndIdentityAreAccepted() throws {
    let frame = try ArkDeckAgentXPC.requestFrame(method: "health", requestID: "req-1")
    let good = try ControlProtocolContract.requestFields(frame)
    for version in ["1", "1.0", "1.1.0", "1.0.1", "2.0.0", "01.0.0", "1.0.0+build", ""] {
      var bad = good; bad["protocolVersion"] = .string(version)
      XCTAssertThrowsError(try ControlProtocolContract.requestFields(data(bad)), version)
    }
    for identity: JSONValue? in [nil, .null, .string("old-build")] {
      var bad = good; bad["contractIdentity"] = identity
      XCTAssertThrowsError(try ControlProtocolContract.requestFields(data(bad)))
    }
    for key in ["credentials", "supportedExactVersions", "requiredMajor", "bootstrapVersion"] {
      var bad = good; bad[key] = .null
      XCTAssertThrowsError(try ControlProtocolContract.requestFields(data(bad)), key)
    }
  }

  func testHealthRequiresCurrentShapeIdentityAndCompleteMethodSet() throws {
    let health: [String: JSONValue] = [
      "status": .string("ok"), "protocolVersion": .string(ArkDeckControlProtocol.currentVersion),
      "contractIdentity": .string(ArkDeckControlProtocol.contractIdentity),
      "publishedMethods": .array(ArkDeckControlProtocol.methods.sorted().map(JSONValue.string)),
      "catalogDigest": .string(String(repeating: "a", count: 64)), "providers": .array([]),
    ]
    func response(_ fields: [String: JSONValue]) throws -> Data {
      try data(["id": .string("req-1"), "ok": .bool(true), "result": .object(fields)])
    }
    try ControlProtocolContract.validateHealth(response(health), id: "req-1")
    for key in health.keys {
      var bad = health; bad.removeValue(forKey: key)
      XCTAssertThrowsError(try ControlProtocolContract.validateHealth(response(bad), id: "req-1"), key)
    }
    for (key, value) in [("contractIdentity", JSONValue.string("same-version-old-build")),
      ("publishedMethods", .array([.string("health")])), ("protocolVersion", .string("2.0.0")),
      ("supportedExactVersions", .array([.string("1.0.0")]))] {
      var bad = health; bad[key] = value
      XCTAssertThrowsError(try ControlProtocolContract.validateHealth(response(bad), id: "req-1"), key)
    }
    XCTAssertThrowsError(try ControlProtocolContract.validateHealth(response(health), id: "another-id"))
  }

  func testResponsesHaveOneClosedSuccessOrFailureShape() throws {
    let good: [String: JSONValue] = ["id": .string("req-1"), "ok": .bool(true), "result": .null]
    _ = try ControlProtocolContract.responseFields(data(good), id: "req-1")
    for (key, value) in [("error", JSONValue.null), ("id", .string("other")), ("ok", .integer(1))] {
      var bad = good; bad[key] = value
      XCTAssertThrowsError(try ControlProtocolContract.responseFields(data(bad), id: "req-1"))
    }
    var failure: [String: JSONValue] = ["id": .string("req-1"), "ok": .bool(false),
      "error": .object(["code": .string("rejected"), "message": .string("reason"),
        "details": .object(["phase": .string("preAdmission"), "newDispatchCount": .integer(0)])])]
    _ = try ControlProtocolContract.responseFields(data(failure), id: "req-1")
    failure["result"] = .null
    XCTAssertThrowsError(try ControlProtocolContract.responseFields(data(failure), id: "req-1"))
  }

  func testDuplicateKeysInvalidUnicodeAndExtraFramesAreRejected() throws {
    let bodies = [
      #"{"a":1,"a":2}"#,
      #"{"a":1,"\u0061":2}"#,
      #"{"nested":{"a":1,"a":2}}"#,
      #"{"a":"\ud800"}"#,
      #"{"a":"\udc00"}"#,
      "{}\n{}", "{}\r", "{} trailing",
    ]
    for body in bodies {
      XCTAssertThrowsError(
        try ControlFrameJSON.decodeObject(
          Data(body.utf8), maximumBytes: 65536), body)
    }
    XCTAssertThrowsError(
      try ControlFrameJSON.decodeObject(
        Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]), maximumBytes: 65536))
    _ = try ControlFrameJSON.decodeObject(
      Data(#"{"emoji":"\ud83d\ude00","nfd":"e\u0301","nfc":"é"}"#.utf8), maximumBytes: 65536)
  }

  func testControlFrameLimitIncludesItsLineTerminator() throws {
    let body = Data((#"{"padding":""# + String(repeating: "x", count: 65521) + #""}"#).utf8)
    XCTAssertEqual(body.count + 1, 65536)
    _ = try ControlFrameJSON.decodeObject(body, maximumBytes: 65536)
    XCTAssertThrowsError(
      try ControlFrameJSON.decodeObject(
        body + Data(" ".utf8), maximumBytes: 65536))
  }

}
