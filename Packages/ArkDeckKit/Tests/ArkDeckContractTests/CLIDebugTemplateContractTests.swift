import Foundation
import XCTest

@testable import ArkDeckCLI
@testable import ArkDeckCore
@testable import ArkDeckWorkflows

/// `arkdeck debug template list/run`: the listing is a local projection of the
/// closed template set, and running one is the generic Job path for
/// `debug.template@1`. Host-only; no daemon or device is involved.
final class CLIDebugTemplateContractTests: XCTestCase {
  private enum FixtureFailure: Error { case malformed, timeout }

  private struct Run {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
  }

  func testRegistryPublishesTheTemplateLeavesWithoutHandCopiedInputs() throws {
    let leaves = CLICommandRegistry.allLeaves()
    let list = try XCTUnwrap(leaves.first { $0.path == ["debug", "template", "list"] })
    XCTAssertFalse(list.leaf.connectsToRuntime, "the listing never opens a control connection")
    XCTAssertNil(list.leaf.catalogOperation)
    XCTAssertEqual(list.leaf.outputModes, [.human, .json])
    let run = try XCTUnwrap(leaves.first { $0.path == ["debug", "template", "run"] })
    XCTAssertEqual(run.leaf.catalogOperation, "debug.template@1")
    XCTAssertTrue(run.leaf.connectsToRuntime)

    XCTAssertNotNil(CLIArgumentParser.parse(["debug", "template", "list"]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "debug", "template", "run", "--inputs-file", "/private/tmp/template-inputs.json",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse(["debug", "template", "run", "--template", "device.uptime"]).failure,
      "the template identity is an operation input published by `operation describe`, not a flag")
    XCTAssertNotNil(
      CLIArgumentParser.parse(["debug", "template", "list", "--target", "TGT-1"]).failure)
    XCTAssertNotNil(CLIArgumentParser.parse(["debug", "template", "exec"]).failure)

    let logs = try XCTUnwrap(leaves.first { $0.path == ["debug", "logs"] })
    XCTAssertEqual(logs.leaf.catalogOperation, "capture.diagnostics@1")
    XCTAssertTrue(logs.leaf.connectsToRuntime)
    XCTAssertNotNil(
      CLIArgumentParser.parse([
        "debug", "logs", "--inputs-file", "/private/tmp/logs-inputs.json",
      ]).success)
    XCTAssertNotNil(
      CLIArgumentParser.parse(["debug", "logs", "--duration", "30"]).failure,
      "the window and filters are operation inputs, not flags")
  }

  func testRealCLIProcessListsTheClosedTemplateSetFromTheCatalog() async throws {
    let listed = try await run(["debug", "template", "list", "--output", "json"])
    XCTAssertEqual(listed.exitCode, 0, diagnostic(listed))
    let result = try result(listed)
    XCTAssertEqual(result["schemaVersion"], .string("arkdeck.debug-template-list/1"))
    XCTAssertEqual(result["operation"], .string("debug.template@1"))
    XCTAssertEqual(result["effect"], .string("readOnly"))
    XCTAssertEqual(result["catalogDigest"], .string(RuntimeOperationCatalog.catalogDigest))
    guard case .array(let templates)? = result["templates"] else {
      return XCTFail("the listing must carry the template array")
    }
    let descriptor = try XCTUnwrap(RuntimeOperationCatalog.descriptor(reference: "debug.template@1"))
    let published = try XCTUnwrap(descriptor.inputs.first { $0.name == "templateId" }?.enumValues)
    var identities: [String] = []
    for template in templates {
      guard case .object(let fields) = template,
        Set(fields.keys) == [
          "templateId", "title", "effect", "remoteCommand", "outputByteBudget", "inputs",
        ],
        case .string(let identity)? = fields["templateId"],
        case .string(let title)? = fields["title"], !title.isEmpty,
        fields["effect"] == .string("readOnly"),
        case .array(let command)? = fields["remoteCommand"],
        command.first == .string("shell"), !command.contains(.string("-t")),
        case .integer(let budget)? = fields["outputByteBudget"], budget > 0,
        fields["inputs"] == .object(["templateId": .string(identity)])
      else { return XCTFail("template row is malformed: \(template)") }
      identities.append(identity)
    }
    XCTAssertEqual(identities, published)
    XCTAssertEqual(identities, DebugRuntimeCommandTemplate.allCases.map(\.rawValue))

    let human = try await run(["debug", "template", "list"])
    XCTAssertEqual(human.exitCode, 0, diagnostic(human))
    XCTAssertTrue(
      String(decoding: human.stdout, as: UTF8.self).contains("device.uptime"), diagnostic(human))
  }

  private func run(_ argv: [String]) async throws -> Run {
    let process = Process()
    process.executableURL = Bundle(for: Self.self).bundleURL
      .deletingLastPathComponent().appending(path: "arkdeck")
    process.arguments = argv
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(25)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      throw FixtureFailure.timeout
    }
    return Run(
      exitCode: process.terminationStatus,
      stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
      stderr: stderr.fileHandleForReading.readDataToEndOfFile())
  }

  private func result(_ run: Run) throws -> [String: JSONValue] {
    guard case .object(let envelope) = try CLIStrictJSON.decode(run.stdout),
      case .object(let value)? = envelope["result"]
    else { throw FixtureFailure.malformed }
    return value
  }

  private func diagnostic(_ run: Run) -> String {
    String(decoding: run.stderr + run.stdout, as: UTF8.self)
  }
}

private extension Result {
  var success: Success? {
    guard case .success(let value) = self else { return nil }
    return value
  }

  var failure: Failure? {
    guard case .failure(let value) = self else { return nil }
    return value
  }
}
