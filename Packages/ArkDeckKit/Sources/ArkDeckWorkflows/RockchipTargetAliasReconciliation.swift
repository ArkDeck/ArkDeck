import ArkDeckCore
import ArkDeckStorage
import Foundation

/// Journal-only repair for one very narrow identity split: an HDC address was
/// adopted as a new target before a later, complete Flash durably proved that
/// the same address is the post-flash alias of an older Loader-bound target.
///
/// This service performs no device observation or provider dispatch. It does
/// not change either target and never rewrites an unknown Job outcome. The
/// resulting append-only relation is usable only after the later Flash has a
/// complete write/readback/reboot/HDC/build proof.
package struct ProductRockchipTargetAliasReconciler: Sendable {
  private static let requiredConfirmedStepIDs: Set<String> = [
    "enter-loader-mode", "flash-partitions", "verify-flash-readback",
    "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
  ]

  private let targetStore: RuntimeTargetStore
  private let bindingStore: RockchipProductBindingStore
  private let postFlashBindingStore: RockchipPostFlashHDCBindingStore
  private let stateDirectory: URL

  package init(
    targetStore: RuntimeTargetStore,
    applicationSupportRoot: URL,
    stateDirectory: URL
  ) {
    self.targetStore = targetStore
    self.bindingStore = RockchipProductBindingStore(rootURL: applicationSupportRoot)
    self.postFlashBindingStore = RockchipPostFlashHDCBindingStore(
      rootURL: applicationSupportRoot)
    self.stateDirectory = stateDirectory
  }

  package init(
    targetStore: RuntimeTargetStore,
    bindingStore: RockchipProductBindingStore,
    postFlashBindingStore: RockchipPostFlashHDCBindingStore,
    stateDirectory: URL
  ) {
    self.targetStore = targetStore
    self.bindingStore = bindingStore
    self.postFlashBindingStore = postFlashBindingStore
    self.stateDirectory = stateDirectory
  }

  /// Returns nil when no duplicate alias exists. Any partial or contradictory
  /// proof throws, leaving the #1242 ambiguity gate in force.
  package func reconcileIfProven() throws -> RuntimeTargetAliasResolution? {
    guard let route = try postFlashBindingStore.loadIfPresent(),
      let binding = try bindingStore.loadIfPresent(),
      let canonical = try targetStore.find(targetID: route.targetID),
      try route.covers(target: canonical, binding: binding)
    else { return nil }

    let aliases = try targetStore.list().filter {
      $0.targetID != canonical.targetID
        && $0.connectKey == route.hdcConnectKey
        && $0.stablePhysicalIdentitySHA256 == route.hdcIdentitySHA256
    }
    guard !aliases.isEmpty else { return nil }
    guard aliases.count == 1, let alias = aliases.first,
      alias.bindingRevision == 1,
      canonical.bindingRevision > alias.bindingRevision,
      Self.isJobID(route.jobID)
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias has ambiguous or advanced durable ownership")
    }

    let establishingFlashDirectory = jobDirectory(route.jobID)
    let establishingFlash = try RuntimeJobRecord.load(from: establishingFlashDirectory)
    let replay = try DurableJournalRecovery.inspect(
      url: establishingFlashDirectory.appendingPathComponent("journal.jsonl"))
    guard establishingFlash.jobID == route.jobID,
      RuntimeJobEngine.isDayu200Flash(establishingFlash),
      establishingFlash.providerID == "rockchip",
      establishingFlash.request.target.targetID == canonical.targetID,
      establishingFlash.request.target.expectedBindingRevision == canonical.bindingRevision,
      establishingFlash.materializedStableTargetIdentitySHA256
        == canonical.stablePhysicalIdentitySHA256,
      establishingFlash.materializedBindingRevision == canonical.bindingRevision,
      Self.stringInput("deviceProfile", record: establishingFlash) == "dayu200",
      Self.stringInput("postFlashVerification", record: establishingFlash) == "full",
      Self.partitionPlan(record: establishingFlash) == Self.publishedPartitionPlan()
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias establishing Flash has mismatched operation or target facts")
    }
    guard let planDigest = establishingFlash.materializedPlanDigest,
      Self.isSHA256(planDigest),
      establishingFlash.admissionEvidence?.kind == .runtimeCapability,
      let capability = establishingFlash.admissionEvidence?.runtimeCapabilityCorrelation,
      capability.planDigestSHA256 == planDigest,
      Self.isSHA256(capability.stepSetDigestSHA256),
      Self.isSHA256(capability.targetBindingDigestSHA256),
      let artifactSHA256 = capability.artifactSHA256,
      Self.isSHA256(artifactSHA256)
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias establishing Flash lacks immutable capability facts")
    }
    guard establishingFlash.state == JobState.succeeded.rawValue,
      !establishingFlash.outcomeUnknown,
      let finishedAtUTC = establishingFlash.finishedAtUTC,
      let finishedAt = Self.date(finishedAtUTC),
      let routeEstablished = Self.date(route.establishedAtUTC),
      routeEstablished <= finishedAt,
      !replay.hasTornTail,
      replay.outstandingIntents.isEmpty,
      replay.unknownOutcomes.isEmpty,
      replay.currentState == .succeeded
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias establishing Flash lacks clean terminal journal proof")
    }

    let confirmedStepIDs = Self.confirmedStepIDs(replay)
    guard Set(confirmedStepIDs).isSuperset(of: Self.requiredConfirmedStepIDs),
      Self.hasRequiredEffects(replay)
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias establishing Flash lacks write/readback/postflight proof")
    }
    guard let establishingFlashStarted = Self.date(
      establishingFlash.startedAtUTC ?? establishingFlash.createdAtUTC),
      let aliasAdopted = Self.date(alias.adoptedAtUTC),
      aliasAdopted < establishingFlashStarted
    else {
      throw BootstrapError.storeFailure(
        "post-flash HDC alias chronology is missing or reversed")
    }

    let covered = try coveredUnknownModeIntents(
      alias: alias, before: establishingFlashStarted)
    return try targetStore.appendAliasResolution(
      RuntimeTargetAliasResolutionDraft(
        aliasTargetID: alias.targetID,
        aliasStableIdentitySHA256: alias.stablePhysicalIdentitySHA256,
        aliasBindingRevision: alias.bindingRevision,
        canonicalTargetID: canonical.targetID,
        canonicalStableIdentitySHA256: canonical.stablePhysicalIdentitySHA256,
        canonicalBindingRevision: canonical.bindingRevision,
        routedHDCIdentitySHA256: route.hdcIdentitySHA256,
        routedUSBTopology: route.usbTopology,
        establishingFlashJobID: establishingFlash.jobID,
        establishingFlashPlanDigestSHA256: planDigest,
        confirmedStepIDs: confirmedStepIDs,
        coveredUnknownIntents: covered,
        establishedAtUTC: finishedAtUTC))
  }

  private func coveredUnknownModeIntents(
    alias: RuntimeTargetRecord,
    before recoveryStarted: Date
  ) throws -> [RuntimeTargetAliasCoveredIntent] {
    let jobsRoot = stateDirectory.appendingPathComponent("jobs", isDirectory: true)
    let directories = try FileManager.default.contentsOfDirectory(
      at: jobsRoot, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    var covered: [RuntimeTargetAliasCoveredIntent] = []
    var seen: Set<String> = []
    for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard Self.isJobID(directory.lastPathComponent),
        (try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { continue }
      let record: RuntimeJobRecord
      do {
        record = try RuntimeJobRecord.load(from: directory)
      } catch {
        throw BootstrapError.storeFailure(
          "target alias history contains an unreadable Job record")
      }
      guard record.request.target.targetID == alias.targetID,
        record.materializedStableTargetIdentitySHA256 == alias.stablePhysicalIdentitySHA256,
        record.materializedBindingRevision == alias.bindingRevision
      else { continue }
      let replay = try DurableJournalRecovery.inspect(
        url: directory.appendingPathComponent("journal.jsonl"))
      guard !replay.hasTornTail else {
        throw BootstrapError.storeFailure("target alias history has a torn journal")
      }
      let intents = replay.outstandingIntents.map {
        ($0.eventID, $0.eventID, $0.stepID, $0.effect)
      } + replay.unknownOutcomes.map {
        ($0.correlatedIntentEventID, $0.eventID, $0.stepID, $0.effect)
      }
      for (intentEventID, uncertaintyEventID, stepID, effect) in intents
      where effect >= .deviceMutation
      {
        guard RuntimeJobEngine.isDayu200Flash(record),
          stepID == "enter-loader-mode",
          effect == .deviceMutation,
          let uncertainty = replay.events.first(where: {
            $0.eventID == uncertaintyEventID
          }),
          let observedAt = Self.date(uncertainty.timestamp),
          observedAt < recoveryStarted
        else {
          throw BootstrapError.storeFailure(
            "target alias carries an effect not covered by later normal-mode postflight")
        }
        let key = "\(record.jobID)\n\(intentEventID)"
        if seen.insert(key).inserted {
          covered.append(
            RuntimeTargetAliasCoveredIntent(
              jobID: record.jobID, intentEventID: intentEventID,
              stepID: stepID, effect: effect.rawValue))
        }
      }
    }
    return covered.sorted {
      ($0.jobID, $0.intentEventID) < ($1.jobID, $1.intentEventID)
    }
  }

  private func jobDirectory(_ jobID: String) -> URL {
    stateDirectory.appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
  }

  private static func confirmedStepIDs(_ replay: JournalReplay) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for outcome in replay.events where outcome.kind == .stepOutcome {
      guard let stepID = outcome.stepID,
        outcome.payload["result"] == .string("succeeded"),
        outcome.payload["outcomeCertainty"] == .string("confirmed"),
        let intentEventID = outcome.correlatedIntentEventID,
        replay.events.contains(where: {
          $0.kind == .stepIntent && $0.eventID == intentEventID && $0.stepID == stepID
        }), seen.insert(stepID).inserted
      else { continue }
      result.append(stepID)
    }
    return result
  }

  private static func hasRequiredEffects(_ replay: JournalReplay) -> Bool {
    let expected: [String: WorkflowEffect] = [
      "enter-loader-mode": .deviceMutation,
      "flash-partitions": .destructive,
      "verify-flash-readback": .readOnly,
      "reboot-device": .deviceMutation,
      "wait-for-hdc": .readOnly,
      "rebind-and-verify-build": .readOnly,
    ]
    return expected.allSatisfy { stepID, effect in
      replay.events.contains {
        $0.kind == .stepIntent && $0.stepID == stepID && $0.stepEffect == effect
      }
    }
  }

  private static func stringInput(_ key: String, record: RuntimeJobRecord) -> String? {
    guard case .string(let value)? = record.request.inputs[key] else { return nil }
    return value
  }

  private static func partitionPlan(record: RuntimeJobRecord) -> [String]? {
    guard case .array(let values)? = record.request.inputs["partitionPlan"] else { return nil }
    var partitions: [String] = []
    for value in values {
      guard case .string(let partition) = value else { return nil }
      partitions.append(partition)
    }
    return partitions
  }

  private static func publishedPartitionPlan() -> [String]? {
    RuntimeOperationCatalog.descriptor(reference: "flash.dayu200")?
      .completeOverwriteRecovery?.profile(reference: "dayu200")?.coveredEffects
      .compactMap {
        guard $0.hasPrefix("partition:") else { return nil }
        return String($0.dropFirst("partition:".count))
      }
  }

  private static func date(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
      ("0"..."9").contains($0) || ("a"..."f").contains($0)
    }
  }

  private static func isJobID(_ value: String) -> Bool {
    value.hasPrefix("job-") && value.count == 36
      && value.dropFirst(4).allSatisfy {
        ("0"..."9").contains($0) || ("a"..."f").contains($0)
      }
  }
}
