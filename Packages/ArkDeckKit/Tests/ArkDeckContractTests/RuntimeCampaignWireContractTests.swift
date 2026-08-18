import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Historical campaign references remain wire-decodable so persisted jobs can
/// be inspected, but every new submission refuses them before dispatch.
final class RuntimeCampaignWireContractTests: XCTestCase {
  func testHistoricalReservationRoundTripsButCannotMixWithRuntimeCapability() throws {
    let request = try RuntimeOperationCodec.decodeRequest(
      historicalRequest(reservationID: "ain019-abc123"))
    let decoded = try RuntimeOperationCodec.decodeRequest(
      try RuntimeOperationCodec.encodeRequest(request))
    XCTAssertEqual(decoded.campaignReservation?.reservationID, "ain019-abc123")
    XCTAssertNil(decoded.authorization)

    XCTAssertThrowsError(
      try RuntimeOperationCodec.decodeRequest(
        historicalRequest(
          reservationID: "ain019-abc123",
          authorizationJSON: #", "authorization":{"capabilityId":"CAP-RT-X-1"}"#)))
    XCTAssertThrowsError(
      try RuntimeOperationCodec.decodeRequest(historicalRequest(reservationID: "no spaces")))
  }

  func testNewSubmissionRejectsHistoricalReservationBeforeAnyDispatch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-campaign-refusal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatchLog = DispatchLog()
    let provider = WorkspaceProvider(
      registry: WorkspaceProjectRegistry(roots: ["demo-app": "/tmp/demo-app"]),
      tool: WorkspaceInspectorTool(
        executablePath: "/usr/bin/grep",
        executableSHA256: String(repeating: "a", count: 64)))
    let engine = try RuntimeJobEngine(
      configuration: .init(
        stateDirectory: root.appending(path: "engine", directoryHint: .isDirectory)),
      providers: DeviceProviderRegistry(providers: [provider]),
      dispatcher: RecordingDispatcher(log: dispatchLog),
      capabilityStore: try RuntimeCapabilityStore(
        directoryURL: root.appending(path: "capabilities", directoryHint: .isDirectory)),
      artifactStore: try RuntimeArtifactStore(
        rootURL: root.appending(path: "artifacts", directoryHint: .isDirectory),
        nowUTC: { "2026-08-19T00:00:00Z" }),
      nowUTC: { "2026-08-19T00:00:00Z" })

    do {
      _ = try await engine.submit(historicalRequest(reservationID: "ain019-historical"))
      XCTFail("historical campaign references must never admit new work")
    } catch let error as RuntimeJobEngineError {
      guard case .rejected(let code, let detail) = error else {
        return XCTFail("unexpected rejection: \(error)")
      }
      XCTAssertEqual(code, .authorizationRequired)
      XCTAssertTrue(detail.contains("decode/export-only"), detail)
    }
    let dispatchCount = await dispatchLog.count
    XCTAssertEqual(dispatchCount, 0)
  }

  private actor DispatchLog {
    private(set) var count = 0
    func record() { count += 1 }
  }

  private struct RecordingDispatcher: RuntimeProcessDispatching {
    let log: DispatchLog
    func unavailableReason(providerID _: String) -> String? { nil }
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      await log.record()
      throw RuntimeDispatchFailure.failed("historical campaign request reached dispatch")
    }
  }

  private func historicalRequest(
    reservationID: String,
    authorizationJSON: String = ""
  ) -> Data {
    Data(
      """
      {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
      "requestId":"req-campaign-wire","idempotencyKey":"idem-campaign-wire",\
      "target":{"targetId":"demo-app"},\
      "operation":{"id":"workspace.inspect-source","version":1},\
      "inputs":{"projectRef":"demo-app","symbol":"RockchipFlash","fileScope":"*.swift"},\
      "campaignReservation":{"reservationId":"\(reservationID)"}\(authorizationJSON)}
      """.utf8)
  }
}
