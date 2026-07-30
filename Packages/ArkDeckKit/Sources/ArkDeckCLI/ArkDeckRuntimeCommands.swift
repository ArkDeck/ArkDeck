// Runtime client commands (CHG-2026-048, T09/T11).
//
// `arkdeck doctor`, `arkdeck device list|adopt|show` and
// `arkdeck job submit|status` are thin daemon clients: they construct a
// typed request or a control-plane call and print the response. No HDC,
// no argv, no executor lives here - the CLI cannot execute a device
// operation even in principle, only ask the daemon to.

import ArkDeckAgentClient
import ArkDeckCore
import CryptoKit
import Darwin
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

  /// `arkdeck agent run|resume` - the Device Runtime Agent entry point.
  /// A persisted resume token keeps physical assistance inside the same
  /// execution instead of asking a maintainer to restart host commands.
  static func runAgent(_ arguments: [String]) throws {
    guard let subcommand = arguments.first, subcommand == "run" || subcommand == "resume" else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "usage: arkdeck agent run --operation <id@v> | agent resume --resume-token <token>")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    let executor = AgentRuntimeExecutor(client: client, nowUTC: RuntimeCLI.utcNow)
    let outcome: RuntimeAgentExecutionOutcome

    if subcommand == "resume" {
      guard let tokenIndex = rest.firstIndex(of: "--resume-token"),
        tokenIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent resume requires --resume-token")
      }
      var selection: String?
      if let index = rest.firstIndex(of: "--selection"), index + 1 < rest.count {
        selection = rest[index + 1]
      }
      outcome = try executor.resume(
        resumeToken: rest[tokenIndex + 1], selection: selection)
    } else {
      guard let operationIndex = rest.firstIndex(of: "--operation"),
        operationIndex + 1 < rest.count
      else {
        throw CLIError(exitCode: EX_USAGE, message: "agent run requires --operation <id@version>")
      }
      let parts = rest[operationIndex + 1].split(separator: "@")
      guard parts.count == 2, let version = Int(parts[1]) else {
        throw CLIError(exitCode: EX_USAGE, message: "operation must be <id>@<version>")
      }
      var inputs: [String: JSONValue] = [:]
      if let index = rest.firstIndex(of: "--inputs-file"), index + 1 < rest.count {
        let url = URL(fileURLWithPath: rest[index + 1])
        guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read typed inputs from \(url.path)")
        }
        inputs = decoded
      }
      var capability: String?
      if let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count {
        capability = rest[index + 1]
      }
      var target: String?
      if let index = rest.firstIndex(of: "--target"), index + 1 < rest.count {
        target = rest[index + 1]
      }

      outcome = try executor.run(
        RuntimeAgentExecutionRequest(
          operationID: String(parts[0]), operationVersion: version, inputs: inputs,
          capabilityReference: capability, targetID: target))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]

    switch outcome {
    case .completed(let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      } else {
        print("completed \(receipt.operationReference) job=\(receipt.jobID ?? "-")")
      }
    case .awaitingHumanAction(let action, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      FileHandle.standardError.write(
        Data(
          """
          human action required (\(action.kind.rawValue)): \(action.prompt)
          \(action.selectionOptions.map { "selection options: \($0.joined(separator: ", "))\n" } ?? "")\
          resume with: arkdeck agent resume --resume-token \(action.resumeToken)

          """.utf8))
      throw CLIError(exitCode: 75, message: "paused for physical assistance")
    case .failed(let reason, let receipt):
      if json, let data = try? encoder.encode(receipt),
        let text = String(data: data, encoding: .utf8)
      {
        print(text)
      }
      throw CLIError(exitCode: 1, message: reason)
    }
  }

  static func utcNow() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: Date())
  }

  static func runCapability(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE, message: "missing capability subcommand (list|install|revoke)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    switch subcommand {
    case "list":
      emit(try client.request(method: "capability.list"), json: json)
    case "install":
      guard let index = rest.firstIndex(of: "--file"), index + 1 < rest.count else {
        throw CLIError(exitCode: EX_USAGE, message: "capability install requires --file <path>")
      }
      let url = URL(fileURLWithPath: rest[index + 1])
      guard let document = try? String(contentsOf: url, encoding: .utf8) else {
        throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
      }
      emit(
        try client.request(
          method: "capability.install", params: ["capabilityJson": .string(document)]),
        json: json)
    case "revoke":
      guard let index = rest.firstIndex(of: "--capability"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "capability revoke requires --capability <id>")
      }
      emit(
        try client.request(
          method: "capability.revoke", params: ["capabilityId": .string(rest[index + 1])]),
        json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported capability subcommand")
    }
  }

  static func runArtifact(_ arguments: [String]) throws {
    guard let subcommand = arguments.first else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "missing artifact subcommand (import-hap|list|inspect|read|export)")
    }
    var rest = Array(arguments.dropFirst())
    let json = rest.contains("--json")
    let client = client(&rest)
    if subcommand == "import-hap" {
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let fileIndex = rest.firstIndex(of: "--file"), fileIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message: "artifact import-hap requires --target <id> --file <signed.hap>")
      }
      let targetID = rest[targetIndex + 1]
      let payload = try readHAPImportPayload(path: rest[fileIndex + 1])
      let begin = try client.request(
        method: "artifact.importHap.begin",
        params: [
          "targetId": .string(targetID),
          "name": .string(payload.name),
          "byteCount": .integer(Int64(payload.contents.count)),
          "sha256": .string(payload.sha256),
        ])
      guard case .object(let beginFields) = begin,
        case .string(let uploadID)? = beginFields["uploadId"],
        case .integer(let maximumChunkValue)? = beginFields["maximumChunkBytes"],
        maximumChunkValue > 0, maximumChunkValue <= Int64(Int.max)
      else {
        throw AgentClientError.malformedResponse(
          "artifact.importHap.begin returned no bounded upload identity")
      }
      var committed = false
      defer {
        if !committed {
          _ = try? client.request(
            method: "artifact.importHap.abort",
            params: ["uploadId": .string(uploadID)])
        }
      }
      let maximumChunk = Int(maximumChunkValue)
      var offset = 0
      while offset < payload.contents.count {
        let end = min(payload.contents.count, offset + maximumChunk)
        let chunk = payload.contents.subdata(in: offset..<end)
        let appended = try client.request(
          method: "artifact.importHap.append",
          params: [
            "uploadId": .string(uploadID),
            "offset": .integer(Int64(offset)),
            "base64": .string(chunk.base64EncodedString()),
          ])
        guard case .object(let fields) = appended,
          case .integer(let nextOffset)? = fields["nextOffset"],
          nextOffset == Int64(end)
        else {
          throw AgentClientError.malformedResponse(
            "artifact.importHap.append returned a mismatched offset")
        }
        offset = end
      }
      let result = try client.request(
        method: "artifact.importHap.commit",
        params: ["uploadId": .string(uploadID)])
      committed = true
      emit(result, json: json)
      return
    }
    guard let jobIndex = rest.firstIndex(of: "--job"), jobIndex + 1 < rest.count else {
      throw CLIError(exitCode: EX_USAGE, message: "artifact commands require --job <id>")
    }
    var params: [String: JSONValue] = ["jobId": .string(rest[jobIndex + 1])]
    if let index = rest.firstIndex(of: "--artifact"), index + 1 < rest.count {
      params["artifactId"] = .string(rest[index + 1])
    }
    if rest.contains("--allow-sensitive") { params["allowSensitive"] = .bool(true) }
    switch subcommand {
    case "list":
      emit(try client.request(method: "artifact.list", params: params), json: json)
    case "inspect":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact inspect requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.inspect", params: params), json: json)
    case "read":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact read requires --artifact <id>")
      }
      emit(try client.request(method: "artifact.read", params: params), json: json)
    case "export":
      guard params["artifactId"] != nil else {
        throw CLIError(exitCode: EX_USAGE, message: "artifact export requires --artifact <id>")
      }
      guard let index = rest.firstIndex(of: "--destination"), index + 1 < rest.count else {
        throw CLIError(
          exitCode: EX_USAGE, message: "artifact export requires --destination <directory>")
      }
      params["destinationDirectory"] = .string(rest[index + 1])
      emit(try client.request(method: "artifact.export", params: params), json: json)
    default:
      throw CLIError(exitCode: EX_USAGE, message: "unsupported artifact subcommand")
    }
  }

  private struct HAPImportPayload {
    let name: String
    let contents: Data
    let sha256: String
  }

  private static func readHAPImportPayload(path: String) throws -> HAPImportPayload {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let name = url.lastPathComponent
    guard name.count <= 128,
      name.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.hap$"#,
        options: .regularExpression) != nil
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP file must have a safe .hap basename")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw CLIError(
        exitCode: EX_USAGE, message: "cannot open HAP file (errno \(errno))")
    }
    defer { Darwin.close(descriptor) }
    var before = stat()
    let maximumBytes = 64 * 1_024 * 1_024
    guard fstat(descriptor, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0,
      before.st_size <= maximumBytes
    else {
      throw CLIError(
        exitCode: EX_USAGE,
        message: "HAP must be a non-empty regular file no larger than \(maximumBytes) bytes")
    }
    var contents = Data()
    contents.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else {
        throw CLIError(
          exitCode: EX_USAGE, message: "HAP read failed (errno \(errno))")
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      contents.count == Int(before.st_size),
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_size == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP changed while it was being imported")
    }
    guard contents.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
      throw CLIError(
        exitCode: EX_USAGE, message: "HAP is not a ZIP-based .hap container")
    }
    let digest = SHA256.hash(data: contents)
      .map { String(format: "%02x", $0) }.joined()
    return HAPImportPayload(name: name, contents: contents, sha256: digest)
  }

  private static func json2Bool(_ arguments: [String]) -> Bool {
    arguments.contains("--json")
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
      // A prepared request file carries typed inputs the flag form cannot
      // express; it is passed through verbatim so the daemon, not the CLI,
      // remains the validator.
      if let fileIndex = rest.firstIndex(of: "--request-file"), fileIndex + 1 < rest.count {
        let url = URL(fileURLWithPath: rest[fileIndex + 1])
        guard let json = try? String(contentsOf: url, encoding: .utf8) else {
          throw CLIError(exitCode: EX_USAGE, message: "cannot read \(url.path)")
        }
        let submitted = try client.request(
          method: "job.submit", params: ["requestJson": .string(json)])
        emit(submitted, json: json2Bool(rest))
        if rest.contains("--wait"), case .object(let fields) = submitted,
          case .string(let jobID)? = fields["jobId"]
        {
          emit(
            try client.request(method: "job.run", params: ["jobId": .string(jobID)]),
            json: json2Bool(rest))
        }
        return
      }
      guard let targetIndex = rest.firstIndex(of: "--target"), targetIndex + 1 < rest.count,
        let operationIndex = rest.firstIndex(of: "--operation"), operationIndex + 1 < rest.count
      else {
        throw CLIError(
          exitCode: EX_USAGE,
          message:
            "job submit requires --target <id> --operation <id@version>, "
            + "or --request-file <path> for typed inputs")
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
