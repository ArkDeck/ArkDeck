// The production writer that turns one terminal Job into a formal Session.
//
// Before this existed the Runtime finished Jobs, wrote their Artifacts and
// left the Sessions root empty: `SessionStorageTerminalFinalizer` had only
// test callers and the retention catalog stayed at `{"entries":[],
// "generation":0}`. Job -> Session -> exact finalized export could not be
// demonstrated at all.
//
// Everything here is derived from durable facts the Job already owns: its
// record, its own Journal, and the storage owner's configured root. Nothing
// is invented. A Session whose Manifest cannot be rendered from those facts
// is refused with an exact reason; a write whose outcome cannot be proven is
// `outcomeUnknown`, never a receipt.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import Foundation

// MARK: - Durable ownership marker

/// Where a Session publication got to, in the order the phases are entered.
///
/// The producer seals at terminal rather than streaming into the Session
/// while the Job runs, so `recording` is not one of its phases: nothing is
/// written under the Sessions root until the Job's outcome is known.
package enum RuntimeSessionPublicationPhase: String, Codable, Sendable, Equatable {
  /// A claim was requested and the Session root does not exist yet.
  case awaitingStorage
  /// The claim is bound to a created Session root; nothing is sealed.
  case prepared
  /// The checkpoint, Manifest proposal and complete Journal are sealed.
  case sealed
  /// The Manifest is published and read back under the Session root.
  case manifestPublished
  /// The catalog holds this Session's exact entry and the receipt is durable.
  case catalogPublished
}

/// The configured root this Job's Session belongs to. Never leaves the
/// Runtime: a caller-visible Job object must not disclose host paths.
package struct RuntimeSessionPublicationRoot: Codable, Sendable, Equatable {
  package let path: String
  package let device: String
  package let inode: String
  package let volumeIdentity: String
}

/// The device/inode of the Session directory this publication actually opened.
package struct RuntimeSessionPublicationIdentity: Codable, Sendable, Equatable {
  package let device: String
  package let inode: String
}

/// One per-volume claim this publication holds or held.
package struct RuntimeSessionPublicationClaim: Codable, Sendable, Equatable {
  package let volumeIdentity: String
  package let claimID: String
  package let admissionGeneration: String
  package let writerClass: String
  package let metadataHeadroomBytes: String
  package let finalizationHeadroomBytes: String
  package let remainingGrowthBytes: String
}

/// A sealed byte range: what was hashed, how much of it, and where it ended.
package struct RuntimeSessionPublicationSeal: Codable, Sendable, Equatable {
  package let sha256: String
  package let byteCount: String
  package let lastSequence: Int
}

/// The Manifest this publication proposes, before it is published.
package struct RuntimeSessionPublicationProposal: Codable, Sendable, Equatable {
  package let manifestSHA256: String
  package let manifestByteCount: String
  package let terminalStatus: String
  package let outcomeCertainty: String
  package let completedAtUTC: String
}

/// The publication receipt. A storage fact only: it says this Session's
/// Manifest was published and registered, not that the device succeeded and
/// not that the bytes will be retained.
package struct RuntimeSessionPublicationReceipt: Codable, Sendable, Equatable {
  package let manifestSHA256: String
  package let catalogGeneration: String
  package let publishedAtUTC: String
}

/// Why a publication stopped, and whether that stop is confirmed.
package struct RuntimeSessionPublicationFailureRecord: Codable, Sendable, Equatable {
  package let code: String
  package let certainty: String
  package let detail: String
}

/// The authoritative, internal ownership marker for one Job's Session.
///
/// Its absence is the only thing that means "unavailable". Pre-existing Jobs
/// are never given one retroactively: their `sessionId` is an identity string
/// the Runtime minted, not a claim that a Session was ever written.
package struct RuntimeSessionPublicationRecord: Codable, Sendable, Equatable {
  package let sessionID: String
  package let catalogDigest: String
  package let policyGeneration: String
  package let root: RuntimeSessionPublicationRoot
  /// Always derived as `yyyy/mm/<sessionId>`; never a caller-supplied path.
  package let relativeSessionPath: String
  package var sessionRootIdentity: RuntimeSessionPublicationIdentity?
  /// Nonempty for every record this writer creates.
  package var claims: [RuntimeSessionPublicationClaim]
  package var phase: RuntimeSessionPublicationPhase
  package var checkpointSeal: RuntimeSessionPublicationSeal?
  package var proposal: RuntimeSessionPublicationProposal?
  package var journalSeal: RuntimeSessionPublicationSeal?
  package var receipt: RuntimeSessionPublicationReceipt?
  package var failure: RuntimeSessionPublicationFailureRecord?

  /// The observable fact for this marker.
  ///
  /// A receipt outranks everything: once the catalog holds the entry, a later
  /// unrelated failure cannot un-publish it. Otherwise a recorded failure is
  /// reported with its own certainty, and anything else is still pending.
  package var fact: RuntimeSessionPublicationFact {
    if let receipt {
      return (try? RuntimeSessionPublicationFact.published(
        manifestSHA256: receipt.manifestSHA256,
        catalogGeneration: receipt.catalogGeneration))
        ?? .outcomeUnknown
    }
    if let failure {
      guard let reason = RuntimeSessionPublicationReason(rawValue: failure.code) else {
        return .outcomeUnknown
      }
      if failure.certainty != "confirmed" || !reason.isConfirmedFailure { return .outcomeUnknown }
      return (try? RuntimeSessionPublicationFact.failed(reason)) ?? .outcomeUnknown
    }
    return (try? RuntimeSessionPublicationFact.pending(
      phase == .awaitingStorage ? .waitingForStorage : .jobNotTerminal)) ?? .outcomeUnknown
  }
}

// MARK: - Writer seam

/// What the engine asks for at a Job's terminal boundary.
package struct RuntimeSessionPublicationRequest: Sendable {
  package let record: RuntimeJobRecord
  /// The Job's own Journal, as it stands after the terminal transition and
  /// before the `finalized` record this publication appends.
  package let journalURL: URL
  package let jobDirectory: URL
  package let nowUTC: String

  package init(
    record: RuntimeJobRecord, journalURL: URL, jobDirectory: URL, nowUTC: String
  ) {
    self.record = record
    self.journalURL = journalURL
    self.jobDirectory = jobDirectory
    self.nowUTC = nowUTC
  }
}

/// What the publication produced, and what the engine must persist.
package struct RuntimeSessionPublicationOutcome: Sendable {
  package let record: RuntimeSessionPublicationRecord
  /// The `finalized` Journal record this publication appended to the Job's
  /// own Journal, if it got that far. The engine advances its sequence past
  /// it so a later append cannot collide.
  package let appendedFinalizedSequence: Int?
}

/// The production seam. The engine never reaches storage directly; a build
/// that composed no writer refuses admission rather than quietly finishing
/// Jobs whose Sessions nobody writes.
package protocol RuntimeSessionPublicationWriting: Sendable {
  func publish(_ request: RuntimeSessionPublicationRequest) async -> RuntimeSessionPublicationOutcome
}

// MARK: - Manifest composition

/// Renders one Job's Manifest from its own durable facts.
///
/// Every field is either read out of the Job record or out of the Job's
/// Journal. When a fact the current Manifest contract requires is missing,
/// this refuses by name instead of substituting a placeholder device,
/// binding or tool.
package enum RuntimeSessionManifestComposer {
  package static let appVersion = "ArkDeckKit-M1-006"
  package static let platformProfile = "PLATFORM-MACOS@0.2.0"

  package struct Refusal: Error, Sendable, Equatable {
    package let reason: RuntimeSessionPublicationReason
    package let detail: String
  }

  /// Terminal Job states this producer can render into the current Manifest
  /// contract's closed `status` vocabulary.
  package static func manifestStatus(for state: String) -> String? {
    switch JobState(rawValue: state) {
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .cancelled: "cancelled"
    case .interrupted: "interrupted"
    // `recovered` is a Runtime terminal state with no Manifest counterpart:
    // the locked contract's status vocabulary has no `recovered`, and the
    // Journal's `finalized` record must carry the same word the Manifest
    // does. Rendering it as `succeeded` would erase the distinction the
    // recovery epoch exists to preserve, so it is refused instead.
    default: nil
    }
  }

  package static func disposition(
    for manifestStatus: String
  ) -> StorageTerminalDisposition? {
    switch manifestStatus {
    case "succeeded": .succeeded
    case "failed", "interrupted": .failed
    case "cancelled": .cancelled
    default: nil
    }
  }

  /// Builds the canonical Manifest bytes for this Job, or refuses.
  package static func compose(
    record: RuntimeJobRecord,
    replay: JournalReplay,
    completedAtUTC: String
  ) throws -> SessionManifestDocument {
    guard let status = manifestStatus(for: record.state) else {
      throw Refusal(
        reason: .contractViolation,
        detail: "terminal state \(record.state) has no current Manifest status")
    }
    guard !record.outcomeUnknown, !replay.requiresRecovery else {
      throw Refusal(
        reason: .contractViolation,
        detail: "an unresolved Job cannot be sealed as a confirmed Session")
    }
    guard let created = replay.events.first, created.kind == .jobCreated,
      let executionMode = created.payload.publicationString("executionMode"),
      let executionAuthority = created.payload.publicationString("executionAuthority"),
      let coreBaseline = created.payload.publicationString("coreBaseline")
    else {
      throw Refusal(
        reason: .sourceIntegrityFailed,
        detail: "the Job Journal does not open with its own creation facts")
    }

    let steps = try manifestSteps(replay: replay)
    let compensations = try manifestCompensations(replay: replay)
    let bindings = manifestBindings(replay: replay)
    let target = try manifestTarget(record: record, replay: replay, bindings: bindings)
    let toolchain = try manifestToolchain(record: record, target: target)

    var manifest: [String: JSONValue] = [
      "schemaVersion": .string("1.0.0"),
      "appVersion": .string(appVersion),
      "coreSpecBaseline": .string(coreBaseline),
      "platformProfile": .string(platformProfile),
      "sessionId": .string(record.sessionID),
      "jobId": .string(record.jobID),
      "status": .string(status),
      "executionMode": .string(executionMode),
      "executionAuthority": .string(executionAuthority),
      "outcomeCertainty": .string("confirmed"),
      "sessionDisposition": .string("finalized"),
      "createdAt": .string(record.createdAtUTC),
      "completedAt": .string(completedAtUTC),
      "archivedAt": .null,
      "originalTarget": target,
      "bindingHistory": .array(bindings),
      "toolchain": toolchain,
      "workflow": .object([
        "kind": .string(record.operationReference),
        "profileVersion": .string(record.catalogDigest),
        "providerIdentity": .string(record.providerID),
      ]),
      "steps": .array(steps),
      "parameters": .array([]),
      "compensations": .array(compensations),
      "confirmations": .array([]),
      // Runtime Artifacts stay in the Artifact store with their own index and
      // lineage. Copying them into the Session is a separate, byte-moving
      // step; declaring them here without copying would publish a Manifest
      // whose relative paths do not exist under the Session root.
      "artifacts": .array([]),
      "warnings": .array([]),
      "recovery": .null,
    ]
    if status == "failed" {
      guard let failure = record.operationFailure else {
        throw Refusal(
          reason: .sourceIntegrityFailed,
          detail: "a failed Job must carry its durable failure facts")
      }
      manifest["failure"] = .object([
        "stage": .string("runtime"),
        "code": .string(failure.code.rawValue),
        "summary": .string(
          "\(failure.category.rawValue)/\(failure.retryability.rawValue)/"
            + "\(failure.recovery.rawValue)"),
      ])
    } else {
      manifest["failure"] = .null
    }

    do {
      return try SessionManifestDocument(
        data: CanonicalJSONEncoders.canonical().encode(JSONValue.object(manifest)))
    } catch {
      throw Refusal(
        reason: .contractViolation,
        detail: "composed Manifest was refused by the current contract: \(error)")
    }
  }

  private static func manifestSteps(replay: JournalReplay) throws -> [JSONValue] {
    var outcomesByIntent: [String: JournalEvent] = [:]
    for event in replay.events where event.kind == .stepOutcome {
      guard let intentID = event.correlatedIntentEventID else { continue }
      outcomesByIntent[intentID] = event
    }
    var steps: [JSONValue] = []
    var seen: Set<String> = []
    for event in replay.events where event.kind == .stepIntent {
      guard let stepID = event.stepID, let declaration = event.payload["step"],
        case .object(var step) = declaration
      else {
        throw Refusal(
          reason: .sourceIntegrityFailed,
          detail: "Journal Step intent \(event.eventID) carries no typed declaration")
      }
      if !seen.insert(stepID).inserted {
        // A retried Step is one Manifest row; the Journal keeps every attempt
        // and the cross-validator matches the latest one.
        steps.removeAll { value in
          guard case .object(let existing) = value else { return false }
          return existing["id"] == .string(stepID)
        }
      }
      guard let argumentsHash = event.argumentsHash else {
        throw Refusal(
          reason: .sourceIntegrityFailed,
          detail: "Journal Step intent \(event.eventID) carries no arguments hash")
      }
      step["argumentsHash"] = .string(argumentsHash)
      step["sourceStepId"] = .null
      step["compensationTrigger"] = .null
      step["bindingRevision"] = event.bindingRevision.map { .integer(Int64($0)) } ?? .null
      let tuple = try executionTuple(outcome: outcomesByIntent[event.eventID], context: stepID)
      step["disposition"] = .string(tuple.disposition)
      step["outcomeCertainty"] = .string(tuple.certainty)
      step["semanticResult"] = .string(tuple.result)
      steps.append(.object(step))
    }
    return steps
  }

  private static func manifestCompensations(replay: JournalReplay) throws -> [JSONValue] {
    var outcomesByIntent: [String: JournalEvent] = [:]
    for event in replay.events where event.kind == .compensationOutcome {
      guard let intentID = event.correlatedIntentEventID else { continue }
      outcomesByIntent[intentID] = event
    }
    var records: [JSONValue] = []
    for event in replay.events where event.kind == .compensationIntent {
      guard let descriptorID = event.stepID, let descriptor = event.payload["descriptor"],
        let sourceStepID = event.payload.publicationString("compensationOfStepId")
      else {
        throw Refusal(
          reason: .sourceIntegrityFailed,
          detail: "Journal compensation intent \(event.eventID) is incomplete")
      }
      let outcome = outcomesByIntent[event.eventID]
      let tuple = try executionTuple(outcome: outcome, context: descriptorID)
      var eventIDs = [event.eventID]
      if let outcome { eventIDs.append(outcome.eventID) }
      records.removeAll { value in
        guard case .object(let existing) = value,
          case .object(let existingDescriptor)? = existing["descriptor"]
        else { return false }
        return existingDescriptor["id"] == .string(descriptorID)
      }
      records.append(
        .object([
          "descriptor": descriptor,
          "sourceStepId": .string(sourceStepID),
          "disposition": .string(tuple.disposition),
          "outcomeCertainty": .string(tuple.certainty),
          "result": .string(tuple.result),
          "failure": tuple.result == "failed"
            ? .object([
              "stage": .string("compensation"),
              "code": .string("compensation.failed"),
              "summary": .string(
                outcome?.payload.publicationString("summary") ?? "compensation reported failure"),
            ])
            : .null,
          "journalEventIds": .array(eventIDs.map(JSONValue.string)),
        ]))
    }
    return records
  }

  /// The exact tuple the Journal cross-validator will recompute. It is derived
  /// only from a recorded outcome; a Step with no outcome is not executed.
  private static func executionTuple(
    outcome: JournalEvent?, context: String
  ) throws -> (disposition: String, certainty: String, result: String) {
    guard let outcome else { return ("skipped", "notApplicable", "notRun") }
    guard let result = outcome.payload.publicationString("result"),
      let certainty = outcome.payload.publicationString("outcomeCertainty")
    else {
      throw Refusal(
        reason: .sourceIntegrityFailed,
        detail: "Journal outcome for \(context) is incomplete")
    }
    guard certainty == JournalOutcomeCertainty.confirmed.rawValue else {
      return ("outcomeUnknown", "outcomeUnknown", "unknown")
    }
    return ("executed", "confirmed", result == "succeeded" ? "succeeded" : "failed")
  }

  /// Binding history is taken verbatim from the Journal's confirmed bindings:
  /// the cross-validator compares the Manifest entry, minus its revision, to
  /// the exact object the binding event recorded.
  private static func manifestBindings(replay: JournalReplay) -> [JSONValue] {
    var byRevision: [Int: JSONValue] = [:]
    for event in replay.events where event.kind == .bindingConfirmed {
      guard let revision = event.bindingRevision,
        case .object(let binding)? = event.payload["binding"]
      else { continue }
      var entry = binding
      entry["revision"] = .integer(Int64(revision))
      byRevision[revision] = .object(entry)
    }
    return byRevision.keys.sorted().compactMap { byRevision[$0] }
  }

  private static func manifestTarget(
    record: RuntimeJobRecord, replay: JournalReplay, bindings: [JSONValue]
  ) throws -> JSONValue {
    let touchesDevice = replay.events.contains { event in
      guard event.kind == .stepIntent, case .object(let step)? = event.payload["step"] else {
        return false
      }
      if case .string(let effect)? = step["effect"], effect != "hostOnly" { return true }
      if case .string(let binding)? = step["bindingRequirement"], binding != "none" { return true }
      return false
    }
    if !touchesDevice && bindings.isEmpty {
      // An honest host branch. There is no device to name, so naming one -
      // even the target identifier the request carried - would assert a
      // binding this Job never made.
      return .object([
        "kind": .string("host"),
        "connectKey": .null,
        "transport": .string("host"),
        "identitySnapshot": .object([
          "workspaceScope": .string(record.request.target.targetID),
          "providerId": .string(record.providerID),
          "catalogDigest": .string(record.catalogDigest),
        ]),
      ])
    }
    // A device Session needs its address, its confirmed binding and the tool
    // that spoke to it. Those facts live with the Provider and the HDC server
    // lifecycle, not on the Job record, so this producer refuses rather than
    // publishing a Manifest whose target it cannot substantiate.
    throw Refusal(
      reason: .sourceIntegrityFailed,
      detail: "device-bound Session publication needs target and toolchain facts "
        + "this Job record does not carry")
  }

  private static func manifestToolchain(
    record: RuntimeJobRecord, target: JSONValue
  ) throws -> JSONValue {
    guard case .object(let targetObject) = target,
      targetObject["kind"] == .string("host")
    else {
      throw Refusal(
        reason: .sourceIntegrityFailed,
        detail: "no durable toolchain facts for a non-host Session")
    }
    guard let observation = record.evidenceObservation else {
      // Nothing external is claimed to have run, and nothing is invented.
      return .object(["kind": .string("none")])
    }
    return .object([
      "kind": .string("hostTool"),
      "providerIdentity": .string(observation.providerID),
      "profileIdentifier": .string(record.operationReference),
      "reportedVersion": .string(observation.toolVersion),
      "sha256": .string(observation.toolSHA256),
    ])
  }
}

extension [String: JSONValue] {
  /// The Journal's own accessor is internal to ArkDeckStorage; this reads the
  /// same shape without widening that module's surface.
  fileprivate func publicationString(_ key: String) -> String? {
    guard case .string(let value)? = self[key] else { return nil }
    return value
  }
}

// MARK: - Production writer

/// Publishes a Session through the configured Session owner.
///
/// The five phases follow the reviewed order exactly: claim, create, seal,
/// publish, register, receipt, release. Registration happens before the claim
/// is released, so a crash between them leaves a claim to recover rather than
/// an unregistered Session whose headroom was already given away.
package struct RuntimeSessionPublicationWriter: RuntimeSessionPublicationWriting {
  private let owner: RuntimeSessionStorageStore
  private let coordinator: HostStorageCoordinator
  private let probe: any HostStorageProbing

  package init(
    owner: RuntimeSessionStorageStore,
    coordinator: HostStorageCoordinator = HostStorageCoordinator(),
    probe: any HostStorageProbing = SystemHostStorageProbe()
  ) {
    self.owner = owner
    self.coordinator = coordinator
    self.probe = probe
  }

  package func publish(
    _ request: RuntimeSessionPublicationRequest
  ) async -> RuntimeSessionPublicationOutcome {
    do {
      return try await attempt(request)
    } catch let refusal as RuntimeSessionManifestComposer.Refusal {
      return RuntimeSessionPublicationOutcome(
        record: refusedRecord(request, reason: refusal.reason, detail: refusal.detail),
        appendedFinalizedSequence: nil)
    } catch let failure as RuntimeSessionStorageFailure {
      return RuntimeSessionPublicationOutcome(
        record: refusedRecord(
          request, reason: .storageUnavailable, detail: "\(failure.code): \(failure.message)"),
        appendedFinalizedSequence: nil)
    } catch {
      return RuntimeSessionPublicationOutcome(
        record: refusedRecord(
          request, reason: .storageUnavailable, detail: String(describing: error)),
        appendedFinalizedSequence: nil)
    }
  }

  // MARK: Phases

  private func attempt(
    _ request: RuntimeSessionPublicationRequest
  ) async throws -> RuntimeSessionPublicationOutcome {
    let record = request.record
    if let existing = record.sessionPublicationRecord, existing.receipt != nil {
      // The receipt is already durable. Re-running the phases would try to
      // create a Session root that exists and refuse, turning a completed
      // publication into a failure; and re-registering would be a second
      // catalog decision about the same bytes. A receipt records what
      // happened once — it is not a promise the bytes are still retained, so
      // repeating it neither re-proves nor re-writes anything.
      return RuntimeSessionPublicationOutcome(
        record: existing, appendedFinalizedSequence: nil)
    }
    let status = try owner.status()
    let root = URL(filePath: status.rootPath, directoryHint: .isDirectory)
    let rootFacts = try Self.rootFacts(root)
    guard let createdAt = ISO8601Timestamps.parse(record.createdAtUTC) else {
      throw RuntimeSessionManifestComposer.Refusal(
        reason: .sourceIntegrityFailed, detail: "Job creation time is unreadable")
    }
    let relative = Self.relativeSessionPath(sessionID: record.sessionID, createdAt: createdAt)

    // 1. Reserve metadata and finalization headroom before anything is created.
    let replay = try DurableJournalRecovery.inspect(url: request.journalURL)
    let journalBytes = UInt64((try Data(contentsOf: request.journalURL)).count)
    let budget = try StorageBudget(
      metadataHeadroomBytes: max(journalBytes, 1) + 64 * 1_024,
      finalizationHeadroomBytes: UInt64(SessionManifestDocument.maximumCanonicalBytes),
      remainingGrowthBytes: 0, writerClass: .light)
    let claimRequest = try StorageClaimRequest(
      claimID: "session-publication-\(record.jobID)", jobID: record.jobID,
      volumeIdentity: rootFacts.volumeIdentity, budget: budget)
    let snapshot = try probe.snapshot(for: root)
    guard case .admitted(let claim) = await coordinator.admit(claimRequest, snapshot: snapshot)
    else {
      var pending = Self.marker(
        request, root: rootFacts.root, relative: relative,
        policyGeneration: status.generation, claims: [])
      pending.phase = .awaitingStorage
      return RuntimeSessionPublicationOutcome(record: pending, appendedFinalizedSequence: nil)
    }
    var marker = Self.marker(
      request, root: rootFacts.root, relative: relative,
      policyGeneration: status.generation,
      claims: [
        RuntimeSessionPublicationClaim(
          volumeIdentity: claim.volumeIdentity.value, claimID: claim.claimID,
          admissionGeneration: claim.admissionGenerationIdentity,
          writerClass: claim.writerClass.rawValue,
          metadataHeadroomBytes: String(claim.metadataHeadroomBytes),
          finalizationHeadroomBytes: String(claim.finalizationHeadroomBytes),
          remainingGrowthBytes: String(claim.remainingGrowthBytes))
      ])

    // 2. Compose the proposal before a byte is written under the Sessions
    //    root. A Job whose facts cannot render the current contract never
    //    creates a Session directory at all.
    let manifest: SessionManifestDocument
    do {
      manifest = try RuntimeSessionManifestComposer.compose(
        record: record, replay: replay, completedAtUTC: record.finishedAtUTC ?? request.nowUTC)
    } catch {
      await coordinator.cancelUnboundAdmission(claim)
      throw error
    }
    guard let disposition = RuntimeSessionManifestComposer.disposition(for: manifest.status) else {
      await coordinator.cancelUnboundAdmission(claim)
      throw RuntimeSessionManifestComposer.Refusal(
        reason: .contractViolation, detail: "no storage disposition for \(manifest.status)")
    }

    // 3. Freeze the checkpoint of the exact record and Journal prefix this
    //    proposal was built from, before any seal field is set.
    marker.checkpointSeal = RuntimeSessionPublicationSeal(
      sha256: SHA256Hex.string(of: try record.durableData()),
      byteCount: String(journalBytes),
      lastSequence: replay.events.last?.sequence ?? -1)
    marker.proposal = RuntimeSessionPublicationProposal(
      manifestSHA256: manifest.sha256, manifestByteCount: String(manifest.canonicalData.count),
      terminalStatus: record.state, outcomeCertainty: "confirmed",
      completedAtUTC: record.finishedAtUTC ?? request.nowUTC)
    try DurableFileWriter.createOrReplaceAtomically(
      destination: request.jobDirectory.appending(path: "session-manifest.proposal.json"),
      data: manifest.canonicalData)

    // 4. Append the last finalized record to the Job's own Journal. It refers
    //    to the proposal hash, so the Manifest cannot in turn hash the
    //    complete Journal without a cycle; journalSeal binds it instead.
    let sequence = (replay.events.last?.sequence ?? -1) + 1
    let finalized = try JournalEvent(
      eventID: "session-finalized", sequence: sequence, sessionID: record.sessionID,
      jobID: record.jobID, timestamp: request.nowUTC, kind: .finalized,
      payload: [
        "terminalStatus": .string(record.state),
        "manifestSha256": .string(manifest.sha256),
        "outcomeCertainty": .string("confirmed"),
      ])
    let sourceJournal = try FileDurableJournal(url: request.journalURL)
    if !replay.finalized { try sourceJournal.appendAndSynchronize(finalized) }
    let sealedReplay = try DurableJournalRecovery.inspect(url: request.journalURL)

    // 5. Create the Session, publish identical Journal bytes and the
    //    validated Manifest, read back, register, then release.
    let sessionStore = try SessionStore(sessionsRoot: root)
    let layout = try sessionStore.createSession(
      sessionID: record.sessionID, jobID: record.jobID, createdAt: createdAt, claim: claim)
    marker.sessionRootIdentity = try Self.identity(layout.root)
    marker.phase = .prepared

    let sessionJournal = try FileDurableJournal(url: layout.journalURL)
    for event in sealedReplay.events { try sessionJournal.appendAndSynchronize(event) }
    let publishedBytes = try Data(contentsOf: layout.journalURL)
    guard publishedBytes == (try Data(contentsOf: request.journalURL)) else {
      throw RuntimeSessionManifestComposer.Refusal(
        reason: .sourceIntegrityFailed,
        detail: "the Session Journal copy is not byte-identical to the Job Journal")
    }
    marker.journalSeal = RuntimeSessionPublicationSeal(
      sha256: SHA256Hex.string(of: publishedBytes),
      byteCount: String(publishedBytes.count),
      lastSequence: sealedReplay.events.last?.sequence ?? sequence)
    marker.phase = .sealed

    let boundClaim = try await coordinator.beginTerminalFinalization(
      claimID: claim.claimID, disposition: disposition)
    let audit = try FileDurableSessionAuditStore(layout: layout)
    let auditRecord = try SessionAuditRecord(
      recordID: "session-publication-outcome", auditID: "session-publication-\(record.jobID)",
      correlationID: record.jobID, sessionID: record.sessionID, jobID: record.jobID,
      category: .outcome, timestamp: request.nowUTC,
      details: [
        "terminalStatus": .string(record.state),
        "manifestSha256": .string(manifest.sha256),
        "operation": .string(record.operationReference),
      ])
    let receipt = try SessionStorageTerminalFinalizer(
      audit: audit, manifestPublisher: AtomicSessionManifestPublisher(layout: layout)
    ).persist(
      claim: boundClaim, disposition: disposition, auditRecord: auditRecord, manifest: manifest)
    guard receipt.manifestSHA256 == manifest.sha256,
      try AtomicSessionManifestPublisher(layout: layout).load().sha256 == manifest.sha256
    else {
      throw RuntimeSessionManifestComposer.Refusal(
        reason: .contractViolation, detail: "published Manifest does not read back")
    }
    marker.phase = .manifestPublished

    let generation = try owner.registerPublishedSession(sessionRoot: layout.root)
    marker.receipt = RuntimeSessionPublicationReceipt(
      manifestSHA256: manifest.sha256, catalogGeneration: String(generation),
      publishedAtUTC: request.nowUTC)
    marker.phase = .catalogPublished
    _ = try await coordinator.completeRecoveredFinalization(receipt)
    return RuntimeSessionPublicationOutcome(
      record: marker, appendedFinalizedSequence: replay.finalized ? nil : sequence)
  }

  // MARK: Helpers

  private func refusedRecord(
    _ request: RuntimeSessionPublicationRequest,
    reason: RuntimeSessionPublicationReason,
    detail: String
  ) -> RuntimeSessionPublicationRecord {
    var marker = Self.marker(
      request, root: RuntimeSessionPublicationRoot(
        path: "", device: "0", inode: "0", volumeIdentity: ""),
      relative: "", policyGeneration: 0, claims: [])
    marker.failure = RuntimeSessionPublicationFailureRecord(
      code: reason.rawValue,
      certainty: reason.isConfirmedFailure ? "confirmed" : "outcomeUnknown",
      detail: String(detail.prefix(512)))
    return marker
  }

  private static func marker(
    _ request: RuntimeSessionPublicationRequest,
    root: RuntimeSessionPublicationRoot,
    relative: String,
    policyGeneration: UInt64,
    claims: [RuntimeSessionPublicationClaim]
  ) -> RuntimeSessionPublicationRecord {
    RuntimeSessionPublicationRecord(
      sessionID: request.record.sessionID, catalogDigest: request.record.catalogDigest,
      policyGeneration: String(policyGeneration), root: root, relativeSessionPath: relative,
      sessionRootIdentity: nil, claims: claims, phase: .awaitingStorage,
      checkpointSeal: nil, proposal: nil, journalSeal: nil, receipt: nil, failure: nil)
  }

  private static func relativeSessionPath(sessionID: String, createdAt: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month], from: createdAt)
    return String(format: "%04d/%02d/", parts.year ?? 0, parts.month ?? 0) + sessionID
  }

  private static func rootFacts(
    _ root: URL
  ) throws -> (root: RuntimeSessionPublicationRoot, volumeIdentity: VolumeIdentity) {
    let identity = try SystemVolumeIdentityResolver().resolve(root)
    let facts = try Self.identity(root)
    return (
      RuntimeSessionPublicationRoot(
        path: root.path, device: facts.device, inode: facts.inode,
        volumeIdentity: identity.value),
      identity
    )
  }

  private static func identity(_ url: URL) throws -> RuntimeSessionPublicationIdentity {
    var metadata = stat()
    guard Darwin.lstat(url.path, &metadata) == 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session root identity is unreadable")
    }
    return RuntimeSessionPublicationIdentity(
      device: String(UInt64(UInt32(bitPattern: metadata.st_dev))),
      inode: String(UInt64(metadata.st_ino)))
  }
}
