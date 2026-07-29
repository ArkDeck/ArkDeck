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
public struct HDCCompatibilityProfile: Sendable, Equatable {
  public let profileID: String
  /// Exact `Ver: x.y.zc` strings this profile covers (e.g. "3.2.0d", "3.2.0f").
  public let registeredVersions: Set<String>

  public init(profileID: String, registeredVersions: Set<String>) {
    self.profileID = profileID
    self.registeredVersions = registeredVersions
  }

  /// The registered production profile: the 3.2.0 observation family, with
  /// membership mirroring the pinned discovery/registry facts.
  public static let openHarmony320Family = HDCCompatibilityProfile(
    profileID: "OPENHARMONY-HDC-3.2.0-FAMILY@1",
    registeredVersions: ["3.2.0d", "3.2.0f"])

  public func covers(version: String) -> Bool {
    registeredVersions.contains(version)
  }
}

/// Explicit, closed outcomes. There is no "assume success" member and no
/// exit-code shortcut: every path is either a parsed value or a named
/// refusal.
public enum HDCObservationParseOutcome<Value: Sendable & Equatable>: Sendable, Equatable {
  case parsed(Value)
  case unsupportedVersion(String)
  case invalidEncoding
  case truncated
  case empty
  case malformed(reason: String)
}

public struct HDCParsedClientVersion: Sendable, Equatable {
  public let version: String
}

/// `hdc checkserver` reports both sides at once:
/// `Client version:Ver: X, server version:Ver: Y`. It is deliberately a
/// distinct shape from `hdc -v` - reusing the version parser here is the
/// defect the first device window exposed (it looked for lines starting
/// with "Ver:" and found none).
public struct HDCParsedServerCheck: Sendable, Equatable {
  public let clientVersion: String
  public let serverVersion: String

  public var versionsAgree: Bool { clientVersion == serverVersion }
}

public struct HDCParsedTargetLine: Sendable, Equatable {
  public let connectKey: String
  public let transport: String
  public let state: String
}

public struct HDCParsedTargetList: Sendable, Equatable {
  public let targets: [HDCParsedTargetLine]
}

public enum HDCObservationSemanticParser {
  /// Diagnostic noise the daemon may interleave with observation output.
  /// Matching is prefix-based on the trimmed line; the list is closed and
  /// additive per registered version evidence.
  private static let ignorableDiagnosticPrefixes: [String] = [
    "[I]", "[W]", "[D]", "* daemon", "Connect server failed",
  ]

  private static func normalizedLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { line in
        guard !line.isEmpty else { return false }
        return !ignorableDiagnosticPrefixes.contains { line.hasPrefix($0) }
      }
  }

  /// Parses `hdc -v` / `hdc checkserver` style version output:
  /// exactly one meaningful line of the form `Ver: <version>`.
  public static func parseClientVersion(
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
  public static func parseServerCheck(
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
  public static func parseTargetList(
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
    let lines = normalizedLines(text)
    guard !lines.isEmpty else { return .empty }
    if lines == ["[Empty]"] {
      return .parsed(HDCParsedTargetList(targets: []))
    }
    var targets: [HDCParsedTargetLine] = []
    for line in lines {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        .map(String.init)
      guard columns.count == 5, columns[1].isEmpty, columns[4] == "localhost" else {
        return .malformed(reason: "target line is not the registered 5-column family")
      }
      let key = columns[0]
      guard !key.isEmpty, key.utf8.count <= 128,
        key.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace })
      else {
        return .malformed(reason: "connect key length out of bounds")
      }
      let transport = columns[2]
      guard ["USB", "TCP", "UART"].contains(transport) else {
        return .malformed(reason: "unregistered target transport \(transport)")
      }
      let state = columns[3]
      guard ["Connected", "Unauthorized", "Offline"].contains(state) else {
        return .malformed(reason: "unregistered target state \(state)")
      }
      targets.append(
        HDCParsedTargetLine(connectKey: key, transport: transport.lowercased(), state: state))
    }
    return .parsed(HDCParsedTargetList(targets: targets))
  }
}
