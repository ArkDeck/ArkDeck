// Runtime-owned workspace isolation host.
//
// Copying a primary ProjectProfile is a host action, not a command selected by
// a caller. It runs only after Runtime has durably installed the typed action;
// every later patch/build/test still travels through the ordinary workspace
// provider against the derived `evolution-*` profile.

import ArkDeckCore
import ArkDeckWorkflows
import Foundation

/// Late-binding seam for the engine-implemented reference ledger: the engine
/// is constructed after this dispatcher (it consumes it), so the composition
/// root installs the ledger once both exist. A sweep dispatched before
/// installation is refused by name rather than guessed at.
package final class WorkspaceReferenceLedgerHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var reading: (any WorkspaceReferenceLedgerReading)?

  package init() {}

  package func install(_ reading: any WorkspaceReferenceLedgerReading) {
    lock.withLock { self.reading = reading }
  }

  package func current() -> (any WorkspaceReferenceLedgerReading)? {
    lock.withLock { reading }
  }
}

package struct RuntimeOwnedWorkspaceDispatcher: RuntimeProcessDispatching {
  private let fallback: any RuntimeProcessDispatching
  private let manager: any WorkspaceIsolationManaging
  private let sweeper: EvolutionWorkspaceManager?
  private let referenceLedger: WorkspaceReferenceLedgerHandle?

  package init(
    fallback: any RuntimeProcessDispatching,
    manager: any WorkspaceIsolationManaging,
    sweeper: EvolutionWorkspaceManager? = nil,
    referenceLedger: WorkspaceReferenceLedgerHandle? = nil
  ) {
    self.fallback = fallback
    self.manager = manager
    self.sweeper = sweeper
    self.referenceLedger = referenceLedger
  }

  package func unavailableReason(providerID: String) -> String? {
    fallback.unavailableReason(providerID: providerID)
  }

  package func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
    if case .workspace(.sweepIsolatedCopies(let sweep)) = plan.action {
      return try await dispatchSweep(sweep, plan: plan)
    }
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

  /// Testimony is composed here, at execution, exclusively from the two
  /// stores the runtime itself owns: the manager's persisted workspace
  /// inventory (with the same vouching adoption applies) and the engine's
  /// durable job ledger. Unvouched or unreferenced trees are simply not
  /// attested, which the sweep classifies as untouchable; the durable
  /// intent's creation instant is the retention clock, so a replay reasons
  /// about the same moment the journal recorded (CHG-2026-067).
  private func dispatchSweep(
    _ sweep: WorkspaceSweepIntent, plan: TypedProcessPlan
  ) async throws -> ProviderProcessReceipt {
    guard case .hostWorkspace(let descriptor) = plan.kind,
      descriptor.identifier == "workspace.sweep-isolated-copies/v1",
      descriptor.stepID == "sweep-isolated-copies",
      sweep.runtimeOwnerID.hasPrefix("runtime-"),
      descriptor.jobID == String(sweep.runtimeOwnerID.dropFirst("runtime-".count)),
      descriptor.actionSHA256 == sweep.actionSHA256,
      plan.argumentZero == nil,
      plan.workingDirectory == nil,
      plan.hostLanding == nil
    else {
      throw RuntimeDispatchFailure.failed(
        "workspace sweep plan drifted from its typed action")
    }
    guard let sweeper else {
      throw RuntimeDispatchFailure.failed(
        "workspace sweep refused: no isolation store in this composition")
    }
    guard let ledger = referenceLedger?.current() else {
      throw RuntimeDispatchFailure.failed(
        "workspace sweep refused: the reference ledger is not installed")
    }
    let started = Date()
    do {
      var references: [EvolutionWorkspaceGCTaskReference] = []
      var attested: [String: WorkspaceReferenceLedgerFacts] = [:]
      for entry in sweeper.runtimeWorkspaceInventory() where entry.vouched {
        let facts = try await ledger.referenceFacts(
          prepareRuntimeOwnerID: entry.runtimeOwnerID,
          derivedProjectRef: entry.derivedProjectRef)
        guard facts.referencingJobCount > 0 else { continue }
        attested[entry.workspaceID] = facts
        references.append(
          EvolutionWorkspaceGCTaskReference(
            workspaceID: entry.workspaceID,
            htaskID: entry.runtimeOwnerID,
            lifecycle: EvolutionWorkspaceGCLifecycle(
              rawValue: facts.allTerminal ? "quiescent" : "activeJob",
              isTerminal: facts.allTerminal),
            updatedAtUTC: facts.newestTransitionUTC ?? entry.createdAtUTC))
      }
      let findings = try await sweeper.sweepTerminalWorkspaces(
        tasks: references,
        retention: EvolutionWorkspaceRetention(
          minimumTerminalAgeSeconds: sweep.minimumQuiescentSeconds,
          retainLatestTerminalCount: sweep.retainLatestCount,
          dryRun: sweep.dryRun),
        nowUTC: sweep.createdAtUTC)
      var entries: [JSONValue] = []
      var destroyed = 0
      for finding in findings.sorted(by: { $0.workspaceID < $1.workspaceID }) {
        if finding.disposition == .destroyed { destroyed += 1 }
        var fields: [String: JSONValue] = [
          "workspaceId": .string(finding.workspaceID),
          "disposition": .string(finding.disposition.rawValue),
          "reclaimedBytes": .integer(finding.reclaimedBytes),
        ]
        if let facts = attested[finding.workspaceID] {
          fields["referencingJobs"] = .integer(Int64(facts.referencingJobCount))
          fields["allReferencesTerminal"] = .bool(facts.allTerminal)
          if let newest = facts.newestTransitionUTC {
            fields["newestReferenceTransitionUtc"] = .string(newest)
          }
        }
        entries.append(.object(fields))
      }
      let document: [String: JSONValue] = [
        "documentType": .string("arkdeck-workspace-sweep"),
        "schemaVersion": .string("1.0.0"),
        "dryRun": .bool(sweep.dryRun),
        "retainLatestCount": .integer(Int64(sweep.retainLatestCount)),
        "minimumQuiescentSeconds": .integer(Int64(sweep.minimumQuiescentSeconds)),
        "sweptAtUtc": .string(sweep.createdAtUTC),
        "findings": .array(entries),
      ]
      let encoder = CanonicalJSONEncoders.canonicalPretty()
      let stdout = try encoder.encode(document)
      return ProviderProcessReceipt(
        exitStatus: 0,
        stdout: stdout, stderr: Data(), stdoutTruncated: false,
        durationSeconds: Date().timeIntervalSince(started),
        hostManagedRecordID: sweep.actionSHA256,
        hostManagedSummary: [
          "destroyed": String(destroyed),
          "retained": String(findings.count - destroyed),
          "dryRun": String(sweep.dryRun),
          "findingsSha256": WorkspaceProviderSupport.sha256(stdout),
        ])
    } catch is CancellationError {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "workspace sweep cancelled before its findings were durable")
    } catch let error as EvolutionWorkspaceError {
      throw RuntimeDispatchFailure.failed(
        "workspace sweep refused: \(String(describing: error))")
    } catch {
      throw RuntimeDispatchFailure.failed("workspace sweep refused")
    }
  }
}
