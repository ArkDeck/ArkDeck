// Shared Swift oracle for the Rust port of `JSCrashSymbolizer` (TASK-XPA-015,
// M3), the one-shot `--symbolize-crash` mode `workspace.symbolize-crash@1`
// runs: for every source map and crash dump below, the exact report
// `JSCrashSymbolizer.symbolize` writes, or the error it throws.
//
// The corpus has three parts. The device's own case: the jscrash stack and
// the `sourceMaps.map` entry of the obfuscated WaterFlow build
// (`JSCrashSymbolizerContractTests`). Hand-written cases for each rule: the
// column and the line placement, a frame whose unit the map does not name, an
// unparsed frame, a line with no segment, signs and continuations, digits
// outside the alphabet, a trailing continuation, short and long segments,
// source indexes out of range, entries that are not objects or carry no
// strings, maps that are not objects or not JSON, several stack blocks,
// blank and tab-indented lines, CRLF line ends, bytes that are not UTF-8, and
// signed and malformed positions. And 60 generated cases from a fixed seed,
// small enough never to reach Swift's integer traps.
//
// Host-local only, no daemon, no device. Record with
// `ARKDECK_RUST_CRASH_SYMBOLIZER_RECORD=/private/tmp/<new directory>`.
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime

final class CrashSymbolizerOracleContractTests: XCTestCase {
  private static let repository: URL = {
    var url = URL(filePath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }()
  private static let oracle = repository.appending(
    path: "rust/tests/fixtures/crash-symbolizer-oracle", directoryHint: .isDirectory)
  private static let recordVariable = "ARKDECK_RUST_CRASH_SYMBOLIZER_RECORD"

  /// The obfuscated WaterFlow build's own map entry and the device's stack.
  private static let deviceUnit = "entry|entry|1.0.0|src/main/ets/h/l.ts"
  private static let deviceMappings =
    "OAcS,KAAK,MAAA,aAAA,CAAA;OACP,EAAU,MAAA,mCAAA,CAAA;AACV,OAAA,EAAE,EAAc,EAAE,EAAW,EAAE,EAAI,EAAE,gDAAA;AAE5C,MAAM,MAAM,GAAG,MAAM,CAAC;AACtB,MAAM,KAAM,mBAAmB,CAAC;AAEhC,MAAM,gBAA2B,IAAI;IACnC,IAAI,OAAS,KAAsB,EAAE;QACnC,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,YAAY,EAAE,wDAAwD,CAAC,CAAC;QAChG,OAAO;KACR;IACD,KAAK,CAAC,IAAI,CAAC,MAAM,MAAO,8CAA8C,KAAiB,CAAC;IACxF,UAAU,CAAC,GAAG,EAAE;QACd,KAAK,CAAC,KAAK,CAAC,MAAM,MAAO,YAAY,EAAE,oBAAoB,CAAC,CAAC;QAC7D,KAA6B,EAAE,CAAC;IAClC,CAAC,KAAiB,CAAC;AACrB,CAAC"

  private struct Case {
    let name: String
    let map: Data
    let dump: Data
  }

  private static func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  /// Base64 VLQ, as Source Map v3 encodes one field.
  private static func vlq(_ value: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var remaining = value < 0 ? ((-value) << 1) | 1 : value << 1
    var text = ""
    repeat {
      var digit = remaining & 31
      remaining >>= 5
      if remaining > 0 { digit |= 32 }
      text.append(alphabet[digit])
    } while remaining > 0
    return text
  }

  /// SplitMix64, so the generated corpus is the same on every host.
  private struct Seeded {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    mutating func between(_ low: Int, _ high: Int) -> Int { low + below(high - low + 1) }
  }

  private static func handWritten() -> [Case] {
    let unit = "entry|entry|1.0.0|src/main/ets/a.ts"
    let simple: [String: Any] = [
      unit: [
        "version": 3, "sources": ["entry/src/main/ets/pages/Index.ets", "entry/src/main/ets/b.ets"],
        "names": [], "mappings": "AAAA,IAAI;AACA,EAAE;;GACC,CAAE",
      ]
    ]
    let simpleMap = json(simple)
    func text(_ value: String) -> Data { Data(value.utf8) }
    var cases: [Case] = []
    cases.append(
      Case(
        name: "device", map: json([deviceUnit: ["version": 3, "sources": ["entry/src/main/ets/fixture/CrashProbe.ets"], "names": [], "mappings": deviceMappings, "file": "CrashProbe.ets"]]),
        dump: text(
          "Reason:TypeError\nError message:Cannot read property h2 of undefined\nStacktrace:\n    at anonymous (\(deviceUnit):14:1)\n    at anonymous (\(deviceUnit):14:20)\n    at anonymous entry (entry/src/main/ets/fixture/CrashProbe.ets:30:16)\nNativeModuleErrorInfo:\n")))
    cases.append(
      Case(
        name: "rules", map: simpleMap,
        dump: text(
          "Reason:Error\nStacktrace:\n    at a (\(unit):1:5)\n    at b (\(unit):1:1)\n    at c (\(unit):2:1)\n    at d (\(unit):2:3)\n    at e (\(unit):3:1)\n    at f (\(unit):4:9)\n    at g (\(unit):5:1)\n    at h (\(unit):0:1)\n    at i (other|unit:1:1)\n    at j (no position)\n    at k (\(unit):x:1)\n    at l (\(unit):1: 2)\n    at m (\(unit):+1:+3)\n    at n (\(unit):1:-3)\n    at o (:1:1)\n    at p (\(unit):1)\n    at q ((\(unit):1:1)\nEnd\n")))
    cases.append(
      Case(
        name: "blocks", map: simpleMap,
        dump: text(
          "prefix\nStacktrace: first\n    at a (\(unit):1:1)\n\n   \t \n\tat b (\(unit):2:2)\nnot a frame\n    at ignored (\(unit):1:1)\nStacktrace:\nStacktrace: again\n  at two-spaces (\(unit):1:1)\n")))
    cases.append(
      Case(
        name: "crlf", map: simpleMap,
        dump: text("Stacktrace:\r\n    at a (\(unit):1:1)\r\n    at b (\(unit):2:1)\r\n")))
    cases.append(
      Case(
        name: "crlf-after-lf", map: simpleMap,
        dump: text("Stacktrace:\n    at a (\(unit):1:1)\r\n    at b (\(unit):2:1)\n    at c (\(unit):2:1)\r")))
    var invalid = text("Stacktrace:\n    at a (")
    invalid.append(contentsOf: [0xFF, 0xFE])
    invalid.append(text("\(unit):1:1)\n    at b (\(unit):1:1)\n"))
    cases.append(Case(name: "invalid-utf8", map: simpleMap, dump: invalid))
    cases.append(Case(name: "empty-dump", map: simpleMap, dump: Data()))
    cases.append(
      Case(name: "no-stack", map: simpleMap, dump: text("Reason:Error\nnothing here\n")))
    let vlq: [String: Any] = [
      "u": [
        "sources": ["s0", "s1", "s2"],
        "mappings":
          "gBAAgB,kBAAmB,D;!AAA,CAAC,A;ggggA,AAAA,AAAAA,AACCG;AAAg;DADD,CCCC;,,AAAA,,;+/+/,A",
      ]
    ]
    cases.append(
      Case(
        name: "vlq", map: json(vlq),
        dump: text(
          "Stacktrace:\n" + (1...8).flatMap { line in
            [1, 2, 5, 17, 40].map { column in "    at f (u:\(line):\(column))\n" }
          }.joined())))
    let shapes: [String: Any] = [
      "not-an-object": ["sources": ["x"], "mappings": "AAAA"] as Any,
      "array-entry": [1, 2, 3],
      "string-entry": "AAAA",
      "number-sources": ["sources": [1], "mappings": "AAAA"],
      "null-source": ["sources": [NSNull()], "mappings": "AAAA"],
      "mixed-sources": ["sources": ["a", 2], "mappings": "AAAA"],
      "no-sources": ["mappings": "AAAA"],
      "empty-sources": ["sources": [], "mappings": "AAAA"],
      "number-mappings": ["sources": ["a"], "mappings": 1],
      "no-mappings": ["sources": ["a"]],
      "out-of-range": ["sources": ["a"], "mappings": "ACAA"],
      "negative-source": ["sources": ["a"], "mappings": "ADAA"],
      "fine": ["sources": ["a"], "mappings": "AAAA"],
    ]
    cases.append(
      Case(
        name: "entry-shapes", map: json(shapes),
        dump: text(
          "Stacktrace:\n"
            + shapes.keys.sorted().map { "    at f (\($0):1:1)\n" }.joined())))
    cases.append(
      Case(name: "map-array", map: text("[{\"u\":{\"sources\":[\"a\"],\"mappings\":\"AAAA\"}}]"), dump: text("Stacktrace:\n    at f (u:1:1)\n")))
    cases.append(Case(name: "map-string", map: text("\"AAAA\""), dump: text("Stacktrace:\n")))
    cases.append(Case(name: "map-invalid", map: text("{\"u\": {"), dump: text("Stacktrace:\n")))
    cases.append(Case(name: "map-empty", map: Data(), dump: text("Stacktrace:\n")))
    cases.append(
      Case(
        name: "map-duplicate-key",
        map: text("{\"u\":{\"sources\":[\"first\"],\"mappings\":\"AAAA\"},\"u\":{\"sources\":[\"second\"],\"mappings\":\"AAAA\"}}"),
        dump: text("Stacktrace:\n    at f (u:1:1)\n")))
    cases.append(
      Case(
        name: "map-unicode-key",
        map: json(["ü|x": ["sources": ["ñ.ets"], "mappings": "AAAA"]]),
        dump: text("Stacktrace:\n    at f (ü|x:1:1)\n    at g (u\u{0308}|x:1:1)\n")))
    cases.append(
      Case(
        name: "colon-unit", map: json(["a:b:c": ["sources": ["s"], "mappings": "AAAA,EAAE"]]),
        dump: text("Stacktrace:\n    at f (a:b:c:1:3)\n    at g (x (a:b:c:1:1) tail)\n")))
    return cases
  }

  private static func generated() -> [Case] {
    var random = Seeded(state: 0x5328_A11C_E5EE_D001)
    var cases: [Case] = []
    for index in 0..<60 {
      var map: [String: Any] = [:]
      var units: [String] = []
      for unitIndex in 0..<random.between(1, 3) {
        let unit = "entry|entry|1.0.0|src/main/ets/g\(index)/u\(unitIndex).ts"
        units.append(unit)
        let sources = (0..<random.between(1, 3)).map { "entry/src/main/ets/g\(index)/S\($0).ets" }
        var rows: [String] = []
        for _ in 0..<random.between(1, 8) {
          var segments: [String] = []
          for _ in 0..<random.between(0, 5) {
            let width = [1, 4, 4, 4, 5][random.below(5)]
            var fields = [random.between(0, 12)]
            if width >= 4 {
              fields += [
                random.between(-1, sources.count - 1), random.between(-3, 4), random.between(-6, 8),
              ]
            }
            if width == 5 { fields.append(random.between(0, 3)) }
            segments.append(fields.map(vlq).joined())
          }
          if random.below(8) == 0 { segments.append("") }
          rows.append(segments.joined(separator: ","))
        }
        map[unit] = ["version": 3, "sources": sources, "names": [], "mappings": rows.joined(separator: ";")]
      }
      var lines = ["Reason:Error", "Stacktrace:"]
      for _ in 0..<random.between(1, 6) {
        let unit = random.below(6) == 0 ? "unknown|unit" : units[random.below(units.count)]
        lines.append(
          "    at f\(random.below(100)) (\(unit):\(random.between(0, 9)):\(random.between(0, 30)))")
      }
      if random.below(3) == 0 { lines.append("    at anonymous (no position)") }
      lines.append("NativeModuleErrorInfo:")
      cases.append(
        Case(
          name: "generated-\(index)", map: json(map),
          dump: Data((lines.joined(separator: "\n") + "\n").utf8)))
    }
    return cases
  }

  func testTheSymbolizerReportsAsRecorded() throws {
    var recorded: [JSONValue] = []
    for item in Self.handWritten() + Self.generated() {
      var fields: [String: JSONValue] = [
        "name": .string(item.name),
        "map": .string(item.map.base64EncodedString()),
        "dump": .string(item.dump.base64EncodedString()),
      ]
      do {
        let report = try JSCrashSymbolizer.symbolize(
          sourceMapData: item.map, dumpText: String(decoding: item.dump, as: UTF8.self))
        fields["report"] = .string(report)
      } catch let error as JSCrashSymbolizerError {
        switch error {
        case .sourceMapUnreadable(let detail):
          fields["error"] = .string("sourceMapUnreadable")
          // Only the symbolizer's own detail is Swift's to keep; a Foundation
          // parse error's text is not a contract.
          if detail == "not a JSON object" { fields["detail"] = .string(detail) }
        case .dumpUnreadable:
          fields["error"] = .string("dumpUnreadable")
        }
      }
      recorded.append(.object(fields))
    }
    let bytes = try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.array(recorded))
    if let output = ProcessInfo.processInfo.environment[Self.recordVariable] {
      let directory = URL(filePath: output, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try bytes.write(to: directory.appending(path: "cases.json"))
      return
    }
    XCTAssertEqual(try Data(contentsOf: Self.oracle.appending(path: "cases.json")), bytes)
  }
}
