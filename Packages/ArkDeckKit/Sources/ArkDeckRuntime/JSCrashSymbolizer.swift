// Resolve an obfuscated ArkTS crash stack back to its original source.
//
// An OpenHarmony `jscrash` fault log carries a `Stacktrace:` block whose frames
// name a compiled unit, a line and a column:
//
//     at anonymous (entry|entry|1.0.0|src/main/ets/h/l.ts:14:1)
//
// With obfuscation enabled that unit name, the property that failed and the
// position are all mangled — the frame above is `CrashProbe.ets:30:16` in the
// source someone can actually open. The build writes `sourceMaps.map`, whose
// top-level keys are exactly those frame units, so the resolution is a lookup
// and a Source Map v3 decode. Nothing here guesses: a frame either has a
// mapping segment that covers it or it is reported unresolved.

import Foundation

public enum JSCrashSymbolizerError: Error, Equatable, Sendable {
  case sourceMapUnreadable(String)
  case dumpUnreadable(String)
}

/// One frame of a `Stacktrace:` block, and what the source map made of it.
public struct JSCrashSymbolizedFrame: Equatable, Sendable {
  public let raw: String
  public let unit: String?
  public let line: Int?
  public let column: Int?
  public let originalSource: String?
  public let originalLine: Int?
  public let originalColumn: Int?

  public var isResolved: Bool { originalSource != nil }
}

public enum JSCrashSymbolizer {
  /// Frames look like `at <something> (<unit>:<line>:<column>)`. The part
  /// before the parenthesis varies — the unobfuscated build emits
  /// `at anonymous entry (…)` where the obfuscated one emits `at anonymous (…)`
  /// — so only the parenthesised triple is parsed, and the rest is carried
  /// through untouched for whoever reads the report.
  static func parseFrame(_ line: String) -> (unit: String, line: Int, column: Int)? {
    guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"),
      open < close
    else { return nil }
    let inner = line[line.index(after: open)..<close]
    let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3, let column = Int(parts[parts.count - 1]),
      let row = Int(parts[parts.count - 2])
    else { return nil }
    let unit = parts[0..<(parts.count - 2)].joined(separator: ":")
    guard !unit.isEmpty else { return nil }
    return (unit, row, column)
  }

  /// Base64 VLQ, as Source Map v3 defines it: six bits per digit, the low bit
  /// of the decoded value is the sign, and the continuation bit says whether
  /// another digit follows.
  static func decodeVLQ(_ text: Substring) -> [Int]? {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    var index: [Character: Int] = [:]
    for (position, character) in alphabet.enumerated() { index[character] = position }

    var values: [Int] = []
    var result = 0
    var shift = 0
    for character in text {
      guard let digit = index[character] else { return nil }
      let hasContinuation = (digit & 32) != 0
      result += (digit & 31) << shift
      if hasContinuation {
        shift += 5
        continue
      }
      let negative = (result & 1) == 1
      var magnitude = result >> 1
      if negative { magnitude = -magnitude }
      values.append(magnitude)
      result = 0
      shift = 0
    }
    return shift == 0 ? values : nil
  }

  /// How exactly a frame's position could be placed.
  public enum Precision: String, Equatable, Sendable {
    /// A segment starts at or before the reported column.
    case column
    /// No segment does, so the line's first segment answered instead. The
    /// engine reports column 1 for a whole statement while the compiled line
    /// begins further right, which is the common case rather than an edge one.
    case line
  }

  /// The mapping segment covering `column` on `line`, as an original position.
  ///
  /// Segments are ordered by generated column, and a position lands on the last
  /// segment that starts at or before it — a statement maps to the segment that
  /// opened it, not the next one. When the reported column precedes every
  /// segment on the line, the line is still unambiguous, so its first segment
  /// answers and the result says it was placed by line. A line with no segments
  /// at all has no answer, and says that instead of borrowing another line's.
  static func originalPosition(
    mappings: String, sources: [String], line: Int, column: Int
  ) -> (source: String, line: Int, column: Int, precision: Precision)? {
    var sourceIndex = 0
    var originalLine = 0
    var originalColumn = 0
    let rows = mappings.split(separator: ";", omittingEmptySubsequences: false)
    guard line >= 1, line <= rows.count else { return nil }

    var covering: (Int, Int, Int)?
    var firstOnLine: (Int, Int, Int)?
    for (rowNumber, row) in rows.enumerated() {
      var generatedColumn = 0
      for segment in row.split(separator: ",", omittingEmptySubsequences: true) {
        guard let fields = decodeVLQ(segment), !fields.isEmpty else { continue }
        generatedColumn += fields[0]
        guard fields.count >= 4 else { continue }
        sourceIndex += fields[1]
        originalLine += fields[2]
        originalColumn += fields[3]
        // Decoding must run over every earlier row: the fields are deltas
        // against the whole document, so a row cannot be decoded alone.
        guard rowNumber == line - 1 else { continue }
        if firstOnLine == nil {
          firstOnLine = (sourceIndex, originalLine, originalColumn)
        }
        if generatedColumn <= column - 1 {
          covering = (sourceIndex, originalLine, originalColumn)
        }
      }
    }
    let precision: Precision = covering != nil ? .column : .line
    guard let answer = covering ?? firstOnLine, answer.0 >= 0, answer.0 < sources.count
    else { return nil }
    return (sources[answer.0], answer.1 + 1, answer.2 + 1, precision)
  }

  /// Symbolize every frame of the dump's `Stacktrace:` block.
  ///
  /// The report keeps the original text and adds the resolution beneath each
  /// frame, because the raw frame is what matches the device's own record and
  /// an operator comparing the two should not have to trust this tool to have
  /// preserved it.
  public static func symbolize(sourceMapData: Data, dumpText: String) throws -> String {
    let object: [String: Any]
    do {
      guard let parsed = try JSONSerialization.jsonObject(with: sourceMapData) as? [String: Any]
      else { throw JSCrashSymbolizerError.sourceMapUnreadable("not a JSON object") }
      object = parsed
    } catch let error as JSCrashSymbolizerError {
      throw error
    } catch {
      throw JSCrashSymbolizerError.sourceMapUnreadable("\(error)")
    }

    var report: [String] = []
    var inStack = false
    var frameCount = 0
    var resolvedCount = 0

    for raw in dumpText.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if line.hasPrefix("Stacktrace:") {
        inStack = true
        report.append(line)
        continue
      }
      guard inStack else { continue }
      // The block ends at the first line that is not an indented frame.
      guard line.hasPrefix("    ") || line.hasPrefix("\t") else {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        inStack = false
        continue
      }
      report.append(line)
      frameCount += 1
      guard let frame = parseFrame(line) else {
        report.append("        <unparsed frame>")
        continue
      }
      guard let entry = object[frame.unit] as? [String: Any],
        let mappings = entry["mappings"] as? String,
        let sources = entry["sources"] as? [String]
      else {
        // A frame whose unit is not in this map is not a failure: an
        // unobfuscated build names its own source directly, and a frame from
        // another module belongs to another map.
        report.append("        <unresolved: no mapping for \(frame.unit)>")
        continue
      }
      guard let position = originalPosition(
        mappings: mappings, sources: sources, line: frame.line, column: frame.column)
      else {
        report.append("        <unresolved: line \(frame.line) has no mapping segment>")
        continue
      }
      resolvedCount += 1
      let placed = position.precision == .column ? "" : "  (placed by line)"
      report.append(
        "        -> \(position.source):\(position.line):\(position.column)\(placed)")
    }

    report.append("")
    report.append("frames: \(frameCount)  resolved: \(resolvedCount)")
    return report.joined(separator: "\n") + "\n"
  }
}
