import Foundation
import XCTest

@testable import ArkDeckCore

final class ControlProtocolNegotiationContractTests: XCTestCase {
  private func data(_ object: [String: JSONValue]) throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(object)
  }

  private func request(
    versions: [String] = ["2.0.0", "1.0.0"], major: Int64 = 2
  ) -> [String: JSONValue] {
    [
      "bootstrapVersion": .string("arkdeck.control.negotiation/1"),
      "id": .string("request-1"), "method": .string("protocol.negotiate"),
      "supportedExactVersions": .array(versions.map(JSONValue.string)),
      "requiredMajor": .integer(major),
    ]
  }

  private func response(_ request: [String: JSONValue]) throws -> [String: JSONValue] {
    let bytes = try XCTUnwrap(ControlProtocolNegotiation.responseIfBootstrap(data(request)))
    return try JSONDecoder().decode([String: JSONValue].self, from: bytes)
  }

  func testSelectsHighestCommonExactVersionWithinTheRequiredMajor() throws {
    XCTAssertEqual(
      try ControlProtocolNegotiation.select(
        client: ["3.0.0", "2.11.0", "2.9.1", "2.0.0", "1.0.0"],
        daemon: ["2.12.0", "2.11.0", "2.9.1", "1.0.0"], requiredMajor: 2), "2.11.0")
    XCTAssertEqual(
      try ControlProtocolNegotiation.select(
        client: ["2.0.0", "1.0.0"], daemon: ["2.0.0", "1.0.0"], requiredMajor: 1), "1.0.0")
    XCTAssertThrowsError(
      try ControlProtocolNegotiation.select(
        client: ["2.0.0", "1.0.0"], daemon: ["1.0.0"], requiredMajor: 2)
    ) {
      XCTAssertEqual($0 as? ControlProtocolNegotiation.Failure, .unsupported)
    }
  }

  func testRejectsMalformedOrNonCanonicalVersionLists() {
    let invalid: [[String]] = [
      [], ["2.0.0", "2.0.0"], ["1.0.0", "2.0.0"], ["2.9.0", "2.10.0"],
      ["02.0.0"], ["2.00.0"], ["2.0.00"], ["2.0"], ["2.0.0.1"], ["+2.0.0"],
      ["2.0.0-alpha"], ["2.0.0+build"], ["２.0.0"], ["2.0.0 "],
      ["18446744073709551616.0.0"],
    ]
    for versions in invalid {
      XCTAssertThrowsError(try ControlProtocolNegotiation.validateVersions(versions), "\(versions)")
    }
  }

  func testBootstrapSuccessAndNoCommonReplyHaveClosedShapes() throws {
    let accepted = try response(request())
    XCTAssertEqual(accepted["ok"], .bool(true))
    XCTAssertEqual(accepted["selectedExactVersion"], .string("2.0.0"))
    XCTAssertEqual(
      Set(accepted.keys),
      [
        "bootstrapVersion", "id", "ok", "selectedExactVersion", "daemonSupportedExactVersions",
      ])
    let refused = try response(request(versions: ["3.0.0"], major: 3))
    XCTAssertEqual(refused["ok"], .bool(false))
    XCTAssertNil(refused["selectedExactVersion"])
    XCTAssertEqual(refused["error"], .object(["code": .string("protocolVersionUnsupported")]))
  }

  func testBootstrapCannotCarryADomainRequestOrAuthority() throws {
    for field in ["protocolVersion", "params", "credentials", "idempotencyKey", "requestJson"] {
      var object = request()
      object[field] = .string("must-not-be-dispatched")
      let refused = try response(object)
      XCTAssertEqual(refused["ok"], .bool(false), field)
      XCTAssertEqual(refused["error"], .object(["code": .string("protocolMalformed")]), field)
    }
    for value in [JSONValue.integer(1), .null, .string(""), .string("line\nbreak")] {
      var object = request()
      object["id"] = value
      XCTAssertEqual(try response(object)["ok"], .bool(false))
    }
  }

  func testClientVerifiesResponseIdentityExactSelectionAndShape() throws {
    let good = try response(request())
    XCTAssertEqual(
      try ControlProtocolNegotiation.selectedVersion(
        response: data(good), id: "request-1", requiredMajor: 2), "2.0.0")
    let mutations: [(String, JSONValue)] = [
      ("id", .string("another-request")),
      ("selectedExactVersion", .string("1.0.0")),
      ("selectedExactVersion", .string("2.1.0")),
      ("daemonSupportedExactVersions", .array([.string("1.0.0")])),
      ("daemonSupportedExactVersions", .array([.string("1.0.0"), .string("2.0.0")])),
      ("result", .object([:])),
      ("bootstrapVersion", .string("arkdeck.control.negotiation/2")),
    ]
    for (field, value) in mutations {
      var bad = good
      bad[field] = value
      XCTAssertThrowsError(
        try ControlProtocolNegotiation.selectedVersion(
          response: data(bad), id: "request-1", requiredMajor: 2), field)
    }
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
        try ControlProtocolNegotiation.decodeObject(
          Data(body.utf8), maximumBytes: 65536), body)
    }
    XCTAssertThrowsError(
      try ControlProtocolNegotiation.decodeObject(
        Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]), maximumBytes: 65536))
    _ = try ControlProtocolNegotiation.decodeObject(
      Data(#"{"emoji":"\ud83d\ude00","nfd":"e\u0301","nfc":"é"}"#.utf8), maximumBytes: 65536)
  }

  func testBootstrapFrameLimitIncludesItsLineTerminator() throws {
    let body = Data((#"{"padding":""# + String(repeating: "x", count: 65521) + #""}"#).utf8)
    XCTAssertEqual(body.count + 1, 65536)
    _ = try ControlProtocolNegotiation.decodeObject(body, maximumBytes: 65536)
    XCTAssertThrowsError(
      try ControlProtocolNegotiation.decodeObject(
        body + Data(" ".utf8), maximumBytes: 65536))
  }

  func testLegacyFallbackRecognizesOnlyAnExactPreBootstrapRefusal() throws {
    let old: [String: JSONValue] = [
      "id": .string("-"), "ok": .bool(false),
      "error": .object([
        "code": .string("malformedFrame"), "message": .string("undecodable request frame"),
      ]),
    ]
    XCTAssertTrue(ControlProtocolNegotiation.isPreBootstrapRefusal(try data(old)))
    for code in ["unknownMethod", "rejected", "internalError", "unsupportedProtocolVersion"] {
      var changed = old
      changed["error"] = .object(["code": .string(code), "message": .string("old daemon")])
      XCTAssertFalse(ControlProtocolNegotiation.isPreBootstrapRefusal(try data(changed)))
    }
    var changed = old
    changed["id"] = .string("request-1")
    XCTAssertFalse(ControlProtocolNegotiation.isPreBootstrapRefusal(try data(changed)))
  }
}
