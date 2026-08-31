import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// §6.1's `operation validate`: the local half of "will this be accepted".
///
/// The check is structural on purpose. It answers the one question the
/// published descriptor fully describes — does this document match the field
/// contract — and says so; the Runtime still validates plan materialization,
/// capability, binding and freshness. Claiming more would be worse than
/// claiming nothing, because a caller who reads "valid" as "will run" finds out
/// otherwise only after dispatch.
final class CLIOperationInputValidationContractTests: XCTestCase {

  private func field(
    _ name: String, type: String, required: Bool = false, extra: [String: JSONValue] = [:]
  ) -> JSONValue {
    var fields: [String: JSONValue] = [
      "name": .string(name), "type": .string(type), "required": .bool(required),
    ]
    for (key, value) in extra { fields[key] = value }
    return .object(fields)
  }

  private func findings(_ document: JSONValue, _ inputs: [JSONValue]) -> [String] {
    CLIOperationInputValidation.findings(for: document, against: inputs).map(\.code)
  }

  func testAMatchingDocumentProducesNoFindings() {
    let inputs = [
      field("durationSeconds", type: "integer", required: true),
      field("label", type: "string"),
    ]
    XCTAssertEqual(
      findings(.object(["durationSeconds": .integer(5), "label": .string("a")]), inputs), [])
    // An optional field may simply be absent.
    XCTAssertEqual(findings(.object(["durationSeconds": .integer(5)]), inputs), [])
  }

  func testAMissingRequiredFieldIsReportedByName() {
    let found = CLIOperationInputValidation.findings(
      for: .object([:]), against: [field("target", type: "string", required: true)])
    XCTAssertEqual(found.map(\.code), ["missingRequired"])
    XCTAssertEqual(found.first?.field, "target")
  }

  /// §5.3 makes the input document exact. An unrecognised key is a caller
  /// mistake, not decoration to ignore — reporting it is the difference
  /// between finding a typo before dispatch and finding it after.
  func testAnUnknownFieldIsReportedRatherThanIgnored() {
    XCTAssertEqual(
      findings(.object(["typo": .string("x")]), [field("target", type: "string")]),
      ["unknownField"])
  }

  func testTypesAreCheckedAgainstTheCatalogVocabulary() {
    XCTAssertEqual(
      findings(.object(["n": .string("5")]), [field("n", type: "integer")]), ["typeMismatch"])
    XCTAssertEqual(
      findings(.object(["n": .integer(5)]), [field("n", type: "string")]), ["typeMismatch"])
    XCTAssertEqual(
      findings(.object(["n": .bool(true)]), [field("n", type: "boolean")]), [])
    XCTAssertEqual(
      findings(.object(["n": .array([.string("a")])]), [field("n", type: "stringArray")]), [])
    XCTAssertEqual(
      findings(.object(["n": .array([.integer(1)])]), [field("n", type: "stringArray")]),
      ["typeMismatch"])
    // Every catalog field type must be understood; an unhandled one would pass
    // anything through as valid.
    for type in CatalogFieldType.allCases {
      _ = findings(.object(["n": .string("x")]), [field("n", type: type.rawValue)])
    }
  }

  /// Once the type is wrong the remaining checks would read the value as
  /// something it is not, so they would only restate the same problem.
  func testAWrongTypeSuppressesTheChecksThatDependOnIt() {
    XCTAssertEqual(
      findings(
        .object(["n": .string("x")]),
        [field("n", type: "integer", extra: ["minimum": .integer(10)])]),
      ["typeMismatch"])
  }

  func testBoundsEnumerationsAndPatternsAreChecked() {
    XCTAssertEqual(
      findings(
        .object(["n": .integer(1)]),
        [field("n", type: "integer", extra: ["minimum": .integer(2)])]),
      ["outOfRange"])
    XCTAssertEqual(
      findings(
        .object(["n": .integer(9)]),
        [field("n", type: "integer", extra: ["maximum": .integer(2)])]),
      ["outOfRange"])
    XCTAssertEqual(
      findings(
        .object(["s": .string("no")]),
        [field("s", type: "string", extra: ["enum": .array([.string("yes")])])]),
      ["notInEnum"])
    XCTAssertEqual(
      findings(
        .object(["s": .string("abcd")]),
        [field("s", type: "string", extra: ["maxLength": .integer(3)])]),
      ["tooLong"])
    XCTAssertEqual(
      findings(
        .object(["s": .array([.string("a"), .string("b")])]),
        [field("s", type: "stringArray", extra: ["maxItems": .integer(1)])]),
      ["tooManyItems"])
  }

  /// A pattern is a whole-value contract. An unanchored search would accept a
  /// value that merely contains a match, which is how a field meant to hold an
  /// identity ends up holding a sentence with an identity in it.
  func testAPatternMustMatchTheWholeValue() {
    let pattern = field("s", type: "string", extra: ["pattern": .string("[a-z]+")])
    XCTAssertEqual(findings(.object(["s": .string("abc")]), [pattern]), [])
    XCTAssertEqual(findings(.object(["s": .string("abc1")]), [pattern]), ["patternMismatch"])
    XCTAssertEqual(findings(.object(["s": .string("1abc")]), [pattern]), ["patternMismatch"])
  }

  /// A pattern this build cannot compile is not the caller's mistake, and
  /// reporting it as one would refuse a document the Runtime accepts.
  func testAnUncompilablePatternDoesNotRefuseTheDocument() {
    XCTAssertEqual(
      findings(
        .object(["s": .string("anything")]),
        [field("s", type: "string", extra: ["pattern": .string("[unterminated")])]),
      [])
  }

  func testANonObjectDocumentIsRefusedAtTheRoot() {
    XCTAssertEqual(findings(.array([]), []), ["notAnObject"])
    XCTAssertEqual(findings(.string("{}"), []), ["notAnObject"])
  }
}
