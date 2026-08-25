import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckCore
@testable import ArkDeckProcess
@testable import ArkDeckWorkflows

/// Routing pointer injection over an open shell (TASK-IDC-002 stage 6).
///
/// The saving is a per-command constant — measured interleaved against the
/// device, p50 334 ms spawned versus p50 223 ms over an open channel — so what
/// decides whether this is worth having is not the number but what stays off
/// the channel and what happens when the channel cannot answer.
final class PointerInputChannelRoutingContractTests: XCTestCase {
  /// Stands in for `hdc`: the dispatcher opens the channel as
  /// `<executable> -t <key> shell`, so the shell under test has to be reached
  /// by a binary that accepts that shape. This one ignores the arguments and
  /// becomes a shell, which is exactly what `hdc shell` does once it has
  /// reached the device.
  private var shellStub: URL!

  override func setUpWithError() throws {
    shellStub = FileManager.default.temporaryDirectory
      .appending(path: "arkdeck-channel-stub-\(UUID().uuidString)")
    try "#!/bin/sh\nexec /bin/sh\n".write(to: shellStub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: shellStub.path())
  }

  override func tearDownWithError() throws {
    if let shellStub { try? FileManager.default.removeItem(at: shellStub) }
  }

  private struct Resolver: RuntimeExecutableResolving {
    var path: String
    var fails = false
    func resolveExecutable(providerID: String) throws -> ResolvedExecutable {
      if fails { throw DeviceShellChannelError.unavailable("no executable") }
      let digest = SHA256.hash(data: (try? Data(contentsOf: URL(filePath: path))) ?? Data())
      return ResolvedExecutable(
        path: path, sha256: digest.map { String(format: "%02x", $0) }.joined())
    }
  }

  private actor RecordingDispatcher: RuntimeProcessDispatching {
    private(set) var dispatched: [TypedProcessPlan] = []
    func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt {
      dispatched.append(plan)
      return ProviderProcessReceipt(
        exitStatus: 0, stdout: Data("spawned\n".utf8), stderr: Data(),
        stdoutTruncated: false, durationSeconds: 0)
    }
  }

  private func spec() throws -> HDCPointerInputSpec {
    try HDCPointerInputSpec(
      gesture: .tap, x: 640, y: 1500, displayWidth: 1260, displayHeight: 2720)
  }

  private func plan(
    action: TypedProviderAction? = nil,
    argv: [String] = ["-t", "KEY", "shell", "uinput", "-T", "-c", "640", "1500"],
    timeoutSeconds: Int? = 30,
    hostLanding: HostLandingExpectation? = nil
  ) throws -> TypedProcessPlan {
    TypedProcessPlan(
      action: try action ?? .hdc(.injectPointerInput(spec())),
      kind: .process(
        executableSHA256: "resolved-at-dispatch", argumentSummary: argv,
        timeoutSeconds: timeoutSeconds),
      hostLanding: hostLanding)
  }

  // MARK: - What may ride the channel

  func testOnlyAPointerInjectionInTheExpectedShapeIsRouted() throws {
    XCTAssertNotNil(PointerInputChannelDispatcher.routable(try plan()))

    XCTAssertNil(
      PointerInputChannelDispatcher.routable(try plan(action: .hdc(.observeDevice(connectKey: "KEY")))),
      "another action must keep the behaviour it already has")
    XCTAssertNil(
      PointerInputChannelDispatcher.routable(
        try plan(argv: ["-t", "KEY", "file", "send", "/a", "/b"])),
      "a plan that is not a device shell command cannot be a shell line")
    XCTAssertNil(
      PointerInputChannelDispatcher.routable(
        try plan(hostLanding: HostLandingExpectation(
          destination: URL(filePath: "/tmp/x"), maximumBytes: 1_024))),
      "a plan whose product is a host file is not carried by a shell")
  }

  /// Arguments become one shell line, so a token the shell would not read back
  /// unchanged is left to the spawning path. Quoting it instead would mean the
  /// two dispatch shapes could run different commands, which is a worse
  /// outcome than not using the channel.
  func testATokenTheShellWouldRereadIsLeftToTheSpawningPath() throws {
    for token in ["two words", "a;rm -rf /", "$HOME", "a|b", "`x`", "a\nb"] {
      XCTAssertNil(
        PointerInputChannelDispatcher.routable(
          try plan(argv: ["-t", "KEY", "shell", "uinput", token])),
        "\(token) must not be joined into a shell line")
    }
  }

  func testASequenceIsNeverRouted() throws {
    let sequence = TypedProcessPlan(
      action: .hdc(.injectPointerInput(try spec())),
      kind: .processSequence(
        executableSHA256: "resolved-at-dispatch",
        invocations: [
          TypedProcessInvocation(
            arguments: ["-t", "KEY", "shell", "uinput"], timeoutSeconds: 30)
        ]))
    XCTAssertNil(PointerInputChannelDispatcher.routable(sequence))
  }

  // MARK: - What happens when the channel cannot serve

  func testAnUnroutablePlanReachesTheDispatcherItWraps() async throws {
    let fallback = RecordingDispatcher()
    let routing = PointerInputChannelDispatcher(
      fallback: fallback, resolver: Resolver(path: shellStub.path()), childEnvironment: [:])
    let observe = try plan(action: .hdc(.observeDevice(connectKey: "KEY")))
    _ = try await routing.dispatch(observe)
    let seen = await fallback.dispatched
    XCTAssertEqual(seen, [observe])
    await routing.closeAllChannels()
  }

  /// A channel that cannot be opened costs latency, never the operation:
  /// nothing was written, so the gesture still goes out the ordinary way.
  func testAChannelThatCannotOpenFallsBackToSpawning() async throws {
    let fallback = RecordingDispatcher()
    let routing = PointerInputChannelDispatcher(
      fallback: fallback, resolver: Resolver(path: shellStub.path(), fails: true), childEnvironment: [:])
    let receipt = try await routing.dispatch(try plan())
    XCTAssertEqual(String(decoding: receipt.stdout, as: UTF8.self), "spawned\n")
    let seen = await fallback.dispatched
    XCTAssertEqual(seen.count, 1)
    await routing.closeAllChannels()
  }

  /// The one case that must never fall back. The command was written and the
  /// device may well have carried it out; dispatching it again would inject a
  /// second gesture. So the caller inherits an unknown outcome instead.
  func testAGestureThatWasWrittenButNeverAnsweredIsNeverSentAgain() async throws {
    let fallback = RecordingDispatcher()
    let routing = PointerInputChannelDispatcher(
      fallback: fallback, resolver: Resolver(path: shellStub.path()), childEnvironment: [:])
    // The shell here is the host's, so this is a command that is written and
    // then does not answer inside its timeout — the shape of a device that
    // took the gesture and went quiet.
    let stalling = try plan(argv: ["-t", "KEY", "shell", "sleep", "9"], timeoutSeconds: 1)
    do {
      _ = try await routing.dispatch(stalling)
      XCTFail("a gesture with an unknown outcome must not be reported as done")
    } catch let failure as RuntimeDispatchFailure {
      guard case .outcomeUnknown = failure else {
        return XCTFail("expected outcomeUnknown, got \(failure)")
      }
    }
    let seen = await fallback.dispatched
    XCTAssertTrue(
      seen.isEmpty,
      "an unknown outcome must never be resolved by dispatching the gesture again")
    await routing.closeAllChannels()
  }

  /// A routed gesture really does go over the channel rather than quietly
  /// taking the spawning path.
  func testARoutedGestureReachesTheChannelAndNotTheFallback() async throws {
    let fallback = RecordingDispatcher()
    let routing = PointerInputChannelDispatcher(
      fallback: fallback, resolver: Resolver(path: shellStub.path()), childEnvironment: [:])
    let receipt = try await routing.dispatch(
      try plan(argv: ["-t", "KEY", "shell", "echo", "over-the-channel"]))
    XCTAssertEqual(
      String(decoding: receipt.stdout, as: UTF8.self), "over-the-channel\n")
    let seen = await fallback.dispatched
    XCTAssertTrue(seen.isEmpty)
    await routing.closeAllChannels()
  }

  /// An open channel is a shell running on the device, so it has to close on
  /// its own. Sweeping only when the next gesture arrives closes nothing in
  /// the case that matters - the one where no next gesture comes. Measured on
  /// the device before this was armed: still open 11 minutes after the last
  /// gesture, under a 120s timeout.
  func testAnIdleChannelClosesWithoutWaitingForAnotherGesture() async throws {
    let routing = PointerInputChannelDispatcher(
      fallback: RecordingDispatcher(), resolver: Resolver(path: shellStub.path()),
      childEnvironment: [:], idleTimeout: 0.5)
    _ = try await routing.dispatch(
      try plan(argv: ["-t", "KEY", "shell", "echo", "open"]))
    let heldAfterUse = await routing.holdsChannel(connectKey: "KEY")
    XCTAssertTrue(heldAfterUse, "the channel is held while gestures are arriving")

    // Nothing else is dispatched: the close has to come from the channel's own
    // idle timer.
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let heldWhenIdle = await routing.holdsChannel(connectKey: "KEY")
    XCTAssertFalse(
      heldWhenIdle, "an idle channel must not outlive its timeout on the device")
    await routing.closeAllChannels()
  }

  /// The channel reports the status the spawning path reports. `hdc shell`
  /// cannot carry the device's own status back, so a channel that surfaced it
  /// would make a gesture's verdict depend on which path it happened to take.
  func testTheChannelReportsTheStatusTheSpawningPathWouldReport() async throws {
    let routing = PointerInputChannelDispatcher(
      fallback: RecordingDispatcher(), resolver: Resolver(path: shellStub.path()), childEnvironment: [:])
    let receipt = try await routing.dispatch(
      try plan(argv: ["-t", "KEY", "shell", "definitely-not-a-binary"]))
    XCTAssertEqual(
      receipt.exitStatus, 0,
      "both dispatch shapes must answer with the same status for the same command")
    await routing.closeAllChannels()
  }
}
