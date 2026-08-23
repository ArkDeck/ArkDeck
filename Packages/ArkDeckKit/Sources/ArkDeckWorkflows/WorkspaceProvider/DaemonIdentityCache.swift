import Foundation
import os

/// Memoises a value derived from one file, keyed on that file's identity.
///
/// Runtime answers "is this provider available" by re-deriving facts from the
/// files behind it, and `operationAvailability()` asks that question once per
/// published operation. With twenty-five operations that meant hashing the
/// same executables twenty-five times per call: a sample of the daemon during
/// `operation.list` put about sixty percent of its time inside SHA-256, and
/// the call cost seconds.
///
/// Invalidation is by **file identity** — device, inode, size, and both
/// modification and change times. Replacing a file moves at least one of
/// these, so a changed file is always re-derived. A file that cannot be
/// stat'd is never a hit: not being able to see a file is not evidence about
/// what it contains, and a failed derivation is never stored, so refusals
/// stay repeatable rather than sticky.
///
/// `expirySeconds` exists for values that are *not* purely a function of the
/// bytes. A content hash is; code-signature validity is not, because a
/// certificate can be revoked while the file sits still.
package final class FileDerivedCache: Sendable {
  private struct Entry: Sendable {
    let identity: FileIdentity
    let derivedAt: Date
    let value: String
  }

  package struct FileIdentity: Sendable, Equatable {
    package let device: Int32
    package let inode: UInt64
    package let size: Int64
    package let modified: timespec
    package let changed: timespec

    package static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
        && lhs.modified.tv_sec == rhs.modified.tv_sec
        && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        && lhs.changed.tv_sec == rhs.changed.tv_sec
        && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }

    package static func read(_ url: URL) -> FileIdentity? {
      var info = stat()
      guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
      return FileIdentity(
        device: info.st_dev, inode: info.st_ino, size: info.st_size,
        modified: info.st_mtimespec, changed: info.st_ctimespec)
    }
  }

  private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
  private let expirySeconds: TimeInterval?
  private let now: @Sendable () -> Date

  package init(
    expirySeconds: TimeInterval?,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.expirySeconds = expirySeconds
    self.now = now
  }

  /// The memoised value, or `nil` when the caller must derive it.
  package func value(for url: URL) -> String? {
    guard let identity = FileIdentity.read(url) else { return nil }
    let current = now()
    return entries.withLock { entries -> String? in
      guard let entry = entries[url.path], entry.identity == identity else { return nil }
      if let expirySeconds, current.timeIntervalSince(entry.derivedAt) >= expirySeconds {
        return nil
      }
      return entry.value
    }
  }

  package func store(_ value: String?, for url: URL) {
    guard let value, let identity = FileIdentity.read(url) else { return }
    let entry = Entry(identity: identity, derivedAt: now(), value: value)
    entries.withLock { $0[url.path] = entry }
  }

  package func invalidate() {
    entries.withLock { $0.removeAll() }
  }
}

/// The process-wide memos. Both are keyed on file identity; they differ only
/// in whether the value they hold can change while the file does not.
package enum RuntimeFileDerivedCaches {
  /// A content hash is a pure function of the bytes, so file identity is the
  /// complete invalidation condition.
  package static let executableDigest = FileDerivedCache(expirySeconds: nil)

  /// Code-signature validity is not a pure function of the bytes: a signing
  /// certificate can be revoked without the file moving. A short window keeps
  /// that observable while still removing the cost from an interactive path.
  package static let daemonIdentity = FileDerivedCache(expirySeconds: 60)
}
