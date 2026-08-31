import ArkDeckCore
import ArkDeckOpenHarmony
import ArkDeckProcess
import Foundation

/// The Runtime reads its own selected executable, native process identity,
/// durable Job inventory and USB-bracketed observations. No RPC supplies these
/// facts. This snapshot is diagnostic until the dispatch path revalidates it.
package struct HeadlessHDCControlImpactSource: HDCControlImpactObserving {
  private let executable: ResolvedExecutable
  private let endpoint: HDCServerEndpointSelection
  private let managedLaunch: @Sendable () -> HDCManagedProcessLaunch?
  private let supervisor: HDCServerSupervisor?
  private let engine: RuntimeJobEngine
  private let targets: RuntimeTargetStore
  private let observations: TargetObservationCoordinator
  package var endpointReference: String { "hdc-endpoint:" + SHA256Hex.string(of: Data(endpoint.endpoint.rawValue.utf8)) }

  package init(executable: ResolvedExecutable, endpoint: HDCServerEndpointSelection,
    managedLaunch: @escaping @Sendable () -> HDCManagedProcessLaunch?, engine: RuntimeJobEngine,
    targets: RuntimeTargetStore, observations: TargetObservationCoordinator,
    supervisor: HDCServerSupervisor? = nil) {
    self.executable = executable; self.endpoint = endpoint; self.managedLaunch = managedLaunch
    self.supervisor = supervisor
    self.engine = engine; self.targets = targets; self.observations = observations
  }

  package func readImpact() async throws -> HDCControlImpactReading {
    let path = URL(filePath: executable.path)
    let pinned = try VerifiedRegularFileDescriptor.open(path: path, expectedSHA256: executable.sha256,
      maximumBytes: 256 * 1024 * 1024, requireExecutable: true)
    let signature = try HeadlessHDCStatusObserver.signature(path)
    try pinned.revalidate()
    let launchBefore = managedLaunch()
    let supervisedBefore: HDCServerState? = if let supervisor {
      await supervisor.state(for: endpoint.endpoint)
    } else { nil }
    let server = await HDCControlServerObserver.observe(tool: HDCCandidate(path: path, source: .userConfigured, sha256: executable.sha256), endpoint: endpoint)
    try pinned.revalidate()
    let jobs = try await engine.listCurrentJobs()
    let targetsBefore = try targets.list()
    let devices = try await observations.snapshot()
    let targetsAfter = try targets.list()
    let jobsAfter = try await engine.listCurrentJobs()
    let jobProjection = Self.jobBlockers(jobs), finalJobs = Self.jobBlockers(jobsAfter)
    let inventoryDrifted = jobProjection != finalJobs || targetsBefore != targetsAfter
    // Include all durable targets: a disconnected participant can still own
    // affected work. No connect key becomes an external target identifier.
    let targetIDs = targetsAfter.map(\.targetID)
    let jobIDs = Array(Set(jobs.map(\.jobID) + jobsAfter.map(\.jobID))).sorted()
    var rows: [JSONValue] = [], relations: [JSONValue] = []
    var continuityMissing = false
    for row in devices.observations {
      let authorization = row.candidate.state == "Connected" ? "authorized" : row.candidate.state == "Unauthorized" ? "unauthorized" : "unknown"
      let health = row.candidate.state == "Connected" ? "connected" : row.candidate.state == "Offline" ? "offline" : "unknown"
      rows.append(.object(["observationId": .string(row.observationID), "generation": .string(String(devices.generation)),
        "authorization": .string(authorization), "health": .string(health)]))
      if let relation = row.relation {
        relations.append(.object(["observationId": .string(row.observationID), "generation": .string(String(devices.generation)),
          "serial": .string(relation.serial), "location": .string(relation.location), "attachmentId": .string(String(relation.attachmentID)),
          "vendorId": .integer(Int64(relation.vendorID)), "productId": .integer(Int64(relation.productID))]))
      } else { continuityMissing = true }
    }
    relations.sort { left, right in
      guard case .object(let l) = left, case .object(let r) = right,
        case .string(let a)? = l["observationId"], case .string(let b)? = r["observationId"] else { return false }
      return a.utf8.lexicographicallyPrecedes(b.utf8)
    }
    let gateUnknown = inventoryDrifted || continuityMissing
    let criticalState = gateUnknown ? "unknown" : jobIDs.isEmpty ? "clear" : "blocked"
    let gateReason: JSONValue = gateUnknown ? .string("hdc.participantInventoryUnproven") : jobIDs.isEmpty ? .null : .string("hdc.currentJobs")
    let finalServer = await HDCCommandlessServerIdentity.observe(
      toolchain: HDCCandidate(path: path, source: .userConfigured, sha256: executable.sha256), endpoint: endpoint.endpoint)
    let supervisedAfter: HDCServerState? = if let supervisor {
      await supervisor.state(for: endpoint.endpoint)
    } else { nil }
    let serverStable = finalServer.identity == server.identity
    let ownership: String
    var generation: JSONValue = .null
    if serverStable, let receipt = server.identity, receipt.executablePath.path == executable.path, receipt.executableSHA256 == executable.sha256,
      receipt.endpoint == endpoint.endpoint, let observedGeneration = receipt.stableGeneration, observedGeneration > 0 {
      generation = .string(String(observedGeneration))
      if let launch = launchBefore, launch == managedLaunch(), launch.matches(receipt),
        HDCCommandlessServerIdentity.verifiesManagedProcess(receipt, arguments: launch.arguments), managedLaunch() == launch { ownership = "arkDeckManaged" }
      else if let supervisedBefore, supervisedBefore == supervisedAfter,
        supervisedBefore.endpoint == endpoint.endpoint,
        supervisedBefore.health == .healthy,
        supervisedBefore.generation == observedGeneration,
        supervisedBefore.ownership == .arkDeckManaged
      { ownership = "arkDeckManaged" }
      else { ownership = "unknown" }
    } else { ownership = "unknown" }
    try pinned.revalidate()
    let clientVersion = HDCCommandlessServerIdentity.clientVersion(sha256: executable.sha256)
    let impact = try HDCControlImpact(["serverEndpointRef": .string(endpointReference), "endpoint": .string(endpoint.endpoint.rawValue),
      "serverOwnership": .string(ownership), "serverGeneration": generation, "serverHealth": .string(serverStable ? server.health.rawValue : "unknown"),
      "serverVersion": serverStable ? server.serverVersion.map(JSONValue.string) ?? .null : .null,
      "tool": .object(["reference": .null, "executablePath": .string(executable.path), "source": .string("runtimeConfiguration"),
        "sha256": .string(executable.sha256), "signature": signature, "version": clientVersion.map(JSONValue.string) ?? .null, "trust": .string("unverified")]),
      "affectedTargetIds": .array(targetIDs.map(JSONValue.string)), "affectedJobIds": .array(jobIDs.map(JSONValue.string)),
      "detectedOtherClientIds": .array([]), "otherClientsMayExist": .bool(true), "affectedDeviceObservations": .array(rows),
      "criticalJobGate": .object(["state": .string(criticalState), "blocking": .array(finalJobs), "reasonCode": gateReason]),
      "interruption": .object(["kind": .string("hdcEndpointUnavailable"), "affectsAllParticipants": .bool(true)]),
      "recovery": .object(["kind": .string("statusThenReconcile"), "replayAllowed": .bool(false)])])
    return .init(impact: impact, observationRelations: relations, blockerReasonCode: serverStable ? server.reasonCode : "hdc.serverFactsDrifted")
  }

  private static func jobBlockers(_ jobs: [RuntimeJobStatus]) -> [JSONValue] {
    jobs.sorted { $0.jobID < $1.jobID }.map { job in
      .object(["jobId": .string(job.jobID), "stepId": .null, "state": .string(job.state), "safeBoundary": .string("blocked"),
        "recovery": .string(job.outcomeUnknown ? "reconcileJob" : (job.outstandingResidueCount ?? 0) > 0 ? "continueCleanup" : job.waitingForHuman ? "inspectJob" : "waitForJob")])
    }
  }
}
