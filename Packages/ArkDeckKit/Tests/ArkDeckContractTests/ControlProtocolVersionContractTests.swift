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

  func testEveryPublishedProtocolFactUsesTheOneDefinition() throws {
    XCTAssertEqual(ArkDeckControlProtocol.currentVersion, "1.0.0")
    XCTAssertEqual(ArkDeckAgentXPC.wireProtocolVersion, ArkDeckControlProtocol.currentVersion)
    XCTAssertEqual(AgentWireProtocol.version, ArkDeckControlProtocol.currentVersion)
    XCTAssertEqual(CLIProductVersion.controlProtocolVersion, ArkDeckControlProtocol.currentVersion)
    let fields = try ControlProtocolContract.requestFields(
      ArkDeckAgentXPC.requestFrame(method: "health", requestID: "req-1"))
    XCTAssertEqual(fields["contractIdentity"], .string(ArkDeckControlProtocol.contractIdentity))
    XCTAssertTrue(["health", "job.plan", "job.submit", "job.run"].allSatisfy(ArkDeckControlProtocol.methods.contains))
    XCTAssertFalse(ArkDeckControlProtocol.methods.contains("protocol.negotiate"))
    XCTAssertFalse(ArkDeckControlProtocol.methods.contains("capability.install"))
  }

  func testGeneratedProtocolMatchesTheLanguageNeutralRegistry() throws {
    let root = sourceRoot().deletingLastPathComponent()
    let bytes = try Data(contentsOf: root.appending(path: "Contracts/control-protocol.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(object["currentVersion"] as? String, ArkDeckControlProtocol.currentVersion)
    XCTAssertEqual(Set(object["methods"] as? [String] ?? []), ArkDeckControlProtocol.methods)
    XCTAssertEqual(object["maximumRequestFrameBytes"] as? Int, ArkDeckControlProtocol.maximumRequestFrameBytes)
    XCTAssertEqual(object["maximumResponseFrameBytes"] as? Int, ArkDeckControlProtocol.maximumResponseFrameBytes)
    for retired in ["legacyVersion", "targetVersion", "supportedExactVersions", "bootstrapMethod", "preBootstrapLegacyMethods"] {
      XCTAssertNil(object[retired])
    }
  }
}
