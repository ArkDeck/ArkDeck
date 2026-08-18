import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckWorkflows
@testable import ArkForgeIPC

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

  /// A real file, because composition reads the profile's declared id out of
  /// it before launching anything: `materializePlan` addresses a profile by
  /// that id, and a lane that cannot name one cannot materialize a plan.
  private var profileURL: URL!

  override func setUpWithError() throws {
    profileURL = FileManager.default.temporaryDirectory
      .appending(path: "arkforge-assembly-\(UUID().uuidString).yaml")
    try Data(
      """
      schemaVersion: arkforge.device-profile/v1

      profile:
        id: org.openharmony.dayu200
        version: 1.0.0
      """.utf8
    ).write(to: profileURL)
  }

  override func tearDownWithError() throws {
    if let profileURL { try? FileManager.default.removeItem(at: profileURL) }
  }

  private var environment: [String: String] {
    [
      "ARKDECK_ARKFORGED_PATH": "/opt/arkforged",
      "ARKDECK_ARKFORGED_SHA256": String(repeating: "a", count: 64),
      "ARKDECK_ARKFORGE_PROFILE_PATH": profileURL.path,
      "ARKDECK_RKDEVELOPTOOL_PATH": "/opt/rkdeveloptool",
    ]
  }

  private static func readyAck(
    toolchain: String = ArkForgeToolchainPin.signedSHA256
  ) -> ArkForgeHelloAck {
    ArkForgeHelloAck(
      protocolMajor: 1, protocolMinor: 0, sessionKind: .controller, daemonVersion: "0.1.0",
      refusal: nil, executionReady: true, executionBlockers: [],
      toolchainID: "rkdeveloptool", toolchainSHA256: toolchain)
  }

  private func dependencies() -> ArkForgeLaneComposition.Dependencies {
    .init(
      rockchipHost: { RefusingRockchipRuntimeActionHost(reason: "test") },
      rockchipExecutable: ResolvedExecutable(
        path: "/opt/rkdeveloptool", sha256: String(repeating: "c", count: 64)),
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
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { _, _ in },
      connect: { _ in (SilentDaemon(), Self.readyAck()) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .success = result else {
      return XCTFail("a fully configured daemon must produce a lane, got \(result)")
    }
  }

  func testTheSecretGoesToTheLaunchAndNotIntoArgv() async {
    // Asserted at the assembly point, where the two could actually diverge.
    let seen = LaunchRecorder()
    _ = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in (SilentDaemon(), Self.readyAck()) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await seen.snapshot()
    XCTAssertEqual(record?.secret.count, 32, "a 32-byte secret must reach the launch")
    let argv = (record?.arguments ?? []).joined(separator: " ")
    XCTAssertFalse(argv.contains(SHA256Hex.lowercaseHex(record?.secret ?? Data())))
    XCTAssertTrue(argv.contains("--pair-from-stdin 3"))
    XCTAssertTrue(argv.contains("--require-release-signing"))
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
      connect: { _ in (SilentDaemon(), Self.readyAck()) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await observed.snapshot()
    XCTAssertNotNil(record, "the launch must still happen")
  }

  func testADaemonThatNeverOpensItsSocketYieldsNoLane() async {
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { _, _ in }, connect: { _ in (SilentDaemon(), Self.readyAck()) },
      awaitSocket: { _ in nil })

    guard case .failure(let why) = result else {
      return XCTFail("a daemon that never opened its socket has no lane")
    }
    XCTAssertTrue("\(why)".contains("never opened"), "\(why)")
  }

  func testADaemonBoundToAnotherToolYieldsNoLane() async {
    // The rehearsal build, which AD-023 showed cannot ship. Caught at assembly
    // rather than at the first write.
    let result = await ArkForgeLaneComposition.compose(
      environment: environment, runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { _, _ in },
      connect: { _ in
        (SilentDaemon(),
         Self.readyAck(
          toolchain: "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"))
      },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    guard case .failure(let why) = result else {
      return XCTFail("a daemon on an unshippable tool must not become a lane")
    }
    XCTAssertTrue("\(why)".contains("libusb"), "\(why)")
  }

  func testAnUnconfiguredDaemonNeverLaunchesAnything() async {
    // Absent is the normal state, and it must not start a process to discover
    // that. Nothing is launched, and the reason names the product effect.
    let seen = LaunchRecorder()
    let result = await ArkForgeLaneComposition.compose(
      environment: [:], runtimeDirectory: URL(filePath: "/tmp/rt"),
      pairingEpoch: 3, dependencies: dependencies(),
      launch: { request, secret in await seen.record(request: request, secret: secret) },
      connect: { _ in (SilentDaemon(), Self.readyAck()) },
      awaitSocket: { _ in "/tmp/rt/controller.sock" })

    let record = await seen.snapshot()
    XCTAssertNil(record, "an unconfigured daemon must not spawn anything")
    guard case .failure(let why) = result else { return XCTFail("expected no lane") }
    XCTAssertTrue("\(why)".contains("flash.dayu200 refuses"), "\(why)")
  }

  private actor LaunchRecorder {
    struct Record { let arguments: [String]; let secret: Data }
    private var record: Record?
    func record(request: ProcessIdentityBoundRequest, secret: Data) {
      self.record = Record(arguments: request.process.arguments, secret: secret)
    }
    func snapshot() -> Record? { record }
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
}
