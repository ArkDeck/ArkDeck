import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum DiagnosticExportTrigger: String, Sendable {
  case userInitiated
  case appCrash
  case jobFailure
}

public enum DiagnosticPlaceholderState: String, Codable, CaseIterable, Sendable {
  case unknown
  case unverified
  case redacted
}

public enum LocalDiagnosticBundleError: Error, Equatable, Sendable {
  case explicitUserInitiationRequired
  case previewScopeMismatch
  case invalidInput(String)
  case deviceRawNotExcluded
  case bundleQuotaExceeded
  case destinationAlreadyExists
  case exportOutcomeUnknown
  case fileOperationFailed(path: String, errno: Int32)
}

public enum LocalDiagnosticBundleFaultPoint: String, CaseIterable, Sendable {
  case afterPreparedForExport
  case afterStagingOpened
  case beforePublish
  case afterRenameBeforeCommit
}

public struct LocalDiagnosticBundleFaultInjector: @unchecked Sendable {
  private let body: (LocalDiagnosticBundleFaultPoint) throws -> Void

  public init(_ body: @escaping (LocalDiagnosticBundleFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: LocalDiagnosticBundleFaultPoint) throws {
    try body(point)
  }

  public static let none = LocalDiagnosticBundleFaultInjector { _ in }
}

public struct DiagnosticBundleMetadata: Codable, Equatable, Sendable {
  public let appName: String
  public let appVersion: String
  public let buildVersion: String
  public let platform: String
  public let architecture: String

  public init(
    appName: String,
    appVersion: String,
    buildVersion: String,
    platform: String,
    architecture: String
  ) throws {
    for value in [appName, appVersion, buildVersion, platform, architecture] {
      guard !value.isEmpty, value.utf8.count <= 256 else {
        throw LocalDiagnosticBundleError.invalidInput("metadata field is empty or oversized")
      }
    }
    self.appName = appName
    self.appVersion = appVersion
    self.buildVersion = buildVersion
    self.platform = platform
    self.architecture = architecture
  }
}

public struct DiagnosticToolPlaceholder: Codable, Equatable, Sendable {
  public let path: DiagnosticPlaceholderState
  public let version: DiagnosticPlaceholderState
  public let serverEndpoint: DiagnosticPlaceholderState
  public let serverOwnership: DiagnosticPlaceholderState

  public init(
    path: DiagnosticPlaceholderState = .unknown,
    version: DiagnosticPlaceholderState = .unknown,
    serverEndpoint: DiagnosticPlaceholderState = .unknown,
    serverOwnership: DiagnosticPlaceholderState = .unknown
  ) {
    self.path = path
    self.version = version
    self.serverEndpoint = serverEndpoint
    self.serverOwnership = serverOwnership
  }
}

/// A JSONL snapshot produced by `StructuredDiagnosticLogStore.snapshot()` at the composition
/// boundary. ArkDeckStorage intentionally does not import ArkDeckRuntime, so this initializer
/// treats the input as untrusted: it accepts only the writer's closed event/field catalog,
/// generated correlation shape, and privacy-specific value grammar before retaining canonical
/// export bytes.
public struct RedactedDiagnosticLogFile: Equatable, Sendable {
  public static let maximumBytes = 16 * 1_024 * 1_024
  public let name: String
  public let data: Data

  public init(name: String, data: Data) throws {
    guard
      name.range(
        of: #"^diagnostics-[0-9]{20}\.jsonl$"#, options: .regularExpression)
        == name.startIndex..<name.endIndex,
      data.count <= Self.maximumBytes
    else { throw LocalDiagnosticBundleError.invalidInput("invalid diagnostic log snapshot") }
    self.name = name
    self.data = try DiagnosticLogExportSanitizer.sanitize(data)
  }
}

private enum DiagnosticLogExportSanitizer {
  private static let requiredKeys: Set<String> = [
    "schemaVersion", "timestamp", "level", "category", "eventName", "correlationId", "fields",
  ]
  private static let levels: Set<String> = ["debug", "info", "notice", "warning", "error"]
  private static let categories: Set<String> = ["app", "hdcServer", "workflow", "storage", "ui"]
  private static let events: Set<String> = [
    "rotation.sample", "privacy.contract", "job.failed", "platform.contract",
  ]

  static func sanitize(_ data: Data) throws -> Data {
    if !data.isEmpty, data.last != 0x0A {
      throw LocalDiagnosticBundleError.invalidInput("diagnostic log snapshot has a torn tail")
    }
    var output = Data()
    for line in data.split(separator: 0x0A) {
      let lineData = Data(line)
      do {
        var duplicateValidator = StrictJSONDuplicateValidator(data: lineData)
        try duplicateValidator.validate()
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: lineData),
          Set(root.keys) == requiredKeys,
          case .string("1.0.0")? = root["schemaVersion"],
          case .string(let timestamp)? = root["timestamp"],
          case .string(let level)? = root["level"], levels.contains(level),
          case .string(let category)? = root["category"], categories.contains(category),
          case .string(let eventName)? = root["eventName"], events.contains(eventName),
          case .string(let correlationID)? = root["correlationId"],
          case .object(let fields)? = root["fields"], fields.count <= 64
        else {
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic log record has an invalid closed shape")
        }
        guard
          correlationID.range(
            of: #"^corr-[0-9a-f]{32}$"#, options: .regularExpression)
            == correlationID.startIndex..<correlationID.endIndex
        else {
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic correlation identifier was not writer-generated")
        }
        do {
          try SessionStorageValidation.timestamp(timestamp, field: "timestamp")
        } catch {
          throw LocalDiagnosticBundleError.invalidInput("diagnostic log timestamp is invalid")
        }
        for key in fields.keys.sorted() {
          guard case .string(let value)? = fields[key], value.utf8.count <= 4 * 1_024 else {
            throw LocalDiagnosticBundleError.invalidInput(
              "diagnostic log field is not a bounded string")
          }
          try validateField(key: key, value: value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(JSONValue.object(root))
        guard canonical.count < RedactedDiagnosticLogFile.maximumBytes,
          output.count <= RedactedDiagnosticLogFile.maximumBytes - canonical.count - 1
        else {
          throw LocalDiagnosticBundleError.invalidInput(
            "sanitized diagnostic log snapshot exceeds its bound")
        }
        output.append(canonical)
        output.append(0x0A)
      } catch let error as LocalDiagnosticBundleError {
        throw error
      } catch {
        throw LocalDiagnosticBundleError.invalidInput("diagnostic log record is malformed")
      }
    }
    return output
  }

  private static func validateField(key: String, value: String) throws {
    let valid: Bool
    switch key {
    case "device":
      valid = value == "[REDACTED-DEVICE-ID]"
    case "path":
      valid = value == "[REDACTED-USER-PATH]"
    case "business":
      valid = value == "[REDACTED-BUSINESS-STRING]"
    case "publicCode":
      valid = value == "diagnostics.test" || value == "diagnostics.rotation"
    case "code":
      valid = value == "fixture.failure"
    default:
      valid = false
    }
    guard valid else {
      throw LocalDiagnosticBundleError.invalidInput(
        "diagnostic log field is outside the writer catalog")
    }
  }
}

/// The Session source must be an M1-005 `SessionDiagnosticExporter` result created with its
/// default device-data exclusion and redaction policy. Only bounded structural summaries are
/// copied into this bundle; journal payload and Artifact bytes are never copied.
public struct RecentSessionDiagnosticSource: Equatable, Sendable {
  public let export: MaterializedSessionExport
  public let journalReplay: JournalReplay?

  public init(export: MaterializedSessionExport, journalReplay: JournalReplay? = nil) {
    self.export = export
    self.journalReplay = journalReplay
  }
}

public struct LocalDiagnosticBundleRequest: Equatable, Sendable {
  public let destination: URL
  public let metadata: DiagnosticBundleMetadata
  public let tool: DiagnosticToolPlaceholder
  public let logs: [RedactedDiagnosticLogFile]
  public let recentSessions: [RecentSessionDiagnosticSource]

  public init(
    destination: URL,
    metadata: DiagnosticBundleMetadata,
    tool: DiagnosticToolPlaceholder = .init(),
    logs: [RedactedDiagnosticLogFile],
    recentSessions: [RecentSessionDiagnosticSource]
  ) {
    self.destination = destination
    self.metadata = metadata
    self.tool = tool
    self.logs = logs
    self.recentSessions = recentSessions
  }
}

public struct LocalDiagnosticBundlePreview: Codable, Equatable, Sendable {
  public let scopeSHA256: String
  public let includedEntries: [String]
  public let estimatedBytes: UInt64
  public let deviceRawExcluded: Bool
  public let sensitiveDataWarning: String

  public init(
    scopeSHA256: String,
    includedEntries: [String],
    estimatedBytes: UInt64,
    deviceRawExcluded: Bool,
    sensitiveDataWarning: String
  ) {
    self.scopeSHA256 = scopeSHA256
    self.includedEntries = includedEntries
    self.estimatedBytes = estimatedBytes
    self.deviceRawExcluded = deviceRawExcluded
    self.sensitiveDataWarning = sensitiveDataWarning
  }
}

public struct MaterializedLocalDiagnosticBundle: Equatable, Sendable {
  public let root: URL
  public let preview: LocalDiagnosticBundlePreview
}

private struct DiagnosticExportParentIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
}

private final class AnchoredDiagnosticBundleStaging {
  let parentURL: URL
  let destinationURL: URL
  let stagingURL: URL

  private let parentDescriptor: Int32
  private let descriptor: Int32
  private let parentDevice: dev_t
  private let parentInode: ino_t
  private let stagingDevice: dev_t
  private let stagingInode: ino_t
  private let destinationName: String
  private let stagingName: String
  private var expectedFiles: [String: (size: UInt64, sha256: String)] = [:]
  private var renamed = false
  private var committed = false

  init(destination: URL, expectedParentIdentity: DiagnosticExportParentIdentity) throws {
    destinationURL = destination.standardizedFileURL
    parentURL = destinationURL.deletingLastPathComponent()
    destinationName = destinationURL.lastPathComponent
    try SessionStorageValidation.relativePath(destinationName)
    guard !destinationName.contains("/") else {
      throw LocalDiagnosticBundleError.invalidInput("invalid diagnostic export destination")
    }
    stagingName = ".\(destinationName).diagnostics.\(UUID().uuidString).tmp"
    stagingURL = parentURL.appending(path: stagingName, directoryHint: .isDirectory)

    let openedParent = Darwin.open(
      parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard openedParent >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: parentURL.path, errno: errno)
    }
    var openedStaging: Int32 = -1
    do {
      var parentPath = stat()
      var parent = stat()
      guard lstat(parentURL.path, &parentPath) == 0, fstat(openedParent, &parent) == 0,
        parentPath.st_mode & S_IFMT == S_IFDIR, parent.st_mode & S_IFMT == S_IFDIR,
        parentPath.st_uid == geteuid(), parent.st_uid == geteuid(),
        parentPath.st_mode & (S_IWGRP | S_IWOTH) == 0,
        parent.st_mode & (S_IWGRP | S_IWOTH) == 0,
        parentPath.st_dev == parent.st_dev, parentPath.st_ino == parent.st_ino,
        parent.st_dev == expectedParentIdentity.device,
        parent.st_ino == expectedParentIdentity.inode
      else {
        throw LocalDiagnosticBundleError.invalidInput("unsafe diagnostic export parent")
      }
      var destinationMetadata = stat()
      guard
        fstatat(openedParent, destinationName, &destinationMetadata, AT_SYMLINK_NOFOLLOW) != 0,
        errno == ENOENT
      else { throw LocalDiagnosticBundleError.destinationAlreadyExists }
      guard Darwin.mkdirat(openedParent, stagingName, 0o700) == 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(path: stagingURL.path, errno: errno)
      }
      openedStaging = Darwin.openat(
        openedParent, stagingName, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard openedStaging >= 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(path: stagingURL.path, errno: errno)
      }
      var staging = stat()
      var stagingLink = stat()
      guard fstat(openedStaging, &staging) == 0,
        fstatat(openedParent, stagingName, &stagingLink, AT_SYMLINK_NOFOLLOW) == 0,
        staging.st_mode & S_IFMT == S_IFDIR, stagingLink.st_mode & S_IFMT == S_IFDIR,
        staging.st_uid == geteuid(), stagingLink.st_uid == geteuid(),
        staging.st_mode & (S_IRWXG | S_IRWXO) == 0,
        stagingLink.st_mode & (S_IRWXG | S_IRWXO) == 0,
        staging.st_dev == parent.st_dev, staging.st_dev == stagingLink.st_dev,
        staging.st_ino == stagingLink.st_ino
      else {
        throw LocalDiagnosticBundleError.invalidInput(
          "diagnostic export staging directory is not owner-only and anchored")
      }
      try Self.fullSync(openedStaging, path: stagingURL.path)
      try Self.fullSync(openedParent, path: parentURL.path)
      parentDescriptor = openedParent
      descriptor = openedStaging
      parentDevice = parent.st_dev
      parentInode = parent.st_ino
      stagingDevice = staging.st_dev
      stagingInode = staging.st_ino
    } catch {
      if openedStaging >= 0 { Darwin.close(openedStaging) }
      var stagingMetadata = stat()
      if fstatat(openedParent, stagingName, &stagingMetadata, AT_SYMLINK_NOFOLLOW) == 0,
        stagingMetadata.st_mode & S_IFMT == S_IFDIR
      {
        _ = Darwin.unlinkat(openedParent, stagingName, AT_REMOVEDIR)
        _ = Darwin.fsync(openedParent)
      }
      Darwin.close(openedParent)
      throw error
    }
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parentDescriptor)
  }

  func write(_ data: Data, relativePath: String) throws {
    try SessionStorageValidation.relativePath(relativePath)
    let components = relativePath.split(separator: "/").map(String.init)
    guard let name = components.last else {
      throw LocalDiagnosticBundleError.invalidInput("invalid diagnostic bundle entry")
    }
    let parent = try openParentDirectory(components: Array(components.dropLast()))
    defer { Darwin.close(parent) }
    let displayURL = stagingURL.appending(path: relativePath)
    let output = Darwin.openat(
      parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard output >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: displayURL.path, errno: errno)
    }
    var isOpen = true
    defer { if isOpen { Darwin.close(output) } }
    var metadata = stat()
    guard fstat(output, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0, metadata.st_dev == stagingDevice
    else {
      throw LocalDiagnosticBundleError.invalidInput(
        "diagnostic bundle entry is not an owner-only regular file")
    }
    try Self.writeAll(data, descriptor: output, path: displayURL.path)
    try Self.fullSync(output, path: displayURL.path)
    guard Darwin.close(output) == 0 else {
      isOpen = false
      throw LocalDiagnosticBundleError.fileOperationFailed(path: displayURL.path, errno: errno)
    }
    isOpen = false
    try Self.fullSync(parent, path: displayURL.deletingLastPathComponent().path)
    guard
      expectedFiles.updateValue(
        (UInt64(data.count), Self.sha256(data)), forKey: relativePath) == nil
    else { throw LocalDiagnosticBundleError.invalidInput("duplicate diagnostic bundle entry") }
  }

  func publish(afterRename: () throws -> Void) throws {
    try validateParentBinding()
    try validateOwnedEntry(name: stagingName)
    try validateExpectedFiles()
    guard
      renameatx_np(
        parentDescriptor, stagingName, parentDescriptor, destinationName,
        UInt32(RENAME_EXCL)) == 0
    else {
      if errno == EEXIST { throw LocalDiagnosticBundleError.destinationAlreadyExists }
      throw LocalDiagnosticBundleError.fileOperationFailed(path: destinationURL.path, errno: errno)
    }
    renamed = true
    try afterRename()
    try validateParentBinding()
    try validateOwnedEntry(name: destinationName)
    try validateExpectedFiles()
    try Self.fullSync(parentDescriptor, path: parentURL.path)
    committed = true
  }

  func cleanup() throws {
    guard !committed else { return }
    let currentName = renamed ? destinationName : stagingName
    var linked = stat()
    guard fstatat(parentDescriptor, currentName, &linked, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
          opened.st_mode & S_IFMT == S_IFDIR,
          opened.st_dev == stagingDevice, opened.st_ino == stagingInode,
          opened.st_nlink == 0
        else {
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic export name vanished while its directory inode remains linked")
        }
        return
      }
      throw LocalDiagnosticBundleError.fileOperationFailed(
        path: parentURL.appending(path: currentName).path, errno: errno)
    }
    guard linked.st_mode & S_IFMT == S_IFDIR, linked.st_dev == stagingDevice,
      linked.st_ino == stagingInode
    else {
      throw LocalDiagnosticBundleError.invalidInput(
        "refusing to clean a substituted diagnostic staging directory")
    }
    try removeContents(directory: descriptor, displayPath: stagingURL.path)
    guard Darwin.unlinkat(parentDescriptor, currentName, AT_REMOVEDIR) == 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(
        path: parentURL.appending(path: currentName).path, errno: errno)
    }
    try Self.fullSync(parentDescriptor, path: parentURL.path)
  }

  private func openParentDirectory(components: [String]) throws -> Int32 {
    var current = Darwin.dup(descriptor)
    guard current >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: stagingURL.path, errno: errno)
    }
    do {
      var traversed = stagingURL
      for component in components {
        traversed.append(path: component)
        var metadata = stat()
        if fstatat(current, component, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
          guard errno == ENOENT, Darwin.mkdirat(current, component, 0o700) == 0 else {
            throw LocalDiagnosticBundleError.fileOperationFailed(path: traversed.path, errno: errno)
          }
          try Self.fullSync(current, path: traversed.deletingLastPathComponent().path)
        }
        let next = Darwin.openat(
          current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(path: traversed.path, errno: errno)
        }
        var opened = stat()
        var linked = stat()
        guard fstat(next, &opened) == 0,
          fstatat(current, component, &linked, AT_SYMLINK_NOFOLLOW) == 0,
          opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
          opened.st_uid == geteuid(), linked.st_uid == geteuid(),
          opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
          linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
          opened.st_dev == stagingDevice, opened.st_dev == linked.st_dev,
          opened.st_ino == linked.st_ino
        else {
          Darwin.close(next)
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic bundle directory ancestry was substituted")
        }
        Darwin.close(current)
        current = next
      }
      return current
    } catch {
      Darwin.close(current)
      throw error
    }
  }

  private func validateParentBinding() throws {
    var opened = stat()
    var linked = stat()
    guard fstat(parentDescriptor, &opened) == 0, lstat(parentURL.path, &linked) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), linked.st_uid == geteuid(),
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      linked.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_dev == parentDevice, opened.st_ino == parentInode,
      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
    else {
      throw LocalDiagnosticBundleError.invalidInput(
        "diagnostic export parent changed after user approval")
    }
  }

  private func validateOwnedEntry(name: String) throws {
    var opened = stat()
    var linked = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(parentDescriptor, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_mode & S_IFMT == S_IFDIR, linked.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == geteuid(), linked.st_uid == geteuid(),
      opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
      linked.st_mode & (S_IRWXG | S_IRWXO) == 0,
      opened.st_dev == stagingDevice, opened.st_ino == stagingInode,
      opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino
    else {
      throw LocalDiagnosticBundleError.invalidInput(
        "diagnostic export staging identity changed")
    }
  }

  private func validateExpectedFiles() throws {
    for (relativePath, expected) in expectedFiles.sorted(by: { $0.key < $1.key }) {
      let components = relativePath.split(separator: "/").map(String.init)
      guard let name = components.last else {
        throw LocalDiagnosticBundleError.invalidInput("invalid diagnostic bundle entry")
      }
      let parent = try openExistingParentDirectory(components: Array(components.dropLast()))
      defer { Darwin.close(parent) }
      let file = Darwin.openat(
        parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard file >= 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(
          path: stagingURL.appending(path: relativePath).path, errno: errno)
      }
      defer { Darwin.close(file) }
      var metadata = stat()
      guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == geteuid(), metadata.st_nlink == 1,
        metadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
        metadata.st_dev == stagingDevice, metadata.st_size >= 0,
        UInt64(metadata.st_size) == expected.size,
        try Self.hash(descriptor: file, size: expected.size) == expected.sha256
      else {
        throw LocalDiagnosticBundleError.invalidInput(
          "diagnostic bundle entry changed before publication")
      }
    }
  }

  private func openExistingParentDirectory(components: [String]) throws -> Int32 {
    var current = Darwin.dup(descriptor)
    guard current >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: stagingURL.path, errno: errno)
    }
    do {
      for component in components {
        let next = Darwin.openat(
          current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(path: stagingURL.path, errno: errno)
        }
        var opened = stat()
        guard fstat(next, &opened) == 0, opened.st_mode & S_IFMT == S_IFDIR,
          opened.st_uid == geteuid(), opened.st_mode & (S_IRWXG | S_IRWXO) == 0,
          opened.st_dev == stagingDevice
        else {
          Darwin.close(next)
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic bundle directory ancestry changed")
        }
        Darwin.close(current)
        current = next
      }
      return current
    } catch {
      Darwin.close(current)
      throw error
    }
  }

  private func removeContents(directory: Int32, displayPath: String) throws {
    for name in try directoryEntryNames(directory: directory, displayPath: displayPath) {
      var metadata = stat()
      guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(
          path: "\(displayPath)/\(name)", errno: errno)
      }
      if metadata.st_mode & S_IFMT == S_IFDIR {
        let child = Darwin.openat(
          directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(
            path: "\(displayPath)/\(name)", errno: errno)
        }
        var opened = stat()
        guard fstat(child, &opened) == 0, opened.st_dev == metadata.st_dev,
          opened.st_ino == metadata.st_ino
        else {
          Darwin.close(child)
          throw LocalDiagnosticBundleError.invalidInput(
            "diagnostic cleanup directory was substituted")
        }
        do {
          try removeContents(directory: child, displayPath: "\(displayPath)/\(name)")
          Darwin.close(child)
        } catch {
          Darwin.close(child)
          throw error
        }
        guard Darwin.unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(
            path: "\(displayPath)/\(name)", errno: errno)
        }
      } else {
        guard Darwin.unlinkat(directory, name, 0) == 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(
            path: "\(displayPath)/\(name)", errno: errno)
        }
      }
    }
    try Self.fullSync(directory, path: displayPath)
  }

  private func directoryEntryNames(directory: Int32, displayPath: String) throws -> [String] {
    let duplicate = Darwin.dup(directory)
    guard duplicate >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: displayPath, errno: errno)
    }
    guard let stream = fdopendir(duplicate) else {
      let failure = errno
      Darwin.close(duplicate)
      throw LocalDiagnosticBundleError.fileOperationFailed(path: displayPath, errno: failure)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else {
          throw LocalDiagnosticBundleError.fileOperationFailed(path: displayPath, errno: errno)
        }
        break
      }
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(
          decoding: bytes.prefix(Int(entry.pointee.d_namlen)).map { UInt8($0) }, as: UTF8.self)
      }
      if name != ".", name != ".." { names.append(name) }
    }
    return names
  }

  private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(path: path, errno: errno)
      }
      offset += count
    }
  }

  private static func hash(descriptor: Int32, size: UInt64) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    var offset: UInt64 = 0
    while offset < size {
      let requested = min(buffer.count, Int(size - offset))
      let count = Darwin.pread(descriptor, &buffer, requested, off_t(offset))
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw LocalDiagnosticBundleError.invalidInput(
          "diagnostic bundle entry changed while hashing")
      }
      hasher.update(data: Data(buffer[0..<count]))
      offset += UInt64(count)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func fullSync(_ descriptor: Int32, path: String) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard Darwin.fsync(descriptor) == 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: path, errno: errno)
    }
  }
}

public struct LocalDiagnosticBundleExporter: Sendable {
  public static let defaultMaximumBundleBytes: UInt64 = 32 * 1_024 * 1_024
  private let maximumBundleBytes: UInt64
  private let faultInjector: LocalDiagnosticBundleFaultInjector

  public init(
    maximumBundleBytes: UInt64 = Self.defaultMaximumBundleBytes,
    faultInjector: LocalDiagnosticBundleFaultInjector = .none
  ) throws {
    guard maximumBundleBytes > 0, maximumBundleBytes <= 256 * 1_024 * 1_024 else {
      throw LocalDiagnosticBundleError.invalidInput("invalid diagnostic bundle quota")
    }
    self.maximumBundleBytes = maximumBundleBytes
    self.faultInjector = faultInjector
  }

  /// Produces the exact export scope without writing a bundle. The returned scope hash must be
  /// supplied to `export`; a changed request requires a new user preview.
  public func preview(_ request: LocalDiagnosticBundleRequest) throws
    -> LocalDiagnosticBundlePreview
  {
    let parentIdentity = try validateDestination(request.destination)
    let prepared = try prepare(request, parentIdentity: parentIdentity)
    return try makePreview(prepared, tool: request.tool)
  }

  private func makePreview(
    _ prepared: PreparedBundle, tool: DiagnosticToolPlaceholder
  ) throws -> LocalDiagnosticBundlePreview {
    let entryBytes = try prepared.entries.reduce(UInt64(0)) { partial, entry in
      let addition = partial.addingReportingOverflow(UInt64(entry.data.count))
      guard !addition.overflow else { throw LocalDiagnosticBundleError.bundleQuotaExceeded }
      return addition.partialValue
    }
    let includedEntries = (prepared.entries.map(\.path) + ["bundle.json"]).sorted()
    var estimated = entryBytes
    for _ in 0..<8 {
      let preview = LocalDiagnosticBundlePreview(
        scopeSHA256: prepared.scopeSHA256,
        includedEntries: includedEntries,
        estimatedBytes: estimated,
        deviceRawExcluded: true,
        sensitiveDataWarning:
          "诊断包包含 App 日志和结构化 Job 摘要；设备 raw 默认排除，分享前仍应检查预览。")
      let manifestBytes = try Self.canonicalData(
        DiagnosticBundleManifest(
          schemaVersion: "1.0.0", generatedAt: prepared.generatedAt, preview: preview,
          tool: tool, automaticUploadEnabled: false))
      let total = entryBytes.addingReportingOverflow(UInt64(manifestBytes.count))
      guard !total.overflow else { throw LocalDiagnosticBundleError.bundleQuotaExceeded }
      if total.partialValue == estimated {
        guard estimated <= maximumBundleBytes else {
          throw LocalDiagnosticBundleError.bundleQuotaExceeded
        }
        return preview
      }
      estimated = total.partialValue
    }
    throw LocalDiagnosticBundleError.invalidInput(
      "diagnostic bundle preview size did not converge")
  }

  public func export(
    _ request: LocalDiagnosticBundleRequest,
    trigger: DiagnosticExportTrigger,
    approvedPreview: LocalDiagnosticBundlePreview
  ) throws -> MaterializedLocalDiagnosticBundle {
    guard trigger == .userInitiated else {
      throw LocalDiagnosticBundleError.explicitUserInitiationRequired
    }
    let parentIdentity = try validateDestination(request.destination)
    let prepared = try prepare(request, parentIdentity: parentIdentity)
    let currentPreview = try makePreview(prepared, tool: request.tool)
    guard currentPreview == approvedPreview else {
      throw LocalDiagnosticBundleError.previewScopeMismatch
    }
    try faultInjector.check(.afterPreparedForExport)

    let staging = try AnchoredDiagnosticBundleStaging(
      destination: request.destination, expectedParentIdentity: prepared.parentIdentity)
    do {
      try faultInjector.check(.afterStagingOpened)
      for entry in prepared.entries {
        try staging.write(entry.data, relativePath: entry.path)
      }
      let bundleManifestData = try Self.canonicalData(
        DiagnosticBundleManifest(
          schemaVersion: "1.0.0", generatedAt: prepared.generatedAt,
          preview: currentPreview, tool: request.tool, automaticUploadEnabled: false))
      let entryBytes = prepared.entries.reduce(UInt64(0)) {
        $0 + UInt64($1.data.count)
      }
      guard entryBytes + UInt64(bundleManifestData.count) == currentPreview.estimatedBytes else {
        throw LocalDiagnosticBundleError.invalidInput(
          "diagnostic bundle bytes differ from the approved estimate")
      }
      try staging.write(bundleManifestData, relativePath: "bundle.json")
      try faultInjector.check(.beforePublish)
      try staging.publish {
        try faultInjector.check(.afterRenameBeforeCommit)
      }
      return MaterializedLocalDiagnosticBundle(root: request.destination, preview: currentPreview)
    } catch {
      do {
        try staging.cleanup()
      } catch {
        throw LocalDiagnosticBundleError.exportOutcomeUnknown
      }
      throw error
    }
  }

  private struct PreparedEntry {
    let path: String
    let data: Data
  }

  private struct PreparedBundle {
    let entries: [PreparedEntry]
    let scopeSHA256: String
    let generatedAt: String
    let parentIdentity: DiagnosticExportParentIdentity
  }

  private struct ManifestSummary: Codable {
    let opaqueSessionReference: String
    let manifestSHA256: String
    let status: String
    let executionMode: String
    let artifactCounts: [String: Int]
    let confirmationCount: Int
  }

  private struct JournalSummary: Codable {
    let eventCount: Int
    let lastDurableSequence: Int?
    let currentState: String?
    let hasTornTail: Bool
    let requiresRecovery: Bool
    let finalized: Bool
    let outstandingIntentCount: Int
    let unknownOutcomeCount: Int
  }

  private struct DiagnosticBundleManifest: Codable {
    let schemaVersion: String
    let generatedAt: String
    let preview: LocalDiagnosticBundlePreview
    let tool: DiagnosticToolPlaceholder
    let automaticUploadEnabled: Bool
  }

  private func prepare(
    _ request: LocalDiagnosticBundleRequest,
    parentIdentity: DiagnosticExportParentIdentity
  ) throws -> PreparedBundle {
    guard request.logs.count <= 256, request.recentSessions.count <= 64 else {
      throw LocalDiagnosticBundleError.invalidInput("diagnostic source count exceeds bound")
    }
    var logNames: Set<String> = []
    var entries: [PreparedEntry] = [
      PreparedEntry(path: "metadata.json", data: try Self.canonicalData(request.metadata)),
      PreparedEntry(path: "hdc/tool-placeholder.json", data: try Self.canonicalData(request.tool)),
    ]
    for log in request.logs.sorted(by: { $0.name < $1.name }) {
      let path = "logs/\(log.name)"
      guard logNames.insert(path).inserted else {
        throw LocalDiagnosticBundleError.invalidInput("duplicate diagnostic log name")
      }
      entries.append(PreparedEntry(path: path, data: log.data))
    }
    for (index, source) in request.recentSessions.enumerated() {
      guard source.export.plan.deviceIdentifierPolicy == .redact else {
        throw LocalDiagnosticBundleError.deviceRawNotExcluded
      }
      let manifestURL = source.export.root.appending(path: "manifest.json")
      let manifestData = try readBoundedRegularFile(
        manifestURL, maximumBytes: SessionManifestDocument.maximumCanonicalBytes)
      let manifest = try SessionManifestDocument(data: manifestData)
      guard !manifest.artifacts.contains(where: { $0.role == .raw || $0.role == .partial }) else {
        throw LocalDiagnosticBundleError.deviceRawNotExcluded
      }
      let opaqueReference = Self.sha256(Data("\(manifest.sessionID):\(manifest.jobID)".utf8))
      let artifactCounts = Dictionary(grouping: manifest.artifacts, by: { $0.role.rawValue })
        .mapValues(\.count)
      let manifestSummary = ManifestSummary(
        opaqueSessionReference: String(opaqueReference.prefix(24)),
        manifestSHA256: manifest.sha256,
        status: manifest.status,
        executionMode: manifest.executionMode,
        artifactCounts: artifactCounts,
        confirmationCount: manifest.confirmations.count)
      let prefix = String(format: "sessions/recent-%04d", index)
      entries.append(
        PreparedEntry(
          path: "\(prefix)/manifest-summary.json",
          data: try Self.canonicalData(manifestSummary)))
      if let replay = source.journalReplay {
        guard !replay.events.isEmpty,
          replay.events.allSatisfy({
            $0.sessionID == manifest.sessionID && $0.jobID == manifest.jobID
          }),
          let journalExecutionMode = replay.executionMode,
          journalExecutionMode == manifest.executionMode
        else {
          throw LocalDiagnosticBundleError.invalidInput(
            "journal summary identity does not match its Session manifest")
        }
        let journalSummary = JournalSummary(
          eventCount: replay.events.count,
          lastDurableSequence: replay.lastDurableSequence,
          currentState: replay.currentState?.rawValue,
          hasTornTail: replay.hasTornTail,
          requiresRecovery: replay.requiresRecovery,
          finalized: replay.finalized,
          outstandingIntentCount: replay.outstandingIntents.count,
          unknownOutcomeCount: replay.unknownOutcomes.count)
        entries.append(
          PreparedEntry(
            path: "\(prefix)/journal-summary.json",
            data: try Self.canonicalData(journalSummary)))
      }
    }
    var entryPaths: Set<String> = []
    for entry in entries {
      guard entryPaths.insert(entry.path).inserted else {
        throw LocalDiagnosticBundleError.invalidInput("duplicate diagnostic bundle entry")
      }
    }
    var scope = Data(request.destination.standardizedFileURL.path.utf8)
    scope.append(0x0A)
    scope.append(contentsOf: "parent-device:\(parentIdentity.device)\n".utf8)
    scope.append(contentsOf: "parent-inode:\(parentIdentity.inode)\n".utf8)
    scope = entries.sorted(by: { $0.path < $1.path }).reduce(into: scope) { data, entry in
      data.append(contentsOf: entry.path.utf8)
      data.append(0)
      data.append(contentsOf: Self.sha256(entry.data).utf8)
      data.append(0x0A)
    }
    return PreparedBundle(
      entries: entries, scopeSHA256: Self.sha256(scope), generatedAt: Self.timestamp(),
      parentIdentity: parentIdentity)
  }

  private func validateDestination(_ destination: URL) throws
    -> DiagnosticExportParentIdentity
  {
    guard destination.isFileURL, destination.path.hasPrefix("/"),
      !destination.lastPathComponent.isEmpty, destination.lastPathComponent != ".",
      destination.lastPathComponent != "..", !destination.lastPathComponent.contains("/")
    else { throw LocalDiagnosticBundleError.invalidInput("destination must be absolute") }
    let parent = destination.deletingLastPathComponent().standardizedFileURL
    let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: parent.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var linked = stat()
    var opened = stat()
    guard lstat(parent.path, &linked) == 0, fstat(descriptor, &opened) == 0,
      linked.st_mode & S_IFMT == S_IFDIR, opened.st_mode & S_IFMT == S_IFDIR,
      linked.st_uid == geteuid(), opened.st_uid == geteuid(),
      linked.st_mode & (S_IWGRP | S_IWOTH) == 0,
      opened.st_mode & (S_IWGRP | S_IWOTH) == 0,
      linked.st_dev == opened.st_dev, linked.st_ino == opened.st_ino
    else { throw LocalDiagnosticBundleError.invalidInput("unsafe diagnostic export parent") }
    var destinationMetadata = stat()
    guard
      fstatat(
        descriptor, destination.lastPathComponent, &destinationMetadata,
        AT_SYMLINK_NOFOLLOW) != 0,
      errno == ENOENT
    else {
      throw LocalDiagnosticBundleError.destinationAlreadyExists
    }
    return DiagnosticExportParentIdentity(device: opened.st_dev, inode: opened.st_ino)
  }

  private func readBoundedRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw LocalDiagnosticBundleError.fileOperationFailed(path: url.path, errno: errno)
    }
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= maximumBytes
    else { throw LocalDiagnosticBundleError.invalidInput("invalid bounded manifest source") }
    var data = Data(count: Int(metadata.st_size))
    let byteCount = data.count
    var offset = 0
    while offset < byteCount {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), byteCount - offset,
          off_t(offset))
      }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        throw LocalDiagnosticBundleError.fileOperationFailed(path: url.path, errno: errno)
      }
      offset += count
    }
    return data
  }

  private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

}
