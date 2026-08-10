// Native conversational Agent CLI. ArkDeck holds the transcript and model
// loop; this surface does not launch or delegate to another agent process.

import ArkDeckAgentComposition
import Darwin
import Foundation

struct AgentChatOptions: Equatable {
  let socketPath: String
  let initialPrompt: String?
  let allowSensitiveArtifacts: Bool

  static func parse(_ arguments: [String]) throws -> AgentChatOptions {
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
      case "--socket", "--prompt":
        guard index + 1 < arguments.count else {
          throw CLIError(exitCode: EX_USAGE, message: "\(argument) requires a value")
        }
        let value = arguments[index + 1]
        if argument == "--socket" {
          guard !socketWasProvided else {
            throw CLIError(exitCode: EX_USAGE, message: "--socket was provided more than once")
          }
          socketPath = value
          socketWasProvided = true
        } else {
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
            "unsupported agent chat argument \(argument); use --prompt, --socket, "
            + "or --allow-sensitive-artifacts")
      }
    }

    guard socketPath.hasPrefix("/") else {
      throw CLIError(exitCode: EX_USAGE, message: "--socket requires an absolute path")
    }
    if let initialPrompt,
      initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw CLIError(exitCode: EX_USAGE, message: "--prompt cannot be empty")
    }
    return AgentChatOptions(
      socketPath: socketPath,
      initialPrompt: initialPrompt,
      allowSensitiveArtifacts: allowSensitiveArtifacts)
  }
}

enum AgentChatCLI {
  static func run(_ arguments: [String]) async throws {
    let options = try AgentChatOptions.parse(arguments)
    let application = try AgentChatApplication.live(
      socketPath: options.socketPath,
      allowSensitiveArtifacts: options.allowSensitiveArtifacts,
      environment: ProcessInfo.processInfo.environment,
      nowUTC: RuntimeCLI.utcNow)

    if options.allowSensitiveArtifacts {
      writeError(
        "warning: sensitive Artifact text may be sent to the configured model for this session\n")
    }

    if let prompt = options.initialPrompt {
      try await application.runUserTurn(prompt, emit: render)
    }

    if isatty(STDIN_FILENO) != 0 {
      if options.initialPrompt == nil {
        print("ArkDeck Agent is ready. Type /exit to leave.")
      }
      while true {
        FileHandle.standardOutput.write(Data("\n> ".utf8))
        guard let line = readLine() else { break }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "/exit" || text == "/quit" { break }
        if text.isEmpty { continue }
        try await application.runUserTurn(text, emit: render)
      }
    } else if options.initialPrompt == nil {
      while let line = readLine() {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        try await application.runUserTurn(text, emit: render)
      }
    }
  }

  private static let render: @Sendable (AgentChatDisplayEvent) -> Void = { event in
    switch event {
    case .assistantText(let delta):
      FileHandle.standardOutput.write(Data(delta.utf8))
    case .toolCall(let name, let arguments):
      writeError("\n[tool] \(name) \(arguments)\n")
    case .toolResult(let name, let result):
      writeError("[tool result] \(name): \(result)\n")
    case .notice(let text):
      writeError("[agent] \(text)\n")
    case .turnEnded(let reason):
      FileHandle.standardOutput.write(Data("\n".utf8))
      if reason != .endTurn {
        writeError("[agent stopped: \(reason.rawValue)]\n")
      }
    }
  }

  private static func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}
