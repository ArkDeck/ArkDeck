import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore

/// The bytes Swift's legacy `--json` rendering writes, recorded for the Rust
/// CLI to replay (`rust/crates/arkdeck-cli/tests/legacy_json.rs`).
///
/// Each case is a value and `CLIRuntimeSession.legacyDocument` of it. The
/// values cover what the format turns on: empty containers, nesting and key
/// order, 64-bit integers, Foundation's spelling of a `Double`, and the escapes
/// of a string (a solidus, a quote, C0 controls, DEL, U+2028, non-ASCII). Each
/// failure is a code and words, and the legacy document of
/// `CLIResultEnvelope.legacyFailure`.
///
/// Record a new oracle with
/// `ARKDECK_RUST_LEGACY_JSON_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLILegacyJSONOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/legacy-json", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_LEGACY_JSON_RECORD"

  func testSwiftLegacyDocumentsTheRustCLIReplays() throws {
    let values: [(String, JSONValue)] = [
      ("emptyObject", .object([:])),
      ("emptyArray", .array([])),
      (
        "scalars",
        .object([
          "null": .null, "true": .bool(true), "false": .bool(false), "zero": .integer(0),
          "negative": .integer(-42), "int64Max": .integer(Int64.max),
          "int64Min": .integer(Int64.min), "uint64Max": .unsignedInteger(UInt64.max),
        ])
      ),
      (
        "numbers",
        .array([
          .number(1.5), .number(-0.25), .number(0.1), .number(1e-7), .number(123456.789),
          .number(1e21), .number(2.5e-5), .number(1e16), .number(9.87654321e15),
          .number(0.0001), .number(1e15), .number(-1e-10),
        ])
      ),
      (
        // Where Swift's `Double` spelling turns exponential: 2^53 above, 1e-4
        // below.
        "boundaries",
        .array([
          .number(9_007_199_254_740_991), .number(9_007_199_254_740_992),
          .number(9_007_199_254_740_994), .number(-9_007_199_254_740_992),
          .number(1_234_567_890_123_456.8), .number(0.000_099_99), .number(-0.0001),
          .number(5e-324), .number(1.7976931348623157e308),
        ])
      ),
      (
        "strings",
        .object([
          "slash": .string("a/b"), "quote": .string("say \"hi\""),
          "backslash": .string("back\\slash"),
          "controls": .string("\u{0}\u{1}\u{8}\u{9}\u{A}\u{C}\u{D}\u{1F}"),
          "del": .string("\u{7F}"), "separators": .string("\u{2028}\u{2029}"),
          "unicode": .string("é中文🙂"), "empty": .string(""),
        ])
      ),
      (
        "nested",
        .object([
          "b": .array([
            .object(["k": .string("v"), "a": .array([])]), .integer(2),
          ]),
          "a": .object(["z": .object([:]), "y": .array([.array([.null])])]),
        ])
      ),
      (
        "keyOrder",
        .object([
          "b": .integer(1), "B": .integer(2), "a": .integer(3), "_": .integer(4),
          "é": .integer(5), "Z": .integer(6), "aa": .integer(7), "a0": .integer(8),
        ])
      ),
    ]
    let failures: [(CLIErrorCode, String)] = [
      (.resourceNotFound, "target TGT-missing is not adopted"),
      (.clientTimeout, "client stopped waiting; the Runtime execution and Job were not cancelled"),
      (.invalidInput, "a path /tmp/x and \"quoted\" é"),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] =
      try encoder.encode(
        JSONValue.object([
          "documents": .array(
            values.map { name, value in
              .object([
                "name": .string(name), "value": value,
                "document": .string(CLIRuntimeSession.legacyDocument(value)),
              ])
            }),
          "failures": .array(
            failures.map { code, message in
              .object([
                "code": .string(code.rawValue), "message": .string(message),
                "document": .string(
                  CLIRuntimeSession.legacyDocument(
                    CLIResultEnvelope.legacyFailure(
                      CLIRegistryError(code: code, message: message)))),
              ])
            }),
        ])) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLILegacyJSONOracleContractTests"),
          "owners": .array([
            .string("CLIRuntimeSession.legacyDocument"),
            .string("CLIResultEnvelope.legacyFailure"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
