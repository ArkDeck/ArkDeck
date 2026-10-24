import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore

final class OracleSDKDiagnosticCompatibilityTests: XCTestCase {
  private let oldType = "undecodable current request: DecodingError.typeMismatch: expected value of type String. Path: inputs. Debug description: Expected to decode String but found number instead."
  private let newType = "undecodable current request: DecodingError.typeMismatch: Expected value of type String. Path: inputs. Debug description: Expected to decode String but found number instead."
  private let oldNull = "undecodable current request: DecodingError.valueNotFound: Expected value of type String but found null instead. Path: inputs. Debug description: Cannot get value of type String -- found null value instead"
  private let newNull = "undecodable current request: DecodingError.valueNotFound: Expected value of type String. Path: inputs. Debug description: Cannot get value of type String -- found null value instead"

  private func encode(_ value: JSONValue, newline: Bool = false) throws -> Data {
    try CanonicalJSONEncoders.canonicalPretty().encode(value) + (newline ? Data("\n".utf8) : Data())
  }

  private func document(_ message: String, code: String = "invalidInput", dispatch: Int64 = 0,
    result: String = "unchanged", otherMessage: String = "untouched", exchanges: Bool = false
  ) -> JSONValue {
    let row: JSONValue = .object([
      "response": .object([
        "ok": .bool(false),
        "error": .object(["code": .string(code), "message": .string(message),
          "details": .object(["newDispatchCount": .integer(dispatch)])]),
        "result": .string(result),
      ]), "params": .object(["message": .string(otherMessage)]),
    ])
    return .array(exchanges ? [.object(["exchanges": .array([row])])] : [row])
  }

  private func files(_ value: JSONValue, jobPlan: Bool = false) throws -> [String: Data] {
    let cases = try encode(value, newline: jobPlan)
    var result = ["cases.json": cases, "durable.json": Data("immutable bytes".utf8)]
    if jobPlan {
      result["provenance.json"] = try encode(.object([
        "producer": .string("test"),
        "files": .object(["cases.json": .string(digest(cases))]),
      ]), newline: true)
    }
    return result
  }

  private func digest(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
  }

  private func compared(_ value: JSONValue) throws -> [String: Data] {
    try OracleSDKDiagnosticCompatibility.comparableFiles(files(value), family: .artifactQuota)
  }

  func testOnlyTheTwoObservedSDKSpellingsAreCompatible() throws {
    for (old, new) in [(oldType, newType), (oldNull, newNull)] {
      XCTAssertEqual(try compared(document(old)), try compared(document(new)))
      let oldFiles = try files(document(old, exchanges: true))
      let newFiles = try files(document(new, exchanges: true))
      XCTAssertEqual(
        try OracleSDKDiagnosticCompatibility.comparableFiles(oldFiles, family: .capabilityRead),
        try OracleSDKDiagnosticCompatibility.comparableFiles(newFiles, family: .capabilityRead))
    }
  }

  func testCodesProofDetailsAndResultsRemainExact() throws {
    let expected = try compared(document(oldType))
    XCTAssertNotEqual(expected, try compared(document(newType, code: "admissionDenied")))
    XCTAssertNotEqual(expected, try compared(document(newType, dispatch: 1)))
    XCTAssertNotEqual(expected, try compared(document(newType, result: "changed")))
  }

  func testOtherMessagesAndUnknownDiagnosticChangesRemainExact() throws {
    XCTAssertNotEqual(try compared(document(oldType)), try compared(document(newType + " extra")))
    XCTAssertNotEqual(
      try compared(document(oldType, otherMessage: oldType)),
      try compared(document(newType, otherMessage: newType)))
    XCTAssertNotEqual(
      try compared(document(oldNull)),
      try compared(document(newNull.replacingOccurrences(of: "found null value instead", with: "unknown"))))
    XCTAssertNotEqual(
      try compared(document(oldType.replacingOccurrences(of: "String", with: "UnknownSDKType"))),
      try compared(document(newType.replacingOccurrences(of: "String", with: "UnknownSDKType"))))
  }

  func testFormattingAndDurableBytesAreNotNormalized() throws {
    var actual = try files(document(newType))
    actual["cases.json"]!.append(Data("\n".utf8))
    XCTAssertThrowsError(try OracleSDKDiagnosticCompatibility.comparableFiles(actual, family: .artifactQuota))
    actual = try files(document(newType))
    actual["cases.json"] = Data(" \(String(decoding: actual["cases.json"]!, as: UTF8.self))".utf8)
    XCTAssertThrowsError(try OracleSDKDiagnosticCompatibility.comparableFiles(actual, family: .artifactQuota))
    actual = try files(document(newType))
    actual["durable.json"] = Data("different bytes".utf8)
    XCTAssertNotEqual(try compared(document(oldType)),
      try OracleSDKDiagnosticCompatibility.comparableFiles(actual, family: .artifactQuota))
  }

  func testProvenanceFirstAuthenticatesEachSidesRawCases() throws {
    let expected = try files(document(oldNull), jobPlan: true)
    let actual = try files(document(newNull), jobPlan: true)
    XCTAssertNotEqual(expected["provenance.json"], actual["provenance.json"])
    XCTAssertEqual(
      try OracleSDKDiagnosticCompatibility.comparableFiles(expected, family: .jobPlanAnalyzer),
      try OracleSDKDiagnosticCompatibility.comparableFiles(actual, family: .jobPlanAnalyzer))
    var tampered = actual
    tampered["provenance.json"] = expected["provenance.json"]
    XCTAssertThrowsError(try OracleSDKDiagnosticCompatibility.comparableFiles(tampered, family: .jobPlanAnalyzer))
    tampered = actual
    tampered["provenance.json"]!.append(Data(" ".utf8))
    XCTAssertThrowsError(try OracleSDKDiagnosticCompatibility.comparableFiles(tampered, family: .jobPlanAnalyzer))
    tampered = actual
    tampered["provenance.json"] = try encode(.object([
      "producer": .string("different"),
      "files": .object(["cases.json": .string(digest(actual["cases.json"]!))]),
    ]), newline: true)
    XCTAssertNotEqual(
      try OracleSDKDiagnosticCompatibility.comparableFiles(expected, family: .jobPlanAnalyzer),
      try OracleSDKDiagnosticCompatibility.comparableFiles(tampered, family: .jobPlanAnalyzer))
  }
}
