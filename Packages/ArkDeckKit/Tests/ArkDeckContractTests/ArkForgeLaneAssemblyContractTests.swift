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

  private let environment = [
    "ARKDECK_ARKFORGED_PATH": "/opt/arkforged",
    "ARKDECK_ARKFORGED_SHA256": String(repeating: "a", count: 64),
    "ARKDECK_ARKFORGE_PROFILE_PATH": "/opt/dayu200.yaml",
    "ARKDECK_RKDEVELOPTOOL_PATH": "/opt/rkdeveloptool",
  ]

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
      approvedPlan: { jobID, planID in
        .init(
          jobID: jobID, planID: planID, planSHA256: [], admittedDeviceFactsSHA256: [],
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
