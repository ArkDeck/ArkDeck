// Local agent-CLI decision gateway (CHG-2026-055, TASK-HFA-005).
//
// A signed-in ArkDeck host often has a local agent CLI already authenticated
// but no separately provisioned vendor API key. This adapter lets that host
// use the same bounded decision context through a direct argv process launch.
// It is not a shell adapter: the executable is identity-bound, the child is
// read-only and ephemeral, user rules and configuration are ignored where the
// CLI can be told to ignore them, and its working root is an explicit
// empty/operator-owned directory rather than the repaired workspace. The CLI
// receives only `HarnessVendorEnvelope.text(context)`.
//
// Which CLI is a *profile*, not a hard-coded vendor. The profile is the only
// place a concrete command line exists, the set of profiles is closed, and no
// argv fragment is ever taken from the environment — so adding a second agent
// CLI cannot become an operator-supplied raw command surface.
//
// This lane is for unattended operation only, and it is maintenance-frozen:
// the primary decision producer is an external agent reading `task.context`
// and answering at `task.proposePatch`, which needs none of this adapter's
// output-scraping. New profiles and envelope extensions are not accepted
// here; a producer need is met at the typed boundary instead.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckProcess
import CryptoKit
import Foundation

/// Where a CLI puts the model's final message. Every agent CLI prints session
/// diagnostics somewhere; the difference is whether the payload is separable
/// from them by a file the CLI writes, or because the CLI prints the payload
/// and nothing else.
public enum HarnessLocalAgentResponseChannel: String, Sendable, Equatable {
  /// The CLI writes the final message to a path we pass it, and stdout is
  /// diagnostics we never read.
  case finalMessageFile
  /// The CLI prints the final message on stdout and nothing else.
  case standardOutput
}

/// One concrete local agent CLI: how to invoke it for a single bounded,
/// non-interactive answer, and how to read that answer back.
public struct HarnessLocalAgentCLIProfile: Sendable, Equatable {
  /// Stable identifier; it names the producer in durable decision records, so
  /// it may not drift once a record exists.
  public let profileID: String
  /// Reported as the model provider in `HarnessModelDescriptor`.
  public let providerLabel: String
  public let responseChannel: HarnessLocalAgentResponseChannel
  /// Parent-environment variables this CLI needs beyond the executor's
  /// fail-closed base (`PATH`, `HOME`, `TMPDIR`, `LANG`). Names only: the
  /// value is read from the parent at request time and is never a literal
  /// here, and a name that is absent in the parent is simply not passed.
  public let inheritedEnvironmentKeys: [String]
  private let argumentBuilder:
    @Sendable (_ modelName: String, _ workingDirectory: String, _ prompt: String,
      _ finalMessagePath: String?) -> [String]

  init(
    profileID: String,
    providerLabel: String,
    responseChannel: HarnessLocalAgentResponseChannel,
    inheritedEnvironmentKeys: [String] = [],
    argumentBuilder: @escaping @Sendable (String, String, String, String?) -> [String]
  ) {
    self.profileID = profileID
    self.providerLabel = providerLabel
    self.responseChannel = responseChannel
    self.inheritedEnvironmentKeys = inheritedEnvironmentKeys
    self.argumentBuilder = argumentBuilder
  }

  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.profileID == rhs.profileID }

  public func arguments(
    modelName: String, workingDirectory: String, prompt: String, finalMessagePath: String?
  ) -> [String] {
    argumentBuilder(modelName, workingDirectory, prompt, finalMessagePath)
  }

  /// OpenAI Codex CLI. `codex exec` emits session diagnostics on stdout even
  /// with `--color never`, so its explicit output file is what keeps those
  /// diagnostics from becoming JSON input.
  public static let codex = HarnessLocalAgentCLIProfile(
    profileID: "codex",
    providerLabel: "openai-codex-cli",
    responseChannel: .finalMessageFile
  ) { model, workingDirectory, prompt, finalMessagePath in
    var arguments = ["exec"]
    if let finalMessagePath {
      arguments += ["--output-last-message", finalMessagePath]
    }
    arguments += [
      "--ephemeral", "--ignore-user-config", "--ignore-rules",
      "--sandbox", "read-only", "--skip-git-repo-check",
      "-C", workingDirectory, "--color", "never", "--model", model,
      prompt,
    ]
    return arguments
  }

  /// Anthropic Claude Code CLI in print mode, which writes the answer and
  /// nothing else to stdout. `USER` is inherited because the CLI resolves its
  /// stored credential through it; without it the child reports "Not logged
  /// in" while every other condition looks healthy.
  ///
  /// Deliberately no `--permission-mode`: print mode has nobody to answer a
  /// permission prompt, so the default already denies every tool, while
  /// `plan` made the CLI read a request for one JSON decision as an attempt
  /// to route around its own approval gate and answer with prose about that
  /// instead of the decision (observed on device, 2026-08-05). The harness
  /// wants pure text-in/text-out reasoning here, not an agent with tools.
  public static let claudeCode = HarnessLocalAgentCLIProfile(
    profileID: "claude-code",
    providerLabel: "anthropic-claude-code-cli",
    responseChannel: .standardOutput,
    inheritedEnvironmentKeys: ["USER"]
  ) { model, _, prompt, _ in
    [
      "--print", "--model", model, "--output-format", "text",
      "--strict-mcp-config",
      prompt,
    ]
  }

  /// The closed set. A provider name outside it is a configuration error, not
  /// an improvised command line.
  public static let all: [HarnessLocalAgentCLIProfile] = [codex, claudeCode]

  public static func named(_ profileID: String) -> HarnessLocalAgentCLIProfile? {
    all.first { $0.profileID == profileID.lowercased() }
  }
}

public struct HarnessLocalAgentCLIRequest: Sendable, Equatable {
  public let executablePath: String
  public let executableSHA256: String
  public let profile: HarnessLocalAgentCLIProfile
  public let modelName: String
  public let prompt: String
  public let workingDirectory: String
  public let timeoutSeconds: Int

  public init(
    executablePath: String,
    executableSHA256: String,
    profile: HarnessLocalAgentCLIProfile,
    modelName: String,
    prompt: String,
    workingDirectory: String,
    timeoutSeconds: Int
  ) {
    self.executablePath = executablePath
    self.executableSHA256 = executableSHA256
    self.profile = profile
    self.modelName = modelName
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
  }
}

public protocol HarnessLocalAgentCLITransport: Sendable {
  func send(_ request: HarnessLocalAgentCLIRequest) async throws -> Data
}

public struct LocalAgentCLIProcessTransport: HarnessLocalAgentCLITransport {
  private let executor: FoundationProcessExecutor
  private let captureLimit: Int
  private let parentEnvironment: [String: String]

  public init(
    executor: FoundationProcessExecutor = FoundationProcessExecutor(),
    captureLimit: Int = 512 * 1024,
    parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.executor = executor
    self.captureLimit = captureLimit
    self.parentEnvironment = parentEnvironment
  }

  public func send(_ request: HarnessLocalAgentCLIRequest) async throws -> Data {
    let fileManager = FileManager.default
    let needsFile = request.profile.responseChannel == .finalMessageFile
    var outputRoot: URL?
    var outputURL: URL?
    if needsFile {
      let root = fileManager.temporaryDirectory.appending(
        path: "arkdeck-agent-cli-output-\(UUID().uuidString)", directoryHint: .isDirectory)
      do {
        try fileManager.createDirectory(
          at: root, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIOutputDirectoryUnavailable")
      }
      outputRoot = root
      outputURL = root.appending(path: "last-message.json", directoryHint: .notDirectory)
    }
    defer { if let outputRoot { try? fileManager.removeItem(at: outputRoot) } }

    var environment = ["NO_COLOR": "1"]
    for key in request.profile.inheritedEnvironmentKeys {
      if let value = parentEnvironment[key] { environment[key] = value }
    }
    let execution: ProcessIdentityBoundExecutionResult
    do {
      execution = try await executor.executeIdentityBound(
        ProcessIdentityBoundRequest(
          process: ProcessRequest(
            executable: URL(fileURLWithPath: request.executablePath),
            arguments: request.profile.arguments(
              modelName: request.modelName,
              workingDirectory: request.workingDirectory,
              prompt: request.prompt,
              finalMessagePath: outputURL?.path),
            environment: environment,
            workingDirectory: URL(fileURLWithPath: request.workingDirectory, isDirectory: true),
            timeout: TimeInterval(request.timeoutSeconds)),
          expectedSHA256: request.executableSHA256),
        captureLimit: captureLimit)
    } catch {
      throw HarnessDecisionGatewayError.transportFailure("agentCLIProcessLaunchFailed")
    }
    guard execution.execution.termination == .exited(0) else {
      throw HarnessDecisionGatewayError.transportFailure("agentCLIProcessFailed")
    }

    let response: Data
    switch request.profile.responseChannel {
    case .finalMessageFile:
      guard let outputURL else {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIFinalMessageUnavailable")
      }
      let size: Int64
      do {
        size = (try fileManager.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?
          .int64Value ?? -1
      } catch {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIFinalMessageUnavailable")
      }
      guard size >= 0, size <= Int64(captureLimit) else {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIResponseTruncated")
      }
      do {
        response = try Data(contentsOf: outputURL)
      } catch {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIFinalMessageUnavailable")
      }
    case .standardOutput:
      // A capture that hit its limit is not a short answer; it is an answer we
      // cannot prove we read whole.
      guard !execution.execution.stdout.wasTruncated else {
        throw HarnessDecisionGatewayError.transportFailure("agentCLIResponseTruncated")
      }
      response = execution.execution.stdout.data
    }
    guard !response.isEmpty else {
      throw HarnessDecisionGatewayError.transportFailure("agentCLIResponseEmpty")
    }
    // Whitespace and a Markdown code fence are presentation, not content: a
    // CLI that wraps its answer in ```json has still answered, and refusing
    // it burns a round on formatting (observed on device, 2026-08-05).
    // Unwrapping stops there — the closed key set, the forbidden fields and
    // every value check remain `HarnessDecisionProposal.parse`'s to make on
    // the bytes inside.
    let trimmed = Self.unfenced(String(decoding: response, as: UTF8.self))
    guard !trimmed.isEmpty else {
      throw HarnessDecisionGatewayError.transportFailure("agentCLIResponseEmpty")
    }
    return Data(trimmed.utf8)
  }
}

extension LocalAgentCLIProcessTransport {
  /// Strips one surrounding Markdown code fence, with or without a language
  /// tag. Text that is not fenced is returned trimmed and otherwise
  /// untouched, and a fence that does not close is left alone rather than
  /// half-removed.
  static func unfenced(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let fenced = lastFencedObject(in: trimmed) { return fenced }
    // The same narration, without the fence. `lastFencedObject` was added
    // because an agent says what it checked and then states its answer in a
    // ```json block; it also sometimes states the answer as bare JSON on the
    // next line. That variant reached the parser with the sentence still
    // attached and a complete, correct patch proposal was discarded as
    // malformed (observed on device, `HTASK-7C12960C4B6E` round 7 — the one
    // round where a proposal was possible, which is why that run stopped).
    // Only where no fence is involved at all. Text containing a fence — even
    // an unterminated one — is governed by the rule directly below, which
    // deliberately leaves those bytes as returned rather than half-removing a
    // fence. Reaching into it here would overturn that decision as a side
    // effect of fixing a different case.
    if !trimmed.hasPrefix("{"), !trimmed.contains("```"),
      let bare = lastTopLevelObject(in: trimmed)
    {
      return bare
    }
    guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else {
      return trimmed
    }
    var body = trimmed.dropFirst(3).dropLast(3)
    // A language tag runs to the end of the opening line.
    if let newline = body.firstIndex(of: "\n") {
      let tag = body[body.startIndex..<newline]
      if tag.allSatisfy({ $0.isLetter || $0.isNumber }) {
        body = body[body.index(after: newline)...]
      }
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The last fenced block that holds a JSON object, or nil.
  ///
  /// A CLI agent narrates. It says what it checked, shows the diff, and then
  /// states its answer in a ```json block - and a correct, complete patch
  /// proposal was thrown away as malformed because two sentences preceded it
  /// (observed on device, 2026-08-05). Reaching past the narration is the
  /// same judgement the surrounding fence-stripping already makes: this is
  /// presentation, and the answer is the object.
  ///
  /// Last, not first, because an agent that shows its work puts the answer at
  /// the end - an earlier block is a draft or an illustration. Nothing here
  /// interprets the bytes: the closed key set, the forbidden fields, the
  /// offered-operation check and the raw-surface screen are all still
  /// `HarnessDecisionProposal.parse`'s to apply to whatever comes out.
  static func lastFencedObject(in text: String) -> String? {
    var blocks: [String] = []
    var remainder = Substring(text)
    while let open = remainder.range(of: "```") {
      var body = remainder[open.upperBound...]
      // A language tag runs to the end of the opening line.
      if let newline = body.firstIndex(of: "\n") {
        let tag = body[body.startIndex..<newline]
        if tag.allSatisfy({ $0.isLetter || $0.isNumber }) {
          body = body[body.index(after: newline)...]
        }
      }
      guard let close = body.range(of: "```") else { break }
      blocks.append(
        String(body[body.startIndex..<close.lowerBound])
          .trimmingCharacters(in: .whitespacesAndNewlines))
      remainder = body[close.upperBound...]
    }
    return blocks.last { $0.hasPrefix("{") && $0.hasSuffix("}") }
  }

  /// The last balanced top-level `{…}` in unfenced text, or nil.
  ///
  /// Last for the same reason `lastFencedObject` takes the last block: an
  /// agent that shows its work puts the answer at the end.
  ///
  /// Braces inside JSON strings do not count, and neither does an escaped
  /// quote — a unified diff arrives inside one of those strings, so a scanner
  /// that ignored either would cut the answer in half. Nothing here
  /// interprets the bytes: the closed key set, the forbidden fields, the
  /// offered-operation check and the raw-surface screen all remain
  /// `HarnessDecisionProposal.parse`'s to apply to whatever comes out.
  static func lastTopLevelObject(in text: String) -> String? {
    var candidates: [String] = []
    var start: String.Index?
    var depth = 0
    var inString = false
    var escaped = false
    for index in text.indices {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
        continue
      }
      switch character {
      case "\"":
        inString = true
      case "{":
        if depth == 0 { start = index }
        depth += 1
      case "}":
        guard depth > 0 else { break }
        depth -= 1
        if depth == 0, let opened = start {
          candidates.append(String(text[opened...index]))
          start = nil
        }
      default:
        break
      }
    }
    // An unterminated object is left alone rather than half-taken, the same
    // way an unclosed fence is.
    return candidates.last
  }
}

public struct LocalAgentCLIDecisionGateway: HarnessDecisionGateway {
  private let executablePath: String
  private let executableSHA256: String
  private let profile: HarnessLocalAgentCLIProfile
  private let modelName: String
  private let workingDirectory: String
  private let timeoutSeconds: Int
  private let transport: any HarnessLocalAgentCLITransport

  public init(
    profile: HarnessLocalAgentCLIProfile,
    executablePath: String,
    modelName: String,
    workingDirectory: String,
    timeoutSeconds: Int = 180,
    transport: any HarnessLocalAgentCLITransport = LocalAgentCLIProcessTransport()
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
    self.profile = profile
    self.executablePath = executable
    self.executableSHA256 = SHA256Hex.string(of: bytes)
    self.modelName = modelName
    self.workingDirectory = workdir
    self.timeoutSeconds = timeoutSeconds
    self.transport = transport
  }

  public var producerID: String { "\(profile.profileID)-cli-gateway@1" }

  public var modelDescriptor: HarnessModelDescriptor {
    HarnessModelDescriptor(
      provider: profile.providerLabel, modelName: modelName, adapterVersion: producerID)
  }

  public func propose(_ context: HarnessDecisionContext) async throws -> Data {
    try await transport.send(
      HarnessLocalAgentCLIRequest(
        executablePath: executablePath,
        executableSHA256: executableSHA256,
        profile: profile,
        modelName: modelName,
        prompt: HarnessVendorEnvelope.text(context),
        workingDirectory: workingDirectory,
        timeoutSeconds: timeoutSeconds))
  }
}
