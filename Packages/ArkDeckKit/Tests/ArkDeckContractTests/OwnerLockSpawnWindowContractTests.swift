import Darwin
import Foundation
import XCTest

@testable import ArkDeckBootstrap
@testable import ArkDeckClientKit
@testable import ArkDeckCore
@testable import ArkDeckStorage
@testable import ArkDeckWorkflows

/// A child that another thread spawns shares every open file description of
/// this process until its exec closes the close-on-exec ones, and a flock
/// belongs to the open file description. An owner lock released by close()
/// alone therefore stays held while such a child exists, and the next
/// non-blocking acquisition is refused; the Rust host-store owners were
/// (TASK-XPA-012 host-lock-spawn-window-run.md). flock(LOCK_UN) releases a
/// description's lock for every holder of that description, so an owner that
/// unlocks before it closes is not exposed. Every Swift owner that takes
/// flock(LOCK_EX | LOCK_NB) does; these tests keep it that way.
///
/// A child inherits the owner's locked description across its exec and keeps
/// it until the test releases it: the fork-to-exec window, held for as long as
/// the test needs. The owner then releases its lock, and its next non-blocking
/// acquisition must succeed while the child still holds the description. Each
/// control releases a description of the same lock by close() alone and shows
/// the owner refusing until the child exits.
final class OwnerLockSpawnWindowContractTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(filePath: "/private/tmp/owner-lock-\(UUID().uuidString.prefix(8).lowercased())")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  func testBootstrapOwnerIsNotRefusedWhileAChildStillSharesItsReleasedLock() throws {
    let registry = BootstrapBundleRegistry(root: root.appending(path: "registry"))
    let lock = root.appending(path: "registry/.lock")
    var child: DescriptionSharingChild?
    try registry.withSharedStore { _, _ in child = try DescriptionSharingChild(sharing: lock) }
    XCTAssertNotNil(child)
    XCTAssertNoThrow(try registry.withSharedStore(create: false) { _, _ in })
    child?.release()

    try closeOnlyRelease(of: lock) {
      assertFailure("resourceConflict") { try registry.withSharedStore(create: false) { _, _ in } }
    }
    XCTAssertNoThrow(try registry.withSharedStore(create: false) { _, _ in })
  }

  func testHDCControlActionStoreIsNotRefusedWhileAChildStillSharesItsReleasedLock() throws {
    let directory = root.appending(path: "hdc-control-actions")
    let store = try RuntimeHDCControlActionStore(directory: directory)
    XCTAssertTrue(try store.list().isEmpty)
    let child = try childSharingTransactionLock(in: directory) { _ = try store.list() }
    XCTAssertNoThrow(XCTAssertTrue(try store.list().isEmpty))
    child.release()

    try closeOnlyRelease(of: directory.appending(path: ".lock")) {
      assertFailure("resourceConflict") { _ = try store.list() }
    }
    XCTAssertTrue(try store.list().isEmpty)
  }

  func testToolSelectionControlActionStoreIsNotRefusedWhileAChildStillSharesItsReleasedLock()
    throws
  {
    let directory = root.appending(path: "tool-selection-actions")
    let store = try RuntimeToolSelectionControlActionStore(directory: directory)
    XCTAssertTrue(try store.list().isEmpty)
    let child = try childSharingTransactionLock(in: directory) { _ = try store.list() }
    XCTAssertNoThrow(XCTAssertTrue(try store.list().isEmpty))
    child.release()

    try closeOnlyRelease(of: directory.appending(path: ".lock")) {
      assertFailure("resourceConflict") { _ = try store.list() }
    }
    XCTAssertTrue(try store.list().isEmpty)
  }

  func testSessionAuditWriterIsNotRefusedWhileAChildStillSharesItsReleasedLock() throws {
    let layout = try SessionLayout(
      sessionID: "session-1", jobID: "job-1", root: root.appending(path: "session-1"))
    var writer: FileDurableSessionAuditStore? = try FileDurableSessionAuditStore(layout: layout)
    XCTAssertNotNil(writer)
    let child = try DescriptionSharingChild(sharing: layout.sessionAuditURL)
    writer = nil
    XCTAssertNoThrow(try FileDurableSessionAuditStore(layout: layout))
    child.release()

    try closeOnlyRelease(of: layout.sessionAuditURL) {
      XCTAssertThrowsError(try FileDurableSessionAuditStore(layout: layout)) { failure in
        XCTAssertTrue("\(failure)".contains("active writer"), "\(failure)")
      }
    }
    XCTAssertNoThrow(try FileDurableSessionAuditStore(layout: layout))
  }

  func testUpdateOperationLeaseIsNotReportedActiveWhileAChildStillSharesItsReleasedLock() throws {
    let directory = root.appending(path: "update", directoryHint: .isDirectory)
    let lock = directory.appending(path: ".operation-v1.lock")
    let store = RuntimeUpdateStateStore(directory: directory)
    var lease: RuntimeUpdateOperationLease? = try store.acquireOperationLease()
    XCTAssertNotNil(lease)
    let child = try DescriptionSharingChild(sharing: lock)
    lease = nil
    XCTAssertFalse(try store.operationIsActive())
    XCTAssertNoThrow(try store.acquireOperationLease())
    child.release()

    try closeOnlyRelease(of: lock) { XCTAssertTrue(try store.operationIsActive()) }
    XCTAssertFalse(try store.operationIsActive())
  }

  /// Locks `file` through a description of the test's own, lets a child
  /// inherit that description, and releases it by close() alone. `whileHeld`
  /// runs while the child still holds it; the child exits afterwards.
  private func closeOnlyRelease(of file: URL, whileHeld: () throws -> Void) throws {
    let descriptor = open(file.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ChildFailure("cannot open \(file.path): errno \(errno)") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw ChildFailure("cannot lock \(file.path): errno \(errno)")
    }
    let child: DescriptionSharingChild
    do { child = try DescriptionSharingChild(sharing: file) } catch {
      close(descriptor)
      throw error
    }
    close(descriptor)
    defer { child.release() }
    try whileHeld()
  }

  /// Holds `transaction` inside its locked section on another thread. A FIFO
  /// named like a record makes the store's record read wait for a writer;
  /// while it waits, a child inherits the store's lock description. Opening
  /// the FIFO lets the transaction fail on the non-regular record and release
  /// its lock, and the child is returned still holding the description.
  private func childSharingTransactionLock(
    in directory: URL, transaction: @escaping @Sendable () throws -> Void
  ) throws -> DescriptionSharingChild {
    let lock = directory.appending(path: ".lock")
    let record = directory.appending(path: "action-\(String(repeating: "0", count: 64)).json")
    guard mkfifo(record.path, 0o600) == 0 else { throw ChildFailure("mkfifo: errno \(errno)") }
    defer { unlink(record.path) }
    let outcome = TransactionOutcome()
    DispatchQueue.global().async {
      do {
        try transaction()
        outcome.finish(nil)
      } catch { outcome.finish(error) }
    }
    let deadline = Date().addingTimeInterval(30)
    // The store opens its lock before it reads a record and keeps it open
    // until that read returns, which needs the writer opened below.
    while openDescriptors(of: lock).isEmpty {
      guard !outcome.isFinished, Date() < deadline else {
        throw ChildFailure(
          "the transaction never held its lock: \(String(describing: outcome.error))")
      }
      usleep(1_000)
    }
    let child = try DescriptionSharingChild(sharing: lock)
    var writer = open(record.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
    while writer < 0 {
      guard errno == ENXIO, !outcome.isFinished, Date() < deadline else {
        child.release()
        throw ChildFailure(
          "the transaction never read the record: \(String(describing: outcome.error))")
      }
      usleep(1_000)
      writer = open(record.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
    }
    close(writer)
    while !outcome.isFinished {
      guard Date() < deadline else {
        child.release()
        throw ChildFailure("the transaction did not return after its record read")
      }
      usleep(1_000)
    }
    // The transaction reached the FIFO with its lock held and refused it.
    XCTAssertEqual(
      (outcome.error as? AgentExecutionControlFailure)?.code, "recordUnreadable",
      "\(String(describing: outcome.error))")
    return child
  }

  private func assertFailure(
    _ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try body(), file: file, line: line) { failure in
      XCTAssertEqual(
        (failure as? AgentExecutionControlFailure)?.code, code, "\(failure)",
        file: file, line: line)
    }
  }
}

/// A child process that holds every description this process has open on one
/// file until `release()`.
private final class DescriptionSharingChild {
  private let pid: pid_t
  private var input: Int32

  init(sharing file: URL) throws {
    let shared = openDescriptors(of: file)
    guard !shared.isEmpty else { throw ChildFailure("no open description of \(file.path)") }
    var pipe: [Int32] = [-1, -1]
    guard Darwin.pipe(&pipe) == 0 else { throw ChildFailure("pipe: errno \(errno)") }
    _ = fcntl(pipe[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(pipe[1], F_SETFD, FD_CLOEXEC)
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    // Only what the file actions name survives the exec: stdin, the output
    // sinks and the shared descriptions.
    var configured =
      posix_spawn_file_actions_adddup2(&actions, pipe[0], STDIN_FILENO) == 0
      && posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0
      && posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
      && posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
    for descriptor in shared {
      configured =
        configured && posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0
    }
    let words = ["/bin/sh", "-c", "read line"]
    let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    defer { for argument in arguments { free(argument) } }
    let environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var child: pid_t = 0
    let status =
      configured
      ? posix_spawn(&child, "/bin/sh", &actions, &attributes, arguments, environment) : EINVAL
    close(pipe[0])
    guard status == 0 else {
      close(pipe[1])
      throw ChildFailure("posix_spawn: \(status)")
    }
    pid = child
    input = pipe[1]
  }

  deinit { release() }

  /// The child exits at the end of its input, closing the descriptions.
  func release() {
    guard input >= 0 else { return }
    close(input)
    input = -1
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
  }
}

private final class TransactionOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var finished = false
  private var failure: Error?

  func finish(_ error: Error?) {
    lock.withLock {
      failure = error
      finished = true
    }
  }

  var isFinished: Bool { lock.withLock { finished } }
  var error: Error? { lock.withLock { failure } }
}

private struct ChildFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Every descriptor of this process that is open on `file`.
private func openDescriptors(of file: URL) -> [Int32] {
  var target = stat()
  guard lstat(file.path, &target) == 0,
    let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
  else { return [] }
  return names.compactMap { Int32($0) }.filter { descriptor in
    var metadata = stat()
    return fstat(descriptor, &metadata) == 0 && metadata.st_dev == target.st_dev
      && metadata.st_ino == target.st_ino
  }.sorted()
}
