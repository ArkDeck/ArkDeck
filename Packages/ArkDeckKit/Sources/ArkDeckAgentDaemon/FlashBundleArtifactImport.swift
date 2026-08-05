import ArkDeckWorkflows
import Darwin
import Foundation

enum FlashBundleArtifactImportError: Error, Equatable, CustomStringConvertible {
  case stagingUnavailable
  case invalidName
  case invalidByteCount
  case invalidSHA256
  case unknownUpload
  case expiredUpload
  case offsetMismatch(expected: Int, actual: Int)
  case invalidChunk
  case incompleteUpload(expected: Int, actual: Int)
  case invalidBundle(String)
  case ioFailure(String)

  var description: String {
    switch self {
    case .stagingUnavailable:
      return "flash bundle import staging is unavailable"
    case .invalidName:
      return "flash bundle name must be images.tar.gz"
    case .invalidByteCount:
      return "flash bundle byteCount must be a positive byte count"
    case .invalidSHA256:
      return "flash bundle sha256 must be a lowercase SHA-256 digest"
    case .unknownUpload:
      return "unknown flash bundle import upload"
    case .expiredUpload:
      return "flash bundle import upload expired"
    case .offsetMismatch(let expected, let actual):
      return "flash bundle import offset mismatch: expected \(expected), got \(actual)"
    case .invalidChunk:
      return
        "flash bundle import chunk must be 1..."
        + "\(FlashBundleArtifactImportCoordinator.maximumChunkBytes) bytes"
    case .incompleteUpload(let expected, let actual):
      return "flash bundle import is incomplete: expected \(expected), got \(actual)"
    case .invalidBundle(let detail):
      return "flash bundle is not a usable DAYU200 images archive: \(detail)"
    case .ioFailure(let detail):
      return "flash bundle import I/O failed: \(detail)"
    }
  }
}

struct FlashBundleImportValidation: Sendable, Equatable {
  let byteCount: Int
  let sha256: String
}

struct FlashBundleImportPolicy: Sendable {
  struct Candidate: Sendable {
    /// Left nil by the production policy: an archive is judged by reading it,
    /// not by being recognised before it is read. Tests still pin exact
    /// expectations, and a candidate that states them keeps being matched on
    /// them.
    let expectedByteCount: Int?
    let expectedSHA256: String?
    let validate: @Sendable (URL) throws -> FlashBundleImportValidation
  }

  let candidates: [Candidate]

  init(
    expectedByteCount: Int,
    expectedSHA256: String,
    validate: @escaping @Sendable (URL) throws -> FlashBundleImportValidation
  ) {
    candidates = [
      Candidate(
        expectedByteCount: expectedByteCount,
        expectedSHA256: expectedSHA256,
        validate: validate)
    ]
  }

  init(candidates: [Candidate]) {
    precondition(!candidates.isEmpty)
    self.candidates = candidates
  }

  func candidate(byteCount: Int, sha256: String) -> Candidate? {
    candidates.first {
      ($0.expectedByteCount ?? byteCount) == byteCount
        && ($0.expectedSHA256 ?? sha256) == sha256
    }
  }

  /// Accepts any archive that reads as a DAYU200 images bundle.
  ///
  /// It used to accept only the two builds enumerated in the product, matched
  /// by digest before anything was read. A daily published after the last
  /// release was refused with nineteen hash mismatches while fitting the board
  /// perfectly — measured against the 7.0.0.37 build on 2026-08-05.
  ///
  /// What replaces that is not "no checking". The archive is decompressed and
  /// hashed here, its partition table is parsed, its runtime version is read
  /// out of the system image, and it must fit this board structurally: every
  /// mapped partition has an image, the table declares nothing unknown. What
  /// is gone is the requirement that somebody had already met this build.
  static let production: FlashBundleImportPolicy = {
    FlashBundleImportPolicy(candidates: [
      Candidate(expectedByteCount: nil, expectedSHA256: nil) { url in
        let board = RockchipFlashProfile.dayu200OpenHarmony70035
        let summary: GzipTarArchiveSummary
        do {
          summary = try GzipTarArchiveReader.summarize(
            fileAt: url,
            derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
        } catch {
          throw FlashBundleArtifactImportError.invalidBundle("\(error)")
        }
        do {
          let build = try RockchipImageArchiveIntrospection.describe(
            summary: summary, board: board)
          _ = try board.forBuild(build)
          return FlashBundleImportValidation(
            byteCount: Int(summary.archiveSizeBytes),
            sha256: summary.archiveSHA256)
        } catch {
          throw FlashBundleArtifactImportError.invalidBundle("\(error)")
        }
      }
    ])
  }()
}

/// A file-backed Unix-socket upload. The 733 MB production archive never
/// becomes one `Data` value in either CLI or daemon. Upload identity,
/// offsets, target binding and the pinned archive facts are held server
/// side; a caller cannot nominate a daemon-local path.
actor FlashBundleArtifactImportCoordinator {
  static let maximumChunkBytes = 2 * 1_024 * 1_024
  /// Upper bound on a declared upload. Not a pin: the DAYU200 dailies run
  /// ~730 MB and this only stops a declaration that could never be an images
  /// archive from reserving staging space.
  static let maximumBundleBytes = 8 * 1_024 * 1_024 * 1_024
  private static let lifetimeSeconds: TimeInterval = 30 * 60

  struct Completed: Sendable {
    let target: RuntimeTargetRecord
    let name: String
    let sha256: String
    let byteCount: Int
    let fileURL: URL
  }

  private struct Session {
    let target: RuntimeTargetRecord
    let name: String
    let expectedByteCount: Int
    let expectedSHA256: String
    let validate: @Sendable (URL) throws -> FlashBundleImportValidation
    let createdAt: Date
    let fileURL: URL
    var descriptor: Int32
    var receivedByteCount: Int
  }

  private let policy: FlashBundleImportPolicy
  private let directoryURL: URL
  private let setupError: String?
  private var sessions: [String: Session] = [:]

  init(
    directoryURL: URL = FileManager.default.temporaryDirectory,
    policy: FlashBundleImportPolicy = .production
  ) {
    let workingDirectory = directoryURL.appendingPathComponent(
      "arkdeck-flash-import-\(UUID().uuidString.lowercased())",
      isDirectory: true)
    self.policy = policy
    self.directoryURL = workingDirectory
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var rootMetadata = stat()
      guard lstat(directoryURL.path, &rootMetadata) == 0,
        rootMetadata.st_mode & S_IFMT == S_IFDIR,
        rootMetadata.st_mode & 0o077 == 0
      else {
        throw FlashBundleArtifactImportError.stagingUnavailable
      }
      try FileManager.default.createDirectory(
        at: workingDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var metadata = stat()
      guard lstat(workingDirectory.path, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o077 == 0
      else {
        throw FlashBundleArtifactImportError.stagingUnavailable
      }
      setupError = nil
    } catch {
      setupError = "\(error)"
    }
  }

  deinit {
    for session in sessions.values {
      if session.descriptor >= 0 { Darwin.close(session.descriptor) }
    }
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func begin(
    target: RuntimeTargetRecord,
    name: String,
    byteCount: Int,
    sha256: String,
    now: Date = Date()
  ) throws -> String {
    guard setupError == nil else {
      throw FlashBundleArtifactImportError.stagingUnavailable
    }
    pruneExpired(now: now)
    guard name == "images.tar.gz" else {
      throw FlashBundleArtifactImportError.invalidName
    }
    // A declared size is admissible when it is a plausible upload; the
    // archive itself is judged on commit, by being read. Matching the
    // declaration against a list of known builds is what refused a firmware
    // daily published after the last release.
    guard byteCount > 0, byteCount <= FlashBundleArtifactImportCoordinator.maximumBundleBytes
    else {
      throw FlashBundleArtifactImportError.invalidByteCount
    }
    // Shape, not membership. Matching the declaration against a list of known
    // builds is what refused a firmware daily published after the last
    // release; a digest that is not a digest is still refusable here, without
    // reading anything.
    guard sha256.count == 64,
      sha256.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    else {
      throw FlashBundleArtifactImportError.invalidSHA256
    }
    guard let candidate = policy.candidate(byteCount: byteCount, sha256: sha256) else {
      throw FlashBundleArtifactImportError.invalidSHA256
    }
    let uploadID = "FLASH-\(UUID().uuidString.lowercased())"
    let fileURL = directoryURL.appendingPathComponent(uploadID)
    let descriptor = Darwin.open(
      fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw FlashBundleArtifactImportError.ioFailure(
        "cannot create staging file (errno \(errno))")
    }
    sessions[uploadID] = Session(
      target: target, name: name, expectedByteCount: byteCount,
      expectedSHA256: sha256, validate: candidate.validate,
      createdAt: now, fileURL: fileURL,
      descriptor: descriptor, receivedByteCount: 0)
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
      throw FlashBundleArtifactImportError.expiredUpload
    }
    guard var session = sessions[uploadID] else {
      throw FlashBundleArtifactImportError.unknownUpload
    }
    guard offset == session.receivedByteCount else {
      throw FlashBundleArtifactImportError.offsetMismatch(
        expected: session.receivedByteCount, actual: offset)
    }
    guard (1...Self.maximumChunkBytes).contains(chunk.count),
      chunk.count <= session.expectedByteCount - session.receivedByteCount
    else {
      throw FlashBundleArtifactImportError.invalidChunk
    }
    try chunk.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          session.descriptor, bytes.baseAddress!.advanced(by: written),
          bytes.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw FlashBundleArtifactImportError.ioFailure(
            "cannot append staging file (errno \(errno))")
        }
        written += count
      }
    }
    session.receivedByteCount += chunk.count
    sessions[uploadID] = session
    return session.receivedByteCount
  }

  func commit(uploadID: String, now: Date = Date()) throws -> Completed {
    let expired = pruneExpired(now: now)
    if expired.contains(uploadID) {
      throw FlashBundleArtifactImportError.expiredUpload
    }
    guard var session = sessions.removeValue(forKey: uploadID) else {
      throw FlashBundleArtifactImportError.unknownUpload
    }
    guard session.receivedByteCount == session.expectedByteCount else {
      sessions[uploadID] = session
      throw FlashBundleArtifactImportError.incompleteUpload(
        expected: session.expectedByteCount, actual: session.receivedByteCount)
    }
    guard fsync(session.descriptor) == 0 else {
      sessions[uploadID] = session
      throw FlashBundleArtifactImportError.ioFailure(
        "cannot synchronize staging file (errno \(errno))")
    }
    Darwin.close(session.descriptor)
    session.descriptor = -1
    do {
      let receipt = try session.validate(session.fileURL)
      guard receipt.byteCount == session.expectedByteCount,
        receipt.sha256 == session.expectedSHA256
      else {
        throw FlashBundleArtifactImportError.invalidBundle(
          "validator returned different archive facts")
      }
      return Completed(
        target: session.target, name: session.name,
        sha256: receipt.sha256, byteCount: receipt.byteCount,
        fileURL: session.fileURL)
    } catch let error as FlashBundleArtifactImportError {
      _ = Darwin.unlink(session.fileURL.path)
      throw error
    } catch {
      _ = Darwin.unlink(session.fileURL.path)
      throw FlashBundleArtifactImportError.invalidBundle("\(error)")
    }
  }

  @discardableResult
  func abort(uploadID: String) -> Bool {
    guard let session = sessions.removeValue(forKey: uploadID) else {
      return false
    }
    if session.descriptor >= 0 { Darwin.close(session.descriptor) }
    _ = Darwin.unlink(session.fileURL.path)
    return true
  }

  @discardableResult
  private func pruneExpired(now: Date) -> Set<String> {
    let expired = Set(
      sessions.compactMap { uploadID, session in
        now.timeIntervalSince(session.createdAt) > Self.lifetimeSeconds
          ? uploadID : nil
      })
    for uploadID in expired {
      guard let session = sessions.removeValue(forKey: uploadID) else { continue }
      if session.descriptor >= 0 { Darwin.close(session.descriptor) }
      _ = Darwin.unlink(session.fileURL.path)
    }
    return expired
  }
}
