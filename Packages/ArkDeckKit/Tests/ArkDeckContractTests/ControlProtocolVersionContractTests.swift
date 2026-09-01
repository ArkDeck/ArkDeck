import Foundation
import XCTest

@testable import ArkDeckAgentClient
@testable import ArkDeckAgentDaemon
@testable import ArkDeckCLI
@testable import ArkDeckCore

/// §12: the local control protocol version has exactly one statement.
///
/// It used to have three. `ArkDeckAgentXPC.wireProtocolVersion` was the
/// intended source, but `AgentClient` put its own `"1.0.0"` literal in every
/// request frame and the CLI published its own `["1.0.0"]` as the versions it
/// supports. Nothing compared them. A drift would not have failed a build or a
/// test — it would have surfaced in the field as a daemon refusing its own
/// client with `unsupportedProtocolVersion`, which reads like a compatibility
/// problem rather than the editing mistake it actually is.
///
/// So the guard is not "the three agree today" — three constants agree until
/// someone edits one. It is that there is nothing left to disagree with.
final class ControlProtocolVersionContractTests: XCTestCase {

  private func sourceRoot() -> URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources")
  }

  private func swiftSources() throws -> [(path: String, text: String)] {
    let root = sourceRoot()
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var found: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
      found.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return found
  }

  /// The definition is allowed to contain the literal. Nothing else is.
  private static let definitionFile = "ArkDeckCore/ControlProtocolGenerated.swift"

  /// Every way a build could state the control protocol version a second time:
  /// filling the wire field with a literal, or publishing a literal list of
  /// versions it claims to speak.
  ///
  /// Deliberately narrow. `"1.0.0"` is a common schema version across this
  /// package and matching it everywhere would make the test a nuisance that
  /// gets deleted; what matters is a literal reaching *the control protocol*.
  func testTheControlProtocolVersionIsStatedInExactlyOnePlace() throws {
    let patterns = [
      #"protocolVersion: ""#,
      #"protocolVersion = ""#,
      #"wireProtocolVersion = ""#,
      #"ControlProtocolExactVersions = ["#,
      #"WireProtocolExactVersions = ["#,
    ]
    var offenders: [String] = []
    for (path, text) in try swiftSources() {
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        guard patterns.contains(where: { line.contains($0) }) else { continue }
        // A list built from the single constant is the point, not a violation.
        guard line.contains("\"") else { continue }
        if path == Self.definitionFile { continue }
        offenders.append("\(path):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
      }
    }
    XCTAssertEqual(
      offenders, [],
      """
      the control protocol version must come from \
      `ArkDeckAgentXPC.wireProtocolVersion` and nowhere else; these state it \
      again:
      \(offenders.joined(separator: "\n"))
      """)
  }

  /// The derived values really are derived. If `wireProtocolVersion` moves to
  /// `2.0.0`, every one of these moves with it and this test needs no edit —
  /// which is the property being asserted.
  func testEveryPublishedProtocolFactIsDerivedFromTheOneDefinition() {
    let version = ArkDeckAgentXPC.wireProtocolVersion
    XCTAssertEqual(AgentWireProtocol.version, version)
    XCTAssertEqual(
      CLIProductVersion.supportedControlProtocolExactVersions,
      ArkDeckControlProtocol.supportedExactVersions,
      "`--version` must publish what the client will actually send")
    XCTAssertEqual(CLIProductVersion.preferredControlProtocol, ArkDeckControlProtocol.targetVersion)

    let major = Int(version.split(separator: ".").first.map(String.init) ?? "") ?? -1
    XCTAssertEqual(ArkDeckAgentXPC.wireProtocolMajor, major)
    XCTAssertEqual(
      AgentWireProtocol.requiredMajor, major,
      "the daemon admits on the major of the version it says it speaks")
  }

  /// The frame the client actually builds carries that version — the assertion
  /// the three-literal arrangement could not make, because each constant only
  /// ever proved itself.
  func testTheRequestFrameTheClientBuildsCarriesTheOneVersion() throws {
    let frame = try ArkDeckAgentXPC.requestFrame(method: "health", requestID: "req-1")
    let decoded = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: frame) as? [String: Any])
    XCTAssertEqual(decoded["protocolVersion"] as? String, ArkDeckAgentXPC.wireProtocolVersion)

    // And the daemon admits exactly that major, so client and daemon cannot be
    // built from the same tree and still refuse each other.
    let admitted = Int(
      (decoded["protocolVersion"] as? String)?.split(separator: ".").first.map(String.init) ?? "")
    XCTAssertEqual(admitted, AgentWireProtocol.requiredMajor)
  }

  /// Every advertised version must survive the actual bootstrap selection.
  /// A v2 selection only publishes the methods that have a complete v2 handler.
  func testThePublishedListClaimsOnlyWhatThisBuildCanSpeak() {
    for version in ArkDeckAgentXPC.supportedWireProtocolExactVersions {
      let major = Int(version.split(separator: ".")[0])!
      XCTAssertEqual(
        try ControlProtocolNegotiation.select(
          client: [version], daemon: ArkDeckControlProtocol.supportedExactVersions,
          requiredMajor: major), version)
    }
    XCTAssertTrue(ArkDeckControlProtocol.targetMethods.contains("health"))
    XCTAssertTrue(
      ["job.plan", "job.submit", "job.run"].allSatisfy(
        ArkDeckControlProtocol.targetMethods.contains))
    XCTAssertFalse(ArkDeckControlProtocol.targetMethods.contains("capability.install"))
  }

  func testGeneratedProtocolVocabularyMatchesTheLanguageNeutralContract() throws {
    let root = sourceRoot().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appending(path: "Contracts/control-negotiation.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["legacyVersion"] as? String, ArkDeckControlProtocol.legacyVersion)
    XCTAssertEqual(object["targetVersion"] as? String, ArkDeckControlProtocol.targetVersion)
    XCTAssertEqual(
      object["supportedExactVersions"] as? [String], ArkDeckControlProtocol.supportedExactVersions)
    XCTAssertEqual(object["bootstrapVersion"] as? String, ArkDeckControlProtocol.bootstrapVersion)
    XCTAssertEqual(object["bootstrapMethod"] as? String, ArkDeckControlProtocol.bootstrapMethod)
    XCTAssertEqual(
      object["maximumBootstrapFrameBytes"] as? Int,
      ArkDeckControlProtocol.maximumBootstrapFrameBytes)
    XCTAssertEqual(
      Set(object["targetMethods"] as? [String] ?? []), ArkDeckControlProtocol.targetMethods)
    XCTAssertEqual(
      Set(object["preBootstrapLegacyMethods"] as? [String] ?? []),
      ArkDeckControlProtocol.preBootstrapLegacyMethods)
  }
}
