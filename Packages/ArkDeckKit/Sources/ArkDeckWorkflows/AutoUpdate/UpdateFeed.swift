import CryptoKit
import Darwin
import Foundation

public enum UpdateFeedError: Error, Equatable, Sendable {
  case feedTooLarge
  case payloadTooLarge
  case malformedEnvelope
  case nonCanonicalEnvelope
  case wrongSchemaVersion
  case unknownKey
  case malformedBase64
  case invalidSignature
  case nonCanonicalPayload
  case invalidPayload
  case invalidVersion
  case invalidSystemVersion
  case invalidArchitecture
  case invalidTimestamp
  case invalidValidityWindow
  case feedNotYetValid
  case feedExpired
  case invalidArtifactURL
  case invalidArtifactLength
  case invalidArtifactDigest
  case downgrade
  case replay
  case sequenceConflict
  case nonIncreasingRelease
  case replayStateCorrupt
  case replayStateWriteFailed
}

public struct UpdateFeedTrust: Equatable, Sendable {
  public static let productionKeyID = "arkdeck-update-2026-07-b949b102"
  public static let productionRawPublicKeyBase64 =
    "c5Ho0xkWFQ3Ovzjx98dQhF3n5sytJjffqD3a+ftgP8c="
  public static let productionSPKISHA256 =
    "b949b102c5eb266084c3d59ee2e05de45681947841a4864afa0fc4136a1e7ddf"

  public let keyID: String
  public let rawPublicKey: Data

  public init(keyID: String, rawPublicKey: Data) throws {
    guard !keyID.isEmpty, rawPublicKey.count == 32,
      (try? Curve25519.Signing.PublicKey(rawRepresentation: rawPublicKey)) != nil
    else { throw UpdateFeedError.unknownKey }
    self.keyID = keyID
    self.rawPublicKey = rawPublicKey
  }

  public static var production: UpdateFeedTrust {
    get throws {
      guard
        let raw = Data(
          base64Encoded: productionRawPublicKeyBase64,
          options: [])
      else { throw UpdateFeedError.unknownKey }
      return try UpdateFeedTrust(keyID: productionKeyID, rawPublicKey: raw)
    }
  }
}

public struct UpdateFeedEnvelope: Codable, Equatable, Sendable {
  public let schemaVersion: UInt64
  public let keyId: String
  public let payload: String
  public let signature: String

  public init(schemaVersion: UInt64 = 1, keyId: String, payload: String, signature: String) {
    self.schemaVersion = schemaVersion
    self.keyId = keyId
    self.payload = payload
    self.signature = signature
  }
}

public struct UpdateArtifactDescriptor: Codable, Equatable, Sendable {
  public let url: String
  public let byteLength: UInt64
  public let sha256: String

  public init(url: String, byteLength: UInt64, sha256: String) {
    self.url = url
    self.byteLength = byteLength
    self.sha256 = sha256
  }
}

public struct UpdateFeedPayload: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let version: String
  public let minimumSystemVersion: String
  public let architectures: [String]
  public let issuedAt: String
  public let expiresAt: String
  public let artifact: UpdateArtifactDescriptor
  public let releaseNotesSummary: String

  public init(
    sequence: UInt64,
    version: String,
    minimumSystemVersion: String,
    architectures: [String],
    issuedAt: String,
    expiresAt: String,
    artifact: UpdateArtifactDescriptor,
    releaseNotesSummary: String
  ) {
    self.sequence = sequence
    self.version = version
    self.minimumSystemVersion = minimumSystemVersion
    self.architectures = architectures
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.artifact = artifact
    self.releaseNotesSummary = releaseNotesSummary
  }
}

public struct UpdateSemanticVersion: Codable, Comparable, Equatable, Sendable {
  public let major: UInt64
  public let minor: UInt64
  public let patch: UInt64

  public init?(_ value: String) {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var numbers: [UInt64] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isNumber),
        part == "0" || part.first != "0", let number = UInt64(part)
      else { return nil }
      numbers.append(number)
    }
    self.major = numbers[0]
    self.minor = numbers[1]
    self.patch = numbers[2]
  }

  public static func < (lhs: UpdateSemanticVersion, rhs: UpdateSemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  public var string: String { "\(major).\(minor).\(patch)" }
}

public enum UpdateFeedCodec {
  public static let maximumFeedBytes = 128 * 1_024
  public static let maximumPayloadBytes = 64 * 1_024
  private static let domain = Data("ArkDeck.UpdateFeed.v1".utf8)

  public static func canonicalPayload(_ payload: UpdateFeedPayload) throws -> Data {
    try validateCanonicalStrings(payload)
    return try canonicalJSON(payload)
  }

  public static func signatureInput(payload: Data, keyID: String) throws -> Data {
    guard payload.count <= maximumPayloadBytes,
      keyID.precomposedStringWithCanonicalMapping == keyID
    else { throw UpdateFeedError.invalidPayload }
    var input = domain
    input.append(0)
    input.append(Data(keyID.utf8))
    input.append(0)
    input.append(payload)
    return input
  }

  public static func assemble(
    canonicalPayload payload: Data,
    signature: Data,
    keyID: String
  ) throws -> Data {
    guard payload.count <= maximumPayloadBytes, signature.count == 64 else {
      throw UpdateFeedError.invalidSignature
    }
    let envelope = UpdateFeedEnvelope(
      keyId: keyID,
      payload: payload.base64EncodedString(),
      signature: signature.base64EncodedString())
    let data = try canonicalJSON(envelope)
    guard data.count <= maximumFeedBytes else { throw UpdateFeedError.feedTooLarge }
    return data
  }

  public static func decodeAndVerify(
    _ data: Data,
    trust: UpdateFeedTrust
  ) throws -> (payload: UpdateFeedPayload, canonicalPayload: Data) {
    guard data.count <= maximumFeedBytes else { throw UpdateFeedError.feedTooLarge }
    let envelope: UpdateFeedEnvelope
    do {
      envelope = try JSONDecoder().decode(UpdateFeedEnvelope.self, from: data)
    } catch {
      throw UpdateFeedError.malformedEnvelope
    }
    guard try canonicalJSON(envelope) == data else {
      throw UpdateFeedError.nonCanonicalEnvelope
    }
    guard envelope.schemaVersion == 1 else { throw UpdateFeedError.wrongSchemaVersion }
    guard envelope.keyId == trust.keyID else { throw UpdateFeedError.unknownKey }
    let payload = try canonicalBase64(envelope.payload)
    let signature = try canonicalBase64(envelope.signature)
    guard payload.count <= maximumPayloadBytes else { throw UpdateFeedError.payloadTooLarge }
    guard signature.count == 64 else { throw UpdateFeedError.invalidSignature }
    let publicKey: Curve25519.Signing.PublicKey
    do {
      publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: trust.rawPublicKey)
    } catch {
      throw UpdateFeedError.unknownKey
    }
    let input = try signatureInput(payload: payload, keyID: envelope.keyId)
    guard publicKey.isValidSignature(signature, for: input) else {
      throw UpdateFeedError.invalidSignature
    }
    let decoded: UpdateFeedPayload
    do {
      decoded = try JSONDecoder().decode(UpdateFeedPayload.self, from: payload)
    } catch {
      throw UpdateFeedError.invalidPayload
    }
    guard try canonicalPayload(decoded) == payload else {
      throw UpdateFeedError.nonCanonicalPayload
    }
    return (decoded, payload)
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
      return try encoder.encode(value)
    } catch {
      throw UpdateFeedError.invalidPayload
    }
  }

  private static func canonicalBase64(_ value: String) throws -> Data {
    guard let data = Data(base64Encoded: value, options: []),
      data.base64EncodedString() == value
    else { throw UpdateFeedError.malformedBase64 }
    return data
  }

  private static func validateCanonicalStrings(_ payload: UpdateFeedPayload) throws {
    let values =
      [
        payload.version, payload.minimumSystemVersion, payload.issuedAt, payload.expiresAt,
        payload.artifact.url, payload.artifact.sha256, payload.releaseNotesSummary,
      ] + payload.architectures
    guard values.allSatisfy({ $0.precomposedStringWithCanonicalMapping == $0 }) else {
      throw UpdateFeedError.nonCanonicalPayload
    }
  }
}

public struct UpdateReplayRecord: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let payloadSHA256: String
  public let version: String

  public init(sequence: UInt64, payloadSHA256: String, version: String) {
    self.sequence = sequence
    self.payloadSHA256 = payloadSHA256
    self.version = version
  }
}

public enum UpdateReplayDecision: Equatable, Sendable {
  case accepted
  case replay
  case sequenceConflict
  case nonIncreasingRelease
}

public enum UpdateReplayPolicy {
  public static func decision(
    previous: UpdateReplayRecord?,
    candidate: UpdateReplayRecord
  ) -> UpdateReplayDecision {
    guard let previous else { return .accepted }
    if candidate.sequence < previous.sequence { return .replay }
    if candidate.sequence == previous.sequence {
      return candidate == previous ? .accepted : .sequenceConflict
    }
    guard let previousVersion = UpdateSemanticVersion(previous.version),
      let candidateVersion = UpdateSemanticVersion(candidate.version),
      previousVersion < candidateVersion
    else { return .nonIncreasingRelease }
    return .accepted
  }
}

public protocol UpdateReplayStoring: Sendable {
  func validateAndCommit(_ candidate: UpdateReplayRecord) throws -> UpdateReplayDecision
}

/// Serializes replay admission across both store instances and App processes, then persists the
/// highest accepted record with an atomic same-directory rename and durable file/directory sync.
public final class FileUpdateReplayStore: UpdateReplayStoring, @unchecked Sendable {
  private static let stateName = "replay-state-v1.json"
  private static let lockName = ".replay-state-v1.lock"
  private static let maximumStateBytes = 4 * 1_024

  public let directory: URL
  private let processLock: NSLock

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL
    self.processLock = UpdateReplayProcessLockRegistry.shared.lock(for: self.directory.path)
  }

  public static func production() throws -> FileUpdateReplayStore {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true)
      return FileUpdateReplayStore(
        directory: support.appending(
          path: "ArkDeck/AutoUpdateReplay", directoryHint: .isDirectory))
    } catch {
      throw UpdateFeedError.replayStateWriteFailed
    }
  }

  public func validateAndCommit(
    _ candidate: UpdateReplayRecord
  ) throws -> UpdateReplayDecision {
    guard Self.isValid(candidate) else { throw UpdateFeedError.replayStateWriteFailed }
    return try withExclusiveTransaction { directoryDescriptor in
      let previous = try Self.loadRecord(directoryDescriptor: directoryDescriptor)
      let decision = UpdateReplayPolicy.decision(previous: previous, candidate: candidate)
      if decision == .accepted, previous != candidate {
        try Self.persist(candidate, directoryDescriptor: directoryDescriptor)
      }
      return decision
    }
  }

  public func loadCurrentRecord() throws -> UpdateReplayRecord? {
    try withExclusiveTransaction { directoryDescriptor in
      try Self.loadRecord(directoryDescriptor: directoryDescriptor)
    }
  }

  private func withExclusiveTransaction<T>(
    _ body: (Int32) throws -> T
  ) throws -> T {
    processLock.lock()
    defer { processLock.unlock() }
    let directoryDescriptor = try openSecureDirectory()
    defer { Darwin.close(directoryDescriptor) }
    let lockDescriptor = Darwin.openat(
      directoryDescriptor, Self.lockName,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lockDescriptor >= 0 else { throw UpdateFeedError.replayStateWriteFailed }
    defer { Darwin.close(lockDescriptor) }
    guard fchmod(lockDescriptor, 0o600) == 0 else {
      throw UpdateFeedError.replayStateWriteFailed
    }
    var lockMetadata = stat()
    guard fstat(lockDescriptor, &lockMetadata) == 0,
      lockMetadata.st_mode & S_IFMT == S_IFREG,
      lockMetadata.st_uid == geteuid(), lockMetadata.st_nlink == 1,
      lockMetadata.st_mode & mode_t(0o777) == mode_t(0o600)
    else { throw UpdateFeedError.replayStateWriteFailed }
    while flock(lockDescriptor, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      throw UpdateFeedError.replayStateWriteFailed
    }
    defer { _ = flock(lockDescriptor, LOCK_UN) }
    return try body(directoryDescriptor)
  }

  private func openSecureDirectory() throws -> Int32 {
    guard directory.isFileURL, directory.path.hasPrefix("/") else {
      throw UpdateFeedError.replayStateWriteFailed
    }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw UpdateFeedError.replayStateWriteFailed
    }
    let descriptor = Darwin.open(
      directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw UpdateFeedError.replayStateWriteFailed }
    do {
      guard fchmod(descriptor, 0o700) == 0 else {
        throw UpdateFeedError.replayStateWriteFailed
      }
      var opened = stat()
      var linked = stat()
      guard fstat(descriptor, &opened) == 0,
        lstat(directory.path, &linked) == 0,
        opened.st_mode & S_IFMT == S_IFDIR,
        linked.st_mode & S_IFMT == S_IFDIR,
        opened.st_uid == geteuid(), linked.st_uid == geteuid(),
        opened.st_mode & mode_t(0o777) == mode_t(0o700),
        linked.st_mode & mode_t(0o777) == mode_t(0o700),
        opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
      else { throw UpdateFeedError.replayStateWriteFailed }
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  private static func loadRecord(directoryDescriptor: Int32) throws -> UpdateReplayRecord? {
    let descriptor = Darwin.openat(
      directoryDescriptor, stateName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw UpdateFeedError.replayStateCorrupt
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & mode_t(0o777) == mode_t(0o400),
      metadata.st_size > 0, metadata.st_size <= maximumStateBytes
    else { throw UpdateFeedError.replayStateCorrupt }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw UpdateFeedError.replayStateCorrupt }
      if count == 0 { break }
      guard data.count + count <= maximumStateBytes else {
        throw UpdateFeedError.replayStateCorrupt
      }
      data.append(contentsOf: buffer[0..<count])
    }
    guard data.count == metadata.st_size,
      let record = try? JSONDecoder().decode(UpdateReplayRecord.self, from: data),
      isValid(record),
      try canonicalData(record) == data
    else { throw UpdateFeedError.replayStateCorrupt }
    return record
  }

  private static func persist(
    _ record: UpdateReplayRecord,
    directoryDescriptor: Int32
  ) throws {
    let data: Data
    do {
      data = try canonicalData(record)
    } catch {
      throw UpdateFeedError.replayStateWriteFailed
    }
    let temporaryName = ".replay-\(UUID().uuidString.lowercased()).part"
    let descriptor = Darwin.openat(
      directoryDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw UpdateFeedError.replayStateWriteFailed }
    var temporaryExists = true
    defer {
      Darwin.close(descriptor)
      if temporaryExists { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    try writeAll(data, descriptor: descriptor)
    try fullSync(descriptor)
    guard fchmod(descriptor, 0o400) == 0 else {
      throw UpdateFeedError.replayStateWriteFailed
    }
    try fullSync(descriptor)
    guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, stateName) == 0 else {
      throw UpdateFeedError.replayStateWriteFailed
    }
    temporaryExists = false
    try fullSync(directoryDescriptor)
  }

  private static func canonicalData(_ record: UpdateReplayRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(record)
  }

  private static func isValid(_ record: UpdateReplayRecord) -> Bool {
    record.sequence > 0
      && UpdateSemanticVersion(record.version) != nil
      && record.payloadSHA256.count == 64
      && record.payloadSHA256.allSatisfy {
        $0.isASCII && ($0.isNumber || ($0 >= "a" && $0 <= "f"))
      }
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw UpdateFeedError.replayStateWriteFailed }
      offset += count
    }
  }

  private static func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw UpdateFeedError.replayStateWriteFailed }
  }
}

private final class UpdateReplayProcessLockRegistry: @unchecked Sendable {
  static let shared = UpdateReplayProcessLockRegistry()
  private let registryLock = NSLock()
  private var locks: [String: NSLock] = [:]

  func lock(for path: String) -> NSLock {
    registryLock.withLock {
      if let existing = locks[path] { return existing }
      let lock = NSLock()
      locks[path] = lock
      return lock
    }
  }
}

public struct UpdateVerificationContext: Equatable, Sendable {
  public let installedVersion: String
  public let systemVersion: String
  public let architecture: String

  public init(installedVersion: String, systemVersion: String, architecture: String) {
    self.installedVersion = installedVersion
    self.systemVersion = systemVersion
    self.architecture = architecture
  }
}

public struct VerifiedUpdateFeed: Equatable, Sendable {
  public let payload: UpdateFeedPayload
  public let canonicalPayload: Data
  public let payloadSHA256: String

  public init(payload: UpdateFeedPayload, canonicalPayload: Data, payloadSHA256: String) {
    self.payload = payload
    self.canonicalPayload = canonicalPayload
    self.payloadSHA256 = payloadSHA256
  }
}

public enum UpdateNoUpdateReason: Equatable, Sendable {
  case currentVersion
  case unsupportedSystem
  case unsupportedArchitecture
}

public enum UpdateAvailability: Equatable, Sendable {
  case update(VerifiedUpdateFeed)
  case noUpdate(UpdateNoUpdateReason)
}

public struct UpdateFeedVerifier: Sendable {
  public static let maximumValiditySeconds: TimeInterval = 30 * 24 * 60 * 60

  private let trust: UpdateFeedTrust
  private let replayStore: any UpdateReplayStoring

  public init(
    trust: UpdateFeedTrust,
    replayStore: any UpdateReplayStoring
  ) {
    self.trust = trust
    self.replayStore = replayStore
  }

  public func verify(
    _ data: Data,
    context: UpdateVerificationContext,
    now: Date
  ) throws -> UpdateAvailability {
    guard let installed = UpdateSemanticVersion(context.installedVersion) else {
      throw UpdateFeedError.invalidVersion
    }
    guard
      let system = UpdateSemanticVersion(Self.normalizedSystemVersion(context.systemVersion))
    else {
      throw UpdateFeedError.invalidSystemVersion
    }
    let decoded = try UpdateFeedCodec.decodeAndVerify(data, trust: trust)
    let payload = decoded.payload
    let validated = try Self.validateStaticPayload(payload)
    guard now >= validated.issued else { throw UpdateFeedError.feedNotYetValid }
    guard now < validated.expires else { throw UpdateFeedError.feedExpired }
    let candidate = validated.version
    let payloadHash = UpdateFeedCodec.sha256(decoded.canonicalPayload)
    let nextRecord = UpdateReplayRecord(
      sequence: payload.sequence, payloadSHA256: payloadHash, version: payload.version)
    if candidate < installed { throw UpdateFeedError.downgrade }
    switch try replayStore.validateAndCommit(nextRecord) {
    case .accepted:
      break
    case .replay:
      throw UpdateFeedError.replay
    case .sequenceConflict:
      throw UpdateFeedError.sequenceConflict
    case .nonIncreasingRelease:
      throw UpdateFeedError.nonIncreasingRelease
    }
    if candidate == installed { return .noUpdate(.currentVersion) }
    guard payload.architectures.contains(context.architecture) else {
      return .noUpdate(.unsupportedArchitecture)
    }
    guard
      let minimum = UpdateSemanticVersion(
        Self.normalizedSystemVersion(payload.minimumSystemVersion)),
      minimum <= system
    else {
      return .noUpdate(.unsupportedSystem)
    }
    return .update(
      VerifiedUpdateFeed(
        payload: payload, canonicalPayload: decoded.canonicalPayload,
        payloadSHA256: payloadHash))
  }

  /// Validates every signed payload field that can be checked before the isolated maintainer
  /// environment signs it. Freshness against the client's current clock and replay state remain
  /// verification-time checks.
  public static func validateUnsignedPayloadForSigning(_ payload: UpdateFeedPayload) throws {
    _ = try validateStaticPayload(payload)
  }

  private static func validateStaticPayload(_ payload: UpdateFeedPayload) throws -> (
    version: UpdateSemanticVersion, issued: Date, expires: Date
  ) {
    guard payload.sequence > 0 else { throw UpdateFeedError.invalidPayload }
    guard let version = UpdateSemanticVersion(payload.version) else {
      throw UpdateFeedError.invalidVersion
    }
    guard
      let minimum = UpdateSemanticVersion(normalizedSystemVersion(payload.minimumSystemVersion)),
      minimum >= UpdateSemanticVersion("14.0.0")!
    else { throw UpdateFeedError.invalidSystemVersion }
    guard payload.architectures == ["arm64"] else {
      throw UpdateFeedError.invalidArchitecture
    }
    guard payload.releaseNotesSummary.utf8.count <= 4 * 1_024 else {
      throw UpdateFeedError.invalidPayload
    }
    let issued = try timestamp(payload.issuedAt)
    let expires = try timestamp(payload.expiresAt)
    let duration = expires.timeIntervalSince(issued)
    guard duration > 0, duration <= Self.maximumValiditySeconds else {
      throw UpdateFeedError.invalidValidityWindow
    }
    try validateArtifact(payload.artifact)
    return (version, issued, expires)
  }

  private static func validateArtifact(_ artifact: UpdateArtifactDescriptor) throws {
    guard artifact.byteLength > 0 else { throw UpdateFeedError.invalidArtifactLength }
    guard artifact.sha256.count == 64,
      artifact.sha256.allSatisfy({
        $0.isASCII && ($0.isNumber || ($0 >= "a" && $0 <= "f"))
      })
    else { throw UpdateFeedError.invalidArtifactDigest }
    guard let components = URLComponents(string: artifact.url),
      components.scheme == "https", components.user == nil, components.password == nil,
      components.fragment == nil, components.port == nil,
      let host = components.host?.lowercased(), UpdateNetworkContract.allowedHosts.contains(host),
      !isIPAddress(host), components.path.hasSuffix(".dmg"),
      components.url?.absoluteString == artifact.url
    else { throw UpdateFeedError.invalidArtifactURL }
  }

  private static func timestamp(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
      throw UpdateFeedError.invalidTimestamp
    }
    return date
  }

  private static func normalizedSystemVersion(_ value: String) -> String {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 2 { return value + ".0" }
    return value
  }

  private static func isIPAddress(_ host: String) -> Bool {
    host.contains(":")
      || host.split(separator: ".").count == 4
        && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
  }
}
