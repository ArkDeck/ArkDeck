import Foundation
import XCTest

@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

// CHG-2026-068 LPP-AC-1/2: the lane plan preview is exactly three read-only
// calls, and every state it can return is an honest mapping of what the
// daemon said. Nothing here imports, starts, permits, or persists.

final class LanePlanPreviewContractTests: XCTestCase {
  private static let topology = "17956864"
  private static let archive = String(repeating: "e", count: 64)
  private static let profileID = "org.openharmony.dayu200"

  private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ call: String) {
      lock.lock()
      recorded.append(call)
      lock.unlock()
    }
    var calls: [String] {
      lock.lock()
      defer { lock.unlock() }
      return recorded
    }
  }

  private struct StoreMiss: Error {}

  private struct RecordingPlanSource: ArkForgePlanSource {
    let recorder: CallRecorder
    var inspectKnowsArtifact = true
    var observedTopology = LanePlanPreviewContractTests.topology
    var answer: ArkForgeMaterializePlanResponse = .plan(
      ArkForgeExecutablePlan(
        planID: "PLAN-preview", planSHA256: String(repeating: "d", count: 64),
        providerExecutionPlanSHA256: "", publicProjectionSHA256: "",
        expiresAtEpochMS: .max))

    func importArtifact(
      contentsOf _: URL, expectedSHA256: String, requestID _: String
    ) throws -> ArkForgeImportArtifactResponse {
      recorder.record("importArtifact")
      return ArkForgeImportArtifactResponse(
        artifactID: expectedSHA256, contentSHA256: expectedSHA256, sizeBytes: 1,
        deduplicated: false)
    }

    func inspectArtifact(
      artifactID: String, requestID _: String
    ) throws -> ArkForgeInspectArtifactResponse {
      recorder.record("inspectArtifact")
      guard inspectKnowsArtifact else { throw StoreMiss() }
      return ArkForgeInspectArtifactResponse(
        formatID: "rockchip.dayu200", contentSHA256: artifactID, sizeBytes: 1,
        manifestSHA256: String(repeating: "b", count: 64), buildFacts: [:])
    }

    func discoverDevices(requestID _: String) throws -> [ArkForgeDeviceObservation] {
      recorder.record("discoverDevices")
      return [
        ArkForgeDeviceObservation(
          observationID: "USB-2207-5000-01200000", observedAtEpochMS: 0,
          mode: "hdc-normal",
          topologyDigest: ArkForgeObservationSelection.topologyDigest(
            usbTopology: observedTopology)!,
          descriptorDigest: String(repeating: "c", count: 64),
          identityStrength: "serialAndTopology", malformedDescriptor: false,
          protocolIdentity: [:])
      ]
    }

    func materializePlan(
      _ body: ArkForgeMaterializePlanRequest, requestID _: String
    ) throws -> ArkForgeMaterializePlanResponse {
      recorder.record("materializePlan")
      XCTAssertEqual(body.artifactID, LanePlanPreviewContractTests.archive)
      XCTAssertEqual(body.profileID, LanePlanPreviewContractTests.profileID)
      return answer
    }
  }

  private func host(_ source: RecordingPlanSource) -> ArkForgeLaneHost {
    ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: String(repeating: "0", count: 64),
      makePerformer: { _, _ in preconditionFailure("a preview never builds a performer") },
      makeClient: { _ in preconditionFailure("a preview never opens the job client") },
      makeMaterializer: { _ in source },
      makeAuthority: { _, _, _, _ in
        preconditionFailure("a preview never builds an authority")
      })
  }

  func testPreviewIsExactlyThreeReadOnlyCalls() async {
    let recorder = CallRecorder()
    let outcome = await host(RecordingPlanSource(recorder: recorder)).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    XCTAssertEqual(
      recorder.calls, ["inspectArtifact", "discoverDevices", "materializePlan"],
      "the preview is the read-only prefix of materialization and nothing else")
    XCTAssertEqual(
      outcome,
      .available(
        planID: "PLAN-preview", planSHA256: String(repeating: "d", count: 64),
        observationMode: "hdc-normal"))
  }

  func testMissingBundleIsAnHonestStateAndNeverTriggersAnImport() async {
    let recorder = CallRecorder()
    var source = RecordingPlanSource(recorder: recorder)
    source.inspectKnowsArtifact = false
    let outcome = await host(source).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    XCTAssertEqual(outcome, .bundleNotInLaneStore)
    XCTAssertEqual(
      recorder.calls, ["inspectArtifact"],
      "a store miss stops the preview; importing 731 MB to answer a preview is the "
        + "exact cost this state exists to avoid")
  }

  func testUnobservedDeviceReportsTheSelectionReason() async {
    let recorder = CallRecorder()
    var source = RecordingPlanSource(recorder: recorder)
    source.observedTopology = "18874368"
    let outcome = await host(source).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    guard case .deviceNotObserved(let reason) = outcome else {
      return XCTFail("a port-path mismatch must be an observation state, got \(outcome)")
    }
    XCTAssertTrue(reason.contains(Self.topology), reason)
    XCTAssertEqual(recorder.calls, ["inspectArtifact", "discoverDevices"])
  }

  func testAssessmentSurfacesAsPlanNotExecutableWithItsReasons() async {
    let recorder = CallRecorder()
    var source = RecordingPlanSource(recorder: recorder)
    source.answer = .assessment(
      ArkForgePlanAssessment(
        availability: "unavailable",
        unavailableReason: "maturity is hardwareGated",
        unknowns: ["RK-M02": "combination is hardwareGated"]))
    let outcome = await host(source).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    XCTAssertEqual(
      outcome,
      .planNotExecutable(
        availability: "unavailable", reason: "maturity is hardwareGated",
        unknowns: ["RK-M02": "combination is hardwareGated"]))
  }
}
