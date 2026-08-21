import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

// CHG-2026-068 LPP-AC-1/2: the lane plan preview performs only assessment and
// materialization calls. Nothing here imports, starts, permits, or persists.

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
    enum Role: String { case controller, publicAssessment }
    let recorder: CallRecorder
    var role: Role = .controller
    var inspectKnowsArtifact = true
    var observedTopology = LanePlanPreviewContractTests.topology
    var mechanicsState = "hardwareCampaign"
    var unavailableReason = "maturity is hardwareGated"
    static let mechanicsKey = String(repeating: "9", count: 64)

    func importArtifact(
      contentsOf _: URL, expectedSHA256: String, requestID _: String
    ) throws -> ArkForgeImportArtifactResponse {
      recorder.record("\(role.rawValue).importArtifact")
      return ArkForgeImportArtifactResponse(
        artifactID: expectedSHA256, contentSHA256: expectedSHA256, sizeBytes: 1,
        deduplicated: false)
    }

    func inspectArtifact(
      artifactID: String, requestID _: String
    ) throws -> ArkForgeInspectArtifactResponse {
      recorder.record("\(role.rawValue).inspectArtifact")
      guard inspectKnowsArtifact else { throw StoreMiss() }
      return ArkForgeInspectArtifactResponse(
        formatID: "rockchip.dayu200", contentSHA256: artifactID, sizeBytes: 1,
        manifestSHA256: String(repeating: "b", count: 64), buildFacts: [:])
    }

    func discoverDevices(requestID _: String) throws -> [ArkForgeDeviceObservation] {
      recorder.record("\(role.rawValue).discoverDevices")
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
      recorder.record("\(role.rawValue).materializePlan")
      XCTAssertEqual(body.artifactID, LanePlanPreviewContractTests.archive)
      XCTAssertEqual(body.profileID, LanePlanPreviewContractTests.profileID)
      if role == .publicAssessment {
        XCTAssertTrue(body.authoritySupportKeySHA256.isEmpty)
        return .assessment(
          ArkForgePlanAssessment(
            availability: "unavailable",
            unavailableReason: "public sessions cannot publish executable plans",
            unknowns: ["RK-A01": "public assessment"],
            mechanicsMaturityKeySHA256: Self.mechanicsKey,
            mechanicsMaturityState: "hardwareGated",
            authoritySupportKeySHA256: String(repeating: "8", count: 64),
            authoritySupportState: "hardwareGated"))
      }
      let keyHex = SHA256Hex.lowercaseHex(Data(body.authoritySupportKeySHA256))
      let pendingHex = SHA256Hex.lowercaseHex(Data(ArkForgeAuthoritySupport.pendingKeySHA256))
      if keyHex == pendingHex {
        return .assessment(
          ArkForgePlanAssessment(
            availability: "unavailable", unavailableReason: unavailableReason,
            unknowns: mechanicsState == "hardwareCampaign"
              ? ["RK-A01": "pending authority support"] : ["RK-M02": "hardwareGated"],
            mechanicsMaturityKeySHA256: Self.mechanicsKey,
            mechanicsMaturityState: mechanicsState,
            authoritySupportKeySHA256: pendingHex,
            authoritySupportState: "hardwareGated"))
      }
      return .plan(
        ArkForgeExecutablePlan(
          planID: "PLAN-preview", planSHA256: String(repeating: "d", count: 64),
          providerExecutionPlanSHA256: "", publicProjectionSHA256: "",
          expiresAtEpochMS: .max, executionPurpose: "primaryFlash",
          mechanicsMaturityKeySHA256: Self.mechanicsKey,
          mechanicsMaturityState: mechanicsState,
          mechanicsMaturityCampaign: body.authoritySupportDetail,
          authoritySupportKeySHA256: keyHex,
          authoritySupportState: body.authoritySupportState,
          authoritySupportCampaign: body.authoritySupportDetail))
    }
  }

  private func host(_ source: RecordingPlanSource) -> ArkForgeLaneHost {
    var publicSource = source
    publicSource.role = .publicAssessment
    let assessmentSource = publicSource
    return ArkForgeLaneHost(
      connection: .init(socketPath: "/tmp/unused.sock", controllerSessionID: "S"),
      toolchainSHA256: String(repeating: "0", count: 64),
      makePerformer: { _, _ in preconditionFailure("a preview never builds a performer") },
      makeClient: { _ in preconditionFailure("a preview never opens the job client") },
      makeMaterializer: { _ in source },
      makeAssessmentSource: { _ in assessmentSource },
      authoritySupport: scriptedAuthoritySupport(),
      makeAuthority: { _, _, _, _ in
        preconditionFailure("a preview never builds an authority")
      })
  }

  func testPreviewUsesTwoFailClosedAssessmentsBeforeTheExecutablePlan() async {
    let recorder = CallRecorder()
    let outcome = await host(RecordingPlanSource(recorder: recorder)).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    XCTAssertEqual(
      recorder.calls,
      [
        "controller.inspectArtifact", "publicAssessment.inspectArtifact",
        "publicAssessment.discoverDevices", "publicAssessment.materializePlan",
        "controller.discoverDevices", "controller.materializePlan",
        "controller.materializePlan",
      ],
      "the preview gets a public mechanics key and a gated controller assessment before "
        + "materializing the sealed plan")
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
      recorder.calls, ["controller.inspectArtifact"],
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
    XCTAssertEqual(
      recorder.calls,
      [
        "controller.inspectArtifact", "publicAssessment.inspectArtifact",
        "publicAssessment.discoverDevices",
      ])
  }

  func testAssessmentSurfacesAsPlanNotExecutableWithItsReasons() async {
    let recorder = CallRecorder()
    var source = RecordingPlanSource(recorder: recorder)
    source.mechanicsState = "hardwareGated"
    source.unavailableReason = "maturity is hardwareGated"
    let outcome = await host(source).previewPlan(
      archiveSHA256: Self.archive, profileID: Self.profileID, usbTopology: Self.topology)

    XCTAssertEqual(
      outcome,
      .planNotExecutable(
        availability: "unavailable", reason: "maturity is hardwareGated",
        unknowns: ["RK-M02": "hardwareGated"]))
  }
}
