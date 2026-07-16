import Darwin
import Foundation

/// The kernel-backed writer token for `PORT-INSTANCE-001`.
public final class SingleInstanceGuard: @unchecked Sendable {
  private let fileDescriptor: Int32

  private init(fileDescriptor: Int32) {
    self.fileDescriptor = fileDescriptor
  }

  deinit {
    Darwin.close(fileDescriptor)
  }

  public static func acquire(at lockFile: URL) throws -> SingleInstanceGuard {
    guard lockFile.isFileURL, lockFile.path.hasPrefix("/") else {
      throw SingleInstanceGuardError.lockPathMustBeAbsolute(lockFile.path)
    }

    try FileManager.default.createDirectory(
      at: lockFile.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try validateLockDirectory(lockFile.deletingLastPathComponent())

    let (descriptor, openError) = lockFile.withUnsafeFileSystemRepresentation { path in
      guard let path else { return (Int32(-1), EINVAL) }
      let descriptor = Darwin.open(
        path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
        S_IRUSR | S_IWUSR
      )
      return (descriptor, descriptor < 0 ? errno : 0)
    }
    guard descriptor >= 0 else {
      if openError == EWOULDBLOCK || openError == EAGAIN {
        throw SingleInstanceGuardError.alreadyHeld
      }
      throw SingleInstanceGuardError.lockUnavailable(errno: openError)
    }

    do {
      try validateLockFile(descriptor: descriptor, url: lockFile)
      return SingleInstanceGuard(fileDescriptor: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  public static func defaultLockFileURL(fileManager: FileManager = .default) throws -> URL {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return
      applicationSupport
      .appending(path: "ArkDeck", directoryHint: .isDirectory)
      .appending(path: "single-writer.lock", directoryHint: .notDirectory)
  }

  private static func validateLockFile(descriptor: Int32, url: URL) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw SingleInstanceGuardError.lockUnavailable(errno: errno)
    }
    guard metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == geteuid(), metadata.st_nlink == 1,
      metadata.st_mode & (S_IRWXG | S_IRWXO) == 0
    else {
      throw SingleInstanceGuardError.unsafeLockFile
    }

    let values = try url.resourceValues(forKeys: [.volumeIsLocalKey])
    guard values.volumeIsLocal == true else {
      throw SingleInstanceGuardError.unreliableFilesystem
    }
  }

  private static func validateLockDirectory(_ directory: URL) throws {
    var metadata = stat()
    let (result, statusError) = directory.withUnsafeFileSystemRepresentation { path in
      guard let path else { return (Int32(-1), EINVAL) }
      let result = Darwin.lstat(path, &metadata)
      return (result, result < 0 ? errno : 0)
    }
    guard result == 0 else {
      throw SingleInstanceGuardError.lockUnavailable(errno: statusError)
    }
    guard metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    else {
      throw SingleInstanceGuardError.unsafeLockDirectory
    }
  }
}

public enum SingleInstanceGuardError: Error, Equatable, LocalizedError, Sendable {
  case lockPathMustBeAbsolute(String)
  case alreadyHeld
  case unsafeLockDirectory
  case unsafeLockFile
  case unreliableFilesystem
  case lockUnavailable(errno: Int32)

  public var errorDescription: String? {
    switch self {
    case .lockPathMustBeAbsolute(let path):
      "Single-instance lock path must be absolute: \(path)"
    case .alreadyHeld:
      "Another ArkDeck writer already holds the single-instance lock"
    case .unsafeLockDirectory:
      "Single-instance lock directory is not a private user-owned directory"
    case .unsafeLockFile:
      "Single-instance lock is not a private, regular, single-link user-owned file"
    case .unreliableFilesystem:
      "Single-instance lock is not on a verified local filesystem"
    case .lockUnavailable(let errno):
      "Single-instance lock is unavailable (errno \(errno))"
    }
  }
}

public protocol SingleInstanceGuardAcquiring: Sendable {
  func acquire(at lockFile: URL) throws -> SingleInstanceGuard
}

public struct SystemSingleInstanceGuardAcquirer: SingleInstanceGuardAcquiring {
  public init() {}

  public func acquire(at lockFile: URL) throws -> SingleInstanceGuard {
    try SingleInstanceGuard.acquire(at: lockFile)
  }
}

/// Admission is the only runtime result available before Job, HDC, or Session
/// writers may be constructed.
public enum RuntimeInstanceAdmission: Sendable {
  case writer(SingleInstanceGuard)
  case secondary(ActivationDelivery)
  case readOnlyDiagnostics(String)
}

public struct RuntimeInstanceCoordinator: Sendable {
  private let lockFile: URL
  private let guardAcquirer: any SingleInstanceGuardAcquiring
  private let activationSender: any ActivationRequestSending

  public init(
    lockFile: URL,
    guardAcquirer: any SingleInstanceGuardAcquiring = SystemSingleInstanceGuardAcquirer(),
    activationSender: any ActivationRequestSending
  ) {
    self.lockFile = lockFile
    self.guardAcquirer = guardAcquirer
    self.activationSender = activationSender
  }

  public func admit() -> RuntimeInstanceAdmission {
    do {
      return .writer(try guardAcquirer.acquire(at: lockFile))
    } catch SingleInstanceGuardError.alreadyHeld {
      return .secondary(activationSender.requestActivation())
    } catch {
      return .readOnlyDiagnostics(error.localizedDescription)
    }
  }

  /// Runs writer-resource initialization only after kernel-backed writer
  /// admission. The closure is deliberately part of the admission boundary so
  /// secondary and uncertain paths cannot construct Job, HDC, or Session writers.
  public func admit(
    initializingWriterResources initializeWriterResources: () throws -> Void
  ) rethrows -> RuntimeInstanceAdmission {
    let admission = admit()
    if case .writer = admission {
      try initializeWriterResources()
    }
    return admission
  }
}
