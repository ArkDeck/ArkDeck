import ArkDeckCore
import ArkDeckStorage
import Darwin
import Foundation

public struct RuntimeSessionStoragePolicy: Codable, Equatable, Sendable {
  public let totalQuotaBytes: UInt64
  public let safetyMarginBytes: UInt64
  public let retentionDays: UInt64

  public init(
    totalQuotaBytes: UInt64,
    safetyMarginBytes: UInt64,
    retentionDays: UInt64
  ) {
    self.totalQuotaBytes = totalQuotaBytes
    self.safetyMarginBytes = safetyMarginBytes
    self.retentionDays = retentionDays
  }
}

public struct RuntimeSessionStorageStatus: Equatable, Sendable {
  public let generation: UInt64
  public let rootPath: String
  public let usesCustomRoot: Bool
  public let policy: RuntimeSessionStoragePolicy
  public let currentBytes: UInt64
  public let pinnedBytes: UInt64
  public let sessionCount: Int
  public let pinnedSessionCount: Int
  public let unaccountedSessionCount: Int
  public let measurementIncomplete: Bool
  public let catalogGeneration: UInt64?

  package var projection: JSONValue {
    .object([
      "schemaVersion": .string("arkdeck.session-storage-status/1"),
      "generation": .string(String(generation)),
      "rootPath": .string(rootPath),
      "rootKind": .string(usesCustomRoot ? "custom" : "default"),
      "policy": .object([
        "totalQuotaBytes": .string(String(policy.totalQuotaBytes)),
        "safetyMarginBytes": .string(String(policy.safetyMarginBytes)),
        "retentionDays": .string(String(policy.retentionDays)),
      ]),
      "usage": .object([
        "usedBytes": .string(String(currentBytes)),
        "pinnedBytes": .string(String(pinnedBytes)),
        "sessionCount": .string(String(sessionCount)),
        "pinnedSessionCount": .string(String(pinnedSessionCount)),
        "unaccountedSessionCount": .string(String(unaccountedSessionCount)),
        "measurementIncomplete": .bool(measurementIncomplete),
      ]),
      "catalogGeneration": catalogGeneration.map { .string(String($0)) } ?? .null,
    ])
  }
}

public struct RuntimeSessionStorageFailure: Error, Equatable, Sendable {
  public let code: String
  public let message: String

  package init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// The daemon-owned Session storage configuration and measurement resource.
///
/// App and CLI reach this owner only through typed control methods. The file is
/// private to the Runtime state directory, while a selected Session root is
/// stored as one validated canonical path. No process-local preference is a
/// source of truth after this owner is composed.
public final class RuntimeSessionStorageStore: @unchecked Sendable {
  private struct Document: Codable, Equatable {
    var schemaVersion = "arkdeck.session-storage-store/1"
    var generation: UInt64
    var rootKind: String
    var rootPath: String
    var policy: RuntimeSessionStoragePolicy
  }

  public static let defaultPolicy = RuntimeSessionStoragePolicy(
    totalQuotaBytes: 20 * 1_024 * 1_024 * 1_024,
    safetyMarginBytes: 2 * 1_024 * 1_024 * 1_024,
    retentionDays: 90)

  private static let documentName = "session-storage.json"
  private static let lockName = ".session-storage.lock"
  private static let sessionSnapshotDirectoryName = "session-resource-snapshots"
  private static let cleanupPreviewDirectoryName = "session-cleanup-previews"
  private static let exportPreviewDirectoryName = "session-export-previews"
  private static let maximumDocumentBytes = 64 * 1_024
  private static let maximumRootPathBytes = 4 * 1_024

  private let ownerRoot: URL
  private let defaultSessionsRoot: URL
  private let clock: @Sendable () -> Date
  private let retentionController: SessionRetentionController
  private let exportFaultInjector: SessionStorageFaultInjector

  package init(
    ownerRoot: URL,
    defaultSessionsRoot: URL,
    clock: @escaping @Sendable () -> Date = { Date() },
    retentionController: SessionRetentionController = SessionRetentionController(),
    exportFaultInjector: SessionStorageFaultInjector = .none
  ) throws {
    let normalizedOwner = ownerRoot.standardizedFileURL
    try Self.requireOwnerDirectory(normalizedOwner)
    // Resolve aliases only after the fixed default exists. Foundation cannot
    // resolve an aliased ancestor reliably when the leaf itself is absent;
    // persisting that pre-creation spelling would make the same root appear
    // non-canonical on the next mutation.
    try Self.ensureDirectory(defaultSessionsRoot)
    self.ownerRoot = try Self.canonicalRoot(normalizedOwner)
    self.defaultSessionsRoot = try Self.canonicalRoot(defaultSessionsRoot)
    self.clock = clock
    self.retentionController = retentionController
    self.exportFaultInjector = exportFaultInjector
    try requireDisjointFromOwner(self.defaultSessionsRoot)
  }

  package func status() throws -> RuntimeSessionStorageStatus {
    try withLockedDocument { _, document in
      try measuredStatus(document)
    }
  }

  package func updatePolicy(
    _ policy: RuntimeSessionStoragePolicy,
    expectedGeneration: UInt64
  ) throws -> RuntimeSessionStorageStatus {
    try validate(policy)
    return try mutate(expectedGeneration: expectedGeneration) { document in
      document.policy = policy
    }
  }

  package func updateRoot(
    path: String?,
    resetToDefault: Bool,
    expectedGeneration: UInt64
  ) throws -> RuntimeSessionStorageStatus {
    guard (path != nil) != resetToDefault else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "select exactly one custom root or the default root")
    }
    let selected: URL
    let kind: String
    if resetToDefault {
      selected = defaultSessionsRoot
      kind = "default"
    } else {
      guard let path, path.utf8.count <= Self.maximumRootPathBytes,
        path == path.trimmingCharacters(in: .whitespacesAndNewlines),
        path.hasPrefix("/")
      else {
        throw RuntimeSessionStorageFailure(
          "invalidInput", "Session root must be one bounded absolute path")
      }
      selected = try Self.canonicalRoot(URL(filePath: path, directoryHint: .isDirectory))
      kind = "custom"
    }
    return try mutate(expectedGeneration: expectedGeneration) { document in
      // A stale CAS request must have no filesystem write-probe side effect.
      // The mutation helper checks generation before invoking this closure.
      if resetToDefault {
        try Self.ensureDirectory(selected)
      }
      try requireDisjointFromOwner(selected)
      try Self.requireSafeWritableRoot(selected)
      document.rootKind = kind
      document.rootPath = selected.path
    }
  }

  /// Returns one immutable, bounded page of Sessions from the Runtime-selected
  /// root. The cursor names a private Runtime snapshot; it never exposes a
  /// directory, catalog offset or App preference.
  package func listSessions(pageSize: Int, cursor: String?) throws -> JSONValue {
    let pager = try RuntimeSnapshotPager(
      directory: ownerRoot.appending(
        path: Self.sessionSnapshotDirectoryName, directoryHint: .isDirectory))
    if cursor != nil {
      return try pager.page(
        method: "session.list", filters: [:],
        order: "completedAtDescSessionIdAsc", pageSize: pageSize, cursor: cursor
      ) {
        // RuntimeSnapshotPager never evaluates this closure for a cursor. The
        // stored page remains readable after the active root or policy moves.
        []
      }
    }
    return try withLockedDocument { _, document in
      try pager.page(
        method: "session.list", filters: [:],
        order: "completedAtDescSessionIdAsc", pageSize: pageSize, cursor: nil
      ) {
        try sessionRows(sessionCatalog(document)).map(\.projection)
      }
    }
  }

  /// Reads one Session through the same catalog owner used by list and pin.
  /// No Session directory or manifest path crosses the control protocol.
  package func showSession(sessionID: String) throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(sessionID) else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "sessionId must be one bounded Runtime identifier")
    }
    return try withLockedDocument { _, document in
      let snapshot = try sessionCatalog(document)
      guard let row = try sessionRows(snapshot).first(where: { $0.sessionID == sessionID }) else {
        throw RuntimeSessionStorageFailure(
          "resourceNotFound", "Session is not present in the Runtime catalog")
      }
      return row.projection
    }
  }

  /// Applies a generation-bound pin transition while holding the storage
  /// configuration owner. A concurrent root or policy replacement therefore
  /// cannot redirect this intent to another Session tree.
  package func updateSessionPin(
    sessionID: String,
    isPinned: Bool,
    expectedGeneration: UInt64
  ) throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(sessionID),
      expectedGeneration <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session pin requires a bounded identity and generation")
    }
    return try withLockedDocument { _, document in
      let before = try sessionCatalog(document)
      let beforeRows = try sessionRows(before)
      guard before.catalogGeneration == expectedGeneration else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session catalog generation changed")
      }
      guard beforeRows.contains(where: { $0.sessionID == sessionID }) else {
        throw RuntimeSessionStorageFailure(
          "resourceNotFound", "Session is not present in the Runtime catalog")
      }
      let root = try activeRoot(document, createDefaultIfMissing: true)
      let catalog = try SessionRetentionCatalog(sessionsRoot: root)
      do {
        _ = try catalog.updatePin(
          sessionID: sessionID, isPinned: isPinned,
          expectedGeneration: expectedGeneration)
      } catch let failure as SessionRetentionCatalogError {
        throw mapCatalogFailure(failure)
      }
      let after = try catalog.scan(
        retentionDays: document.policy.retentionDays,
        policyGeneration: document.generation)
      guard let row = try sessionRows(after).first(where: { $0.sessionID == sessionID }),
        row.isPinned == isPinned
      else {
        throw RuntimeSessionStorageFailure(
          "outcomeUnknown", "Session pin publication cannot be read back exactly")
      }
      return row.projection
    }
  }

  package func previewSessionExport(
    sessionID: String,
    destinationPath: String,
    allowSensitive: Bool
  ) throws -> JSONValue {
    guard AgentExecutionIntent.validIdentifier(sessionID) else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export requires one bounded Session identity")
    }
    return try withLockedDocument { _, document in
      let snapshot = try sessionCatalog(document)
      _ = try sessionRows(snapshot)
      let root = try activeRoot(document, createDefaultIfMissing: true)
      let destination = try exportDestinationFacts(
        destinationPath, sourceRoot: root)
      let createdAt = clock()
      guard createdAt.timeIntervalSince1970.isFinite else {
        throw RuntimeSessionStorageFailure(
          "operationUnavailable", "Runtime clock is unavailable")
      }
      let expiresAt = createdAt.addingTimeInterval(10 * 60)
      let previewID = UUID().uuidString.lowercased()
      let projection = try exportPreviewProjection(
        previewID: previewID, createdAt: createdAt, expiresAt: expiresAt,
        sessionID: sessionID, allowSensitive: allowSensitive,
        destination: destination, document: document, snapshot: snapshot)
      guard case .object(let fields) = projection,
        case .string(let digest)? = fields["previewDigest"],
        case .string(let expiry)? = fields["expiresAtUtc"]
      else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session export preview projection is malformed")
      }
      try exportRecordStore().create(
        previewID: previewID, previewDigest: digest,
        expiresAtUTC: expiry, preview: projection, now: createdAt)
      return projection
    }
  }

  package func applySessionExport(
    previewID: String,
    previewDigest: String
  ) throws -> JSONValue {
    guard let uuid = UUID(uuidString: previewID),
      uuid.uuidString.lowercased() == previewID,
      SHA256Hex.isLowercaseSHA256(previewDigest)
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export apply requires an exact preview tuple")
    }
    return try withLockedDocument { _, document in
      let store = try exportRecordStore()
      var record = try store.load(previewID)
      guard record.previewDigest == previewDigest else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session export preview digest does not match")
      }
      if record.state == .applied, record.result != .null { return record.result }
      guard record.state == .ready else {
        throw RuntimeSessionStorageFailure(
          "outcomeUnknown", "Session export may already have published output")
      }
      guard case .object(let stored) = record.preview,
        case .string(let createdText)? = stored["createdAtUtc"],
        case .string(let expiresText)? = stored["expiresAtUtc"],
        let createdAt = ISO8601Timestamps.parseCanonicalPlain(createdText),
        let expiresAt = ISO8601Timestamps.parseCanonicalPlain(expiresText),
        expiresAt > clock(),
        case .string(let sessionID)? = stored["sessionId"],
        case .bool(let allowSensitive)? = stored["allowSensitive"],
        case .object(let storedDestination)? = stored["destination"],
        case .string(let destinationPath)? = storedDestination["path"]
      else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session export preview expired or is malformed")
      }
      let snapshot = try sessionCatalog(document)
      _ = try sessionRows(snapshot)
      let root = try activeRoot(document, createDefaultIfMissing: true)
      let destination = try exportDestinationFacts(
        destinationPath, sourceRoot: root)
      let current = try exportPreviewProjection(
        previewID: previewID, createdAt: createdAt, expiresAt: expiresAt,
        sessionID: sessionID, allowSensitive: allowSensitive,
        destination: destination, document: document, snapshot: snapshot)
      guard current == record.preview,
        let retained = snapshot.sessions.first(where: { $0.sessionID == sessionID }),
        let jobID = snapshot.jobIDBySession[sessionID],
        let artifacts = snapshot.artifactRecordsBySession[sessionID],
        case .string(let generationText)? = stored["generation"],
        let generation = UInt64(generationText)
      else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session export facts changed after preview")
      }
      let layout = try SessionLayout(
        sessionID: sessionID, jobID: jobID, root: retained.root)
      let maximumGrowth = try exportMaximumGrowth(
        snapshot: snapshot, sessionID: sessionID,
        allowSensitive: allowSensitive)
      let parent = URL(filePath: destinationPath).deletingLastPathComponent()
      let destinationSnapshot: HostStorageSnapshot
      do {
        destinationSnapshot = try SystemHostStorageProbe().snapshot(for: parent)
      } catch {
        throw RuntimeSessionStorageFailure(
          "operationUnavailable", "Session export destination capacity is unavailable")
      }
      let claim: StorageClaim
      do {
        claim = try StorageClaim.finalizedSessionExport(
          jobID: jobID, destinationSnapshot: destinationSnapshot,
          maximumGrowthBytes: maximumGrowth)
      } catch {
        throw RuntimeSessionStorageFailure(
          "quotaExceeded", "Session export destination lacks bounded headroom")
      }
      record = try store.markApplying(record)
      do {
        let materialized = try SessionDiagnosticExporter(
          faultInjector: exportFaultInjector
        ).export(
          layout: layout, artifacts: artifacts, claim: claim,
          to: URL(filePath: destinationPath),
          includeDeviceData: allowSensitive,
          deviceIdentifierPolicy: .redact)
        let after = try sessionCatalog(document)
        guard after == snapshot else {
          throw RuntimeSessionStorageFailure(
            "outcomeUnknown", "Session changed while its export was published")
        }
        let result = try exportResult(
          previewID: previewID, previewDigest: previewDigest,
          generation: generation, sessionID: sessionID,
          destinationPath: materialized.root.standardizedFileURL.path,
          snapshot: snapshot, allowSensitive: allowSensitive)
        _ = try store.markApplied(record, result: result)
        return result
      } catch {
        throw RuntimeSessionStorageFailure(
          "outcomeUnknown", "Session export outcome requires destination inspection")
      }
    }
  }

  package func previewSessionCleanup(
    activeSessionIDs: Set<String>
  ) throws -> JSONValue {
    guard activeSessionIDs.allSatisfy(AgentExecutionIntent.validIdentifier) else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Runtime active Session inventory is malformed")
    }
    return try withLockedDocument { _, document in
      let snapshot = try sessionCatalog(document)
      _ = try sessionRows(snapshot)
      let createdAt = clock()
      guard createdAt.timeIntervalSince1970.isFinite else {
        throw RuntimeSessionStorageFailure(
          "operationUnavailable", "Runtime clock is unavailable")
      }
      let expiresAt = createdAt.addingTimeInterval(10 * 60)
      let previewID = UUID().uuidString.lowercased()
      let projection = try cleanupPreviewProjection(
        previewID: previewID, createdAt: createdAt, expiresAt: expiresAt,
        document: document, snapshot: snapshot,
        activeSessionIDs: activeSessionIDs)
      guard case .object(let fields) = projection,
        case .string(let digest)? = fields["previewDigest"],
        case .string(let expiry)? = fields["expiresAtUtc"]
      else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session cleanup preview projection is malformed")
      }
      let store = try cleanupRecordStore()
      try store.create(
        previewID: previewID, previewDigest: digest,
        expiresAtUTC: expiry, preview: projection, now: createdAt)
      return projection
    }
  }

  package func applySessionCleanup(
    previewID: String,
    previewDigest: String,
    activeSessionIDs: Set<String>
  ) throws -> JSONValue {
    guard let uuid = UUID(uuidString: previewID),
      uuid.uuidString.lowercased() == previewID,
      SHA256Hex.isLowercaseSHA256(previewDigest),
      activeSessionIDs.allSatisfy(AgentExecutionIntent.validIdentifier)
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session cleanup apply requires an exact preview tuple")
    }
    return try withLockedDocument { _, document in
      let store = try cleanupRecordStore()
      var record = try store.load(previewID)
      guard record.previewDigest == previewDigest else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session cleanup preview digest does not match")
      }
      if record.state == .applied, record.result != .null { return record.result }
      guard record.state == .ready else {
        throw RuntimeSessionStorageFailure(
          "outcomeUnknown", "Session cleanup may already have changed storage")
      }
      guard case .object(let stored) = record.preview,
        case .string(let createdText)? = stored["createdAtUtc"],
        case .string(let expiresText)? = stored["expiresAtUtc"],
        let createdAt = ISO8601Timestamps.parseCanonicalPlain(createdText),
        let expiresAt = ISO8601Timestamps.parseCanonicalPlain(expiresText),
        expiresAt > clock()
      else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session cleanup preview expired")
      }
      let snapshot = try sessionCatalog(document)
      _ = try sessionRows(snapshot)
      let current = try cleanupPreviewProjection(
        previewID: previewID, createdAt: createdAt, expiresAt: expiresAt,
        document: document, snapshot: snapshot,
        activeSessionIDs: activeSessionIDs)
      guard current == record.preview else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session cleanup facts changed after preview")
      }
      let plan = try retentionPlan(
        snapshot, policy: document.policy,
        activeSessionIDs: activeSessionIDs, now: createdAt)
      record = try store.markApplying(record)
      do {
        let root = try activeRoot(document, createDefaultIfMissing: true)
        let catalog = try SessionRetentionCatalog(sessionsRoot: root)
        let after = try catalog.applyRetention(
          plan, expectedSnapshot: snapshot,
          retentionDays: document.policy.retentionDays,
          policyGeneration: document.generation,
          controller: retentionController)
        let result = try cleanupResult(
          previewID: previewID, previewDigest: previewDigest,
          before: snapshot, after: after, plan: plan)
        _ = try store.markApplied(record, result: result)
        return result
      } catch SessionRetentionCatalogError.staleSnapshot {
        _ = try store.restoreReady(record)
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session cleanup facts changed before apply")
      } catch {
        throw RuntimeSessionStorageFailure(
          "outcomeUnknown", "Session cleanup outcome requires inspection")
      }
    }
  }

  private func cleanupResult(
    previewID: String,
    previewDigest: String,
    before: SessionRetentionCatalogSnapshot,
    after: SessionRetentionCatalogSnapshot,
    plan: SessionRetentionPlan
  ) throws -> JSONValue {
    _ = try sessionRows(after)
    guard let beforeGeneration = before.catalogGeneration,
      let afterGeneration = after.catalogGeneration
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup result generation is unavailable")
    }
    let removed = Set(plan.deletionSessionIDs)
    let removedArtifacts = before.artifactsBySession
      .filter { removed.contains($0.key) }
      .flatMap { sessionID, artifacts in
        artifacts.map { (sessionID, $0) }
      }
      .sorted {
        ($0.0, $0.1.artifactID) < ($1.0, $1.1.artifactID)
      }
      .map { sessionID, artifact in
        JSONValue.object([
          "sessionId": .string(sessionID),
          "artifactId": .string(artifact.artifactID),
          "artifactDigest": .string(artifact.sha256),
        ])
      }
    let reclaimed = before.sessions
      .filter { removed.contains($0.sessionID) }
      .reduce(UInt64(0)) { partial, session in
        let sum = partial.addingReportingOverflow(session.sizeBytes)
        return sum.overflow ? UInt64.max : sum.partialValue
      }
    return .object([
      "schemaVersion": .string("arkdeck.session-cleanup-result/1"),
      "previewId": .string(previewID),
      "previewDigest": .string(previewDigest),
      "generation": .string(String(beforeGeneration)),
      "resultGeneration": .string(String(afterGeneration)),
      "appliedAtUtc": .string(ISO8601Timestamps.string(from: clock())),
      "removedSessionIds": .array(plan.deletionSessionIDs.sorted().map(JSONValue.string)),
      "removedArtifacts": .array(removedArtifacts),
      "reclaimedBytes": .string(String(reclaimed)),
      "remainingBytes": .string(String(after.currentBytes)),
      "newDispatchCount": .integer(0),
    ])
  }

  private func exportPreviewProjection(
    previewID: String,
    createdAt: Date,
    expiresAt: Date,
    sessionID: String,
    allowSensitive: Bool,
    destination: JSONValue,
    document: Document,
    snapshot: SessionRetentionCatalogSnapshot
  ) throws -> JSONValue {
    guard let generation = snapshot.catalogGeneration,
      generation <= UInt64(Int64.max),
      document.generation <= UInt64(Int64.max),
      snapshot.sessions.contains(where: { $0.sessionID == sessionID }),
      let artifacts = snapshot.artifactsBySession[sessionID],
      let manifestBytes = snapshot.manifestByteCountBySession[sessionID],
      snapshot.jobIDBySession[sessionID] != nil,
      snapshot.artifactRecordsBySession[sessionID] != nil
    else {
      throw RuntimeSessionStorageFailure(
        "resourceNotFound", "Session is not present in the Runtime export catalog")
    }
    var estimatedBytes = manifestBytes
    var rows: [JSONValue] = []
    for artifact in artifacts {
      let sensitive = ["raw", "partial"].contains(artifact.role)
      let included = allowSensitive || !sensitive
      if included {
        let sum = estimatedBytes.addingReportingOverflow(artifact.byteCount)
        guard !sum.overflow else {
          throw RuntimeSessionStorageFailure(
            "recordUnreadable", "Session export byte estimate overflowed")
        }
        estimatedBytes = sum.partialValue
      }
      rows.append(.object([
        "artifactId": .string(artifact.artifactID),
        "artifactDigest": .string(artifact.sha256),
        "byteCount": .string(String(artifact.byteCount)),
        "role": .string(artifact.role),
        "privacy": .string(sensitive ? "sensitive" : "unknown"),
        "disposition": .string(included ? "include" : "excludeByDefault"),
        "transformation": .string(included ? "redactDeviceIdentifiers" : "excluded"),
      ]))
    }
    var fields: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.session-export-preview/1"),
      "previewId": .string(previewID),
      "digestAlgorithm": .string("sha256-jcs"),
      "sessionId": .string(sessionID),
      "generation": .string(String(generation)),
      "policyGeneration": .string(String(document.generation)),
      "createdAtUtc": .string(ISO8601Timestamps.string(from: createdAt)),
      "expiresAtUtc": .string(ISO8601Timestamps.string(from: expiresAt)),
      "confirmationRequired": .bool(true),
      "allowSensitive": .bool(allowSensitive),
      "sensitiveDefaultExcluded": .bool(true),
      "deviceIdentifierPolicy": .string("redact"),
      "estimatedBytes": .string(String(estimatedBytes)),
      "destination": destination,
      "artifacts": .array(rows),
      "newDispatchCount": .integer(0),
    ]
    let digest = SHA256Hex.string(
      of: try PortableCanonicalJSON.canonicalBytes(.object(fields)))
    fields["previewDigest"] = .string(digest)
    return .object(fields)
  }

  private func exportDestinationFacts(
    _ path: String,
    sourceRoot: URL
  ) throws -> JSONValue {
    guard !path.isEmpty, path.utf8.count <= 4 * 1_024,
      path == path.trimmingCharacters(in: .whitespacesAndNewlines),
      path.hasPrefix("/"),
      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export destination must be one bounded absolute path")
    }
    let physical = RuntimeArtifactExport.physicalPath(
      URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path)
    let destination = URL(filePath: physical, directoryHint: .isDirectory)
    let name = destination.lastPathComponent
    guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export destination name is invalid")
    }
    let protected = [ownerRoot, sourceRoot].map {
      RuntimeArtifactExport.physicalPath($0.standardizedFileURL.path)
    }
    guard protected.allSatisfy({ physical != $0 && !physical.hasPrefix($0 + "/") }) else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export destination must be outside Runtime storage")
    }
    let parent = destination.deletingLastPathComponent()
    let descriptor: Int32
    do {
      descriptor = try ArkTraceProfileFileReader.openPhysicalDirectoryDescriptor(parent.path)
    } catch {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export parent must exist without symbolic-link components")
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid()
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session export parent must be an owned directory")
    }
    var existing = stat()
    if fstatat(descriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
      throw RuntimeSessionStorageFailure(
        "resourceConflict", "Session export destination already exists")
    }
    guard errno == ENOENT else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session export destination cannot be inspected")
    }
    let volume: VolumeIdentity
    do {
      volume = try SystemVolumeIdentityResolver().resolve(openFileDescriptor: descriptor)
    } catch {
      throw RuntimeSessionStorageFailure(
        "operationUnavailable", "Session export destination volume is unavailable")
    }
    return .object([
      "path": .string(physical),
      "parentDevice": .string(String(UInt64(UInt32(bitPattern: metadata.st_dev)))),
      "parentInode": .string(String(UInt64(metadata.st_ino))),
      "volumeIdentity": .string(volume.value),
      "expectedState": .string("absent"),
    ])
  }

  private func exportMaximumGrowth(
    snapshot: SessionRetentionCatalogSnapshot,
    sessionID: String,
    allowSensitive: Bool
  ) throws -> UInt64 {
    guard let artifacts = snapshot.artifactsBySession[sessionID] else {
      throw RuntimeSessionStorageFailure(
        "resourceNotFound", "Session export inventory is unavailable")
    }
    var maximum: UInt64 = 16 * 1_024 * 1_024
    for artifact in artifacts {
      let sensitive = ["raw", "partial"].contains(artifact.role)
      guard allowSensitive || !sensitive else { continue }
      let bound = max(artifact.byteCount, 64 * 1_024 * 1_024)
      let sum = maximum.addingReportingOverflow(bound)
      guard !sum.overflow else {
        throw RuntimeSessionStorageFailure(
          "quotaExceeded", "Session export write bound overflowed")
      }
      maximum = sum.partialValue
    }
    return maximum
  }

  private func exportResult(
    previewID: String,
    previewDigest: String,
    generation: UInt64,
    sessionID: String,
    destinationPath: String,
    snapshot: SessionRetentionCatalogSnapshot,
    allowSensitive: Bool
  ) throws -> JSONValue {
    guard let artifacts = snapshot.artifactsBySession[sessionID] else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session export result inventory is unavailable")
    }
    let included = artifacts.filter {
      allowSensitive || !["raw", "partial"].contains($0.role)
    }.map(\.artifactID).sorted()
    let excluded = artifacts.filter {
      !allowSensitive && ["raw", "partial"].contains($0.role)
    }.map(\.artifactID).sorted()
    return .object([
      "schemaVersion": .string("arkdeck.session-export-result/1"),
      "previewId": .string(previewID),
      "previewDigest": .string(previewDigest),
      "sessionId": .string(sessionID),
      "generation": .string(String(generation)),
      "resultGeneration": .string(String(generation)),
      "publishedAtUtc": .string(ISO8601Timestamps.string(from: clock())),
      "exportedPath": .string(destinationPath),
      "sourceArtifactIds": .array(included.map(JSONValue.string)),
      "excludedArtifactIds": .array(excluded.map(JSONValue.string)),
      "deviceIdentifierPolicy": .string("redact"),
      "evidenceClass": .string("derivedExport"),
      "newDispatchCount": .integer(0),
    ])
  }

  private func exportRecordStore() throws -> RuntimeSessionExportRecordStore {
    try RuntimeSessionExportRecordStore(
      directory: ownerRoot.appending(
        path: Self.exportPreviewDirectoryName, directoryHint: .isDirectory))
  }

  private func cleanupRecordStore() throws -> RuntimeSessionCleanupRecordStore {
    try RuntimeSessionCleanupRecordStore(
      directory: ownerRoot.appending(
        path: Self.cleanupPreviewDirectoryName, directoryHint: .isDirectory))
  }

  private func retentionPlan(
    _ snapshot: SessionRetentionCatalogSnapshot,
    policy: RuntimeSessionStoragePolicy,
    activeSessionIDs: Set<String>,
    now: Date
  ) throws -> SessionRetentionPlan {
    let planning = try snapshot.sessions.map { session -> RetainedSession in
      guard activeSessionIDs.contains(session.sessionID), !session.isPinned else {
        return session
      }
      return try RetainedSession(
        sessionID: session.sessionID, root: session.root,
        sizeBytes: session.sizeBytes, completedAt: session.completedAt,
        expiresAt: session.expiresAt, isPinned: true)
    }
    return retentionController.plan(
      sessions: planning,
      totalQuotaBytes: policy.totalQuotaBytes,
      safetyMarginBytes: policy.safetyMarginBytes,
      now: now)
  }

  private func cleanupPreviewProjection(
    previewID: String,
    createdAt: Date,
    expiresAt: Date,
    document: Document,
    snapshot: SessionRetentionCatalogSnapshot,
    activeSessionIDs: Set<String>
  ) throws -> JSONValue {
    guard let generation = snapshot.catalogGeneration,
      generation <= UInt64(Int64.max),
      document.generation <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session cleanup generation is unavailable")
    }
    let plan = try retentionPlan(
      snapshot, policy: document.policy,
      activeSessionIDs: activeSessionIDs, now: createdAt)
    let deleting = Set(plan.deletionSessionIDs)
    let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.sessionID, $0) })
    var reclaimBytes: UInt64 = 0
    let sessions: [JSONValue] = try snapshot.sessions
      .sorted { $0.sessionID < $1.sessionID }
      .map { session in
        guard let entry = entries[session.sessionID],
          let sessionExpiry = session.expiresAt,
          entry.expiresAt == sessionExpiry,
          entry.isPinned == session.isPinned,
          let artifacts = snapshot.artifactsBySession[session.sessionID]
        else {
          throw RuntimeSessionStorageFailure(
            "recordUnreadable", "Session cleanup inventory is inconsistent")
        }
        let active = activeSessionIDs.contains(session.sessionID)
        let remove = deleting.contains(session.sessionID)
        if remove {
          let sum = reclaimBytes.addingReportingOverflow(session.sizeBytes)
          guard !sum.overflow else {
            throw RuntimeSessionStorageFailure(
              "recordUnreadable", "Session cleanup byte total overflowed")
          }
          reclaimBytes = sum.partialValue
        }
        let reason: String
        if active {
          reason = "activeLease"
        } else if session.isPinned {
          reason = "pinned"
        } else if remove, sessionExpiry <= createdAt {
          reason = "expiredQuotaPressure"
        } else if remove {
          reason = "quotaPressure"
        } else {
          reason = "withinSafetyTarget"
        }
        let artifactValues = artifacts.map { artifact in
          JSONValue.object([
            "artifactId": .string(artifact.artifactID),
            "artifactDigest": .string(artifact.sha256),
            "byteCount": .string(String(artifact.byteCount)),
            "role": .string(artifact.role),
            "privacy": .string(
              ["raw", "partial"].contains(artifact.role) ? "sensitive" : "unknown"),
          ])
        }
        return .object([
          "sessionId": .string(session.sessionID),
          "disposition": .string(remove ? "reclaim" : "retain"),
          "reason": .string(reason),
          "sizeBytes": .string(String(session.sizeBytes)),
          "expiresAtUtc": .string(ISO8601Timestamps.string(from: sessionExpiry)),
          "pinned": .bool(session.isPinned),
          "activeLease": .bool(active),
          "artifacts": .array(artifactValues),
        ])
      }
    var fields: [String: JSONValue] = [
      "schemaVersion": .string("arkdeck.session-cleanup-preview/1"),
      "previewId": .string(previewID),
      "digestAlgorithm": .string("sha256-jcs"),
      "generation": .string(String(generation)),
      "policyGeneration": .string(String(document.generation)),
      "createdAtUtc": .string(ISO8601Timestamps.string(from: createdAt)),
      "expiresAtUtc": .string(ISO8601Timestamps.string(from: expiresAt)),
      "confirmationRequired": .bool(true),
      "currentBytes": .string(String(snapshot.currentBytes)),
      "projectedBytes": .string(String(plan.projectedBytes)),
      "safetyTargetBytes": .string(String(plan.safetyTargetBytes)),
      "reclaimBytes": .string(String(reclaimBytes)),
      "blocksNewHeavyWriters": .bool(plan.blocksNewHeavyWriters),
      "sessions": .array(sessions),
      "newDispatchCount": .integer(0),
    ]
    let digest = SHA256Hex.string(
      of: try PortableCanonicalJSON.canonicalBytes(.object(fields)))
    fields["previewDigest"] = .string(digest)
    return .object(fields)
  }

  private struct SessionRow {
    let sessionID: String
    let completedAt: Date
    let isPinned: Bool
    let projection: JSONValue
  }

  private func sessionCatalog(
    _ document: Document
  ) throws -> SessionRetentionCatalogSnapshot {
    let root = try activeRoot(document, createDefaultIfMissing: true)
    do {
      return try SessionRetentionCatalog(sessionsRoot: root).scan(
        retentionDays: document.policy.retentionDays,
        policyGeneration: document.generation)
    } catch let failure as SessionRetentionCatalogError {
      throw mapCatalogFailure(failure)
    }
  }

  private func sessionRows(
    _ snapshot: SessionRetentionCatalogSnapshot
  ) throws -> [SessionRow] {
    guard !snapshot.unknownPressure, snapshot.unknownSessionIDs.isEmpty else {
      throw RuntimeSessionStorageFailure(
        "operationUnavailable",
        "Session catalog contains unaccounted content; inspect runtime storage status")
    }
    guard let generation = snapshot.catalogGeneration,
      generation <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session catalog generation is unavailable")
    }
    let entries = Dictionary(grouping: snapshot.entries, by: \.sessionID)
    guard snapshot.entries.count == snapshot.sessions.count,
      Set(snapshot.entries.map(\.sessionID)) == Set(snapshot.sessions.map(\.sessionID))
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session catalog inventory is internally inconsistent")
    }
    var rows: [SessionRow] = []
    for session in snapshot.sessions {
      guard let matches = entries[session.sessionID], matches.count == 1,
        let entry = matches.first,
        entry.completedAt == session.completedAt,
        entry.expiresAt == session.expiresAt,
        entry.isPinned == session.isPinned,
        let expiresAt = session.expiresAt
      else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session catalog entry does not match measured content")
      }
      rows.append(
        SessionRow(
          sessionID: session.sessionID,
          completedAt: session.completedAt,
          isPinned: session.isPinned,
          projection: .object([
            "schemaVersion": .string("arkdeck.session/1"),
            "sessionId": .string(session.sessionID),
            "generation": .string(String(generation)),
            "completedAtUtc": .string(ISO8601Timestamps.string(from: session.completedAt)),
            "expiresAtUtc": .string(ISO8601Timestamps.string(from: expiresAt)),
            "sizeBytes": .string(String(session.sizeBytes)),
            "pinned": .bool(session.isPinned),
            "policyGeneration": .string(String(entry.policyGeneration)),
          ])))
    }
    return rows.sorted {
      if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
      return $0.sessionID.utf8.lexicographicallyPrecedes($1.sessionID.utf8)
    }
  }

  private func mapCatalogFailure(
    _ failure: SessionRetentionCatalogError
  ) -> RuntimeSessionStorageFailure {
    switch failure {
    case .staleGeneration, .staleSnapshot:
      return RuntimeSessionStorageFailure(
        "resourceConflict", "Session catalog generation changed")
    case .unknownSession:
      return RuntimeSessionStorageFailure(
        "resourceNotFound", "Session is not present in the Runtime catalog")
    case .generationOverflow:
      return RuntimeSessionStorageFailure(
        "resourceConflict", "Session catalog generation is exhausted")
    case .invalidRoot, .invalidRetentionDays, .metadataUnavailable, .metadataCorrupt,
      .unsafeSession:
      return RuntimeSessionStorageFailure(
        "recordUnreadable", "Session catalog cannot be read safely")
    }
  }

  private func mutate(
    expectedGeneration: UInt64,
    change: (inout Document) throws -> Void
  ) throws -> RuntimeSessionStorageStatus {
    try withLockedDocument { owner, loaded in
      guard expectedGeneration > 0, expectedGeneration <= UInt64(Int64.max) else {
        throw RuntimeSessionStorageFailure(
          "invalidInput", "expected generation must be a canonical positive integer")
      }
      guard loaded.generation == expectedGeneration else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session storage generation changed")
      }
      let next = loaded.generation.addingReportingOverflow(1)
      guard !next.overflow, next.partialValue <= UInt64(Int64.max) else {
        throw RuntimeSessionStorageFailure(
          "resourceConflict", "Session storage generation is exhausted")
      }
      var document = loaded
      try change(&document)
      document.generation = next.partialValue
      try validate(document)
      // Complete every fallible measurement before publishing the settings
      // generation. Once save returns, composing the receipt cannot fail.
      let result = try measuredStatus(document)
      try save(document, owner: owner)
      return result
    }
  }

  private func measuredStatus(_ document: Document) throws -> RuntimeSessionStorageStatus {
    let root = try activeRoot(document, createDefaultIfMissing: true)
    let catalog = try SessionRetentionCatalog(sessionsRoot: root).scan(
      retentionDays: document.policy.retentionDays,
      policyGeneration: document.generation)
    return RuntimeSessionStorageStatus(
      generation: document.generation,
      rootPath: root.path,
      usesCustomRoot: document.rootKind == "custom",
      policy: document.policy,
      currentBytes: catalog.currentBytes,
      pinnedBytes: catalog.pinnedBytes,
      sessionCount: catalog.entries.count,
      pinnedSessionCount: catalog.entries.filter(\.isPinned).count,
      unaccountedSessionCount: catalog.unknownSessionIDs.count,
      measurementIncomplete: catalog.unknownPressure,
      catalogGeneration: catalog.catalogGeneration)
  }

  private func withLockedDocument<T>(
    _ body: (Int32, Document) throws -> T
  ) throws -> T {
    let owner = Darwin.open(
      ownerRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard owner >= 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage owner directory cannot be opened")
    }
    defer { Darwin.close(owner) }
    try Self.validateOwnedDirectory(owner, label: "Session storage owner")
    let lock = Darwin.openat(
      owner, Self.lockName, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage lock cannot be opened")
    }
    defer { Darwin.close(lock) }
    try Self.validateOwnedRegularFile(lock, label: "Session storage lock")
    while flock(lock, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw RuntimeSessionStorageFailure(
        "resourceConflict", "Session storage lock cannot be acquired")
    }
    defer { _ = flock(lock, LOCK_UN) }
    return try body(owner, load(owner: owner))
  }

  private func load(owner: Int32) throws -> Document {
    let descriptor = Darwin.openat(
      owner, Self.documentName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT {
      return Document(
        generation: 1, rootKind: "default", rootPath: defaultSessionsRoot.path,
        policy: Self.defaultPolicy)
    }
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage document cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try Self.validateOwnedRegularFile(descriptor, label: "Session storage document")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0,
      metadata.st_size <= Self.maximumDocumentBytes
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage document size is invalid")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while data.count < Int(metadata.st_size) {
      let count = Darwin.read(
        descriptor, &buffer, min(buffer.count, Int(metadata.st_size) - data.count))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session storage document is truncated")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    do {
      let document = try JSONDecoder().decode(Document.self, from: data)
      try validate(document)
      var canonical = try CanonicalJSONEncoders.canonical().encode(document)
      canonical.append(0x0A)
      guard canonical == data else {
        throw RuntimeSessionStorageFailure(
          "recordUnreadable", "Session storage document is not canonical")
      }
      return document
    } catch let failure as RuntimeSessionStorageFailure {
      throw failure
    } catch {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage document failed schema validation")
    }
  }

  private func save(_ document: Document, owner: Int32) throws {
    var data = try CanonicalJSONEncoders.canonical().encode(document)
    data.append(0x0A)
    guard data.count <= Self.maximumDocumentBytes else {
      throw RuntimeSessionStorageFailure(
        "quotaExceeded", "Session storage document exceeds its byte bound")
    }
    let temporaryName = ".session-storage.\(UUID().uuidString.lowercased()).part"
    let descriptor = Darwin.openat(
      owner, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session storage transaction cannot be created")
    }
    var descriptorOpen = true
    defer {
      if descriptorOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(owner, temporaryName, 0)
    }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw RuntimeSessionStorageFailure(
          "ioFailure", "Session storage transaction cannot be written")
      }
      offset += count
    }
    guard fchmod(descriptor, 0o600) == 0, Darwin.fsync(descriptor) == 0,
      Darwin.close(descriptor) == 0
    else {
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session storage transaction cannot be synchronized")
    }
    descriptorOpen = false
    guard renameat(owner, temporaryName, owner, Self.documentName) == 0,
      Darwin.fsync(owner) == 0
    else {
      throw RuntimeSessionStorageFailure(
        "outcomeUnknown", "Session storage publication outcome is unknown")
    }
  }

  private func validate(_ document: Document) throws {
    guard document.schemaVersion == "arkdeck.session-storage-store/1",
      document.generation > 0, document.generation <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage record header is invalid")
    }
    guard ["default", "custom"].contains(document.rootKind),
      document.rootPath.utf8.count <= Self.maximumRootPathBytes,
      document.rootPath.hasPrefix("/")
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage root record is invalid")
    }
    let canonical: String
    do {
      canonical = try Self.canonicalRoot(
        URL(filePath: document.rootPath, directoryHint: .isDirectory)).path
    } catch {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage root record is not canonical")
    }
    guard document.rootPath == canonical else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage root record is not canonical")
    }
    guard document.rootKind != "default" || document.rootPath == defaultSessionsRoot.path else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage default root record drifted")
    }
    do {
      try validate(document.policy)
    } catch {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage policy record is invalid")
    }
  }

  private func validate(_ policy: RuntimeSessionStoragePolicy) throws {
    guard policy.totalQuotaBytes > policy.safetyMarginBytes,
      policy.safetyMarginBytes > 0,
      policy.retentionDays > 0,
      policy.totalQuotaBytes <= UInt64(Int64.max),
      policy.safetyMarginBytes <= UInt64(Int64.max),
      policy.retentionDays <= UInt64(Int64.max)
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session storage policy is outside its published bounds")
    }
  }

  private func activeRoot(
    _ document: Document,
    createDefaultIfMissing: Bool
  ) throws -> URL {
    do {
      let root = try Self.canonicalRoot(
        URL(filePath: document.rootPath, directoryHint: .isDirectory))
      if document.rootKind == "default", createDefaultIfMissing {
        try Self.ensureDirectory(root)
      }
      try requireDisjointFromOwner(root)
      try Self.requireSafeWritableRoot(root)
      return root
    } catch let failure as RuntimeSessionStorageFailure where failure.code == "invalidInput" {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "configured Session storage root is unavailable")
    }
  }

  private func requireDisjointFromOwner(_ root: URL) throws {
    func contains(_ ancestor: String, _ candidate: String) -> Bool {
      if ancestor == "/" { return true }
      return candidate == ancestor || candidate.hasPrefix(ancestor + "/")
    }
    guard !contains(root.path, ownerRoot.path), !contains(ownerRoot.path, root.path) else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root must be disjoint from Runtime state")
    }
  }

  private static func requireOwnerDirectory(_ url: URL) throws {
    try ensureDirectory(url)
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "Session storage owner directory cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    try validateOwnedDirectory(descriptor, label: "Session storage owner")
  }

  private static func ensureDirectory(_ url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session storage directory cannot be created")
    }
  }

  private static func canonicalRoot(_ url: URL) throws -> URL {
    guard url.isFileURL, url.path.hasPrefix("/"),
      url.path.utf8.count <= maximumRootPathBytes
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root must be one bounded absolute path")
    }
    return url.resolvingSymlinksInPath().standardizedFileURL
  }

  private static func requireSafeWritableRoot(_ url: URL) throws {
    var pathMetadata = stat()
    guard Darwin.lstat(url.path, &pathMetadata) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFDIR,
      pathMetadata.st_uid == geteuid(),
      pathMetadata.st_mode & (S_IRUSR | S_IWUSR | S_IXUSR)
        == (S_IRUSR | S_IWUSR | S_IXUSR),
      pathMetadata.st_mode & 0o077 == 0
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root ownership or permissions are unsafe")
    }
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root cannot be opened")
    }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_dev == pathMetadata.st_dev, opened.st_ino == pathMetadata.st_ino
    else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root changed while being opened")
    }
    let probeName = ".arkdeck-runtime-storage-probe-\(UUID().uuidString.lowercased())"
    let probe = Darwin.openat(
      descriptor, probeName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard probe >= 0 else {
      throw RuntimeSessionStorageFailure(
        "invalidInput", "Session root is not writable by the Runtime owner")
    }
    var probeOpen = true
    defer {
      if probeOpen { Darwin.close(probe) }
      _ = Darwin.unlinkat(descriptor, probeName, 0)
    }
    guard Darwin.close(probe) == 0 else {
      probeOpen = false
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session root write probe could not be closed")
    }
    probeOpen = false
    guard Darwin.unlinkat(descriptor, probeName, 0) == 0 else {
      throw RuntimeSessionStorageFailure(
        "ioFailure", "Session root write probe could not be removed")
    }
  }

  private static func validateOwnedDirectory(_ descriptor: Int32, label: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "\(label) ownership or permissions are unsafe")
    }
  }

  private static func validateOwnedRegularFile(_ descriptor: Int32, label: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & 0o077 == 0
    else {
      throw RuntimeSessionStorageFailure(
        "recordUnreadable", "\(label) ownership or permissions are unsafe")
    }
  }
}
