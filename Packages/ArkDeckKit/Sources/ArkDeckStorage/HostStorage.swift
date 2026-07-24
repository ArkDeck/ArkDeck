import Darwin
import Foundation

public struct VolumeIdentity: Hashable, Codable, Sendable {
  public let value: String

  public init(value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 512 else {
      throw SessionStorageError.volumeUnavailable("invalid volume identity")
    }
    self.value = value
  }
}

public protocol VolumeIdentityResolving: Sendable {
  func resolve(_ url: URL) throws -> VolumeIdentity
  func resolve(openFileDescriptor descriptor: Int32) throws -> VolumeIdentity
}

public struct SystemVolumeIdentityResolver: VolumeIdentityResolving {
  public init() {}

  public func resolve(_ url: URL) throws -> VolumeIdentity {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw SessionStorageError.volumeUnavailable("\(url.path):errno=\(errno)")
    }
    defer { Darwin.close(descriptor) }
    return try resolve(openFileDescriptor: descriptor)
  }

  public func resolve(openFileDescriptor descriptor: Int32) throws -> VolumeIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw SessionStorageError.volumeUnavailable("descriptor:errno=\(errno)")
    }
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.volattr = UInt32(ATTR_VOL_UUID)
    var buffer = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + 16)
    if fgetattrlist(descriptor, &attributes, &buffer, buffer.count, 0) == 0,
      buffer.withUnsafeBytes({ $0.load(as: UInt32.self) }) == buffer.count
    {
      let uuid = buffer.withUnsafeBytes { rawBuffer -> UUID in
        let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
          .advanced(by: MemoryLayout<UInt32>.size)
        return NSUUID(uuidBytes: bytes) as UUID
      }
      return try VolumeIdentity(value: "uuid:\(uuid.uuidString.lowercased())")
    }
    let device = UInt64(UInt32(bitPattern: metadata.st_dev))
    // A device number is only a same-mount grouping key. Unlike a volume UUID it can be reused
    // after unmount/remount, so the coordinator treats this identity as unverified at revalidation.
    return try VolumeIdentity(value: "dev-unverified:\(device)")
  }
}

public struct HostStorageSnapshot: Equatable, Sendable {
  public let volumeIdentity: VolumeIdentity
  public let totalBytes: UInt64
  public let availableBytes: UInt64
  public let isReadOnly: Bool

  public init(
    volumeIdentity: VolumeIdentity,
    totalBytes: UInt64,
    availableBytes: UInt64,
    isReadOnly: Bool
  ) {
    self.volumeIdentity = volumeIdentity
    self.totalBytes = totalBytes
    self.availableBytes = availableBytes
    self.isReadOnly = isReadOnly
  }
}

public protocol HostStorageProbing: Sendable {
  func snapshot(for url: URL) throws -> HostStorageSnapshot
}

public struct SystemHostStorageProbe: HostStorageProbing {
  private let resolver: any VolumeIdentityResolving

  public init(resolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver()) {
    self.resolver = resolver
  }

  public func snapshot(for url: URL) throws -> HostStorageSnapshot {
    let identity = try resolver.resolve(url)
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
    guard let total = (attributes[.systemSize] as? NSNumber)?.uint64Value,
      let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
    else { throw SessionStorageError.volumeUnavailable("capacity unavailable: \(url.path)") }

    var status = statfs()
    guard statfs(url.path, &status) == 0 else {
      throw SessionStorageError.volumeUnavailable("statfs:\(url.path):errno=\(errno)")
    }
    return HostStorageSnapshot(
      volumeIdentity: identity,
      totalBytes: total,
      availableBytes: available,
      isReadOnly: status.f_flags & UInt32(MNT_RDONLY) != 0
    )
  }
}

public enum StorageWriterClass: String, Codable, Sendable {
  case heavy
  case light
  case unknown
}

public struct StorageBudget: Equatable, Sendable {
  public let metadataHeadroomBytes: UInt64
  public let finalizationHeadroomBytes: UInt64
  public let remainingGrowthBytes: UInt64
  public let writerClass: StorageWriterClass

  public init(
    metadataHeadroomBytes: UInt64,
    finalizationHeadroomBytes: UInt64,
    remainingGrowthBytes: UInt64,
    writerClass: StorageWriterClass
  ) throws {
    guard metadataHeadroomBytes > 0, finalizationHeadroomBytes > 0,
      writerClass != .unknown || remainingGrowthBytes > 0
    else {
      throw SessionStorageError.invalidRecord("metadata/finalization headroom must be positive")
    }
    _ = try SessionStorageValidation.addingWithoutOverflow(
      try SessionStorageValidation.addingWithoutOverflow(
        metadataHeadroomBytes, finalizationHeadroomBytes),
      remainingGrowthBytes)
    self.metadataHeadroomBytes = metadataHeadroomBytes
    self.finalizationHeadroomBytes = finalizationHeadroomBytes
    self.remainingGrowthBytes = remainingGrowthBytes
    self.writerClass = writerClass
  }

  public var totalSoftClaimBytes: UInt64 {
    metadataHeadroomBytes + finalizationHeadroomBytes + remainingGrowthBytes
  }

  public var abortsWhenGrowthExceedsBudget: Bool { true }
}

public struct StorageClaimRequest: Equatable, Sendable {
  public let claimID: String
  public let jobID: String
  public let volumeIdentity: VolumeIdentity
  public let budget: StorageBudget

  public init(
    claimID: String,
    jobID: String,
    volumeIdentity: VolumeIdentity,
    budget: StorageBudget
  ) throws {
    try SessionStorageValidation.identifier(claimID, field: "claimId")
    try SessionStorageValidation.identifier(jobID, field: "jobId")
    self.claimID = claimID
    self.jobID = jobID
    self.volumeIdentity = volumeIdentity
    self.budget = budget
  }
}

private struct StorageClaimSessionBinding: Equatable {
  let sessionID: String
  let rootPath: String
}

struct StorageClaimSessionRootOwnership: Equatable {
  let device: UInt64
  let inode: UInt64

  init(metadata: stat) {
    device = UInt64(UInt32(bitPattern: metadata.st_dev))
    inode = UInt64(metadata.st_ino)
  }
}

struct StorageClaimSessionCreationContext {
  let isRepair: Bool
  let expectedRootOwnership: StorageClaimSessionRootOwnership?
}

struct StorageClaimSessionCreationProgress {
  var rootCreated: Bool
  var rootOwnership: StorageClaimSessionRootOwnership?
}

private struct StorageClaimOwnedSessionBinding: Equatable {
  let binding: StorageClaimSessionBinding
  let rootOwnership: StorageClaimSessionRootOwnership
}

private enum StorageClaimSessionBindingState: Equatable {
  case unbound
  case provisional(StorageClaimSessionBinding)
  case committed(StorageClaimOwnedSessionBinding)
  case failed(StorageClaimOwnedSessionBinding)
}

private final class StorageClaimPermit: @unchecked Sendable {
  private let lock = NSLock()
  private var active = true
  private var finalizationOnly = false
  private var sessionBindingState = StorageClaimSessionBindingState.unbound
  private var pendingTerminalDisposition: StorageTerminalDisposition?
  private var completedTerminalReceipt: StorageTerminalPersistenceReceipt?
  private let maximumGrowthBytes: UInt64
  private var remainingGrowthBytes: UInt64

  init(remainingGrowthBytes: UInt64) {
    maximumGrowthBytes = remainingGrowthBytes
    self.remainingGrowthBytes = remainingGrowthBytes
  }

  func requireOptionalWriteAuthorization(claimID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard !finalizationOnly else { throw SessionStorageError.optionalWritesStopped(claimID) }
  }

  func performSessionCreation<T>(
    claimID: String,
    binding: StorageClaimSessionBinding,
    body: (
      StorageClaimSessionCreationContext,
      inout StorageClaimSessionCreationProgress
    ) throws -> T
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard !finalizationOnly else { throw SessionStorageError.optionalWritesStopped(claimID) }
    let context: StorageClaimSessionCreationContext
    var progress: StorageClaimSessionCreationProgress
    switch sessionBindingState {
    case .unbound:
      context = StorageClaimSessionCreationContext(
        isRepair: false, expectedRootOwnership: nil)
      progress = StorageClaimSessionCreationProgress(
        rootCreated: false, rootOwnership: nil)
    case .failed(let ownedBinding) where ownedBinding.binding == binding:
      context = StorageClaimSessionCreationContext(
        isRepair: true, expectedRootOwnership: ownedBinding.rootOwnership)
      progress = StorageClaimSessionCreationProgress(
        rootCreated: true, rootOwnership: ownedBinding.rootOwnership)
    default:
      throw SessionStorageError.invalidRecord(
        "storage claim is already bound to a Session creation attempt")
    }
    sessionBindingState = .provisional(binding)
    do {
      let result = try body(context, &progress)
      guard progress.rootCreated, let rootOwnership = progress.rootOwnership else {
        throw SessionStorageError.invalidRecord(
          "Session creation completed without owned root identity")
      }
      sessionBindingState = .committed(
        StorageClaimOwnedSessionBinding(
          binding: binding, rootOwnership: rootOwnership))
      return result
    } catch {
      if progress.rootCreated, let rootOwnership = progress.rootOwnership {
        // Only this exact claim can repair the root that it successfully created. Until repair
        // completes, Artifact and terminal persistence continue to reject the failed binding.
        sessionBindingState = .failed(
          StorageClaimOwnedSessionBinding(
            binding: binding, rootOwnership: rootOwnership))
      } else {
        // No Session root was created by this permit, or creation failed before an owned root
        // identity could be captured. This includes a racing EEXIST loser and initial-volume/
        // preflight failures. End the unusable permit so coordinator accounting and heavy-writer
        // admission recover without accepting persistence for an unproven root.
        sessionBindingState = .unbound
        active = false
        remainingGrowthBytes = 0
      }
      throw error
    }
  }

  func requireSessionBinding(
    claimID: String,
    binding: StorageClaimSessionBinding,
    rootMetadata: stat
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard case .committed(let ownedBinding) = sessionBindingState,
      ownedBinding.binding == binding,
      StorageClaimSessionRootOwnership(metadata: rootMetadata) == ownedBinding.rootOwnership
    else {
      throw SessionStorageError.invalidRecord(
        "persistence does not match the claim-bound Session root")
    }
  }

  func requireSessionBinding(
    claimID: String,
    binding: StorageClaimSessionBinding
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard case .committed(let ownedBinding) = sessionBindingState,
      ownedBinding.binding == binding,
      rootOwnership(atPath: binding.rootPath) == ownedBinding.rootOwnership
    else {
      if case .failed(let failedBinding) = sessionBindingState,
        failedBinding.binding == binding
      {
        throw SessionStorageError.invalidRecord(
          "Session creation is incomplete and requires repair before persistence")
      }
      throw SessionStorageError.invalidRecord(
        "persistence does not match the claim-bound Session root")
    }
  }

  func requireFinalizationAuthorization(
    claimID: String,
    disposition: StorageTerminalDisposition? = nil
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard finalizationOnly else {
      throw SessionStorageError.invalidRecord(
        "terminal persistence requires a finalization-only claim")
    }
    if let disposition, let pendingTerminalDisposition,
      disposition != pendingTerminalDisposition
    {
      throw SessionStorageError.invalidRecord(
        "terminal persistence disposition does not match the retained claim")
    }
  }

  func performOptionalWrite<T>(
    claimID: String,
    bytes: UInt64,
    body: () throws -> T
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard !finalizationOnly else { throw SessionStorageError.optionalWritesStopped(claimID) }
    guard bytes <= remainingGrowthBytes else {
      throw SessionStorageError.insufficientSpace(
        required: bytes, available: remainingGrowthBytes)
    }
    remainingGrowthBytes -= bytes
    return try body()
  }

  func reduceRemainingGrowth(claimID: String, to remainingBytes: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard remainingBytes <= remainingGrowthBytes else {
      throw SessionStorageError.invalidRecord(
        "remaining growth increase requires a new capacity admission")
    }
    guard !finalizationOnly || remainingBytes == 0 else {
      throw SessionStorageError.optionalWritesStopped(claimID)
    }
    remainingGrowthBytes = remainingBytes
  }

  func refundOptionalWrite(claimID: String, bytes: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard active else { throw SessionStorageError.claimUnavailable(claimID) }
    guard !finalizationOnly else { throw SessionStorageError.optionalWritesStopped(claimID) }
    let refundable = min(bytes, maximumGrowthBytes - remainingGrowthBytes)
    remainingGrowthBytes += refundable
  }

  func stopOptionalWrites(disposition: StorageTerminalDisposition? = nil) {
    lock.lock()
    finalizationOnly = true
    remainingGrowthBytes = 0
    if let disposition {
      if pendingTerminalDisposition == nil {
        pendingTerminalDisposition = disposition
      }
    }
    lock.unlock()
  }

  func isFinalizationOnly() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return finalizationOnly
  }

  func remainingGrowth() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return remainingGrowthBytes
  }

  func completeTerminalPersistence(
    _ receipt: StorageTerminalPersistenceReceipt,
    claimID: String,
    jobID: String,
    admissionGeneration: UUID,
    volumeIdentity: VolumeIdentity
  ) throws -> ResourceReleaseDisposition {
    lock.lock()
    defer { lock.unlock() }
    if let completedTerminalReceipt {
      guard completedTerminalReceipt == receipt else {
        throw SessionStorageError.invalidRecord(
          "terminal persistence receipt conflicts with completed claim")
      }
      return .alreadyReleased
    }
    guard active, finalizationOnly, let pendingTerminalDisposition else {
      throw SessionStorageError.claimUnavailable(claimID)
    }
    guard case .committed(let ownedBinding) = sessionBindingState,
      receipt.sessionID == ownedBinding.binding.sessionID,
      receipt.sessionRootPath == ownedBinding.binding.rootPath,
      rootOwnership(atPath: ownedBinding.binding.rootPath) == ownedBinding.rootOwnership
    else {
      throw SessionStorageError.invalidRecord(
        "terminal persistence receipt does not match the claim-bound Session root")
    }
    guard receipt.claimID == claimID, receipt.jobID == jobID,
      receipt.admissionGeneration == admissionGeneration,
      receipt.volumeIdentity == volumeIdentity,
      receipt.disposition == pendingTerminalDisposition
    else { throw SessionStorageError.invalidRecord("terminal persistence receipt mismatch") }
    active = false
    remainingGrowthBytes = 0
    completedTerminalReceipt = receipt
    return .releasedNow
  }

  func isActive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  func terminalReceipt() -> StorageTerminalPersistenceReceipt? {
    lock.lock()
    defer { lock.unlock() }
    return completedTerminalReceipt
  }

  func bindingState() -> StorageClaimSessionBindingState {
    lock.lock()
    defer { lock.unlock() }
    return sessionBindingState
  }

  func currentSessionBinding() -> StorageClaimSessionBinding? {
    lock.lock()
    defer { lock.unlock() }
    switch sessionBindingState {
    case .unbound:
      return nil
    case .provisional(let binding):
      return binding
    case .committed(let owned), .failed(let owned):
      return owned.binding
    }
  }

  private func rootOwnership(atPath path: String) -> StorageClaimSessionRootOwnership? {
    var metadata = stat()
    guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      return nil
    }
    return StorageClaimSessionRootOwnership(metadata: metadata)
  }
}

public struct StorageClaim: Equatable, @unchecked Sendable {
  public let claimID: String
  public let jobID: String
  public let volumeIdentity: VolumeIdentity
  public let writerClass: StorageWriterClass
  public let metadataHeadroomBytes: UInt64
  public let finalizationHeadroomBytes: UInt64
  fileprivate let admissionGeneration: UUID
  fileprivate let permit: StorageClaimPermit

  fileprivate init(request: StorageClaimRequest) {
    claimID = request.claimID
    jobID = request.jobID
    volumeIdentity = request.volumeIdentity
    writerClass = request.budget.writerClass
    metadataHeadroomBytes = request.budget.metadataHeadroomBytes
    finalizationHeadroomBytes = request.budget.finalizationHeadroomBytes
    admissionGeneration = UUID()
    permit = StorageClaimPermit(remainingGrowthBytes: request.budget.remainingGrowthBytes)
  }

  public var remainingGrowthBytes: UInt64 { permit.remainingGrowth() }

  public var totalSoftClaimBytes: UInt64 {
    metadataHeadroomBytes + finalizationHeadroomBytes + remainingGrowthBytes
  }

  public var finalizationOnly: Bool { permit.isFinalizationOnly() }

  func requireOptionalWriteAuthorization(forJobID jobID: String) throws {
    guard self.jobID == jobID else {
      throw SessionStorageError.claimUnavailable("\(claimID):job-mismatch")
    }
    try permit.requireOptionalWriteAuthorization(claimID: claimID)
  }

  func performOptionalWrite<T>(
    bytes: UInt64,
    forJobID jobID: String,
    body: () throws -> T
  ) throws -> T {
    guard self.jobID == jobID else {
      throw SessionStorageError.claimUnavailable("\(claimID):job-mismatch")
    }
    return try permit.performOptionalWrite(claimID: claimID, bytes: bytes, body: body)
  }

  func performSessionCreation<T>(
    layout: SessionLayout,
    body: (
      StorageClaimSessionCreationContext,
      inout StorageClaimSessionCreationProgress
    ) throws -> T
  ) throws -> T {
    guard jobID == layout.jobID else {
      throw SessionStorageError.claimUnavailable("\(claimID):job-mismatch")
    }
    return try permit.performSessionCreation(
      claimID: claimID,
      binding: StorageClaimSessionBinding(
        sessionID: layout.sessionID, rootPath: layout.root.standardizedFileURL.path),
      body: body)
  }

  func requireSessionBinding(sessionID: String, root: URL) throws {
    try permit.requireSessionBinding(
      claimID: claimID,
      binding: StorageClaimSessionBinding(
        sessionID: sessionID, rootPath: root.standardizedFileURL.path))
  }

  /// Joins the claim's committed root ownership to an already-opened root descriptor, closing
  /// the window where path-based rechecks and descriptor-anchored operations could observe
  /// different directories.
  func requireSessionBinding(sessionID: String, root: URL, rootDescriptor: Int32) throws {
    var metadata = stat()
    guard fstat(rootDescriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      throw SessionStorageError.writeFailed(path: root.path, errno: errno)
    }
    try permit.requireSessionBinding(
      claimID: claimID,
      binding: StorageClaimSessionBinding(
        sessionID: sessionID, rootPath: root.standardizedFileURL.path),
      rootMetadata: metadata)
  }

  func requireReceiptSessionBinding(_ receipt: StorageTerminalPersistenceReceipt) throws {
    try requireSessionBinding(
      sessionID: receipt.sessionID, root: URL(filePath: receipt.sessionRootPath))
  }

  func reduceRemainingGrowth(to remainingBytes: UInt64) throws {
    try permit.reduceRemainingGrowth(claimID: claimID, to: remainingBytes)
  }

  func refundOptionalWrite(bytes: UInt64) throws {
    try permit.refundOptionalWrite(claimID: claimID, bytes: bytes)
  }

  func beginFinalization(_ disposition: StorageTerminalDisposition) {
    permit.stopOptionalWrites(disposition: disposition)
  }

  func requireFinalizationAuthorization(
    for disposition: StorageTerminalDisposition? = nil
  ) throws {
    try permit.requireFinalizationAuthorization(
      claimID: claimID, disposition: disposition)
  }

  func completeTerminalPersistence(
    _ receipt: StorageTerminalPersistenceReceipt
  ) throws -> ResourceReleaseDisposition {
    try permit.completeTerminalPersistence(
      receipt, claimID: claimID, jobID: jobID,
      admissionGeneration: admissionGeneration, volumeIdentity: volumeIdentity)
  }

  var isActive: Bool { permit.isActive() }

  var completedTerminalReceipt: StorageTerminalPersistenceReceipt? {
    permit.terminalReceipt()
  }

  public static func == (lhs: StorageClaim, rhs: StorageClaim) -> Bool {
    lhs.claimID == rhs.claimID && lhs.jobID == rhs.jobID
      && lhs.admissionGeneration == rhs.admissionGeneration
      && lhs.volumeIdentity == rhs.volumeIdentity && lhs.writerClass == rhs.writerClass
      && lhs.metadataHeadroomBytes == rhs.metadataHeadroomBytes
      && lhs.finalizationHeadroomBytes == rhs.finalizationHeadroomBytes
      && lhs.remainingGrowthBytes == rhs.remainingGrowthBytes
      && lhs.finalizationOnly == rhs.finalizationOnly
      && lhs.permit.bindingState() == rhs.permit.bindingState()
  }
}

public enum StorageQueueReason: String, Equatable, Sendable {
  case waitingForStorage
  case insufficientHeadroom
  case volumeReadOnly
}

public enum StorageAdmission: Equatable, Sendable {
  case admitted(StorageClaim)
  case queued(StorageQueueReason)
}

public struct ActiveStorageSessionSnapshot: Equatable, Sendable {
  public let claimID: String
  public let jobID: String
  public let sessionID: String
  public let sessionRoot: URL
  public let volumeIdentity: VolumeIdentity
  public let writerClass: StorageWriterClass

  fileprivate init(claim: StorageClaim, binding: StorageClaimSessionBinding) {
    claimID = claim.claimID
    jobID = claim.jobID
    sessionID = binding.sessionID
    sessionRoot = URL(filePath: binding.rootPath).standardizedFileURL
    volumeIdentity = claim.volumeIdentity
    writerClass = claim.writerClass
  }
}

public enum StorageRevalidationAction: Equatable, Sendable {
  case continueWriting
  case stopOptionalWritesAndFinalize
  case pauseForVolumeIdentityChange(expected: VolumeIdentity, actual: VolumeIdentity)
  case volumeUnavailable
}

public enum StorageClaimExecution<Value: Sendable>: Sendable {
  case executed(Value)
  case queued(StorageQueueReason)
}

public struct StorageOperationFinalizationError: Error, @unchecked Sendable {
  public let operationError: any Error
  public let finalizationError: any Error

  public init(operationError: any Error, finalizationError: any Error) {
    self.operationError = operationError
    self.finalizationError = finalizationError
  }
}

public enum StorageTerminalDisposition: String, Equatable, Sendable {
  case succeeded
  case failed
  case cancelled
}

public struct StorageTerminalPersistenceReceipt: Equatable, Sendable {
  public let claimID: String
  public let jobID: String
  public let disposition: StorageTerminalDisposition
  public let manifestSHA256: String
  fileprivate let admissionGeneration: UUID
  fileprivate let sessionID: String
  fileprivate let sessionRootPath: String
  fileprivate let volumeIdentity: VolumeIdentity
}

private final class RepairedTerminalStorageClaimReleaser: StorageClaimReleasing,
  @unchecked Sendable
{
  private let claim: StorageClaim
  private let receipt: StorageTerminalPersistenceReceipt

  init(claim: StorageClaim, receipt: StorageTerminalPersistenceReceipt) {
    self.claim = claim
    self.receipt = receipt
  }

  func ensureStorageClaimReleased() throws -> ResourceReleaseDisposition {
    try claim.completeTerminalPersistence(receipt)
  }
}

public struct SessionStorageTerminalFinalizer: Sendable {
  private let audit: any DurableSessionAuditAppending
  private let manifestPublisher: any SessionManifestPublishing
  private let volumeIdentityResolver: any VolumeIdentityResolving

  public init(
    audit: any DurableSessionAuditAppending,
    manifestPublisher: any SessionManifestPublishing,
    volumeIdentityResolver: any VolumeIdentityResolving = SystemVolumeIdentityResolver()
  ) {
    self.audit = audit
    self.manifestPublisher = manifestPublisher
    self.volumeIdentityResolver = volumeIdentityResolver
  }

  public func persist(
    claim: StorageClaim,
    disposition: StorageTerminalDisposition,
    auditRecord: SessionAuditRecord,
    manifest: SessionManifestDocument
  ) throws -> StorageTerminalPersistenceReceipt {
    try claim.requireFinalizationAuthorization(for: disposition)
    guard auditRecord.jobID == claim.jobID, manifest.jobID == claim.jobID,
      auditRecord.sessionID == manifest.sessionID
    else {
      throw SessionStorageError.invalidRecord("terminal persistence Job/claim mismatch")
    }
    let allowedStatus: Bool
    switch disposition {
    case .succeeded:
      allowedStatus = manifest.status == "succeeded"
    case .failed:
      allowedStatus = ["failed", "interrupted"].contains(manifest.status)
    case .cancelled:
      allowedStatus = manifest.status == "cancelled"
    }
    guard allowedStatus, auditRecord.category == .outcome else {
      throw SessionStorageError.invalidRecord("terminal persistence disposition mismatch")
    }
    try validateStorageLocation(claim: claim, sessionID: manifest.sessionID)
    try audit.appendAndSynchronize(auditRecord)
    try validateStorageLocation(claim: claim, sessionID: manifest.sessionID)
    let published = try manifestPublisher.publish(manifest)
    try validateStorageLocation(claim: claim, sessionID: manifest.sessionID)
    return StorageTerminalPersistenceReceipt(
      claimID: claim.claimID, jobID: claim.jobID, disposition: disposition,
      manifestSHA256: published.sha256,
      admissionGeneration: claim.admissionGeneration,
      sessionID: manifest.sessionID,
      sessionRootPath: audit.layout.root.standardizedFileURL.path,
      volumeIdentity: claim.volumeIdentity)
  }

  private func validateStorageLocation(claim: StorageClaim, sessionID: String) throws {
    let auditLayout = audit.layout
    let manifestLayout = manifestPublisher.layout
    guard auditLayout.sessionID == sessionID, manifestLayout.sessionID == sessionID,
      auditLayout.jobID == claim.jobID, manifestLayout.jobID == claim.jobID,
      auditLayout.root.standardizedFileURL == manifestLayout.root.standardizedFileURL
    else {
      throw SessionStorageError.invalidRecord(
        "terminal audit and manifest must share the claimed Session root")
    }
    try claim.requireSessionBinding(sessionID: sessionID, root: auditLayout.root)
    for actual in [
      try audit.storageVolumeIdentity(using: volumeIdentityResolver),
      try manifestPublisher.storageVolumeIdentity(using: volumeIdentityResolver),
    ] {
      guard actual == claim.volumeIdentity else {
        throw SessionStorageError.volumeIdentityChanged(
          expected: claim.volumeIdentity, actual: actual)
      }
    }
  }
}

public actor HostStorageCoordinator {
  private var claims: [String: StorageClaim] = [:]
  private var completedTerminalReceipts: [String: StorageTerminalPersistenceReceipt] = [:]
  private var completedTerminalReceiptOrder: [String] = []
  private let completedTerminalReceiptLimit: Int
  private var retentionBlockedVolumes: Set<VolumeIdentity> = []
  private var conservativeRetentionBlockedVolumes: Set<VolumeIdentity> = []

  public init(completedReceiptCacheLimit: Int = 256) {
    completedTerminalReceiptLimit = max(1, completedReceiptCacheLimit)
  }

  public func admit(_ request: StorageClaimRequest, snapshot: HostStorageSnapshot)
    -> StorageAdmission
  {
    purgeCompletedClaims()
    guard request.volumeIdentity == snapshot.volumeIdentity else {
      return .queued(.waitingForStorage)
    }
    guard !snapshot.isReadOnly else { return .queued(.volumeReadOnly) }
    guard claims[request.claimID] == nil else { return .queued(.waitingForStorage) }
    if retentionBlockedVolumes.contains(request.volumeIdentity)
      || conservativeRetentionBlockedVolumes.contains(request.volumeIdentity),
      request.budget.writerClass != .light
    {
      return .queued(.insufficientHeadroom)
    }

    let sameVolume = claims.values.filter { $0.volumeIdentity == request.volumeIdentity }
    let hasUnknown = sameVolume.contains { $0.writerClass == .unknown }
    let hasAnyWriter = !sameVolume.isEmpty
    let hasHeavy = sameVolume.contains { $0.writerClass == .heavy }
    switch request.budget.writerClass {
    case .heavy where hasHeavy || hasUnknown:
      return .queued(.waitingForStorage)
    case .unknown where hasAnyWriter:
      return .queued(.waitingForStorage)
    case .light where hasUnknown:
      return .queued(.waitingForStorage)
    default:
      break
    }

    let existingBytes = sameVolume.reduce(UInt64(0)) { partial, claim in
      SessionStorageValidation.saturatingAdd(partial, claim.totalSoftClaimBytes)
    }
    let required = existingBytes.addingReportingOverflow(request.budget.totalSoftClaimBytes)
    guard !required.overflow, required.partialValue <= snapshot.availableBytes else {
      return .queued(.insufficientHeadroom)
    }
    // A claim ID is an external correlation label, not a capability. A successful new admission
    // starts a distinct generation and supersedes only the coordinator's idempotency cache for
    // the older generation; stale receipts remain unable to complete the new permit.
    removeCompletedReceipt(forKey: request.claimID)
    let claim = StorageClaim(request: request)
    claims[claim.claimID] = claim
    return .admitted(claim)
  }

  public func updateRemainingGrowth(claimID: String, remainingBytes: UInt64) throws {
    purgeCompletedClaims()
    guard let claim = claims[claimID] else {
      throw SessionStorageError.invalidRecord("unknown claim: \(claimID)")
    }
    try claim.reduceRemainingGrowth(to: remainingBytes)
  }

  public func revalidate(
    claimID: String,
    current snapshot: HostStorageSnapshot
  ) -> StorageRevalidationAction {
    purgeCompletedClaims()
    guard let claim = claims[claimID] else { return .volumeUnavailable }
    guard snapshot.volumeIdentity == claim.volumeIdentity else {
      claim.permit.stopOptionalWrites()
      return .pauseForVolumeIdentityChange(
        expected: claim.volumeIdentity, actual: snapshot.volumeIdentity)
    }
    // st_dev cannot prove that an unmounted volume was not replaced by another filesystem that
    // reused the same device number. Refuse runtime continuation when no stable UUID is available.
    guard !claim.volumeIdentity.value.hasPrefix("dev-unverified:") else {
      claim.permit.stopOptionalWrites()
      return .volumeUnavailable
    }
    if claim.finalizationOnly { return .stopOptionalWritesAndFinalize }
    guard !snapshot.isReadOnly else {
      claim.permit.stopOptionalWrites()
      return .stopOptionalWritesAndFinalize
    }
    let reservedOnVolume = claims.values
      .filter { $0.volumeIdentity == claim.volumeIdentity }
      .reduce(UInt64(0)) { partial, current in
        SessionStorageValidation.saturatingAdd(partial, current.totalSoftClaimBytes)
      }
    guard snapshot.availableBytes >= reservedOnVolume else {
      claim.permit.stopOptionalWrites()
      return .stopOptionalWritesAndFinalize
    }
    return .continueWriting
  }

  public func reportWriteFailure(
    claimID: String,
    errno _: Int32,
    terminalDisposition: StorageTerminalDisposition? = nil
  )
    -> StorageRevalidationAction
  {
    purgeCompletedClaims()
    guard let claim = claims[claimID] else { return .volumeUnavailable }
    // Callers that already know the terminal outcome may bind it here so a later repaired receipt
    // can release the retained headroom. Omitting it preserves capacity-only revalidation, where
    // the enclosing operation still determines success/failure/cancellation.
    claim.permit.stopOptionalWrites(disposition: terminalDisposition)
    return .stopOptionalWritesAndFinalize
  }

  public func updateRetentionAdmission(
    _ plan: SessionRetentionPlan,
    on volume: VolumeIdentity
  ) {
    setRetentionAdmission(blocked: plan.blocksNewHeavyWriters, on: volume)
  }

  public func setRetentionAdmission(blocked: Bool, on volume: VolumeIdentity) {
    if blocked {
      retentionBlockedVolumes.insert(volume)
    } else {
      retentionBlockedVolumes.remove(volume)
    }
  }

  public func retentionAdmissionIsBlocked(on volume: VolumeIdentity) -> Bool {
    retentionBlockedVolumes.contains(volume)
      || conservativeRetentionBlockedVolumes.contains(volume)
  }

  public func requireConservativeRetentionBlock(on volume: VolumeIdentity) {
    conservativeRetentionBlockedVolumes.insert(volume)
  }

  public func clearConservativeRetentionBlockAfterSuccessfulRescan(
    on volume: VolumeIdentity
  ) {
    conservativeRetentionBlockedVolumes.remove(volume)
  }

  private func release(
    _ claim: StorageClaim,
    receipt: StorageTerminalPersistenceReceipt
  ) throws {
    _ = try claim.completeTerminalPersistence(receipt)
    claims.removeValue(forKey: claim.claimID)
    rememberCompletedReceipt(receipt)
  }

  private func purgeCompletedClaims() {
    for (claimID, claim) in claims where !claim.isActive {
      if let receipt = claim.completedTerminalReceipt {
        rememberCompletedReceipt(receipt)
      }
      claims.removeValue(forKey: claimID)
    }
  }

  private func rememberCompletedReceipt(_ receipt: StorageTerminalPersistenceReceipt) {
    removeCompletedReceipt(forKey: receipt.claimID)
    completedTerminalReceipts[receipt.claimID] = receipt
    completedTerminalReceiptOrder.append(receipt.claimID)
    while completedTerminalReceiptOrder.count > completedTerminalReceiptLimit {
      let evictedClaimID = completedTerminalReceiptOrder.removeFirst()
      completedTerminalReceipts.removeValue(forKey: evictedClaimID)
    }
  }

  private func removeCompletedReceipt(forKey claimID: String) {
    completedTerminalReceipts.removeValue(forKey: claimID)
    completedTerminalReceiptOrder.removeAll { $0 == claimID }
  }

  private func touchCompletedReceipt(forKey claimID: String) {
    guard completedTerminalReceipts[claimID] != nil else { return }
    completedTerminalReceiptOrder.removeAll { $0 == claimID }
    completedTerminalReceiptOrder.append(claimID)
  }

  public func performWithClaim<Value: Sendable>(
    request: StorageClaimRequest,
    snapshot: HostStorageSnapshot,
    operation: @Sendable (StorageClaim) async throws -> Value,
    finalize:
      @escaping @Sendable (StorageClaim, StorageTerminalDisposition) async throws
      -> StorageTerminalPersistenceReceipt
  ) async throws -> StorageClaimExecution<Value> {
    let admission = admit(request, snapshot: snapshot)
    guard case .admitted(let claim) = admission else {
      guard case .queued(let reason) = admission else { return .queued(.waitingForStorage) }
      return .queued(reason)
    }
    let value: Value
    do {
      value = try await operation(claim)
    } catch {
      let operationError = error
      let disposition: StorageTerminalDisposition =
        operationError is CancellationError ? .cancelled : .failed
      claim.beginFinalization(disposition)
      // Cancellation belongs to the operation. Terminal persistence must run in an uncancelled
      // task, and a failed finalizer deliberately leaves the claim/headroom active for recovery.
      let receipt: StorageTerminalPersistenceReceipt
      do {
        receipt = try await Task.detached {
          try await finalize(claim, disposition)
        }.value
        try validateTerminalReceipt(receipt, claim: claim, disposition: disposition)
      } catch {
        throw StorageOperationFinalizationError(
          operationError: operationError, finalizationError: error)
      }
      try release(claim, receipt: receipt)
      throw operationError
    }
    claim.beginFinalization(.succeeded)
    let receipt = try await Task.detached {
      try await finalize(claim, .succeeded)
    }.value
    try validateTerminalReceipt(receipt, claim: claim, disposition: .succeeded)
    try release(claim, receipt: receipt)
    return .executed(value)
  }

  /// Completes a retained finalization-only claim after terminal persistence has been repaired.
  /// The receipt is minted by `SessionStorageTerminalFinalizer`, and must match the claim's
  /// pending Job and terminal disposition before any headroom is released.
  public func completeRecoveredFinalization(
    _ receipt: StorageTerminalPersistenceReceipt
  ) throws -> ResourceReleaseDisposition {
    purgeCompletedClaims()
    if let completed = completedTerminalReceipts[receipt.claimID] {
      guard completed == receipt else {
        throw SessionStorageError.invalidRecord(
          "terminal persistence receipt conflicts with completed claim")
      }
      touchCompletedReceipt(forKey: receipt.claimID)
      return .alreadyReleased
    }
    guard let claim = claims[receipt.claimID] else {
      throw SessionStorageError.claimUnavailable(receipt.claimID)
    }
    guard receipt.jobID == claim.jobID,
      receipt.admissionGeneration == claim.admissionGeneration,
      receipt.volumeIdentity == claim.volumeIdentity
    else {
      throw SessionStorageError.invalidRecord(
        "terminal persistence receipt belongs to a different admission generation")
    }
    let disposition = try claim.completeTerminalPersistence(receipt)
    claims.removeValue(forKey: claim.claimID)
    rememberCompletedReceipt(receipt)
    return disposition
  }

  /// Bridges a repaired terminal receipt into the synchronous recovery release seam delivered by
  /// TASK-M1-003. The adapter remains idempotent; coordinator accounting purges its completed
  /// claim before the next admission, revalidation, or accounting observation.
  public func recoveredFinalizationReleaser(
    _ receipt: StorageTerminalPersistenceReceipt
  ) throws -> any StorageClaimReleasing {
    purgeCompletedClaims()
    if let completed = completedTerminalReceipts[receipt.claimID] {
      guard completed == receipt else {
        throw SessionStorageError.invalidRecord(
          "terminal persistence receipt conflicts with completed claim")
      }
      touchCompletedReceipt(forKey: receipt.claimID)
      return CompletedStorageClaimReleaser()
    }
    guard let claim = claims[receipt.claimID] else {
      throw SessionStorageError.claimUnavailable(receipt.claimID)
    }
    guard receipt.jobID == claim.jobID,
      receipt.admissionGeneration == claim.admissionGeneration,
      receipt.volumeIdentity == claim.volumeIdentity
    else {
      throw SessionStorageError.invalidRecord(
        "terminal persistence receipt belongs to a different admission generation")
    }
    try claim.requireReceiptSessionBinding(receipt)
    return RepairedTerminalStorageClaimReleaser(claim: claim, receipt: receipt)
  }

  public func activeClaimCount(on volume: VolumeIdentity? = nil) -> Int {
    purgeCompletedClaims()
    guard let volume else { return claims.count }
    return claims.values.filter { $0.volumeIdentity == volume }.count
  }

  public func activeSessions(
    on volume: VolumeIdentity? = nil
  ) -> [ActiveStorageSessionSnapshot] {
    purgeCompletedClaims()
    return claims.values.compactMap { claim in
      guard volume == nil || claim.volumeIdentity == volume,
        let binding = claim.permit.currentSessionBinding()
      else { return nil }
      return ActiveStorageSessionSnapshot(claim: claim, binding: binding)
    }.sorted {
      if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
      return $0.claimID < $1.claimID
    }
  }

  public func completedReceiptTombstoneCount() -> Int {
    purgeCompletedClaims()
    return completedTerminalReceipts.count
  }

  public func reservedBytes(on volume: VolumeIdentity) -> UInt64 {
    purgeCompletedClaims()
    return claims.values.filter { $0.volumeIdentity == volume }.reduce(UInt64(0)) {
      SessionStorageValidation.saturatingAdd($0, $1.totalSoftClaimBytes)
    }
  }

  private func validateTerminalReceipt(
    _ receipt: StorageTerminalPersistenceReceipt,
    claim: StorageClaim,
    disposition: StorageTerminalDisposition
  ) throws {
    guard receipt.claimID == claim.claimID, receipt.jobID == claim.jobID,
      receipt.admissionGeneration == claim.admissionGeneration,
      receipt.volumeIdentity == claim.volumeIdentity,
      receipt.disposition == disposition
    else { throw SessionStorageError.invalidRecord("terminal persistence receipt mismatch") }
    try claim.requireReceiptSessionBinding(receipt)
  }
}

private struct CompletedStorageClaimReleaser: StorageClaimReleasing {
  func ensureStorageClaimReleased() throws -> ResourceReleaseDisposition { .alreadyReleased }
}
