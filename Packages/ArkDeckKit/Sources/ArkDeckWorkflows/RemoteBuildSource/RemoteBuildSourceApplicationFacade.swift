@preconcurrency import Citadel
import ArkDeckCore
import Crypto
import Darwin
import Foundation
import Logging
import NIOCore
@preconcurrency import NIOSSH
import Security

// Remote build sources are deliberately narrower than a terminal. The App can
// save one SSH endpoint, list directories below one canonical build root and
// read one bounded native library. No API in this file accepts a command,
// executable, argv, environment or write-capable SFTP flag.

public enum RemoteBuildSourceAuthentication: String, Codable, CaseIterable, Sendable {
  case password
  case privateKey
}

public enum RemoteBuildSourceCredentialInput: Sendable {
  case password(String)
  case privateKey(Data, passphrase: String?)
  /// Uses ArkDeck's bounded subset of OpenSSH's default identity files. No
  /// SSH config, agent socket, known-hosts file or arbitrary home path is read.
  case systemDefault(passphrase: String?)
}

public struct RemoteBuildSourceDraft: Sendable, Equatable {
  public let id: UUID?
  public let name: String
  public let host: String
  public let port: Int
  public let username: String
  public let rootPath: String
  public let authentication: RemoteBuildSourceAuthentication

  public init(
    id: UUID? = nil,
    name: String,
    host: String,
    port: Int = 22,
    username: String,
    rootPath: String,
    authentication: RemoteBuildSourceAuthentication
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.rootPath = rootPath
    self.authentication = authentication
  }
}

public struct RemoteBuildSourcePresentation: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let host: String
  public let port: Int
  public let username: String
  public let rootPath: String
  public let authentication: RemoteBuildSourceAuthentication
  public let hostKeyFingerprint: String
  public let credentialStored: Bool
  public let usesSystemDefaultCredential: Bool
  public let lastVerifiedAt: Date

  public var endpoint: String { "\(username)@\(host):\(port)" }
}

/// An explicit association created by a user's remote-artifact selection.
///
/// It contains identifiers only: credentials and remote paths stay in their
/// existing stores, and consumers still have to resolve `sourceID` against the
/// current verified-source list before presenting it as usable.
public struct RemoteBuildSourceBindingPresentation: Sendable, Equatable {
  public let targetID: String
  public let sourceID: UUID
  public let boundAt: Date
}

/// A successful, short-lived connection probe. `trustToken` cannot be created
/// by the App and is consumed exactly once by the provider when saving.
public struct RemoteBuildSourceProbe: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let sourceName: String
  public let endpoint: String
  public let rootPath: String
  public let canonicalRootPath: String
  public let hostKeyFingerprint: String
  public let requiresNewHostTrust: Bool
  public let verifiedAt: Date
  fileprivate let trustToken: UUID
}

public enum RemoteBuildEntryKind: String, Sendable, Equatable {
  case directory
  case nativeLibrary
}

public struct RemoteBuildDirectoryEntry: Sendable, Equatable, Identifiable {
  public let name: String
  public let relativePath: String
  public let kind: RemoteBuildEntryKind
  public let byteCount: UInt64?
  public let modifiedAt: Date?

  public var id: String { relativePath }
}

public struct RemoteBuildDirectoryListing: Sendable, Equatable {
  public let sourceID: UUID
  public let sourceName: String
  public let relativePath: String
  public let entries: [RemoteBuildDirectoryEntry]
}

public struct RemoteBuildNativeLibraryArtifact: Sendable, Equatable {
  public let sourceID: UUID
  public let sourceName: String
  public let relativePath: String
  public let fileName: String
  public let byteCount: Int
  public let sha256: String
  package let contents: Data
}

public enum RemoteBuildSourceError: LocalizedError, Sendable, Equatable {
  case invalidName
  case invalidHost
  case invalidPort
  case invalidUsername
  case invalidRoot
  case invalidCredential
  case systemCredentialUnavailable
  case sourceNotFound
  case credentialUnavailable
  case probeExpired
  case hostKeyChanged
  case rootChanged
  case pathOutsideRoot
  case tooManyEntries
  case invalidLibraryName
  case invalidLibrarySize
  case fileChanged
  case connectionFailed(String)
  case keychainFailed(Int32)
  case storageFailed

  public var errorDescription: String? {
    switch self {
    case .invalidName: "服务器名称不能为空，且最多 80 个字符。"
    case .invalidHost: "主机名或 IP 地址格式无效。"
    case .invalidPort: "SSH 端口必须在 1 到 65535 之间。"
    case .invalidUsername: "SSH 用户名只能包含字母、数字、点、下划线和连字符。"
    case .invalidRoot: "编译根目录必须是非根级的绝对 POSIX 路径，且不能包含 . 或 ..。"
    case .invalidCredential: "凭据为空、过大或私钥格式不受支持。"
    case .systemCredentialUnavailable:
      "未找到可用的系统默认 OpenSSH 私钥。请配置权限安全的 ~/.ssh/id_rsa 或 ~/.ssh/id_ed25519，或手动选择私钥。"
    case .sourceNotFound: "远端构建源不存在或已被删除。"
    case .credentialUnavailable: "Keychain 中没有可用凭据，请在设置中重新测试并保存。"
    case .probeExpired: "连接测试已过期，请重新测试后再保存。"
    case .hostKeyChanged: "SSH 主机密钥与已保存的指纹不一致，连接已拒绝。"
    case .rootChanged: "远端编译根目录的真实路径已变化，连接已拒绝。"
    case .pathOutsideRoot: "远端路径超出已保存的编译根目录。"
    case .tooManyEntries: "目录包含超过 500 个可见条目，请配置更具体的编译根目录。"
    case .invalidLibraryName: "只能导入名称为 lib<name>.so 的远端文件。"
    case .invalidLibrarySize: "远端动态库必须在 64 字节到 64 MiB 之间。"
    case .fileChanged: "远端文件在读取期间发生变化，请重新选择。"
    case .connectionFailed(let detail): "SSH/SFTP 连接失败：\(detail)"
    case .keychainFailed(let status): "Keychain 操作失败（OSStatus \(status)）。"
    case .storageFailed: "无法安全保存远端构建源。"
    }
  }
}

public protocol RemoteBuildSourceProviding: Sendable {
  func listSources() async throws -> [RemoteBuildSourcePresentation]
  func probe(
    draft: RemoteBuildSourceDraft,
    credential: RemoteBuildSourceCredentialInput?
  ) async throws -> RemoteBuildSourceProbe
  func save(probe: RemoteBuildSourceProbe) async throws -> RemoteBuildSourcePresentation
  func remove(sourceID: UUID) async throws
  func listDirectory(
    sourceID: UUID,
    relativePath: String
  ) async throws -> RemoteBuildDirectoryListing
  func fetchNativeLibrary(
    sourceID: UUID,
    relativePath: String
  ) async throws -> RemoteBuildNativeLibraryArtifact
}

public protocol RemoteBuildSourceBindingProviding: Sendable {
  func binding(forTargetID targetID: String) async throws
    -> RemoteBuildSourceBindingPresentation?
  func bind(sourceID: UUID, toTargetID targetID: String) async throws
  func unbind(targetID: String) async throws
}

public enum RemoteBuildSourceApplicationFacade {
  public static func make() -> any RemoteBuildSourceProviding {
    ProductionRemoteBuildSourceProvider(
      records: RemoteBuildSourceProductionState.records,
      credentials: RemoteBuildSourceProductionState.credentials,
      audit: RemoteBuildSourceProductionState.audit)
  }
}

public enum RemoteBuildSourceBindingApplicationFacade {
  public static func make() -> any RemoteBuildSourceBindingProviding {
    ProductionRemoteBuildSourceBindingProvider(
      records: RemoteBuildSourceProductionState.records,
      bindings: RemoteBuildSourceProductionState.bindings)
  }
}

private enum RemoteBuildSourceProductionState {
  static let root = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask
  )[0]
  .appending(path: "com.arkdeck.ArkDeck", directoryHint: .isDirectory)
  .appending(path: "RemoteBuildSources", directoryHint: .isDirectory)

  static let records = FileRemoteBuildSourceRecordStore(
    fileURL: root.appending(path: "sources-v1.json"))
  static let bindings = FileRemoteBuildSourceBindingStore(
    fileURL: root.appending(path: "target-bindings-v1.json"))
  static let credentials: any RemoteBuildCredentialStoring = KeychainRemoteBuildCredentialStore()
  static let audit = FileRemoteBuildSourceAuditStore(
    fileURL: root.appending(path: "audit-v1.jsonl"))
}

package struct RemoteBuildSourceRecord: Codable, Sendable, Equatable {
  let id: UUID
  let name: String
  let host: String
  let port: Int
  let username: String
  let rootPath: String
  let canonicalRootPath: String
  let authentication: RemoteBuildSourceAuthentication
  let hostPublicKey: String
  let hostKeyFingerprint: String
  let lastVerifiedAt: Date
}

private struct RemoteBuildSourceRecordEnvelope: Codable, Sendable {
  let version: Int
  let records: [RemoteBuildSourceRecord]
}

package protocol RemoteBuildSourceRecordStoring: Sendable {
  func load() async throws -> [RemoteBuildSourceRecord]
  func replace(_ records: [RemoteBuildSourceRecord]) async throws
}

package actor FileRemoteBuildSourceRecordStore: RemoteBuildSourceRecordStoring {
  private let fileURL: URL

  package init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

  package func load() throws -> [RemoteBuildSourceRecord] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let envelope = try decoder.decode(
        RemoteBuildSourceRecordEnvelope.self, from: Data(contentsOf: fileURL))
      guard envelope.version == 1 else { throw RemoteBuildSourceError.storageFailed }
      return envelope.records
    } catch let error as RemoteBuildSourceError {
      throw error
    } catch {
      throw RemoteBuildSourceError.storageFailed
    }
  }

  package func replace(_ records: [RemoteBuildSourceRecord]) throws {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(
        RemoteBuildSourceRecordEnvelope(
          version: 1, records: records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }))
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      throw RemoteBuildSourceError.storageFailed
    }
  }
}

package struct RemoteBuildSourceBindingRecord: Codable, Sendable, Equatable {
  let targetID: String
  let sourceID: UUID
  let boundAt: Date
}

private struct RemoteBuildSourceBindingEnvelope: Codable, Sendable {
  let version: Int
  let bindings: [RemoteBuildSourceBindingRecord]
}

package protocol RemoteBuildSourceBindingStoring: Sendable {
  func load() async throws -> [RemoteBuildSourceBindingRecord]
  func replace(_ bindings: [RemoteBuildSourceBindingRecord]) async throws
}

package actor FileRemoteBuildSourceBindingStore: RemoteBuildSourceBindingStoring {
  private let fileURL: URL

  package init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

  package func load() throws -> [RemoteBuildSourceBindingRecord] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let envelope = try decoder.decode(
        RemoteBuildSourceBindingEnvelope.self, from: Data(contentsOf: fileURL))
      guard envelope.version == 1 else { throw RemoteBuildSourceError.storageFailed }
      return envelope.bindings
    } catch let error as RemoteBuildSourceError {
      throw error
    } catch {
      throw RemoteBuildSourceError.storageFailed
    }
  }

  package func replace(_ bindings: [RemoteBuildSourceBindingRecord]) throws {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(
        RemoteBuildSourceBindingEnvelope(
          version: 1, bindings: bindings.sorted { $0.targetID < $1.targetID }))
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      throw RemoteBuildSourceError.storageFailed
    }
  }
}

package actor ProductionRemoteBuildSourceBindingProvider:
  RemoteBuildSourceBindingProviding
{
  private let records: any RemoteBuildSourceRecordStoring
  private let bindings: any RemoteBuildSourceBindingStoring

  package init(
    records: any RemoteBuildSourceRecordStoring,
    bindings: any RemoteBuildSourceBindingStoring
  ) {
    self.records = records
    self.bindings = bindings
  }

  public func binding(forTargetID targetID: String) async throws
    -> RemoteBuildSourceBindingPresentation?
  {
    let targetID = try validatedTargetID(targetID)
    return try await bindings.load().first(where: { $0.targetID == targetID }).map {
      RemoteBuildSourceBindingPresentation(
        targetID: $0.targetID, sourceID: $0.sourceID, boundAt: $0.boundAt)
    }
  }

  public func bind(sourceID: UUID, toTargetID targetID: String) async throws {
    let targetID = try validatedTargetID(targetID)
    guard try await records.load().contains(where: { $0.id == sourceID }) else {
      throw RemoteBuildSourceError.sourceNotFound
    }
    var current = try await bindings.load().filter { $0.targetID != targetID }
    current.append(
      RemoteBuildSourceBindingRecord(
        targetID: targetID, sourceID: sourceID, boundAt: Date()))
    try await bindings.replace(current)
  }

  public func unbind(targetID: String) async throws {
    let targetID = try validatedTargetID(targetID)
    let current = try await bindings.load()
    try await bindings.replace(current.filter { $0.targetID != targetID })
  }

  private func validatedTargetID(_ targetID: String) throws -> String {
    let trimmed = targetID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == targetID, !trimmed.isEmpty, trimmed.utf8.count <= 512,
      trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw RemoteBuildSourceError.storageFailed }
    return trimmed
  }
}

private enum RemoteBuildCredentialOrigin: String, Codable, Sendable {
  case provided
  case systemDefault
}

private struct RemoteBuildCredentialEnvelope: Codable, Sendable, Equatable {
  let authentication: RemoteBuildSourceAuthentication
  let secret: Data
  let passphrase: Data?
  /// Optional so credentials saved by the first remote-source release remain
  /// decodable. A missing origin is an explicitly provided secret.
  let origin: RemoteBuildCredentialOrigin?

  var usesSystemDefault: Bool { origin == .systemDefault }
}

package protocol RemoteBuildCredentialStoring: Sendable {
  func set(_ data: Data, account: UUID) throws
  func read(account: UUID) throws -> Data
  func contains(account: UUID) -> Bool
  @discardableResult func remove(account: UUID) throws -> Bool
}

package struct KeychainRemoteBuildCredentialStore: RemoteBuildCredentialStoring {
  private static let service = "com.arkdeck.remote-build-source.v1"

  package init() {}

  package func set(_ data: Data, account: UUID) throws {
    let identity = query(account: account)
    let update = SecItemUpdate(
      identity as CFDictionary,
      [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw RemoteBuildSourceError.keychainFailed(update)
    }
    var item = identity
    item[kSecValueData as String] = data
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw RemoteBuildSourceError.keychainFailed(added)
    }
  }

  package func read(account: UUID) throws -> Data {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    guard status != errSecItemNotFound else {
      throw RemoteBuildSourceError.credentialUnavailable
    }
    guard status == errSecSuccess else { throw RemoteBuildSourceError.keychainFailed(status) }
    guard let data = value as? Data, !data.isEmpty else {
      throw RemoteBuildSourceError.credentialUnavailable
    }
    return data
  }

  package func contains(account: UUID) -> Bool {
    var request = query(account: account)
    request[kSecReturnAttributes as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    return SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess
  }

  package func remove(account: UUID) throws -> Bool {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: throw RemoteBuildSourceError.keychainFailed(status)
    }
  }

  private func query(account: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: account.uuidString.lowercased(),
    ]
  }
}

package struct RemoteBuildAuditEvent: Codable, Sendable {
  let eventID: UUID
  let correlationID: UUID
  let phase: String
  let action: String
  let sourceID: UUID?
  let relativePathSHA256: String?
  let outcome: String?
  let observedAt: Date
}

package protocol RemoteBuildSourceAuditWriting: Sendable {
  func append(_ event: RemoteBuildAuditEvent) async throws
}

package actor FileRemoteBuildSourceAuditStore: RemoteBuildSourceAuditWriting {
  private let fileURL: URL

  package init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

  package func append(_ event: RemoteBuildAuditEvent) throws {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      var line = try encoder.encode(event)
      line.append(0x0A)
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        try line.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      } else {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      }
    } catch {
      throw RemoteBuildSourceError.storageFailed
    }
  }
}

private struct PendingRemoteBuildSource: Sendable {
  let record: RemoteBuildSourceRecord
  let credentialData: Data
  let expiresAt: Date
}

package actor ProductionRemoteBuildSourceProvider: RemoteBuildSourceProviding {
  private static let probeLifetime: TimeInterval = 5 * 60
  private static let maximumEntries = 500
  private static let readChunkBytes: UInt32 = 512 * 1_024
  private static let minimumLibraryBytes: UInt64 = 64
  private static let maximumLibraryBytes: UInt64 = 64 * 1_024 * 1_024

  private let records: any RemoteBuildSourceRecordStoring
  private let credentials: any RemoteBuildCredentialStoring
  private let audit: any RemoteBuildSourceAuditWriting
  private let systemSSHHomeDirectory: URL
  private var pending: [UUID: PendingRemoteBuildSource] = [:]

  package init(
    records: any RemoteBuildSourceRecordStoring,
    credentials: any RemoteBuildCredentialStoring,
    audit: any RemoteBuildSourceAuditWriting,
    systemSSHHomeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.records = records
    self.credentials = credentials
    self.audit = audit
    self.systemSSHHomeDirectory = systemSSHHomeDirectory.standardizedFileURL
  }

  public func listSources() async throws -> [RemoteBuildSourcePresentation] {
    try await records.load().map(presentation).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func probe(
    draft: RemoteBuildSourceDraft,
    credential: RemoteBuildSourceCredentialInput?
  ) async throws -> RemoteBuildSourceProbe {
    let normalized = try RemoteBuildSourceBounds.validate(draft)
    let existing = try await records.load().first { $0.id == normalized.id }
    let sourceID = normalized.id ?? UUID()
    let credentialEnvelope = try credentialForProbe(
      input: credential,
      existing: existing,
      sourceID: sourceID,
      authentication: normalized.authentication)
    let credentialData = try JSONEncoder().encode(credentialEnvelope)
    let expectedHostKey = existing.flatMap {
      $0.host == normalized.host && $0.port == normalized.port ? $0.hostPublicKey : nil
    }
    let correlationID = UUID()
    try await auditEvent(
      correlationID: correlationID, phase: "intent", action: "probe",
      sourceID: normalized.id, relativePath: nil, outcome: nil)
    do {
      let observation = try await connect(
        draft: normalized,
        credential: credentialEnvelope,
        expectedHostKey: expectedHostKey
      ) { client in
        try await client.withSFTP(logger: Self.sftpLogger()) { sftp in
          try await sftp.getRealPath(atPath: normalized.rootPath)
        }
      }
      let record = RemoteBuildSourceRecord(
        id: sourceID, name: normalized.name, host: normalized.host, port: normalized.port,
        username: normalized.username, rootPath: normalized.rootPath,
        canonicalRootPath: observation.value,
        authentication: normalized.authentication,
        hostPublicKey: observation.hostPublicKey,
        hostKeyFingerprint: Self.fingerprint(observation.hostPublicKey),
        lastVerifiedAt: Date())
      let token = UUID()
      pending[token] = PendingRemoteBuildSource(
        record: record, credentialData: credentialData,
        expiresAt: Date().addingTimeInterval(Self.probeLifetime))
      try await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "probe",
        sourceID: sourceID, relativePath: nil, outcome: "confirmed")
      return RemoteBuildSourceProbe(
        id: sourceID,
        sourceName: record.name,
        endpoint: "\(record.username)@\(record.host):\(record.port)",
        rootPath: record.rootPath,
        canonicalRootPath: record.canonicalRootPath,
        hostKeyFingerprint: record.hostKeyFingerprint,
        requiresNewHostTrust: expectedHostKey == nil,
        verifiedAt: record.lastVerifiedAt,
        trustToken: token)
    } catch {
      try? await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "probe",
        sourceID: normalized.id, relativePath: nil, outcome: "failed")
      throw mapConnectionError(error)
    }
  }

  public func save(probe: RemoteBuildSourceProbe) async throws -> RemoteBuildSourcePresentation {
    guard let staged = pending.removeValue(forKey: probe.trustToken),
      staged.record.id == probe.id,
      staged.expiresAt > Date()
    else { throw RemoteBuildSourceError.probeExpired }
    let correlationID = UUID()
    try await auditEvent(
      correlationID: correlationID, phase: "intent", action: "save",
      sourceID: staged.record.id, relativePath: nil, outcome: nil)
    let previousCredential = try? credentials.read(account: staged.record.id)
    do {
      try credentials.set(staged.credentialData, account: staged.record.id)
      var all = try await records.load().filter { $0.id != staged.record.id }
      all.append(staged.record)
      try await records.replace(all)
      try? await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "save",
        sourceID: staged.record.id, relativePath: nil, outcome: "confirmed")
      return presentation(staged.record)
    } catch {
      if let previousCredential {
        try? credentials.set(previousCredential, account: staged.record.id)
      } else {
        _ = try? credentials.remove(account: staged.record.id)
      }
      throw RemoteBuildSourceError.storageFailed
    }
  }

  public func remove(sourceID: UUID) async throws {
    let old = try await records.load()
    guard old.contains(where: { $0.id == sourceID }) else {
      throw RemoteBuildSourceError.sourceNotFound
    }
    let correlationID = UUID()
    try await auditEvent(
      correlationID: correlationID, phase: "intent", action: "remove",
      sourceID: sourceID, relativePath: nil, outcome: nil)
    _ = try credentials.remove(account: sourceID)
    try await records.replace(old.filter { $0.id != sourceID })
    try? await auditEvent(
      correlationID: correlationID, phase: "outcome", action: "remove",
      sourceID: sourceID, relativePath: nil, outcome: "confirmed")
  }

  public func listDirectory(
    sourceID: UUID,
    relativePath: String
  ) async throws -> RemoteBuildDirectoryListing {
    let relativePath = try RemoteBuildSourceBounds.relativePath(relativePath, allowEmpty: true)
    let record = try await record(sourceID)
    let credential = try decodedCredential(sourceID: sourceID, expected: record.authentication)
    let correlationID = UUID()
    try await auditEvent(
      correlationID: correlationID, phase: "intent", action: "listDirectory",
      sourceID: sourceID, relativePath: relativePath, outcome: nil)
    do {
      let result = try await connect(
        record: record, credential: credential
      ) { client in
        try await client.withSFTP(logger: Self.sftpLogger()) { sftp in
          let root = try await sftp.getRealPath(atPath: record.rootPath)
          guard root == record.canonicalRootPath else { throw RemoteBuildSourceError.rootChanged }
          let requested = RemoteBuildSourceBounds.join(record.rootPath, relativePath)
          let canonical = try await sftp.getRealPath(atPath: requested)
          guard RemoteBuildSourceBounds.isContained(canonical, in: root) else {
            throw RemoteBuildSourceError.pathOutsideRoot
          }
          let batches = try await sftp.listDirectory(atPath: canonical)
          let components = batches.flatMap(\.components).filter {
            $0.filename != "." && $0.filename != ".."
          }
          guard components.count <= Self.maximumEntries else {
            throw RemoteBuildSourceError.tooManyEntries
          }
          return components.compactMap { component -> RemoteBuildDirectoryEntry? in
            guard let name = try? RemoteBuildSourceBounds.component(component.filename) else {
              return nil
            }
            let mode = component.attributes.permissions.map { $0 & 0o170000 }
            let kind: RemoteBuildEntryKind
            if mode == 0o040000 {
              kind = .directory
            } else if mode == nil || mode == 0o100000 {
              guard DebugTypedValueValidator.isValidNativeLibraryLogicalName(name) else {
                return nil
              }
              kind = .nativeLibrary
            } else {
              return nil
            }
            return RemoteBuildDirectoryEntry(
              name: name,
              relativePath: RemoteBuildSourceBounds.append(relativePath, name),
              kind: kind,
              byteCount: component.attributes.size,
              modifiedAt: component.attributes.accessModificationTime?.modificationTime)
          }
          .sorted {
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
          }
        }
      }.value
      try await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "listDirectory",
        sourceID: sourceID, relativePath: relativePath, outcome: "confirmed")
      return RemoteBuildDirectoryListing(
        sourceID: sourceID, sourceName: record.name,
        relativePath: relativePath, entries: result)
    } catch {
      try? await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "listDirectory",
        sourceID: sourceID, relativePath: relativePath, outcome: "failed")
      throw mapConnectionError(error)
    }
  }

  public func fetchNativeLibrary(
    sourceID: UUID,
    relativePath: String
  ) async throws -> RemoteBuildNativeLibraryArtifact {
    let relativePath = try RemoteBuildSourceBounds.relativePath(relativePath, allowEmpty: false)
    let fileName = try RemoteBuildSourceBounds.component(
      String(relativePath.split(separator: "/").last ?? ""))
    guard DebugTypedValueValidator.isValidNativeLibraryLogicalName(fileName) else {
      throw RemoteBuildSourceError.invalidLibraryName
    }
    let record = try await record(sourceID)
    let credential = try decodedCredential(sourceID: sourceID, expected: record.authentication)
    let correlationID = UUID()
    try await auditEvent(
      correlationID: correlationID, phase: "intent", action: "readNativeLibrary",
      sourceID: sourceID, relativePath: relativePath, outcome: nil)
    do {
      let data = try await connect(record: record, credential: credential) { client in
        try await client.withSFTP(logger: Self.sftpLogger()) { sftp in
          let root = try await sftp.getRealPath(atPath: record.rootPath)
          guard root == record.canonicalRootPath else { throw RemoteBuildSourceError.rootChanged }
          let requested = RemoteBuildSourceBounds.join(record.rootPath, relativePath)
          let canonical = try await sftp.getRealPath(atPath: requested)
          guard RemoteBuildSourceBounds.isContained(canonical, in: root) else {
            throw RemoteBuildSourceError.pathOutsideRoot
          }
          return try await sftp.withFile(filePath: canonical, flags: .read) { file in
            let before = try await file.readAttributes()
            guard let size = before.size,
              (Self.minimumLibraryBytes...Self.maximumLibraryBytes).contains(size)
            else { throw RemoteBuildSourceError.invalidLibrarySize }
            var contents = Data()
            contents.reserveCapacity(Int(size))
            var offset: UInt64 = 0
            while offset < size {
              try Task.checkCancellation()
              let requested = UInt32(min(UInt64(Self.readChunkBytes), size - offset))
              var buffer = try await file.read(from: offset, length: requested)
              guard buffer.readableBytes > 0 else { throw RemoteBuildSourceError.fileChanged }
              let chunk = buffer.readData(length: buffer.readableBytes) ?? Data()
              contents.append(chunk)
              offset += UInt64(chunk.count)
              guard offset <= size else { throw RemoteBuildSourceError.fileChanged }
            }
            let after = try await file.readAttributes()
            guard after.size == before.size,
              after.accessModificationTime?.modificationTime
                == before.accessModificationTime?.modificationTime,
              contents.count == Int(size)
            else { throw RemoteBuildSourceError.fileChanged }
            return contents
          }
        }
      }.value
      let artifact = RemoteBuildNativeLibraryArtifact(
        sourceID: sourceID, sourceName: record.name, relativePath: relativePath,
        fileName: fileName, byteCount: data.count,
        sha256: SHA256Hex.string(of: data), contents: data)
      try await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "readNativeLibrary",
        sourceID: sourceID, relativePath: relativePath, outcome: "confirmed")
      return artifact
    } catch {
      try? await auditEvent(
        correlationID: correlationID, phase: "outcome", action: "readNativeLibrary",
        sourceID: sourceID, relativePath: relativePath, outcome: "failed")
      throw mapConnectionError(error)
    }
  }

  private func record(_ sourceID: UUID) async throws -> RemoteBuildSourceRecord {
    guard let record = try await records.load().first(where: { $0.id == sourceID }) else {
      throw RemoteBuildSourceError.sourceNotFound
    }
    return record
  }

  private func existingCredential(
    sourceID: UUID,
    expected: RemoteBuildSourceAuthentication
  ) throws -> RemoteBuildCredentialEnvelope {
    try decodedCredential(sourceID: sourceID, expected: expected)
  }

  private func credentialForProbe(
    input: RemoteBuildSourceCredentialInput?,
    existing: RemoteBuildSourceRecord?,
    sourceID: UUID,
    authentication: RemoteBuildSourceAuthentication
  ) throws -> RemoteBuildCredentialEnvelope {
    if let input {
      return try RemoteBuildSourceBounds.credential(input, authentication: authentication)
    }
    if existing?.authentication == authentication {
      return try existingCredential(sourceID: sourceID, expected: authentication)
    }
    if authentication == .privateKey {
      return try RemoteBuildSourceBounds.credential(
        .systemDefault(passphrase: nil), authentication: authentication)
    }
    throw RemoteBuildSourceError.credentialUnavailable
  }

  private func decodedCredential(
    sourceID: UUID,
    expected: RemoteBuildSourceAuthentication
  ) throws -> RemoteBuildCredentialEnvelope {
    let data = try credentials.read(account: sourceID)
    guard let envelope = try? JSONDecoder().decode(RemoteBuildCredentialEnvelope.self, from: data),
      envelope.authentication == expected
    else { throw RemoteBuildSourceError.credentialUnavailable }
    return envelope
  }

  private struct ConnectionObservation<Value: Sendable>: Sendable {
    let hostPublicKey: String
    let value: Value
  }

  private func connect<Value: Sendable>(
    record: RemoteBuildSourceRecord,
    credential: RemoteBuildCredentialEnvelope,
    operation: @escaping @Sendable (SSHClient) async throws -> Value
  ) async throws -> ConnectionObservation<Value> {
    let draft = RemoteBuildSourceDraft(
      id: record.id, name: record.name, host: record.host, port: record.port,
      username: record.username, rootPath: record.rootPath,
      authentication: record.authentication)
    return try await connect(
      draft: draft, credential: credential,
      expectedHostKey: record.hostPublicKey, operation: operation)
  }

  private func connect<Value: Sendable>(
    draft: RemoteBuildSourceDraft,
    credential: RemoteBuildCredentialEnvelope,
    expectedHostKey: String?,
    operation: @escaping @Sendable (SSHClient) async throws -> Value
  ) async throws -> ConnectionObservation<Value> {
    let validator = RemoteBuildHostKeyValidator(expectedOpenSSH: expectedHostKey)
    // Parse and decrypt key material before opening the socket. Authentication
    // callbacks cannot throw, so deferring this work would turn a bad key or
    // passphrase into a process crash instead of a typed validation failure.
    let authenticationMethod = try Self.authenticationMethod(
      username: draft.username,
      credential: credential,
      systemSSHHomeDirectory: systemSSHHomeDirectory)
    var settings = SSHClientSettings(
      host: draft.host,
      port: draft.port,
      authenticationMethod: { authenticationMethod },
      hostKeyValidator: .custom(validator))
    settings.connectTimeout = .seconds(12)
    let client = try await SSHClient.connect(to: settings)
    do {
      let value = try await operation(client)
      try await client.close()
      guard let observed = validator.observedOpenSSH else {
        throw RemoteBuildSourceError.connectionFailed("服务器未提供可固定的主机密钥")
      }
      return ConnectionObservation(hostPublicKey: observed, value: value)
    } catch {
      try? await client.close()
      throw error
    }
  }

  private static func authenticationMethod(
    username: String,
    credential: RemoteBuildCredentialEnvelope,
    systemSSHHomeDirectory: URL
  ) throws -> SSHAuthenticationMethod {
    switch credential.authentication {
    case .password:
      guard let password = String(data: credential.secret, encoding: .utf8) else {
        throw RemoteBuildSourceError.invalidCredential
      }
      return .passwordBased(username: username, password: password)
    case .privateKey:
      let passphrase = credential.passphrase
      if credential.usesSystemDefault {
        let keys = SystemSSHIdentityResolver.loadCandidateData(
          homeDirectory: systemSSHHomeDirectory
        ).compactMap { try? sshPrivateKey(data: $0, passphrase: passphrase) }
        guard !keys.isEmpty else {
          throw RemoteBuildSourceError.systemCredentialUnavailable
        }
        return .custom(RemoteBuildDefaultIdentityDelegate(username: username, keys: keys))
      }
      return try authenticationMethod(
        username: username,
        privateKey: credential.secret,
        passphrase: passphrase)
    }
  }

  private static func authenticationMethod(
    username: String,
    privateKey: Data,
    passphrase: Data?
  ) throws -> SSHAuthenticationMethod {
    let keyType = try SSHKeyDetection.detectPrivateKeyType(
      from: String(decoding: privateKey, as: UTF8.self))
    switch keyType {
    case .ed25519:
      return .ed25519(
        username: username,
        privateKey: try Curve25519.Signing.PrivateKey(
          sshEd25519: privateKey, decryptionKey: passphrase))
    case .rsa:
      return .rsa(
        username: username,
        privateKey: try Insecure.RSA.PrivateKey(
          sshRsa: privateKey, decryptionKey: passphrase))
    default:
      throw RemoteBuildSourceError.invalidCredential
    }
  }

  private static func sshPrivateKey(data: Data, passphrase: Data?) throws -> NIOSSHPrivateKey {
    let keyType = try SSHKeyDetection.detectPrivateKeyType(
      from: String(decoding: data, as: UTF8.self))
    switch keyType {
    case .ed25519:
      return NIOSSHPrivateKey(
        ed25519Key: try Curve25519.Signing.PrivateKey(
          sshEd25519: data, decryptionKey: passphrase))
    case .rsa:
      return NIOSSHPrivateKey(
        custom: try Insecure.RSA.PrivateKey(sshRsa: data, decryptionKey: passphrase))
    default:
      throw RemoteBuildSourceError.invalidCredential
    }
  }

  private static func fingerprint(_ openSSH: String) -> String {
    let components = openSSH.split(separator: " ", maxSplits: 2)
    let keyData = components.count > 1
      ? (Data(base64Encoded: String(components[1])) ?? Data(openSSH.utf8))
      : Data(openSSH.utf8)
    return "SHA256:\(SHA256Hex.string(of: keyData))"
  }

  private static func sftpLogger() -> Logger {
    var logger = Logger(label: "com.arkdeck.remote-build-source.sftp")
    // Citadel logs the full SFTP file path at info level. Remote build paths
    // are private source metadata, so production deliberately retains only
    // warnings while ArkDeck's own audit stores a one-way relative-path hash.
    logger.logLevel = .warning
    return logger
  }

  private func presentation(_ record: RemoteBuildSourceRecord) -> RemoteBuildSourcePresentation {
    let credential = try? decodedCredential(
      sourceID: record.id, expected: record.authentication)
    return RemoteBuildSourcePresentation(
      id: record.id, name: record.name, host: record.host, port: record.port,
      username: record.username, rootPath: record.rootPath,
      authentication: record.authentication,
      hostKeyFingerprint: record.hostKeyFingerprint,
      credentialStored: credentials.contains(account: record.id),
      usesSystemDefaultCredential: credential?.usesSystemDefault == true,
      lastVerifiedAt: record.lastVerifiedAt)
  }

  private func auditEvent(
    correlationID: UUID,
    phase: String,
    action: String,
    sourceID: UUID?,
    relativePath: String?,
    outcome: String?
  ) async throws {
    try await audit.append(
      RemoteBuildAuditEvent(
        eventID: UUID(), correlationID: correlationID,
        phase: phase, action: action, sourceID: sourceID,
        relativePathSHA256: relativePath.map { SHA256Hex.string(of: Data($0.utf8)) },
        outcome: outcome, observedAt: Date()))
  }

  private func mapConnectionError(_ error: Error) -> Error {
    if let error = error as? RemoteBuildSourceError { return error }
    if error is RemoteBuildHostKeyMismatch { return RemoteBuildSourceError.hostKeyChanged }
    return RemoteBuildSourceError.connectionFailed(String(describing: error))
  }
}

private final class RemoteBuildDefaultIdentityDelegate: NIOSSHClientUserAuthenticationDelegate,
  @unchecked Sendable
{
  private let username: String
  private var keys: [NIOSSHPrivateKey]

  init(username: String, keys: [NIOSSHPrivateKey]) {
    self.username = username
    self.keys = keys
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard availableMethods.contains(.publicKey) else {
      nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
      return
    }
    guard !keys.isEmpty else {
      nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
      return
    }
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "",
        offer: .privateKey(.init(privateKey: keys.removeFirst()))))
  }
}

/// Reads only the two software-key identity files ArkDeck can parse. It does
/// not enumerate `.ssh`, follow symlinks, consult SSH config, or access agent
/// sockets. Opened files must match OpenSSH's owner-private expectations.
package enum SystemSSHIdentityResolver {
  package static let candidateRelativePaths = [".ssh/id_rsa", ".ssh/id_ed25519"]
  private static let maximumBytes = 256 * 1_024

  package static func loadCandidateData(homeDirectory: URL) -> [Data] {
    candidateRelativePaths.compactMap { relativePath in
      secureData(at: homeDirectory.appending(path: relativePath))
    }
  }

  private static func secureData(at url: URL) -> Data? {
    guard url.isFileURL else { return nil }
    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_uid == geteuid(),
      before.st_mode & 0o077 == 0,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else { return nil }

    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard let data = try? handle.readToEnd(),
      data.count == Int(before.st_size)
    else { return nil }

    var after = stat()
    guard fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_uid == before.st_uid,
      after.st_mode == before.st_mode,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else { return nil }
    return data
  }
}

private struct RemoteBuildHostKeyMismatch: Error, Sendable {}

private final class RemoteBuildHostKeyValidator: NIOSSHClientServerAuthenticationDelegate,
  @unchecked Sendable
{
  private let expectedOpenSSH: String?
  private let lock = NSLock()
  private var observed: String?

  init(expectedOpenSSH: String?) { self.expectedOpenSSH = expectedOpenSSH }

  var observedOpenSSH: String? {
    lock.lock()
    defer { lock.unlock() }
    return observed
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let canonical = String(openSSHPublicKey: hostKey)
    guard expectedOpenSSH == nil || expectedOpenSSH == canonical else {
      validationCompletePromise.fail(RemoteBuildHostKeyMismatch())
      return
    }
    lock.lock()
    observed = canonical
    lock.unlock()
    validationCompletePromise.succeed(())
  }
}

package enum RemoteBuildSourceBounds {
  package static func validate(_ draft: RemoteBuildSourceDraft) throws -> RemoteBuildSourceDraft {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80 else { throw RemoteBuildSourceError.invalidName }
    let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !host.isEmpty, host.count <= 255,
      host.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    else { throw RemoteBuildSourceError.invalidHost }
    guard (1...65_535).contains(draft.port) else { throw RemoteBuildSourceError.invalidPort }
    let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard username.range(
      of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
    else { throw RemoteBuildSourceError.invalidUsername }
    let root = try absoluteRoot(draft.rootPath)
    return RemoteBuildSourceDraft(
      id: draft.id, name: name, host: host, port: draft.port,
      username: username, rootPath: root, authentication: draft.authentication)
  }

  fileprivate static func credential(
    _ input: RemoteBuildSourceCredentialInput,
    authentication: RemoteBuildSourceAuthentication
  ) throws -> RemoteBuildCredentialEnvelope {
    switch (input, authentication) {
    case (.password(let password), .password):
      let secret = Data(password.utf8)
      guard !secret.isEmpty, secret.count <= 4_096 else {
        throw RemoteBuildSourceError.invalidCredential
      }
      return RemoteBuildCredentialEnvelope(
        authentication: .password, secret: secret, passphrase: nil, origin: .provided)
    case (.privateKey(let key, let passphrase), .privateKey):
      guard !key.isEmpty, key.count <= 256 * 1_024 else {
        throw RemoteBuildSourceError.invalidCredential
      }
      let passphraseData = passphrase.map { Data($0.utf8) }
      guard (passphraseData?.count ?? 0) <= 4_096 else {
        throw RemoteBuildSourceError.invalidCredential
      }
      return RemoteBuildCredentialEnvelope(
        authentication: .privateKey, secret: key,
        passphrase: passphraseData?.isEmpty == true ? nil : passphraseData,
        origin: .provided)
    case (.systemDefault(let passphrase), .privateKey):
      let passphraseData = passphrase.map { Data($0.utf8) }
      guard (passphraseData?.count ?? 0) <= 4_096 else {
        throw RemoteBuildSourceError.invalidCredential
      }
      return RemoteBuildCredentialEnvelope(
        authentication: .privateKey, secret: Data(),
        passphrase: passphraseData?.isEmpty == true ? nil : passphraseData,
        origin: .systemDefault)
    default:
      throw RemoteBuildSourceError.invalidCredential
    }
  }

  package static func absoluteRoot(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/"), trimmed != "/", trimmed.utf8.count <= 1_024,
      !trimmed.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else { throw RemoteBuildSourceError.invalidRoot }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.first?.isEmpty == true,
      parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw RemoteBuildSourceError.invalidRoot }
    return "/" + parts.dropFirst().joined(separator: "/")
  }

  package static func component(_ value: String) throws -> String {
    guard !value.isEmpty, value != ".", value != "..", value.utf8.count <= 255,
      !value.contains("/"),
      !value.unicodeScalars.contains(where: {
        $0.value == 0 || CharacterSet.controlCharacters.contains($0)
      })
    else { throw RemoteBuildSourceError.pathOutsideRoot }
    return value
  }

  package static func relativePath(_ value: String, allowEmpty: Bool) throws -> String {
    guard value.utf8.count <= 2_048, !value.hasPrefix("/") else {
      throw RemoteBuildSourceError.pathOutsideRoot
    }
    if value.isEmpty {
      guard allowEmpty else { throw RemoteBuildSourceError.pathOutsideRoot }
      return ""
    }
    return try value.split(separator: "/", omittingEmptySubsequences: false)
      .map { try component(String($0)) }
      .joined(separator: "/")
  }

  package static func append(_ base: String, _ component: String) -> String {
    base.isEmpty ? component : "\(base)/\(component)"
  }

  package static func join(_ root: String, _ relative: String) -> String {
    relative.isEmpty ? root : "\(root)/\(relative)"
  }

  package static func isContained(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }
}
