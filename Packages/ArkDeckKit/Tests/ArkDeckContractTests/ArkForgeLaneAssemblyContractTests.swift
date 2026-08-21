import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckWorkflows
@testable import ArkForgeClient
@testable import ArkForgeProtocol

/// The assertion this work needed from the start and did not have.
///
/// Every part of the lane was built and tested — the authority, the control
/// port, the session, the launcher, the input reader — and nothing asserted
/// that a daemon startup actually *assembles* them. It did not. The engine got
/// `nil` on every job, `flash.dayu200` refused, and the refusal was
/// indistinguishable from a daemon nobody had configured.
///
/// That is exactly the failure mode written into `ArkForgeLaneComposition`'s
/// own doc comment. Writing it down did not prevent producing it; this test is
/// what prevents producing it again.
final class ArkForgeLaneAssemblyContractTests: XCTestCase {

  /// A real file, because composition reads the profile's declared id and
  /// version out of it before launching anything: `materializePlan` addresses
  /// a profile by `id@version`, and a lane that cannot name the exact selector
  /// cannot materialize a plan.
  private var bundleRoot: URL!
  private var fixture: ArkForgeBundleFixture!

  override func setUpWithError() throws {
    bundleRoot = FileManager.default.temporaryDirectory
      .appending(path: "arkforge-assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
    fixture = try makeArkForgeBundle(at: bundleRoot.appending(path: "ArkForge.bundle"))
  }

  override func tearDownWithError() throws {
    if let bundleRoot { try? FileManager.default.removeItem(at: bundleRoot) }
  }

  private var environment: [String: String] {
    fixture.environment
  }

  private static func readyAck(
    toolchainID: String = "arkforged-native-rockusb",
    toolchain: String
  ) -> ArkForgeHelloAck {
    ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: toolchainID, toolchainSHA256: toolchain)
  }

  private func dependencies() -> ArkForgeLaneComposition.Dependencies {
    .init(
      rockchipHost: { RefusingRockchipRuntimeActionHost(reason: "test") },
      providerIdentity: ResolvedExecutable(
        path: fixture.daemon.path, sha256: fixture.daemonSHA256),
      approvedPlan: { jobID, planID, planDigest, _ in
        .init(
          jobID: jobID, planID: planID, planSHA256: planDigest,
          admittedDeviceFactsSHA256: planDigest,
          binding: ArkForgeAuthorityBinding(
            authorityNamespace: "arkdeck", bindingID: "T", bindingRevision: 1,
            stableIdentityDigest: []),
          controllerSessionID: "arkdeck-agentd")
      })
  }

  private struct SilentDaemon: ArkForgeFlashSession.Daemon {
    func startExecution(_ body: ArkForgeStartExecutionRequest, requestID: String) throws
      -> ArkForgeStartExecutionResponse
    { ArkForgeStartExecutionResponse(jobID: "JOB-1") }
    func submitStepPermit(_ body: ArkForgeSubmitStepPermitRequest, requestID: String) throws
      -> ArkForgeSubmitStepPermitResponse
    { ArkForgeSubmitStepPermitResponse(accepted: true, rejectionCode: "", rejectionMessage: "") }
    func submitManagedControlReceipt(
      _ body: ArkForgeSubmitManagedControlReceiptRequest, requestID: String
    ) throws -> ArkForgeSubmitManagedControlReceiptResponse {
      ArkForgeSubmitManagedControlReceiptResponse(
        accepted: true, rejectionCode: "", rejectionMessage: "")
    }
    func watchJob(
      _ body: ArkForgeWatchJobRequest, requestID: String,
      handle: (ArkForgeJobEvent) throws -> Bool
    ) throws {}
    func cancelJob(jobID: String, requestID: String) throws -> ArkForgeCancelJobResponse {
      ArkForgeCancelJobResponse(cancellationState: "cancelledSafe")
    }
  }

  func testAConfiguredDaemonActuallyComesOutWithALane() async {
    // The whole point. Not "the parts exist" — a lane, out the other end.
    let daemonDigest = fixture.daemonSHA256
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { _, _ in },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .success(let composed) = result else {
      return XCTFail("a fully configured daemon must produce a lane, got \(result)")
    }
    XCTAssertEqual(composed.deviceProfileID, "org.openharmony.dayu200@1.0.0")
  }

  func testAProfileWithoutAnExactVersionNeverLaunchesTheDaemon() async throws {
    try Data(
      """
      schemaVersion: arkforge.device-profile/v1
      profile:
        id: org.openharmony.dayu200
      """.utf8
    ).write(to: fixture.profile)
    try ArkForgeBundleManifestWriter.write(
      bundleURL: fixture.root, version: "0.1.0-test",
      declarations: [
        .init(path: "Contents/MacOS/arkforge", role: .cli),
        .init(path: "Contents/MacOS/arkforged", role: .daemon),
        .init(
          path: "Contents/Resources/profiles/dayu200.yaml", role: .profile,
          profileID: "org.openharmony.dayu200"),
      ])
    let seen = LaunchRecorder()
    let daemonDigest = fixture.daemonSHA256

    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .failure(let why) = result else {
      return XCTFail("an unversioned profile must not compose a lane")
    }
    XCTAssertTrue("\(why)".contains("id@version"), "\(why)")
    let record = await seen.snapshot()
    XCTAssertNil(record, "an ambiguous profile selector must fail before daemon launch")
  }

  func testDuplicateProfileSelectorFieldsAreRefusedRatherThanGuessed() {
    XCTAssertNil(
      ArkForgeLaneComposition.deviceProfileSelector(
        inDocument: """
          schemaVersion: arkforge.device-profile/v1
          profile:
            id: org.openharmony.dayu200
            id: org.openharmony.another
            version: 1.0.0
          """))
    XCTAssertNil(
      ArkForgeLaneComposition.deviceProfileSelector(
        inDocument: """
          schemaVersion: arkforge.device-profile/v1
          profile:
            id: org.openharmony.dayu200
            version: 1.0.0
            version: 2.0.0
          """))
  }

  func testTheDefaultComposesTheNativeBuildIdentityAndArgument() async throws {
    var nativeEnvironment = environment
    nativeEnvironment["ARKDECK_ARKFORGE_CAMPAIGN"] = "AFA-AC-7"
    let daemonDigest = fixture.daemonSHA256
    let seen = LaunchRecorder()
    let result = await ArkForgeLaneComposition.compose(
      environment: nativeEnvironment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 7, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in
        (
          SilentDaemon(),
          Self.readyAck(
            toolchainID: "arkforged-native-rockusb", toolchain: daemonDigest)
        )
      },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .success(let composed) = result else {
      return XCTFail("the default must compose the native lane, got \(result)")
    }
    XCTAssertEqual(
      composed.toolchain,
      .init(id: "arkforged-native-rockusb", sha256: daemonDigest))
    XCTAssertEqual(composed.lane.toolchainSHA256, daemonDigest)
    let configuration = RuntimeJobEngine.Configuration(
      stateDirectory: URL(filePath: "/tmp/arkdeck-native-plan-test"),
      arkForgeLane: composed.lane)
    XCTAssertEqual(configuration.arkForgeToolchainSHA256, daemonDigest)
    let arguments = await seen.snapshot()?.arguments ?? []
    XCTAssertFalse(arguments.contains("--rockusb-port"))
    XCTAssertFalse(arguments.contains("--rkdeveloptool"))
    XCTAssertFalse(arguments.contains("--rkdeveloptool-sha256"))
    XCTAssertFalse(arguments.contains("/opt/rkdeveloptool"))
    XCTAssertFalse(arguments.joined(separator: " ").contains("rkdeveloptool"))
    XCTAssertEqual(
      arguments[try XCTUnwrap(arguments.firstIndex(of: "--hardware-campaign")) + 1],
      "AFA-AC-7")
  }

  func testTheDefaultRefusesAHandshakeFromAnotherBackend() async {
    let nativeEnvironment = environment
    let daemonDigest = fixture.daemonSHA256
    let result = await ArkForgeLaneComposition.compose(
      environment: nativeEnvironment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 7, dependencies: dependencies(),
      launch: { _, _ in },
      connect: { _ in
        (SilentDaemon(), Self.readyAck(toolchainID: "other-backend", toolchain: daemonDigest))
      },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .failure(let why) = result else {
      return XCTFail("another backend must not enter the native product lane")
    }
    XCTAssertTrue("\(why)".contains("arkforged-native-rockusb"), "\(why)")
  }

  func testTheSecretGoesToTheLaunchAndNotIntoArgv() async {
    // Asserted at the assembly point, where the two could actually diverge.
    let seen = LaunchRecorder()
    let daemonDigest = fixture.daemonSHA256
    _ = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await seen.snapshot()
    XCTAssertEqual(record?.secret.count, 32, "a 32-byte secret must reach the launch")
    let argv = (record?.arguments ?? []).joined(separator: " ")
    XCTAssertFalse(argv.contains(SHA256Hex.lowercaseHex(record?.secret ?? Data())))
    XCTAssertTrue(argv.contains("--pair-from-stdin 3"))
    XCTAssertFalse(argv.contains("--require-release-signing"))
  }

  func testStaleSocketFilesAreGoneBeforeTheDaemonIsLaunched() async throws {
    // A leftover socket file from a previous daemon generation satisfies the
    // "socket exists" readiness probe instantly, so the controller session
    // connected to the *orphaned* previous daemon while the per-job
    // materializer, connecting later by path, reached the new one — the plan
    // then lived in one daemon and startExecution asked the other
    // (PLAN_NOT_STARTABLE, measured 2026-08-18). The files must be gone by the
    // time the new daemon is launched.
    let runtime = FileManager.default.temporaryDirectory.appending(
      path: "lane-compose-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: runtime) }
    for name in ["controller.sock", "public.sock"] {
      FileManager.default.createFile(
        atPath: runtime.appending(path: name).path, contents: Data("stale".utf8))
    }

    let observed = LaunchRecorder()
    let daemonDigest = fixture.daemonSHA256
    _ = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: runtime,
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in
        await observed.record(request: request, secret: secret)
        for name in ["controller.sock", "public.sock"] {
          XCTAssertFalse(
            FileManager.default.fileExists(atPath: runtime.appending(path: name).path),
            "\(name) must be removed before the new daemon is launched")
        }
      },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await observed.snapshot()
    XCTAssertNotNil(record, "the launch must still happen")
  }

  func testADaemonThatNeverOpensItsSocketYieldsNoLane() async {
    let stopped = StopRecorder()
    let lifecycle = ArkForgeLaneComposition.DaemonLifecycle()
    let daemonDigest = fixture.daemonSHA256
    lifecycle.install { stopped.record() }
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(), daemonLifecycle: lifecycle,
      launch: { _, _ in },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in nil })

    guard case .failure(let why) = result else {
      return XCTFail("a daemon that never opened its socket has no lane")
    }
    XCTAssertTrue("\(why)".contains("never opened"), "\(why)")
    XCTAssertEqual(stopped.count, 1, "failed composition must stop its exact daemon generation")
    lifecycle.stop()
    XCTAssertEqual(stopped.count, 1, "daemon shutdown must be idempotent")
  }

  func testADaemonBoundToAnotherToolYieldsNoLane() async {
    // A different daemon build is a different backend identity. Caught at
    // assembly rather than at the first write.
    let expectedDigest = fixture.daemonSHA256
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { _, _ in },
      connect: { _ in
        (
          SilentDaemon(),
          Self.readyAck(
            toolchain: "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611")
        )
      },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .failure(let why) = result else {
      return XCTFail("a daemon on another build must not become a lane")
    }
    XCTAssertTrue("\(why)".contains("038a8a0e"), "\(why)")
    XCTAssertTrue("\(why)".contains(expectedDigest), "\(why)")
  }

  func testAnUnconfiguredDaemonNeverLaunchesAnything() async {
    // Absent is the normal state, and it must not start a process to discover
    // that. Nothing is launched, and the reason names the product effect.
    let seen = LaunchRecorder()
    let daemonDigest = fixture.daemonSHA256
    let result = await ArkForgeLaneComposition.compose(
      environment: [:], runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in (SilentDaemon(), Self.readyAck(toolchain: daemonDigest)) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await seen.snapshot()
    XCTAssertNil(record, "an unconfigured daemon must not spawn anything")
    guard case .failure(let why) = result else { return XCTFail("expected no lane") }
    XCTAssertTrue("\(why)".contains("canonical ArkForge Flash refuses"), "\(why)")
  }

  private actor LaunchRecorder {
    struct Record {
      let arguments: [String]
      let secret: Data
    }
    private var record: Record?
    func record(request: ProcessIdentityBoundRequest, secret: Data) {
      self.record = Record(arguments: request.process.arguments, secret: secret)
    }
    func snapshot() -> Record? { record }
  }

  private final class StopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }

    func record() {
      lock.lock()
      value += 1
      lock.unlock()
    }
  }
}

/// The composition root actually calls the composition.
///
/// A source-level check, in the same spirit as the architecture boundary
/// tests, and for the same reason they exist: the compiler cannot see this.
/// `compose` can be perfect and fully tested while nothing calls it, and the
/// daemon then reports "no lane configured" — indistinguishable from a daemon
/// nobody configured. This project shipped that state for several rounds with
/// every unit test green.
final class ArkForgeCompositionRootContractTests: XCTestCase {

  private func mainSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appending(path: "Sources/ArkDeckAgentDaemonMain/main.swift"),
      encoding: .utf8)
  }

  func testTheDaemonComposesTheLaneAtStartup() throws {
    let source = try mainSource()
    XCTAssertTrue(
      source.contains("ArkForgeLaneComposition.composeFromEnvironment"),
      "main.swift must compose the lane; every part being built and tested is not the same "
        + "as the daemon having one")
  }

  func testTheComposedLaneReachesTheEngine() throws {
    // Composing it and then not passing it would be the same failure wearing a
    // different hat.
    let source = try mainSource()
    XCTAssertTrue(
      source.contains("arkForgeLane: arkForgeLane"),
      "the composed lane must be handed to the engine's configuration")
  }

  func testAbsenceIsReportedRatherThanSilent() throws {
    // The daemon that cannot build a lane and the daemon nobody configured
    // must be distinguishable in the log, because only one of them is a
    // problem an operator should act on.
    let source = try mainSource()
    XCTAssertTrue(
      source.contains("arkforge lane: composed"),
      "a composed lane must say so")
    XCTAssertTrue(
      source.contains("\\(absence)"),
      "an absent lane must write the reason, not fail silently")
  }

  func testTheComposedDaemonIsStoppedOnAgentShutdown() throws {
    let source = try mainSource()
    XCTAssertTrue(source.contains("startedArkForgeDaemon = composed.daemonLifecycle"))
    XCTAssertTrue(source.contains("startedArkForgeDaemon?.stop()"))
  }
}
