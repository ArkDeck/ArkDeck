import ArkDeckCore
import ArkDeckWorkflows
import CryptoKit
import Foundation

enum NativeLibraryArtifactImportError: Error, Equatable, CustomStringConvertible {
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
  case invalidELF(String)

  var description: String {
    switch self {
    case .invalidName:
      return "native library name must be a safe lib*.so basename"
    case .invalidByteCount:
      return
        "native library byteCount must be 64..."
        + "\(NativeLibraryArtifactImportCoordinator.maximumLibraryBytes)"
    case .invalidSHA256:
      return "native library sha256 must be 64 lowercase hexadecimal characters"
    case .stagingCapacityExceeded:
      return "native library import staging capacity is exhausted"
    case .unknownUpload:
      return "unknown native library import upload"
    case .expiredUpload:
      return "native library import upload expired"
    case .offsetMismatch(let expected, let actual):
      return "native library import offset mismatch: expected \(expected), got \(actual)"
    case .invalidChunk:
      return
        "native library import chunk must be 1..."
        + "\(NativeLibraryArtifactImportCoordinator.maximumChunkBytes) bytes"
    case .incompleteUpload(let expected, let actual):
      return "native library import is incomplete: expected \(expected), got \(actual)"
    case .digestMismatch:
      return "native library import sha256 does not match the declared digest"
    case .invalidELF(let detail):
      return "native library import failed ELF validation: \(detail)"
    }
  }
}

actor NativeLibraryArtifactImportCoordinator {
  static let maximumLibraryBytes = NativeLibraryArtifactValidator.maximumBytes
  static let maximumChunkBytes = 512 * 1_024
  private static let maximumStagedBytes = maximumLibraryBytes
  private static let lifetimeSeconds: TimeInterval = 5 * 60

  struct Completed: Sendable {
    let target: RuntimeTargetRecord
    let name: String
    let sha256: String
    let contents: Data
    let facts: HDCNativeLibraryArtifactFacts
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
    guard Self.isSafeLibraryName(name) else {
      throw NativeLibraryArtifactImportError.invalidName
    }
    guard (64...Self.maximumLibraryBytes).contains(byteCount) else {
      throw NativeLibraryArtifactImportError.invalidByteCount
    }
    guard Self.isLowercaseSHA256(sha256) else {
      throw NativeLibraryArtifactImportError.invalidSHA256
    }
    let staged = sessions.values.reduce(0) { $0 + $1.expectedByteCount }
    guard staged <= Self.maximumStagedBytes - byteCount else {
      throw NativeLibraryArtifactImportError.stagingCapacityExceeded
    }
    let uploadID = "SO-\(UUID().uuidString.lowercased())"
    sessions[uploadID] = Session(
      target: target, name: name, expectedByteCount: byteCount,
      expectedSHA256: sha256, createdAt: now, contents: Data())
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
      throw NativeLibraryArtifactImportError.expiredUpload
    }
    guard var session = sessions[uploadID] else {
      throw NativeLibraryArtifactImportError.unknownUpload
    }
    guard offset == session.contents.count else {
      throw NativeLibraryArtifactImportError.offsetMismatch(
        expected: session.contents.count, actual: offset)
    }
    guard (1...Self.maximumChunkBytes).contains(chunk.count),
      chunk.count <= session.expectedByteCount - session.contents.count
    else {
      throw NativeLibraryArtifactImportError.invalidChunk
    }
    session.contents.append(chunk)
    sessions[uploadID] = session
    return session.contents.count
  }

  func commit(uploadID: String, now: Date = Date()) throws -> Completed {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw NativeLibraryArtifactImportError.expiredUpload
    }
    guard let session = sessions[uploadID] else {
      throw NativeLibraryArtifactImportError.unknownUpload
    }
    guard session.contents.count == session.expectedByteCount else {
      throw NativeLibraryArtifactImportError.incompleteUpload(
        expected: session.expectedByteCount, actual: session.contents.count)
    }
    let digest = SHA256Hex.string(of: session.contents)
    guard digest == session.expectedSHA256 else {
      sessions.removeValue(forKey: uploadID)
      throw NativeLibraryArtifactImportError.digestMismatch
    }
    let facts: HDCNativeLibraryArtifactFacts
    do {
      facts = try NativeLibraryArtifactValidator.validate(
        session.contents, requireOpenHarmonyCodeSignature: true)
    } catch {
      sessions.removeValue(forKey: uploadID)
      throw NativeLibraryArtifactImportError.invalidELF("\(error)")
    }
    sessions.removeValue(forKey: uploadID)
    return Completed(
      target: session.target, name: session.name, sha256: digest,
      contents: session.contents, facts: facts)
  }

  @discardableResult
  func abort(uploadID: String) -> Bool {
    sessions.removeValue(forKey: uploadID) != nil
  }

  private func pruneExpired(now: Date) -> Set<String> {
    let expired = Set(
      sessions.compactMap { uploadID, session in
        now.timeIntervalSince(session.createdAt) > Self.lifetimeSeconds
          ? uploadID : nil
      })
    for uploadID in expired {
      sessions.removeValue(forKey: uploadID)
    }
    return expired
  }

  private static func isSafeLibraryName(_ name: String) -> Bool {
    name.count <= 128
      && name.range(
        of: #"^lib[A-Za-z0-9_.-]+\.so$"#,
        options: .regularExpression) != nil
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    SHA256Hex.isLowercaseSHA256(value)
  }
}
