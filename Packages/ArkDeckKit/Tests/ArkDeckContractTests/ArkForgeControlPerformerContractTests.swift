import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

/// The performer's descriptors, validated by the host that will actually see
/// them.
///
/// The regression this file exists for: the lane once handed the performer a
/// single fabricated descriptor (`identifier: "arkforge.managedControl"`,
/// `actionSHA256: ""`) for all five actions of `enterUpdater`. Every unit in
/// that chain was tested against a stub of its neighbour, every suite passed,
/// and the real composition refused every control action it was ever given —
/// the flash stalled at STEP-001 with both sides waiting on the other. So this
/// suite runs the real `DurableRockchipRuntimeActionHost`, with its real
/// validation and its real record store, and stubs only the executor beneath
/// them: what is asserted is precisely the seam that was never exercised.
final class ArkForgeControlPerformerContractTests: XCTestCase {

  private struct FixedLoaderObserver: ArkForgeLoaderObserving {
    let identity: RockchipRuntimeLoaderIdentity

    func observeLoader(
      stableIdentitySHA256: String,
      expectedUSBTopology: String?,
      requestID _: String
    ) throws -> RockchipRuntimeLoaderIdentity {
      guard identity.serialDigestSHA256 == stableIdentitySHA256,
        expectedUSBTopology == nil || expectedUSBTopology == identity.topology
      else {
        throw ArkForgeLoaderObservationFailure.identityMismatch
      }
      return identity
    }
  }

  private final class RecordingExecutor: RockchipRuntimeActionExecuting,
    @unchecked Sendable
  {
    var executed: [(action: RockchipProviderAction, descriptor: HostManagedProcessDescriptor)] = []

    func unavailableReason() -> String? { nil }

    func execute(
      action: RockchipProviderAction,
      descriptor: HostManagedProcessDescriptor,
      rockchipExecutable: ResolvedExecutable,
      actionDirectory: URL
    ) async throws -> RockchipRuntimeActionExecutionResult {
      executed.append((action, descriptor))
      let summary: [String: String]
      switch action {
      case .rebindLoader:
        summary = [
          "loaderIdentitySha256": Fixture.identity,
          "usbTopology": Fixture.topology,
          "bindingRevision": "4",
        ]
      default:
        summary = ["usbState": "observed"]
      }
      return RockchipRuntimeActionExecutionResult(
        summary: summary, stdout: Data(), stderr: Data(), stdoutTruncated: false,
        subprocesses: [])
    }
  }

  private enum Fixture {
    static let identity = String(repeating: "a4", count: 32)
    static let topology = "17956864"
    static let connectKey = "7001005458323933328a25a89c9c214d"

    static func request(id: String) -> ArkForgeManagedControlRequest {
      ArkForgeManagedControlRequest(
        jobID: "JOB-1", stepID: "STEP-001", requestID: id, action: .enterUpdater,
        permitID: "PERMIT-1", expectedFacts: [], deadlineEpochMs: 2_000_000)
    }
  }

  private func makePerformer(
    executor: RecordingExecutor, storeRoot: URL,
    loaderObserver: any ArkForgeLoaderObserving = RefusingArkForgeLoaderObserver(
      reason: "fixture starts in HDC-normal")
  ) -> ArkForgeControlPerformer {
    ArkForgeControlPerformer(
      binding: .init(
        jobID: "job-affe0011", targetID: "TGT-1", bindingRevision: 4,
        connectKey: Fixture.connectKey,
        stableIdentitySHA256: Fixture.identity,
        usbTopology: Fixture.topology,
        rockchipExecutable: ResolvedExecutable(
          path: "/opt/rk/rkdeveloptool", sha256: String(repeating: "5c", count: 32))),
      host: DurableRockchipRuntimeActionHost(
        executor: executor,
        records: RockchipRuntimeActionRecordStore(rootURL: storeRoot)),
      loaderObserver: loaderObserver)
  }

  private func temporaryStore() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "performer-contract-\(UUID().uuidString.lowercased())")
    // Owner-only, as the record store demands of every directory it touches.
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func testEnterUpdaterRunsAllFiveActionsThroughTheValidatingHost() async throws {
    let executor = RecordingExecutor()
    let performer = makePerformer(executor: executor, storeRoot: try temporaryStore())

    let observation = try await performer.perform(Fixture.request(id: "REQ-1-control"))

    XCTAssertTrue(
      observation.accepted,
      "the validating host refused a performer action: \(observation.failureReason)")
    XCTAssertTrue(observation.observedDisconnect)
    XCTAssertTrue(observation.observedUniqueLoaderRebind)
    XCTAssertEqual(observation.facts["mode"], "Loader")
    XCTAssertEqual(observation.facts["stableIdentitySHA256"], Fixture.identity)
    XCTAssertEqual(observation.facts["usbTopology"], Fixture.topology)

    // The five actions, in the order the port publishes for `enterUpdater`,
    // each under its own catalog identifier — not one identifier for five.
    let identifiers = executor.executed.map(\.descriptor.identifier)
    XCTAssertEqual(
      identifiers,
      [
        "rockchip.iokit.observe-hdc-normal.v1",
        "rockchip.hdc.enter-loader.v1",
        "rockchip.hdc.wait-disconnect.v1",
        "rockchip.rockusb.wait-loader.v1",
        "rockchip.rockusb.rebind-loader.v1",
      ])
    // And each descriptor pins its own action's canonical digest.
    for (action, descriptor) in executor.executed {
      XCTAssertEqual(
        descriptor.actionSHA256,
        try RockchipHostManagedActionCatalog.actionSHA256(of: .rockchip(action)))
    }
  }

  func testAlreadyLoaderFastPathUsesDualSourceObservationWithoutRunningHDC() async throws {
    let executor = RecordingExecutor()
    let performer = makePerformer(
      executor: executor,
      storeRoot: try temporaryStore(),
      loaderObserver: FixedLoaderObserver(
        identity: RockchipRuntimeLoaderIdentity(
          serialDigestSHA256: Fixture.identity, topology: Fixture.topology)))

    let observation = try await performer.perform(Fixture.request(id: "REQ-already-loader"))

    XCTAssertTrue(observation.accepted)
    XCTAssertTrue(observation.observedDisconnect)
    XCTAssertTrue(observation.observedUniqueLoaderRebind)
    XCTAssertEqual(observation.facts["mode"], "Loader")
    XCTAssertEqual(observation.facts["stableIdentitySHA256"], Fixture.identity)
    XCTAssertEqual(observation.facts["usbTopology"], Fixture.topology)
    XCTAssertTrue(
      executor.executed.isEmpty,
      "an already-Loader semantic success must not send HDC or start a vendor action")
  }

  func testARepeatedRequestReplaysItsRecordsAndAFreshRequestDoesNot() async throws {
    let executor = RecordingExecutor()
    let performer = makePerformer(executor: executor, storeRoot: try temporaryStore())

    _ = try await performer.perform(Fixture.request(id: "REQ-1-control"))
    XCTAssertEqual(executor.executed.count, 5)

    // The same control attempt again — a crash-and-repeat — replays the
    // recorded results instead of touching the device a second time.
    let replayed = try await performer.perform(Fixture.request(id: "REQ-1-control"))
    XCTAssertEqual(executor.executed.count, 5, "a repeat of the same attempt must replay")
    XCTAssertTrue(replayed.accepted)

    // A new attempt is a new question about the device, never a replay.
    _ = try await performer.perform(Fixture.request(id: "REQ-2-control"))
    XCTAssertEqual(executor.executed.count, 10)
  }

  func testTheAcceptedObservationBecomesAReceiptTheDaemonWillTake() async throws {
    let executor = RecordingExecutor()
    let performer = makePerformer(executor: executor, storeRoot: try temporaryStore())

    let observation = try await performer.perform(Fixture.request(id: "REQ-1-control"))
    let receipt = try ArkForgeManagedControlPort.receipt(
      jobID: "JOB-1", requestID: "REQ-1-control", action: .enterUpdater,
      observation: observation)

    XCTAssertTrue(receipt.accepted)
    // The daemon recomputes the canonical digest of the receipt's facts and
    // refuses a mismatch, so the port must have filled exactly that.
    XCTAssertEqual(
      receipt.evidenceSHA256,
      ArkForgeManagedControlPort.canonicalFactsDigest(observation.facts))
    XCTAssertEqual(receipt.evidenceSHA256.count, 32)
  }
}
