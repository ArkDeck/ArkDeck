import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

final class RuntimeUpdateRustOracleTests: XCTestCase {
  func testSwiftDurableStatesAndPathFreeProjectionsForRust() throws {
    let payload = UpdateFeedPayload(
      sequence: UInt64.max, version: "1.2.3", minimumSystemVersion: "14.0",
      architectures: ["arm64"], issuedAt: "2026-09-26T00:00:00Z", expiresAt: "2026-09-27T00:00:00Z",
      artifact: UpdateArtifactDescriptor(
        url: "https://github.com/ArkDeck/ArkDeck/a.dmg", byteLength: 1024,
        sha256: String(repeating: "ab", count: 32)), releaseNotesSummary: "测试 release")
    let bytes = try UpdateFeedCodec.canonicalPayload(payload)
    let feed = VerifiedUpdateFeed(
      payload: payload, canonicalPayload: bytes, payloadSHA256: UpdateFeedCodec.sha256(bytes))
    let downloaded = DownloadedUpdateArtifact(
      url: URL(filePath: "/private/tmp/arkdeck-update-fixture/12345678-1234-1234-1234-123456789abc.dmg"),
      byteLength: 1024, sha256: payload.artifact.sha256,
      identity: UpdateFileIdentity(
        device: 1, inode: 2, byteLength: 1024, mode: 0o100400,
        modifiedSeconds: 3, modifiedNanoseconds: 4, changedSeconds: 5, changedNanoseconds: 6))
    let validated = ValidatedUpdateArtifact(downloaded: downloaded, teamIdentifier: "FIXTURE123")
    let states: [(String, AutoUpdateState, Bool)] = [
      ("idle", .idle, false), ("checking", .checking, true),
      ("available", .available(feed), false),
      ("noUpdate", .noUpdate(.unsupportedSystem), false),
      ("downloading", .downloading(feed), true),
      ("verifying", .verifying(downloaded), true),
      ("awaitingConsent", .awaitingConsent(feed: feed, artifact: validated), false),
      ("handoffInProgress", .awaitingConsent(feed: feed, artifact: validated), true),
      ("handedOff", .handedOff(downloaded.url), false),
      ("failed", .failed(.network), false), ("cancelled", .cancelled, false),
      ("filePathEscaping", .handedOff(URL(filePath: "/private/tmp/Application Support/测试%name.dmg")), false),
    ]
    let encoder = CanonicalJSONEncoders.canonical()
    var cases: [JSONValue] = []
    for (name, state, active) in states {
      let snapshot = RuntimeUpdateSnapshot(
        generation: UInt64.max, state: state,
        activeOperationID: active ? UUID(uuidString: "abcdef01-2345-6789-abcd-ef0123456789") : nil,
        cancellationRequested: active,
        updatedAtUTC: name == "filePathEscaping" ? "2026-09-26T00:00:00.123Z" : "2026-09-26T00:00:00Z")
      let encoded = try encoder.encode(snapshot)
      let status = RuntimeUpdateStatusProjection(snapshot: snapshot)
      let projection: JSONValue = .object([
        "schemaVersion": .string(RuntimeUpdateStatusProjection.schemaVersion),
        "generation": .unsignedInteger(status.generation), "phase": .string(status.phase),
        "isBusy": .bool(status.isBusy), "cancellationRequested": .bool(status.cancellationRequested),
        "canCheck": .bool(status.canCheck), "canDownload": .bool(status.canDownload),
        "canHandoff": .bool(status.canHandoff),
        "updateVersion": status.updateVersion.map(JSONValue.string) ?? .null,
        "releaseNotesSummary": status.releaseNotesSummary.map(JSONValue.string) ?? .null,
        "artifactSha256": status.artifactSHA256.map(JSONValue.string) ?? .null,
        "artifactByteLength": status.artifactByteLength.map(JSONValue.unsignedInteger) ?? .null,
        "noUpdateReason": status.noUpdateReason.map(JSONValue.string) ?? .null,
        "failureCode": status.failureCode.map(JSONValue.string) ?? .null,
        "updatedAtUtc": .string(status.updatedAtUTC),
      ])
      cases.append(.object([
        "name": .string(name), "snapshotBase64": .string(encoded.base64EncodedString()),
        "projection": projection,
      ]))
    }
    var urlCases: [JSONValue] = []
    for url in [
      "file:///private/tmp/a%20b.dmg", "file:///private/tmp/a b.dmg",
      "file:///private/tmp/%.dmg", "file:///private/tmp/%ZZ.dmg",
      "file:///private/tmp/测试.dmg", "file:///private/tmp/%FF.dmg",
      "file:///private/tmp/a.dmg?x=[1]", "relative.dmg", "", "http://[broken",
    ] {
      let raw: JSONValue = .object([
        "schemaVersion": .string(RuntimeUpdateSnapshot.currentSchemaVersion),
        "generation": .unsignedInteger(1), "state": .object(["handedOff": .object(["_0": .string(url)])]),
        "cancellationRequested": .bool(false), "updatedAtUTC": .string("2026-09-26T00:00:00Z"),
      ])
      let data = try encoder.encode(raw)
      var canonical: Data?
      if let decoded = try? JSONDecoder().decode(RuntimeUpdateSnapshot.self, from: data) {
        canonical = try encoder.encode(decoded)
      }
      urlCases.append(.object([
        "url": .string(url), "snapshotBase64": .string(data.base64EncodedString()),
        "canonicalSnapshotBase64": canonical.map { .string($0.base64EncodedString()) } ?? .null,
        "recordAccepted": .bool(canonical == data),
      ]))
    }
    let outputEncoder = CanonicalJSONEncoders.canonicalPretty()
    let output = try outputEncoder.encode(JSONValue.object([
      "producer": .string("RuntimeUpdateRustOracleTests"), "cases": .array(cases), "urlCases": .array(urlCases),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if ProcessInfo.processInfo.environment["ARKDECK_RUST_UPDATE_STATE_RECORD"] != nil {
      try HDCOracleHarness.recordOrCompare(
        ["states.json": output], variable: "ARKDECK_RUST_UPDATE_STATE_RECORD",
        oracle: repository.appending(path: "rust/tests/fixtures/runtime-update"))
    } else {
      XCTAssertEqual(output, try Data(contentsOf:
        repository.appending(path: "rust/tests/fixtures/runtime-update/states.json")))
    }
  }
}
