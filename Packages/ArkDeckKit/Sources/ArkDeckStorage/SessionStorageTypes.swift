import ArkDeckCore
import CryptoKit
import Darwin
import Foundation

public enum SessionStorageError: Error, Equatable, Sendable {
  case invalidIdentifier(String)
  case invalidTimestamp(String)
  case invalidRelativePath(String)
  case invalidRecord(String)
  case invalidManifest(String)
  case invalidArtifact(String)
  case emptyArtifact
  case checksumMismatch(expected: String, actual: String)
  case artifactAlreadyPublished(String)
  case volumeUnavailable(String)
  case volumeIdentityChanged(expected: VolumeIdentity, actual: VolumeIdentity)
  case insufficientSpace(required: UInt64, available: UInt64)
  case claimUnavailable(String)
  case optionalWritesStopped(String)
  case writeFailed(path: String, errno: Int32)
  case retentionTargetEscapesRoot(String)
}

public enum SessionStorageFaultPoint: String, CaseIterable, Sendable {
  case sessionBeforeRootCreate
  case sessionRootCreated
  case sessionIdentityFileSync
  case sessionDirectorySync
  case artifactWrite
  case artifactPublicationLock
  case artifactSourceValidation
  case artifactFileSync
  case artifactValidation
  case artifactReplace
  case artifactDirectorySync
  case artifactPartialDirectorySync
  case artifactSourceDirectorySync
  case artifactRecoveryRecordWrite
  case artifactRecoveryRecordSync
  case artifactRecoveryRecordReplace
  case artifactRecoveryRecordDirectorySync
  case artifactRecoveryRecordCleanup
  case artifactRecoveryRecordCleanupDirectorySync
  case auditAppend
  case auditWrite
  case auditFileSync
  case auditDirectorySync
  case manifestValidation
  case manifestWrite
  case manifestFileSync
  case manifestReplace
  case manifestDirectorySync
  case inputReferencePathValidation
  case exportBeforeReplace
  case exportAfterReplace
  case retentionBeforeDelete
}

public struct SessionStorageFaultInjector: @unchecked Sendable {
  private let body: (SessionStorageFaultPoint) throws -> Void

  public init(_ body: @escaping (SessionStorageFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: SessionStorageFaultPoint) throws {
    try body(point)
  }

  public static let none = SessionStorageFaultInjector { _ in }
}

enum SessionStorageValidation {
  static func mappingDurableFileErrors<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      throw storageDomainError(error)
    }
  }

  static func storageDomainError(_ error: Error) -> Error {
    guard let failure = error as? DurableFileError else { return error }
    switch failure {
    case .openFailed(let path, let code), .writeFailed(let path, let code),
      .syncFailed(let path, let code), .replaceFailed(let path, let code),
      .truncateFailed(let path, let code):
      return SessionStorageError.writeFailed(path: path, errno: code)
    case .pathMustBeAbsolute(let path):
      return SessionStorageError.invalidRecord("path must be absolute: \(path)")
    case .symbolicLinkRejected(let path):
      return SessionStorageError.invalidRecord("symbolic link rejected: \(path)")
    default:
      return SessionStorageError.invalidRecord(String(describing: failure))
    }
  }

  static func identifier(_ value: String, field: String) throws {
    guard
      value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#,
        options: .regularExpression
      ) == value.startIndex..<value.endIndex
    else {
      throw SessionStorageError.invalidIdentifier("\(field):\(value)")
    }
  }

  static func timestamp(_ value: String, field: String) throws {
    let pattern =
      #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#
    guard
      value.range(of: pattern, options: .regularExpression)
        == value.startIndex..<value.endIndex
    else {
      throw SessionStorageError.invalidTimestamp("\(field):\(value)")
    }

    let localDateTime: Substring
    if value.last == "Z" || value.last == "z" {
      localDateTime = value.dropLast()
    } else {
      let offsetStart = value.index(value.endIndex, offsetBy: -6)
      let offset = value[offsetStart...]
      let offsetHour = Int(offset.dropFirst().prefix(2))
      let offsetMinute = Int(offset.suffix(2))
      guard let offsetHour, let offsetMinute, offsetHour <= 23, offsetMinute <= 59 else {
        throw SessionStorageError.invalidTimestamp("\(field):\(value)")
      }
      localDateTime = value[..<offsetStart]
    }

    let dateAndTime = localDateTime.split(whereSeparator: { $0 == "T" || $0 == "t" })
    guard dateAndTime.count == 2 else {
      throw SessionStorageError.invalidTimestamp("\(field):\(value)")
    }
    let dateParts = dateAndTime[0].split(separator: "-")
    let timeParts = dateAndTime[1].split(separator: ":")
    let secondText = timeParts.count == 3 ? timeParts[2].split(separator: ".")[0] : ""
    guard dateParts.count == 3, timeParts.count == 3,
      let year = Int(dateParts[0]), let month = Int(dateParts[1]),
      let day = Int(dateParts[2]), let hour = Int(timeParts[0]),
      let minute = Int(timeParts[1]), let second = Int(secondText),
      (1...9_999).contains(year), (1...12).contains(month),
      (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
    else {
      throw SessionStorageError.invalidTimestamp("\(field):\(value)")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var firstOfMonth = DateComponents()
    firstOfMonth.calendar = calendar
    firstOfMonth.timeZone = calendar.timeZone
    firstOfMonth.year = year
    firstOfMonth.month = month
    firstOfMonth.day = 1
    guard let monthDate = calendar.date(from: firstOfMonth),
      let days = calendar.range(of: .day, in: .month, for: monthDate), days.contains(day)
    else {
      throw SessionStorageError.invalidTimestamp("\(field):\(value)")
    }
  }

  static func sha256(_ value: String, field: String) throws {
    guard
      value.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression)
        == value.startIndex..<value.endIndex
    else { throw SessionStorageError.invalidRecord("\(field) must be SHA-256") }
  }

  static func relativePath(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.hasPrefix("/"),
      value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil
    else { throw SessionStorageError.invalidRelativePath(value) }

    for component in value.split(separator: "/", omittingEmptySubsequences: false) {
      let string = String(component)
      guard !string.isEmpty, string != ".", string != "..",
        !string.hasSuffix("."), !string.hasSuffix(" "),
        string.unicodeScalars.allSatisfy({ scalar in
          scalar.value > 0x1F && scalar.value != 0x7F
            && !#"<>:"/\|?*"#.unicodeScalars.contains(scalar)
        })
      else { throw SessionStorageError.invalidRelativePath(value) }
    }
  }

  static func lowercaseSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func secureDirectory(_ url: URL) throws {
    try DurableFilePrimitives.requireAbsoluteFileURL(url)
    try DurableFilePrimitives.rejectSymbolicLink(url)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(), metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw SessionStorageError.invalidRecord("not a directory: \(url.path)")
    }
  }

  static func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else {
      throw SessionStorageError.invalidRecord("storage byte accounting overflow")
    }
    return result.partialValue
  }

  static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? UInt64.max : result.partialValue
  }
}
