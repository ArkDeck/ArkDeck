import ArkDeckCore
import Darwin
import Foundation

public struct AuthorizationReference: Codable, Equatable, Hashable, Sendable {
  public let authorizationID: String
  public let mainCommitOID: String
  public let authorizationBlobOID: String
  public let approvalPRNumber: Int

  enum CodingKeys: String, CodingKey {
    case authorizationID = "authorizationId"
    case mainCommitOID
    case authorizationBlobOID
    case approvalPRNumber
  }

  public init(
    authorizationID: String,
    mainCommitOID: String,
    authorizationBlobOID: String,
    approvalPRNumber: Int
  ) throws {
    guard Self.isIdentifier(authorizationID) else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid authorizationId")
    }
    guard Self.isFullLowercaseGitOID(mainCommitOID),
      Self.isFullLowercaseGitOID(authorizationBlobOID)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "authorization OIDs must be full 40-character lowercase hex")
    }
    guard approvalPRNumber > 0 else {
      throw AuthorizationUsageLedgerError.invalidRecord("approvalPRNumber must be positive")
    }
    self.authorizationID = authorizationID
    self.mainCommitOID = mainCommitOID
    self.authorizationBlobOID = authorizationBlobOID
    self.approvalPRNumber = approvalPRNumber
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      authorizationID: container.decode(String.self, forKey: .authorizationID),
      mainCommitOID: container.decode(String.self, forKey: .mainCommitOID),
      authorizationBlobOID: container.decode(String.self, forKey: .authorizationBlobOID),
      approvalPRNumber: container.decode(Int.self, forKey: .approvalPRNumber))
  }

  init(jsonValue: JSONValue, context: String) throws {
    guard case .object(let object) = jsonValue,
      Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)),
      case .string(let authorizationID)? = object[CodingKeys.authorizationID.rawValue],
      case .string(let mainCommitOID)? = object[CodingKeys.mainCommitOID.rawValue],
      case .string(let authorizationBlobOID)? = object[CodingKeys.authorizationBlobOID.rawValue],
      let approvalPRNumber = object[CodingKeys.approvalPRNumber.rawValue]?.authorizationInteger
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "\(context) must be a closed authorizationRef object")
    }
    try self.init(
      authorizationID: authorizationID, mainCommitOID: mainCommitOID,
      authorizationBlobOID: authorizationBlobOID, approvalPRNumber: approvalPRNumber)
  }

  var jsonValue: JSONValue {
    .object([
      CodingKeys.authorizationID.rawValue: .string(authorizationID),
      CodingKeys.mainCommitOID.rawValue: .string(mainCommitOID),
      CodingKeys.authorizationBlobOID.rawValue: .string(authorizationBlobOID),
      CodingKeys.approvalPRNumber.rawValue: .integer(Int64(approvalPRNumber)),
    ])
  }

  private static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  private static func isFullLowercaseGitOID(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }
}

extension AuthorizationReference.CodingKeys: CaseIterable {}

public enum AuthorizationUsageTerminalStatus: String, Codable, CaseIterable, Sendable {
  case succeeded
  case failed
  case cancelled
  case interrupted
  case outcomeUnknown
}

public struct AuthorizationUsageTerminal: Codable, Equatable, Sendable {
  public let status: AuthorizationUsageTerminalStatus
  public let closedAt: String
  public let destructiveIntentEventIDs: [String]

  enum CodingKeys: String, CodingKey {
    case status
    case closedAt
    case destructiveIntentEventIDs = "destructiveIntentEventIds"
  }

  public init(
    status: AuthorizationUsageTerminalStatus,
    closedAt: String,
    destructiveIntentEventIDs: [String]
  ) throws {
    guard AuthorizationUsageValidation.isTimestamp(closedAt) else {
      throw AuthorizationUsageLedgerError.invalidRecord("terminal.closedAt is not RFC 3339")
    }
    guard Set(destructiveIntentEventIDs).count == destructiveIntentEventIDs.count,
      destructiveIntentEventIDs.allSatisfy(AuthorizationUsageValidation.isIdentifier)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "terminal destructiveIntentEventIds must be unique identifiers")
    }
    self.status = status
    self.closedAt = closedAt
    self.destructiveIntentEventIDs = destructiveIntentEventIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      status: container.decode(AuthorizationUsageTerminalStatus.self, forKey: .status),
      closedAt: container.decode(String.self, forKey: .closedAt),
      destructiveIntentEventIDs: container.decode(
        [String].self, forKey: .destructiveIntentEventIDs))
  }
}

public struct AuthorizationUsageReservation: Codable, Equatable, Sendable {
  public let reservationID: String
  public let authorizationRef: AuthorizationReference
  public let ordinal: Int
  public let maxRuns: Int
  public let jobID: String
  public let planDigestSHA256: String
  public let targetDigestSHA256: String
  public let reservedAt: String
  public let terminal: AuthorizationUsageTerminal?

  enum CodingKeys: String, CodingKey {
    case reservationID = "reservationId"
    case authorizationRef
    case ordinal
    case maxRuns
    case jobID = "jobId"
    case planDigestSHA256
    case targetDigestSHA256
    case reservedAt
    case terminal
  }

  public init(
    reservationID: String,
    authorizationRef: AuthorizationReference,
    ordinal: Int,
    maxRuns: Int,
    jobID: String,
    planDigestSHA256: String,
    targetDigestSHA256: String,
    reservedAt: String,
    terminal: AuthorizationUsageTerminal? = nil
  ) throws {
    guard AuthorizationUsageValidation.isIdentifier(reservationID),
      AuthorizationUsageValidation.isIdentifier(jobID)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("invalid reservationId or jobId")
    }
    guard ordinal > 0, maxRuns >= 0 else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "ordinal must be positive and maxRuns must be nonnegative")
    }
    guard AuthorizationUsageValidation.isSHA256(planDigestSHA256),
      AuthorizationUsageValidation.isSHA256(targetDigestSHA256)
    else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "plan and target digests must be lowercase SHA-256")
    }
    guard AuthorizationUsageValidation.isTimestamp(reservedAt) else {
      throw AuthorizationUsageLedgerError.invalidRecord("reservedAt is not RFC 3339")
    }
    self.reservationID = reservationID
    self.authorizationRef = authorizationRef
    self.ordinal = ordinal
    self.maxRuns = maxRuns
    self.jobID = jobID
    self.planDigestSHA256 = planDigestSHA256
    self.targetDigestSHA256 = targetDigestSHA256
    self.reservedAt = reservedAt
    self.terminal = terminal
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      reservationID: container.decode(String.self, forKey: .reservationID),
      authorizationRef: container.decode(AuthorizationReference.self, forKey: .authorizationRef),
      ordinal: container.decode(Int.self, forKey: .ordinal),
      maxRuns: container.decode(Int.self, forKey: .maxRuns),
      jobID: container.decode(String.self, forKey: .jobID),
      planDigestSHA256: container.decode(String.self, forKey: .planDigestSHA256),
      targetDigestSHA256: container.decode(String.self, forKey: .targetDigestSHA256),
      reservedAt: container.decode(String.self, forKey: .reservedAt),
      terminal: container.decodeIfPresent(AuthorizationUsageTerminal.self, forKey: .terminal))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reservationID, forKey: .reservationID)
    try container.encode(authorizationRef, forKey: .authorizationRef)
    try container.encode(ordinal, forKey: .ordinal)
    try container.encode(maxRuns, forKey: .maxRuns)
    try container.encode(jobID, forKey: .jobID)
    try container.encode(planDigestSHA256, forKey: .planDigestSHA256)
    try container.encode(targetDigestSHA256, forKey: .targetDigestSHA256)
    try container.encode(reservedAt, forKey: .reservedAt)
    if let terminal {
      try container.encode(terminal, forKey: .terminal)
    } else {
      try container.encodeNil(forKey: .terminal)
    }
  }

  fileprivate func replacingTerminal(_ terminal: AuthorizationUsageTerminal) throws
    -> AuthorizationUsageReservation
  {
    try AuthorizationUsageReservation(
      reservationID: reservationID, authorizationRef: authorizationRef, ordinal: ordinal,
      maxRuns: maxRuns, jobID: jobID, planDigestSHA256: planDigestSHA256,
      targetDigestSHA256: targetDigestSHA256, reservedAt: reservedAt, terminal: terminal)
  }
}

public struct AuthorizationUsageLedgerDocument: Codable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"

  public let schemaVersion: String
  public let reservations: [AuthorizationUsageReservation]

  public init(reservations: [AuthorizationUsageReservation]) throws {
    schemaVersion = Self.schemaVersion
    self.reservations = reservations
    try AuthorizationUsageValidation.validateDocument(self)
  }
}

public enum AuthorizationUsageLedgerError: Error, Equatable, Sendable {
  case invalidRecord(String)
  case reservationConflict(String)
  case usageLimitExceeded(authorizationID: String, maxRuns: Int)
  case reservationNotFound(String)
  case unsafePath(String)
}

public enum AuthorizationUsageLedgerFaultPoint: String, CaseIterable, Sendable {
  case beforeTemporaryWrite
  case afterFileSync
  case afterReplace
  case beforeDirectorySync
}

public struct AuthorizationUsageLedgerFaultInjector: @unchecked Sendable {
  private let body: (AuthorizationUsageLedgerFaultPoint) throws -> Void

  public init(_ body: @escaping (AuthorizationUsageLedgerFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: AuthorizationUsageLedgerFaultPoint) throws { try body(point) }

  public static let none = AuthorizationUsageLedgerFaultInjector { _ in }
}

/// A host-wide, durable consume-on-reserve ledger. This type validates shape and correlation only;
/// it does not prove Git provenance or grant device-dispatch authority.
public final class AuthorizationUsageLedger: @unchecked Sendable {
  public static let ledgerFileName = "authorization-usage.json"
  public static let lockFileName = ".authorization-usage.lock"
  public static let maximumBytes = 16 * 1_024 * 1_024

  public let root: URL
  private let faultInjector: AuthorizationUsageLedgerFaultInjector

  public init(
    root: URL,
    faultInjector: AuthorizationUsageLedgerFaultInjector = .none
  ) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(root)
    self.root = root.standardizedFileURL
    self.faultInjector = faultInjector
    try DurableFilePrimitives.rejectSymbolicLink(self.root)
    try FileManager.default.createDirectory(
      at: self.root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try withLockedRoot { _ in () }
  }

  @discardableResult
  public func reserve(_ request: AuthorizationUsageReservation) throws
    -> AuthorizationUsageReservation
  {
    guard request.terminal == nil else {
      throw AuthorizationUsageLedgerError.invalidRecord(
        "reserve request must not carry terminal state")
    }
    return try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      if let existing = document.reservations.first(where: {
        $0.reservationID == request.reservationID
      }) {
        guard existing == request else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "reservation retry fields drifted: \(request.reservationID)")
        }
        return existing
      }
      let sameAuthorization = document.reservations.filter {
        $0.authorizationRef.authorizationID == request.authorizationRef.authorizationID
      }
      guard
        sameAuthorization.allSatisfy({
          $0.authorizationRef == request.authorizationRef && $0.maxRuns == request.maxRuns
        })
      else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "authorizationRef or maxRuns drifted")
      }
      let expectedOrdinal = (sameAuthorization.map(\.ordinal).max() ?? 0) + 1
      guard request.ordinal == expectedOrdinal else {
        throw AuthorizationUsageLedgerError.reservationConflict(
          "ordinal must be the next monotonic value \(expectedOrdinal)")
      }
      if request.maxRuns > 0, request.ordinal > request.maxRuns {
        throw AuthorizationUsageLedgerError.usageLimitExceeded(
          authorizationID: request.authorizationRef.authorizationID,
          maxRuns: request.maxRuns)
      }
      document = try AuthorizationUsageLedgerDocument(
        reservations: document.reservations + [request])
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return request
    }
  }

  @discardableResult
  public func close(
    reservationID: String,
    terminal: AuthorizationUsageTerminal
  ) throws -> AuthorizationUsageReservation {
    try withLockedRoot { rootDescriptor in
      var document = try loadLocked(rootDescriptor: rootDescriptor)
      guard
        let index = document.reservations.firstIndex(where: {
          $0.reservationID == reservationID
        })
      else {
        throw AuthorizationUsageLedgerError.reservationNotFound(reservationID)
      }
      let existing = document.reservations[index]
      if let existingTerminal = existing.terminal {
        guard existingTerminal == terminal else {
          throw AuthorizationUsageLedgerError.reservationConflict(
            "terminal retry fields drifted: \(reservationID)")
        }
        return existing
      }
      let closed = try existing.replacingTerminal(terminal)
      var reservations = document.reservations
      reservations[index] = closed
      document = try AuthorizationUsageLedgerDocument(reservations: reservations)
      try persistLocked(document, rootDescriptor: rootDescriptor)
      return closed
    }
  }

  public func load() throws -> AuthorizationUsageLedgerDocument {
    try withLockedRoot { try loadLocked(rootDescriptor: $0) }
  }

  private func withLockedRoot<T>(_ body: (Int32) throws -> T) throws -> T {
    let rootDescriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard rootDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open ledger root")
    }
    defer { Darwin.close(rootDescriptor) }
    try validateRootBinding(rootDescriptor)

    var prior = stat()
    let lockWasAbsent =
      fstatat(rootDescriptor, Self.lockFileName, &prior, AT_SYMLINK_NOFOLLOW) != 0
      && errno == ENOENT
    let lockDescriptor = Darwin.openat(
      rootDescriptor, Self.lockFileName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot open usage lock")
    }
    defer { Darwin.close(lockDescriptor) }
    try validateOwnerSafeRegularFile(lockDescriptor, context: "usage lock")
    if lockWasAbsent {
      try DurableFilePrimitives.fullSync(
        lockDescriptor, path: root.appending(path: Self.lockFileName).path)
      try DurableFilePrimitives.syncDirectory(root)
    }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw AuthorizationUsageLedgerError.unsafePath("cannot acquire usage lock")
    }
    defer { flock(lockDescriptor, LOCK_UN) }
    try validatePathBinding(
      descriptor: lockDescriptor, rootDescriptor: rootDescriptor,
      name: Self.lockFileName, context: "usage lock")
    try validateRootBinding(rootDescriptor)
    let result = try body(rootDescriptor)
    try validateRootBinding(rootDescriptor)
    return result
  }

  private func loadLocked(rootDescriptor: Int32) throws -> AuthorizationUsageLedgerDocument {
    let descriptor = Darwin.openat(
      rootDescriptor, Self.ledgerFileName,
      O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0 {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath("cannot open usage ledger")
      }
      return try AuthorizationUsageLedgerDocument(reservations: [])
    }
    defer { Darwin.close(descriptor) }
    try validateOwnerSafeRegularFile(descriptor, context: "usage ledger")
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0,
      metadata.st_size <= Self.maximumBytes
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger size is invalid")
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "usage ledger")
    var data = Data(count: Int(metadata.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { bytes in
        Darwin.pread(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw AuthorizationUsageLedgerError.invalidRecord("usage ledger read failed")
      }
      offset += count
    }
    try validatePathBinding(
      descriptor: descriptor, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "usage ledger")
    return try AuthorizationUsageValidation.decode(data)
  }

  private func persistLocked(
    _ document: AuthorizationUsageLedgerDocument,
    rootDescriptor: Int32
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    guard !data.isEmpty, data.count <= Self.maximumBytes else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger exceeds size limit")
    }
    let temporaryName = ".authorization-usage.\(UUID().uuidString).tmp"
    let temporaryURL = root.appending(path: temporaryName)
    let descriptor = Darwin.openat(
      rootDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot create usage temporary file")
    }
    var descriptorIsOpen = true
    defer {
      if descriptorIsOpen { Darwin.close(descriptor) }
      _ = Darwin.unlinkat(rootDescriptor, temporaryName, 0)
    }
    try validateOwnerSafeRegularFile(descriptor, context: "usage temporary file")
    try faultInjector.check(.beforeTemporaryWrite)
    try DurableFilePrimitives.writeAll(data, descriptor: descriptor, path: temporaryURL.path)
    try DurableFilePrimitives.fullSync(descriptor, path: temporaryURL.path)
    try faultInjector.check(.afterFileSync)
    var temporaryMetadata = stat()
    guard fstat(descriptor, &temporaryMetadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot inspect usage temporary file")
    }
    guard Darwin.close(descriptor) == 0 else {
      descriptorIsOpen = false
      throw AuthorizationUsageLedgerError.unsafePath("cannot close usage temporary file")
    }
    descriptorIsOpen = false
    try validateExistingLedgerPath(rootDescriptor)
    guard renameat(rootDescriptor, temporaryName, rootDescriptor, Self.ledgerFileName) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot atomically replace usage ledger")
    }
    try validatePathBinding(
      metadata: temporaryMetadata, rootDescriptor: rootDescriptor,
      name: Self.ledgerFileName, context: "replaced usage ledger")
    try faultInjector.check(.afterReplace)
    try faultInjector.check(.beforeDirectorySync)
    try DurableFilePrimitives.syncDirectory(root)
  }

  private func validateExistingLedgerPath(_ rootDescriptor: Int32) throws {
    var metadata = stat()
    if fstatat(
      rootDescriptor, Self.ledgerFileName, &metadata, AT_SYMLINK_NOFOLLOW) != 0
    {
      guard errno == ENOENT else {
        throw AuthorizationUsageLedgerError.unsafePath("usage ledger path inspection failed")
      }
      return
    }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_nlink == 1, metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath("unsafe usage ledger replacement target")
    }
  }

  private func validateRootBinding(_ descriptor: Int32) throws {
    var descriptorMetadata = stat()
    var pathMetadata = stat()
    guard fstat(descriptor, &descriptorMetadata) == 0,
      lstat(root.path, &pathMetadata) == 0,
      descriptorMetadata.st_mode & S_IFMT == S_IFDIR,
      descriptorMetadata.st_uid == geteuid(),
      descriptorMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
      descriptorMetadata.st_dev == pathMetadata.st_dev,
      descriptorMetadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath("ledger root path changed or is unsafe")
    }
  }

  private func validateOwnerSafeRegularFile(_ descriptor: Int32, context: String) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw AuthorizationUsageLedgerError.unsafePath("unsafe \(context)")
    }
  }

  private func validatePathBinding(
    descriptor: Int32,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw AuthorizationUsageLedgerError.unsafePath("cannot inspect \(context)")
    }
    try validatePathBinding(
      metadata: metadata, rootDescriptor: rootDescriptor, name: name, context: context)
  }

  private func validatePathBinding(
    metadata: stat,
    rootDescriptor: Int32,
    name: String,
    context: String
  ) throws {
    var pathMetadata = stat()
    guard fstatat(rootDescriptor, name, &pathMetadata, AT_SYMLINK_NOFOLLOW) == 0,
      pathMetadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_dev == pathMetadata.st_dev, metadata.st_ino == pathMetadata.st_ino
    else {
      throw AuthorizationUsageLedgerError.unsafePath("\(context) path changed")
    }
  }
}

private enum AuthorizationUsageValidation {
  static func validateDocument(_ document: AuthorizationUsageLedgerDocument) throws {
    guard document.schemaVersion == AuthorizationUsageLedgerDocument.schemaVersion else {
      throw AuthorizationUsageLedgerError.invalidRecord("unsupported usage schemaVersion")
    }
    var reservationIDs = Set<String>()
    var ordinals: [String: Set<Int>] = [:]
    var maximumOrdinal: [String: Int] = [:]
    var identities: [String: (AuthorizationReference, Int)] = [:]
    for reservation in document.reservations {
      guard reservationIDs.insert(reservation.reservationID).inserted else {
        throw AuthorizationUsageLedgerError.invalidRecord("duplicate reservationId")
      }
      let authorizationID = reservation.authorizationRef.authorizationID
      if let identity = identities[authorizationID] {
        guard identity.0 == reservation.authorizationRef, identity.1 == reservation.maxRuns else {
          throw AuthorizationUsageLedgerError.invalidRecord(
            "authorizationRef or maxRuns drift within ledger")
        }
      } else {
        identities[authorizationID] = (reservation.authorizationRef, reservation.maxRuns)
      }
      var seen = ordinals[authorizationID, default: []]
      guard seen.insert(reservation.ordinal).inserted else {
        throw AuthorizationUsageLedgerError.invalidRecord("duplicate authorization ordinal")
      }
      ordinals[authorizationID] = seen
      maximumOrdinal[authorizationID] = max(
        maximumOrdinal[authorizationID] ?? 0, reservation.ordinal)
      if reservation.maxRuns > 0, reservation.ordinal > reservation.maxRuns {
        throw AuthorizationUsageLedgerError.invalidRecord("reservation exceeds maxRuns")
      }
    }
    for (authorizationID, seen) in ordinals {
      let maximum = maximumOrdinal[authorizationID] ?? 0
      guard seen == Set(1...maximum) else {
        throw AuthorizationUsageLedgerError.invalidRecord(
          "authorization ordinals are not monotonic and contiguous")
      }
    }
  }

  static func decode(_ data: Data) throws -> AuthorizationUsageLedgerDocument {
    var duplicateValidator = StrictJSONDuplicateValidator(data: data)
    do { try duplicateValidator.validate() } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("duplicate JSON member")
    }
    let root: JSONValue
    do { root = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger is not valid JSON")
    }
    try validateClosedShape(root)
    let document: AuthorizationUsageLedgerDocument
    do {
      document = try JSONDecoder().decode(AuthorizationUsageLedgerDocument.self, from: data)
    } catch {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger fields are invalid")
    }
    try validateDocument(document)
    return document
  }

  static func validateClosedShape(_ root: JSONValue) throws {
    guard case .object(let object) = root,
      Set(object.keys) == ["schemaVersion", "reservations"],
      object["schemaVersion"] == .string(AuthorizationUsageLedgerDocument.schemaVersion),
      case .array(let reservations)? = object["reservations"]
    else {
      throw AuthorizationUsageLedgerError.invalidRecord("usage ledger root shape is invalid")
    }
    let reservationKeys = Set(
      AuthorizationUsageReservation.CodingKeys.allCases.map(\.rawValue))
    let terminalKeys = Set(AuthorizationUsageTerminal.CodingKeys.allCases.map(\.rawValue))
    for value in reservations {
      guard case .object(let reservation) = value,
        Set(reservation.keys) == reservationKeys,
        let authorizationValue = reservation["authorizationRef"]
      else {
        throw AuthorizationUsageLedgerError.invalidRecord("reservation shape is not closed")
      }
      _ = try AuthorizationReference(
        jsonValue: authorizationValue, context: "reservation.authorizationRef")
      if case .object(let terminal)? = reservation["terminal"] {
        guard Set(terminal.keys) == terminalKeys else {
          throw AuthorizationUsageLedgerError.invalidRecord("terminal shape is not closed")
        }
      } else if reservation["terminal"] != .null {
        throw AuthorizationUsageLedgerError.invalidRecord("terminal must be object or null")
      }
    }
  }

  static func isIdentifier(_ value: String) -> Bool {
    value.range(
      of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression)
      == value.startIndex..<value.endIndex
  }

  static func isTimestamp(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }
}

extension AuthorizationUsageReservation.CodingKeys: CaseIterable {}
extension AuthorizationUsageTerminal.CodingKeys: CaseIterable {}

extension JSONValue {
  fileprivate var authorizationInteger: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .unsignedInteger(let value): Int(exactly: value)
    default: nil
    }
  }
}
