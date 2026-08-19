// Runtime-owned workspace isolation host.
//
// Copying a primary ProjectProfile is a host action, not a command selected by
// a caller. It runs only after Runtime has durably installed the typed action;
// every later patch/build/test still travels through the ordinary workspace
// provider against the derived `evolution-*` profile.

import ArkDeckCore
import ArkDeckWorkflows
import Foundation

package struct RuntimeOwnedWorkspaceDispatcher: RuntimeProcessDispatching {
  private let fallback: any RuntimeProcessDispatching
  private let manager: any WorkspaceIsolationManaging

  package init(
    fallback: any RuntimeProcessDispatching,
    manager: any WorkspaceIsolationManaging
  ) {
    self.fallback = fallback
    self.manager = manager
  }

  package func unavailableReason(providerID: String) -> String? {
    fallback.unavailableReason(providerID: providerID)
  }

  package func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    guard case .workspace(.prepareIsolatedCopy(let intent)) = plan.action else {
      if case .hostWorkspace = plan.kind {
        throw RuntimeDispatchFailure.failed(
          "host workspace plan does not carry its typed isolation action")
      }
      return try await fallback.dispatch(plan)
    }
    guard case .hostWorkspace(let descriptor) = plan.kind,
      descriptor.identifier == "workspace.prepare-isolated-copy/v1",
      descriptor.stepID == "prepare-isolated-copy",
      intent.runtimeOwnerID.hasPrefix("runtime-"),
      descriptor.jobID == String(intent.runtimeOwnerID.dropFirst("runtime-".count)),
      descriptor.actionSHA256 == intent.actionSHA256,
      plan.argumentZero == nil,
      plan.workingDirectory == nil,
      plan.hostLanding == nil
    else {
      throw RuntimeDispatchFailure.failed(
        "workspace isolation plan drifted from its typed action")
    }
    let started = Date()
    do {
      let result = try await manager.prepare(intent)
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: Data(), stderr: Data(), stdoutTruncated: false,
        durationSeconds: Date().timeIntervalSince(started),
        hostManagedRecordID: result.workspaceID,
        hostManagedSummary: result.summary)
    } catch is CancellationError {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "workspace isolation cancelled before durable readback")
    } catch let error as EvolutionWorkspaceError {
      // Isolation refusals carry tree-relative entries, refs, revisions or
      // reason tokens — never host paths — so the receipt can say what was
      // refused instead of hiding the cause behind a bare string.
      throw RuntimeDispatchFailure.failed(
        "workspace isolation refused: \(String(describing: error))")
    } catch {
      throw RuntimeDispatchFailure.failed("workspace isolation refused")
    }
  }
}
