import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// Public test-key signatures only. No release private key or production
/// replay/cache directory is read or changed by this oracle.
final class UpdateFeedSignedRustOracleTests: XCTestCase {
  private struct Replay: UpdateReplayStoring {
    func validateAndCommit(_ candidate: UpdateReplayRecord) throws -> UpdateReplayDecision {
      .accepted
    }
  }

  func testSignedCodecAndFieldBoundariesForRust() throws {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 42, count: 32))
    let keyID = "fixture-key"
    let trust = try UpdateFeedTrust(keyID: keyID, rawPublicKey: key.publicKey.rawRepresentation)
    let issued = "2026-09-26T00:00:00Z"
    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: issued))
    var rows: [JSONValue] = []
    let cases: [(String, UInt64, String, String)] = [
      ("ordinary", 1, "a.dmg", issued),
      ("uint53", 9_007_199_254_740_992, "a.dmg", issued),
      ("uint64max", UInt64.max, "a.dmg", issued),
      ("encodedDotUpper", 1, "a%2Edmg", issued),
      ("encodedDotLower", 1, "a%2edmg", issued),
      ("invalidEscape", 1, "%ZZ.dmg", issued),
      ("barePercent", 1, "%.dmg", issued),
      ("encodedSlash", 1, "dir%2Fa.dmg", issued),
      ("query", 1, "a.dmg?download=1", issued),
      ("unicodeDate", 1, "a.dmg", "2026-09-2éT00:00:00Z"),
      ("encodedHost", 1, "https://%67ithub.com/ArkDeck/a.dmg", issued),
      ("rawBracketsPath", 1, "[x].dmg", issued),
      ("rawBracketsQuery", 1, "a.dmg?x=[1]", issued),
      ("invalidUTF8Path", 1, "%FF.dmg", issued),
    ]
    for (name, sequence, path, timestamp) in cases {
      let payload = UpdateFeedPayload(
        sequence: sequence, version: "1.2.3", minimumSystemVersion: "14.0",
        architectures: ["arm64"], issuedAt: timestamp, expiresAt: "2026-09-27T00:00:00Z",
        artifact: UpdateArtifactDescriptor(
          url: path.hasPrefix("https://") ? path : "https://github.com/ArkDeck/\(path)", byteLength: sequence,
          sha256: String(repeating: "ab", count: 32)), releaseNotesSummary: "测试 release")
      let bytes = try UpdateFeedCodec.canonicalPayload(payload)
      let signature = try key.signature(for: UpdateFeedCodec.signatureInput(payload: bytes, keyID: keyID))
      let envelope = try UpdateFeedCodec.assemble(canonicalPayload: bytes, signature: signature, keyID: keyID)
      let decoded = try UpdateFeedCodec.decodeAndVerify(envelope, trust: trust)
      XCTAssertEqual(decoded.canonicalPayload, bytes)
      let result: String
      do {
        _ = try UpdateFeedVerifier(trust: trust, replayStore: Replay()).verify(
          envelope, context: UpdateVerificationContext(
            installedVersion: "0.0.0", systemVersion: "27.0.0", architecture: "arm64"), now: now)
        result = "valid"
      } catch {
        result = String(describing: error)
      }
      rows.append(.object([
        "name": .string(name), "payloadBase64": .string(bytes.base64EncodedString()),
        "envelopeBase64": .string(envelope.base64EncodedString()), "result": .string(result),
      ]))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let output = try encoder.encode(JSONValue.object([
      "producer": .string("UpdateFeedSignedRustOracleTests"),
      "keyId": .string(keyID),
      "publicKeyBase64": .string(key.publicKey.rawRepresentation.base64EncodedString()),
      "now": .string(issued), "cases": .array(rows),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    try HDCOracleHarness.recordOrCompare(
      ["signed.json": output], variable: "ARKDECK_RUST_SIGNED_FEED_RECORD",
      oracle: repository.appending(path: "rust/tests/fixtures/update-feed"))
  }
}
