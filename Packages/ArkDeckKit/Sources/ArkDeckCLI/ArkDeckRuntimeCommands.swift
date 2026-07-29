// Runtime client commands (CHG-2026-048, T09/T11).
//
// `arkdeck doctor`, `arkdeck device list|adopt|show` and
// `arkdeck job submit|status` are thin daemon clients: they construct a
// typed request or a control-plane call and print the response. No HDC,
// no argv, no executor lives here - the CLI cannot execute a device
// operation even in principle, only ask the daemon to.

import ArkDeckAgentClient
import ArkDeckCore
import Foundation

enum RuntimeCLI {
  static func defaultSocketPath() -> String {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ArkDeck/Agentd/agentd.sock").path
  }

  static func client(_ arguments: inout [String]) -> AgentClient {
    var socketPath = defaultSocketPath()
    if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
      socketPath = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
    }
    return AgentClient(socketPath: socketPath)
  }

  static func emit(_ value: JSONValue, json: Bool) {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
        return
      }
    }
    print(render(value, indent: 0))
  }

  private static func render(_ value: JSONValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch value {
    case .object(let fields):
      return fields.keys.sorted().map { key in
        "\(pad)\(key): \(render(fields[key] ?? .null, indent: indent + 1).trimmingCharacters(in: .whitespaces))"
      }.joined(separator: "\n")
    case .array(let items):
      if items.isEmpty { return "\(pad)(none)" }
      return items.map { "\(pad)- \(render($0, indent: indent + 1).trimmingCharacters(in: .whitespaces))" }
        .joined(separator: "\n")
    case .string(let text): return "\(pad)\(text)"
    case .integer(let number): return "\(pad)\(number)"
    case .unsignedInteger(let number): return "\(pad)\(number)"
    case .number(let number): return "\(pad)\(number)"
    case .bool(let flag): return "\(pad)\(flag)"
    case .null: return "\(pad)-"
    }
  }

  static func runDoctor(_ arguments: [String]) throws {
    var rest = arguments
    let json = rest.contains("--json")
    let client = client(&rest)
    emit(try client.request(method: "doctor"), json: json)
  }

  static func runDevice(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing device subcommand (list|adopt|show)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list", "show":
      emit(try client.request(method: "target.list"), json: json)
    case "adopt":
      var params: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--candidate"), index + 1 < rest.count {
        params["candidate"] = .string(rest[index + 1])
      }
      emit(try client.request(method: "target.adopt", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported device subcommand")
    }
  }

  static func runJob(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(exitCode: EX_USAGE, message: "missing job subcommand (submit|status|list)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "job.list"), json: json)
    case "status":
      guard let index = rest.firstIndex(of: "--job"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "job status requires --job <id>")
      }
      emit(
        try client.request(method: "job.status", params: ["jobId": .string(rest[index + 1])]),
        json: json)
    case "submit":
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let operationIndex = rest.firstIndex(of: "--operation"), operationIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "job submit requires --target <id> --operation <id@version>")
      }
      let reference = rest[operationIndex + 1]
      let parts = reference.split(separator: "@")
      guard parts.count == 2, let version = Int(parts[1]) else {
        throw CLIError(exitCode: EX_USAGE, message: "operation must be <id>@<version>")
      }
      // The CLI builds a typed v2 request: no governance identifiers exist
      // in this surface to pass along even by accident.
      let requestJSON = """
        {"documentType":"runtime-operation-request","schemaVersion":"2.0.0",\
        "requestId":"cli-\(UUID().uuidString.prefix(8).lowercased())",\
        "idempotencyKey":"cli-\(UUID().uuidString.lowercased())",\
        "target":{"targetId":"\(rest[targetIndex + 1])"},\
        "operation":{"id":"\(parts[0])","version":\(version)}}
        """
      let submitted = try client.request(
        method: "job.submit", params: ["requestJson": .string(requestJSON)])
      emit(submitted, json: json)
      if rest.contains("--wait"), case .object(let fields) = submitted,
        case .string(let jobID)? = fields["jobId"]
      {
        emit(
          try client.request(method: "job.run", params: ["jobId": .string(jobID)]), json: json)
      }
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported job subcommand")
    }
  }
}
