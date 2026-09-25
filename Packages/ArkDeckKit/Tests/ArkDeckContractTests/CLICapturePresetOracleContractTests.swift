import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckClientKit
@testable import ArkDeckCLI
@testable import ArkDeckCore

/// What Swift's `RuntimeCLI.capturePresetExecutionRequest` makes of a
/// capture preset leaf's typed inputs (`screen capture`, `ui-dump capture`,
/// `ui-dump component-detail`, `debug logs`, `trace capture`), recorded for
/// the Rust CLI to replay (`rust/crates/arkdeck-cli/tests/domain_leaves.rs`).
///
/// Each case is a leaf's path and the inputs a caller's `--inputs-file`
/// holds; the record is the inputs the preset submits, or the words of its
/// refusal. The cases cover each preset's accepted shape, each field's type
/// and range, a field the preset does not accept, and the boundaries of the
/// identifier, category and HiLog filter grammars (ASCII and Unicode).
///
/// Record a new oracle with
/// `ARKDECK_RUST_CAPTURE_PRESET_RECORD=/private/tmp/<new directory>`;
/// otherwise the checked-in oracle must match byte for byte.
final class CLICapturePresetOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/capture-presets", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_CAPTURE_PRESET_RECORD"

  func testSwiftCapturePresetsTheRustCLIReplays() throws {
    let screen = ["screen", "capture"]
    let uiDump = ["ui-dump", "capture"]
    let detail = ["ui-dump", "component-detail"]
    let logs = ["debug", "logs"]
    let trace = ["trace", "capture"]
    let text: (String) -> JSONValue = { .string($0) }
    let cases: [(String, [String], [String: JSONValue])] = [
      ("screenDefault", screen, [:]),
      ("screenPng", screen, ["screenshotImageType": text("png")]),
      ("screenJpeg", screen, ["screenshotImageType": text("jpeg")]),
      ("screenGif", screen, ["screenshotImageType": text("gif")]),
      ("screenNotString", screen, ["screenshotImageType": .integer(1)]),
      ("screenExtra", screen, ["uiDump": .bool(true), "captureHilog": .bool(true)]),
      ("uiDump", uiDump, [:]),
      ("uiDumpExtra", uiDump, ["screenshotImageType": text("png")]),
      ("detail", detail, ["windowId": text("12"), "componentId": text("345")]),
      ("detailTwentyDigits", detail, [
        "windowId": text("12345678901234567890"), "componentId": text("0"),
      ]),
      ("detailTwentyOneDigits", detail, [
        "windowId": text("123456789012345678901"), "componentId": text("1"),
      ]),
      ("detailEmpty", detail, ["windowId": text(""), "componentId": text("1")]),
      ("detailNonDigit", detail, ["windowId": text("1a"), "componentId": text("1")]),
      ("detailFullwidthDigit", detail, ["windowId": text("１"), "componentId": text("1")]),
      ("detailArabicDigit", detail, ["windowId": text("٣"), "componentId": text("1")]),
      ("detailNumber", detail, ["windowId": .integer(1), "componentId": text("1")]),
      ("detailMissingWindow", detail, ["componentId": text("1")]),
      ("detailMissingBoth", detail, [:]),
      ("detailExtra", detail, [
        "windowId": text("1"), "componentId": text("1"), "zeta": text("z"), "alpha": text("a"),
      ]),
      ("logs", logs, ["durationSeconds": .integer(5)]),
      ("logsFilters", logs, [
        "durationSeconds": .integer(600),
        "hilogFilters": .array([text("A.b_c:d-e"), text("é中文"), text("x1")]),
      ]),
      ("logsZero", logs, ["durationSeconds": .integer(0)]),
      ("logsTooLong", logs, ["durationSeconds": .integer(601)]),
      ("logsFloat", logs, ["durationSeconds": .number(5.5)]),
      ("logsString", logs, ["durationSeconds": text("5")]),
      ("logsMissing", logs, [:]),
      ("logsBadFilter", logs, [
        "durationSeconds": .integer(5), "hilogFilters": .array([text("a b")]),
      ]),
      ("logsEmptyFilter", logs, [
        "durationSeconds": .integer(5), "hilogFilters": .array([text("")]),
      ]),
      ("logsCombiningFilter", logs, [
        "durationSeconds": .integer(5), "hilogFilters": .array([text("e\u{301}")]),
      ]),
      ("logsEmojiFilter", logs, [
        "durationSeconds": .integer(5), "hilogFilters": .array([text("🙂")]),
      ]),
      ("logsLongFilter", logs, [
        "durationSeconds": .integer(5),
        "hilogFilters": .array([text(String(repeating: "a", count: 200))]),
      ]),
      ("logsTooLongFilter", logs, [
        "durationSeconds": .integer(5),
        "hilogFilters": .array([text(String(repeating: "a", count: 201))]),
      ]),
      ("logsGraphemeFilter", logs, [
        "durationSeconds": .integer(5),
        "hilogFilters": .array([text(String(repeating: "e\u{301}", count: 200))]),
      ]),
      ("logsSixteenFilters", logs, [
        "durationSeconds": .integer(5),
        "hilogFilters": .array((0..<16).map { text("f\($0)") }),
      ]),
      ("logsSeventeenFilters", logs, [
        "durationSeconds": .integer(5),
        "hilogFilters": .array((0..<17).map { text("f\($0)") }),
      ]),
      ("logsFiltersNotArray", logs, [
        "durationSeconds": .integer(5), "hilogFilters": text("a"),
      ]),
      ("logsFilterNotString", logs, [
        "durationSeconds": .integer(5), "hilogFilters": .array([.integer(1)]),
      ]),
      ("logsExtra", logs, ["durationSeconds": .integer(5), "uiDump": .bool(true)]),
      ("trace", trace, [
        "durationSeconds": .integer(10), "traceCategories": .array([text("ability"), text("graphic")]),
        "traceBufferKB": .integer(1_024),
      ]),
      ("traceRing", trace, [
        "durationSeconds": .integer(600), "traceCategories": .array([text("a_1")]),
        "traceBufferKB": .integer(65_536), "ringBuffered": .bool(true),
      ]),
      ("traceRingFalse", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(2_048), "ringBuffered": .bool(false),
      ]),
      ("traceRingNotBool", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(2_048), "ringBuffered": .integer(1),
      ]),
      ("traceSmallBuffer", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(1_023),
      ]),
      ("traceLargeBuffer", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(65_537),
      ]),
      ("traceNoCategories", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceDuplicateCategories", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a"), text("a")]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceBadCategory", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a-b")]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceUnicodeCategory", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("é")]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceLongCategory", trace, [
        "durationSeconds": .integer(1),
        "traceCategories": .array([text(String(repeating: "a", count: 65))]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceTwentyFiveCategories", trace, [
        "durationSeconds": .integer(1),
        "traceCategories": .array((0..<25).map { text("c\($0)") }),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceMissingBuffer", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
      ]),
      ("traceCategoriesNotStrings", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([.integer(1)]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceZeroDuration", trace, [
        "durationSeconds": .integer(0), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(2_048),
      ]),
      ("traceExtra", trace, [
        "durationSeconds": .integer(1), "traceCategories": .array([text("a")]),
        "traceBufferKB": .integer(2_048), "hilogFilters": .array([]),
      ]),
      ("notAPreset", ["input", "tap"], ["x": .integer(1)]),
    ]
    var records: [JSONValue] = []
    for (name, path, inputs) in cases {
      let request = RuntimeAgentExecutionRequest(
        operationID: "capture.diagnostics", operationVersion: 1, inputs: inputs,
        capabilityReference: "CAP-EXAMPLE", targetID: "TGT-example", maximumWaitSeconds: 900,
        executionID: "exec-\(name)")
      var record: [String: JSONValue] = [
        "name": .string(name), "path": .array(path.map(JSONValue.string)),
        "inputs": .object(inputs),
      ]
      do {
        let presented = try RuntimeCLI.capturePresetExecutionRequest(path: path, request: request)
        record["presetInputs"] = .object(presented.inputs)
        // Everything but the inputs is carried through as given.
        XCTAssertEqual(presented.operationID, request.operationID, name)
        XCTAssertEqual(presented.operationVersion, request.operationVersion, name)
        XCTAssertEqual(presented.capabilityReference, request.capabilityReference, name)
        XCTAssertEqual(presented.targetID, request.targetID, name)
        XCTAssertEqual(presented.maximumWaitSeconds, request.maximumWaitSeconds, name)
        XCTAssertEqual(presented.executionID, request.executionID, name)
      } catch let failure as DiagnosticCapturePresetError {
        record["refusal"] = .string(failure.reason)
      }
      records.append(.object(record))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var files: [String: Data] = [:]
    files["cases.json"] = try encoder.encode(JSONValue.array(records)) + Data("\n".utf8)
    files["provenance.json"] =
      try encoder.encode(
        JSONValue.object([
          "producer": .string("CLICapturePresetOracleContractTests"),
          "owners": .array([
            .string("RuntimeCLI.capturePresetExecutionRequest"),
            .string("DiagnosticCapturePreset"),
            .string("DebugTypedValueValidator.isSafeHilogComponent"),
          ]),
        ])) + Data("\n".utf8)
    try HDCOracleHarness.recordOrCompare(
      files, variable: Self.recordVariable, oracle: Self.oracle)
  }
}
