// `maintainer update-feed prepare` and `assemble` write public update-feed
// material (TASK-XPA-018): the canonical payload, the signature input and the
// assembled feed. They wrote it with the complete Data Protection class,
// which macOS 27 refuses (NSCocoaError 513, EPERM), so every release run
// failed with ioFailure. The material is public and the Ed25519 signature is
// what vouches for it; it is now written atomically with no protection class,
// through one function.
//
// `prepare` is run end to end. `assemble` verifies what it writes against the
// production public key, by design with no trust a test could substitute, so
// no fixture feed reaches its write: that write is held by the function it
// goes through, and by the check that it does go through it.

import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckClientKit

final class CLIUpdateFeedWriteContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-update-feed-write", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testPrepareWritesThePayloadAndTheSignatureInput() throws {
    let artifact = root.appending(path: "ArkDeck-1.2.3.dmg")
    try Data("arkdeck".utf8).write(to: artifact)
    let output = root.appending(path: "feed", directoryHint: .isDirectory)
    try ArkDeckCommandLine.prepareUpdateFeed([
      "--sequence", "7", "--version", "1.2.3", "--minimum-system", "26.0",
      "--issued-at", "2026-09-26T00:00:00Z", "--expires-at", "2026-10-20T00:00:00Z",
      "--artifact", artifact.path,
      "--artifact-url",
      "https://github.com/ArkDeck/ArkDeck/releases/download/v1.2.3/ArkDeck-1.2.3.dmg",
      "--notes", "Fixes.", "--out", output.path,
    ])
    let payload = try Data(contentsOf: output.appending(path: "arkdeck-update-payload-v1.json"))
    let input = try Data(
      contentsOf: output.appending(path: "arkdeck-update-signature-input-v1.bin"))
    XCTAssertEqual(
      input,
      try UpdateFeedCodec.signatureInput(payload: payload, keyID: UpdateFeedTrust.productionKeyID))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(fields["sequence"] as? Int, 7)
    XCTAssertEqual(fields["version"] as? String, "1.2.3")
    let described = try XCTUnwrap(fields["artifact"] as? [String: Any])
    XCTAssertEqual(described["byteLength"] as? Int, 7)
    XCTAssertEqual(
      described["sha256"] as? String,
      SHA256.hash(data: Data("arkdeck".utf8)).map { String(format: "%02x", $0) }.joined())
    // The output directory stays the maintainer's alone.
    let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
  }

  /// The one function every update-feed write goes through, `assemble`'s
  /// feed included: atomic, and accepted by the host.
  func testUpdateFeedFilesAreWrittenAtomicallyWithNoProtectionClass() throws {
    let feed = root.appending(path: "arkdeck-update-feed-v1.json")
    try ArkDeckCommandLine.writeUpdateFeedFile(Data("first".utf8), to: feed)
    try ArkDeckCommandLine.writeUpdateFeedFile(Data("second".utf8), to: feed)
    XCTAssertEqual(try Data(contentsOf: feed), Data("second".utf8))
  }

  /// No update-feed write bypasses that function, and it names no protection
  /// class.
  func testEveryUpdateFeedWriteGoesThroughTheOneFunction() throws {
    let source = try String(
      contentsOf: packageRoot().appending(path: "Sources/ArkDeckCLI/ArkDeckCLIMain.swift"),
      encoding: .utf8)
    func body(of name: String) throws -> Substring {
      let start = try XCTUnwrap(source.range(of: "static func \(name)("), name)
      let next = source.range(of: "\n  static func ", range: start.upperBound..<source.endIndex)
      return source[start.lowerBound..<(next?.lowerBound ?? source.endIndex)]
    }
    let prepare = try body(of: "prepareUpdateFeed")
    let assemble = try body(of: "assembleUpdateFeed")
    XCTAssertTrue(prepare.contains("writeUpdateFeedFile(canonicalPayload, to: payloadURL)"))
    XCTAssertTrue(prepare.contains("writeUpdateFeedFile(signatureInput, to: inputURL)"))
    XCTAssertTrue(assemble.contains("writeUpdateFeedFile(envelope, to: output)"))
    for (name, code) in [("prepare", prepare), ("assemble", assemble)] {
      XCTAssertFalse(code.contains(".write(to:"), "\(name) writes around writeUpdateFeedFile")
      XCTAssertFalse(code.contains("FileProtection"), "\(name) names a protection class")
    }
    let writer = try body(of: "writeUpdateFeedFile")
    XCTAssertTrue(writer.contains("options: [.atomic]"))
    XCTAssertFalse(writer.contains("FileProtection"))
  }

  private func packageRoot() -> URL {
    // …/Tests/ArkDeckContractTests/CLIUpdateFeedWriteContractTests.swift -> package root
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
