import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckProcess

/// The persistent device shell (TASK-IDC-002 stage 6).
///
/// Spawning a client per command costs a process launch on top of the device
/// round trip — measured p50 242 ms spawned versus p50 177 ms over an open
/// channel for the same `uinput` invocation, against a 400 ms interactive
/// budget. What makes a channel safe to use is not the saving but what it does
/// when it cannot answer, which is what these assert.
///
/// The shell here is the host's `/bin/sh` rather than a device: the framing,
/// the status recovery and every refusal are properties of the channel, and
/// pinning them to a real device would make them unrunnable rather than
/// stronger.
final class PersistentDeviceShellChannelContractTests: XCTestCase {
  private func shellRequest(timeout: TimeInterval = 30) throws -> ProcessIdentityBoundRequest {
    let executable = URL(filePath: "/bin/sh")
    let digest = SHA256.hash(data: try Data(contentsOf: executable))
    return ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: executable, arguments: [], timeout: timeout),
      expectedSHA256: digest.map { String(format: "%02x", $0) }.joined())
  }

  private func openChannel() throws -> PersistentDeviceShellChannel {
    try PersistentDeviceShellChannel.open(try shellRequest(), settleSeconds: 0.4)
  }

  private func answer(
    _ channel: PersistentDeviceShellChannel, _ argv: [String],
    timeout: TimeInterval = 10, budget: Int = 1_048_576
  ) throws -> DeviceShellAnswer {
    try channel.run(argv, timeout: timeout, outputByteBudget: budget)
  }

  /// A spawned `hdc shell` exits 0 whether the device command succeeded,
  /// failed, or was never found, so verdicts on that path have to be inferred
  /// from output text. Framing the command recovers the status itself, which
  /// is the stronger fact and the reason this shape is worth its hazards.
  func testTheChannelRecoversTheStatusOfTheCommandItRan() throws {
    let channel = try openChannel()
    defer { channel.close() }
    XCTAssertEqual(try answer(channel, ["true"]).deviceExitStatus, 0)
    XCTAssertEqual(try answer(channel, ["false"]).deviceExitStatus, 1)
    XCTAssertEqual(
      try answer(channel, ["definitely-not-a-binary"]).deviceExitStatus, 127,
      "a command that was never found must be distinguishable from one that failed")
  }

  func testOutputComesBackWithoutTheCommandOrThePrompt() throws {
    let channel = try openChannel()
    defer { channel.close() }
    let first = try answer(channel, ["echo", "alpha"])
    XCTAssertEqual(String(decoding: first.stdout, as: UTF8.self), "alpha\n")
    XCTAssertFalse(first.truncated)
    // The second answer must not carry any part of the first, which is what a
    // stream read by position rather than by frame would do.
    let second = try answer(channel, ["echo", "beta"])
    XCTAssertEqual(String(decoding: second.stdout, as: UTF8.self), "beta\n")
  }

  /// Arguments are joined into one shell line, so a token the shell would not
  /// read back exactly is refused rather than quoted: a quoting rule differing
  /// from the spawned path by one character would make the two dispatch shapes
  /// run different commands, which is worse than not using the channel.
  func testATokenTheShellWouldRereadIsRefusedRatherThanQuoted() throws {
    let channel = try openChannel()
    defer { channel.close() }
    for argv in [["echo", "two words"], ["echo", "a;rm"], ["echo", "$HOME"], ["echo", "a|b"]] {
      XCTAssertThrowsError(try answer(channel, argv), "\(argv) must not ride the channel") {
        guard case DeviceShellChannelError.unavailable = $0 else {
          return XCTFail("expected unavailable, got \($0)")
        }
      }
    }
    // Refusing a command must not cost the channel: it never reached the device.
    XCTAssertEqual(try answer(channel, ["echo", "still-open"]).deviceExitStatus, 0)
  }

  /// The command was written and the device may well have carried it out. That
  /// is an unknown outcome, and it must never be reported as a failure — a
  /// gesture reported failed is a gesture a person may repeat.
  func testACommandThatNeverAnswersIsUnknownRatherThanFailed() throws {
    let channel = try openChannel()
    defer { channel.close() }
    XCTAssertThrowsError(try answer(channel, ["sleep", "5"], timeout: 0.5)) {
      guard case DeviceShellChannelError.outcomeUnknown = $0 else {
        return XCTFail("expected outcomeUnknown, got \($0)")
      }
    }
    // The stream's position is no longer trustworthy, so the channel is gone
    // rather than resynchronised.
    XCTAssertFalse(channel.isAlive)
  }

  /// A channel whose far end is gone must refuse, not hang and not invent an
  /// answer. Nothing was written, so this is `unavailable` and the caller may
  /// still spawn.
  func testAChannelWhoseShellIsGoneRefusesRatherThanGuessing() throws {
    let channel = try openChannel()
    defer { channel.close() }
    XCTAssertEqual(try answer(channel, ["true"]).deviceExitStatus, 0)
    channel.close()
    XCTAssertFalse(channel.isAlive)
    XCTAssertThrowsError(try answer(channel, ["true"])) {
      guard case DeviceShellChannelError.unavailable = $0 else {
        return XCTFail("expected unavailable, got \($0)")
      }
    }
  }

  /// Output past the budget is dropped from what is returned, but the command
  /// is still accounted for: the status comes back and the channel stays
  /// usable, because abandoning it over a chatty command would cost every
  /// command after it.
  func testOutputBeyondTheBudgetIsTruncatedWithoutLosingTheStatus() throws {
    let channel = try openChannel()
    defer { channel.close() }
    let answered = try answer(
      channel, ["/usr/bin/head", "-c", "200000", "/dev/zero"], budget: 4_096)
    XCTAssertTrue(answered.truncated)
    XCTAssertLessThanOrEqual(answered.stdout.count, 4_096)
    XCTAssertEqual(answered.deviceExitStatus, 0)
    XCTAssertEqual(
      try answer(channel, ["echo", "after"]).deviceExitStatus, 0,
      "a chatty command must not cost the channel")
  }

  func testTheChannelRefusesAnExecutableWhoseIdentityDoesNotMatch() throws {
    let wrong = ProcessIdentityBoundRequest(
      process: ProcessRequest(executable: URL(filePath: "/bin/sh"), arguments: []),
      expectedSHA256: String(repeating: "a", count: 64))
    XCTAssertThrowsError(try PersistentDeviceShellChannel.open(wrong, settleSeconds: 0.2)) {
      guard case DeviceShellChannelError.unavailable = $0 else {
        return XCTFail("expected unavailable, got \($0)")
      }
    }
  }
}
