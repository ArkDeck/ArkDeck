import Foundation
import XCTest

@testable import ArkDeckWorkflows

/// The cache that removed a two-second strict code-signature evaluation from
/// every operation availability query.
///
/// Caching an answer about a binary's signature is only safe if the cache
/// cannot outlive the thing it describes. These assert the invalidation
/// conditions directly rather than by timing anything.
final class FileDerivedCacheTests: XCTestCase {
  private var directory: URL!
  private var file: URL!

  override func setUpWithError() throws {
    directory = URL(filePath: NSTemporaryDirectory())
      .appending(path: "arkdeck-identity-cache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    file = directory.appending(path: "helper")
    try Data("one".utf8).write(to: file)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testAStoredFingerprintIsReturnedForTheSameFile() {
    let cache = FileDerivedCache(expirySeconds: 60)
    cache.store("fingerprint-a", for: file)
    XCTAssertEqual(cache.value(for: file), "fingerprint-a")
  }

  func testReplacingTheFileInvalidatesTheEntry() throws {
    let cache = FileDerivedCache(expirySeconds: 60)
    cache.store("fingerprint-a", for: file)
    XCTAssertEqual(cache.value(for: file), "fingerprint-a")

    // Replacing the helper is the only way its signature can change, and it
    // always moves the file's identity.
    try FileManager.default.removeItem(at: file)
    try Data("two-different-length".utf8).write(to: file)
    XCTAssertNil(
      cache.value(for: file),
      "a replaced helper must be validated again, not answered from cache")
  }

  /// A Sendable clock the test can move, so expiry is asserted rather than
  /// waited for.
  private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var current: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  func testAnExpiredEntryIsNotReturned() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let cache = FileDerivedCache(expirySeconds: 60, now: { clock.current })
    cache.store("fingerprint-a", for: file)
    XCTAssertEqual(cache.value(for: file), "fingerprint-a")

    clock.advance(60.0 - 1)
    XCTAssertEqual(cache.value(for: file), "fingerprint-a", "still inside the window")

    clock.advance(2)
    XCTAssertNil(
      cache.value(for: file),
      "validity is not purely a function of the bytes; a revocation must surface")
  }

  func testAMissingFileIsNeverAHit() throws {
    let cache = FileDerivedCache(expirySeconds: 60)
    cache.store("fingerprint-a", for: file)
    try FileManager.default.removeItem(at: file)
    XCTAssertNil(
      cache.value(for: file),
      "being unable to see the file is not evidence about what it contains")
  }

  func testAFailedEvaluationIsNotCached() {
    let cache = FileDerivedCache(expirySeconds: 60)
    // A refusal has no fingerprint. Storing one would make the next caller
    // inherit a refusal it never evaluated.
    cache.store(nil, for: file)
    XCTAssertNil(cache.value(for: file))
  }

  /// A content hash never expires on its own: the bytes decide it, and the
  /// file identity already covers the bytes changing.
  func testAPureContentValueDoesNotExpire() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let cache = FileDerivedCache(expirySeconds: nil, now: { clock.current })
    cache.store("digest-a", for: file)
    clock.advance(86_400)
    XCTAssertEqual(
      cache.value(for: file), "digest-a",
      "a hash of unchanged bytes cannot become wrong by waiting")
  }

  func testInvalidateDropsEverything() {
    let cache = FileDerivedCache(expirySeconds: 60)
    cache.store("fingerprint-a", for: file)
    cache.invalidate()
    XCTAssertNil(cache.value(for: file))
  }

  /// The workspace resolver's drift refusal reads its digest through the
  /// process-wide memo rather than re-hashing. That is only safe while
  /// replacing an executable still produces a different digest — otherwise
  /// availability would keep vouching for bytes that are gone.
  func testHashingAnExecutableReDerivesAfterItIsReplaced() throws {
    let executable = directory.appending(path: "tool")
    try Data("first".utf8).write(to: executable)
    let before = try WorkspaceExecutableIdentity.hashing(path: executable.path).sha256

    try Data("second-and-longer".utf8).write(to: executable)
    let after = try WorkspaceExecutableIdentity.hashing(path: executable.path).sha256

    XCTAssertNotEqual(
      before, after, "a replaced executable must not keep its old digest")
    XCTAssertEqual(
      try WorkspaceExecutableIdentity.hashing(path: executable.path).sha256, after,
      "the second read of unchanged bytes must agree with the first")
  }
}
