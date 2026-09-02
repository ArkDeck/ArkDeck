import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckOpenHarmony

/// The daemon's managed startup binds the server it launched through the
/// identity family the selected tool belongs to. hdc 3.2.0f is published in
/// the OPENHARMONY-TOOLS@0.6.0 commandless family and has no `checkserver`
/// golden; gating it on the 3.2.0d read-only registry left protected `main`
/// unable to start with the only registered tool. These tests drive the
/// commandless managed-startup path through the real supervisor state machine
/// at the family's exact endpoint, with a fixed identity observer standing in
/// for the system observer, and prove the family split is closed in both
/// directions. Live-process and listener-family binding are covered by
/// `HDCManagedListenerFamilyContractTests`.
final class HDCManagedCommandlessStartupContractTests: XCTestCase {
  private struct FixedIdentityObserver: HDCServerProcessIdentityObserving {
    let observation: HDCServerProcessIdentityRawObservation
    func observe(
      endpoint: HDCServerEndpoint, selectedToolchain: HDCCandidate
    ) async -> HDCServerProcessIdentityRawObservation {
      observation
    }
  }

  /// The family's exact registered endpoint; nothing here binds it.
  private func exactEndpoint() throws -> HDCServerEndpointSelection {
    try HDCServerEndpointSelector.select(
      explicitEndpoint: HDCSupervisorObservationProbeCatalog.exactEndpoint)
  }

  /// A candidate carrying the 3.2.0f family identity. The fixed observer
  /// stands in for the system observer that would verify the executable.
  private let commandlessCandidate = HDCCandidate(
    path: URL(filePath: "/private/tmp/arkdeck-commandless-startup-hdc"),
    source: .userConfigured,
    sha256: HDCSupervisorObservationProbeCatalog.targetExecutableSHA256)

  private func receipt(
    for candidate: HDCCandidate, endpoint: HDCServerEndpointSelection,
    startSeconds: UInt64 = 1_756_800_000, startMicroseconds: UInt64 = 424_242
  ) -> HDCServerProcessIdentityReceipt {
    HDCServerProcessIdentityReceipt(
      pid: 4_321, startSeconds: startSeconds, startMicroseconds: startMicroseconds,
      executablePath: candidate.path.resolvingSymlinksInPath().standardizedFileURL,
      executableSHA256: candidate.sha256, endpoint: endpoint.endpoint)
  }

  private func makeProcessSupervisor(
    supervisor: HDCServerSupervisor, observation: HDCServerProcessIdentityRawObservation
  ) -> HDCServerProcessSupervisor {
    HDCServerProcessSupervisor(
      supervisor: supervisor,
      additionalChildEnvironment: [:],
      readOnlyProbeRegistry: .pinnedProduction,
      semanticProfile: .pinnedProduction,
      identityObserver: FixedIdentityObserver(observation: observation))
  }

  func testManagedStartupBindsTheCommandlessFamilyWithReadinessHealth() async throws {
    let endpoint = try exactEndpoint()
    let receipt = receipt(for: commandlessCandidate, endpoint: endpoint)
    let generation = try XCTUnwrap(receipt.stableGeneration)
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor, observation: .observed(receipt))
    let result = await processSupervisor.observeManagedCommandlessServer(
      endpoint: endpoint, toolchain: commandlessCandidate, serverVersion: "3.2.0f")
    guard case .observed(let observedGeneration, let observedVersion) = result.classification else {
      return XCTFail("commandless managed startup did not observe: \(result.classification)")
    }
    XCTAssertEqual(observedGeneration, generation)
    XCTAssertEqual(observedVersion, "3.2.0f")
    XCTAssertEqual(result.identity, receipt)
    let stateValue = await supervisor.state(for: endpoint.endpoint)
    let state = try XCTUnwrap(stateValue)
    XCTAssertEqual(state.health, .healthy, "readiness checkserver is the family's health source")
    XCTAssertEqual(state.generation, generation)
    XCTAssertEqual(state.version, .known("3.2.0f"))
  }

  func testTheCommandlessFamilyIsUnsupportedByTheReadOnlyRegistryPath() async throws {
    // Documents why the host must branch: the 0.3.0 read-only registry path
    // refuses the 3.2.0f identity outright, before any probe.
    let endpoint = try exactEndpoint()
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor,
      observation: .observed(receipt(for: commandlessCandidate, endpoint: endpoint)))
    let result = await processSupervisor.observeRegisteredExistingServer(
      endpoint: endpoint, toolchain: commandlessCandidate)
    guard case .unsupported(let reason) = result.classification else {
      return XCTFail("3.2.0f must be outside the 0.3.0 checkserver family: \(result.classification)")
    }
    XCTAssertTrue(reason.contains("OPENHARMONY-TOOLS@0.3.0"), reason)
    XCTAssertTrue(HDCServerProcessSupervisor.selectsCommandlessFamily(commandlessCandidate))
  }

  func testAToolOutsideTheCommandlessFamilyIsRefusedByTheCommandlessPath() async throws {
    let endpoint = try exactEndpoint()
    let other = HDCCandidate(
      path: commandlessCandidate.path, source: .userConfigured,
      sha256: HDCReadOnlyProbeRegistry.targetExecutableSHA256)
    XCTAssertFalse(HDCServerProcessSupervisor.selectsCommandlessFamily(other))
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor, observation: .observed(receipt(for: other, endpoint: endpoint)))
    let result = await processSupervisor.observeManagedCommandlessServer(
      endpoint: endpoint, toolchain: other, serverVersion: "3.2.0d")
    guard case .unsupported = result.classification else {
      return XCTFail("an executable outside 0.6.0 must not gain commandless managed health")
    }
    let state = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNotEqual(state?.health, .healthy)
  }

  func testAnEndpointOutsideTheRegistryIsRefused() async throws {
    let endpoint = try HDCServerEndpointSelector.select(explicitEndpoint: "127.0.0.1:18861")
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor,
      observation: .observed(receipt(for: commandlessCandidate, endpoint: endpoint)))
    let result = await processSupervisor.observeManagedCommandlessServer(
      endpoint: endpoint, toolchain: commandlessCandidate, serverVersion: "3.2.0f")
    guard case .unsupported(let reason) = result.classification else {
      return XCTFail("only the registered exact endpoint may bind: \(result.classification)")
    }
    XCTAssertTrue(reason.contains("endpoint"), reason)
    let state = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNotEqual(state?.health, .healthy)
  }

  func testAMissingReadinessVersionIsNotHealth() async throws {
    let endpoint = try exactEndpoint()
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor,
      observation: .observed(receipt(for: commandlessCandidate, endpoint: endpoint)))
    let result = await processSupervisor.observeManagedCommandlessServer(
      endpoint: endpoint, toolchain: commandlessCandidate, serverVersion: "")
    guard case .unknown = result.classification else {
      return XCTFail("an empty server version must stay unknown, never healthy: \(result.classification)")
    }
    let state = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNotEqual(state?.health, .healthy)
  }

  func testAnUnobservableProcessNeverBecomesHealthy() async throws {
    let endpoint = try exactEndpoint()
    let supervisor = HDCServerSupervisor(auditStore: InMemoryHDCServerLifecycleAuditStore())
    let processSupervisor = makeProcessSupervisor(
      supervisor: supervisor, observation: .unavailable(reason: "no listener owner"))
    let result = await processSupervisor.observeManagedCommandlessServer(
      endpoint: endpoint, toolchain: commandlessCandidate, serverVersion: "3.2.0f")
    guard case .unavailable = result.classification else {
      return XCTFail("no identity means no managed health: \(result.classification)")
    }
    let state = await supervisor.state(for: endpoint.endpoint)
    XCTAssertNotEqual(state?.health, .healthy)
  }
}
