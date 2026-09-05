// First-device-adoption bootstrap (CHG-2026-048, T09).
//
// Breaks the deadlock "no observation without a binding, no binding
// without observation" with an independent, permanently read-only
// admission path. Structural E0: the machine's action vocabulary is a
// closed observation subset - there is no type-level way to express a
// mutation inside bootstrap, and the normal runtime's checks are never
// relaxed (this is a separate path, not a bypass).

import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

// MARK: - Closed observation vocabulary

package enum BootstrapObservationAction: Sendable, Equatable {
  case observeTool
  case observeServer
  case listCandidates
  case observeDevice(connectKey: String)
  case queryDeviceName
  case queryDeviceSystemVersion

  var providerAction: TypedProviderAction {
    switch self {
    case .observeTool: return .hdc(.observeTool)
    case .observeServer: return .hdc(.observeServer)
    case .listCandidates: return .hdc(.listDeviceCandidates)
    case .observeDevice(let connectKey): return .hdc(.observeDevice(connectKey: connectKey))
    case .queryDeviceName: return .hdc(.queryProperty(.productName))
    case .queryDeviceSystemVersion: return .hdc(.queryProperty(.fullBuildVersion))
    }
  }
}

public enum BootstrapPhase: String, Sendable, Equatable, Codable {
  case discoverHostTools
  case observeHDCServer
  case enumerateDeviceCandidates
  case waitForPhysicalTrust
  case observeSelectedDevice
  case createDurableTarget
  case persistInitialBinding
  case handedOff
}

public struct BootstrapCandidate: Sendable, Equatable, Codable {
  public let connectKey: String
  public let state: String
  /// §8.5's Runtime-issued lifecycle-scoped observation ID.
  ///
  /// `nil` means this candidate did not come through the Runtime's observation
  /// registry — a fixture, or a decode in a test. It is not a missing value to
  /// be filled in with something plausible: an ID a caller could pass to
  /// `target adopt --observation` has to have been minted by the Runtime that
  /// will check it.
  public let observationID: String?

  public init(connectKey: String, state: String, observationID: String? = nil) {
    self.connectKey = connectKey
    self.state = state
    self.observationID = observationID
  }

  public var isAuthorized: Bool { state == "Connected" }
  public var needsPhysicalTrust: Bool {
    state == "Unauthorized" || state == "Offline"
  }
}

/// A point-in-time HDC candidate observation owned by the login-session
/// daemon. HDC 3.2 exposes a bounded `list targets -v` read but no target
/// event stream, so the daemon keeps this observation warm outside the App's
/// launch path. `observedAtUTC` makes the cache boundary explicit; a failed
/// follow-up probe never rewrites the old observation as current.
public struct BootstrapCandidateSnapshot: Sendable, Equatable {
  public enum Health: String, Sendable, Equatable {
    case current
    case stale
  }

  public let candidates: [BootstrapCandidate]
  public let observedAtUTC: String
  public let health: Health
  /// §6.1's fixed snapshot generation, monotonic per daemon session.
  ///
  /// `nil` for a snapshot the observation registry never stamped, for the same
  /// reason `observationID` is optional: a generation a caller could pass to
  /// `target adopt --observation-generation` must be one the Runtime issued.
  public let generation: UInt64?

  public init(
    candidates: [BootstrapCandidate], observedAtUTC: String, health: Health,
    generation: UInt64? = nil
  ) {
    self.candidates = candidates
    self.observedAtUTC = observedAtUTC
    self.health = health
    self.generation = generation
  }
}

/// Best-effort presentation facts read directly from one currently connected
/// HDC candidate. These values never participate in target identity or
/// binding: the connect key still comes from the candidate snapshot and the
/// bootstrap machine's stable-identity path remains unchanged.
public struct BootstrapDeviceInformation: Sendable, Equatable {
  public let name: String?
  public let systemVersion: String?
  public let transport: String

  public init(name: String?, systemVersion: String?, transport: String) {
    self.name = name
    self.systemVersion = systemVersion
    self.transport = transport
  }
}

/// Display decoration has its own observation time. A warm candidate list
/// must not relabel older property values with the candidate probe's time.
public struct BootstrapDeviceInformationSnapshot: Sendable, Equatable {
  public let information: [String: BootstrapDeviceInformation]
  public let observedAtUTC: String
}

public enum BootstrapHumanActionKind: String, Sendable, Equatable {
  case trustDevice
  case physicalReconnect
}

public enum BootstrapProgress: Sendable, Equatable {
  case adopted(RuntimeTargetRecord)
  case needsSelection([BootstrapCandidate])
  case waitingForHuman(kind: BootstrapHumanActionKind, prompt: String)
  case failed(reason: String)
}

public enum BootstrapError: Error, Equatable, Sendable {
  case noCandidates
  case unknownCandidate(String)
  case observationFailed(String)
  case storeFailure(String)
}

// MARK: - Durable target store

public struct RuntimeTargetRecord: Sendable, Equatable, Codable {
  public let targetID: String
  public let stablePhysicalIdentitySHA256: String
  public let bindingRevision: Int
  public let connectKey: String
  public let toolVersion: String
  public let adoptedAtUTC: String

  public init(
    targetID: String,
    stablePhysicalIdentitySHA256: String,
    bindingRevision: Int,
    connectKey: String,
    toolVersion: String,
    adoptedAtUTC: String
  ) {
    self.targetID = targetID
    self.stablePhysicalIdentitySHA256 = stablePhysicalIdentitySHA256
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.toolVersion = toolVersion
    self.adoptedAtUTC = adoptedAtUTC
  }
}

/// Provider-facing HDC route for an active durable target. Target identity
/// and revision remain canonical; only the address may come from an
/// append-only alias resolution whose Flash/postflight proof has already
/// passed validation.
public struct RuntimeTargetHDCRoute: Sendable, Equatable {
  package let targetID: String
  package let bindingRevision: Int
  package let toolVersion: String
  package let connectKey: String
}

/// A single, already-proven cross-mode identity transition. The Rockchip
/// binding store constructs this value from its owner-only lineage evidence;
/// the target store only applies the exact previous -> current edge. Keeping
/// the proof outside the generic store prevents a caller from advancing a
/// target with an uncorrelated identity or a skipped revision.
public struct RuntimeTargetBindingLineageAdvance: Sendable, Equatable {
  package let previousStableIdentitySHA256: String
  package let previousRevision: Int
  package let currentStableIdentitySHA256: String
  package let currentRevision: Int

  package init(
    previousStableIdentitySHA256: String,
    previousRevision: Int,
    currentStableIdentitySHA256: String,
    currentRevision: Int
  ) {
    self.previousStableIdentitySHA256 = previousStableIdentitySHA256
    self.previousRevision = previousRevision
    self.currentStableIdentitySHA256 = currentStableIdentitySHA256
    self.currentRevision = currentRevision
  }
}

package struct RuntimeTargetAliasCoveredIntent: Codable, Sendable, Equatable {
  package let jobID: String
  package let intentEventID: String
  package let stepID: String
  package let effect: String
}

public struct RuntimeTargetAliasResolutionDraft: Sendable, Equatable {
  package let aliasTargetID: String
  package let aliasStableIdentitySHA256: String
  package let aliasBindingRevision: Int
  package let canonicalTargetID: String
  package let canonicalStableIdentitySHA256: String
  package let canonicalBindingRevision: Int
  package let routedHDCIdentitySHA256: String
  package let routedUSBTopology: String
  package let establishingFlashJobID: String
  package let establishingFlashPlanDigestSHA256: String
  package let confirmedStepIDs: [String]
  package let coveredUnknownIntents: [RuntimeTargetAliasCoveredIntent]
  package let establishedAtUTC: String
}

public struct RuntimeTargetAliasResolution: Codable, Sendable, Equatable {
  package let resolutionID: String
  package let aliasTargetID: String
  package let aliasStableIdentitySHA256: String
  package let aliasBindingRevision: Int
  package let canonicalTargetID: String
  package let canonicalStableIdentitySHA256: String
  package let canonicalBindingRevision: Int
  package let routedHDCIdentitySHA256: String
  package let routedUSBTopology: String
  package let establishingFlashJobID: String
  package let establishingFlashPlanDigestSHA256: String
  package let confirmedStepIDs: [String]
  package let coveredUnknownIntents: [RuntimeTargetAliasCoveredIntent]
  package let establishedAtUTC: String
  package let previousResolutionSHA256: String?
  package let resolutionSHA256: String
}

private struct RuntimeTargetAliasResolutionMaterial: Codable {
  let resolutionID: String
  let aliasTargetID: String
  let aliasStableIdentitySHA256: String
  let aliasBindingRevision: Int
  let canonicalTargetID: String
  let canonicalStableIdentitySHA256: String
  let canonicalBindingRevision: Int
  let routedHDCIdentitySHA256: String
  let routedUSBTopology: String
  let establishingFlashJobID: String
  let establishingFlashPlanDigestSHA256: String
  let confirmedStepIDs: [String]
  let coveredUnknownIntents: [RuntimeTargetAliasCoveredIntent]
  let establishedAtUTC: String
  let previousResolutionSHA256: String?
}

private struct TargetStoreDocument: Codable, Equatable {
  var schemaVersion: String
  var targets: [RuntimeTargetRecord]
  var aliasResolutions: [RuntimeTargetAliasResolution]?

  init(
    schemaVersion: String,
    targets: [RuntimeTargetRecord],
    aliasResolutions: [RuntimeTargetAliasResolution]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.targets = targets
    self.aliasResolutions = aliasResolutions
  }
}

/// Durable, flock-guarded target registry in the daemon state directory.
public final class RuntimeTargetStore: @unchecked Sendable {
  private struct LiveHDCCandidateObservation {
    let candidates: [BootstrapCandidate]
    let observedAt: Date
  }

  private let url: URL
  private let lockURL: URL
  private let displayNames: RuntimeTargetDisplayNameStore
  private let queue = DispatchQueue(label: "arkdeck.target-store")
  private let routeObservationNow: @Sendable () -> Date
  private let routeObservationFreshnessSeconds: TimeInterval = 5
  private var liveHDCCandidateObservation: LiveHDCCandidateObservation?

  public init(
    directoryURL: URL,
    routeObservationNow: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw BootstrapError.storeFailure("cannot create target store directory: \(error)")
    }
    self.url = directoryURL.appending(path: "targets.json")
    self.lockURL = directoryURL.appending(path: ".targets.lock")
    self.displayNames = RuntimeTargetDisplayNameStore(rootURL: directoryURL)
    self.routeObservationNow = routeObservationNow
    let activeTargetIDs = Set(try activeTargets().map(\.targetID))
    try displayNames.reconcileAfterRuntimeRestart(activeTargetIDs: activeTargetIDs)
  }

  /// Publishes one provider-verified candidate snapshot for live route
  /// selection. This is deliberately memory-only: it cannot create, rewrite
  /// or widen durable target/alias ownership, and it expires quickly when HDC
  /// stops producing fresh observations.
  package func recordLiveHDCCandidates(_ candidates: [BootstrapCandidate]) {
    queue.sync {
      liveHDCCandidateObservation = LiveHDCCandidateObservation(
        candidates: candidates, observedAt: routeObservationNow())
    }
  }

  public func list() throws -> [RuntimeTargetRecord] {
    try queue.sync { try load().targets }
  }

  public func find(targetID: String) throws -> RuntimeTargetRecord? {
    try queue.sync { try load().targets.first { $0.targetID == targetID } }
  }

  package func targetDisplayNames(
    targetIDs: [String]
  ) throws -> [String: RuntimeTargetDisplayName] {
    try queue.sync { try displayNames.read(targetIDs: targetIDs) }
  }

  package func targetDisplayName(targetID: String) throws -> RuntimeTargetDisplayName {
    try queue.sync {
      guard try activeTargets().contains(where: { $0.targetID == targetID }) else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceNotFound", "durable target does not exist or is an inactive alias")
      }
      return try displayNames.read(targetID: targetID)
    }
  }

  package func setTargetDisplayName(
    targetID: String, expectedGeneration: UInt64, name: String
  ) throws -> RuntimeTargetDisplayName {
    try queue.sync {
      guard try activeTargets().contains(where: { $0.targetID == targetID }) else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceNotFound", "durable target does not exist or is an inactive alias")
      }
      return try displayNames.set(
        targetID: targetID, expectedGeneration: expectedGeneration, name: name)
    }
  }

  package func clearTargetDisplayName(
    targetID: String, expectedGeneration: UInt64
  ) throws -> RuntimeTargetDisplayName {
    try queue.sync {
      guard try activeTargets().contains(where: { $0.targetID == targetID }) else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceNotFound", "durable target does not exist or is an inactive alias")
      }
      return try displayNames.clear(
        targetID: targetID, expectedGeneration: expectedGeneration)
    }
  }

  package func candidateDisplayNames(
    references: [TargetObservationReference]
  ) throws -> [String: RuntimeCandidateDisplayName] {
    try queue.sync { try displayNames.candidateDisplayNames(references: references) }
  }

  package func setCandidateDisplayName(
    _ reference: TargetObservationReference,
    activeReferences: [TargetObservationReference],
    nextGeneration: UInt64,
    name: String
  ) throws -> RuntimeCandidateDisplayName {
    try queue.sync {
      let document = try load()
      guard try candidateTarget(connectKey: reference.candidate, document: document) == nil else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceConflict", "candidate is already adopted; use its durable target resource")
      }
      return try displayNames.setCandidate(
        reference, activeReferences: activeReferences,
        nextGeneration: nextGeneration, name: name)
    }
  }

  package func clearCandidateDisplayName(
    _ reference: TargetObservationReference,
    activeReferences: [TargetObservationReference],
    nextGeneration: UInt64
  ) throws -> RuntimeCandidateDisplayName {
    try queue.sync {
      let document = try load()
      guard try candidateTarget(connectKey: reference.candidate, document: document) == nil else {
        throw RuntimeTargetDisplayNameFailure(
          "resourceConflict", "candidate is already adopted; use its durable target resource")
      }
      return try displayNames.clearCandidate(
        reference, activeReferences: activeReferences,
        nextGeneration: nextGeneration)
    }
  }

  package func expireCandidateDisplayNames() throws {
    try queue.sync { try displayNames.expireCandidateDisplayNames() }
  }

  /// Historical aliases remain in `list()` so old Job identity never changes.
  /// New selection surfaces use only the canonical records returned here.
  public func listActive() throws -> [RuntimeTargetRecord] {
    try queue.sync { try activeTargets() }
  }

  private func activeTargets() throws -> [RuntimeTargetRecord] {
    let document = try load()
    let aliases = Set((document.aliasResolutions ?? []).map(\.aliasTargetID))
    return document.targets.filter { !aliases.contains($0.targetID) }
  }

  /// Resolves one currently observed address only through a durable alias
  /// relation. Singleton presence and similar IDs are never sufficient.
  public func candidateTarget(connectKey: String) throws -> RuntimeTargetRecord? {
    try queue.sync {
      let document = try load()
      return try candidateTarget(connectKey: connectKey, document: document)
    }
  }

  private func candidateTarget(
    connectKey: String, document: TargetStoreDocument
  ) throws -> RuntimeTargetRecord? {
    let matches = document.targets.filter { $0.connectKey == connectKey }
    guard matches.count <= 1 else {
      throw BootstrapError.storeFailure("candidate connect key has ambiguous target owners")
    }
    guard let direct = matches.first else { return nil }
    guard
      let resolution = (document.aliasResolutions ?? []).first(where: {
        $0.aliasTargetID == direct.targetID
      })
    else { return direct }
    guard
      let canonical = document.targets.first(where: {
        $0.targetID == resolution.canonicalTargetID
      })
    else {
      throw BootstrapError.storeFailure("resolved candidate canonical target is missing")
    }
    return canonical
  }

  /// Resolves the address the HDC provider must use without rewriting the
  /// canonical target record. A target with no proven alias uses its adopted
  /// connect key. When a later Flash has proven an alias, both the canonical
  /// address and that exact alias remain durably owned by the same target. A
  /// fresh provider-verified candidate snapshot may select the sole Connected
  /// member of that closed set; zero or multiple live members fail closed.
  /// Without a fresh snapshot the existing proven-alias fallback is retained
  /// for startup and host-only Artifact binding.
  public func hdcExecutionRoute(targetID: String) throws -> RuntimeTargetHDCRoute? {
    try queue.sync {
      let document = try load()
      let targets = document.targets.filter { $0.targetID == targetID }
      guard targets.count <= 1 else {
        throw BootstrapError.storeFailure("HDC execution target is ambiguous")
      }
      guard let target = targets.first else { return nil }
      let resolutions = (document.aliasResolutions ?? []).filter {
        $0.canonicalTargetID == targetID
      }
      guard resolutions.count <= 1 else {
        throw BootstrapError.storeFailure("HDC execution route is ambiguous")
      }
      let connectKey: String
      if let resolution = resolutions.first {
        let aliases = document.targets.filter { $0.targetID == resolution.aliasTargetID }
        guard aliases.count == 1, let alias = aliases.first,
          alias.stablePhysicalIdentitySHA256 == resolution.aliasStableIdentitySHA256,
          alias.bindingRevision == resolution.aliasBindingRevision,
          Self.sha256(alias.connectKey) == resolution.routedHDCIdentitySHA256
        else {
          throw BootstrapError.storeFailure(
            "HDC execution route lacks its proven alias target")
        }
        let fallbackConnectKey = alias.connectKey
        let observationAge = liveHDCCandidateObservation.map {
          routeObservationNow().timeIntervalSince($0.observedAt)
        }
        if let observation = liveHDCCandidateObservation,
          let observationAge,
          observationAge >= 0,
          observationAge <= routeObservationFreshnessSeconds
        {
          let allowedConnectKeys = Set([target.connectKey, alias.connectKey])
          let connected = Set(
            observation.candidates.compactMap { candidate in
              candidate.state == "Connected" && allowedConnectKeys.contains(candidate.connectKey)
                ? candidate.connectKey : nil
            })
          guard connected.count == 1, let liveConnectKey = connected.first else {
            let reason =
              connected.isEmpty ? "no Connected proven route" : "multiple Connected proven routes"
            throw BootstrapError.observationFailed(
              "fresh HDC observation found \(reason) for target \(targetID)")
          }
          connectKey = liveConnectKey
        } else {
          connectKey = fallbackConnectKey
        }
      } else {
        connectKey = target.connectKey
      }
      return RuntimeTargetHDCRoute(
        targetID: target.targetID, bindingRevision: target.bindingRevision,
        toolVersion: target.toolVersion, connectKey: connectKey)
    }
  }

  public func aliasResolutions() throws -> [RuntimeTargetAliasResolution] {
    try queue.sync { try load().aliasResolutions ?? [] }
  }

  /// Appends one mechanically proven identity relation without editing either
  /// target or any Job. Repeating the exact proof is idempotent.
  @discardableResult
  public func appendAliasResolution(
    _ draft: RuntimeTargetAliasResolutionDraft
  ) throws -> RuntimeTargetAliasResolution {
    try queue.sync {
      var document = try load()
      try Self.validate(draft, targets: document.targets)
      let existing = document.aliasResolutions ?? []
      if let resolution = existing.first(where: {
        $0.aliasTargetID == draft.aliasTargetID
          || $0.canonicalTargetID == draft.aliasTargetID
      }) {
        guard Self.draft(from: resolution) == draft else {
          throw BootstrapError.storeFailure(
            "target alias already has a different durable resolution")
        }
        return resolution
      }
      guard !existing.contains(where: { $0.aliasTargetID == draft.canonicalTargetID }) else {
        throw BootstrapError.storeFailure("target alias resolution chains are forbidden")
      }
      let existingIntentKeys = Set(
        existing.flatMap {
          $0.coveredUnknownIntents.map { "\($0.jobID)\n\($0.intentEventID)" }
        })
      let newIntentKeys = Set(
        draft.coveredUnknownIntents.map {
          "\($0.jobID)\n\($0.intentEventID)"
        })
      guard existingIntentKeys.isDisjoint(with: newIntentKeys),
        !existing.contains(where: {
          $0.establishingFlashJobID == draft.establishingFlashJobID
        })
      else {
        throw BootstrapError.storeFailure(
          "target alias resolution reuses durable Flash or intent proof")
      }
      let material = RuntimeTargetAliasResolutionMaterial(
        resolutionID: Self.resolutionID(for: draft),
        aliasTargetID: draft.aliasTargetID,
        aliasStableIdentitySHA256: draft.aliasStableIdentitySHA256,
        aliasBindingRevision: draft.aliasBindingRevision,
        canonicalTargetID: draft.canonicalTargetID,
        canonicalStableIdentitySHA256: draft.canonicalStableIdentitySHA256,
        canonicalBindingRevision: draft.canonicalBindingRevision,
        routedHDCIdentitySHA256: draft.routedHDCIdentitySHA256,
        routedUSBTopology: draft.routedUSBTopology,
        establishingFlashJobID: draft.establishingFlashJobID,
        establishingFlashPlanDigestSHA256: draft.establishingFlashPlanDigestSHA256,
        confirmedStepIDs: draft.confirmedStepIDs,
        coveredUnknownIntents: draft.coveredUnknownIntents,
        establishedAtUTC: draft.establishedAtUTC,
        previousResolutionSHA256: existing.last?.resolutionSHA256)
      let resolution = RuntimeTargetAliasResolution(
        resolutionID: material.resolutionID,
        aliasTargetID: material.aliasTargetID,
        aliasStableIdentitySHA256: material.aliasStableIdentitySHA256,
        aliasBindingRevision: material.aliasBindingRevision,
        canonicalTargetID: material.canonicalTargetID,
        canonicalStableIdentitySHA256: material.canonicalStableIdentitySHA256,
        canonicalBindingRevision: material.canonicalBindingRevision,
        routedHDCIdentitySHA256: material.routedHDCIdentitySHA256,
        routedUSBTopology: material.routedUSBTopology,
        establishingFlashJobID: material.establishingFlashJobID,
        establishingFlashPlanDigestSHA256: material.establishingFlashPlanDigestSHA256,
        confirmedStepIDs: material.confirmedStepIDs,
        coveredUnknownIntents: material.coveredUnknownIntents,
        establishedAtUTC: material.establishedAtUTC,
        previousResolutionSHA256: material.previousResolutionSHA256,
        resolutionSHA256: try Self.digest(material))
      document.aliasResolutions = existing + [resolution]
      try persist(document)
      return resolution
    }
  }

  /// Reports whether a freshly verified HDC alias is already owned by a
  /// different durable target. A post-flash route proves how to address the
  /// selected target; it does not erase a second target record or authorize
  /// Runtime to guess that both records represent the same physical device.
  /// Callers must fail closed until that identity conflict is reconciled by a
  /// separate, history-preserving mechanism. Once reconciled, the exact
  /// identity relation remains valid across later successful Flash Jobs; a
  /// new route Job ID alone is not a new physical-device identity.
  public func hasConflictingHDCAliasOwner(
    canonicalTargetID: String,
    connectKey: String,
    identitySHA256: String,
    establishingFlashJobID: String
  ) throws -> Bool {
    try queue.sync {
      guard !canonicalTargetID.isEmpty,
        !connectKey.isEmpty,
        Self.isCanonicalSHA256(identitySHA256),
        Self.sha256(connectKey) == identitySHA256,
        !establishingFlashJobID.isEmpty
      else {
        throw BootstrapError.storeFailure("invalid HDC alias ownership query")
      }
      let document = try load()
      let targets = document.targets
      let canonicals = targets.filter { $0.targetID == canonicalTargetID }
      guard canonicals.count == 1, let canonical = canonicals.first else {
        throw BootstrapError.storeFailure(
          "canonical target for HDC alias ownership is missing or ambiguous")
      }
      let conflicts = targets.filter {
        $0.targetID != canonicalTargetID
          && ($0.connectKey == connectKey || $0.stablePhysicalIdentitySHA256 == identitySHA256)
      }
      let resolutions = document.aliasResolutions ?? []
      return conflicts.contains { conflict in
        !resolutions.contains {
          $0.aliasTargetID == conflict.targetID
            && $0.aliasStableIdentitySHA256 == conflict.stablePhysicalIdentitySHA256
            && $0.aliasBindingRevision == conflict.bindingRevision
            && $0.canonicalTargetID == canonicalTargetID
            && $0.canonicalStableIdentitySHA256
              == canonical.stablePhysicalIdentitySHA256
            && $0.canonicalBindingRevision == canonical.bindingRevision
            && $0.routedHDCIdentitySHA256 == identitySHA256
        }
      }
    }
  }

  /// Idempotent adoption keyed by stable physical identity: re-adopting
  /// the same device returns the existing record untouched.
  public func adopt(
    stableIdentitySHA256: String,
    connectKey: String,
    toolVersion: String,
    nowUTC: String
  ) throws -> (record: RuntimeTargetRecord, created: Bool) {
    try queue.sync {
      var document = try load()
      let result = try materializeAdoption(
        stableIdentitySHA256: stableIdentitySHA256, connectKey: connectKey,
        toolVersion: toolVersion, nowUTC: nowUTC, document: &document)
      if result.created { try persist(document) }
      return result
    }
  }

  package func adoptObservedCandidate(
    stableIdentitySHA256: String,
    connectKey: String,
    toolVersion: String,
    nowUTC: String,
    reference: TargetObservationReference,
    activeReferences: [TargetObservationReference],
    nextObservationGeneration: UInt64
  ) throws -> (record: RuntimeTargetRecord, created: Bool) {
    try queue.sync {
      var document = try load()
      let result = try materializeAdoption(
        stableIdentitySHA256: stableIdentitySHA256, connectKey: connectKey,
        toolVersion: toolVersion, nowUTC: nowUTC, document: &document)
      // The target display record is staged while it is still invisible for a
      // newly created binding. This queue also guards target reads, so no
      // in-process observer can see a target without its migrated name.
      try displayNames.stageCandidateAdoption(reference, targetID: result.record.targetID)
      if result.created { try persist(document) }
      try displayNames.finishCandidateAdoption(
        reference, activeReferences: activeReferences,
        nextGeneration: nextObservationGeneration)
      return result
    }
  }

  private func materializeAdoption(
    stableIdentitySHA256: String,
    connectKey: String,
    toolVersion: String,
    nowUTC: String,
    document: inout TargetStoreDocument
  ) throws -> (record: RuntimeTargetRecord, created: Bool) {
    if let resolution = (document.aliasResolutions ?? []).first(where: {
      $0.aliasStableIdentitySHA256 == stableIdentitySHA256
        || $0.routedHDCIdentitySHA256 == stableIdentitySHA256
    }),
      let canonical = document.targets.first(where: {
        $0.targetID == resolution.canonicalTargetID
      })
    {
      return (canonical, false)
    }
    if let existing = document.targets.first(where: {
      $0.stablePhysicalIdentitySHA256 == stableIdentitySHA256
    }) {
      if let resolution = (document.aliasResolutions ?? []).first(where: {
        $0.aliasTargetID == existing.targetID
      }),
        let canonical = document.targets.first(where: {
          $0.targetID == resolution.canonicalTargetID
        })
      {
        return (canonical, false)
      }
      return (existing, false)
    }
    // A Flash lineage advance can replace the stored identity while retaining
    // the target ID and connect key. Do not append a colliding second record.
    let derivedID = "TGT-\(stableIdentitySHA256.prefix(12))"
    if let sameDevice = document.targets.first(where: { $0.targetID == derivedID }) {
      guard sameDevice.connectKey == connectKey else {
        throw BootstrapError.storeFailure(
          "adopted target \(derivedID) is bound to another connect key")
      }
      return (sameDevice, false)
    }
    let record = RuntimeTargetRecord(
      targetID: derivedID,
      stablePhysicalIdentitySHA256: stableIdentitySHA256,
      bindingRevision: 1,
      connectKey: connectKey,
      toolVersion: toolVersion,
      adoptedAtUTC: nowUTC)
    document.targets.append(record)
    return (record, true)
  }

  /// Advances one adopted target across a strictly adjacent, externally
  /// proven binding lineage edge. The durable target ID and HDC connect key
  /// remain stable: after a Loader-mode Flash the same normal-mode address is
  /// needed for reconnect and full Debug Runtime verification.
  ///
  /// This is idempotent for the exact current edge. Any missing, ambiguous,
  /// colliding or skipped lineage fails closed without changing the file.
  public func advanceBindingLineage(
    _ advance: RuntimeTargetBindingLineageAdvance
  ) throws -> (record: RuntimeTargetRecord, updated: Bool) {
    try queue.sync {
      guard
        Self.isCanonicalSHA256(advance.previousStableIdentitySHA256),
        Self.isCanonicalSHA256(advance.currentStableIdentitySHA256),
        advance.previousStableIdentitySHA256 != advance.currentStableIdentitySHA256,
        advance.previousRevision > 0,
        advance.currentRevision == advance.previousRevision + 1
      else {
        throw BootstrapError.storeFailure("invalid target binding lineage advance")
      }

      var document = try load()
      let currentMatches = document.targets.filter {
        $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
          && $0.bindingRevision == advance.currentRevision
      }
      let previousIdentityIndexes = document.targets.indices.filter {
        document.targets[$0].stablePhysicalIdentitySHA256
          == advance.previousStableIdentitySHA256
      }
      if currentMatches.count == 1 {
        guard previousIdentityIndexes.isEmpty,
          document.targets.filter({
            $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
          }).count == 1
        else {
          throw BootstrapError.storeFailure("ambiguous completed target binding lineage")
        }
        return (currentMatches[0], false)
      }
      guard currentMatches.isEmpty else {
        throw BootstrapError.storeFailure("ambiguous current target binding lineage")
      }
      guard
        !document.targets.contains(where: {
          $0.stablePhysicalIdentitySHA256 == advance.currentStableIdentitySHA256
        })
      else {
        throw BootstrapError.storeFailure("target binding lineage collides with a durable record")
      }
      guard previousIdentityIndexes.count == 1,
        let index = previousIdentityIndexes.first,
        document.targets[index].bindingRevision == advance.previousRevision
      else {
        throw BootstrapError.storeFailure("previous target binding lineage is missing or ambiguous")
      }
      let previous = document.targets[index]
      let current = RuntimeTargetRecord(
        targetID: previous.targetID,
        stablePhysicalIdentitySHA256: advance.currentStableIdentitySHA256,
        bindingRevision: advance.currentRevision,
        connectKey: previous.connectKey,
        toolVersion: previous.toolVersion,
        adoptedAtUTC: previous.adoptedAtUTC)
      document.targets[index] = current
      // An alias resolution names a relation between two device identities,
      // not between two revisions of one binding. `load` re-validates every
      // resolution against the target records, so advancing the target without
      // carrying its resolutions forward persists a document this same store
      // can no longer read — silently, because `persist` does not check what
      // `load` checks. That turned one rebind into an unusable target store.
      document.aliasResolutions = try Self.carryAliasResolutionsForward(
        document.aliasResolutions,
        canonicalTargetID: current.targetID,
        canonicalStableIdentitySHA256: advance.currentStableIdentitySHA256,
        canonicalBindingRevision: advance.currentRevision)
      try persist(document)
      return (current, true)
    }
  }

  private static func isCanonicalSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy {
        ("0"..."9").contains($0) || ("a"..."f").contains($0)
      }
  }

  private func load() throws -> TargetStoreDocument {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return TargetStoreDocument(schemaVersion: "1.0.0", targets: [])
    }
    do {
      let document = try JSONDecoder().decode(
        TargetStoreDocument.self, from: Data(contentsOf: url))
      try Self.validate(document)
      return document
    } catch {
      throw BootstrapError.storeFailure("undecodable target store: \(error)")
    }
  }

  private static let requiredAliasEstablishingFlashSteps: Set<String> = [
    "enter-loader-mode", "flash-partitions", "verify-flash-readback",
    "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
  ]

  private static func validate(_ document: TargetStoreDocument) throws {
    guard document.schemaVersion == "1.0.0" else {
      throw BootstrapError.storeFailure("unsupported target store schema")
    }
    var previous: String?
    var aliases: Set<String> = []
    var establishingFlashJobs: Set<String> = []
    var coveredIntentKeys: Set<String> = []
    for resolution in document.aliasResolutions ?? [] {
      let draft = draft(from: resolution)
      try validate(draft, targets: document.targets)
      guard aliases.insert(resolution.aliasTargetID).inserted,
        establishingFlashJobs.insert(resolution.establishingFlashJobID).inserted,
        resolution.resolutionID == resolutionID(for: draft),
        resolution.coveredUnknownIntents.allSatisfy({
          coveredIntentKeys.insert("\($0.jobID)\n\($0.intentEventID)").inserted
        }),
        resolution.previousResolutionSHA256 == previous
      else {
        throw BootstrapError.storeFailure("target alias resolution chain is ambiguous")
      }
      let material = RuntimeTargetAliasResolutionMaterial(
        resolutionID: resolution.resolutionID,
        aliasTargetID: resolution.aliasTargetID,
        aliasStableIdentitySHA256: resolution.aliasStableIdentitySHA256,
        aliasBindingRevision: resolution.aliasBindingRevision,
        canonicalTargetID: resolution.canonicalTargetID,
        canonicalStableIdentitySHA256: resolution.canonicalStableIdentitySHA256,
        canonicalBindingRevision: resolution.canonicalBindingRevision,
        routedHDCIdentitySHA256: resolution.routedHDCIdentitySHA256,
        routedUSBTopology: resolution.routedUSBTopology,
        establishingFlashJobID: resolution.establishingFlashJobID,
        establishingFlashPlanDigestSHA256: resolution.establishingFlashPlanDigestSHA256,
        confirmedStepIDs: resolution.confirmedStepIDs,
        coveredUnknownIntents: resolution.coveredUnknownIntents,
        establishedAtUTC: resolution.establishedAtUTC,
        previousResolutionSHA256: resolution.previousResolutionSHA256)
      guard resolution.resolutionSHA256 == (try digest(material)) else {
        throw BootstrapError.storeFailure("target alias resolution hash chain is invalid")
      }
      previous = resolution.resolutionSHA256
    }
    let canonicals = Set((document.aliasResolutions ?? []).map(\.canonicalTargetID))
    guard aliases.isDisjoint(with: canonicals) else {
      throw BootstrapError.storeFailure("target alias resolution chains are forbidden")
    }
  }

  private static func validate(
    _ draft: RuntimeTargetAliasResolutionDraft,
    targets: [RuntimeTargetRecord]
  ) throws {
    let alias = targets.filter { $0.targetID == draft.aliasTargetID }
    let canonical = targets.filter { $0.targetID == draft.canonicalTargetID }
    let intentKeys = draft.coveredUnknownIntents.map { "\($0.jobID)\n\($0.intentEventID)" }
    guard draft.aliasTargetID != draft.canonicalTargetID,
      alias.count == 1, canonical.count == 1,
      alias[0].stablePhysicalIdentitySHA256 == draft.aliasStableIdentitySHA256,
      alias[0].bindingRevision == draft.aliasBindingRevision,
      canonical[0].stablePhysicalIdentitySHA256 == draft.canonicalStableIdentitySHA256,
      canonical[0].bindingRevision == draft.canonicalBindingRevision,
      draft.aliasStableIdentitySHA256 == draft.routedHDCIdentitySHA256,
      sha256(alias[0].connectKey) == draft.routedHDCIdentitySHA256,
      isCanonicalSHA256(draft.canonicalStableIdentitySHA256),
      isCanonicalSHA256(draft.establishingFlashPlanDigestSHA256),
      !draft.establishingFlashJobID.isEmpty,
      !draft.routedUSBTopology.isEmpty,
      draft.routedUSBTopology.utf8.allSatisfy({ (48...57).contains($0) }),
      Set(draft.confirmedStepIDs).isSuperset(of: requiredAliasEstablishingFlashSteps),
      Set(draft.confirmedStepIDs).count == draft.confirmedStepIDs.count,
      Set(intentKeys).count == intentKeys.count,
      draft.coveredUnknownIntents.allSatisfy({
        !$0.jobID.isEmpty && !$0.intentEventID.isEmpty
          && $0.stepID == "enter-loader-mode" && $0.effect == "deviceMutation"
      }),
      ISO8601Timestamps.parse(draft.establishedAtUTC) != nil
    else {
      throw BootstrapError.storeFailure(
        "target alias resolution lacks exact identity, history or postflight proof")
    }
  }

  private static func draft(
    from resolution: RuntimeTargetAliasResolution
  ) -> RuntimeTargetAliasResolutionDraft {
    RuntimeTargetAliasResolutionDraft(
      aliasTargetID: resolution.aliasTargetID,
      aliasStableIdentitySHA256: resolution.aliasStableIdentitySHA256,
      aliasBindingRevision: resolution.aliasBindingRevision,
      canonicalTargetID: resolution.canonicalTargetID,
      canonicalStableIdentitySHA256: resolution.canonicalStableIdentitySHA256,
      canonicalBindingRevision: resolution.canonicalBindingRevision,
      routedHDCIdentitySHA256: resolution.routedHDCIdentitySHA256,
      routedUSBTopology: resolution.routedUSBTopology,
      establishingFlashJobID: resolution.establishingFlashJobID,
      establishingFlashPlanDigestSHA256: resolution.establishingFlashPlanDigestSHA256,
      confirmedStepIDs: resolution.confirmedStepIDs,
      coveredUnknownIntents: resolution.coveredUnknownIntents,
      establishedAtUTC: resolution.establishedAtUTC)
  }

  /// Re-publishes the alias resolutions whose canonical target just advanced.
  ///
  /// Only the canonical identity and revision move. The alias side, the
  /// establishing Flash proof and the covered intents are history and are
  /// carried verbatim — that is what keeps this a lineage advance rather than
  /// a fresh claim about the device. `resolutionID` is derived from the two
  /// target IDs and the establishing Job, so it survives unchanged; the hash
  /// chain does not, so the whole list is re-chained in order.
  private static func carryAliasResolutionsForward(
    _ resolutions: [RuntimeTargetAliasResolution]?,
    canonicalTargetID: String,
    canonicalStableIdentitySHA256: String,
    canonicalBindingRevision: Int
  ) throws -> [RuntimeTargetAliasResolution]? {
    guard let resolutions,
      resolutions.contains(where: { $0.canonicalTargetID == canonicalTargetID })
    else { return resolutions }
    var rebuilt: [RuntimeTargetAliasResolution] = []
    var chain: String?
    for resolution in resolutions {
      let existing = draft(from: resolution)
      let updated: RuntimeTargetAliasResolutionDraft
      if resolution.canonicalTargetID == canonicalTargetID {
        updated = RuntimeTargetAliasResolutionDraft(
          aliasTargetID: existing.aliasTargetID,
          aliasStableIdentitySHA256: existing.aliasStableIdentitySHA256,
          aliasBindingRevision: existing.aliasBindingRevision,
          canonicalTargetID: existing.canonicalTargetID,
          canonicalStableIdentitySHA256: canonicalStableIdentitySHA256,
          canonicalBindingRevision: canonicalBindingRevision,
          routedHDCIdentitySHA256: existing.routedHDCIdentitySHA256,
          routedUSBTopology: existing.routedUSBTopology,
          establishingFlashJobID: existing.establishingFlashJobID,
          establishingFlashPlanDigestSHA256: existing.establishingFlashPlanDigestSHA256,
          confirmedStepIDs: existing.confirmedStepIDs,
          coveredUnknownIntents: existing.coveredUnknownIntents,
          establishedAtUTC: existing.establishedAtUTC)
      } else {
        updated = existing
      }
      let material = RuntimeTargetAliasResolutionMaterial(
        resolutionID: resolutionID(for: updated),
        aliasTargetID: updated.aliasTargetID,
        aliasStableIdentitySHA256: updated.aliasStableIdentitySHA256,
        aliasBindingRevision: updated.aliasBindingRevision,
        canonicalTargetID: updated.canonicalTargetID,
        canonicalStableIdentitySHA256: updated.canonicalStableIdentitySHA256,
        canonicalBindingRevision: updated.canonicalBindingRevision,
        routedHDCIdentitySHA256: updated.routedHDCIdentitySHA256,
        routedUSBTopology: updated.routedUSBTopology,
        establishingFlashJobID: updated.establishingFlashJobID,
        establishingFlashPlanDigestSHA256: updated.establishingFlashPlanDigestSHA256,
        confirmedStepIDs: updated.confirmedStepIDs,
        coveredUnknownIntents: updated.coveredUnknownIntents,
        establishedAtUTC: updated.establishedAtUTC,
        previousResolutionSHA256: chain)
      let next = RuntimeTargetAliasResolution(
        resolutionID: material.resolutionID,
        aliasTargetID: material.aliasTargetID,
        aliasStableIdentitySHA256: material.aliasStableIdentitySHA256,
        aliasBindingRevision: material.aliasBindingRevision,
        canonicalTargetID: material.canonicalTargetID,
        canonicalStableIdentitySHA256: material.canonicalStableIdentitySHA256,
        canonicalBindingRevision: material.canonicalBindingRevision,
        routedHDCIdentitySHA256: material.routedHDCIdentitySHA256,
        routedUSBTopology: material.routedUSBTopology,
        establishingFlashJobID: material.establishingFlashJobID,
        establishingFlashPlanDigestSHA256: material.establishingFlashPlanDigestSHA256,
        confirmedStepIDs: material.confirmedStepIDs,
        coveredUnknownIntents: material.coveredUnknownIntents,
        establishedAtUTC: material.establishedAtUTC,
        previousResolutionSHA256: material.previousResolutionSHA256,
        resolutionSHA256: try digest(material))
      rebuilt.append(next)
      chain = next.resolutionSHA256
    }
    return rebuilt
  }

  private static func digest(_ material: RuntimeTargetAliasResolutionMaterial) throws -> String {
    let encoder = CanonicalJSONEncoders.canonical()
    return sha256(try encoder.encode(material))
  }

  private static func resolutionID(
    for draft: RuntimeTargetAliasResolutionDraft
  ) -> String {
    let seed = sha256(
      [draft.aliasTargetID, draft.canonicalTargetID, draft.establishingFlashJobID]
        .joined(separator: "\n"))
    return "target-alias-resolution-\(seed.prefix(32))"
  }

  private static func sha256(_ text: String) -> String {
    sha256(Data(text.utf8))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }

  private func persist(_ document: TargetStoreDocument) throws {
    let lockFD = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockFD >= 0 else { throw BootstrapError.storeFailure("cannot open target lock") }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX) == 0 else {
      throw BootstrapError.storeFailure("cannot lock target store")
    }
    defer { flock(lockFD, LOCK_UN) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw BootstrapError.storeFailure("cannot encode target store: \(error)")
    }
    let temporary = url.deletingLastPathComponent()
      .appending(path: ".targets.tmp.\(getpid())")
    do {
      try data.write(to: temporary, options: [])
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.synchronize()
      try handle.close()
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
      throw BootstrapError.storeFailure("cannot persist target store: \(error)")
    }
  }
}

// MARK: - Observation port

/// What bootstrap may do, and nothing else. The production implementation
/// composes the HDC provider + dispatcher; fixtures fake it in tests.
public protocol BootstrapObservationPort: Sendable {
  func observeToolVersion() async throws -> String
  func listCandidates() async throws -> [BootstrapCandidate]
  /// Reads display-only facts through the same exact candidate route. A
  /// composition without this optional enrichment still supports bootstrap.
  func observeDeviceInformation(connectKey: String) async throws
    -> BootstrapDeviceInformation?
  /// Returns the device's stable-identity source attributes (serial et al).
  func observeDeviceIdentity(connectKey: String) async throws -> [String: String]
}

public extension BootstrapObservationPort {
  func observeDeviceInformation(connectKey: String) async throws
    -> BootstrapDeviceInformation?
  {
    nil
  }
}

// MARK: - The machine

public actor DeviceBootstrapMachine {
  private struct CandidateEnumeration: Sendable {
    let id: UInt64
    let task: Task<BootstrapCandidateSnapshot, Error>
  }

  private struct InformationRead: Sendable {
    let id: UInt64
    let generation: UInt64
    let task: Task<BootstrapDeviceInformationSnapshot, Never>
  }

  public private(set) var phase: BootstrapPhase = .discoverHostTools
  private let observation: any BootstrapObservationPort
  private let targetStore: RuntimeTargetStore
  private let nowUTC: @Sendable () -> String
  private let candidateClock = ContinuousClock()
  private let candidateSnapshotFreshnessWindow: Duration = .seconds(5)
  private var candidateEnumeration: CandidateEnumeration?
  private var nextCandidateEnumerationID: UInt64 = 0
  private var latestCandidateSnapshot: BootstrapCandidateSnapshot?
  /// Mints §8.5's snapshot generation and observation IDs. One per machine, so
  /// the generation is monotonic for this daemon session.
  private let observationRegistry = DeviceObservationRegistry()
  private var latestCandidateSnapshotObservedAt: ContinuousClock.Instant?
  private var latestCandidateRefreshFailed = false
  private var candidateMonitoringTask: Task<Void, Never>?
  private var informationRoutes: Set<String> = []
  private var informationGeneration: UInt64 = 0
  private var nextInformationReadID: UInt64 = 0
  private var informationRead: InformationRead?
  private var latestInformation: BootstrapDeviceInformationSnapshot?
  private var latestInformationObservedAt: ContinuousClock.Instant?

  public init(
    observation: any BootstrapObservationPort,
    targetStore: RuntimeTargetStore,
    nowUTC: @escaping @Sendable () -> String
  ) {
    self.observation = observation
    self.targetStore = targetStore
    self.nowUTC = nowUTC
  }

  /// Lists the current device candidates and nothing else: no selection, no
  /// trust wait, no adoption, no phase change. This is the discovery read the
  /// App's device list consumes — unlike `advance`, which adopts outright
  /// when exactly one Connected candidate is present, this method is
  /// deliberately incapable of producing a binding.
  public func enumerateCandidates() async throws -> [BootstrapCandidate] {
    try await refreshCandidateSnapshot().candidates
  }

  /// Returns the latest completed HDC observation immediately and starts a
  /// coalesced follow-up read. Only the first request of a new daemon session
  /// can wait for HDC; normal App cold starts consume the continuously warmed
  /// snapshot rather than joining a command with a multi-second tail.
  public func candidateSnapshotForPresentation() async throws -> BootstrapCandidateSnapshot {
    guard let latestCandidateSnapshot else {
      return try await refreshCandidateSnapshot()
    }
    scheduleCandidateRefresh()
    let isWithinFreshnessWindow =
      latestCandidateSnapshotObservedAt.map {
        $0.duration(to: candidateClock.now) <= candidateSnapshotFreshnessWindow
      } ?? false
    // Republished, not re-stamped: this is the same observation, and only its
    // freshness differs. Minting here would make every warm read look like a
    // new observation and would break the one thing a generation-scoped ID is
    // for — pinning an exact snapshot for `target adopt`.
    return observationRegistry.republish(
      latestCandidateSnapshot,
      health: !latestCandidateRefreshFailed && isWithinFreshnessWindow ? .current : .stale)
  }

  /// Explicit UI re-checks wait for one coalesced official HDC read. Startup
  /// uses the warm snapshot above; keeping these paths distinct preserves the
  /// button's promise without putting its worst-case latency back on launch.
  public func refreshCandidateSnapshotForPresentation() async throws
    -> BootstrapCandidateSnapshot
  {
    try await refreshCandidateSnapshot()
  }

  /// Enriches only current, authorized candidates with best-effort display
  /// information. Property failures omit decoration without hiding the
  /// primary candidate row, and unauthorized/offline routes are never asked
  /// to answer a device command.
  public func deviceInformationForPresentation(
    candidates: [BootstrapCandidate]
  ) async -> [String: BootstrapDeviceInformation] {
    await Self.readDeviceInformation(
      routes: Set(candidates.filter(\.isAuthorized).map(\.connectKey)),
      observation: observation, nowUTC: nowUTC).information
  }

  /// Startup consumes completed, bounded-age decoration while the daemon
  /// refreshes it independently. Explicit re-checks still await a property
  /// read. Neither path changes target identity, binding or admission facts.
  /// Decorate the current Runtime observation directly. Its authorized routes
  /// come from the owner snapshot, independently of the startup display cache.
  /// Information is presentation only and cannot establish a target binding.
  package func deviceInformationSnapshotForPresentation(
    observation snapshot: TargetObservationSnapshot
  ) async -> BootstrapDeviceInformationSnapshot {
    let routes = Set(snapshot.observations.map(\.candidate).filter(\.isAuthorized).map(\.connectKey))
    return await Self.readDeviceInformation(routes: routes, observation: observation, nowUTC: nowUTC)
  }

  public func deviceInformationSnapshotForPresentation(
    candidates: [BootstrapCandidate], useWarmSnapshot: Bool = false
  ) async -> BootstrapDeviceInformationSnapshot {
    let requestedRoutes = Set(candidates.filter(\.isAuthorized).map(\.connectKey))
    let routes = requestedRoutes.intersection(informationRoutes)
    guard !routes.isEmpty, !latestCandidateRefreshFailed else {
      return BootstrapDeviceInformationSnapshot(information: [:], observedAtUTC: nowUTC())
    }
    if useWarmSnapshot, let latestInformation, let latestInformationObservedAt,
      latestInformationObservedAt.duration(to: candidateClock.now)
        <= candidateSnapshotFreshnessWindow
    {
      return BootstrapDeviceInformationSnapshot(
        information: latestInformation.information.filter { routes.contains($0.key) },
        observedAtUTC: latestInformation.observedAtUTC)
    }

    let read = beginInformationRead()
    let snapshot = await resolveInformationRead(read)
    return BootstrapDeviceInformationSnapshot(
      information: snapshot.information.filter { routes.contains($0.key) },
      observedAtUTC: snapshot.observedAtUTC)
  }

  private static func readDeviceInformation(
    routes: Set<String>, observation: any BootstrapObservationPort,
    nowUTC: @Sendable () -> String
  ) async -> BootstrapDeviceInformationSnapshot {
    let values = await withTaskGroup(
      of: (String, BootstrapDeviceInformation)?.self,
      returning: [String: BootstrapDeviceInformation].self
    ) { group in
      for route in routes {
        group.addTask {
          guard let value = try? await observation.observeDeviceInformation(connectKey: route)
          else { return nil }
          return (route, value)
        }
      }
      var values: [String: BootstrapDeviceInformation] = [:]
      for await result in group {
        if let (route, value) = result { values[route] = value }
      }
      return values
    }
    return BootstrapDeviceInformationSnapshot(information: values, observedAtUTC: nowUTC())
  }

  private func beginInformationRead() -> InformationRead {
    if let informationRead { return informationRead }
    nextInformationReadID &+= 1
    let observation = observation
    let nowUTC = nowUTC
    let routes = informationRoutes
    let task = Task {
      await Self.readDeviceInformation(routes: routes, observation: observation, nowUTC: nowUTC)
    }
    let read = InformationRead(
      id: nextInformationReadID, generation: informationGeneration, task: task)
    informationRead = read
    return read
  }

  private func resolveInformationRead(
    _ read: InformationRead
  ) async -> BootstrapDeviceInformationSnapshot {
    let snapshot = await read.task.value
    guard read.generation == informationGeneration, !latestCandidateRefreshFailed else {
      return BootstrapDeviceInformationSnapshot(information: [:], observedAtUTC: nowUTC())
    }
    if informationRead?.id == read.id {
      informationRead = nil
      latestInformation = snapshot
      latestInformationObservedAt = candidateClock.now
    }
    return snapshot
  }

  private func invalidateDeviceInformation() {
    informationGeneration &+= 1
    informationRead?.task.cancel()
    informationRead = nil
    latestInformation = nil
    latestInformationObservedAt = nil
  }

  private func warmDeviceInformation() {
    guard informationRead == nil, !informationRoutes.isEmpty else { return }
    let read = beginInformationRead()
    Task { [weak self] in
      _ = await self?.resolveInformationRead(read)
    }
  }

  /// HDC has no public device-event stream. Keep its official read-only
  /// candidate command warm in the long-lived daemon instead of making every
  /// App process pay the command startup and server round trip.
  public func startCandidateMonitoring(interval: Duration = .seconds(2)) {
    guard candidateMonitoringTask == nil else { return }
    candidateMonitoringTask = Task.detached(priority: .utility) { [weak self] in
      let clock = ContinuousClock()
      while !Task.isCancelled {
        guard let self else { return }
        if (try? await self.refreshCandidateSnapshot()) != nil {
          await self.warmDeviceInformation()
        }
        do {
          try await clock.sleep(for: interval)
        } catch {
          return
        }
      }
    }
  }

  private func scheduleCandidateRefresh() {
    guard candidateEnumeration == nil else { return }
    Task { [weak self] in
      guard let self else { return }
      _ = try? await self.refreshCandidateSnapshot()
    }
  }

  private func refreshCandidateSnapshot() async throws -> BootstrapCandidateSnapshot {
    if let candidateEnumeration {
      return try await resolveCandidateEnumeration(candidateEnumeration)
    }

    nextCandidateEnumerationID &+= 1
    let enumerationID = nextCandidateEnumerationID
    let observation = observation
    let nowUTC = nowUTC
    let task = Task {
      let candidates = try await observation.listCandidates()
      return BootstrapCandidateSnapshot(
        candidates: candidates, observedAtUTC: nowUTC(), health: .current)
    }
    let enumeration = CandidateEnumeration(id: enumerationID, task: task)
    candidateEnumeration = enumeration
    return try await resolveCandidateEnumeration(enumeration)
  }

  /// Publishes the shared result before returning it to any waiter. Actor
  /// reentrancy means a caller coalescing onto an existing task can resume
  /// before the caller that created that task; making every waiter run the
  /// same idempotent commit closes the window where a completed refresh was
  /// returned while the presentation cache still held the previous value.
  private func resolveCandidateEnumeration(
    _ enumeration: CandidateEnumeration
  ) async throws -> BootstrapCandidateSnapshot {
    do {
      let observed = try await enumeration.task.value
      // Stamped here rather than inside the enumeration task: the task runs off
      // the actor, and the generation has to advance exactly once per committed
      // observation. Every waiter that coalesced onto this refresh must also
      // receive the stamped value — returning the raw snapshot to a losing
      // waiter would hand it candidates with no observation ID at all, which
      // reads as "this Runtime does not issue them" rather than "you raced".
      var snapshot = observed
      if candidateEnumeration?.id == enumeration.id {
        snapshot = observationRegistry.stamp(observed)
        candidateEnumeration = nil
        latestCandidateSnapshot = snapshot
        latestCandidateSnapshotObservedAt = candidateClock.now
        latestCandidateRefreshFailed = false
        targetStore.recordLiveHDCCandidates(snapshot.candidates)
        let routes = Set(snapshot.candidates.filter(\.isAuthorized).map(\.connectKey))
        if routes != informationRoutes {
          invalidateDeviceInformation()
          informationRoutes = routes
        }
        return snapshot
      }
      return latestCandidateSnapshot ?? snapshot
    } catch {
      if candidateEnumeration?.id == enumeration.id {
        candidateEnumeration = nil
        latestCandidateRefreshFailed = latestCandidateSnapshot != nil
        invalidateDeviceInformation()
      }
      throw error
    }
  }

  /// Runs the bootstrap to its next decision point. `selectedConnectKey`
  /// resolves a prior needsSelection; re-running after physical trust
  /// resumes automatically. Every path is observation-only.
  public func advance(selectedConnectKey: String? = nil) async -> BootstrapProgress {
    do {
      phase = .discoverHostTools
      let toolVersion = try await observation.observeToolVersion()
      phase = .observeHDCServer
      phase = .enumerateDeviceCandidates
      let candidates = try await observation.listCandidates()
      targetStore.recordLiveHDCCandidates(candidates)
      guard !candidates.isEmpty else {
        return .failed(reason: "no device candidates observed; connect a device and retry")
      }
      let selected: BootstrapCandidate
      if let selectedConnectKey {
        guard let match = candidates.first(where: { $0.connectKey == selectedConnectKey })
        else {
          return .failed(reason: "selected candidate is no longer present")
        }
        selected = match
      } else if candidates.count == 1 {
        selected = candidates[0]
      } else {
        return .needsSelection(candidates)
      }
      if selected.needsPhysicalTrust {
        phase = .waitForPhysicalTrust
        if selected.state == "Unauthorized" {
          return .waitingForHuman(
            kind: .trustDevice,
            prompt:
              "Confirm the debugging trust prompt on the device screen "
              + "(state: \(selected.state)); bootstrap resumes automatically.")
        }
        return .waitingForHuman(
          kind: .physicalReconnect,
          prompt:
            "Reconnect the device until it reports Connected "
            + "(state: \(selected.state)); bootstrap resumes automatically.")
      }
      phase = .observeSelectedDevice
      let identity = try await observation.observeDeviceIdentity(
        connectKey: selected.connectKey)
      guard let serial = identity["serial"], !serial.isEmpty else {
        return .failed(reason: "device identity has no stable serial; cannot bind safely")
      }
      phase = .createDurableTarget
      let stableIdentity = Self.stableIdentitySHA256(serial: serial)
      phase = .persistInitialBinding
      let (record, _) = try targetStore.adopt(
        stableIdentitySHA256: stableIdentity,
        connectKey: selected.connectKey,
        toolVersion: toolVersion,
        nowUTC: nowUTC())
      phase = .handedOff
      return .adopted(record)
    } catch let error as BootstrapError {
      return .failed(reason: "\(error)")
    } catch {
      return .failed(reason: "observation failed: \(error)")
    }
  }

  /// Mirrors DeviceIdentitySnapshot.stablePhysicalIdentitySha256: the
  /// stable identity hashes only the normalized serial.
  static func stableIdentitySHA256(serial: String) -> String {
    let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return SHA256Hex.string(of: Data(normalized.utf8))
  }
}
