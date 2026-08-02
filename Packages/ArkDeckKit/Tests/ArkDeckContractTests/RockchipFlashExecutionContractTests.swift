import ArkDeckCore
import ArkDeckProcess
import ArkDeckStorage
import Compression
import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class RockchipFlashExecutionContractTests: XCTestCase {
  private enum ToolPreferenceFailure: Error { case injected }

  private final class ToolPreferenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var failingSetKey: String?

    func preferences() -> RockchipToolBookmarkPreferences {
      RockchipToolBookmarkPreferences(
        object: { [self] key in lock.withLock { values[key] } },
        setObject: { [self] value, key in
          try lock.withLock {
            if failingSetKey == key {
              failingSetKey = nil
              throw ToolPreferenceFailure.injected
            }
            values[key] = value
          }
        },
        removeObject: { [self] key in lock.withLock { values.removeValue(forKey: key) } })
    }

    func value(_ key: String) -> Any? {
      lock.withLock { values[key] }
    }

    func seed(_ value: Any, key: String) {
      lock.withLock { values[key] = value }
    }

    func failNextSet(for key: String) {
      lock.withLock { failingSetKey = key }
    }
  }

  private final class ToolTrustState: @unchecked Sendable {
    private let lock = NSLock()
    private var assessment = RockchipPlatformTrustReceipt(
      codeTrust: .adHoc, quarantinePresent: true)
    private var clears = 0

    func current() -> RockchipPlatformTrustReceipt {
      lock.withLock { assessment }
    }

    func clear() {
      lock.withLock {
        clears += 1
        assessment = RockchipPlatformTrustReceipt(
          codeTrust: .adHoc, quarantinePresent: false)
      }
    }

    var clearCount: Int { lock.withLock { clears } }
  }

  private final class ProvenanceCredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    func load() -> String? {
      lock.withLock {
        loads += 1
        return "protected-main-token"
      }
    }

    var loadCount: Int { lock.withLock { loads } }
  }

  func testChatConfirmationDefersStandingAuthorizationKeychainCredential() throws {
    let probe = ProvenanceCredentialProbe()
    let loader = RockchipProductionProvenanceTokenLoader(loadToken: { probe.load() })
    let archive = URL(fileURLWithPath: "/tmp/dayu200-images.tar.gz")
    let assertion = try RockchipChatConfirmationAssertion(
      confirmationDigestSHA256: String(repeating: "c", count: 64),
      planDigestSHA256: String(repeating: "d", count: 64),
      archiveDigestSHA256: String(repeating: "a", count: 64),
      stepSetDigestSHA256: String(repeating: "e", count: 64),
      targetDigestSHA256: String(repeating: "b", count: 64), bindingRevision: 1)
    let chatRequest = try RockchipFlashExecutionRequest(
      chatConfirmation: assertion, archiveURL: archive, targetLocationSelector: "42")

    XCTAssertNil(try loader.token(for: chatRequest.authority))
    XCTAssertEqual(
      probe.loadCount, 0,
      "chat-confirmed execution must not ask Keychain for standing provenance")

    let standingRequest = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-TEST-AIN-018", archiveURL: archive,
      targetLocationSelector: "42")
    XCTAssertEqual(
      try loader.token(for: standingRequest.authority), "protected-main-token")
    XCTAssertEqual(
      probe.loadCount, 1,
      "standing authorization must still load its protected-main credential on demand")
  }

  func testTypedToolTrustRequiresExactPinAndNeverClearsQuarantineImplicitly() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-tool-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "rkdeveloptool")
    try Data("pinned tool fixture".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o755), 0)

    let preferences = ToolPreferenceBox()
    let state = ToolTrustState()
    let installer = RockchipProductToolInstaller(
      bookmarks: RockchipProductToolBookmarkStore(
        preferences: preferences.preferences(),
        codec: RockchipOrdinaryBookmarkCodec(
          create: { _ in Data([0x62, 0x6d]) },
          resolve: { _ in RockchipBookmarkResolution(url: executable, isStale: false) }),
        verifier: RockchipPinnedExecutableVerifier { _ in }),
      trustInspector: RockchipProductToolTrustInspector(
        assess: { _ in state.current() },
        clearQuarantine: { _ in state.clear() }),
      trustFacts: RockchipToolTrustFactStore(preferences: preferences.preferences()))

    XCTAssertThrowsError(try installer.install(executableURL: executable))
    XCTAssertEqual(state.clearCount, 0)
    XCTAssertNil(preferences.value(RockchipToolTrustFactStore.codeTrustKey))
    XCTAssertNil(preferences.value(RockchipToolTrustFactStore.quarantineKey))

    XCTAssertThrowsError(
      try installer.trustAndInstall(
        executableURL: executable,
        expectedSHA256: String(repeating: "0", count: 64)))
    XCTAssertEqual(state.clearCount, 0)

    let receipt = try installer.trustAndInstall(
      executableURL: executable,
      expectedSHA256: RockchipDiscoveryIntegrationProfile.pinnedProduction.executableSHA256)
    XCTAssertEqual(state.clearCount, 1)
    XCTAssertEqual(receipt.codeTrust, .adHoc)
    XCTAssertFalse(receipt.quarantinePresent)
    XCTAssertEqual(
      preferences.value(RockchipToolTrustFactStore.codeTrustKey) as? String,
      RockchipPlatformCodeTrust.adHoc.rawValue)
    XCTAssertEqual(
      preferences.value(RockchipToolTrustFactStore.quarantineKey) as? Bool,
      false)

    let rollbackPreferences = ToolPreferenceBox()
    rollbackPreferences.seed(
      RockchipPlatformCodeTrust.developerID.rawValue,
      key: RockchipToolTrustFactStore.codeTrustKey)
    rollbackPreferences.seed(true, key: RockchipToolTrustFactStore.quarantineKey)
    rollbackPreferences.failNextSet(for: RockchipToolTrustFactStore.quarantineKey)
    XCTAssertThrowsError(
      try RockchipToolTrustFactStore(preferences: rollbackPreferences.preferences()).persist(
        RockchipPlatformTrustReceipt(codeTrust: .adHoc, quarantinePresent: false)))
    XCTAssertEqual(
      rollbackPreferences.value(RockchipToolTrustFactStore.codeTrustKey) as? String,
      RockchipPlatformCodeTrust.developerID.rawValue)
    XCTAssertEqual(
      rollbackPreferences.value(RockchipToolTrustFactStore.quarantineKey) as? Bool,
      true)
  }

  func testTypedE0CrossModeBootstrapPublishesOwnerOnlyBindingAndRejectsDrift() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-binding-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = RockchipProductUSBIdentity(
      serial: "sensitive-loader-serial",
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "336592896", productName: "HDC Device")
    let store = RockchipProductBindingStore(rootURL: root)
    let bootstrap = RockchipProductBindingBootstrap(probe: { identity }, store: store)

    let first = try bootstrap.installCurrentLoader()
    XCTAssertTrue(first.created)
    XCTAssertEqual(first.revision, 1)
    XCTAssertEqual(first.usbTopology, identity.topology)
    XCTAssertEqual(first.serialDigestSHA256.count, 64)
    let bindingURL = root.appending(path: RockchipProductBindingStore.bindingFileName)
    var metadata = stat()
    XCTAssertEqual(lstat(bindingURL.path, &metadata), 0)
    XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    let snapshot = try JSONDecoder().decode(
      RockchipProductBindingSnapshot.self, from: Data(contentsOf: bindingURL))
    XCTAssertEqual(snapshot.serial, identity.serial)
    XCTAssertFalse(snapshot.evidence.contains { $0.contains(identity.serial) })

    let loaderIdentity = RockchipProductUSBIdentity(
      serial: identity.serial,
      vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID,
      topology: identity.topology)
    let second = try RockchipProductBindingBootstrap(
      probe: { loaderIdentity }, store: store
    ).installCurrentLoader()
    XCTAssertFalse(second.created)
    XCTAssertEqual(second.serialDigestSHA256, first.serialDigestSHA256)

    let drifted = RockchipProductBindingBootstrap(
      probe: {
        RockchipProductUSBIdentity(
          serial: identity.serial,
          vendorID: identity.vendorID,
          productID: identity.productID,
          topology: "336592897", productName: identity.productName)
      },
      store: store)
    XCTAssertThrowsError(try drifted.installCurrentLoader())
    XCTAssertEqual(try store.loadExisting(), snapshot)

    let spoofedNormal = RockchipProductBindingBootstrap(
      probe: {
        RockchipProductUSBIdentity(
          serial: identity.serial,
          vendorID: identity.vendorID,
          productID: identity.productID,
          topology: identity.topology, productName: "Maskrom Device")
      },
      store: store)
    XCTAssertThrowsError(try spoofedNormal.installCurrentLoader())
  }

  func testChatConfirmedNormalModeDispatchesExactHDCOnceBeforeClosedRockUSBSequence()
    async throws
  {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let hdcExecutable = packageRoot.appending(path: ".build/debug/ArkDeckFakeHDCFixture")
    let hdcSHA256 = RockchipExecutionTestFixture.sha256(try Data(contentsOf: hdcExecutable))
    let spawnLog = RockchipSpawnLog()
    let processExecutor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in },
      launchObserver: { _ in },
      identityBoundSpawnObserver: { _, request, _ in spawnLog.append(request) })
    let serial = "cross-mode-connect-key"
    let serialDigest = RockchipExecutionTestFixture.sha256(Data(serial.utf8))
    let normal = RockchipProductUSBIdentity(
      serial: serial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "42", productName: "HDC Device")
    // `rkdeveloptool ld` reports VID/PID/LocationID/mode, not the normal-mode USB serial.
    // The transition must therefore correlate the semantic Loader observation without
    // inventing a cross-mode serial readback.
    let loader = RockchipDeviceObservation(
      deviceNumber: 0, usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
      usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
      locationID: 42, mode: .loader)
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: fixture.executable, executor: processExecutor,
      executableSHA256: fixture.executableSHA256,
      hdcTransition: RockchipHDCTransitionConfiguration(
        executableURL: hdcExecutable, executableSHA256: hdcSHA256,
        connectKey: serial, stableIdentitySHA256: serialDigest, usbTopology: "42",
        currentIdentity: { normal }, waitForLoader: { loader }))
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: RecordingPowerBackend(),
        makePersistence: { _, _, _ in persistence },
        profiles: [.dayu200, fixture.profile],
        makeID: RockchipExecutionTestFixture.deterministicID))
    let assertion = try RockchipChatConfirmationAssertion(
      confirmationDigestSHA256: String(repeating: "c", count: 64),
      planDigestSHA256: fixture.plan.planDigestSHA256,
      archiveDigestSHA256: fixture.plan.archiveSHA256,
      stepSetDigestSHA256: fixture.plan.stepSetDigestSHA256,
      targetDigestSHA256: String(repeating: "b", count: 64), bindingRevision: 1)

    let result = try await host.execute(
      RockchipFlashExecutionRequest(
        chatConfirmation: assertion, archiveURL: fixture.archive,
        targetLocationSelector: "42"))

    XCTAssertEqual(result.status, .succeeded)
    let requests = spawnLog.requests
    XCTAssertEqual(requests.count, 13)
    XCTAssertEqual(requests[0].executable, hdcExecutable)
    XCTAssertEqual(requests[0].arguments, ["-t", serial, "shell", "reboot", "loader"])
    XCTAssertEqual(requests[1].arguments, ["ld"])
    XCTAssertEqual(requests[2].arguments, ["ppt"])
    XCTAssertEqual(requests[3...11].map { $0.arguments.first }, Array(repeating: "wlx", count: 9))
    XCTAssertEqual(requests[12].arguments, ["rd"])
    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    let loaderOutcome = try XCTUnwrap(
      replay.events.first(where: {
        $0.kind == .stepOutcome
          && $0.stepID == fixture.plan.steps.first(where: { $0.kind == .enterUpdater })?.id
      }))
    XCTAssertEqual(
      loaderOutcome.payload["semanticCode"],
      .string("rockchip.enter-loader.readback-confirmed"))
  }

  func testHDCTransitionWithoutMatchingLoaderBlocksAllRockUSBDispatch() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let hdcExecutable = packageRoot.appending(path: ".build/debug/ArkDeckFakeHDCFixture")
    let hdcSHA256 = RockchipExecutionTestFixture.sha256(try Data(contentsOf: hdcExecutable))
    let spawnLog = RockchipSpawnLog()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in }, launchObserver: { _ in },
      identityBoundSpawnObserver: { _, request, _ in spawnLog.append(request) })
    let serial = "cross-mode-connect-key"
    let serialDigest = RockchipExecutionTestFixture.sha256(Data(serial.utf8))
    let normal = RockchipProductUSBIdentity(
      serial: serial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "42", productName: "HDC Device")
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: fixture.executable, executor: executor,
      executableSHA256: fixture.executableSHA256,
      hdcTransition: RockchipHDCTransitionConfiguration(
        executableURL: hdcExecutable, executableSHA256: hdcSHA256,
        connectKey: serial, stableIdentitySHA256: serialDigest, usbTopology: "42",
        currentIdentity: { normal },
        waitForLoader: { throw RockchipHDCTransitionError.loaderUnavailable }))
    let command = try XCTUnwrap(
      RockchipFlashExecutionLowering.commands(
        plan: fixture.plan,
        stagedImages: RockchipFlashExecutionStager.stage(
          archiveURL: fixture.archive, sessionRoot: fixture.base, profile: fixture.profile)
      ).first)
    let prepared = try process.prepare(
      command: command, admissionIdentity: fixture.executableReceipt)

    do {
      _ = try await prepared.launch(criticalNonInterruptible: false)
      XCTFail("missing same-device Loader readback must fail closed")
    } catch {
      XCTAssertEqual(error as? RockchipHDCTransitionError, .loaderUnavailable)
    }
    XCTAssertEqual(spawnLog.requests.count, 1)
    XCTAssertEqual(
      spawnLog.requests.first?.arguments,
      ["-t", serial, "shell", "reboot", "loader"])
    XCTAssertFalse(spawnLog.requests.contains(where: { $0.arguments.first == "ld" }))
    XCTAssertFalse(spawnLog.requests.contains(where: { $0.arguments.first == "wlx" }))
  }

  func testHDCTransitionRejectsLoaderAtAnotherTopologyBeforeRockUSBDispatch() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let hdcExecutable = packageRoot.appending(path: ".build/debug/ArkDeckFakeHDCFixture")
    let hdcSHA256 = RockchipExecutionTestFixture.sha256(try Data(contentsOf: hdcExecutable))
    let spawnLog = RockchipSpawnLog()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in }, launchObserver: { _ in },
      identityBoundSpawnObserver: { _, request, _ in spawnLog.append(request) })
    let serial = "cross-mode-connect-key"
    let serialDigest = RockchipExecutionTestFixture.sha256(Data(serial.utf8))
    let normal = RockchipProductUSBIdentity(
      serial: serial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipHDCIntegrationProfile.dayu200NormalProductID,
      topology: "42", productName: "HDC Device")
    let movedLoader = RockchipDeviceObservation(
      deviceNumber: 0, usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
      usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
      locationID: 43, mode: .loader)
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: fixture.executable, executor: executor,
      executableSHA256: fixture.executableSHA256,
      hdcTransition: RockchipHDCTransitionConfiguration(
        executableURL: hdcExecutable, executableSHA256: hdcSHA256,
        connectKey: serial, stableIdentitySHA256: serialDigest, usbTopology: "42",
        currentIdentity: { normal }, waitForLoader: { movedLoader }))
    let command = try XCTUnwrap(
      RockchipFlashExecutionLowering.commands(
        plan: fixture.plan,
        stagedImages: RockchipFlashExecutionStager.stage(
          archiveURL: fixture.archive, sessionRoot: fixture.base, profile: fixture.profile)
      ).first)
    let prepared = try process.prepare(
      command: command, admissionIdentity: fixture.executableReceipt)

    do {
      _ = try await prepared.launch(criticalNonInterruptible: false)
      XCTFail("a Loader at another topology must require an explicit rebind")
    } catch {
      XCTAssertEqual(error as? RockchipHDCTransitionError, .identityDrift)
    }
    XCTAssertEqual(spawnLog.requests.map(\.arguments), [
      ["-t", serial, "shell", "reboot", "loader"]
    ])
  }

  func testAlreadyLoaderSkipsHDCRebootAndRunsOnlyLoaderReadback() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let hdcExecutable = packageRoot.appending(path: ".build/debug/ArkDeckFakeHDCFixture")
    let hdcSHA256 = RockchipExecutionTestFixture.sha256(try Data(contentsOf: hdcExecutable))
    let spawnLog = RockchipSpawnLog()
    let executor = FoundationProcessExecutor(
      identityBoundPreSpawnHook: { _ in }, launchObserver: { _ in },
      identityBoundSpawnObserver: { _, request, _ in spawnLog.append(request) })
    let serial = "already-loader-connect-key"
    let serialDigest = RockchipExecutionTestFixture.sha256(Data(serial.utf8))
    let loader = RockchipProductUSBIdentity(
      serial: serial, vendorID: RockchipProbeEvidence.rockUSBVendorID,
      productID: RockchipProbeEvidence.dayu200LoaderProductID, topology: "42")
    let process = FoundationRockchipExecutionProcessPort(
      executableURL: fixture.executable, executor: executor,
      executableSHA256: fixture.executableSHA256,
      hdcTransition: RockchipHDCTransitionConfiguration(
        executableURL: hdcExecutable, executableSHA256: hdcSHA256,
        connectKey: serial, stableIdentitySHA256: serialDigest, usbTopology: "42",
        currentIdentity: { loader },
        waitForLoader: {
          XCTFail("already-Loader path must not wait for an HDC transition")
          return RockchipDeviceObservation(
            deviceNumber: 0, usbVendorID: RockchipProbeEvidence.rockUSBVendorID,
            usbProductID: RockchipProbeEvidence.dayu200LoaderProductID,
            locationID: 42, mode: .loader)
        }))
    let command = try XCTUnwrap(
      RockchipFlashExecutionLowering.commands(
        plan: fixture.plan,
        stagedImages: RockchipFlashExecutionStager.stage(
          archiveURL: fixture.archive, sessionRoot: fixture.base, profile: fixture.profile)
      ).first)
    let prepared = try process.prepare(
      command: command, admissionIdentity: fixture.executableReceipt)

    let attempt = try await prepared.launch(criticalNonInterruptible: false)

    XCTAssertEqual(attempt.semantic, .succeeded)
    XCTAssertEqual(spawnLog.requests.map(\.arguments), [["ld"]])
  }

  func testChatConfirmedFakeExecutesOnceAndPublishesTruthfulV22Authority() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: RecordingPowerBackend(),
        makePersistence: { _, _, _ in persistence },
        profiles: [.dayu200, fixture.profile],
        makeID: RockchipExecutionTestFixture.deterministicID))
    let assertion = try RockchipChatConfirmationAssertion(
      confirmationDigestSHA256: String(repeating: "c", count: 64),
      planDigestSHA256: fixture.plan.planDigestSHA256,
      archiveDigestSHA256: fixture.plan.archiveSHA256,
      stepSetDigestSHA256: fixture.plan.stepSetDigestSHA256,
      targetDigestSHA256: String(repeating: "b", count: 64), bindingRevision: 1)

    let result = try await host.execute(
      RockchipFlashExecutionRequest(
        chatConfirmation: assertion, archiveURL: fixture.archive,
        targetLocationSelector: "42"))

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(process.arguments.count, 12)
    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.events.first?.schemaVersion, JournalEvent.agentAuthoritySchemaVersion)
    XCTAssertNil(replay.authorizationReference)
    XCTAssertEqual(replay.agentExecutionAuthorityReference?.kind, .chatConfirmation)
    let externalIntents = replay.events.filter {
      $0.kind == .stepIntent && ($0.stepEffect ?? .hostOnly) >= .readOnly
    }
    XCTAssertEqual(externalIntents.count, 13)
    XCTAssertTrue(
      externalIntents.allSatisfy {
        $0.agentExecutionAuthorityReference?.kind == .chatConfirmation
          && $0.usageReservationID == "reservation-ain-007"
      })
    let manifest = try SessionManifestDocument(
      data: Data(contentsOf: try XCTUnwrap(result.manifestURL)))
    XCTAssertEqual(manifest.schemaVersion, JournalEvent.agentAuthoritySchemaVersion)
    XCTAssertNil(manifest.authorization?.authorizationReference)
    XCTAssertEqual(
      manifest.authorization?.agentExecutionAuthorityReference?.kind, .chatConfirmation)
    XCTAssertEqual(manifest.authorization?.externalIntentEventIDs.count, 13)
    XCTAssertEqual(admission.closedIntentIDs.count, 13)
    XCTAssertEqual(admission.authorizeAndConsumeCount, 1)
  }

  func testAuthorizedFakeDescriptorExecutesExactClosedSequenceAndPublishesV21Manifest()
    async throws
  {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let persistence = try await fixture.makePersistence()
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let powerBackend = RecordingPowerBackend()
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: powerBackend,
        makePersistence: { _, _, _ in persistence },
        profiles: [.dayu200, fixture.profile],
        makeID: RockchipExecutionTestFixture.deterministicID))
    let request = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-TEST-AIN-007", archiveURL: fixture.archive,
      targetLocationSelector: "42")

    let result = try await host.execute(request)

    XCTAssertEqual(result.status, .succeeded)
    XCTAssertEqual(result.evidenceClass, .contractFake)
    XCTAssertEqual(result.manifestURL, persistence.sessionRoot.appending(path: "manifest.json"))
    let arguments = process.arguments
    XCTAssertEqual(arguments.count, 12)
    XCTAssertEqual(arguments[0], ["ld"])
    XCTAssertEqual(arguments[1], ["ppt"])
    XCTAssertEqual(
      arguments[2...10].map { Array($0.prefix(2)) },
      fixture.profile.mappedPartitions.map { ["wlx", $0.partitionName] })
    XCTAssertEqual(arguments[11], ["rd"])
    XCTAssertTrue(
      arguments.flatMap { $0 }.allSatisfy {
        !$0.contains("sudo") && $0 != "sh" && $0 != "bash" && $0 != "wl"
      })
    for row in arguments[2...10] {
      XCTAssertEqual(row.count, 3)
      XCTAssertTrue(row[2].hasPrefix("/.vol/"))
      var metadata = stat()
      XCTAssertEqual(lstat(row[2], &metadata), 0)
      XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
    }

    let replay = try DurableJournalRecovery.inspect(
      url: persistence.sessionRoot.appending(path: "journal.jsonl"))
    XCTAssertEqual(replay.events.first?.schemaVersion, "2.1.0")
    XCTAssertEqual(replay.events.first?.kind, .jobCreated)
    XCTAssertEqual(replay.events.first?.payload["executionAuthority"], .string("authorizedAgent"))
    let destructiveIntents = replay.events.filter {
      $0.kind == .stepIntent && $0.stepEffect == .destructive
    }
    XCTAssertEqual(destructiveIntents.count, 9)
    XCTAssertTrue(
      destructiveIntents.allSatisfy {
        $0.authorizationReference?.authorizationID == "AUTH-TEST-AIN-007"
          && $0.usageReservationID == "reservation-ain-007"
      })
    XCTAssertTrue(replay.finalized)
    XCTAssertEqual(replay.currentState, .succeeded)

    let manifest = try SessionManifestDocument(
      data: Data(contentsOf: try XCTUnwrap(result.manifestURL)))
    XCTAssertEqual(manifest.schemaVersion, "2.1.0")
    XCTAssertEqual(manifest.executionMode, "execute")
    XCTAssertEqual(manifest.executionAuthority, "authorizedAgent")
    XCTAssertEqual(manifest.authorization?.destructiveIntentEventIDs.count, 9)
    XCTAssertEqual(manifest.authorization?.usageReservationID, "reservation-ain-007")
    XCTAssertGreaterThanOrEqual(manifest.artifacts.count, 12)
    XCTAssertTrue(manifest.artifacts.allSatisfy { $0.role == .raw })
    let manifestText = String(decoding: manifest.canonicalData, as: UTF8.self)
    let manifestRoot = try XCTUnwrap(
      JSONSerialization.jsonObject(with: manifest.canonicalData) as? [String: Any])
    let toolchain = try XCTUnwrap(manifestRoot["toolchain"] as? [String: Any])
    XCTAssertEqual(toolchain["pathSource"] as? String, "installedOrdinaryBookmark")
    XCTAssertFalse(manifestText.contains(fixture.executable.path))
    XCTAssertFalse(manifestText.contains(fixture.archive.path))
    XCTAssertFalse(manifestText.contains("/.vol/"))
    XCTAssertFalse(manifestText.contains("bookmarkData"))
    XCTAssertFalse(manifestText.contains("contractFake"))

    let records = try persistence.auditRecordsForTesting(
      correlationID: "rockchip-session-fixed")
    XCTAssertEqual(records.last?.details["evidenceClass"], .string("contractFake"))
    XCTAssertEqual(records.last?.details["hardwareSupportEligible"], .bool(false))
    XCTAssertEqual(powerBackend.activeCount, 0)
    XCTAssertEqual(admission.closedStatus, .succeeded)
    XCTAssertEqual(admission.closedIntentIDs.count, 9)
    print(
      "TEST-AIN-DISPATCH-001 PASS argv=1ld+1ppt+9wlx+1rd schema=2.1.0 "
        + "pathSource=installedOrdinaryBookmark evidence=contractFake "
        + "realDevice=0 hdc=0 network=0 shell=0")
  }

  func testPublicRequestRejectsAuthorityAndSelectorInjection() throws {
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "../AUTH", archiveURL: URL(fileURLWithPath: "/tmp/a"),
        targetLocationSelector: "42"))
    XCTAssertThrowsError(
      try RockchipFlashExecutionRequest(
        authorizationID: "AUTH-TEST", archiveURL: URL(string: "https://example.invalid/a")!,
        targetLocationSelector: "42"))
    for selector in ["", "042", "42 --tool /tmp/fake", "-1", "４２"] {
      XCTAssertThrowsError(
        try RockchipFlashExecutionRequest(
          authorizationID: "AUTH-TEST", archiveURL: URL(fileURLWithPath: "/tmp/a"),
          targetLocationSelector: selector))
    }
  }

  func testUnpublishedExecuteProfileStopsBeforePersistenceAuthorizationOrDispatch() async throws {
    let fixture = try RockchipExecutionTestFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let admission = RecordingRockchipAdmissionPort(
      plan: fixture.plan, receipt: fixture.executableReceipt)
    let process = RecordingRockchipProcessPort(
      executable: fixture.executable, sha256: fixture.executableSHA256)
    let host = RockchipFlashExecutionHost(
      dependencies: RockchipFlashExecutionDependencies(
        admission: admission, process: process,
        postflight: FixedRockchipPostflightPort(
          serialDigest: String(repeating: "a", count: 64), topology: "42"),
        power: RecordingPowerBackend(),
        makePersistence: { _, _, _ in
          throw RockchipFlashExecutionError.storageRejected(
            "persistence must not start for an unpublished profile")
        },
        profiles: [.dayu200],
        makeID: RockchipExecutionTestFixture.deterministicID))
    let request = try RockchipFlashExecutionRequest(
      authorizationID: "AUTH-TEST-UNPUBLISHED-PROFILE",
      archiveURL: fixture.archive,
      targetLocationSelector: "42")

    do {
      _ = try await host.execute(request)
      XCTFail("an admitted plan without an exact published profile must fail closed")
    } catch {
      XCTAssertEqual(
        error as? RockchipFlashExecutionError,
        .admissionRejected("execute plan has no exact published profile"))
    }
    XCTAssertEqual(admission.authorizeAndConsumeCount, 0)
    XCTAssertEqual(admission.closedStatus, .failed)
    XCTAssertTrue(admission.closedIntentIDs.isEmpty)
    XCTAssertTrue(process.arguments.isEmpty)
  }

  func testLoweringRejectsMissingStagedImageAndNeverOffersWLFallback() throws {
    let provider = RockchipRockUSBFlashProvider()
    let plan = try provider.makePlan(mode: .execute, archiveValidation: .valid)
    XCTAssertThrowsError(
      try RockchipFlashExecutionLowering.commands(plan: plan, stagedImages: [:]))
    XCTAssertFalse(RockchipRockUSBFlashProvider.closedCommandSurface.isEmpty)
  }
}

private final class RockchipSpawnLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ProcessRequest] = []

  var requests: [ProcessRequest] { lock.withLock { stored } }

  func append(_ request: ProcessRequest) {
    lock.withLock { stored.append(request) }
  }
}

final class RecordingRockchipAdmissionPort: @unchecked Sendable, RockchipExecutionAdmissionPort {
  private let lock = NSLock()
  let plan: RockchipFlashPlan
  let receipt: ProcessExecutableIdentityReceipt
  private(set) var closedStatus: AuthorizationUsageTerminalStatus?
  private(set) var closedIntentIDs: [String] = []
  private var consumeCount = 0

  var authorizeAndConsumeCount: Int { lock.withLock { consumeCount } }

  init(plan: RockchipFlashPlan, receipt: ProcessExecutableIdentityReceipt) {
    self.plan = plan
    self.receipt = receipt
  }

  func admit(
    request: RockchipFlashExecutionRequest,
    sessionID _: String,
    jobID _: String,
    targetID: String
  ) async throws -> RockchipExecutionAdmission {
    let authorityReference: RockchipExecutionAdmission.AuthorityReference
    switch request.authority {
    case .standingAuthorization(let authorizationID):
      authorityReference = .standingAuthorization(
        try AuthorizationReference(
          authorizationID: authorizationID,
          mainCommitOID: String(repeating: "1", count: 40),
          authorizationBlobOID: String(repeating: "2", count: 40),
          approvalPRNumber: 314))
    case .chatConfirmation(let assertion):
      authorityReference = .agent(
        try .validatedChatConfirmation(
          confirmationDigestSHA256: assertion.confirmationDigestSHA256,
          planDigestSHA256: assertion.planDigestSHA256,
          archiveDigestSHA256: assertion.archiveDigestSHA256,
          stepSetDigestSHA256: assertion.stepSetDigestSHA256,
          targetDigestSHA256: assertion.targetDigestSHA256,
          confirmedAt: "2026-08-01T12:00:00Z"))
    }
    return RockchipExecutionAdmission(
      backing: .contractFake, plan: plan,
      authorityReference: authorityReference,
      usageReservationID: "reservation-ain-007", targetID: targetID,
      bindingRevision: 1, targetDigestSHA256: String(repeating: "b", count: 64),
      serialDigestSHA256: String(repeating: "a", count: 64), usbTopology: "42",
      executableIdentity: receipt, evidenceClass: .contractFake)
  }

  func authorizeAndConsume(_: RockchipExecutionAdmission) async throws {
    lock.withLock { consumeCount += 1 }
  }

  func closeUsage(
    admission _: RockchipExecutionAdmission,
    status: AuthorizationUsageTerminalStatus,
    destructiveIntentEventIDs: [String]
  ) throws {
    lock.lock()
    closedStatus = status
    closedIntentIDs = destructiveIntentEventIDs
    lock.unlock()
  }
}

final class RecordingRockchipProcessPort: @unchecked Sendable, RockchipExecutionProcessPort {
  private let lock = NSLock()
  private let executable: URL
  private let sha256: String
  private let executor = FoundationProcessExecutor()
  private let semanticOverride:
    @Sendable (RockchipClosedCommand, RockchipCommandSemanticResult)
      -> RockchipCommandSemanticResult
  private var recordedArguments: [[String]] = []
  private var recordedTerminations: [ProcessTermination] = []

  init(
    executable: URL,
    sha256: String,
    semanticOverride:
      @escaping @Sendable (RockchipClosedCommand, RockchipCommandSemanticResult)
      -> RockchipCommandSemanticResult = { _, result in result }
  ) {
    self.executable = executable
    self.sha256 = sha256
    self.semanticOverride = semanticOverride
  }

  var arguments: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recordedArguments
  }

  var terminations: [ProcessTermination] {
    lock.withLock { recordedTerminations }
  }

  func prepare(
    command: RockchipClosedCommand,
    admissionIdentity: ProcessExecutableIdentityReceipt
  ) throws -> RockchipPreparedCommand {
    let request = ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: executable, arguments: command.arguments),
      expectedSHA256: sha256)
    let prepared = try executor.prepareIdentityBoundLaunch(request)
    guard prepared.executableIdentity == admissionIdentity else {
      prepared.close()
      throw RockchipFlashExecutionError.executableIdentityDrift
    }
    return RockchipPreparedCommand(executableIdentity: prepared.executableIdentity) {
      self.lock.withLock { self.recordedArguments.append(command.arguments) }
      let result = try await self.executor.executePreparedIdentityBoundLaunch(
        prepared, evaluating: RockchipCommandSemanticEvaluator(command: command))
      self.lock.withLock { self.recordedTerminations.append(result.execution.termination) }
      return RockchipExecutionAttempt(
        execution: result.execution,
        semantic: self.semanticOverride(command, result.semantic),
        executableIdentity: result.executableIdentity)
    }
  }
}

struct FixedRockchipPostflightPort: RockchipExecutionPostflightPort {
  let serialDigest: String
  let topology: String

  func probe(expectedTopology _: String) async throws -> RockchipPostflightReceipt {
    RockchipPostflightReceipt(
      connected: true, serialDigestSHA256: serialDigest, usbTopology: topology)
  }
}

final class RecordingPowerBackend: @unchecked Sendable, RockchipPowerActivityPort {
  private let lock = NSLock()
  private var count = 0

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func acquire(reason _: String) throws -> any RockchipPowerActivityLease {
    lock.lock()
    count += 1
    lock.unlock()
    return RecordingPowerLease { [weak self] in self?.release() }
  }

  private func release() {
    lock.lock()
    count -= 1
    lock.unlock()
  }
}

private final class RecordingPowerLease: @unchecked Sendable, RockchipPowerActivityLease {
  private let lock = NSLock()
  private var release: (@Sendable () -> Void)?

  init(release: @escaping @Sendable () -> Void) {
    self.release = release
  }

  deinit { end() }

  func end() {
    lock.lock()
    let release = release
    self.release = nil
    lock.unlock()
    release?()
  }
}

struct RockchipExecutionTestFixture {
  let base: URL
  let archive: URL
  let executable: URL
  let executableSHA256: String
  let executableReceipt: ProcessExecutableIdentityReceipt
  let profile: RockchipFlashProfile
  let plan: RockchipFlashPlan
  let sessionsRoot: URL
  let coordinator: HostStorageCoordinator

  static let deterministicID: @Sendable (String) -> String = { prefix in
    switch prefix {
    case "rockchip-session": "rockchip-session-fixed"
    case "rockchip-job": "rockchip-job-fixed"
    default: "rockchip-target-fixed"
    }
  }

  static func make(partitionNames: [String]? = nil) throws -> RockchipExecutionTestFixture {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "arkdeck-ain007-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let members = (0..<9).map { index in
      (name: "image\(index).img", bytes: Data("image-\(index)-payload".utf8))
    }
    let archive = base.appending(path: "images.tar.gz")
    try makeGzipTar(members: members).write(to: archive)
    let archiveBytes = try Data(contentsOf: archive)
    let profileMembers = members.map {
      RockchipImagesArchiveMember(
        name: $0.name, sizeBytes: Int64($0.bytes.count), sha256: sha256($0.bytes),
        classification: .mappedPartitionImage)
    }
    let profile = try RockchipFlashProfile(
      archiveSizeBytes: Int64(archiveBytes.count), archiveSHA256: sha256(archiveBytes),
      members: profileMembers,
      mappedPartitions: members.enumerated().map { index, member in
        RockchipMappedPartition(
          writeOrder: index + 1,
          partitionName: partitionNames?[index] ?? "partition\(index)",
          imageMemberName: member.name, offsetSectors: Int64((index + 1) * 8192))
      },
      membershiplessPartitionsWriteForbidden: [],
      prerequisites: [
        .loader: .required, .recoveryPath: .required, .unlocked: .required,
        .stablePower: .optional,
      ])
    let plan = try RockchipRockUSBFlashProvider(profile: profile).makePlan(
      mode: .execute, archiveValidation: .valid)
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = packageRoot.appending(path: ".build/debug/ArkDeckFakeRockchipFixture")
    let executableSHA256 = sha256(try Data(contentsOf: executable))
    let executor = FoundationProcessExecutor()
    let prepared = try executor.prepareIdentityBoundLaunch(
      ProcessIdentityBoundRequest(
        process: ProcessRequest(executable: executable, arguments: ["ld"]),
        expectedSHA256: executableSHA256))
    let receipt = prepared.executableIdentity
    prepared.close()
    let sessionsRoot = base.appending(path: "Sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sessionsRoot, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return RockchipExecutionTestFixture(
      base: base, archive: archive, executable: executable,
      executableSHA256: executableSHA256, executableReceipt: receipt,
      profile: profile, plan: plan, sessionsRoot: sessionsRoot,
      coordinator: HostStorageCoordinator())
  }

  func makePersistence() async throws -> RockchipDurableExecutionPersistence {
    let probe = SystemHostStorageProbe()
    let snapshot = try probe.snapshot(for: sessionsRoot)
    let request = try StorageClaimRequest(
      claimID: "claim-rockchip-job-fixed", jobID: "rockchip-job-fixed",
      volumeIdentity: snapshot.volumeIdentity,
      budget: StorageBudget(
        metadataHeadroomBytes: 1 << 20, finalizationHeadroomBytes: 1 << 20,
        remainingGrowthBytes: 16 << 20, writerClass: .heavy))
    guard case .admitted(let claim) = await coordinator.admit(request, snapshot: snapshot) else {
      throw RockchipFlashExecutionError.storageRejected("fixture claim")
    }
    let store = try SessionStore(sessionsRoot: sessionsRoot)
    let layout = try store.createSession(
      sessionID: "rockchip-session-fixed", jobID: "rockchip-job-fixed",
      createdAt: Date(timeIntervalSince1970: 1_752_739_200), claim: claim)
    return try RockchipDurableExecutionPersistence(
      layout: layout, claim: claim, coordinator: coordinator)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func makeGzipTar(members: [(name: String, bytes: Data)]) throws -> Data {
    var tar = Data()
    for member in members {
      var header = [UInt8](repeating: 0, count: 512)
      write(member.name, into: &header, offset: 0, length: 100)
      writeOctal(0o600, into: &header, offset: 100, length: 8)
      writeOctal(0, into: &header, offset: 108, length: 8)
      writeOctal(0, into: &header, offset: 116, length: 8)
      writeOctal(member.bytes.count, into: &header, offset: 124, length: 12)
      writeOctal(0, into: &header, offset: 136, length: 12)
      for index in 148..<156 { header[index] = 0x20 }
      header[156] = UInt8(ascii: "0")
      write("ustar", into: &header, offset: 257, length: 6)
      header[262] = 0
      header[263] = UInt8(ascii: "0")
      header[264] = UInt8(ascii: "0")
      let checksum = header.reduce(0) { $0 + Int($1) }
      let checksumText = String(format: "%06o", checksum)
      write(checksumText, into: &header, offset: 148, length: 6)
      header[154] = 0
      header[155] = 0x20
      tar.append(contentsOf: header)
      tar.append(member.bytes)
      tar.append(Data(repeating: 0, count: (512 - member.bytes.count % 512) % 512))
    }
    tar.append(Data(repeating: 0, count: 1024))
    let compressed = try deflate(tar)
    var gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff])
    gzip.append(compressed)
    gzip.append(Data(repeating: 0, count: 8))
    return gzip
  }

  static func deflate(_ data: Data) throws -> Data {
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count * 2 + 1024)
    defer { destination.deallocate() }
    let count = data.withUnsafeBytes { source in
      compression_encode_buffer(
        destination, data.count * 2 + 1024,
        source.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
        nil, COMPRESSION_ZLIB)
    }
    guard count > 0 else { throw RockchipFlashStagingError.decompressionFailed }
    return Data(bytes: destination, count: count)
  }

  static func write(
    _ string: String, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    for (index, byte) in string.utf8.prefix(length).enumerated() {
      bytes[offset + index] = byte
    }
  }

  static func writeOctal(
    _ value: Int, into bytes: inout [UInt8], offset: Int, length: Int
  ) {
    let text = String(format: "%0*o", length - 1, value)
    write(text, into: &bytes, offset: offset, length: length - 1)
    bytes[offset + length - 1] = 0
  }
}
