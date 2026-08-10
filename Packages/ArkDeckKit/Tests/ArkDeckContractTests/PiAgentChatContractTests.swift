import Foundation
import XCTest

@testable import ArkDeckCLI

final class PiAgentChatContractTests: XCTestCase {
  func testChatLaunchLoadsOnlyTheBundledArkDeckTools() throws {
    let options = try PiAgentChatOptions.parse([
      "--pi-path", "/opt/tools/pi",
      "--socket", "/tmp/arkdeck-agentd.sock",
      "--prompt", "检查设备状态",
    ])
    let plan = PiAgentChatLaunchPlan(
      piExecutable: URL(fileURLWithPath: "/opt/tools/pi"),
      extensionURL: URL(fileURLWithPath: "/bundle/Pi/arkdeck-extension.ts"),
      arkdeckExecutable: URL(fileURLWithPath: "/opt/arkdeck/bin/arkdeck"),
      options: options,
      inheritedEnvironment: ["PATH": "/usr/bin"])

    XCTAssertTrue(plan.arguments.contains("--no-extensions"))
    XCTAssertTrue(plan.arguments.contains("--no-builtin-tools"))
    XCTAssertTrue(plan.arguments.contains("--no-skills"))
    XCTAssertTrue(plan.arguments.contains("--no-context-files"))
    let toolsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--tools"))
    XCTAssertEqual(
      plan.arguments[toolsIndex + 1],
      PiAgentChatLaunchPlan.activeTools.joined(separator: ","))
    XCTAssertEqual(plan.arguments.last, "User request:\n检查设备状态")
    XCTAssertEqual(plan.environment["ARKDECK_PI_ARKDECK_PATH"], "/opt/arkdeck/bin/arkdeck")
    XCTAssertEqual(plan.environment["ARKDECK_PI_AGENTD_SOCKET"], "/tmp/arkdeck-agentd.sock")
    XCTAssertEqual(plan.environment["ARKDECK_PI_ALLOW_SENSITIVE_ARTIFACTS"], "0")
    XCTAssertEqual(plan.environment["PI_SKIP_VERSION_CHECK"], "1")
    XCTAssertEqual(plan.environment["PI_TELEMETRY"], "0")
  }

  func testSensitiveArtifactAccessRequiresAnExplicitChatFlag() throws {
    let options = try PiAgentChatOptions.parse(["--allow-sensitive-artifacts"])
    let plan = PiAgentChatLaunchPlan(
      piExecutable: URL(fileURLWithPath: "/opt/tools/pi"),
      extensionURL: URL(fileURLWithPath: "/bundle/Pi/arkdeck-extension.ts"),
      arkdeckExecutable: URL(fileURLWithPath: "/opt/arkdeck/bin/arkdeck"),
      options: options,
      inheritedEnvironment: [:])

    XCTAssertTrue(options.allowSensitiveArtifacts)
    XCTAssertEqual(plan.environment["ARKDECK_PI_ALLOW_SENSITIVE_ARTIFACTS"], "1")
    XCTAssertTrue(plan.arguments.contains("--no-session"))
    let promptIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--system-prompt"))
    XCTAssertTrue(plan.arguments[promptIndex + 1].contains("explicitly enabled"))
  }

  func testChatOptionsRejectUnknownAndRelativeExecutionSurfaces() throws {
    XCTAssertThrowsError(try PiAgentChatOptions.parse(["--model", "anything"])) { error in
      XCTAssertTrue((error as? CLIError)?.message.contains("--model") == true)
    }
    XCTAssertThrowsError(try PiAgentChatOptions.parse(["--prompt"])) { error in
      XCTAssertEqual((error as? CLIError)?.message, "--prompt requires a value")
    }
    XCTAssertThrowsError(try PiAgentChatOptions.parse(["--pi-path", "bin/pi"]))
    XCTAssertThrowsError(try PiAgentChatOptions.parse(["--socket", "agentd.sock"]))
    XCTAssertThrowsError(try PiAgentChatOptions.parse(["--prompt", "  "]))
  }

  func testInitialPromptCannotBecomeAPiFlagOrFileArgument() throws {
    for prompt in ["--model", "@/tmp/untrusted.txt"] {
      let options = try PiAgentChatOptions.parse(["--prompt", prompt])
      let plan = PiAgentChatLaunchPlan(
        piExecutable: URL(fileURLWithPath: "/opt/tools/pi"),
        extensionURL: URL(fileURLWithPath: "/bundle/Pi/arkdeck-extension.ts"),
        arkdeckExecutable: URL(fileURLWithPath: "/opt/arkdeck/bin/arkdeck"),
        options: options,
        inheritedEnvironment: [:])

      XCTAssertEqual(plan.arguments.last, "User request:\n\(prompt)")
      XCTAssertFalse(plan.arguments.last?.hasPrefix("-") == true)
      XCTAssertFalse(plan.arguments.last?.hasPrefix("@") == true)
    }
  }

  func testChatLaunchesAnExplicitPiExecutableWithoutAShell() throws {
    let executable = "/usr/bin/true"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw XCTSkip("/usr/bin/true is unavailable")
    }

    XCTAssertNoThrow(
      try PiAgentChat.run([
        "--pi-path", executable,
        "--socket", "/tmp/arkdeck-agentd-contract.sock",
      ]))
  }

  func testBundledExtensionKeepsTheModelOnClosedTypedOperations() throws {
    let source = try String(contentsOf: PiAgentChat.bundledExtensionURL(), encoding: .utf8)

    for tool in PiAgentChatLaunchPlan.activeTools {
      XCTAssertTrue(source.contains("name: \"\(tool)\""), "missing Pi tool \(tool)")
    }
    XCTAssertTrue(source.contains("\"observe.device@1\""))
    XCTAssertTrue(source.contains("\"capture.diagnostics@1\""))
    XCTAssertTrue(source.contains("CAPTURE_ARTIFACT_BUDGET_BYTES"))
    XCTAssertTrue(source.contains("MAX_OPERATION_RUNS = 8"))
    XCTAssertTrue(source.contains("MAX_WALL_CLOCK_SECONDS = 30 * 60"))
    XCTAssertTrue(source.contains("MAX_ARTIFACT_BYTES = 64 * 1024 * 1024"))
    XCTAssertTrue(source.contains("redactionProfile: \"standard\""))
    XCTAssertFalse(source.contains("params.redactionProfile"))
    XCTAssertTrue(source.contains("typeof receipt.jobID === \"string\""))
    XCTAssertTrue(source.contains("currentChatArtifacts.get(params.jobId)?.has(params.artifactId)"))
    XCTAssertTrue(source.contains("function noteRuntimeFailure"))
    XCTAssertTrue(source.contains("metadata.privacy !== \"standard\""))
    XCTAssertTrue(source.contains("pi.on(\"user_bash\""))
    XCTAssertFalse(source.contains("shell: true"))
    XCTAssertFalse(source.contains("Type.String({ description: \"Operation"))
    XCTAssertFalse(source.contains("traceCategories"))
    XCTAssertFalse(source.contains("uiScreenshot"))
    XCTAssertFalse(source.contains("uiComponentTree"))
    XCTAssertFalse(source.contains("capability.install"))
    XCTAssertFalse(source.contains("capability.revoke"))
  }
}
