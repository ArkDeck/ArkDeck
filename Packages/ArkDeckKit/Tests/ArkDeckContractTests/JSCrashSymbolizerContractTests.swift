// ArkTS crash symbolization, checked against a stack a real device produced.
//
// The fixtures below are not invented: the frame is the `Stacktrace:` line from
// a jscrash raised by the WaterFlow demo built with obfuscation enabled, and
// the mapping is that build's own `sourceMaps.map` entry for the unit the frame
// names. The expected answer has an independent witness — the same crash from
// the unobfuscated build reported `CrashProbe.ets:30:16`, so a resolution that
// does not land on line 30 of that file is wrong regardless of what the decoder
// thinks.

import XCTest

@testable import ArkDeckRuntime

final class JSCrashSymbolizerContractTests: XCTestCase {
  /// The obfuscated build's own map entry for the crashing unit.
  private let unit = "entry|entry|1.0.0|src/main/ets/h/l.ts"
  private var sourceMap: Data {
    let document: [String: Any] = [
      unit: [
        "version": 3,
        "file": "CrashProbe.ets",
        "sources": ["entry/src/main/ets/fixture/CrashProbe.ets"],
        "names": [],
        "mappings": "OAcS,KAAK,MAAA,aAAA,CAAA;OACP,EAAU,MAAA,mCAAA,CAAA;AACV,OAAA,EAAE,EAAc,EAAE,EAAW,EAAE,EAAI,EAAE,gDAAA;AAE5C,MAAM,MAAM,GAAG,MAAM,CAAC;AACtB,MAAM,KAAM,mBAAmB,CAAC;AAEhC,MAAM,gBAA2B,IAAI;IACnC,IAAI,OAAS,KAAsB,EAAE;QACnC,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,YAAY,EAAE,wDAAwD,CAAC,CAAC;QAChG,OAAO;KACR;IACD,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,8CAA8C,KAAiB,CAAC;IACxF,UAAU,CAAC,GAAG,EAAE;QACd,KAAK,CAAC,KAAK,CAAC,MAAM,MAAO,YAAY,EAAE,oBAAoB,CAAC,CAAC;QAC7D,KAA6B,EAAE,CAAC;IAClC,CAAC,KAAiB,CAAC;AACrB,CAAC",
      ]
    ]
    return try! JSONSerialization.data(withJSONObject: document)
  }

  private let dump = """
    Reason:TypeError
    Error message:Cannot read property h2 of undefined
    Stacktrace:
        at anonymous (entry|entry|1.0.0|src/main/ets/h/l.ts:14:1)
    NativeModuleErrorInfo:
    """

  func testTheObfuscatedFrameResolvesToTheSourceTheOtherBuildNamed() throws {
    let report = try JSCrashSymbolizer.symbolize(sourceMapData: sourceMap, dumpText: dump)
    XCTAssertTrue(
      report.contains("entry/src/main/ets/fixture/CrashProbe.ets:30:"),
      "the unobfuscated build reported line 30 of this file; the report said:\n\(report)")
    XCTAssertTrue(report.contains("frames: 1  resolved: 1"), report)
    // The raw frame survives, because it is what matches the device's record.
    XCTAssertTrue(report.contains("at anonymous (\(unit):14:1)"), report)
  }

  /// The engine reports column 1 for a whole statement while the compiled line
  /// begins further right — here the first segment starts at generated column
  /// 9. Refusing to answer would throw away a resolution whose line is not in
  /// doubt, so the line answers and the report says how it was placed.
  func testAColumnBeforeEverySegmentIsPlacedByLineAndSaysSo() throws {
    let report = try JSCrashSymbolizer.symbolize(sourceMapData: sourceMap, dumpText: dump)
    XCTAssertTrue(report.contains("(placed by line)"), report)

    let exact = JSCrashSymbolizer.originalPosition(
      mappings: "OAcS,KAAK,MAAA,aAAA,CAAA;OACP,EAAU,MAAA,mCAAA,CAAA;AACV,OAAA,EAAE,EAAc,EAAE,EAAW,EAAE,EAAI,EAAE,gDAAA;AAE5C,MAAM,MAAM,GAAG,MAAM,CAAC;AACtB,MAAM,KAAM,mBAAmB,CAAC;AAEhC,MAAM,gBAA2B,IAAI;IACnC,IAAI,OAAS,KAAsB,EAAE;QACnC,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,YAAY,EAAE,wDAAwD,CAAC,CAAC;QAChG,OAAO;KACR;IACD,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,8CAA8C,KAAiB,CAAC;IACxF,UAAU,CAAC,GAAG,EAAE;QACd,KAAK,CAAC,KAAK,CAAC,MAAM,MAAO,YAAY,EAAE,oBAAoB,CAAC,CAAC;QAC7D,KAA6B,EAAE,CAAC;IAClC,CAAC,KAAiB,CAAC;AACrB,CAAC", sources: ["entry/src/main/ets/fixture/CrashProbe.ets"], line: 14, column: 20)
    XCTAssertEqual(exact?.precision, .column, "a column past the first segment is exact")
    XCTAssertEqual(exact?.line, 30)
  }

  /// A frame this map knows nothing about is reported as such. An unobfuscated
  /// build names its own source directly and has no entry here, and a frame
  /// from another module belongs to another map; neither is a decoder failure.
  func testAFrameWithNoMappingIsReportedRatherThanGuessed() throws {
    let other = """
      Stacktrace:
          at anonymous entry (entry/src/main/ets/fixture/CrashProbe.ets:30:16)
      """
    let report = try JSCrashSymbolizer.symbolize(sourceMapData: sourceMap, dumpText: other)
    XCTAssertTrue(report.contains("<unresolved: no mapping for"), report)
    XCTAssertTrue(report.contains("frames: 1  resolved: 0"), report)
  }

  /// Both frame shapes the two builds emit parse. The unobfuscated one carries
  /// an extra bare word before the parenthesis, so only the parenthesised
  /// triple may be read.
  func testBothFrameShapesParse() {
    XCTAssertEqual(
      JSCrashSymbolizer.parseFrame("    at anonymous (a|b|1.0.0|src/x.ts:14:1)")?.unit,
      "a|b|1.0.0|src/x.ts")
    let plain = JSCrashSymbolizer.parseFrame(
      "    at anonymous entry (entry/src/main/ets/fixture/CrashProbe.ets:30:16)")
    XCTAssertEqual(plain?.unit, "entry/src/main/ets/fixture/CrashProbe.ets")
    XCTAssertEqual(plain?.line, 30)
    XCTAssertEqual(plain?.column, 16)
    XCTAssertNil(JSCrashSymbolizer.parseFrame("    at anonymous (no position here)"))
  }

  /// Base64 VLQ, against values the map above actually contains.
  func testVLQDecodesSignAndContinuation() {
    XCTAssertEqual(JSCrashSymbolizer.decodeVLQ("AAAA"), [0, 0, 0, 0])
    XCTAssertEqual(JSCrashSymbolizer.decodeVLQ("D"), [-1])
    XCTAssertEqual(JSCrashSymbolizer.decodeVLQ("C"), [1])
    XCTAssertNil(JSCrashSymbolizer.decodeVLQ("!"), "a non-alphabet digit is not decoded")
  }
}
