// Minimal conversational Device Agent entry point.
//
// Pi owns the interactive transcript and LLM tool loop. The bundled extension
// owns no device transport: it can only launch this exact ArkDeck executable
// with closed, typed CLI arguments. The existing AgentRuntimeExecutor remains
// the only path from an Agent tool call to agentd admission and execution.

import Darwin
import Foundation

struct PiAgentChatOptions: Equatable {
  let piPath: String?
  let socketPath: String
  let initialPrompt: String?
  let allowSensitiveArtifacts: Bool

  static func parse(_ arguments: [String]) throws -> PiAgentChatOptions {
    var piPath: String?
    var socketPath = RuntimeCLI.defaultSocketPath()
    var socketWasProvided = false
    var initialPrompt: String?
    var allowSensitiveArtifacts = false
    var index = 0

    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--allow-sensitive-artifacts":
        guard !allowSensitiveArtifacts else {
          throw CLIError(
            exitCode: EX_USAGE,
            message: "--allow-sensitive-artifacts was provided more than once")
        }
        allowSensitiveArtifacts = true
        index += 1
      case "--pi-path", "--socket", "--prompt":
        guard index + 1 < arguments.count else {
          throw CLIError(exitCode: EX_USAGE, message: "\(argument) requires a value")
        }
        let value = arguments[index + 1]
        switch argument {
        case "--pi-path":
          guard piPath == nil else {
            throw CLIError(exitCode: EX_USAGE, message: "--pi-path was provided more than once")
          }
          piPath = value
        case "--socket":
          guard !socketWasProvided else {
            throw CLIError(exitCode: EX_USAGE, message: "--socket was provided more than once")
          }
          socketPath = value
          socketWasProvided = true
        default:
          guard initialPrompt == nil else {
            throw CLIError(exitCode: EX_USAGE, message: "--prompt was provided more than once")
          }
          initialPrompt = value
        }
        index += 2
      default:
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "unsupported agent chat argument \(argument); use --prompt, --pi-path, --socket, "
            + "or --allow-sensitive-artifacts")
      }
    }

    if let piPath, !piPath.hasPrefix("/") {
      throw CLIError(exitCode: EX_USAGE, message: "--pi-path requires an absolute path")
    }
    guard socketPath.hasPrefix("/") else {
      throw CLIError(exitCode: EX_USAGE, message: "--socket requires an absolute path")
    }
    if let initialPrompt, initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw CLIError(exitCode: EX_USAGE, message: "--prompt cannot be empty")
    }

    return PiAgentChatOptions(
      piPath: piPath, socketPath: socketPath, initialPrompt: initialPrompt,
      allowSensitiveArtifacts: allowSensitiveArtifacts)
  }
}

struct PiAgentChatLaunchPlan {
  static let activeTools = [
    "arkdeck_runtime_overview",
    "arkdeck_observe_device",
    "arkdeck_capture_diagnostics",
    "arkdeck_read_artifact",
    "arkdeck_resume_after_user_action",
  ]

  let piExecutable: URL
  let arguments: [String]
  let environment: [String: String]

  init(
    piExecutable: URL,
    extensionURL: URL,
    arkdeckExecutable: URL,
    options: PiAgentChatOptions,
    inheritedEnvironment: [String: String]
  ) {
    self.piExecutable = piExecutable
    var arguments = [
      "--no-extensions",
      "--extension", extensionURL.path,
      "--no-builtin-tools",
      "--tools", Self.activeTools.joined(separator: ","),
      "--no-skills",
      "--no-prompt-templates",
      "--no-context-files",
      "--no-approve",
      "--system-prompt", Self.systemPrompt(
        allowsSensitiveArtifacts: options.allowSensitiveArtifacts),
    ]
    if options.allowSensitiveArtifacts { arguments.append("--no-session") }
    if let initialPrompt = options.initialPrompt {
      // Pi treats any positional beginning with `-` as a CLI flag and any
      // positional beginning with `@` as a file reference. Prefix the user's
      // text so it always remains one message argument instead of gaining a
      // second configuration or filesystem surface.
      arguments.append("User request:\n\(initialPrompt)")
    }
    self.arguments = arguments

    var environment = inheritedEnvironment
    environment["ARKDECK_PI_ARKDECK_PATH"] = arkdeckExecutable.path
    environment["ARKDECK_PI_AGENTD_SOCKET"] = options.socketPath
    environment["ARKDECK_PI_ALLOW_SENSITIVE_ARTIFACTS"] =
      options.allowSensitiveArtifacts ? "1" : "0"
    // This chat may contact the model provider the user selected, but it
    // does not need unrelated Pi update checks or install telemetry.
    environment["PI_SKIP_VERSION_CHECK"] = "1"
    environment["PI_TELEMETRY"] = "0"
    self.environment = environment
  }

  private static func systemPrompt(allowsSensitiveArtifacts: Bool) -> String {
    let privacy =
      allowsSensitiveArtifacts
      ? "The user explicitly enabled sensitive Artifact text for this ephemeral session. "
        + "Read it only when it is needed to answer the current request."
      : "Sensitive Artifact text is disabled. Explain how to restart with "
        + "--allow-sensitive-artifacts when raw HiLog or UI content is necessary."
    return """
      You are ArkDeck's conversational OpenHarmony device Agent. Pi owns the conversation and
      tool loop; ArkDeck Runtime owns targets, admission, execution, journals, recovery and
      Artifacts. Use only the available arkdeck_* tools. Never ask for or invent executable
      paths, command lines, device commands, remote paths, capability administration or raw
      transport access.

      Start with arkdeck_runtime_overview when target or availability is unknown. Use
      arkdeck_observe_device for current device facts and arkdeck_capture_diagnostics for a
      bounded read-only capture. Inspect the returned Artifact list and read only the products
      needed for the diagnosis. Reassess after every tool result; a later typed operation is a
      new Runtime admission, never an implicit retry.

      Stop and report the exact blocker on outcomeUnknown, authorizationRequired, repeated
      failure or exhausted budget. When Runtime requests a physical action, ask the user to do
      it and wait for a new user message before calling arkdeck_resume_after_user_action. Never
      claim real-device success without a succeeded Runtime terminal and verified Artifacts.

      \(privacy)
      """
  }
}

enum PiAgentChat {
  static func run(_ arguments: [String]) throws {
    let options = try PiAgentChatOptions.parse(arguments)
    let environment = ProcessInfo.processInfo.environment
    let piExecutable = try resolvePiExecutable(
      explicitPath: options.piPath,
      environment: environment)
    let extensionURL = try bundledExtensionURL()
    let arkdeckExecutable = try currentExecutableURL()
    let plan = PiAgentChatLaunchPlan(
      piExecutable: piExecutable,
      extensionURL: extensionURL,
      arkdeckExecutable: arkdeckExecutable,
      options: options,
      inheritedEnvironment: environment)

    if options.allowSensitiveArtifacts {
      let warning =
        "Sensitive Artifact sharing is enabled for this chat. Artifact text may be sent "
        + "to the selected Pi model provider; Pi session saving is disabled.\n"
      FileHandle.standardError.write(
        Data(warning.utf8))
    }

    let process = Process()
    process.executableURL = plan.piExecutable
    process.arguments = plan.arguments
    process.environment = plan.environment
    do {
      try process.run()
    } catch {
      throw CLIError(
        exitCode: 1,
        message: "unable to start Pi at \(plan.piExecutable.path): \(error)")
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw CLIError(
        exitCode: process.terminationStatus == 0 ? 1 : process.terminationStatus,
        message: "Pi ended with status \(process.terminationStatus)")
    }
  }

  static func bundledExtensionURL() throws -> URL {
    guard
      let url = Bundle.module.url(
        forResource: "arkdeck-extension", withExtension: "ts", subdirectory: "Pi")
    else {
      throw CLIError(exitCode: 1, message: "the bundled ArkDeck Pi extension is missing")
    }
    return url
  }

  static func resolvePiExecutable(
    explicitPath: String?,
    environment: [String: String],
    fileManager: FileManager = .default
  ) throws -> URL {
    if let explicitPath {
      return try validateExecutable(
        path: explicitPath, source: "--pi-path", fileManager: fileManager)
    }
    if let configured = environment["ARKDECK_PI_PATH"], !configured.isEmpty {
      return try validateExecutable(
        path: configured, source: "ARKDECK_PI_PATH", fileManager: fileManager)
    }
    for directory in (environment["PATH"] ?? "").split(
      separator: ":", omittingEmptySubsequences: true)
    {
      let path = String(directory)
      guard path.hasPrefix("/") else { continue }
      let candidate = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent("pi").path
      if fileManager.isExecutableFile(atPath: candidate) {
        return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().standardizedFileURL
      }
    }
    throw CLIError(
      exitCode: EX_UNAVAILABLE,
      message:
        "Pi is not installed. Install it with "
        + "`npm install -g --ignore-scripts @earendil-works/pi-coding-agent`, "
        + "or pass --pi-path <absolute-path>.")
  }

  private static func validateExecutable(
    path: String,
    source: String,
    fileManager: FileManager
  ) throws -> URL {
    guard path.hasPrefix("/") else {
      throw CLIError(exitCode: EX_USAGE, message: "\(source) requires an absolute path")
    }
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard fileManager.isExecutableFile(atPath: url.path) else {
      throw CLIError(
        exitCode: EX_UNAVAILABLE, message: "\(source) does not name an executable Pi file")
    }
    return url
  }

  private static func currentExecutableURL() throws -> URL {
    if let bundled = Bundle.main.executableURL {
      let canonical = bundled.resolvingSymlinksInPath().standardizedFileURL
      if FileManager.default.isExecutableFile(atPath: canonical.path) { return canonical }
    }
    let value = CommandLine.arguments[0]
    let url: URL
    if value.hasPrefix("/") {
      url = URL(fileURLWithPath: value)
    } else {
      url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(value)
    }
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: canonical.path) else {
      throw CLIError(exitCode: 1, message: "unable to resolve the current ArkDeck executable")
    }
    return canonical
  }
}
