// HDC compatibility profiles and the observation-family semantic parser
// (CHG-2026-047, T06 - additive; no existing judgment path changes).
//
// E0 observation outputs are judged by a registered version profile plus
// structural parsing with explicit invariants, instead of byte-exact stdout
// hashes: semantically equal outputs that differ in whitespace or in
// irrelevant diagnostic lines parse identically, while truncation, invalid
// encoding, empty output and unregistered versions each get an explicit,
// closed outcome. Destructive and lifecycle families deliberately keep the
// existing exact golden-fingerprint pins - this parser is not reachable
// from them.

import Foundation

/// Closed set of tool-version families this parser is registered for.
/// Unknown versions never parse - they fail closed as `unsupportedVersion`.
package struct HDCCompatibilityProfile: Sendable, Equatable {
  public let profileID: String
  /// Exact `Ver: x.y.zc` strings this profile covers (e.g. "3.2.0d", "3.2.0f").
  package let registeredVersions: Set<String>

  public init(profileID: String, registeredVersions: Set<String>) {
    self.profileID = profileID
    self.registeredVersions = registeredVersions
  }

  /// The registered production profile: the 3.2.0 observation family, with
  /// membership mirroring the pinned discovery/registry facts.
  package static let openHarmony320Family = HDCCompatibilityProfile(
    profileID: "OPENHARMONY-HDC-3.2.0-FAMILY@1",
    registeredVersions: ["3.2.0d", "3.2.0f"])

  public func covers(version: String) -> Bool {
    registeredVersions.contains(version)
  }
}

/// Explicit, closed outcomes. There is no "assume success" member and no
/// exit-code shortcut: every path is either a parsed value or a named
/// refusal.
package enum HDCObservationParseOutcome<Value: Sendable & Equatable>: Sendable, Equatable {
  case parsed(Value)
  case unsupportedVersion(String)
  case invalidEncoding
  case truncated
  case empty
  case malformed(reason: String)
}

package struct HDCParsedClientVersion: Sendable, Equatable {
  public let version: String
}

/// `hdc checkserver` reports both sides at once:
/// `Client version:Ver: X, server version:Ver: Y`. It is deliberately a
/// distinct shape from `hdc -v` - reusing the version parser here is the
/// defect the first device window exposed (it looked for lines starting
/// with "Ver:" and found none).
package struct HDCParsedServerCheck: Sendable, Equatable {
  public let clientVersion: String
  public let serverVersion: String

  package var versionsAgree: Bool { clientVersion == serverVersion }
}

package struct HDCParsedTargetLine: Sendable, Equatable {
  public let connectKey: String
  public let transport: String
  public let state: String
}

package struct HDCParsedTargetList: Sendable, Equatable {
  public let targets: [HDCParsedTargetLine]
}

package enum HDCObservationSemanticParser {
  /// Diagnostic noise the daemon may interleave with observation output.
  /// Matching is prefix-based on the trimmed line; the list is closed and
  /// additive per registered version evidence.
  private static let ignorableDiagnosticPrefixes: [String] = [
    "[I]", "[W]", "[D]", "* daemon", "Connect server failed",
  ]

  private struct OutputLine {
    let number: Int
    let source: Substring
    let normalized: String
  }

  private static func targetOutputLines(_ text: String) -> [OutputLine] {
    var lines: [OutputLine] = []
    var start = text.startIndex
    var number = 1

    func appendLine(contentEnd: String.Index, sourceEnd: String.Index) {
      let content = text[start..<contentEnd]
      let containsUnregisteredNewline = content.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
      let normalized = containsUnregisteredNewline
        ? String(content) : content.trimmingCharacters(in: .whitespaces)
      guard containsUnregisteredNewline
        || (!normalized.isEmpty && !ignorableDiagnosticPrefixes.contains(where: { normalized.hasPrefix($0) }))
      else { return }
      lines.append(OutputLine(number: number, source: text[start..<sourceEnd], normalized: normalized))
    }

    // Swift treats CRLF as one Character, distinct from LF. The target-list
    // family registers both.
    // Bare CR and other newlines stay input, never extra delimiters. Keep the
    // original terminator bytes in bounded failure previews.
    for index in text.indices where text[index] == "\n" || text[index] == "\r\n" {
      let end = text.index(after: index)
      appendLine(contentEnd: index, sourceEnd: end)
      start = end
      number += 1
    }
    appendLine(contentEnd: text.endIndex, sourceEnd: text.endIndex)
    return lines
  }

  private static func normalizedLines(_ text: String) -> [String] {
    // Version probes retain their original Character-LF boundaries and
    // diagnostic-prefix filtering independently of the target-list grammar.
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { source in
      let normalized = source.trimmingCharacters(in: .whitespaces)
      guard !normalized.isEmpty,
        !ignorableDiagnosticPrefixes.contains(where: { normalized.hasPrefix($0) })
      else { return nil }
      return normalized
    }
  }

  /// This is bounded failure prose, not a process receipt or raw Artifact.
  /// Escape bytes before they reach a terminal, Job timeline or control error;
  /// neither control sequences nor non-ASCII direction markers may render.
  private static func invalidTargetOutput(
    _ reason: String, line: OutputLine, columnCount: Int
  ) -> HDCObservationParseOutcome<HDCParsedTargetList> {
    let maximumPreviewBytes = 256
    let byteCount = line.source.utf8.count
    let preview: String
    // A malformed row can be arbitrary tool text. Do not persist an apparent
    // credential or private key merely because it reached a target-list parser.
    // Match sensitive fragments conservatively: snake/camel-case suffixes such
    // as SECRET_ACCESS_KEY and SecretAccessKey need no adjacent delimiter.
    let sensitive = line.source.range(
      of: #"(?i)(token|secret|password|passwd|api[_-]?key|authorization)|-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
      options: .regularExpression) != nil
    if sensitive {
      preview = "<sensitive text omitted>"
    } else {
      preview = line.source.utf8.prefix(maximumPreviewBytes).map { byte in
        switch byte {
        case 0x09: return "\\t"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        case 0x22: return "\\\""
        case 0x5C: return "\\\\"
        case 0x20...0x7E: return String(UnicodeScalar(byte))
        default: return String(format: "\\x%02X", byte)
        }
      }.joined()
    }
    let truncation = byteCount > maximumPreviewBytes
      ? "; preview truncated to \(maximumPreviewBytes) of \(byteCount) bytes" : ""
    return .malformed(
      reason: "target output line \(line.number): \(reason); saw \(columnCount) columns; "
        + "preview \"\(preview)\"\(truncation)")
  }

  /// Parses `hdc -v` / `hdc checkserver` style version output:
  /// exactly one meaningful line of the form `Ver: <version>`.
  package static func parseClientVersion(
    stdout: Data,
    profile: HDCCompatibilityProfile,
    truncated: Bool
  ) -> HDCObservationParseOutcome<HDCParsedClientVersion> {
    if truncated { return .truncated }
    guard let text = String(data: stdout, encoding: .utf8) else {
      return .invalidEncoding
    }
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return .empty }
    let versionLines = lines.filter { $0.hasPrefix("Ver:") }
    guard versionLines.count == 1, let line = versionLines.first else {
      return .malformed(reason: "expected exactly one Ver: line, saw \(versionLines.count)")
    }
    let version = line.dropFirst("Ver:".count).trimmingCharacters(in: .whitespaces)
    guard !version.isEmpty else { return .malformed(reason: "empty version token") }
    guard profile.covers(version: version) else {
      return .unsupportedVersion(version)
    }
    return .parsed(HDCParsedClientVersion(version: version))
  }

  /// Parses `hdc checkserver` output. A client/server version disagreement
  /// is a named failure, never a pass: the two sides speaking different
  /// protocol versions is exactly the condition this probe exists to find.
  package static func parseServerCheck(
    stdout: Data,
    profile: HDCCompatibilityProfile,
    truncated: Bool
  ) -> HDCObservationParseOutcome<HDCParsedServerCheck> {
    if truncated { return .truncated }
    guard let text = String(data: stdout, encoding: .utf8) else {
      return .invalidEncoding
    }
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return .empty }
    guard
      let line = lines.first(where: {
        $0.hasPrefix("Client version:") && $0.contains("server version:")
      })
    else {
      // A `[Fail] …` diagnostic line is a legible failure, not a parse bug.
      if let failure = lines.first(where: { $0.hasPrefix("[Fail]") }) {
        return .malformed(reason: "server check reported: \(failure)")
      }
      return .malformed(reason: "no client/server version line in checkserver output")
    }
    let segments = line.split(separator: ",", maxSplits: 1)
    guard segments.count == 2 else {
      return .malformed(reason: "checkserver line is missing its server segment")
    }

    func version(of segment: Substring, marker: String) -> String? {
      guard let range = segment.range(of: marker) else { return nil }
      let value = segment[range.upperBound...].trimmingCharacters(in: .whitespaces)
      return value.isEmpty ? nil : value
    }

    guard let client = version(of: segments[0], marker: "Ver:"),
      let server = version(of: segments[1], marker: "Ver:")
    else {
      return .malformed(reason: "checkserver versions could not be read")
    }
    for value in [client, server] where !profile.covers(version: value) {
      return .unsupportedVersion(value)
    }
    return .parsed(HDCParsedServerCheck(clientVersion: client, serverVersion: server))
  }

  /// Parses `hdc list targets -v` output. Each target line is
  /// `<connectKey>\t\t<transport>\t<state>\tlocalhost`; the exact `[Empty]`
  /// sentinel parses to an empty list. Line order is irrelevant to
  /// equality of the parsed value's set semantics; the parser preserves
  /// input order for display but callers compare normalized sets.
  package static func parseTargetList(
    stdout: Data,
    profile: HDCCompatibilityProfile,
    toolVersion: String,
    truncated: Bool
  ) -> HDCObservationParseOutcome<HDCParsedTargetList> {
    if truncated { return .truncated }
    guard profile.covers(version: toolVersion) else {
      return .unsupportedVersion(toolVersion)
    }
    guard let text = String(data: stdout, encoding: .utf8) else {
      return .invalidEncoding
    }
    let lines = targetOutputLines(text)
    guard !lines.isEmpty else { return .empty }
    if lines.map(\.normalized) == ["[Empty]"] {
      return .parsed(HDCParsedTargetList(targets: []))
    }
    var targets: [HDCParsedTargetLine] = []
    for line in lines {
      let columns = line.normalized.split(separator: "\t", omittingEmptySubsequences: false)
        .map(String.init)
      guard columns.count == 5, columns[1].isEmpty, columns[4] == "localhost" else {
        return invalidTargetOutput(
          "target line is not the registered 5-column family", line: line,
          columnCount: columns.count)
      }
      let key = columns[0]
      guard !key.isEmpty, key.utf8.count <= 128,
        key.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
      else {
        return invalidTargetOutput(
          "connect key length out of bounds", line: line, columnCount: columns.count)
      }
      let transport = columns[2]
      guard ["USB", "TCP", "UART"].contains(transport) else {
        return invalidTargetOutput(
          "unregistered target transport", line: line, columnCount: columns.count)
      }
      let state = columns[3]
      guard ["Connected", "Unauthorized", "Offline"].contains(state) else {
        return invalidTargetOutput(
          "unregistered target state", line: line, columnCount: columns.count)
      }
      targets.append(
        HDCParsedTargetLine(connectKey: key, transport: transport.lowercased(), state: state))
    }
    return .parsed(HDCParsedTargetList(targets: targets))
  }
}
