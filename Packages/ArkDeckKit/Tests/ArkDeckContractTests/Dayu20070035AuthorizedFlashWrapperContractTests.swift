import Foundation
import XCTest

final class Dayu20070035AuthorizedFlashWrapperContractTests: XCTestCase {
  private static let planDigest =
    "3922f6a22401a624dd393932bbfc7d3774953be79aaece08961a8bbfb77dc2b8"
  private static let authorizationID = "AUTH-2026-025-DAYU200-TEST"

  func testWrapperPinsExactV2FactsAndDelegatesOnlyToTypedExecutor() throws {
    let source = try String(contentsOf: Self.scriptURL, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e"))
    XCTAssertTrue(
      source.contains(
        "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"))
    XCTAssertTrue(source.contains(Self.planDigest))
    XCTAssertTrue(
      source.contains(
        "c8bdce2a137690081c1dd5ca38f91f25399c63778ab18b4f94000b127382fa14"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash execute"))
    XCTAssertTrue(source.contains("--authorization-id \"$authorization_id\""))
    XCTAssertTrue(source.contains("ARKDECK_EXECUTION_AUTHORITY=standardAgent"))
    XCTAssertFalse(source.contains("eval "))
    XCTAssertFalse(source.contains("sudo "))
    XCTAssertFalse(source.contains("exec \"$TOOL\""))
  }

  func testChatTriggerRejectsAnythingButTheFullPinnedPlanBeforeHostChecks() throws {
    let result = try runScript([
      "--chat-trigger", "--authorization-id", Self.authorizationID,
      "--confirm-plan-sha256", String(Self.planDigest.prefix(12)),
    ])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("does not confirm the exact pinned plan digest"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  func testOrdinaryCICannotUseChatTriggerEvenWithExactPlan() throws {
    let result = try runScript(
      [
        "--chat-trigger", "--authorization-id", Self.authorizationID,
        "--confirm-plan-sha256", Self.planDigest,
      ],
      environment: ["CI": "true"])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("CI cannot trigger real Flash"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  func testInteractiveTriggerRequiresTTYBeforeHostChecks() throws {
    let result = try runScript([
      "--interactive-trigger", "--authorization-id", Self.authorizationID,
    ])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("requires stdin and stdout attached to a TTY"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  private static var scriptURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Scripts/run-dayu200-70035-authorized-flash.sh")
  }

  private func runScript(
    _ arguments: [String], environment additions: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Self.scriptURL.path] + arguments
    process.standardInput = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
