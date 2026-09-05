import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckRuntime
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// Retired authority cannot enter through wire, Codable or durable Job decoding.
final class RuntimeCampaignWireContractTests: XCTestCase {
  func testHistoricalReservationIsRejectedEvenUnderTheCurrentVersion() throws {
    for version in ["1.0.0", "2.0.0"] {
      let bytes = Data(String(decoding: historicalRequest(reservationID: "ain019-abc123"), as: UTF8.self)
        .replacingOccurrences(of: "2.0.0", with: version).utf8)
      XCTAssertThrowsError(try RuntimeOperationCodec.decodeRequest(bytes))
      XCTAssertThrowsError(try JSONDecoder().decode(RuntimeOperationRequest.self, from: bytes))
    }
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
      XCTAssertTrue(detail.contains("retired authority"), detail)
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
      {"documentType":"runtime-operation-request","schemaVersion":"1.0.0",\
      "requestId":"req-campaign-wire","idempotencyKey":"idem-campaign-wire",\
      "target":{"targetId":"demo-app"},\
      "operation":{"id":"workspace.inspect-source","version":1},\
      "inputs":{"projectRef":"demo-app","symbol":"RockchipFlash","fileScope":"*.swift"},\
      "campaignReservation":{"reservationId":"\(reservationID)"}\(authorizationJSON)}
      """.utf8)
  }
}
