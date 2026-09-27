import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

/// Only the isolated SPK-9 carrier opts in. Every device/store-changing method
/// traps before reaching the SDK, even if the preview owner regresses.
final class ArkForgeMissingArchiveLiveTests: XCTestCase {
  private static let archive = String(repeating: "0", count: 64)
  private static let profile = "org.openharmony.dayu200@1.0.0"

  private final class InspectOnly: ArkForgePlanSource, @unchecked Sendable {
    let client: ArkForgeControllerClient
    private let lock = NSLock()
    private var count = 0
    init(_ client: ArkForgeControllerClient) { self.client = client }
    var inspections: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
    func inspectArtifact(artifactID: String, requestID: String) throws
      -> ArkForgeInspectArtifactResponse
    {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      XCTAssertEqual(count, 1)
      XCTAssertEqual(artifactID, ArkForgeMissingArchiveLiveTests.archive)
      do {
        let response = try client.inspectArtifact(artifactID: artifactID, requestID: requestID)
        XCTFail("the harness-owned fresh CAS must not contain this archive")
        return response
      } catch {
        guard case ArkForgeClientError.daemonRefused(let api, let status, let body) = error else {
          XCTFail("transport/codec failure is not a proven CAS miss: \(error)")
          throw error
        }
        XCTAssertEqual(api, .inspectArtifact)
        XCTAssertEqual(status, .notFound)
        XCTAssertEqual(body?.code, "ARTIFACT_NOT_FOUND")
        throw error
      }
    }
    func importArtifact(contentsOf _: URL, expectedSHA256 _: String, requestID _: String)
      throws -> ArkForgeImportArtifactResponse
    { preconditionFailure("CAS-miss preview must not import") }
    func discoverDevices(requestID _: String) throws -> [ArkForgeDeviceObservation] {
      preconditionFailure("CAS-miss preview must not discover devices")
    }
    func materializePlan(_ body: ArkForgeMaterializePlanRequest, requestID: String) throws
      -> ArkForgeMaterializePlanResponse
    { preconditionFailure("CAS-miss preview must not materialize") }
  }

  func testRealDaemonMissingArchivePreview() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let runtime = env["ARKDECK_SPK9_RUNTIME"] else {
      throw XCTSkip("use scripts/ci/run-spk9-preview-missing.py")
    }
    let expectedSHA = try XCTUnwrap(env["ARKDECK_SPK9_DAEMON_SHA256"])
    let report = try XCTUnwrap(env["ARKDECK_SPK9_SWIFT_REPORT"])
    let socket = URL(fileURLWithPath: runtime).appendingPathComponent("controller.sock").path
    let client = try ArkForgeControllerClient(socketPath: socket, timeoutSeconds: 5)
    XCTAssertFalse(client.helloAck.executionReady, "isolated daemon must remain unpaired")
    XCTAssertEqual(client.helloAck.toolchainSHA256, expectedSHA)
    let source = InspectOnly(client)
    let host = ArkForgeLaneHost(
      connection: .init(socketPath: socket, controllerSessionID: "SPK9-read-only"),
      toolchainSHA256: expectedSHA,
      makePerformer: { _, _ in preconditionFailure("no performer") },
      makeClient: { _ in preconditionFailure("no execution client") },
      makeMaterializer: { _ in source },
      makeAssessmentSource: { _ in preconditionFailure("no public assessment on a CAS miss") },
      authoritySupport: scriptedAuthoritySupport(campaign: ""),
      makeAuthority: { _, _, _, _ in preconditionFailure("no authority") })
    let result = await host.previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profile, usbTopology: "SPK9-fixture-no-device")
    XCTAssertEqual(result, .bundleNotInLaneStore)
    XCTAssertEqual(source.inspections, 1)
    let data = try JSONSerialization.data(withJSONObject: [
      "owner": "swift", "outcome": "bundleNotInLaneStore", "archiveSHA256": Self.archive,
      "profileReference": Self.profile, "calls": ["controller.inspectArtifact"],
      "refusalCode": "ARTIFACT_NOT_FOUND", "daemonSHA256": client.helloAck.toolchainSHA256,
      "executionReady": client.helloAck.executionReady,
    ], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: report), options: .atomic)
  }
}
