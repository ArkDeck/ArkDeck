import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public struct SessionManifestConfirmation: Equatable, Sendable {
  public let confirmationID: String
  public let kind: String
  public let scopeHash: String
  public let decision: String
  public let actor: String
  public let actorAuthorizationReference: AuthorizationReference?
  public let decidedAt: String
  public let relatedStepIDs: [String]

  fileprivate init(object: [String: JSONValue], schemaVersion: String) throws {
    confirmationID = try object.manifestString("confirmationId")
    kind = try object.manifestString("kind")
    scopeHash = try object.manifestString("scopeHash")
    decision = try object.manifestString("decision")
    if schemaVersion == "1.0.0" {
      actor = try object.manifestString("actor")
      actorAuthorizationReference = nil
    } else {
      guard case .object(let actorObject)? = object["actor"],
        case .string(let kind)? = actorObject["kind"]
      else { throw SessionStorageError.invalidManifest("confirmation actor must be object") }
      actor = kind == "interactiveUser" ? "user" : kind
      if let value = actorObject["authorizationRef"] {
        do {
          actorAuthorizationReference = try AuthorizationReference(
            jsonValue: value, context: "confirmation.actor.authorizationRef")
        } catch {
          throw SessionStorageError.invalidManifest(
            "confirmation actor authorizationRef is malformed")
        }
      } else {
        actorAuthorizationReference = nil
      }
    }
    decidedAt = try object.manifestString("decidedAt")
    relatedStepIDs = try object.manifestStringArray("relatedStepIds")
  }
}

public struct SessionManifestAuthorization: Equatable, Sendable {
  public let authorizationReference: AuthorizationReference
  public let usageReservationID: String
  public let destructiveIntentEventIDs: [String]

  fileprivate init(object: [String: JSONValue]) throws {
    try object.manifestRequireKeys([
      "authorizationRef", "usageReservationId", "destructiveIntentEventIds",
    ])
    do {
      authorizationReference = try AuthorizationReference(
        jsonValue: object["authorizationRef"]!,
        context: "manifest.authorization.authorizationRef")
    } catch {
      throw SessionStorageError.invalidManifest("manifest authorizationRef is malformed")
    }
    usageReservationID = try object.manifestString("usageReservationId")
    try SessionStorageValidation.identifier(
      usageReservationID, field: "authorization.usageReservationId")
    destructiveIntentEventIDs = try object.manifestStringArray("destructiveIntentEventIds")
    guard Set(destructiveIntentEventIDs).count == destructiveIntentEventIDs.count else {
      throw SessionStorageError.invalidManifest("duplicate destructiveIntentEventIds")
    }
    for eventID in destructiveIntentEventIDs {
      try SessionStorageValidation.identifier(
        eventID, field: "authorization.destructiveIntentEventIds")
    }
  }
}

public struct SessionManifestDocument: Equatable, Sendable {
  public static let maximumCanonicalBytes = 16 * 1_024 * 1_024
  public let canonicalData: Data
  public let sha256: String
  public let schemaVersion: String
  public let sessionID: String
  public let jobID: String
  public let status: String
  public let executionMode: String
  public let executionAuthority: String
  public let authorization: SessionManifestAuthorization?
  public let artifacts: [ArtifactRecord]
  public let confirmations: [SessionManifestConfirmation]

  public init(data: Data) throws {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    try duplicateValidator.validate()
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .object(let object) = root else {
      throw SessionStorageError.invalidManifest("manifest must be an object")
    }
    try LockedSessionManifestValidator.validate(object)
    let canonicalData = try SessionStorageValidation.canonicalData(root)
    guard !canonicalData.isEmpty, canonicalData.count <= Self.maximumCanonicalBytes else {
      throw SessionStorageError.invalidManifest(
        "canonical manifest exceeds \(Self.maximumCanonicalBytes) bytes")
    }
    self.canonicalData = canonicalData
    sha256 = SessionStorageValidation.lowercaseSHA256(canonicalData)
    let decodedSchemaVersion = try object.manifestString("schemaVersion")
    schemaVersion = decodedSchemaVersion
    sessionID = try object.manifestString("sessionId")
    jobID = try object.manifestString("jobId")
    status = try object.manifestString("status")
    executionMode = try object.manifestString("executionMode")
    executionAuthority = try object.manifestString("executionAuthority")
    if case .object(let authorizationObject)? = object["authorization"] {
      authorization = try SessionManifestAuthorization(object: authorizationObject)
    } else {
      authorization = nil
    }
    artifacts = try object.manifestArray("artifacts").map { value in
      try JSONDecoder().decode(
        ArtifactRecord.self, from: SessionStorageValidation.canonicalData(value))
    }
    confirmations = try object.manifestArray("confirmations").map { value in
      guard case .object(let confirmation) = value else {
        throw SessionStorageError.invalidManifest("confirmation must be object")
      }
      return try SessionManifestConfirmation(
        object: confirmation, schemaVersion: decodedSchemaVersion)
    }
  }
}

public struct PublishedSessionManifest: Equatable, Sendable {
  public let url: URL
  public let sha256: String
}

public protocol SessionManifestPublishing: Sendable {
  var layout: SessionLayout { get }
  func storageVolumeIdentity(using resolver: any VolumeIdentityResolving) throws -> VolumeIdentity
  func publish(_ manifest: SessionManifestDocument) throws -> PublishedSessionManifest
  func load() throws -> SessionManifestDocument
}

public final class AtomicSessionManifestPublisher: SessionManifestPublishing, @unchecked Sendable {
  public let layout: SessionLayout
  private let lock = NSLock()
  private let faultInjector: SessionStorageFaultInjector

  public init(
    layout: SessionLayout,
    faultInjector: SessionStorageFaultInjector = .none
  ) {
    self.layout = layout
    self.faultInjector = faultInjector
  }

  public func storageVolumeIdentity(using resolver: any VolumeIdentityResolving) throws
    -> VolumeIdentity
  {
    try resolver.resolve(layout.root)
  }

  public func publish(_ manifest: SessionManifestDocument) throws -> PublishedSessionManifest {
    guard manifest.sessionID == layout.sessionID, manifest.jobID == layout.jobID else {
      throw SessionStorageError.invalidManifest("manifest Session/Job identity mismatch")
    }
    guard manifest.canonicalData.count <= SessionManifestDocument.maximumCanonicalBytes else {
      throw SessionStorageError.invalidManifest(
        "canonical manifest exceeds \(SessionManifestDocument.maximumCanonicalBytes) bytes")
    }
    let temporaryURL = layout.root.appending(
      path: ".manifest.\(UUID().uuidString).tmp", directoryHint: .notDirectory)
    let temporaryName = temporaryURL.lastPathComponent

    lock.lock()
    defer { lock.unlock() }
    do {
      try faultInjector.check(.manifestValidation)
      return try withExclusivePublisherLock {
        try SessionArtifactPublicationBarrier.withAllShards(layout: layout) { directories in
          let journalSnapshot = try LockedSessionJournalSnapshot(
            layout: layout, directories: directories)
          try SessionManifestJournalValidator.validate(
            manifest: manifest, replay: journalSnapshot.replay)
          var existingMetadata = stat()
          if fstatat(
            directories.rootDescriptor, layout.manifestURL.lastPathComponent,
            &existingMetadata, AT_SYMLINK_NOFOLLOW) == 0
          {
            guard existingMetadata.st_mode & S_IFMT == S_IFREG else {
              throw SessionStorageError.invalidManifest(
                "terminal manifest path is not a regular file")
            }
            let existing = try loadUnlocked()
            guard existing.canonicalData == manifest.canonicalData else {
              throw SessionStorageError.invalidManifest(
                "a terminal manifest is already published for this Session")
            }
            let cleanupPlan = try ArtifactPublicationRecoveryStore.preflightCommit(
              layout: layout, artifacts: manifest.artifacts, directories: directories)
            try cleanupPlan.validateArtifacts()
            try journalSnapshot.validateStillCurrent()
            // An earlier publisher may have completed rename but failed the directory barrier.
            // Idempotent publication repairs that barrier before returning durable success.
            try faultInjector.check(.manifestDirectorySync)
            try directories.syncDirectory(
              directories.rootDescriptor, path: layout.root.path)
            try ArtifactPublicationRecoveryStore.cleanupCommitted(
              layout: layout, plan: cleanupPlan, faultInjector: faultInjector)
            return PublishedSessionManifest(url: layout.manifestURL, sha256: manifest.sha256)
          } else if errno != ENOENT {
            throw SessionStorageError.writeFailed(path: layout.manifestURL.path, errno: errno)
          }
          // Marker/manifest conflicts must fail before the write-once terminal path can exist.
          let cleanupPlan = try ArtifactPublicationRecoveryStore.preflightCommit(
            layout: layout, artifacts: manifest.artifacts, directories: directories)
          let descriptor = Darwin.openat(
            directories.rootDescriptor, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
          guard descriptor >= 0 else {
            throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
          }
          var descriptorIsOpen = true
          defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            _ = Darwin.unlinkat(directories.rootDescriptor, temporaryName, 0)
          }
          try faultInjector.check(.manifestWrite)
          try DurableFilePrimitives.writeAll(
            manifest.canonicalData, descriptor: descriptor, path: temporaryURL.path)
          try faultInjector.check(.manifestFileSync)
          try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
          guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw SessionStorageError.writeFailed(path: temporaryURL.path, errno: errno)
          }
          descriptorIsOpen = false

          try faultInjector.check(.manifestReplace)
          // Revalidate every descriptor-bound Artifact after the last injectable pause and
          // immediately before the write-once terminal rename.
          try cleanupPlan.validateArtifacts()
          try journalSnapshot.validateStillCurrent()
          guard
            renameatx_np(
              directories.rootDescriptor, temporaryName, directories.rootDescriptor,
              layout.manifestURL.lastPathComponent, UInt32(RENAME_EXCL)) == 0
          else {
            if errno == EEXIST {
              let existing = try loadUnlocked()
              guard existing.canonicalData == manifest.canonicalData else {
                throw SessionStorageError.invalidManifest(
                  "a terminal manifest is already published for this Session")
              }
              try cleanupPlan.validateArtifacts()
              try journalSnapshot.validateStillCurrent()
              try faultInjector.check(.manifestDirectorySync)
              try directories.syncDirectory(
                directories.rootDescriptor, path: layout.root.path)
              try ArtifactPublicationRecoveryStore.cleanupCommitted(
                layout: layout, plan: cleanupPlan, faultInjector: faultInjector)
              return PublishedSessionManifest(url: layout.manifestURL, sha256: manifest.sha256)
            }
            throw SessionStorageError.writeFailed(path: layout.manifestURL.path, errno: errno)
          }
          try faultInjector.check(.manifestDirectorySync)
          try directories.syncDirectory(
            directories.rootDescriptor, path: layout.root.path)
          try ArtifactPublicationRecoveryStore.cleanupCommitted(
            layout: layout, plan: cleanupPlan, faultInjector: faultInjector)
          return PublishedSessionManifest(url: layout.manifestURL, sha256: manifest.sha256)
        }
      }
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  public func load() throws -> SessionManifestDocument {
    lock.lock()
    defer { lock.unlock() }
    do {
      return try withExclusivePublisherLock { try loadUnlocked() }
    } catch {
      throw SessionStorageValidation.storageDomainError(error)
    }
  }

  private func withExclusivePublisherLock<T>(_ body: () throws -> T) throws -> T {
    try SessionTerminalPublicationLock.withExclusive(in: layout.root, body)
  }

  private func loadUnlocked() throws -> SessionManifestDocument {
    try DurableFilePrimitives.rejectSymbolicLink(layout.manifestURL)
    let descriptor = Darwin.open(
      layout.manifestURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.writeFailed(path: layout.manifestURL.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      metadata.st_size > 0,
      metadata.st_size <= SessionManifestDocument.maximumCanonicalBytes
    else { throw SessionStorageError.invalidManifest("manifest must be a bounded regular file") }
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw SessionStorageError.writeFailed(
          path: layout.manifestURL.path, errno: count < 0 ? errno : EIO)
      }
      offset += count
    }
    let manifest = try SessionManifestDocument(data: data)
    guard manifest.sessionID == layout.sessionID, manifest.jobID == layout.jobID else {
      throw SessionStorageError.invalidManifest("manifest Session/Job identity mismatch")
    }
    return manifest
  }
}

private final class LockedSessionJournalSnapshot {
  let replay: JournalReplay
  private let layout: SessionLayout
  private let rootDescriptor: Int32
  private let descriptor: Int32?
  private let metadata: stat?

  init(
    layout: SessionLayout,
    directories: AnchoredSessionArtifactDirectories
  ) throws {
    self.layout = layout
    rootDescriptor = directories.rootDescriptor
    let journalName = layout.journalURL.lastPathComponent
    let opened = Darwin.openat(
      directories.rootDescriptor, journalName,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if opened < 0 {
      guard errno == ENOENT else {
        throw SessionStorageError.writeFailed(path: layout.journalURL.path, errno: errno)
      }
      descriptor = nil
      metadata = nil
      replay = try DurableJournalRecovery.inspect(data: Data())
      return
    }
    var keepOpen = false
    defer { if !keepOpen { Darwin.close(opened) } }
    var openedMetadata = stat()
    guard fstat(opened, &openedMetadata) == 0,
      openedMetadata.st_mode & S_IFMT == S_IFREG,
      openedMetadata.st_uid == geteuid(), openedMetadata.st_nlink == 1,
      openedMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      openedMetadata.st_dev == directories.rootDevice
    else {
      throw SessionStorageError.invalidManifest(
        "journal snapshot must be an owner-safe Session-root regular file")
    }
    // A Manifest may only rely on bytes that have crossed both the file and parent-directory
    // durability barriers. The shared terminal lock prevents participating writers from
    // appending until the write-once rename is complete.
    try DurableFilePrimitives.fullSync(opened, path: layout.journalURL.path)
    try directories.syncDirectory(directories.rootDescriptor, path: layout.root.path)
    let snapshot = try DurableJournalRecovery.inspect(
      openFileDescriptor: opened, path: layout.journalURL.path)
    guard sameManifestJournalSnapshot(openedMetadata, snapshot.metadata) else {
      throw SessionStorageError.invalidManifest("journal changed during Manifest preflight")
    }
    var pathMetadata = stat()
    guard
      fstatat(
        directories.rootDescriptor, journalName, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      sameManifestJournalSnapshot(snapshot.metadata, pathMetadata)
    else {
      throw SessionStorageError.invalidManifest(
        "journal path changed during Manifest preflight")
    }
    descriptor = opened
    metadata = snapshot.metadata
    replay = snapshot.replay
    keepOpen = true
  }

  deinit {
    if let descriptor { Darwin.close(descriptor) }
  }

  func validateStillCurrent() throws {
    let journalName = layout.journalURL.lastPathComponent
    guard let descriptor, let metadata else {
      var unexpected = stat()
      guard fstatat(rootDescriptor, journalName, &unexpected, AT_SYMLINK_NOFOLLOW) != 0,
        errno == ENOENT
      else {
        throw SessionStorageError.invalidManifest(
          "journal appeared after the stable Manifest snapshot")
      }
      return
    }
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      sameManifestJournalSnapshot(metadata, descriptorMetadata),
      fstatat(rootDescriptor, journalName, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      sameManifestJournalSnapshot(metadata, pathMetadata)
    else {
      throw SessionStorageError.invalidManifest(
        "journal changed before write-once Manifest publication")
    }
  }
}

private enum SessionManifestJournalValidator {
  private struct ExecutionAttempt {
    let intent: JournalEvent
    let outcome: JournalEvent?
  }

  static func validate(manifest: SessionManifestDocument, replay: JournalReplay) throws {
    guard !replay.hasTornTail else {
      throw failure("journal has a torn tail")
    }
    let root = try JSONDecoder().decode(JSONValue.self, from: manifest.canonicalData)
    guard case .object(let object) = root else { throw failure("manifest must be an object") }
    let outcomeCertainty = try object.manifestString("outcomeCertainty")
    let executionAuthority = try object.manifestString("executionAuthority")
    let coreSpecBaseline = try object.manifestString("coreSpecBaseline")
    let stepValues = try object.manifestArray("steps")
    let compensationValues = try object.manifestArray("compensations")
    var bindingsByRevision: [Int: JSONValue] = [:]
    for value in try object.manifestArray("bindingHistory") {
      guard case .object(var binding) = value else {
        throw failure("binding history entry must be an object")
      }
      let revision = Int(try binding.manifestInteger("revision"))
      binding.removeValue(forKey: "revision")
      bindingsByRevision[revision] = .object(binding)
    }
    let bindingRevisions = Set(bindingsByRevision.keys)

    var stepsByID: [String: [String: JSONValue]] = [:]
    for value in stepValues {
      guard case .object(let step) = value else { continue }
      stepsByID[try step.manifestString("id")] = step
    }
    struct CompensationReference {
      let sourceStepID: String
      let descriptor: JSONValue
      let record: [String: JSONValue]
      let journalEventIDs: Set<String>
    }
    var compensationsByID: [String: CompensationReference] = [:]
    for value in compensationValues {
      guard case .object(let compensation) = value,
        let descriptor = compensation["descriptor"],
        case .object(let descriptorObject) = descriptor
      else { continue }
      let descriptorID = try descriptorObject.manifestString("id")
      let journalEventIDs = try compensation.manifestStringArray("journalEventIds")
      guard Set(journalEventIDs).count == journalEventIDs.count else {
        throw failure("duplicate compensation journalEventIds: \(descriptorID)")
      }
      compensationsByID[descriptorID] = CompensationReference(
        sourceStepID: try compensation.manifestString("sourceStepId"),
        descriptor: descriptor, record: compensation,
        journalEventIDs: Set(journalEventIDs))
    }

    let eventsByID = Dictionary(uniqueKeysWithValues: replay.events.map { ($0.eventID, $0) })
    let outcomesByIntentID = Dictionary(
      uniqueKeysWithValues: replay.events.compactMap { event -> (String, JournalEvent)? in
        guard event.kind == .stepOutcome || event.kind == .compensationOutcome,
          let intentID = event.correlatedIntentEventID
        else { return nil }
        return (intentID, event)
      })
    var latestStepAttempts: [String: ExecutionAttempt] = [:]
    var latestCompensationAttempts: [String: ExecutionAttempt] = [:]
    if let first = replay.events.first {
      guard first.schemaVersion == manifest.schemaVersion,
        first.sessionID == manifest.sessionID, first.jobID == manifest.jobID,
        replay.executionMode == manifest.executionMode,
        first.payload.string("executionAuthority") == executionAuthority,
        first.payload.string("coreBaseline") == coreSpecBaseline
      else {
        throw failure(
          "journal Session/Job/executionMode/executionAuthority/coreBaseline does not match Manifest"
        )
      }
    }
    if let authorization = manifest.authorization {
      guard replay.authorizationReference == authorization.authorizationReference,
        replay.usageReservationID == authorization.usageReservationID
      else { throw failure("Manifest authorization does not match journal jobCreated") }
    } else {
      guard replay.authorizationReference == nil, replay.usageReservationID == nil else {
        throw failure("journal authorization has no Manifest authorization")
      }
    }

    for event in replay.events {
      guard event.sessionID == manifest.sessionID, event.jobID == manifest.jobID else {
        throw failure("journal event identity does not match Manifest: \(event.eventID)")
      }
      switch event.kind {
      case .stepIntent:
        guard let stepID = event.stepID, let step = stepsByID[stepID] else {
          throw failure("journal Step intent does not correlate to Manifest: \(event.eventID)")
        }
        let argumentsHash = try step.manifestString("argumentsHash")
        let bindingRevision = try step.manifestNullableInteger("bindingRevision").map(Int.init)
        guard event.argumentsHash == argumentsHash,
          event.bindingRevision == bindingRevision,
          event.payload["step"] == (try workflowStepDeclaration(from: step))
        else {
          throw failure(
            "journal Step intent declaration does not correlate to Manifest: \(event.eventID)")
        }
        latestStepAttempts[stepID] = ExecutionAttempt(
          intent: event, outcome: outcomesByIntentID[event.eventID])
      case .stepOutcome:
        guard let stepID = event.stepID, stepsByID[stepID] != nil else {
          throw failure("journal Step outcome does not correlate to Manifest: \(event.eventID)")
        }
      case .compensationIntent:
        guard let descriptorID = event.stepID,
          let reference = compensationsByID[descriptorID],
          event.payload.string("compensationOfStepId") == reference.sourceStepID,
          event.payload["descriptor"] == reference.descriptor,
          reference.journalEventIDs.contains(event.eventID)
        else {
          throw failure(
            "journal compensation intent does not correlate to Manifest: \(event.eventID)")
        }
        latestCompensationAttempts[descriptorID] = ExecutionAttempt(
          intent: event, outcome: outcomesByIntentID[event.eventID])
      case .compensationOutcome:
        guard let descriptorID = event.stepID,
          let reference = compensationsByID[descriptorID],
          event.payload.string("descriptorId") == descriptorID,
          event.payload.string("compensationOfStepId") == reference.sourceStepID,
          reference.journalEventIDs.contains(event.eventID)
        else {
          throw failure(
            "journal compensation outcome does not correlate to Manifest: \(event.eventID)")
        }
      case .bindingConfirmed:
        guard let revision = event.bindingRevision,
          let manifestBinding = bindingsByRevision[revision],
          event.payload["binding"] == manifestBinding
        else {
          throw failure(
            "journal confirmed binding does not match Manifest: \(event.eventID)")
        }
      case .reconcileOutcome:
        if let revision = event.bindingRevision, !bindingRevisions.contains(revision) {
          throw failure(
            "journal binding revision does not exist in Manifest: \(event.eventID)")
        }
      default:
        break
      }
    }
    for (descriptorID, reference) in compensationsByID {
      for eventID in reference.journalEventIDs {
        guard let event = eventsByID[eventID],
          event.kind == .compensationIntent || event.kind == .compensationOutcome,
          event.stepID == descriptorID,
          event.payload.string("compensationOfStepId") == reference.sourceStepID
        else {
          throw failure("ghost or mismatched compensation journalEventId: \(eventID)")
        }
      }
    }
    if let authorization = manifest.authorization {
      let destructiveIntents = replay.events.filter {
        $0.kind == .stepIntent && $0.stepEffect == .destructive
      }
      let durableIDs = destructiveIntents.map(\.eventID)
      guard Set(durableIDs).count == durableIDs.count,
        Set(durableIDs) == Set(authorization.destructiveIntentEventIDs)
      else {
        throw failure(
          "Manifest destructiveIntentEventIds contain ghost, duplicate, or missing journal refs")
      }
      for event in destructiveIntents {
        guard let stepID = event.stepID, let step = stepsByID[stepID],
          ["executed", "outcomeUnknown"].contains(try step.manifestString("disposition"))
        else {
          throw failure(
            "authorized destructive intent does not map to an executed Manifest Step")
        }
      }
    }
    if outcomeCertainty == JournalOutcomeCertainty.confirmed.rawValue {
      guard !replay.requiresUnknownFinalizedOutcome else {
        throw failure("durable abandonment requires an outcomeUnknown Manifest")
      }
      guard replay.outstandingIntents.isEmpty, replay.unknownOutcomes.isEmpty,
        replay.lastReconcileOutcomeCertainty != .outcomeUnknown
      else {
        throw failure(
          "confirmed Manifest cannot resolve durable outcomeUnknown without per-outcome proof")
      }
    }

    for (stepID, step) in stepsByID {
      if let attempt = latestStepAttempts[stepID] {
        try validateDurableAttempt(
          attempt, manifestRecord: step, resultKey: "semanticResult", context: "Step \(stepID)")
      } else if try executionRecordRequiresDurableBacking(step) {
        throw failure("Manifest Step \(stepID) lacks a durable journal execution attempt")
      }
    }
    for (descriptorID, compensation) in compensationsByID {
      if let attempt = latestCompensationAttempts[descriptorID] {
        try validateDurableAttempt(
          attempt, manifestRecord: compensation.record, resultKey: "result",
          context: "compensation \(descriptorID)")
      } else if try executionRecordRequiresDurableBacking(compensation.record) {
        throw failure(
          "Manifest compensation \(descriptorID) lacks a durable journal execution attempt")
      }
    }

    guard !replay.events.isEmpty else { return }
    guard replay.currentState?.isTerminal == true else {
      throw failure("non-empty journal is not terminal")
    }
    guard replay.finalized, let finalized = replay.events.last, finalized.kind == .finalized else {
      throw failure("terminal journal is missing finalized record")
    }
    guard finalized.payload.string("manifestSha256") == manifest.sha256,
      finalized.payload.string("terminalStatus") == manifest.status
    else { throw failure("journal finalized record does not match Manifest") }
    let durableCertainty = finalized.payload.string("outcomeCertainty")
    guard
      (outcomeCertainty == "mixed" && durableCertainty == "outcomeUnknown")
        || durableCertainty == outcomeCertainty
    else { throw failure("journal finalized certainty does not match Manifest") }
  }

  private static func validateDurableAttempt(
    _ attempt: ExecutionAttempt,
    manifestRecord: [String: JSONValue],
    resultKey: String,
    context: String
  ) throws {
    let journalResult = attempt.outcome?.payload.string("result")
    let journalCertainty = attempt.outcome?.payload.string("outcomeCertainty")
    if attempt.outcome != nil, journalResult == nil || journalCertainty == nil {
      throw failure("journal \(context) outcome is incomplete")
    }
    let expectedDisposition: String
    let expectedCertainty: String
    let expectedResult: String
    if journalCertainty == JournalOutcomeCertainty.confirmed.rawValue {
      expectedDisposition = "executed"
      expectedCertainty = "confirmed"
      expectedResult = journalResult == "succeeded" ? "succeeded" : "failed"
    } else {
      expectedDisposition = "outcomeUnknown"
      expectedCertainty = "outcomeUnknown"
      expectedResult = "unknown"
    }
    guard try manifestRecord.manifestString("disposition") == expectedDisposition,
      try manifestRecord.manifestString("outcomeCertainty") == expectedCertainty,
      try manifestRecord.manifestString(resultKey) == expectedResult
    else {
      throw failure("journal \(context) outcome does not match Manifest execution tuple")
    }
  }

  private static func executionRecordRequiresDurableBacking(
    _ record: [String: JSONValue]
  ) throws -> Bool {
    let disposition = try record.manifestString("disposition")
    return disposition == "executed" || disposition == "outcomeUnknown"
  }

  private static func workflowStepDeclaration(
    from manifestRecord: [String: JSONValue]
  ) throws -> JSONValue {
    let keys = [
      "id", "kind", "effect", "cancellation", "bindingRequirement", "arguments",
      "compensationDescriptors",
    ]
    var declaration: [String: JSONValue] = [:]
    for key in keys {
      guard let value = manifestRecord[key] else {
        throw failure("Manifest Step is missing immutable declaration field: \(key)")
      }
      declaration[key] = value
    }
    return .object(declaration)
  }

  private static func failure(_ message: String) -> SessionStorageError {
    .invalidManifest(message)
  }

}

private func sameManifestJournalSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
  lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
    && lhs.st_size == rhs.st_size && lhs.st_uid == rhs.st_uid && lhs.st_nlink == rhs.st_nlink
    && lhs.st_mode == rhs.st_mode
    && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
    && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
    && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private enum LockedSessionManifestValidator {
  private static let rockchipProfileIdentifier = "ROCKCHIP-ROCKUSB-DISCOVERY@1.0.0"
  private static let rockchipReportedVersion = "rkdeveloptool ver 1.32"
  private static let rockchipExecutableSHA256 =
    "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"
  private static let rockchipPathSource = "userSelectedSecurityScopedBookmark"

  private static let topLevelKeys: Set<String> = [
    "schemaVersion", "appVersion", "coreSpecBaseline", "platformProfile", "sessionId",
    "jobId", "status", "executionMode", "executionAuthority", "outcomeCertainty",
    "sessionDisposition", "createdAt", "completedAt", "archivedAt", "originalTarget",
    "bindingHistory", "toolchain", "workflow", "steps", "parameters", "compensations",
    "confirmations", "artifacts", "warnings", "failure", "recovery",
  ]

  static func validate(_ object: [String: JSONValue]) throws {
    let schemaVersion = try object.manifestString("schemaVersion")
    guard ["1.0.0", "2.0.0", "2.1.0"].contains(schemaVersion) else {
      throw failure("unsupported schemaVersion")
    }
    if schemaVersion == "1.0.0" {
      try object.manifestRequireKeys(topLevelKeys)
    } else {
      try object.manifestRequireKeys(topLevelKeys.union(["authorization"]))
    }
    for key in ["appVersion", "platformProfile"] {
      guard !(try object.manifestString(key)).isEmpty else { throw failure("empty \(key)") }
    }
    let baseline = try object.manifestString("coreSpecBaseline")
    guard
      baseline.range(of: #"^CORE-[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression)
        == baseline.startIndex..<baseline.endIndex
    else { throw failure("invalid coreSpecBaseline") }
    try id(object, "sessionId")
    try id(object, "jobId")
    let status = try enumValue(
      object, "status", ["planned", "succeeded", "failed", "cancelled", "interrupted"])
    let mode = try enumValue(object, "executionMode", ["execute", "planOnly", "simulated"])
    let authorities =
      schemaVersion == "2.0.0" || schemaVersion == "2.1.0"
      ? ["interactiveUser", "standardAgent", "controlledHardwareLab", "authorizedAgent"]
      : ["interactiveUser", "standardAgent", "controlledHardwareLab"]
    let authority = try enumValue(object, "executionAuthority", authorities)
    let authorization = try validateAuthorization(
      object["authorization"], schemaVersion: schemaVersion, authority: authority)
    let certainty = try enumValue(
      object, "outcomeCertainty", ["confirmed", "outcomeUnknown", "mixed"])
    let disposition = try enumValue(object, "sessionDisposition", ["finalized", "archived"])
    try timestamp(object, "createdAt")
    try timestamp(object, "completedAt")
    if disposition == "archived" {
      try timestamp(object, "archivedAt")
    } else if !object.manifestIsNull("archivedAt") {
      throw failure("finalized manifest archivedAt must be null")
    }

    let target = try object.manifestObject("originalTarget")
    try validateTarget(target, simulated: mode == "simulated")
    let bindings = try object.manifestArray("bindingHistory")
    guard !bindings.isEmpty else { throw failure("bindingHistory must not be empty") }
    for value in bindings {
      guard case .object(let binding) = value else { throw failure("binding must be object") }
      try validateBinding(binding, simulated: mode == "simulated")
    }
    try validateToolchain(
      try object.manifestObject("toolchain"), schemaVersion: schemaVersion,
      simulated: mode == "simulated")
    try validateWorkflow(try object.manifestObject("workflow"), simulated: mode == "simulated")

    let steps = try object.manifestArray("steps")
    try steps.forEach(validateStep)
    let parameters = try object.manifestArray("parameters")
    try parameters.forEach(validateParameter)
    let compensations = try object.manifestArray("compensations")
    try compensations.forEach(validateCompensation)
    let confirmations = try object.manifestArray("confirmations")
    for confirmation in confirmations {
      try validateConfirmation(
        confirmation, schemaVersion: schemaVersion, authority: authority,
        authorizationReference: authorization?.authorizationReference)
    }
    let artifacts = try object.manifestArray("artifacts")
    try artifacts.forEach(validateArtifact)
    guard
      try object.manifestArray("warnings").allSatisfy({ value in
        guard case .string(let string) = value else { return false }
        return !string.isEmpty
      })
    else { throw failure("warnings must contain nonempty strings") }

    try validateFailure(object["failure"]!)
    try validateRecovery(object["recovery"]!)
    try validateRelationships(
      bindings: bindings, steps: steps, parameters: parameters,
      compensations: compensations, confirmations: confirmations,
      artifacts: artifacts, recovery: object["recovery"]!)
    try validateConditionals(
      object: object, status: status, mode: mode, authority: authority, certainty: certainty,
      steps: steps, parameters: parameters, compensations: compensations)
    if schemaVersion != "1.0.0", mode == "simulated" {
      for value in steps {
        guard case .object(let step) = value,
          try step.manifestString("effect") == "destructive"
        else { continue }
        guard
          ["notExecuted(planned)", "skipped"].contains(
            try step.manifestString("disposition")),
          try step.manifestString("outcomeCertainty") == "notApplicable",
          try step.manifestString("semanticResult") == "notRun"
        else { throw failure("v2 simulated destructive step executed") }
      }
    }
    if let authorization {
      let authorizedDestructiveSteps = try steps.filter { value in
        guard case .object(let step) = value,
          try step.manifestString("effect") == "destructive"
        else { return false }
        return ["executed", "outcomeUnknown"].contains(
          try step.manifestString("disposition"))
      }
      guard authorization.destructiveIntentEventIDs.count == authorizedDestructiveSteps.count else {
        throw failure(
          "authorized destructive Steps must map one-to-one to destructiveIntentEventIds")
      }
    }
  }

  private static func validateAuthorization(
    _ value: JSONValue?,
    schemaVersion: String,
    authority: String
  ) throws -> SessionManifestAuthorization? {
    if schemaVersion == "1.0.0" { return nil }
    if authority != "authorizedAgent" {
      guard value == .null else {
        throw failure("non-authorized authority must use null authorization")
      }
      return nil
    }
    guard case .object(let object)? = value else {
      throw failure("authorizedAgent requires authorization object")
    }
    return try SessionManifestAuthorization(object: object)
  }

  private static func validateTarget(_ object: [String: JSONValue], simulated: Bool) throws {
    try object.manifestRequireKeys(["kind", "connectKey", "transport", "identitySnapshot"])
    let kind = try enumValue(object, "kind", ["real", "synthetic"])
    let transport = try enumValue(object, "transport", ["usb", "tcp", "uart", "synthetic"])
    let connectKey = try object.manifestNullableString("connectKey")
    guard !(try object.manifestObject("identitySnapshot")).isEmpty else {
      throw failure("identitySnapshot must not be empty")
    }
    if simulated {
      guard kind == "synthetic", transport == "synthetic", connectKey == nil else {
        throw failure("simulated target must be synthetic")
      }
    } else {
      guard kind == "real", ["usb", "tcp", "uart"].contains(transport),
        connectKey?.isEmpty == false
      else { throw failure("non-simulated target must be real and addressable") }
    }
  }

  private static func validateBinding(_ object: [String: JSONValue], simulated: Bool) throws {
    try object.manifestRequireKeys([
      "revision", "connectKey", "transport", "identitySnapshot", "evidence", "confirmedBy",
      "channelProtection",
    ])
    guard try object.manifestInteger("revision") >= 1,
      !(try object.manifestObject("identitySnapshot")).isEmpty
    else { throw failure("invalid binding revision/identity") }
    let connectKey = try object.manifestNullableString("connectKey")
    let transport = try enumValue(object, "transport", ["usb", "tcp", "uart", "synthetic"])
    let evidence = try object.manifestStringArray("evidence")
    guard !evidence.isEmpty, evidence.allSatisfy({ !$0.isEmpty }) else {
      throw failure("binding evidence must not be empty")
    }
    let confirmedBy = try enumValue(object, "confirmedBy", ["corePolicy", "user", "simulation"])
    let protection = try enumValue(
      object, "channelProtection",
      ["encryptedVerified", "unverifiedAssumeUnprotected", "notApplicable"])
    if simulated {
      guard connectKey == nil, transport == "synthetic", confirmedBy == "simulation",
        protection == "notApplicable"
      else { throw failure("simulated binding is invalid") }
    } else {
      guard connectKey?.isEmpty == false, ["usb", "tcp", "uart"].contains(transport),
        ["corePolicy", "user"].contains(confirmedBy), protection != "notApplicable"
      else { throw failure("real binding is invalid") }
    }
  }

  private static func validateToolchain(
    _ object: [String: JSONValue], schemaVersion: String, simulated: Bool
  ) throws {
    if object["kind"] == .string("rockchip") {
      guard schemaVersion == "2.1.0", !simulated else {
        throw failure("rockchip toolchain requires non-simulated schemaVersion 2.1.0")
      }
      try object.manifestRequireKeys([
        "kind", "profileIdentifier", "reportedVersion", "sha256", "pathSource",
        "descriptorIdentity",
      ])
      guard try object.manifestString("profileIdentifier") == rockchipProfileIdentifier,
        try object.manifestString("reportedVersion") == rockchipReportedVersion,
        try object.manifestString("sha256") == rockchipExecutableSHA256,
        try object.manifestString("pathSource") == rockchipPathSource
      else { throw failure("rockchip toolchain does not match the pinned integration profile") }
      let identity = try object.manifestObject("descriptorIdentity")
      try identity.manifestRequireKeys(["device", "inode", "fileSize", "mode"])
      guard try identity.manifestUnsignedInteger("device") > 0,
        try identity.manifestUnsignedInteger("inode") > 0,
        try identity.manifestInteger("fileSize") > 0,
        let mode = UInt32(exactly: try identity.manifestUnsignedInteger("mode")), mode > 0
      else { throw failure("rockchip descriptor identity contains a non-positive field") }
      return
    }
    let allowed: Set<String> = [
      "kind", "source", "path", "sha256", "clientVersion", "serverVersion", "daemonVersion",
      "endpoint", "serverGeneration", "serverOwnership",
    ]
    guard Set(object.keys).isSubset(of: allowed), object["kind"] != nil else {
      throw failure("unknown or missing toolchain field")
    }
    let kind = try enumValue(object, "kind", ["hdc", "none"])
    if kind == "none" {
      guard object.keys.count == 1, simulated else {
        throw failure("toolchain none is simulated-only")
      }
      return
    }
    let required: Set<String> = [
      "kind", "source", "path", "sha256", "clientVersion", "serverVersion", "endpoint",
      "serverGeneration", "serverOwnership",
    ]
    guard required.isSubset(of: Set(object.keys)), !simulated else {
      throw failure("hdc toolchain shape/mode mismatch")
    }
    for key in ["source", "path", "clientVersion", "serverVersion", "endpoint"] {
      guard !(try object.manifestString(key)).isEmpty else {
        throw failure("empty toolchain \(key)")
      }
    }
    try SessionStorageValidation.sha256(
      try object.manifestString("sha256"), field: "toolchain.sha256")
    guard try object.manifestInteger("serverGeneration") >= 0 else {
      throw failure("negative serverGeneration")
    }
    _ = try enumValue(object, "serverOwnership", ["external", "arkDeckManaged", "unknown"])
    if object["daemonVersion"] != nil { _ = try object.manifestNullableString("daemonVersion") }
  }

  private static func validateWorkflow(_ object: [String: JSONValue], simulated: Bool) throws {
    try object.manifestRequireKeys(
      ["kind", "profileVersion", "providerIdentity"],
      optional: ["fixtureIdentity", "scenarioIdentity"])
    for key in ["kind", "profileVersion", "providerIdentity"] {
      guard !(try object.manifestString(key)).isEmpty else {
        throw failure("empty workflow \(key)")
      }
    }
    let fixture = try object.manifestOptionalNullableString("fixtureIdentity")
    let scenario = try object.manifestOptionalNullableString("scenarioIdentity")
    if simulated {
      guard fixture?.isEmpty == false, scenario?.isEmpty == false else {
        throw failure("simulated workflow requires fixture/scenario identity")
      }
    }
  }

  private static func validateStep(_ value: JSONValue) throws {
    guard case .object(let object) = value else { throw failure("step must be object") }
    let required: Set<String> = [
      "id", "kind", "effect", "cancellation", "bindingRequirement", "arguments",
      "argumentsHash", "compensationDescriptors", "sourceStepId", "compensationTrigger",
      "disposition", "outcomeCertainty", "bindingRevision", "semanticResult",
    ]
    try object.manifestRequireKeys(required, optional: ["exitCode", "durationNanoseconds"])
    let workflowObject = Dictionary(
      uniqueKeysWithValues: [
        "id", "kind", "effect", "cancellation", "bindingRequirement", "arguments",
        "compensationDescriptors",
      ].map { ($0, object[$0]!) })
    let decoded = try JSONDecoder().decode(
      WorkflowStep.self,
      from: SessionStorageValidation.canonicalData(JSONValue.object(workflowObject)))
    try validateDeclaredPolicy(
      object, effect: decoded.effect, cancellation: decoded.cancellation,
      bindingRequirement: decoded.bindingRequirement, context: "step")
    let rawDescriptors = try object.manifestArray("compensationDescriptors")
    guard rawDescriptors.count == decoded.compensationDescriptors.count else {
      throw failure("compensation descriptor count mismatch")
    }
    for (rawValue, descriptor) in zip(rawDescriptors, decoded.compensationDescriptors) {
      guard case .object(let rawDescriptor) = rawValue else {
        throw failure("compensation descriptor must be object")
      }
      try validateDeclaredPolicy(
        rawDescriptor, effect: descriptor.effect, cancellation: descriptor.cancellation,
        bindingRequirement: descriptor.bindingRequirement, context: "compensation descriptor")
      try validateCompensationDescriptorHash(rawDescriptor)
    }
    let arguments = try object.manifestObject("arguments")
    let expectedHash = SessionStorageValidation.lowercaseSHA256(
      try SessionStorageValidation.canonicalData(JSONValue.object(arguments)))
    guard (try object.manifestString("argumentsHash")).lowercased() == expectedHash else {
      throw failure("step argumentsHash mismatch")
    }
    let binding = try object.manifestString("bindingRequirement")
    let revision = try object.manifestNullableInteger("bindingRevision")
    guard binding == "none" ? revision == nil : (binding == "confirmedDevice" && revision ?? 0 >= 1)
    else { throw failure("step binding revision mismatch") }
    let source = try object.manifestNullableString("sourceStepId")
    let trigger = try object.manifestNullableString("compensationTrigger")
    guard source == nil ? trigger == nil : trigger != nil else {
      throw failure("step compensation linkage mismatch")
    }
    if let source {
      try SessionStorageValidation.identifier(source, field: "sourceStepId")
      guard let trigger,
        ["onSuccess", "onFailure", "onCancel", "onAnyTerminal"].contains(trigger)
      else { throw failure("invalid compensationTrigger") }
    }
    let disposition = try enumValue(
      object, "disposition", ["executed", "notExecuted(planned)", "skipped", "outcomeUnknown"])
    let certainty = try enumValue(
      object, "outcomeCertainty", ["confirmed", "outcomeUnknown", "notApplicable"])
    let result = try enumValue(
      object, "semanticResult", ["succeeded", "failed", "notRun", "unknown"])
    switch disposition {
    case "executed" where certainty != "confirmed" || !["succeeded", "failed"].contains(result):
      throw failure("executed step result mismatch")
    case "outcomeUnknown" where certainty != "outcomeUnknown" || result != "unknown":
      throw failure("unknown step result mismatch")
    case "notExecuted(planned)" where certainty != "notApplicable" || result != "notRun":
      throw failure("not-run step result mismatch")
    case "skipped" where certainty != "notApplicable" || result != "notRun":
      throw failure("not-run step result mismatch")
    default:
      break
    }
    if let duration = try object.manifestOptionalNullableInteger("durationNanoseconds"),
      duration < 0
    {
      throw failure("negative step duration")
    }
    _ = try object.manifestOptionalNullableInteger("exitCode")
  }

  private static func validateParameter(_ value: JSONValue) throws {
    guard case .object(let object) = value else { throw failure("parameter must be object") }
    try object.manifestRequireKeys([
      "name", "beforeState", "desiredState", "afterState", "restoreState", "restoreDisposition",
    ])
    let name = try object.manifestString("name")
    guard
      name.range(of: #"^[A-Za-z0-9_.-]{1,255}$"#, options: .regularExpression)
        == name.startIndex..<name.endIndex
    else { throw failure("invalid parameter name") }
    let before = try validateParameterState(object["beforeState"]!)
    let desired = try validateParameterState(object["desiredState"]!)
    _ = try validateParameterState(object["afterState"]!)
    let restore = try validateParameterState(object["restoreState"]!)
    guard desired == "value" else { throw failure("desired parameter state must be value") }
    let disposition = try enumValue(
      object, "restoreDisposition",
      ["notRequired", "restored", "persistentChangeAccepted", "failed", "outcomeUnknown"])
    if disposition == "restored", before != "value" || restore != "value" {
      throw failure("restored parameter must have value snapshots")
    }
    if disposition == "restored" {
      let beforeValue = try object.manifestObject("beforeState").manifestString("value")
      let restoreValue = try object.manifestObject("restoreState").manifestString("value")
      guard Data(beforeValue.utf8) == Data(restoreValue.utf8) else {
        throw failure("restored parameter value differs from captured original")
      }
    }
    if ["missing", "unreadable"].contains(before), disposition == "restored" {
      throw failure("unreadable parameter cannot be restored")
    }
  }

  private static func validateParameterState(_ value: JSONValue) throws -> String {
    guard case .object(let object) = value else { throw failure("parameter state must be object") }
    let state = try object.manifestString("state")
    switch state {
    case "missing":
      try object.manifestRequireKeys(["state"])
    case "unreadable":
      try object.manifestRequireKeys(["state", "reason"])
      guard !(try object.manifestString("reason")).isEmpty else {
        throw failure("empty unreadable reason")
      }
    case "value":
      try object.manifestRequireKeys(["state", "value"])
      guard (try object.manifestString("value")).count <= 4_096 else {
        throw failure("parameter value too long")
      }
    default:
      throw failure("unknown parameter state")
    }
    return state
  }

  private static func validateCompensation(_ value: JSONValue) throws {
    guard case .object(let object) = value else { throw failure("compensation must be object") }
    try object.manifestRequireKeys([
      "descriptor", "sourceStepId", "disposition", "outcomeCertainty", "result", "failure",
      "journalEventIds",
    ])
    let descriptor = try JSONDecoder().decode(
      CompensationDescriptor.self,
      from: SessionStorageValidation.canonicalData(object["descriptor"]!))
    guard case .object(let rawDescriptor)? = object["descriptor"] else {
      throw failure("compensation descriptor must be object")
    }
    try validateDeclaredPolicy(
      rawDescriptor, effect: descriptor.effect, cancellation: descriptor.cancellation,
      bindingRequirement: descriptor.bindingRequirement, context: "compensation descriptor")
    try validateCompensationDescriptorHash(rawDescriptor)
    try id(object, "sourceStepId")
    let eventIDs = try object.manifestStringArray("journalEventIds")
    for eventID in eventIDs {
      try SessionStorageValidation.identifier(eventID, field: "journalEventIds")
    }
    let disposition = try enumValue(
      object, "disposition", ["executed", "notRun", "outcomeUnknown"])
    let certainty = try enumValue(
      object, "outcomeCertainty", ["confirmed", "outcomeUnknown", "notApplicable"])
    let result = try enumValue(object, "result", ["succeeded", "failed", "notRun", "unknown"])
    try validateFailure(object["failure"]!)
    switch disposition {
    case "executed":
      guard certainty == "confirmed", ["succeeded", "failed"].contains(result) else {
        throw failure("executed compensation tuple mismatch")
      }
      guard
        (result == "succeeded" && object["failure"]!.manifestIsNull)
          || (result == "failed" && !object["failure"]!.manifestIsNull)
      else { throw failure("executed compensation failure tuple mismatch") }
    case "notRun":
      guard certainty == "notApplicable", result == "notRun",
        object["failure"]!.manifestIsNull
      else { throw failure("not-run compensation tuple mismatch") }
    case "outcomeUnknown":
      guard certainty == "outcomeUnknown", result == "unknown" else {
        throw failure("unknown compensation tuple mismatch")
      }
    default:
      throw failure("unknown compensation disposition")
    }
  }

  private static func validateConfirmation(
    _ value: JSONValue,
    schemaVersion: String,
    authority: String,
    authorizationReference: AuthorizationReference?
  ) throws {
    guard case .object(let object) = value else { throw failure("confirmation must be object") }
    try object.manifestRequireKeys([
      "confirmationId", "kind", "scopeHash", "decision", "actor", "decidedAt", "relatedStepIds",
    ])
    try id(object, "confirmationId")
    _ = try enumValue(
      object, "kind",
      ["deviceMutation", "destructive", "serverLifecycle", "recoveryAbandon", "securityBoundary"])
    try SessionStorageValidation.sha256(try object.manifestString("scopeHash"), field: "scopeHash")
    _ = try enumValue(object, "decision", ["accepted", "rejected"])
    if schemaVersion == "1.0.0" {
      guard try object.manifestString("actor") == "user" else {
        throw failure("confirmation actor")
      }
    } else {
      guard case .object(let actor)? = object["actor"],
        case .string(let kind)? = actor["kind"]
      else { throw failure("confirmation actor must be a closed object") }
      switch kind {
      case "interactiveUser":
        try actor.manifestRequireKeys(["kind"])
      case "authorizedAgent":
        try actor.manifestRequireKeys(["kind", "authorizationRef"])
        let actorReference: AuthorizationReference
        do {
          actorReference = try AuthorizationReference(
            jsonValue: actor["authorizationRef"]!,
            context: "confirmation.actor.authorizationRef")
        } catch {
          throw failure("confirmation actor authorizationRef is malformed")
        }
        guard authority == "authorizedAgent", let authorizationReference,
          actorReference == authorizationReference
        else { throw failure("confirmation actor authorizationRef drifted") }
      default:
        throw failure("unknown confirmation actor kind")
      }
    }
    try timestamp(object, "decidedAt")
    for stepID in try object.manifestStringArray("relatedStepIds") {
      try SessionStorageValidation.identifier(stepID, field: "relatedStepIds")
    }
  }

  private static func validateArtifact(_ value: JSONValue) throws {
    guard case .object(let object) = value else { throw failure("artifact must be object") }
    try object.manifestRequireKeys(
      ["id", "role", "origin", "relativePath", "size", "sha256"],
      optional: ["mediaType", "derivedFrom"])
    try id(object, "id")
    let role = try enumValue(object, "role", ArtifactRole.allCases.map(\.rawValue))
    guard !(try object.manifestString("origin")).isEmpty else {
      throw failure("empty artifact origin")
    }
    try SessionStorageValidation.relativePath(try object.manifestString("relativePath"))
    guard try object.manifestInteger("size") >= 0 else { throw failure("negative artifact size") }
    try SessionStorageValidation.sha256(
      try object.manifestString("sha256"), field: "artifact.sha256")
    _ = try object.manifestOptionalNullableString("mediaType")
    if object["derivedFrom"] != nil {
      let lineage = try object.manifestStringArray("derivedFrom")
      guard Set(lineage).count == lineage.count else { throw failure("duplicate artifact lineage") }
      for sourceID in lineage {
        try SessionStorageValidation.identifier(sourceID, field: "derivedFrom")
      }
      guard role == "derived", !lineage.isEmpty else {
        throw failure("only derived Artifact may declare non-empty lineage")
      }
      let provenance = try decodedDerivedProvenance(
        try object.manifestString("origin"), artifactID: try object.manifestString("id"))
      guard provenance.inputHashes.count == lineage.count else {
        throw failure("derived Artifact provenance does not match lineage")
      }
    } else if role == "derived" {
      throw failure("derived Artifact requires lineage")
    }
  }

  private static func validateFailure(_ value: JSONValue) throws {
    if value.manifestIsNull { return }
    guard case .object(let object) = value else { throw failure("failure must be object or null") }
    try object.manifestRequireKeys(["stage", "code", "summary"])
    guard !(try object.manifestString("stage")).isEmpty,
      !(try object.manifestString("summary")).isEmpty
    else { throw failure("empty failure field") }
    try id(object, "code")
  }

  private static func validateRecovery(_ value: JSONValue) throws {
    if value.manifestIsNull { return }
    guard case .object(let recovery) = value else {
      throw failure("recovery must be object or null")
    }
    for descriptorValue in try recovery.manifestArray("unexecutedCompensations") {
      guard case .object(let descriptor) = descriptorValue else {
        throw failure("recovery compensation descriptor must be object")
      }
      try validateCompensationDescriptorHash(descriptor)
    }
    _ = try RecoveryManifestCodec.decode(try SessionStorageValidation.canonicalData(value))
  }

  private static func validateRelationships(
    bindings: [JSONValue],
    steps: [JSONValue],
    parameters _: [JSONValue],
    compensations: [JSONValue],
    confirmations: [JSONValue],
    artifacts: [JSONValue],
    recovery: JSONValue
  ) throws {
    var previousRevision: Int64?
    var bindingRevisions = Set<Int64>()
    for bindingValue in bindings {
      guard case .object(let binding) = bindingValue else { continue }
      let revision = try binding.manifestInteger("revision")
      guard previousRevision.map({ revision > $0 }) ?? true else {
        throw failure("binding revisions must be strictly increasing")
      }
      previousRevision = revision
      bindingRevisions.insert(revision)
    }

    var stepsByID: [String: [String: JSONValue]] = [:]
    var declaredCompensations: [String: (sourceStepID: String, value: JSONValue)] = [:]
    for stepValue in steps {
      guard case .object(let step) = stepValue else { continue }
      let stepID = try step.manifestString("id")
      guard stepsByID.updateValue(step, forKey: stepID) == nil else {
        throw failure("duplicate Step ID: \(stepID)")
      }
      if let revision = try step.manifestNullableInteger("bindingRevision"),
        !bindingRevisions.contains(revision)
      {
        throw failure("Step bindingRevision does not exist: \(revision)")
      }
      for descriptorValue in try step.manifestArray("compensationDescriptors") {
        guard case .object(let descriptor) = descriptorValue else { continue }
        let descriptorID = try descriptor.manifestString("id")
        guard
          declaredCompensations.updateValue(
            (sourceStepID: stepID, value: descriptorValue), forKey: descriptorID) == nil
        else {
          throw failure("duplicate compensation ID: \(descriptorID)")
        }
      }
    }

    for stepValue in steps {
      guard case .object(let step) = stepValue,
        let sourceStepID = try step.manifestNullableString("sourceStepId")
      else { continue }
      guard stepsByID[sourceStepID] != nil else {
        throw failure("compensation Step source does not exist: \(sourceStepID)")
      }
      let stepID = try step.manifestString("id")
      guard let declared = declaredCompensations[stepID],
        declared.sourceStepID == sourceStepID,
        try compensationExecution(step, matches: declared.value)
      else {
        throw failure("compensation Step is not declared by its source Step: \(stepID)")
      }
    }

    var compensationRecordIDs = Set<String>()
    for compensationValue in compensations {
      guard case .object(let compensation) = compensationValue,
        case .object(let descriptor)? = compensation["descriptor"]
      else { continue }
      let descriptorID = try descriptor.manifestString("id")
      guard compensationRecordIDs.insert(descriptorID).inserted else {
        throw failure("duplicate compensation record ID: \(descriptorID)")
      }
      let sourceStepID = try compensation.manifestString("sourceStepId")
      guard stepsByID[sourceStepID] != nil,
        let declared = declaredCompensations[descriptorID],
        declared.sourceStepID == sourceStepID,
        declared.value == compensation["descriptor"]!
      else {
        throw failure("compensation record is not declared by its source Step: \(descriptorID)")
      }
    }

    var confirmationsByID: [String: Set<String>] = [:]
    for confirmationValue in confirmations {
      guard case .object(let confirmation) = confirmationValue else { continue }
      let confirmationID = try confirmation.manifestString("confirmationId")
      let relatedStepIDs = try confirmation.manifestStringArray("relatedStepIds")
      guard
        confirmationsByID.updateValue(Set(relatedStepIDs), forKey: confirmationID) == nil
      else {
        throw failure("duplicate confirmation ID: \(confirmationID)")
      }
      for stepID in relatedStepIDs where stepsByID[stepID] == nil {
        throw failure("confirmation references unknown Step: \(stepID)")
      }
    }
    for (stepID, step) in stepsByID {
      let arguments = try step.manifestObject("arguments")
      guard let value = arguments["confirmationId"], !value.manifestIsNull else { continue }
      guard case .string(let confirmationID) = value,
        let relatedStepIDs = confirmationsByID[confirmationID],
        relatedStepIDs.contains(stepID)
      else {
        throw failure("Step confirmationId does not resolve to the same Step: \(stepID)")
      }
    }

    var artifactsByID: [String: [String: JSONValue]] = [:]
    for artifactValue in artifacts {
      guard case .object(let artifact) = artifactValue else { continue }
      let artifactID = try artifact.manifestString("id")
      guard artifactsByID.updateValue(artifact, forKey: artifactID) == nil else {
        throw failure("duplicate Artifact ID: \(artifactID)")
      }
    }
    for (artifactID, artifact) in artifactsByID where artifact["derivedFrom"] != nil {
      let lineage = try artifact.manifestStringArray("derivedFrom")
      let provenance = try decodedDerivedProvenance(
        try artifact.manifestString("origin"), artifactID: artifactID)
      guard provenance.inputHashes.count == lineage.count else {
        throw failure("derived Artifact provenance does not match lineage: \(artifactID)")
      }
      for (sourceID, sourceHash) in zip(lineage, provenance.inputHashes) {
        guard let source = artifactsByID[sourceID] else {
          throw failure("Artifact derivedFrom references unknown Artifact: \(sourceID)")
        }
        guard (try source.manifestString("sha256")).lowercased() == sourceHash else {
          throw failure(
            "derived Artifact provenance hash does not match source Artifact: \(sourceID)")
        }
      }
    }

    var visitingArtifacts = Set<String>()
    var visitedArtifacts = Set<String>()
    func visitArtifact(_ artifactID: String) throws {
      if visitedArtifacts.contains(artifactID) { return }
      guard visitingArtifacts.insert(artifactID).inserted else {
        throw failure("derived Artifact lineage contains a cycle: \(artifactID)")
      }
      if let artifact = artifactsByID[artifactID], artifact["derivedFrom"] != nil {
        for sourceID in try artifact.manifestStringArray("derivedFrom") {
          try visitArtifact(sourceID)
        }
      }
      visitingArtifacts.remove(artifactID)
      visitedArtifacts.insert(artifactID)
    }
    for artifactID in artifactsByID.keys { try visitArtifact(artifactID) }

    if case .object(let recoveryObject) = recovery,
      let lastConfirmedStepID = try recoveryObject.manifestNullableString("lastConfirmedStepId"),
      stepsByID[lastConfirmedStepID] == nil
    {
      throw failure("recovery references unknown lastConfirmedStepId: \(lastConfirmedStepID)")
    }
    if case .object(let recoveryObject) = recovery {
      for descriptorValue in try recoveryObject.manifestArray("unexecutedCompensations") {
        guard case .object(let descriptor) = descriptorValue else { continue }
        let descriptorID = try descriptor.manifestString("id")
        guard let declared = declaredCompensations[descriptorID],
          declared.value == descriptorValue
        else {
          throw failure(
            "recovery compensation is not declared by a Session Step: \(descriptorID)")
        }
      }
    }
  }

  private static func compensationExecution(
    _ step: [String: JSONValue],
    matches descriptorValue: JSONValue
  ) throws -> Bool {
    guard case .object(let descriptor) = descriptorValue else { return false }
    for key in [
      "id", "kind", "effect", "cancellation", "bindingRequirement", "arguments",
      "argumentsHash",
    ] where step[key] != descriptor[key] {
      return false
    }
    return step["compensationTrigger"] == descriptor["trigger"]
  }

  private static func decodedDerivedProvenance(
    _ origin: String,
    artifactID: String
  ) throws -> DerivedArtifactProvenance {
    do {
      return try DerivedArtifactProvenance(manifestOrigin: origin)
    } catch {
      throw failure("derived Artifact has invalid typed provenance: \(artifactID)")
    }
  }

  private static func validateCompensationDescriptorHash(
    _ descriptor: [String: JSONValue]
  ) throws {
    let arguments = try descriptor.manifestObject("arguments")
    let expected = SessionStorageValidation.lowercaseSHA256(
      try SessionStorageValidation.canonicalData(JSONValue.object(arguments)))
    guard (try descriptor.manifestString("argumentsHash")).lowercased() == expected else {
      throw failure("compensation argumentsHash mismatch")
    }
  }

  private static func validateConditionals(
    object: [String: JSONValue],
    status: String,
    mode: String,
    authority: String,
    certainty: String,
    steps: [JSONValue],
    parameters: [JSONValue],
    compensations: [JSONValue]
  ) throws {
    if mode == "planOnly", status == "succeeded" { throw failure("planOnly cannot succeed") }
    if status == "planned" {
      guard mode == "planOnly", certainty == "confirmed", object["failure"]!.manifestIsNull,
        object["recovery"]!.manifestIsNull
      else { throw failure("planned status mismatch") }
    }
    if status == "succeeded" {
      guard certainty == "confirmed", object["failure"]!.manifestIsNull,
        object["recovery"]!.manifestIsNull
      else { throw failure("succeeded status mismatch") }
    }
    if status == "failed" {
      guard certainty == "confirmed", !object["failure"]!.manifestIsNull else {
        throw failure("failed status mismatch")
      }
    }
    if status == "cancelled" {
      guard certainty == "confirmed", object["failure"]!.manifestIsNull else {
        throw failure("cancelled status mismatch")
      }
    }
    if status == "interrupted" {
      guard case .object(let recovery) = object["recovery"],
        try recovery.manifestBool("needsAttention"),
        (try recovery.manifestNullableString("interruptedReason"))?.isEmpty == false,
        !(try recovery.manifestStringArray("abandonAuditEventIds")).isEmpty,
        !recovery["userConfirmation"]!.manifestIsNull
      else { throw failure("interrupted recovery mismatch") }
    }

    for stepValue in steps {
      guard case .object(let step) = stepValue else { continue }
      let effect = try step.manifestString("effect")
      let disposition = try step.manifestString("disposition")
      let stepCertainty = try step.manifestString("outcomeCertainty")
      let result = try step.manifestString("semanticResult")
      if authority == "standardAgent", effect == "destructive" {
        guard ["notExecuted(planned)", "skipped"].contains(disposition),
          stepCertainty == "notApplicable", result == "notRun"
        else { throw failure("standardAgent destructive step executed") }
      }
      if mode == "planOnly", ["deviceMutation", "destructive"].contains(effect) {
        guard ["notExecuted(planned)", "skipped"].contains(disposition),
          stepCertainty == "notApplicable", result == "notRun"
        else { throw failure("planOnly mutation step executed") }
      }
      if ["planned", "succeeded", "failed", "cancelled"].contains(status),
        disposition == "outcomeUnknown" || stepCertainty == "outcomeUnknown" || result == "unknown"
      {
        throw failure("confirmed terminal status contains unknown Step")
      }
      if status == "succeeded", ["failed", "unknown"].contains(result) {
        throw failure("succeeded status contains failed Step")
      }
    }
    if authority == "standardAgent", mode == "execute", status == "succeeded" {
      let containsDestructive = try steps.contains { value in
        guard case .object(let step) = value else { return false }
        return try step.manifestString("effect") == "destructive"
      }
      if containsDestructive {
        throw failure("standardAgent execute manifest with destructive Step cannot succeed")
      }
    }
    if authority == "standardAgent" {
      for compensationValue in compensations {
        guard case .object(let compensation) = compensationValue,
          case .object(let descriptor)? = compensation["descriptor"]
        else { continue }
        if try descriptor.manifestString("effect") == "destructive" {
          guard try compensation.manifestString("disposition") == "notRun",
            try compensation.manifestString("outcomeCertainty") == "notApplicable",
            try compensation.manifestString("result") == "notRun"
          else { throw failure("standardAgent destructive compensation executed") }
        }
      }
    }
    if status == "succeeded" {
      for value in compensations {
        if case .object(let item) = value,
          ["failed", "unknown"].contains(try item.manifestString("result"))
        {
          throw failure("succeeded status contains failed compensation")
        }
      }
      for value in parameters {
        if case .object(let item) = value,
          ["failed", "outcomeUnknown"].contains(try item.manifestString("restoreDisposition"))
        {
          throw failure("succeeded status contains failed restoration")
        }
      }
    }
  }

  private static func id(_ object: [String: JSONValue], _ key: String) throws {
    try SessionStorageValidation.identifier(try object.manifestString(key), field: key)
  }

  private static func validateDeclaredPolicy(
    _ object: [String: JSONValue],
    effect: WorkflowEffect,
    cancellation: WorkflowCancellationPolicy,
    bindingRequirement: WorkflowBindingRequirement,
    context: String
  ) throws {
    guard try object.manifestString("effect") == effect.rawValue,
      try object.manifestString("cancellation") == cancellation.rawValue,
      try object.manifestString("bindingRequirement") == bindingRequirement.rawValue
    else {
      throw failure("\(context) understates its locked typed policy")
    }
  }

  private static func timestamp(_ object: [String: JSONValue], _ key: String) throws {
    try SessionStorageValidation.timestamp(try object.manifestString(key), field: key)
  }

  private static func enumValue(
    _ object: [String: JSONValue],
    _ key: String,
    _ allowed: some Sequence<String>
  ) throws -> String {
    let value = try object.manifestString(key)
    guard Set(allowed).contains(value) else { throw failure("unknown \(key):\(value)") }
    return value
  }

  private static func failure(_ detail: String) -> SessionStorageError {
    .invalidManifest(detail)
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func manifestRequireKeys(_ required: Set<String>, optional: Set<String> = []) throws {
    let actual = Set(keys)
    guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
      throw SessionStorageError.invalidManifest(
        "missing=\(required.subtracting(actual).sorted());unexpected=\(actual.subtracting(required.union(optional)).sorted())"
      )
    }
  }

  fileprivate func manifestString(_ key: String) throws -> String {
    guard case .string(let value)? = self[key] else {
      throw SessionStorageError.invalidManifest("\(key) must be string")
    }
    return value
  }

  fileprivate func manifestNullableString(_ key: String) throws -> String? {
    guard let value = self[key] else {
      throw SessionStorageError.invalidManifest("missing \(key)")
    }
    if case .null = value { return nil }
    guard case .string(let string) = value else {
      throw SessionStorageError.invalidManifest("\(key) must be string or null")
    }
    return string
  }

  fileprivate func manifestOptionalNullableString(_ key: String) throws -> String? {
    guard self[key] != nil else { return nil }
    return try manifestNullableString(key)
  }

  fileprivate func manifestInteger(_ key: String) throws -> Int64 {
    guard let value = self[key] else { throw SessionStorageError.invalidManifest("missing \(key)") }
    switch value {
    case .integer(let integer): return integer
    case .unsignedInteger(let integer) where integer <= UInt64(Int64.max): return Int64(integer)
    default: throw SessionStorageError.invalidManifest("\(key) must be integer")
    }
  }

  fileprivate func manifestUnsignedInteger(_ key: String) throws -> UInt64 {
    guard let value = self[key] else { throw SessionStorageError.invalidManifest("missing \(key)") }
    switch value {
    case .integer(let integer) where integer >= 0: return UInt64(integer)
    case .unsignedInteger(let integer): return integer
    default: throw SessionStorageError.invalidManifest("\(key) must be unsigned integer")
    }
  }

  fileprivate func manifestNullableInteger(_ key: String) throws -> Int64? {
    guard let value = self[key] else { throw SessionStorageError.invalidManifest("missing \(key)") }
    if case .null = value { return nil }
    return try manifestInteger(key)
  }

  fileprivate func manifestOptionalNullableInteger(_ key: String) throws -> Int64? {
    guard self[key] != nil else { return nil }
    return try manifestNullableInteger(key)
  }

  fileprivate func manifestObject(_ key: String) throws -> [String: JSONValue] {
    guard case .object(let value)? = self[key] else {
      throw SessionStorageError.invalidManifest("\(key) must be object")
    }
    return value
  }

  fileprivate func manifestArray(_ key: String) throws -> [JSONValue] {
    guard case .array(let value)? = self[key] else {
      throw SessionStorageError.invalidManifest("\(key) must be array")
    }
    return value
  }

  fileprivate func manifestStringArray(_ key: String) throws -> [String] {
    try manifestArray(key).map { value in
      guard case .string(let string) = value else {
        throw SessionStorageError.invalidManifest("\(key) must contain strings")
      }
      return string
    }
  }

  fileprivate func manifestBool(_ key: String) throws -> Bool {
    guard case .bool(let value)? = self[key] else {
      throw SessionStorageError.invalidManifest("\(key) must be boolean")
    }
    return value
  }

  fileprivate func manifestIsNull(_ key: String) -> Bool {
    self[key]?.manifestIsNull == true
  }
}

extension JSONValue {
  fileprivate var manifestIsNull: Bool {
    if case .null = self { return true }
    return false
  }
}
