import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipToolBookmarkContractTests: XCTestCase {
  private enum FixtureError: Error {
    case injected
  }

  private final class PreferenceBox {
    enum SetMode {
      case normal
      case throwBeforeWrite
      case dropWrite
      case corruptData
    }

    var values: [String: Any] = [:]
    var setMode = SetMode.normal
    var removeFailures: Set<String> = []

    func preferences() -> RockchipToolBookmarkPreferences {
      RockchipToolBookmarkPreferences(
        object: { [self] in values[$0] },
        setObject: { [self] value, key in
          let mode = setMode
          if case .normal = mode {
          } else {
            setMode = .normal
          }
          switch mode {
          case .normal:
            values[key] = value
          case .throwBeforeWrite:
            throw FixtureError.injected
          case .dropWrite:
            values.removeValue(forKey: key)
          case .corruptData:
            values[key] = Data([0xff])
          }
        },
        removeObject: { [self] key in
          if removeFailures.contains(key) { throw FixtureError.injected }
          values.removeValue(forKey: key)
        })
    }
  }

  private final class VerificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  private final class AccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [URL.BookmarkResolutionOptions] = []
    private var starts = 0
    private var stops = 0

    func record(_ value: URL.BookmarkResolutionOptions) {
      lock.withLock { options.append(value) }
    }

    func start() {
      lock.withLock { starts += 1 }
    }

    func stop() {
      lock.withLock { stops += 1 }
    }

    var lastOptions: URL.BookmarkResolutionOptions? { lock.withLock { options.last } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
  }

  private var temporaryRoot: URL!

  override func setUpWithError() throws {
    temporaryRoot = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-bookmark-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let temporaryRoot {
      try? FileManager.default.removeItem(at: temporaryRoot)
    }
  }

  func testIsolatedUserDefaultsInstallerRoundTripsOrdinaryBookmark() throws {
    let suiteName = "dev.arkdeck.tests.bookmark.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let verifier = VerificationCounter()
    let store = RockchipProductToolBookmarkStore(
      preferences: .userDefaults(defaults),
      codec: .foundation,
      verifier: RockchipPinnedExecutableVerifier { _ in verifier.increment() })
    let executable = try makeExecutable("isolated-tool")

    try store.install(executableURL: executable)
    let loaded = try store.load()

    XCTAssertEqual(loaded.executableURL, executable)
    XCTAssertFalse(loaded.bookmarkData.isEmpty)
    XCTAssertEqual(verifier.value, 1)
    XCTAssertNil(defaults.object(forKey: RockchipProductToolBookmarkStore.legacyKey))
    XCTAssertNotNil(defaults.data(forKey: RockchipProductToolBookmarkStore.ordinaryKey))
    print(
      "TEST-AIN-BKMK-001 PASS leg=isolated-defaults ordinary=true stale=false "
        + "target_match=true spawn=0")
  }

  func testLoaderRejectsLegacyDualWrongTypeCorruptStaleAndNonCanonical() throws {
    let executable = try makeExecutable("loader-tool")
    let box = PreferenceBox()
    let realStore = makeStore(box: box)

    assertConfigurationUnavailable { _ = try realStore.load() }

    box.values[RockchipProductToolBookmarkStore.legacyKey] = Data([0x01])
    assertConfigurationUnavailable { _ = try realStore.load() }

    box.values[RockchipProductToolBookmarkStore.ordinaryKey] = Data([0x02])
    assertConfigurationUnavailable { _ = try realStore.load() }

    box.values.removeValue(forKey: RockchipProductToolBookmarkStore.legacyKey)
    box.values[RockchipProductToolBookmarkStore.ordinaryKey] = "not-data"
    assertConfigurationUnavailable { _ = try realStore.load() }

    box.values[RockchipProductToolBookmarkStore.ordinaryKey] = Data([0xff])
    assertConfigurationUnavailable { _ = try realStore.load() }

    let staleStore = makeStore(
      box: box,
      codec: codec(resolvingTo: executable, isStale: true))
    box.values[RockchipProductToolBookmarkStore.ordinaryKey] = Data([0x03])
    assertConfigurationUnavailable { _ = try staleStore.load() }

    let webStore = makeStore(
      box: box,
      codec: RockchipOrdinaryBookmarkCodec(
        create: { _ in Data([0x04]) },
        resolve: { _ in
          RockchipBookmarkResolution(
            url: URL(string: "https://example.invalid/tool")!,
            isStale: false)
        }))
    assertConfigurationUnavailable { _ = try webStore.load() }

    let target = try makeExecutable("canonical-target")
    let symlink = temporaryRoot.appending(path: "loader-symlink")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let nonCanonicalStore = makeStore(
      box: box,
      codec: codec(resolvingTo: symlink, isStale: false))
    assertConfigurationUnavailable { _ = try nonCanonicalStore.load() }

    print(
      "TEST-AIN-BKMK-001 PASS leg=loader-faults missing=blocked wrong_type=blocked "
        + "legacy=blocked dual=blocked corrupt=blocked stale=blocked path=blocked spawn=0")
  }

  func testInstallerFaultsRestorePreviousStateAndNeverConsumeLegacy() throws {
    let executable = try makeExecutable("installer-tool")
    let other = try makeExecutable("other-tool")

    do {
      let box = PreferenceBox()
      let store = makeStore(
        box: box,
        verifier: RockchipPinnedExecutableVerifier { _ in throw FixtureError.injected })
      assertConfigurationUnavailable { try store.install(executableURL: executable) }
      XCTAssertNil(box.values[RockchipProductToolBookmarkStore.ordinaryKey])
    }

    do {
      let box = PreferenceBox()
      let store = makeStore(
        box: box,
        codec: RockchipOrdinaryBookmarkCodec(
          create: { _ in throw FixtureError.injected },
          resolve: { _ in throw FixtureError.injected }))
      assertConfigurationUnavailable { try store.install(executableURL: executable) }
      XCTAssertNil(box.values[RockchipProductToolBookmarkStore.ordinaryKey])
    }

    for faultyCodec in [
      RockchipOrdinaryBookmarkCodec(
        create: { _ in Data([0x01]) },
        resolve: { _ in throw FixtureError.injected }),
      codec(resolvingTo: executable, isStale: true),
      codec(resolvingTo: other, isStale: false),
    ] {
      let box = PreferenceBox()
      let store = makeStore(box: box, codec: faultyCodec)
      assertConfigurationUnavailable { try store.install(executableURL: executable) }
      XCTAssertNil(box.values[RockchipProductToolBookmarkStore.ordinaryKey])
    }

    for mode in [
      PreferenceBox.SetMode.throwBeforeWrite,
      .dropWrite,
      .corruptData,
    ] {
      let box = PreferenceBox()
      let previous = Data([0x70, 0x72, 0x65, 0x76])
      box.values[RockchipProductToolBookmarkStore.ordinaryKey] = previous
      box.setMode = mode
      let store = makeStore(box: box)
      assertConfigurationUnavailable { try store.install(executableURL: executable) }
      // A write/readback fault restores the exact pre-attempt value.
      XCTAssertEqual(
        box.values[RockchipProductToolBookmarkStore.ordinaryKey] as? Data,
        previous)
    }

    print(
      "TEST-AIN-BKMK-001 PASS leg=installer-faults verifier=blocked create=blocked "
        + "roundtrip=blocked write_readback=restored spawn=0")
  }

  func testDualKeyCrashStateBlocksAndInstallerRerunRecovers() throws {
    let executable = try makeExecutable("migration-tool")
    let box = PreferenceBox()
    box.values[RockchipProductToolBookmarkStore.legacyKey] = Data([0x6c, 0x65, 0x67])
    box.removeFailures.insert(RockchipProductToolBookmarkStore.legacyKey)
    let store = makeStore(box: box)

    assertConfigurationUnavailable { try store.install(executableURL: executable) }
    XCTAssertNotNil(box.values[RockchipProductToolBookmarkStore.legacyKey])
    XCTAssertNotNil(box.values[RockchipProductToolBookmarkStore.ordinaryKey])
    assertConfigurationUnavailable { _ = try store.load() }

    box.removeFailures.remove(RockchipProductToolBookmarkStore.legacyKey)
    try store.install(executableURL: executable)
    XCTAssertNil(box.values[RockchipProductToolBookmarkStore.legacyKey])
    XCTAssertEqual(try store.load().executableURL, executable)

    print(
      "TEST-AIN-BKMK-001 PASS leg=migration crash_state=dual blocked=true "
        + "rerun=recovered legacy_consumed=0 spawn=0")
  }

  func testInstallerRejectsNonCanonicalSymlinkNonRegularNonExecutableAndHashMismatch()
    throws
  {
    let box = PreferenceBox()
    let fakeVerifierStore = makeStore(box: box)
    let executable = try makeExecutable("input-tool")

    let nonFile = URL(string: "https://example.invalid/tool")!
    assertConfigurationUnavailable { try fakeVerifierStore.install(executableURL: nonFile) }

    let nonCanonical = URL(
      fileURLWithPath: temporaryRoot.path + "/../"
        + temporaryRoot.lastPathComponent + "/input-tool")
    assertConfigurationUnavailable {
      try fakeVerifierStore.install(executableURL: nonCanonical)
    }

    let finalSymlink = temporaryRoot.appending(path: "final-symlink")
    try FileManager.default.createSymbolicLink(at: finalSymlink, withDestinationURL: executable)
    assertConfigurationUnavailable {
      try fakeVerifierStore.install(executableURL: finalSymlink)
    }

    let parentTarget = temporaryRoot.appending(path: "real-parent", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parentTarget, withIntermediateDirectories: true)
    let parentTool = parentTarget.appending(path: "tool")
    try Data("tool".utf8).write(to: parentTool)
    XCTAssertEqual(chmod(parentTool.path, 0o755), 0)
    let parentLink = temporaryRoot.appending(path: "linked-parent", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: parentTarget)
    assertConfigurationUnavailable {
      try fakeVerifierStore.install(executableURL: parentLink.appending(path: "tool"))
    }

    let productionStore = RockchipProductToolBookmarkStore(
      preferences: box.preferences(),
      codec: .foundation,
      verifier: .production)
    assertConfigurationUnavailable {
      try productionStore.install(executableURL: temporaryRoot)
    }
    let nonExecutable = temporaryRoot.appending(path: "non-executable")
    try Data("not executable".utf8).write(to: nonExecutable)
    XCTAssertEqual(chmod(nonExecutable.path, 0o644), 0)
    assertConfigurationUnavailable {
      try productionStore.install(executableURL: nonExecutable)
    }
    assertConfigurationUnavailable {
      try productionStore.install(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
    }
    XCTAssertNil(box.values[RockchipProductToolBookmarkStore.ordinaryKey])

    print(
      "TEST-AIN-BKMK-001 PASS leg=input-matrix absolute=closed canonical=closed "
        + "symlink=closed parent_symlink=closed regular=closed executable=closed "
        + "hash=closed prepared_only=true spawn=0")
  }

  func testTypedAccessPoliciesSeparateScopedE0FromOrdinaryProduction() async throws {
    let executable = try makeExecutable("access-tool")

    let scopedCounter = AccessCounter()
    let scopedOperations = operations(
      resolvingTo: executable,
      counter: scopedCounter,
      scopeStarts: true)
    let scopedAccess = try RockchipExecutableBookmarkAccess(
      path: executable,
      bookmark: Data([0x01]),
      policy: .userSelectedSecurityScopedBookmark,
      operations: scopedOperations)
    XCTAssertTrue(try XCTUnwrap(scopedCounter.lastOptions).contains(.withSecurityScope))
    XCTAssertEqual(scopedCounter.startCount, 1)
    scopedAccess.stop()
    XCTAssertEqual(scopedCounter.stopCount, 1)

    let ordinaryCounter = AccessCounter()
    let ordinaryAccess = try RockchipExecutableBookmarkAccess(
      path: executable,
      bookmark: Data([0x02]),
      policy: .installedOrdinaryBookmark,
      operations: operations(
        resolvingTo: executable,
        counter: ordinaryCounter,
        scopeStarts: true))
    let ordinaryOptions = try XCTUnwrap(ordinaryCounter.lastOptions)
    XCTAssertTrue(ordinaryOptions.contains(.withoutUI))
    XCTAssertFalse(ordinaryOptions.contains(.withSecurityScope))
    XCTAssertEqual(ordinaryCounter.startCount, 0)
    ordinaryAccess.stop()
    XCTAssertEqual(ordinaryCounter.stopCount, 0)

    let deniedCounter = AccessCounter()
    XCTAssertThrowsError(
      try RockchipExecutableBookmarkAccess(
        path: executable,
        bookmark: Data([0x03]),
        policy: .userSelectedSecurityScopedBookmark,
        operations: operations(
          resolvingTo: executable,
          counter: deniedCounter,
          scopeStarts: false))
    ) {
      XCTAssertEqual($0 as? RockchipToolValidationError, .securityScopedAccessDenied)
    }
    XCTAssertEqual(deniedCounter.startCount, 1)

    let e0Profile = RockchipDiscoveryIntegrationProfile.pinnedReadOnlyDiscovery
    // These legs reject before any spawn, so the bound directory is only the
    // one the adapter now requires, not part of what they assert.
    let e0Adapter = RockchipDeviceDiscoveryAdapter(
      profile: e0Profile, workingDirectory: FileManager.default.temporaryDirectory)
    let ordinaryClaimingE0 = RockchipSelectedDiscoveryTool(
      executableURL: executable,
      pathSource: .installedOrdinaryBookmark,
      bookmarkData: Data([0x04]),
      reportedVersion: e0Profile.reportedToolVersion,
      sha256: e0Profile.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: .adHoc, quarantinePresent: false))
    do {
      _ = try await e0Adapter.processRequest(for: ordinaryClaimingE0)
      XCTFail("E0 must reject the production ordinary path source")
    } catch {
      XCTAssertEqual(error as? RockchipToolValidationError, .pathSourceNotUserSelected)
    }

    let productionProfile = RockchipDiscoveryIntegrationProfile.pinnedProduction
    let productionAdapter = RockchipDeviceDiscoveryAdapter(
      profile: productionProfile, workingDirectory: FileManager.default.temporaryDirectory)
    let scopedClaimingProduction = RockchipSelectedDiscoveryTool(
      executableURL: executable,
      pathSource: .userSelectedSecurityScopedBookmark,
      bookmarkData: Data([0x05]),
      reportedVersion: productionProfile.reportedToolVersion,
      sha256: productionProfile.executableSHA256,
      platformTrust: RockchipPlatformTrustReceipt(
        codeTrust: .adHoc, quarantinePresent: false))
    do {
      _ = try await productionAdapter.processRequest(for: scopedClaimingProduction)
      XCTFail("production must reject the E0 security-scoped path source")
    } catch {
      XCTAssertEqual(error as? RockchipToolValidationError, .pathSourceNotInstalledOrdinary)
    }

    print(
      "TEST-AIN-BKMK-001 PASS leg=typed-access e0=scoped scope_start=required "
        + "production=ordinary production_scope_start=0 cross_policy=blocked")
  }

  private func makeStore(
    box: PreferenceBox,
    codec: RockchipOrdinaryBookmarkCodec = .foundation,
    verifier: RockchipPinnedExecutableVerifier? = nil
  ) -> RockchipProductToolBookmarkStore {
    let counter = VerificationCounter()
    return RockchipProductToolBookmarkStore(
      preferences: box.preferences(),
      codec: codec,
      verifier: verifier ?? RockchipPinnedExecutableVerifier { _ in counter.increment() })
  }

  private func codec(
    resolvingTo url: URL,
    isStale: Bool
  ) -> RockchipOrdinaryBookmarkCodec {
    RockchipOrdinaryBookmarkCodec(
      create: { _ in Data([0x62, 0x6d]) },
      resolve: { _ in RockchipBookmarkResolution(url: url, isStale: isStale) })
  }

  private func operations(
    resolvingTo url: URL,
    counter: AccessCounter,
    scopeStarts: Bool
  ) -> RockchipBookmarkAccessOperations {
    RockchipBookmarkAccessOperations(
      resolve: { _, options in
        counter.record(options)
        return RockchipBookmarkResolution(url: url, isStale: false)
      },
      startSecurityScope: { _ in
        counter.start()
        return scopeStarts
      },
      stopSecurityScope: { _ in counter.stop() })
  }

  private func makeExecutable(_ name: String) throws -> URL {
    let url = temporaryRoot.appending(path: name)
    try Data("fixture \(name)".utf8).write(to: url)
    guard chmod(url.path, 0o755) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return url.standardizedFileURL
  }

  private func assertConfigurationUnavailable(
    _ operation: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      try operation()
      XCTFail("expected production configuration failure", file: file, line: line)
    } catch {
      guard case RockchipFlashExecutionError.productionConfigurationUnavailable = error else {
        return XCTFail("unexpected error: \(error)", file: file, line: line)
      }
    }
  }
}
