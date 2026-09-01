import Foundation

package struct HDCControlServerObservation: Sendable {
  package let identity: HDCServerProcessIdentityReceipt?
  package let health: HDCServerHealth
  package let serverVersion: String?
  package let reasonCode: String?
}

/// Uses existing published probes only. In particular, the 3.2.0f identity
/// family does not gain a health/version command by joining a CLI preview.
package enum HDCControlServerObserver {
  package static func observe(tool: HDCCandidate, endpoint: HDCServerEndpointSelection) async -> HDCControlServerObservation {
    if tool.sha256 == HDCReadOnlyProbeRegistry.targetExecutableSHA256 {
      // This local observation-only Supervisor cannot persist a lifecycle
      // preview/confirmation/intent and cannot dispatch. The actual shared
      // lifecycle Supervisor must later own its own complete fresh scope.
      let supervisor = HDCServerSupervisor(auditStore: RefusingLifecycleAudit(), endpoint: endpoint.endpoint, participantImpactReliable: false)
      let result = await HDCServerProcessSupervisor(supervisor: supervisor).observeRegisteredExistingServer(endpoint: endpoint, toolchain: tool)
      if case .observed(let generation, let version) = result.classification,
        let receipt = result.identity, receipt.stableGeneration == generation {
        return .init(identity: receipt, health: .healthy, serverVersion: version, reasonCode: nil)
      }
      return .init(identity: nil, health: .unknown, serverVersion: nil, reasonCode: "hdc.registeredHealthObservationUnavailable")
    }
    let result = await HDCCommandlessServerIdentity.observe(toolchain: tool, endpoint: endpoint.endpoint)
    if case .observed = result.classification {
      return .init(identity: result.identity, health: .unknown, serverVersion: nil, reasonCode: "hdc.serverHealthUnproven")
    }
    return .init(identity: nil, health: .unknown, serverVersion: nil, reasonCode: "hdc.serverIdentityUnproven")
  }

  private struct RefusingLifecycleAudit: HDCServerLifecycleAuditStore {
    private enum Failure: Error { case observationOnly }
    func append(_ event: HDCServerLifecycleAuditEvent) async throws { throw Failure.observationOnly }
    func appendTerminalReconciliation(_ reconciliation: HDCServerLifecycleReconciliation) throws { throw Failure.observationOnly }
  }
}
