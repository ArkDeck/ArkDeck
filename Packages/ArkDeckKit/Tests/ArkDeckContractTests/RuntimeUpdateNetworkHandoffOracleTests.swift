import Foundation
import XCTest

@testable import ArkDeckClientKit
@testable import ArkDeckCore

/// Executes the actual Swift facade with sealed temporary files and fixture-only
/// transport/signature/reveal seams. No production URL or Finder is invoked.
final class RuntimeUpdateNetworkHandoffOracleTests: XCTestCase {
  func testActualSwiftDownloadAndHandoffForRust() async throws {
    let now = ISO8601Timestamps.parseCanonicalPlain("2026-09-26T00:00:00Z")!
    let bytes = Data("abc".utf8)
    let payload = UpdateFeedPayload(
      sequence: 1, version: "2.0.0", minimumSystemVersion: "14.0.0",
      architectures: ["arm64"], issuedAt: "2026-09-25T00:00:00Z",
      expiresAt: "2026-09-27T00:00:00Z",
      artifact: UpdateArtifactDescriptor(
        url: "https://github.com/ArkDeck/ArkDeck/a.dmg", byteLength: 3,
        sha256: UpdateFeedCodec.sha256(bytes)), releaseNotesSummary: "Fixture")
    let canonical = try UpdateFeedCodec.canonicalPayload(payload)
    let feed = VerifiedUpdateFeed(
      payload: payload, canonicalPayload: canonical,
      payloadSHA256: UpdateFeedCodec.sha256(canonical))
    var rows: [JSONValue] = []
    for scenario in ["success", "noConsent", "lateCancel", "revealFailure", "validationFailure",
      "downloadFailure", "downloadOverflow", "downloadCancelled"] {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "arkdeck-consumer-oracle-\(UUID().uuidString)", directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: root) }
      let cache = UpdateArtifactStore(directory: root.appending(path: "cache", directoryHint: .isDirectory))
      let state = RuntimeUpdateStateStore(directory: root.appending(path: "state", directoryHint: .isDirectory), now: { now })
      _ = try state.load()
      _ = try state.replace(expectedGeneration: 0, state: .available(feed))
      let fixture = ConsumerOracleEffects(bytes: bytes, state: state, scenario: scenario)
      let facade = try RuntimeUpdateApplicationFacade(
        streamer: fixture,
        verifier: UpdateFeedVerifier(trust: .production, replayStore: fixture),
        artifactStore: cache, artifactValidator: fixture, preferences: fixture,
        stateStore: state, eventLogger: fixture)
      var steps: [JSONValue] = []
      for action in ["download", "handoff", "repeatHandoff"] {
        var succeeded = false
        do {
          if action == "download" {
            _ = try await facade.downloadAvailableUpdate()
          } else {
            _ = try await facade.handoff(explicitConsent: scenario != "noConsent", revealer: fixture)
          }
          succeeded = true
        } catch { /* The actual durable result and observed effects are recorded below. */ }
        let snapshot = try state.load()
        let status = RuntimeUpdateStatusProjection(snapshot: snapshot)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        steps.append(.object([
          "action": .string(action), "succeeded": .bool(succeeded),
          "generation": .unsignedInteger(status.generation), "phase": .string(status.phase),
          "isBusy": .bool(status.isBusy), "cancellationRequested": .bool(status.cancellationRequested),
          "failureCode": status.failureCode.map(JSONValue.string) ?? .null,
          "updatedAtUtc": .string(status.updatedAtUTC),
          "reveals": .integer(Int64(fixture.reveals)), "validations": .integer(Int64(fixture.validations)),
          "artifacts": .integer(Int64(names.filter { $0.hasSuffix(".dmg") }.count)),
          "partials": .integer(Int64(names.filter { $0.hasSuffix(".part") }.count)),
          "events": .array(fixture.events.map(JSONValue.string)),
        ]))
      }
      rows.append(.object(["name": .string(scenario), "steps": .array(steps)]))
    }
    let output = try CanonicalJSONEncoders.canonicalPretty().encode(JSONValue.object([
      "producer": .string("RuntimeUpdateNetworkHandoffOracleTests"),
      "feedBase64": .string(try CanonicalJSONEncoders.canonical().encode(feed).base64EncodedString()),
      "cases": .array(rows),
    ])) + Data("\n".utf8)
    var repository = URL(filePath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    if ProcessInfo.processInfo.environment["ARKDECK_RUST_UPDATE_CONSUMER_RECORD"] != nil {
      try HDCOracleHarness.recordOrCompare(
        ["consumer.json": output], variable: "ARKDECK_RUST_UPDATE_CONSUMER_RECORD",
        oracle: repository.appending(path: "rust/tests/fixtures/runtime-update-network"))
    } else {
      XCTAssertEqual(output, try Data(contentsOf:
        repository.appending(path: "rust/tests/fixtures/runtime-update-network/consumer.json")))
    }
  }
}

private final class ConsumerOracleEffects: UpdateHTTPStreaming, UpdateArtifactValidating,
  UpdateArtifactRevealing, UpdateReplayStoring, AutoUpdatePreferenceStoring,
  AutoUpdateEventLogging, @unchecked Sendable
{
  private let bytes: Data
  private let state: RuntimeUpdateStateStore
  private let scenario: String
  private let lock = NSLock()
  private var revealCount = 0
  private var validationCount = 0
  private var recordedEvents: [String] = []
  var reveals: Int { lock.withLock { revealCount } }
  var validations: Int { lock.withLock { validationCount } }
  var events: [String] { lock.withLock { recordedEvents } }
  init(bytes: Data, state: RuntimeUpdateStateStore, scenario: String) {
    self.bytes = bytes; self.state = state; self.scenario = scenario
  }
  func stream(for request: URLRequest, maximumBytes: UInt64) -> AsyncThrowingStream<Data, any Error> {
    XCTAssertEqual(maximumBytes, 3)
    return AsyncThrowingStream { continuation in
      if scenario == "downloadFailure" {
        continuation.finish(throwing: URLError(.networkConnectionLost))
      } else if scenario == "downloadOverflow" {
        continuation.yield(bytes + Data([0])); continuation.finish()
      } else {
        if scenario == "downloadCancelled" {
          do { _ = try state.requestCancellation() }
          catch { continuation.finish(throwing: error); return }
        }
        continuation.yield(bytes); continuation.finish()
      }
    }
  }
  func validate(_ artifact: DownloadedUpdateArtifact) throws -> ValidatedUpdateArtifact {
    lock.withLock { validationCount += 1 }
    if scenario == "validationFailure" { throw UpdateArtifactSecurityError.artifactReplaced }
    let identity = try UpdateArtifactStore.verifyFile(
      at: artifact.url, expectedLength: 3, expectedSHA256: UpdateFeedCodec.sha256(bytes))
    XCTAssertEqual(identity, artifact.identity)
    return ValidatedUpdateArtifact(downloaded: artifact, teamIdentifier: "ABCDEFGHIJ")
  }
  @MainActor func revealInFinder(_ url: URL) throws {
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    lock.withLock { revealCount += 1 }
    if scenario == "lateCancel" { _ = try state.requestCancellation() }
    if scenario == "revealFailure" { throw CocoaError(.fileReadUnknown) }
  }
  func validateAndCommit(_ candidate: UpdateReplayRecord) throws -> UpdateReplayDecision {
    XCTFail("preseeded available state must not check a feed"); return .accepted
  }
  func automaticChecksEnabled() -> Bool { true }
  func setAutomaticChecksEnabled(_ enabled: Bool) { XCTFail("not a preference mutation") }
  func lastCheckAttempt() -> Date? { nil }
  func recordCheckAttempt(_ date: Date) { XCTFail("not a feed check") }
  func record(_ event: AutoUpdateLogEvent) {
    lock.withLock { recordedEvents.append(String(describing: event)) }
  }
}
