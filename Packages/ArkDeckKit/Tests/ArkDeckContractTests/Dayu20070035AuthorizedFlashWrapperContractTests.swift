import CryptoKit
import Foundation
import XCTest

@testable import ArkDeckWorkflows

final class Dayu20070035AuthorizedFlashWrapperContractTests: XCTestCase {
  private static let planDigest =
    "3922f6a22401a624dd393932bbfc7d3774953be79aaece08961a8bbfb77dc2b8"
  private static let confirmationDigest = String(repeating: "a", count: 64)

  func testWrapperPinsExactV2FactsAndDelegatesOnlyToTypedExecutor() throws {
    let source = try String(contentsOf: Self.scriptURL, encoding: .utf8)

    XCTAssertTrue(
      source.contains(
        "6a023c738ac585b8a6f537c99f2ab2df95a5359fd6d4dd33150fad62e71f064e"))
    XCTAssertTrue(
      source.contains(
        "038a8a0ea26ef7eb77451789f310c0c9fbeaf43a78af1d6146e02311a9c23611"))
    XCTAssertTrue(
      source.contains(
        "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83"))
    XCTAssertTrue(source.contains(Self.planDigest))
    XCTAssertTrue(
      source.contains(
        "c8bdce2a137690081c1dd5ca38f91f25399c63778ab18b4f94000b127382fa14"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash execute"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash install-tool"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash install-binding"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash binding-preview"))
    XCTAssertTrue(source.contains("\"$ARKDECK_BIN\" flash rebind-binding"))
    XCTAssertTrue(
      source.contains(
        "/usr/bin/swift build --package-path \"$PACKAGE_DIR\" -c release --product arkdeck"))
    XCTAssertFalse(source.contains("if [[ ! -x \"$ARKDECK_BIN\" ]]"))
    XCTAssertTrue(source.contains("--prepare"))
    XCTAssertTrue(source.contains("--confirm-target-sha256"))
    XCTAssertTrue(source.contains("--confirm-binding-revision"))
    XCTAssertTrue(source.contains("--chat-confirmation-digest-sha256"))
    XCTAssertTrue(source.contains("--chat-confirmed-target-sha256"))
    XCTAssertTrue(source.contains("ARKDECK_CHAT_CONFIRMATION_CONTEXT=supervisedInteractiveAgent"))
    XCTAssertTrue(source.contains("ARKDECK_EXECUTION_AUTHORITY=standardAgent"))
    XCTAssertTrue(source.contains("typed hdc shell reboot loader"))
    XCTAssertFalse(source.contains("--authorization-id"))
    XCTAssertFalse(source.contains("AUTH-ID must match"))
    XCTAssertFalse(source.contains("eval "))
    XCTAssertFalse(source.contains("sudo "))
    XCTAssertFalse(source.contains("exec \"$TOOL\""))
    XCTAssertLessThan(
      try XCTUnwrap(source.range(of: "flash rebind-binding")?.lowerBound),
      try XCTUnwrap(source.range(of: "flash execute")?.lowerBound))
  }

  func testWrapperTargetDigestUsesTheCanonicalProductModel() throws {
    let source = try String(contentsOf: Self.scriptURL, encoding: .utf8)
    let canonicalModel = "DAYU200 (RK3568)"
    let serialDigest = "958780b2ffb7090d4f22cdc1f547f9804ed0f0b605e3020f384e5d4823dc7a7e"

    XCTAssertEqual(RockchipFlashProfile.targetDeviceModel, canonicalModel)
    XCTAssertTrue(source.contains("readonly TARGET_MODEL=\"\(canonicalModel)\""))
    XCTAssertTrue(
      source.contains(
        "\"${TARGET_MODEL}|${binding_serial_sha256}|${binding_revision}|${target_location_id}|8711|13578\""))
    XCTAssertFalse(source.contains("\"dayu200|${binding_serial_sha256}"))

    let targetMaterial = [canonicalModel, serialDigest, "1", "18874368", "8711", "13578"]
      .joined(separator: "|")
    let digest = SHA256.hash(data: Data(targetMaterial.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    XCTAssertEqual(
      digest, "f07f2eb8ae0539dc9fe4d9691cfc74776d4d7e1a8fe49ec3c57ef2819ff79428")
  }

  func testChatTriggerRejectsAnythingButTheFullPinnedPlanBeforeHostChecks() throws {
    let result = try runScript([
      "--chat-trigger", "--confirmation-digest-sha256", Self.confirmationDigest,
      "--confirm-plan-sha256", String(Self.planDigest.prefix(12)),
    ])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("does not confirm the exact pinned plan digest"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  func testChatTriggerRequiresProspectiveTargetAndBindingBeforeHostChecks() throws {
    let result = try runScript([
      "--chat-trigger", "--confirmation-digest-sha256", Self.confirmationDigest,
      "--confirm-plan-sha256", Self.planDigest,
      "--confirm-target-sha256", String(repeating: "b", count: 63),
      "--confirm-binding-revision", "2",
    ])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("full prospective target digest"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  func testOrdinaryCICannotUseChatTriggerEvenWithExactPlan() throws {
    let result = try runScript(
      [
        "--chat-trigger", "--confirmation-digest-sha256", Self.confirmationDigest,
        "--confirm-plan-sha256", Self.planDigest,
      ],
      environment: ["CI": "true"])

    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.output.contains("CI cannot trigger real Flash"))
    XCTAssertFalse(result.output.contains("READY:"))
  }

  func testInteractiveTriggerRequiresTTYBeforeHostChecks() throws {
    let result = try runScript([
      "--interactive-trigger"
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
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "CI")
    environment.removeValue(forKey: "GITHUB_ACTIONS")
    process.environment = environment.merging(additions) { _, new in new }
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
