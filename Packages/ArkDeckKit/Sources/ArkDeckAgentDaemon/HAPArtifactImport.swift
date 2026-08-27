import ArkDeckCore
import ArkDeckWorkflows
import CryptoKit
import Foundation

enum HAPArtifactImportError: Error, Equatable, CustomStringConvertible {
  case invalidName
  case invalidByteCount
  case invalidSHA256
  case stagingCapacityExceeded
  case unknownUpload
  case expiredUpload
  case offsetMismatch(expected: Int, actual: Int)
  case invalidChunk
  case incompleteUpload(expected: Int, actual: Int)
  case digestMismatch
  case invalidHAPContainer

  var description: String {
    switch self {
    case .invalidName:
      return "Package name must be a safe .hap or .hsp basename"
    case .invalidByteCount:
      return "HAP byteCount must be 1...\(HAPArtifactImportCoordinator.maximumHAPBytes)"
    case .invalidSHA256:
      return "HAP sha256 must be 64 lowercase hexadecimal characters"
    case .stagingCapacityExceeded:
      return "HAP import staging capacity is exhausted"
    case .unknownUpload:
      return "unknown HAP import upload"
    case .expiredUpload:
      return "HAP import upload expired"
    case .offsetMismatch(let expected, let actual):
      return "HAP import offset mismatch: expected \(expected), got \(actual)"
    case .invalidChunk:
      return "HAP import chunk must be 1...\(HAPArtifactImportCoordinator.maximumChunkBytes) bytes"
    case .incompleteUpload(let expected, let actual):
      return "HAP import is incomplete: expected \(expected), got \(actual)"
    case .digestMismatch:
      return "HAP import sha256 does not match the declared digest"
    case .invalidHAPContainer:
      return "Package import is not a ZIP-based .hap or .hsp container"
    }
  }
}

actor HAPArtifactImportCoordinator {
  static let maximumHAPBytes = 64 * 1_024 * 1_024
  static let maximumChunkBytes = 512 * 1_024
  private static let maximumStagedBytes = maximumHAPBytes
  private static let lifetimeSeconds: TimeInterval = 5 * 60

  struct Completed: Sendable {
    let target: RuntimeTargetRecord
    let name: String
    let sha256: String
    let contents: Data
  }

  private struct Session: Sendable {
    let target: RuntimeTargetRecord
    let name: String
    let expectedByteCount: Int
    let expectedSHA256: String
    let createdAt: Date
    var contents: Data
  }

  private var sessions: [String: Session] = [:]

  func begin(
    target: RuntimeTargetRecord,
    name: String,
    byteCount: Int,
    sha256: String,
    now: Date = Date()
  ) throws -> String {
    _ = pruneExpired(now: now)
    guard Self.isSafeHAPName(name) else {
      throw HAPArtifactImportError.invalidName
    }
    guard (1...Self.maximumHAPBytes).contains(byteCount) else {
      throw HAPArtifactImportError.invalidByteCount
    }
    guard Self.isLowercaseSHA256(sha256) else {
      throw HAPArtifactImportError.invalidSHA256
    }
    let staged = sessions.values.reduce(0) { $0 + $1.expectedByteCount }
    guard staged <= Self.maximumStagedBytes - byteCount else {
      throw HAPArtifactImportError.stagingCapacityExceeded
    }
    let uploadID = "HAP-\(UUID().uuidString.lowercased())"
    sessions[uploadID] = Session(
      target: target,
      name: name,
      expectedByteCount: byteCount,
      expectedSHA256: sha256,
      createdAt: now,
      contents: Data())
    return uploadID
  }

  func append(
    uploadID: String,
    offset: Int,
    chunk: Data,
    now: Date = Date()
  ) throws -> Int {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw HAPArtifactImportError.expiredUpload
    }
    guard var session = sessions[uploadID] else {
      throw HAPArtifactImportError.unknownUpload
    }
    guard offset == session.contents.count else {
      throw HAPArtifactImportError.offsetMismatch(
        expected: session.contents.count, actual: offset)
    }
    guard (1...Self.maximumChunkBytes).contains(chunk.count),
      chunk.count <= session.expectedByteCount - session.contents.count
    else {
      throw HAPArtifactImportError.invalidChunk
    }
    session.contents.append(chunk)
    sessions[uploadID] = session
    return session.contents.count
  }

  func commit(uploadID: String, now: Date = Date()) throws -> Completed {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw HAPArtifactImportError.expiredUpload
    }
    guard let session = sessions[uploadID] else {
      throw HAPArtifactImportError.unknownUpload
    }
    guard session.contents.count == session.expectedByteCount else {
      throw HAPArtifactImportError.incompleteUpload(
        expected: session.expectedByteCount, actual: session.contents.count)
    }
    let digest = SHA256Hex.string(of: session.contents)
    guard digest == session.expectedSHA256 else {
      sessions.removeValue(forKey: uploadID)
      throw HAPArtifactImportError.digestMismatch
    }
    guard session.contents.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
      sessions.removeValue(forKey: uploadID)
      throw HAPArtifactImportError.invalidHAPContainer
    }
    sessions.removeValue(forKey: uploadID)
    return Completed(
      target: session.target,
      name: session.name,
      sha256: digest,
      contents: session.contents)
  }

  @discardableResult
  func abort(uploadID: String) -> Bool {
    sessions.removeValue(forKey: uploadID) != nil
  }

  private func pruneExpired(now: Date) -> Set<String> {
    let expired = Set(
      sessions.compactMap { uploadID, session in
        now.timeIntervalSince(session.createdAt) > Self.lifetimeSeconds ? uploadID : nil
      })
    for uploadID in expired {
      sessions.removeValue(forKey: uploadID)
    }
    return expired
  }

  private static func isSafeHAPName(_ name: String) -> Bool {
    DebugHAPPackageSelection.isSafeName(name, allowsHSP: true)
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    SHA256Hex.isLowercaseSHA256(value)
  }
}
