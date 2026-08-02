// Local Codex CLI decision gateway (CHG-2026-055, TASK-HFA-005).
//
// A signed-in ArkDeck host may already have the Codex CLI but no separately
// provisioned vendor API key.  This adapter lets that host use the same
// bounded decision context through a direct argv process launch.  It is not a
// shell adapter: the executable is identity-bound, the child is read-only and
// ephemeral, rules and user configuration are ignored, and its working root
// is an explicit empty/operator-owned directory rather than the repaired
// workspace.  The CLI receives only `HarnessVendorEnvelope.text(context)`.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckProcess
import CryptoKit
import Foundation

public struct HarnessCodexProcessRequest: Sendable, Equatable {
  public let executablePath: String
  public let executableSHA256: String
  public let arguments: [String]
  public let workingDirectory: String
  public let timeoutSeconds: Int

  public init(
    executablePath: String,
    executableSHA256: String,
    arguments: [String],
    workingDirectory: String,
    timeoutSeconds: Int
  ) {
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
  }
}

public protocol HarnessCodexTransport: Sendable {
  func send(_ request: HarnessCodexProcessRequest) async throws -> Data
}

public struct CodexCLIProcessTransport: HarnessCodexTransport {
  private let executor: FoundationProcessExecutor
  private let captureLimit: Int

  public init(
    executor: FoundationProcessExecutor = FoundationProcessExecutor(),
    captureLimit: Int = 512 * 1024
  ) {
    self.executor = executor
    self.captureLimit = captureLimit
  }

  public func send(_ request: HarnessCodexProcessRequest) async throws -> Data {
    let execution: ProcessIdentityBoundExecutionResult
    do {
      execution = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            environment: ["NO_COLOR": "1"],
            workingDirectory: URL(fileURLWithPath: request.workingDirectory, isDirectory: true),
            timeout: TimeInterval(request.timeoutSeconds)),
          expectedSHA256: request.executableSHA256),
        captureLimit: captureLimit)
    } catch {
      throw HarnessDecisionGatewayError.transportFailure("codexProcessLaunchFailed")
    }
    guard execution.execution.termination == .exited(0) else {
      throw HarnessDecisionGatewayError.transportFailure("codexProcessFailed")
    }
    guard !execution.execution.stdout.wasTruncated else {
      throw HarnessDecisionGatewayError.transportFailure("codexResponseTruncated")
    }
    let response = execution.execution.stdout.data
    guard !response.isEmpty else {
      throw HarnessDecisionGatewayError.transportFailure("codexResponseEmpty")
    }
    // Whitespace is not semantic JSON content.  Everything else remains raw
    // bytes until `HarnessDecisionProposal.parse` accepts or rejects it.
    let trimmed = String(decoding: response, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw HarnessDecisionGatewayError.transportFailure("codexResponseEmpty")
    }
    return Data(trimmed.utf8)
  }
}

public struct CodexCLIDecisionGateway: HarnessDecisionGateway {
  private let executablePath: String
  private let executableSHA256: String
  private let modelName: String
  private let workingDirectory: String
  private let timeoutSeconds: Int
  private let transport: any HarnessCodexTransport

  public init(
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    timeoutSeconds: Int = 180,
    transport: any HarnessCodexTransport = CodexCLIProcessTransport()
  ) throws {
    let executable = URL(fileURLWithPath: executablePath)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let workdir = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard executablePath.hasPrefix("/"), executable == executablePath,
      FileManager.default.isExecutableFile(atPath: executable),
      let bytes = try? Data(contentsOf: URL(fileURLWithPath: executable)),
      FileManager.default.fileExists(atPath: workdir, isDirectory: &isDirectory),
      isDirectory.boolValue,
      workingDirectory.hasPrefix("/"), workdir == workingDirectory,
      (1...900).contains(timeoutSeconds)
    else {
      throw HarnessVendorConfigurationError.malformedExecutable
    }
    self.executablePath = executable
    self.executableSHA256 = SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }.joined()
    self.modelName = modelName
    self.workingDirectory = workdir
    self.timeoutSeconds = timeoutSeconds
    self.transport = transport
  }

  public var producerID: String { "codex-cli-gateway@1" }

  public var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(
      provider: "openai-codex-cli", modelName: modelName, adapterVersion: producerID)
  }

  public func propose(_ context: HarnessDecisionContext) async throws -> Data {
    let prompt = HarnessVendorEnvelope.text(context)
    return try await transport.send(
      HarnessCodexProcessRequest(
        executablePath: executablePath,
        executableSHA256: executableSHA256,
        arguments: [
          "exec", "--ephemeral", "--ignore-user-config", "--ignore-rules",
          "--sandbox", "read-only", "--skip-git-repo-check",
          "-C", workingDirectory, "--color", "never", "--model", modelName,
          prompt,
        ],
        workingDirectory: workingDirectory,
        timeoutSeconds: timeoutSeconds))
  }
}
